extend

folio as real extended Mac display over USB or Wi-Fi | no third-party code | Apple frameworks + Android platform APIs only

what it is
- `mac/extend.swift`/ `CGVirtualDisplay` named `folio` | 1000x600 pt HiDPI = 2000x1200 px = panel 1:1 | 5:3 = panel ratio | 2 panel px per pt, ~0.23 mm per pt, near the Mac screens | display size change = new CarPlay preset size + re-place the display | VideoToolbox H.264 low-latency RC, 20 Mbps, 60 fps | TCP 127.0.0.1:54400 | `CGEvent` mouse from touches
- `mac/CGVirtualDisplay.h`/ private CoreGraphics class declarations | macOS update can break them
- `android/`/ `local.sol.extend` | `MediaCodec` AVC decode to `SurfaceView` | `KEY_LOW_LATENCY` | fills 2000x1200 panel, aspect-fit if size changes | touch down/move/up back to Mac
- `build.sh`/ builds `/Applications/Extend.app` + `build/extend.apk` | installs APK over USB, else Wi-Fi
- wire format/ top of `extend.swift` | `Main.java` must change with it

run
- `ex` pill or `open -a Extend` | quit `pkill -x extend` | display exists only while process runs | second launch exits on busy port
- `adb track-devices` event-driven | reverse `tcp:54400` on one transport, USB when plugged else Wi-Fi | switching removes the old reverse, app reconnects on the new one | transport newly reversed gets `am start -n local.sol.extend/.Main`
- Wi-Fi/ no device listed = `adb connect` every 10 s, hosts from `~/.config/extend/hosts` in order, mDNS `adb-<serial>._adb._tcp` then tailnet `folio.<tailnet>.ts.net:5555`, not in the repo | `~/.config/extend/serial` USB serial for `carplay.sh` | `~/.config/extend` links to gitignored `device/local/`, carried by the `~/Projects` backup | folio adbd on 5555 from boot | same 20 Mbps stream, rides adb over TCP | Mac socket stays on 127.0.0.1
- capture + encode only while folio app in foreground | app backgrounded = socket closed = zero Mac cost
- ScreenCaptureKit sends frames on change only | still screen sends nothing

hooked in
- aerospace/ monitor pattern `folio` | `side` workspace | same outer gaps as every screen, tile 984x552
- sketchybar/ `extend.sh` pill `ex` in overflow popup after steam | bright = running | click starts Extend + folio app, or quits Extend + `am force-stop local.sol.extend`
- sketchybar/ `main_display.sh` on `display_change` | folio never holds main | main to the external screen if connected, else built-in panel | folio alone keeps it
- sketchybar/ `steam.sh` makes the built-in panel main before releasing the external screen while Extend runs
- sketchybar/ `side_display.sh` `br` BetterDisplay brightness `-namelike=folio` | `folio.sh` `ch`/`ba` rightmost on display 3, right click opens Extend + folio app | those two are the whole display 3 bar: the workspace pill, the monitor arrows and `front_app` are tagged `display=1,2` or off, because the left of that screen is CarPlay's dock
- `../carplay.sh`/ starts Extend when not running, quits it on exit only if it started it | brings the folio app forward | CarPlay always tiled on `folio` | `carplay-bar.lldb` finds screen `folio`
- SideScreen/ uninstalled from Mac + folio | numbers below measured before removal

toolchain
- JDK/ `brew --prefix openjdk`
- Android SDK/ `~/Library/Android/sdk` | `platforms;android-36` | `build-tools;36.0.0` | via `sdkmanager` from `android-commandlinetools` cask
- APK signed with `~/.android/debug.keystore`
- Mac app signed with Apple Development identity | Screen Recording + Accessibility grants survive rebuilds | ad-hoc signing loses them every build

measured, cursor circling at 60 Hz, same load | Extend at 2000x1200 encode, SideScreen at 1280x800
| app | CPU | memory |
|---|---|---|
| Extend | 3.9–4.4% | 11 MB |
| SideScreen 60 Hz medium | 16.4–17.4% | 49 MB |
| Extend idle | 0.0% | 11 MB |

gotchas
- adb backend/ native IOUSBLib backend crashes releasing folio's interface (`EXC_GUARD INVALID_NAME` in `~IOUSBInterfaceClass`) and the server dies with it, so every pill that shells out to adb fails | `ADB_LIBUSB=1` is the working path, set in `~/.zshenv`, `plugins/folio.sh`, `plugins/extend.sh`, `plugins/colorfilter.sh` and `extend.swift` | whichever caller starts the server decides for all of them
- usb claim/ `Could not open interface: e00002c5` = another process holds the interface, a WebUSB page in a browser does it | quit that app, `ioreg -r -c IOUSBHostDevice -l | grep -B4 <serial>` names the holder as `IOUserClientCreator`
- permissions/ Screen Recording toggle only lists Extend after first request | first launch writes a denied row, switch on in System Settings, relaunch
- arrangement/ macOS saves position per vendor `0xF011` product `0x0615` serial 1 | x -1000 y 900, left of the external screen | a mode change resets it to y 0 and display 3 becomes the panel: `betterdisplaycli set -namelike=folio -placement=-1000x900` | changing vendor, product or serial loses it
- touch/ one finger only | drag = left-button drag | no scroll, no right click
- dropped input buffer after 100 ms wait corrupts picture until next keyframe | not seen yet
- latency not measured
