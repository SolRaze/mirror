mirror

scrcpy fork | upstream v4.1 | one macOS feature on top | branches `folio` tablet | `pane` headset | same build

mirror frame
`scrcpy --mirror-frame` | macOS only
window framed as iPhone Mirroring | rounded panel | 8 pt sides and bottom | 38 pt top strip
hover chrome in the strip | traffic lights | Home Screen and App Switcher pills with tooltips
menus Edit | View | Device | Help | items send scrcpy shortcuts with the configured `--shortcut-mod`
View sizes Larger | Actual Size | Smaller | window 890 | 696 | 471 pt tall | any device
fixed size | no fullscreen | no resize edges | tiling window managers keep it at its own size

device menu
state read over adb each time the menu opens | checkmarks follow changes made on the device
- Device Screen/ panel off or on, mirroring on | starts from `--turn-screen-off` | a touch on the device relights it unseen
- Show Touches | Brightness Low 20 | Mid 96 | High 255, manual mode
- Rotation Lock/ Natural | Quarter Turn | Auto-Rotate | `wm user-rotation`
- Take Screenshot ⌘S/ device framebuffer | `~/Downloads/<window title> <date>.png`
- Send File… ⌘O/ `.apk` installs | anything else to `/sdcard/Download`
- Force Stop/ names the front app's package
- Connected over USB | Wi-Fi/ from the serial | Battery level | power | held limit
- Charge Limit/ Off | 60–90% | LineageOS charging control only | hidden elsewhere
- Wi-Fi | Bluetooth | Airplane Mode/ toggles | Wi-Fi and Airplane greyed on a wireless link
- Restart/ Reboot | Reboot to Recovery | Shut Down | each confirms
adb items use `$ADB` or adb on PATH | `-s` the connected serial

devices
panel height snaps to multiples of `h / gcd(w, h)` | device pixels scale to whole points
1200x2000 tablet 845 pt | 1080x2400 phone 840 pt | 1920x1080 landscape 846 pt
refit on every content change | rotation | `--crop` | resolution change
panel corners scale with the long side | 48 pt at 844
capped by the screen's visible frame

files
- app/src/sys/macos/mirror_frame.m chrome | menus | geometry hooks
- app/src/screen.c init before window creation | serial and `--turn-screen-off` to the frame | content size | fullscreen guard
- app/src/cli.c `--mirror-frame` | rejects `-f` and `--window-borderless`

docs
- SCRCPY.md upstream readme | every stock option
- doc/ upstream docs | build | connection | control | virtual display
- FAQ.md upstream faq

build
`meson setup build --buildtype=release -Dcompile_server=false -Dprebuilt_server=<scrcpy-server v4.1>` | `ninja -C build`
server must match v4.1 | Homebrew's `share/scrcpy/scrcpy-server` does

upstream
`git remote add upstream https://github.com/Genymobile/scrcpy` | rebase `folio` then `pane` on the next release tag

gotchas
hooks SDL3's `SDL3Window` and `SDL3Cocoa_WindowListener` by name | missing classes log a warning, window left plain
run from an app bundle | a bare CLI process gets no menu bar
