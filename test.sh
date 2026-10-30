#!/bin/bash
# Usage: bash test.sh [--live]   (--live also queries the real RDAP registries)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build"
xcrun swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "$ROOT/Sources/IPAddress.swift" "$ROOT/Sources/RDAP.swift" "$ROOT/Sources/Subnet.swift" "$ROOT/Sources/Geo.swift" "$ROOT/Sources/NetTools.swift" "$ROOT/Sources/MyIP.swift" "$ROOT/Tests/main.swift" \
    "$ROOT/Sources/Reputation.swift" "$ROOT/Sources/SpeedTest.swift" -o "$ROOT/build/Tests"
"$ROOT/build/Tests" "$@"

APP_SOURCES=()
for SOURCE in "$ROOT"/Sources/*.swift; do
    if [ "$SOURCE" != "$ROOT/Sources/main.swift" ]; then APP_SOURCES+=("$SOURCE"); fi
done
xcrun swiftc -swift-version 5 -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    "${APP_SOURCES[@]}" "$ROOT/Tests/App/main.swift" -o "$ROOT/build/AppTests"
"$ROOT/build/AppTests"

APP="$ROOT/dist/IP Toolkit.app"
if [ -d "$APP" ]; then
    codesign --verify --deep --strict "$APP"
    for TARGET in arm64 x86_64; do lipo -verify_arch "$TARGET" "$APP/Contents/MacOS/IPToolkit"; done
    test -f "$APP/Contents/Resources/AppIcon.icns"
    echo "PASS: app bundle is signed, universal, and has its icon"
fi
