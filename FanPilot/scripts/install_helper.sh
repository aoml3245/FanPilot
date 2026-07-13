#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="/tmp/fanpilot-helper-install"
HELPER_ID="local.codex.FanPilotHelper"
HELPER_SRC="${ROOT}/.build/release/FanPilotHelper"
ROOT_SCRIPT="${STAGE}/install-root.sh"
PLIST="${STAGE}/${HELPER_ID}.plist"

cd "$ROOT"
swift build -c release --product FanPilotHelper

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$HELPER_SRC" "${STAGE}/FanPilotHelper"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${HELPER_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Library/PrivilegedHelperTools/${HELPER_ID}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/fanpilot-helper.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/fanpilot-helper.err.log</string>
</dict>
</plist>
PLIST

cat > "$ROOT_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
launchctl bootout system /Library/LaunchDaemons/${HELPER_ID}.plist >/dev/null 2>&1 || true
install -o root -g wheel -m 755 "${STAGE}/FanPilotHelper" "/Library/PrivilegedHelperTools/${HELPER_ID}"
install -o root -g wheel -m 644 "${PLIST}" "/Library/LaunchDaemons/${HELPER_ID}.plist"
launchctl bootstrap system "/Library/LaunchDaemons/${HELPER_ID}.plist"
launchctl kickstart -k "system/${HELPER_ID}"
SCRIPT
chmod +x "$ROOT_SCRIPT"

osascript -e "do shell script quoted form of \"$ROOT_SCRIPT\" with administrator privileges"
echo "Installed ${HELPER_ID}"
