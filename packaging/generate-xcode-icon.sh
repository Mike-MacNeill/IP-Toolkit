#!/bin/bash
set -euo pipefail

: "${SRCROOT:?Run this script through the Xcode project}"
: "${DERIVED_FILE_DIR:?Run this script through the Xcode project}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$DERIVED_FILE_DIR"

xcrun swiftc -O -swift-version 5 -sdk "$SDK" \
    "$SRCROOT/Sources/IconDrawing.swift" "$SRCROOT/Tools/IconGenerator/main.swift" \
    -o "$DERIVED_FILE_DIR/IconGenerator"
"$DERIVED_FILE_DIR/IconGenerator" "$DERIVED_FILE_DIR/AppIcon.iconset"
iconutil -c icns "$DERIVED_FILE_DIR/AppIcon.iconset" -o "$DERIVED_FILE_DIR/AppIcon.icns"
