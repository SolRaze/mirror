// CarPlay-only volume for the simulator, headless. The slider lives in the bar
// carplay-bar.lldb builds inside the simulator; it stores the level in the
// `carplay-volume` defaults suite and posts it as a distributed notification
// named `carplay-volume` (object = level 0-100 as a string).
//
// Volume is a Core Audio process tap (macOS 14.2+): the simulator's own output
// is muted and replayed through a private aggregate device on the default
// output, scaled by the slider. Mac system volume is untouched. Tap and
// aggregate are private to this process, so killing it restores the
// simulator's direct audio. Needs System Audio Recording permission for the
// app that launched it; without it the tap delivers silence.
// Run: swift carplay-volume.swift
import AppKit
import CoreAudio

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T,
             qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, qualifierSize, qualifier, &size, &value) == noErr ? value : nil
}

// Read on the IO thread; a torn Float read is not possible on arm64.
nonisolated(unsafe) var gain: Float = 1

final class Tap {
    let pid: pid_t, output: AudioDeviceID
    var tap = AudioObjectID(kAudioObjectUnknown), agg = AudioObjectID(kAudioObjectUnknown)
    var proc: AudioDeviceIOProcID?

    init?(pid: pid_t, output: AudioDeviceID) {
        self.pid = pid; self.output = output
        var p = pid
        guard let process = prop(AudioObjectID(kAudioObjectSystemObject),
                                 kAudioHardwarePropertyTranslatePIDToProcessObject, AudioObjectID(kAudioObjectUnknown),
                                 qualifier: &p, qualifierSize: UInt32(MemoryLayout<pid_t>.size)),
              process != kAudioObjectUnknown,
              let uidRef = prop(output, kAudioDevicePropertyDeviceUID, Unmanaged<CFString>?.none) ?? nil
        else { return nil }
        let uid = uidRef.takeRetainedValue() as String
        let desc = CATapDescription(stereoMixdownOfProcesses: [process])
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return nil }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "carplay-volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &agg) == noErr,
              AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil, { _, inData, _, outData, _ in
                  let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
                  let outs = UnsafeMutableAudioBufferListPointer(outData)
                  guard ins.count > 0 else { return }
                  let g = gain
                  // Float32 both sides; channels map by index, wrapping when the
                  // output has more than the stereo tap.
                  for (k, o) in outs.enumerated() {
                      let s = ins[min(k, ins.count - 1)]
                      guard let od = o.mData?.assumingMemoryBound(to: Float32.self),
                            let sd = s.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                      let oc = Int(max(o.mNumberChannels, 1)), sc = Int(max(s.mNumberChannels, 1))
                      let frames = min(Int(o.mDataByteSize) / 4 / oc, Int(s.mDataByteSize) / 4 / sc)
                      for f in 0..<frames { for c in 0..<oc { od[f * oc + c] = sd[f * sc + c % sc] * g } }
                  }
              }) == noErr,
              AudioDeviceStart(agg, proc) == noErr else { stop(); return nil }
    }

    func stop() {
        if let proc { AudioDeviceStop(agg, proc); AudioDeviceDestroyIOProcID(agg, proc) }
        if agg != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agg) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
    }
}

let defaults = UserDefaults(suiteName: "carplay-volume")!
func setLevel(_ v: Int) {
    let x = Float(v) / 100
    gain = x * x
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

setLevel(defaults.object(forKey: "level") as? Int ?? 100)
DistributedNotificationCenter.default().addObserver(forName: .init("carplay-volume"), object: nil, queue: .main) { n in
    if let v = (n.object as? String).flatMap(Int.init) { setLevel(v) }
}

// The simulator registers with Core Audio only once it plays something, and a
// relaunch or output switch invalidates the tap, so re-check every 2s.
var tap: Tap?
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    let pid = NSWorkspace.shared.runningApplications
        .first { $0.bundleIdentifier == "com.apple.CarPlaySimulator" }?.processIdentifier
    let output = prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                      AudioDeviceID(kAudioObjectUnknown))
    if let t = tap, t.pid == pid, t.output == output { return }
    tap?.stop(); tap = nil
    if let pid, let output { tap = Tap(pid: pid, output: output) }
}.fire()
app.run()
