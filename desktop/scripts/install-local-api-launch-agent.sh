#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="com.omi.local-api"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SCRIPT_PATH="$PWD/scripts/run-local-api.sh"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SCRIPT_PATH}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${PWD}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/omi-local-api.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/omi-local-api.err</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST"
launchctl bootout "gui/$UID" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/${LABEL}"
launchctl kickstart -k "gui/$UID/${LABEL}"

echo "Installed ${LABEL}"
for _ in {1..20}; do
  if curl -fsS http://127.0.0.1:10201/health >/dev/null; then
    echo "Health: http://127.0.0.1:10201/health"
    exit 0
  fi
  sleep 0.5
done

echo "ERROR: ${LABEL} did not become ready. See /tmp/omi-local-api.err" >&2
exit 1
