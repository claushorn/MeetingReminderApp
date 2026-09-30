#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

APP="$ROOT/Meeting Alarm.app"
INSTALL_DIR="$HOME/Applications"
TARGET="$INSTALL_DIR/Meeting Alarm.app"

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS/com.local.meetingalarm.plist"

"$ROOT/build.sh"

mkdir -p "$INSTALL_DIR"
mkdir -p "$LAUNCH_AGENTS"

rm -rf "$TARGET"

cp -R "$APP" "$TARGET"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">

<plist version="1.0">
<dict>

    <key>Label</key>
    <string>com.local.meetingalarm</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$TARGET</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

</dict>
</plist>
EOF

USER_ID="$(id -u)"

launchctl bootout \
    "gui/$USER_ID" \
    "$PLIST" \
    2>/dev/null || true

launchctl bootstrap \
    "gui/$USER_ID" \
    "$PLIST"

echo
echo "===================================="
echo "Meeting Alarm installed."
echo "===================================="
echo
echo "Application:"
echo "  $TARGET"
echo
echo "It has been configured to start automatically at login."
echo
echo "macOS should now ask for Calendar access."
echo
echo "If it does not, go to:"
echo
echo "System Settings"
echo "  → Privacy & Security"
echo "    → Calendars"
echo
echo "and enable Meeting Alarm."
echo
