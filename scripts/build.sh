#!/bin/bash
# Builds build/ClaudePet.app: a menu bar app without a Dock icon, whose binary is also the CLI.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/ClaudePet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos26" \
  -framework AppKit -framework SwiftUI \
  $(find Sources -name "*.swift") -o "$APP/Contents/MacOS/claude-pet"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.sueun-dev.claude-pet</string>
  <key>CFBundleName</key><string>Claude Pet</string>
  <key>CFBundleExecutable</key><string>claude-pet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Hardened runtime: no DYLD_* injection into the binary that may answer permission prompts.
codesign --force --options runtime --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
