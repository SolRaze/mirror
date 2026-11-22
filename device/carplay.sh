#!/bin/zsh
# CarPlay Simulator for deuce, one entry point (`carplay` alias, CarPlay.app).
# Starts Extend when it is not running and brings folio's Extend app forward over
# USB, else Wi-Fi, so folio becomes display `folio`. The session is tiled on
# workspace `side` on folio with the controls in sketchybar's row, and moved back
# whenever it leaves folio. The simulator builds a new session window on every
# preset change or reconnect, so the bar is re-applied per window.
# Quitting the simulator ends this script and the volume tap, and quits Extend
# when this script started it.
# Root lldb attach needs SIP off. Already running: brings the simulator forward.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
export USER=${USER:-$(id -un)}   # CarPlay.app's shell has none; sketchybar's socket is named after it
export ADB_LIBUSB=1   # see extend/extend.md: the IOUSBLib backend crashes adb
dir=${0:A:h}
folio=$(<~/.config/extend/serial)   # USB serial, kept out of the repo
# Anchored to how CarPlay.app runs it: a loose match also hits editors and shells naming the file.
if pgrep -f '^/bin/zsh [^ ]*/carplay[.]sh$' | grep -vqx $$; then
  open -a "CarPlay Simulator"
  exit
fi
extended() { aerospace list-monitors | grep -qx '[0-9]* | folio' }
# USB first, then the Wi-Fi transport Extend connects when folio is unplugged.
fadb() { adb -s $folio "$@" 2>/dev/null || adb -e "$@" }

started=
if ! pgrep -x extend >/dev/null; then
  open -a Extend; started=1
  # Desk released by the steam pill: keep the built-in panel main, not folio.
  ~/.config/sketchybar/plugins/steam.sh builtin-main >/dev/null 2>&1
fi
# Brought forward every time: the Mac app holds the display open whether or not
# folio is showing it.
fadb shell input keyevent KEYCODE_WAKEUP
fadb shell am start -n local.sol.extend/.Main >/dev/null 2>&1
for i in {1..30}; do extended && break; sleep 1; done

pgrep -x "CarPlay Simulator" >/dev/null || open -a "CarPlay Simulator"
for i in {1..20}; do pgrep -x "CarPlay Simulator" >/dev/null && break; sleep 1; done
pgrep -f 'carplay-volume[.]swift' >/dev/null || { nohup swift $dir/carplay-volume.swift >/dev/null 2>&1 &! }

# Prints "left right centre" for display 3 (the side display): points kept clear
# at the left and right screen edges by sketchybar pills (+8pt gap), and the pill
# centre height above the screen bottom.
# ponytail: measured per window, pills that widen later (front_app) can overlap.
pills() {
  python3 -c '
import json, subprocess
q = lambda *a: json.loads(subprocess.run(["sketchybar", "--query", *a], capture_output=True, text=True).stdout)
d = next(x["frame"] for x in q("displays") if x["arrangement-id"] == 3)
rs = [(g["geometry"]["position"], r) for i in q("bar")["items"] for g in [q(i)]
      for k, r in g.get("bounding_rects", {}).items() if k == "display-3" and r["origin"][0] > -9999]
ls = [r["origin"][0] + r["size"][0] for p, r in rs if p == "left"]
rt = [r["origin"][0] for p, r in rs if p == "right"]
mid = [r["origin"][1] + r["size"][1] / 2 for p, r in rs]
print(int(max(ls) - d["x"]) + 8 if ls else 0, int(d["x"] + d["w"] - min(rt)) + 8 if rt else 0,
      int(d["y"] + d["h"] - sum(mid) / len(mid)) if mid else 16)' 2>/dev/null || echo 0 0 16
}

# Reads a raw `screencap` (16-byte header, RGBA) on stdin. Prints the panel pixel
# centre of Automaker UI's CarPlay icon, the only saturated green on that screen
# and a square about 100 px wide; prints nothing when it is not showing.
automaker() {
  python3 -c '
import sys, struct
b = sys.stdin.buffer.read()
if len(b) < 16: sys.exit()
w, h = struct.unpack("<II", b[:8])
px = b[len(b) - w * h * 4:]
xs, ys = [], []
for y in range(0, h, 4):
    row = y * w * 4
    for x in range(0, w, 4):
        i = row + x * 4
        r, g, bl = px[i], px[i + 1], px[i + 2]
        if g > 80 and g - r > 40 and g - bl > 40: xs.append(x); ys.append(y)
if len(xs) < 150: sys.exit()
bw, bh = max(xs) - min(xs), max(ys) - min(ys)
if 60 < bw < 220 and 60 < bh < 220 and 0.7 < bw / bh < 1.4:
    print(sum(xs) // len(xs), sum(ys) // len(ys))'
}

# done = window id the bar is built for. A window without the session toolbar
# (launcher) returns 0 and is retried after 20s, not every pass. No folio display
# (Extend quit, tablet off): the window waits where it is until folio returns.
done= tried=0
while pgrep -x "CarPlay Simulator" >/dev/null; do
  id=$(aerospace list-windows --all | awk -F' *[|] *' '$2 == "CarPlay Simulator" {print $1; exit}')
  if [[ -n $id ]] && extended; then
    mon=$(aerospace list-windows --all --format '%{window-id}|%{monitor-name}' |
      awk -F'|' -v id=$id '$1 == id {print $2}')
    if [[ $mon != folio ]]; then
      aerospace move-node-to-workspace --window-id $id side
      aerospace layout --window-id $id tiling
    fi
    # The bar waits: the simulator is still building the session window, and a
    # folio display seconds old has no sketchybar row to measure yet.
    if [[ $id != $done && $SECONDS -ge $tried ]]; then
      sleep 2
      # A folio display seconds old has no sketchybar row yet and measures 0 on the
      # right, and its pills draw one at a time; wait for a non-zero right offset
      # that holds across two reads 1s apart, up to 30s. A row still empty at 5s or 15s missed its
      # display_change retag (pills parked off-screen); fire it again.
      p=-1
      for i in {1..30}; do
        read l r c <<< $(pills); (( r > 0 && r == p )) && break; p=$r
        (( (i == 5 || i == 15) && r == 0 )) && sketchybar --trigger display_change
        sleep 1
      done
      print "$(date +%T) bar pills l=$l r=$r c=$c after ${i}s" >> /tmp/carplay.log
      if sudo -n xcrun lldb --batch -p $(pgrep -x "CarPlay Simulator") \
          -o "expr -l objc -- double \$carplayBarSide = 1" -o "expr -l objc -- double \$carplayBarLeft = $l" \
          -o "expr -l objc -- double \$carplayBarRight = $r" -o "expr -l objc -- double \$carplayBarMid = $c" \
          -s $dir/carplay-bar.lldb 2>/dev/null | grep -q '(int) \$[0-9]* = 1'; then
        done=$id
        # The session comes back from the attach on Automaker UI, the simulator's
        # stand-in for the car's own screen; press its CarPlay icon from the tablet.
        for i in {1..20}; do
          xy=$(fadb exec-out screencap | automaker)
          [[ -n $xy ]] && { fadb shell input tap ${=xy}; print "$(date +%T) automaker tap $xy" >> /tmp/carplay.log; break; }
          sleep 1
        done
      else
        tried=$((SECONDS + 20))
      fi
    fi
  fi
  sleep 1
done
pkill -f 'carplay-volume[.]swift'
[[ -n $started ]] && { pkill -x extend; fadb shell am force-stop local.sol.extend; }
