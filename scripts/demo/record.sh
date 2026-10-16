#!/bin/bash
# Records the Bossa menu-bar panel (see assets/demo.gif): open it, change the Mac volume, switch modes.
#
# Setup: Bose QC Ultra headphones connected and selected as the Mac's sound output, Bossa running. Build the helpers:
#   swiftc -O mouse.swift -o mouse   and   swiftc -O backdrop.swift -o backdrop
# Start `./backdrop 2400 0 800 940 &` first (a gradient window behind the panel so no other app shows through the glass).
# The coordinates below are for one specific monitor layout (points, relative to the main display): adjust the menu-bar
# icon position (shown by System Events: position of the Bossa menu bar item) and the panel offsets for your setup,
# and the ffmpeg screen index (ffmpeg -f avfoundation -list_devices true -i "").
# Usage: record.sh <work-dir>   -> <work-dir>/raw.mkv, then run make-gif.sh in that directory.
set -u
D="${1:?usage: record.sh <work-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
M="${MOUSE:-$HERE/mouse}"
mkdir -p "$D"
rm -f "$D/raw.mkv"
VOL0=$(osascript -e 'output volume of (get volume settings)')
echo "volume_before=$VOL0"
"$M" move 1300 -1000
ffmpeg -v error -y -f avfoundation -framerate 30 -capture_cursor 1 -pixel_format nv12 -i "${SCREEN:-3}:none" \
  -vf "crop=640:630:2490:30,format=yuv420p" -c:v libx264 -preset ultrafast -crf 16 "$D/raw.mkv" </dev/null &
FF=$!
sleep 2.5
"$M" move 1912 -1426; sleep 0.6; "$M" click 1912 -1426       # open the panel from the menu bar
sleep 3
"$M" move 1960 -1103; sleep 0.8; "$M" drag 1974 -1103 1850 -1103 40   # volume down
sleep 1.8
"$M" drag 1850 -1103 1930 -1103 25                                   # a bit up
sleep 1.4
"$M" move 1834 -1035; sleep 0.8; "$M" click 1834 -1035                 # Modes
sleep 2
"$M" move 1819 -1112; sleep 0.7; "$M" click 1819 -1112                 # Aware
sleep 2
"$M" move 1819 -1044; sleep 0.7; "$M" click 1819 -1044                 # Immersion
sleep 2
"$M" move 1759 -1375; sleep 0.6; "$M" click 1759 -1375                 # back: the label now says Immersion
sleep 3
"$M" move 1834 -1035; sleep 0.6; "$M" click 1834 -1035                 # Modes again
sleep 1.6
"$M" move 1819 -1180; sleep 0.7; "$M" click 1819 -1180                 # back to Quiet
sleep 1.6
"$M" move 1759 -1375; sleep 0.6; "$M" click 1759 -1375
sleep 3
kill -INT $FF; wait $FF
osascript -e "set volume output volume $VOL0"
echo "volume_after=$(osascript -e 'output volume of (get volume settings)')"
du -h "$D/raw.mkv"
