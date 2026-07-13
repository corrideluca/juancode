#!/usr/bin/env bash
set -euo pipefail

NATIVE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${JUANCODE_CONFIG:-debug}"
swift build --package-path "$NATIVE" --product CorriAssistant -c "$CONFIG"

BIN="$NATIVE/.build/$CONFIG/CorriAssistant"
APP="$NATIVE/.build/CorriAssistant.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN" "$APP/Contents/MacOS/CorriAssistant"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Corri Assistant</string>
  <key>CFBundleDisplayName</key><string>Corri Assistant</string>
  <key>CFBundleIdentifier</key><string>dev.corri.assistant</string>
  <key>CFBundleExecutable</key><string>CorriAssistant</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Corri Assistant shows your upcoming events alongside your work.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

exec "$APP/Contents/MacOS/CorriAssistant" "$@"
