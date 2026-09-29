#!/usr/bin/env bash
# Builds Shaderdesk.app into ./build.   --install  also copies it to /Applications and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
APP="build/Shaderdesk.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Scenes"
cp .build/release/Shaderdesk "$APP/Contents/MacOS/Shaderdesk"
cp Scenes/*.metal "$APP/Contents/Resources/Scenes/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate with scripts/make-icon.sh

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Shaderdesk</string>
  <key>CFBundleDisplayName</key><string>Shaderdesk</string>
  <key>CFBundleIdentifier</key><string>com.ilrein.shaderdesk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Shaderdesk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Shaderdesk 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/Shaderdesk.app
  cp -R "$APP" /Applications/Shaderdesk.app
  open /Applications/Shaderdesk.app
  echo "installed and launched /Applications/Shaderdesk.app"
fi
