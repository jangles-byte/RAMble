#!/bin/zsh
# Bundles the release build into RAMble.app so macOS treats it as a real app
# (menu-bar-only agent, start-at-login support, proper name in Activity Monitor).
set -euo pipefail
cd "$(dirname "$0")/.."

# Build both slices so Intel Macs can run it too. (`swift build --arch`
# needs full Xcode; cross-compiling each slice works with Command Line Tools.)
swift build -c release
X86_OK=1
swift build -c release --scratch-path .build-x86 \
  -Xswiftc -target -Xswiftc x86_64-apple-macos15.0 \
  -Xcc -target -Xcc x86_64-apple-macos15.0 || X86_OK=0

APP=build/RAMble.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "$X86_OK" == "1" && -f .build-x86/release/RAMble ]]; then
  lipo -create .build/release/RAMble .build-x86/release/RAMble \
       -output "$APP/Contents/MacOS/RAMble"
else
  echo "warning: x86_64 slice unavailable — shipping Apple Silicon only"
  cp .build/release/RAMble "$APP/Contents/MacOS/RAMble"
fi
# SwiftPM resource bundle (logo artwork) — Bundle.module finds it in Resources.
cp -R .build/release/RAMble_RAMbleKit.bundle "$APP/Contents/Resources/"

# Generate the ram-head app icon from the in-code vector drawing.
ICONSET=build/RAMble.iconset
rm -rf "$ICONSET"
"$APP/Contents/MacOS/RAMble" --render-icon "$ICONSET"
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
    <key>CFBundleShortVersionString</key>  <string>1.6.0</string>
    <key>CFBundleVersion</key>             <string>7</string>
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
