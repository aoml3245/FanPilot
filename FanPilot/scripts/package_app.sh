#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ROOT="${ROOT}/../outputs"
APP="${OUT_ROOT}/FanPilot.app"
MACOS="${APP}/Contents/MacOS"

cd "$ROOT"
swift build -c release

rm -rf "$APP"
mkdir -p "$MACOS"
cp ".build/release/FanPilot" "$MACOS/FanPilot"

cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>FanPilot</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex.FanPilot</string>
  <key>CFBundleName</key>
  <string>FanPilot</string>
  <key>CFBundleDisplayName</key>
  <string>FanPilot</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "$APP"
