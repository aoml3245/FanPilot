#!/usr/bin/env bash
set -euo pipefail

HELPER_ID="local.codex.FanPilotHelper"
ROOT_SCRIPT="/tmp/fanpilot-uninstall-helper.sh"

cat > "$ROOT_SCRIPT" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail
launchctl bootout system /Library/LaunchDaemons/${HELPER_ID}.plist >/dev/null 2>&1 || true
rm -f "/Library/LaunchDaemons/${HELPER_ID}.plist"
rm -f "/Library/PrivilegedHelperTools/${HELPER_ID}"
rm -f "/tmp/fanpilot-helper.sock"
SCRIPT
chmod +x "$ROOT_SCRIPT"

osascript -e "do shell script quoted form of \"$ROOT_SCRIPT\" with administrator privileges"
echo "Uninstalled ${HELPER_ID}"
