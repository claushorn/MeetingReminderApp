#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

APP="$ROOT/Meeting Alarm.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

rm -rf "$APP"

mkdir -p "$MACOS"

echo "Compiling Meeting Alarm..."

xcrun swiftc \
    "$ROOT/MeetingAlarm.swift" \
    -o "$MACOS/MeetingAlarm" \
    -framework AppKit \
    -framework EventKit \
    -framework SwiftUI \
    -O

cp "$ROOT/Info.plist" \
   "$CONTENTS/Info.plist"

echo "Signing..."

codesign \
    --force \
    --deep \
    --sign - \
    "$APP"

echo
echo "Build successful:"
echo "$APP"
