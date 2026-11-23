folio carplay — tablet as carplay head unit for deuce

goal
folio (SM-P615, LineageOS 23.2, Magisk root) as carplay receiver | deuce iPhone as source | software only

verdict
- folio alone/ no | iPhone demands signed auth from head unit | root on receiver does not move iPhone-side trust
- gate/ MFi auth coprocessor signs challenge with key in silicon | not extractable | not emulable
- second trust path/ BAA | Apple internal CA | iPhone accepts BAA proof in place of MFi signature
- BAA issuers/ Apple devices only | CarPlay Simulator on Mac | jailbroken iPad iOS 12+ | never Android
- protocol side/ open | iAP2 | AirPlay screen stream | xcertplay already runs it on Android USB host
- result/ software-only possible if signing offloads to Mac | folio receives, Mac signs

routes
| route | receiver | signer | hardware | in car | state |
|---|---|---|---|---|---|
| A mirror | CarPlay Simulator on Mac | Mac BAA | none | no | works today |
| B relay | xcertplay fork on folio | Mac helper over tailnet | none | yes, folio LTE | research |
| C chip | xcertplay on folio | MFi chip via CH341 | chip + bridge | yes | known working |

route A — mirror
- install/ Additional Tools for Xcode | CarPlay Simulator | `/Applications/CarPlay Simulator.app`
- deuce USB to Mac | Simulator window = head unit
- stream window to folio/ Screen Sharing | Sunshine + Moonlight | touch back over tailnet
- use/ proves deuce side | dev testing | not in car

route A kiosk
- run/ `carplay` alias | `/Applications/CarPlay.app` (Spotlight, app library) | both run `carplay.sh` | second run brings simulator forward | quit simulator to stop
- `CarPlay.app`/ osacompile applet | icon from CarPlay Simulator `AppIcon.icns` as `applet.icns` | bundle id `local.sol.carplay` | `LSUIElement` | `NSAudioCaptureUsageDescription` set, without it the tap is denied with no prompt | ad-hoc signed
- rebuild/ `osacompile -o /Applications/CarPlay.app -e 'do shell script "nohup $HOME/Projects/Devices/folio/carplay.sh >/dev/null 2>&1 &"'` | copy icon | `plutil -replace` the three keys | `codesign -f -s -`
- folio start/ running folio mirror stopped first, it holds the tablet portrait | rotation locked landscape | Extend not running = `open -a Extend` + `steam.sh builtin-main` | wake folio, `am start -n local.sol.extend/.Main` over USB else Wi-Fi | wait 30s for the `folio` monitor | Extend quit on simulator exit only when this run started it | Extend in `extend/`
- placement/ folio only | tiled on workspace `side` | bar in sketchybar row | re-placed whenever the window is off `folio` | no `folio` display = window waits until it returns
- bar timing/ bar applied 2s after the window appears | one lldb attach per session window | folio display gone then back (Extend restart, unplug) = bar rebuilt, its panels die with the display | launcher window without session toolbar retried after 20s
- gaps/ folio uses the same aerospace outer gaps as every screen, 8 sides + top, 40 bottom | tile 984x552pt | sketchybar row clear below the stream
- preset/ `~/Library/CarPlaySimulator/UserConfigs/folio.yaml`, copy in `carplay-preset.yaml` | 1968x1104 px = tile 984x552 at 2 px/pt = panel pixels 1:1 | UI size set on the iPhone: CarPlay Display "Smart Display Zoom" | iPhone sizes UI from pixel count only, no scale key | fewer pixels = bigger but soft | keep tile aspect 1.783 | gaps or display size change = resize preset | `vehicleConfig: removeWidgets: true`, opens on app grid | `vehicleConfig: rightHandDrive: true` moves the dock right
- preset dead ends/ `displayScales` = cluster gauges, not UI | `physicalDimensions` scales map only | `safeArea` insets controls, no size change
- car name/ iPhone shows `CarPlay Simulator`, hardcoded in the simulator binary | `vehicleConfig` `model` `manufacturer` do not set it | binary patch + ad-hoc re-sign = iPhone never connects | left as is
- dock/ CarPlay dock at the left edge | display 3 sketchybar pills `brightness3` `folio` right-edge only
- pill offset/ side mode measures display 3 sketchybar pills per window | left edge, right edge +8pt | pill centre height | `$carplayBarLeft` `$carplayBarRight` `$carplayBarMid` via `-o` | no left pills on display 3 = left 0, and play/pause sits at the screen centre either way
- pill wait/ new folio display has no sketchybar row for seconds, pills draw one at a time | carplay.sh retries `pills` up to 30s until right > 0 and equal across two reads 1s apart | still 0 at 5s or 15s = `sketchybar --trigger display_change`, row missed its retag (retag lands ~7s later) | measured values logged to `/tmp/carplay.log`
- env/ CarPlay.app runs the script with no `USER` | sketchybar names its socket after `USER`, without it every query is empty and the bar spans the pills | carplay.sh exports it
- single run/ guard matches `^/bin/zsh [^ ]*/carplay[.]sh$` only | a loose match also hits editors and shells naming the file
- `carplay-bar.lldb`/ play | pause | volume slider | hides toolbar + close/minimise/zoom buttons | hides every `contentView` subview except the one holding the largest `VideoStreamView`, so the simulator's own overlay buttons go whatever SwiftUI wraps them in that build | needs `$carplayBarSide` + three offset vars
- side bar/ 32pt panel between left and right pills | centred on pill centre
- float bar/ `$carplayBarSide = 0` only, carplay.sh never sets it | black 44pt child `NSPanel`, frame = stream rect in screen points, 44 below its bottom edge | `addChildWindow:` so it follows the window | `NSPanGestureRecognizer` moves the parent window | starts only on stack background or `carplay-drag` spacer
- window/ minimise removed from style mask | fullscreen disabled (`FullScreenNone`) | clear background, no shadow
- top inset/ hosting view `additionalSafeAreaInsets` top = minus titlebar height (32pt) | stream starts at window top
- window height/ forced from width (`WindowResizability.contentSize`) | hidden overlay strip below stream, clear, hangs off the screen bottom
- hidden overlay/ `hitTest:` swapped on hosting view class | taps over hidden spots return nil | original kept once as `carplayBarOrigHitTest:`
- play + pause/ class methods on `CarplayBarTarget` | `keyDown:` + `keyUp:` sent straight to largest `VideoStreamView` | button tag = keyCode | no mouse events, no focus
- simulator keyboard map/ `'` play | `;` pause | `/` play-pause | `.` next | `,` prev | `\` navigation guidance | from `VideoStreamView.handleKeyEvent` jump table
- `carplay-volume.swift`/ headless tap | started by `carplay.sh` | killed when simulator quits
- volume/ Core Audio process tap on `com.apple.CarPlaySimulator` | mutedWhenTapped | private aggregate on default output | gain (slider/100)^2 | Mac volume untouched
- volume state/ slider writes UserDefaults suite `carplay-volume` key `level` + posts distributed notification `carplay-volume`, object = level string | 2s timer re-attaches on new pid or output
- volume gotcha/ System Audio Recording goes to the launching app | `local.sol.carplay` granted | started from a terminal it needs that terminal's grant | no permission = silent CarPlay | kill `carplay-volume` restores direct audio
- dashboard/ layout comes from the iPhone | map card has no head-unit switch | preset `vehicleConfig` keys: `removeWidgets` `removeLiveActivities` `rightHandDrive` `manufacturer` `model` | both remove flags absent = widgets + live activities allowed
- picker gotcha/ toolbar device picker (`SessionExternalMainWindowTitleView`) stays in hidden toolbar | moved out, it traps on display change and kills simulator
- no device/ simulator draws one window per connected iPhone, none without one | Sessions menu `No Devices Connected` | USB only, deuce paired over network gives nothing | no wireless mode
- bar attach/ lldb attach takes ~30s+ | session lands on `Automaker UI` after it | carplay.sh then polls `screencap` up to 20s for the green CarPlay icon (saturated green blob 60-220 px square) and taps its centre | logged to `/tmp/carplay.log`
- lldb gotcha/ reinstalling live `hitTest:` exits simulator | `layoutSubtreeIfNeeded` on the hosting view from lldb exits it too | `NSHostingView` never lays out a foreign Auto Layout subview, its frame stays `{{0, 0}, {0, 0}}`, which is why both bars are panels | Xcode update resets license, breaks `xcrun lldb` | AeroSpace can crash when simulator quits, `open -a AeroSpace`

route B — signing relay
1. reverse CarPlay Simulator auth call | entitlement + private framework issuing BAA leaf | follow aminerostane writeup
2. Mac helper `carplay-signer` | tailnet only | input challenge | output signature + cert chain
3. run helper with Simulator's restricted entitlement | SIP already off | likely needs `amfi_get_out_of_my_way=1` boot-arg | NVRAM, confirm first
4. fork xcertplay | swap I2C MFi transport for network call to signer | rest of stack unchanged
5. wired first/ folio USB-C OTG host | deuce as device | iAP2 + NCM
6. wireless after/ Bluetooth iAP2 + Wi-Fi P2P 5 GHz | Android 9 limit not relevant on Android 16
7. auth once per session | latency not critical | Mac must answer at connect only

route B risks
- BAA leaf may bind to Mac identity or CarPlay Simulator role | iPhone may reject in real head-unit mode
- iOS update can close BAA acceptance | no fix from our side
- Mac must be reachable at connect | tailnet over folio LTE | dead Mac = no carplay
- Apple ToS | personal use only | nothing here publishes a signer

route C — fallback
- MFi 2.0C/3.0 chip from any carplay dongle | CH341 USB-I2C bridge | xcertplay supports both
- breaks "no external hardware" | only route not tied to Mac or iOS version

order
A first, proves deuce + Simulator | B step 1 decides feasibility | B steps 2–7 only if step 1 finds callable BAA issuance | C if B dead

refs
xcertplay https://github.com/shilapi/xcertplay | LIVI https://github.com/f-io/LIVI | BAA ipad writeup https://aminerostane.com/articles/showcase/
