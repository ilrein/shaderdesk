#!/usr/bin/env bash
# Renders Art/Icon.metal with the app's own renderer and builds Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swift build -c release >/dev/null
.build/release/Shaderdesk --snapshot "$TMP/art.png" --scene-file Art/Icon.metal --size 824x824 --scale 2 --time 1 --no-data >/dev/null
swiftc -O scripts/make-icon.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/art.png" Art/AppIcon.png
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Art/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Art/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "wrote Art/AppIcon.png and Resources/AppIcon.icns"
