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
    <key>CFBundleShortVersionString</key>  <string>1.0.0</string>
    <key>CFBundleVersion</key>             <string>1</string>
    <key>LSMinimumSystemVersion</key>      <string>15.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
echo "Install with: cp -R $APP /Applications/"
