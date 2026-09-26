scrcpy fork

upstream scrcpy v4.1 | one macOS feature on top | branch `folio`

mirror frame
`scrcpy --mirror-frame` | macOS only
window framed as iPhone Mirroring | rounded panel | 8 pt sides and bottom | 38 pt top strip
hover chrome in the strip | traffic lights | Home Screen and App Switcher pills with tooltips
menus Edit | View | Device | Help | items send scrcpy shortcuts with the configured `--shortcut-mod`
View sizes Larger | Actual Size | Smaller | window 890 | 696 | 471 pt tall | any device
fixed size | no fullscreen | no resize edges | tiling window managers keep it at its own size

devices
panel height snaps to multiples of `h / gcd(w, h)` | device pixels scale to whole points
1200x2000 tablet 845 pt | 1080x2400 phone 840 pt | 1920x1080 landscape 846 pt
refit on every content change | rotation | `--crop` | resolution change
panel corners scale with the long side | 48 pt at 844
capped by the screen's visible frame

files
- app/src/sys/macos/mirror_frame.m chrome | menus | geometry hooks
- app/src/screen.c init before window creation | content size to the frame | fullscreen guard
- app/src/cli.c `--mirror-frame` | rejects `-f` and `--window-borderless`

build
`meson setup build --buildtype=release -Dcompile_server=false -Dprebuilt_server=<scrcpy-server v4.1>` | `ninja -C build`
server must match v4.1 | Homebrew's `share/scrcpy/scrcpy-server` does

gotchas
hooks SDL3's `SDL3Window` and `SDL3Cocoa_WindowListener` by name | missing classes log a warning, window left plain
run from an app bundle | a bare CLI process gets no menu bar
