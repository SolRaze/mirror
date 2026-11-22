// Extend: a virtual display streamed to folio over USB, or Wi-Fi when unplugged.
//
// The display is 1000x600 points, rendered at 2000x1200 pixels: the 5:3 panel at
// 2 panel pixels per point, so capture is 1:1 with the panel and a point is about
// 0.23 mm on the glass, near the Mac's own screens. ScreenCaptureKit captures it
// at the panel size,
// VideoToolbox encodes H.264, and the stream goes to folio through
// `adb reverse` on the USB or Wi-Fi transport. Capture and encode run only while
// the folio app is connected.
//
// Wire format, Mac to folio: u8 type | u32 length (big-endian) | payload
//   0 config: u16 width | u16 height | u16 spsLength | sps | pps
//   1 frame:  Annex B NAL units
// folio to Mac, 5 bytes each: u8 action (0 down, 1 move, 2 up) | u16 x | u16 y,
// x and y normalised to 0...65535 over the video.

import AppKit
import ScreenCaptureKit
import VideoToolbox

let port: UInt16 = 54400
let points = (w: 1000, h: 600)
let video = (w: 2000, h: 1200)
let fps = 60
let bitrate = 20_000_000
let adbPaths = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
let package = "local.sol.extend/.Main"
// adb connect targets, one per line in ~/.config/extend/hosts, tried in order; kept
// out of the repo. folio's adbd listens on 5555 from boot. An mDNS instance name
// (adb-<serial>._adb._tcp) follows its DHCP lease; a tailnet name covers other networks.
let wifiHosts = ((try? String(contentsOfFile: NSHomeDirectory() + "/.config/extend/hosts", encoding: .utf8)) ?? "")
    .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

// MARK: display

func makeDisplay() -> CGVirtualDisplay {
    let d = CGVirtualDisplayDescriptor()
    d.queue = .main
    d.name = "folio"
    d.maxPixelsWide = UInt32(points.w * 2)
    d.maxPixelsHigh = UInt32(points.h * 2)
    d.sizeInMillimeters = CGSize(width: 226, height: 136)
    // macOS keys the saved arrangement on these three; keep them fixed.
    d.vendorID = 0xF011
    d.productID = 0x0615
    d.serialNum = 1
    guard let display = CGVirtualDisplay(descriptor: d) else { fatalError("CGVirtualDisplay failed") }
    let s = CGVirtualDisplaySettings()
    s.hiDPI = 1
    s.modes = [CGVirtualDisplayMode(width: UInt(points.w), height: UInt(points.h), refreshRate: Double(fps))]
    guard display.apply(s) else { fatalError("applySettings failed") }
    return display
}

// MARK: capture + encode, one per connection

final class Session: NSObject, SCStreamOutput {
    let fd: Int32
    let displayID: CGDirectDisplayID
    var stream: SCStream?
    var encoder: VTCompressionSession?
    let queue = DispatchQueue(label: "capture")
    var lastConfig = Data()

    init(fd: Int32, displayID: CGDirectDisplayID) {
        self.fd = fd
        self.displayID = displayID
    }

    func start() async throws {
        var enc: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(video.w), height: Int32(video.h),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &enc)
        guard status == noErr, let enc else { throw NSError(domain: "VTCompressionSessionCreate", code: Int(status)) }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
        ]
        VTSessionSetProperties(enc, propertyDictionary: props as CFDictionary)
        encoder = enc

        // A new virtual display takes a moment to show up in shareable content.
        var scDisplay: SCDisplay?
        for _ in 0..<20 {
            scDisplay = try await SCShareableContent.current.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay else { throw NSError(domain: "display not shareable", code: 0) }

        let cfg = SCStreamConfiguration()
        cfg.width = video.w
        cfg.height = video.h
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 4
        let s = SCStream(filter: SCContentFilter(display: scDisplay, excludingWindows: []), configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        queue.sync {
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
        }
    }

    // ScreenCaptureKit sends idle frames when nothing changed; only complete ones carry an image.
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let encoder,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let image = sb.imageBuffer else { return }
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: sb.presentationTimeStamp,
                                        duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [self] status, _, out in
            guard status == noErr, let out else { return }
            send(out)
        }
    }

    func send(_ sb: CMSampleBuffer) {
        let notSync = ((CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        if !notSync, let fmt = sb.formatDescription {
            var sets = [Data]()
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var len = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &len, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let ptr { sets.append(Data(bytes: ptr, count: len)) }
            }
            if sets.count == 2 {
                var config = Data()
                config.append(be16(video.w)); config.append(be16(video.h)); config.append(be16(sets[0].count))
                config.append(sets[0]); config.append(sets[1])
                if config != lastConfig {
                    write(type: 0, config)
                    lastConfig = config
                }
            }
        }
        // AVCC 4-byte lengths become Annex B start codes.
        guard let block = sb.dataBuffer, var avcc = try? block.dataBytes() else { return }
        var i = 0
        while i + 4 <= avcc.count {
            let n = avcc[i..<i + 4].reduce(0) { $0 << 8 | Int($1) }
            avcc.replaceSubrange(i..<i + 4, with: [0, 0, 0, 1])
            i += 4 + n
        }
        write(type: 1, avcc)
    }

    func write(type: UInt8, _ payload: Data) {
        var msg = Data([type])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { msg.append(contentsOf: $0) }
        msg.append(payload)
        msg.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }
}

func be16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).bigEndian) { Data($0) } }

// MARK: touch

func inject(action: UInt8, x: UInt16, y: UInt16, displayID: CGDirectDisplayID) {
    let b = CGDisplayBounds(displayID)
    let p = CGPoint(x: b.minX + Double(x) / 65535 * (b.width - 1), y: b.minY + Double(y) / 65535 * (b.height - 1))
    let types: [CGEventType] = action == 0 ? [.mouseMoved, .leftMouseDown] : action == 1 ? [.leftMouseDragged] : [.leftMouseUp]
    for t in types {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

// MARK: server

// Nil when the port is taken, which means another Extend already runs.
func listenSocket() -> Int32? {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, listen(listener, 1) == 0 else { close(listener); return nil }
    return listener
}

func serve(listener: Int32, displayID: CGDirectDisplayID) {
    var one: Int32 = 1
    while true {
        let fd = accept(listener, nil, nil)
        if fd < 0 { continue }
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let session = Session(fd: fd, displayID: displayID)
        let started = DispatchSemaphore(value: 0)
        Task {
            do { try await session.start() } catch { NSLog("extend: start failed: \(error)") }
            started.signal()
        }
        started.wait()
        var msg = [UInt8](repeating: 0, count: 5)
        while true {
            var got = 0
            while got < 5 {
                let n = msg.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, 5 - got) }
                if n <= 0 { break }
                got += n
            }
            if got < 5 { break }
            inject(action: msg[0], x: UInt16(msg[1]) << 8 | UInt16(msg[2]), y: UInt16(msg[3]) << 8 | UInt16(msg[4]), displayID: displayID)
        }
        session.stop()
        close(fd)
    }
}

// MARK: adb

// adb's native IOUSBLib backend crashes releasing folio's USB interface
// (EXC_GUARD INVALID_NAME in ~IOUSBInterfaceClass) and takes the server with it.
// The libusb backend works, and the first caller to start the server decides.
let adbEnv = ProcessInfo.processInfo.environment.merging(["ADB_LIBUSB": "1"]) { _, new in new }

func adb(_ args: [String]) -> Bool {
    guard let path = adbPaths.first(where: FileManager.default.isExecutableFile) else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.environment = adbEnv
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func isWireless(_ serial: String) -> Bool { serial.contains(":") || serial.contains("._tcp") }

// Serials currently in the `device` state, written by trackDevices, read by keepWireless.
let devicesLock = NSLock()
var devices = [String]()

// `adb track-devices` prints the full list on every change and exits with the adb server.
// Only one transport carries the reverse: USB when plugged, Wi-Fi otherwise. Moving to USB
// drops the Wi-Fi reverse, which closes the stream there and the app reconnects over USB.
// A serial that newly gains the reverse is woken and gets the app launched.
func trackDevices() {
    guard let path = adbPaths.first(where: FileManager.default.isExecutableFile) else { return NSLog("extend: no adb") }
    var active: String?
    while true {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["track-devices"]
        p.environment = adbEnv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            while case let chunk = pipe.fileHandleForReading.availableData, !chunk.isEmpty {
                // Each message: 4 hex digits of length, then "serial\tstate\n" lines.
                let list = String(decoding: chunk.dropFirst(4), as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
                    let f = line.split(separator: "\t")
                    return f.count == 2 && f[1] == "device" ? String(f[0]) : nil
                }
                devicesLock.withLock { devices = list }
                let target = list.first { !isWireless($0) } ?? list.first
                if let old = active, old != target, list.contains(old) {
                    _ = adb(["-s", old, "reverse", "--remove", "tcp:\(port)"])
                }
                guard let target else { active = nil; continue }
                // A transport listed as `device` can refuse the reverse for a moment after it
                // connects, and no further message comes to retry on.
                var ok = false
                for _ in 0..<10 where !ok {
                    ok = adb(["-s", target, "reverse", "tcp:\(port)", "tcp:\(port)"])
                    if !ok { Thread.sleep(forTimeInterval: 1) }
                }
                // The app opens its socket only once it has a surface, so an asleep folio never connects.
                if ok && active != target {
                    _ = adb(["-s", target, "shell", "input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; am start -n \(package)"])
                }
                active = ok ? target : nil
            }
            p.waitUntilExit()
        }
        active = nil
        Thread.sleep(forTimeInterval: 2)
    }
}

// With no device attached, keeps asking adb to connect folio's always-on adbd over Wi-Fi.
func keepWireless() {
    while true {
        if devicesLock.withLock({ devices.isEmpty }) {
            for host in wifiHosts where adb(["connect", host]) { break }
        }
        Thread.sleep(forTimeInterval: 10)
    }
}

// MARK: main

signal(SIGPIPE, SIG_IGN)
guard let listener = listenSocket() else { exit(0) }
NSApplication.shared.setActivationPolicy(.prohibited)
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    NSLog("extend: no Accessibility permission, touch is ignored until granted")
}
if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

let display = makeDisplay()
let id = display.displayID
Thread.detachNewThread { serve(listener: listener, displayID: id) }
Thread.detachNewThread { trackDevices() }
Thread.detachNewThread { keepWireless() }
withExtendedLifetime(display) { NSApplication.shared.run() }
