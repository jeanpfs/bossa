#!/usr/bin/env bash
# Builds demo.gif from raw.mkv, a screen recording of the Bossa panel (640x630) made by record.sh.
# Adds a caption strip under the panel and speeds the take up 1.5x. Run in a directory holding raw.mkv.
# Needs ffmpeg, gifsicle and ImageMagick.
set -euo pipefail

FONT="${FONT:-/System/Library/Fonts/SFNS.ttf}"
pill() {  # pill <out.png> <text>
  magick -size 640x70 xc:'#150f2a' -font "$FONT" -pointsize 19 -gravity center \
    -fill '#cdd6f4' -annotate +0+0 "$2" "$1"
}
pill cap1.png "Mac output volume, right from the menu bar"
pill cap2.png "Switch modes: Quiet, Aware, Immersion, Cinema"
pill cap0.png "Bossa: Bose QC Ultra Headphones in the menu bar"

ffmpeg -v error -y -i raw.mkv -loop 1 -i cap0.png -loop 1 -i cap1.png -loop 1 -i cap2.png -filter_complex "
[0:v]fps=30,pad=640:700:0:0:color=#150f2a[v];
[v][1:v]overlay=0:630:enable='lt(t,4.0)':shortest=1[v0];
[v0][2:v]overlay=0:630:enable='between(t,4.0,12.0)':shortest=1[v1];
[v1][3:v]overlay=0:630:enable='gte(t,12.0)':shortest=1[v2];
[v2]split=2[a][b];
[a]trim=1.4:34.4,setpts=(PTS-STARTPTS)/1.5[s1];
[b]trim=34.3:34.4,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=2.5[s2];
[s1][s2]concat=n=2:v=1:a=0,fps=12,split[x][y];
[x]palettegen=max_colors=256:stats_mode=full[p];[y][p]paletteuse=dither=bayer:bayer_scale=3[out]" \
  -map "[out]" demo-raw.gif
gifsicle -O3 --lossy=25 demo-raw.gif -o demo.gif
echo "wrote $PWD/demo.gif"
