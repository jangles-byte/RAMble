#!/bin/zsh
# Bundles the release build into RAMble.app so macOS treats it as a real app
# (menu-bar-only agent, start-at-login support, proper name in Activity Monitor).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/RAMble.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RAMble "$APP/Contents/MacOS/RAMble"
# SwiftPM resource bundle (logo artwork) — Bundle.module finds it in Resources.
cp -R .build/release/RAMble_RAMbleKit.bundle "$APP/Contents/Resources/"

# Generate the ram-head app icon from the in-code vector drawing.
ICONSET=build/RAMble.iconset
rm -rf "$ICONSET"
.build/release/RAMble --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/RAMble.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>RAMble</string>
    <key>CFBundleIdentifier</key>          <string>com.ramble.overlay</string>
    <key>CFBundleName</key>                <string>RAMble</string>
    <key>CFBundleDisplayName</key>         <string>RAMble</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleIconFile</key>            <string>RAMble</string>
    <key>CFBundleShortVersionString</key>  <string>1.3.0</string>
    <key>CFBundleVersion</key>             <string>4</string>
    <key>LSMinimumSystemVersion</key>      <string>15.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"
echo "Install with: cp -R $APP /Applications/"
