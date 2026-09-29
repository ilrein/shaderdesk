#!/bin/bash
# Renders the website previews: a seamless looping 1080p clip and a poster frame per
# scene, straight from the real Metal renderer.
#
#   scripts/render-previews.sh              # every scene
#   scripts/render-previews.sh raincity     # just one
#
# Each clip is LOOP seconds long. It's rendered LOOP+FADE seconds from START, and the
# last FADE seconds crossfade into the first ones so the loop has no seam. Frames are
# rendered at 2x (3840x2160) and downsampled, for clean edges.
set -euo pipefail
cd "$(dirname "$0")/.."

LOOP=${LOOP:-12}
FADE=${FADE:-2}
FPS=${FPS:-30}
START=${START:-40}
W=1920 H=1080 S=2
OUT=docs/previews
mkdir -p "$OUT"

swift build -c release >/dev/null
BIN=.build/release/Shaderdesk

scenes=("$@")
if [ ${#scenes[@]} -eq 0 ]; then
  for f in Scenes/*.metal; do
    id=$(basename "$f" .metal | tr '[:upper:]' '[:lower:]')
    [ "$id" = common ] && continue
    scenes+=("$id")
  done
fi

for id in "${scenes[@]}"; do
  echo "» $id"
  frames=$(( (LOOP + FADE) * FPS ))
  "$BIN" --snapshot /dev/null --scene "$id" --size ${W}x${H} --scale $S --time "$START" --no-data \
         --frames "$frames" --fps "$FPS" |
  ffmpeg -loglevel error -y -f rawvideo -pix_fmt bgra -s $((W * S))x$((H * S)) -r "$FPS" -i - \
    -filter_complex "[0]scale=${W}:${H}:flags=lanczos,split[a][b];
                     [a]trim=start=${FADE}:end=$((LOOP + FADE)),setpts=PTS-STARTPTS[main];
                     [b]trim=start=0:end=${FADE},setpts=PTS-STARTPTS[head];
                     [main][head]xfade=transition=fade:duration=${FADE}:offset=$((LOOP - FADE)),format=yuv420p[v]" \
    -map "[v]" -c:v libx264 -preset slow -crf 22 -tune film -movflags +faststart -an "$OUT/$id.mp4"
  ffmpeg -loglevel error -y -i "$OUT/$id.mp4" -frames:v 1 -q:v 3 "$OUT/$id.jpg"
  ls -lh "$OUT/$id.mp4" | awk '{print "  " $5}'
done
