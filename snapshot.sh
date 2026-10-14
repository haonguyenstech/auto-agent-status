#!/bin/bash
# Renders README screenshots of every panel tab (light + dark) with made-up data.
#   ./snapshot.sh [out dir]   (default: docs/snapshots)
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
[ -f build/Token.swift ] || printf 'let updateTokenB64 = ""\n' > build/Token.swift
# inside a bundle, so the panel shows the real version from Info.plist
APP=build/Snapshot.app
mkdir -p "$APP/Contents/MacOS" && cp Info.plist "$APP/Contents/Info.plist"
# own bundle id: never read the real app's settings (team key, Figma token) into a screenshot
/usr/libexec/PlistBuddy -c "Set CFBundleIdentifier vn.saigontechnology.autoagent-status.snapshot" "$APP/Contents/Info.plist"
swiftc -D SNAPSHOT Sources/main.swift build/Token.swift Snapshots/Snapshot.swift -o "$APP/Contents/MacOS/AutoAgentStatus" \
  -framework AppKit -framework SwiftUI -framework Combine -framework UserNotifications -framework ServiceManagement
OUT="${1:-docs/snapshots}"; mkdir -p "$OUT"
"$APP/Contents/MacOS/AutoAgentStatus" "$(cd "$OUT" && pwd)"
