#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$ROOT/dist/IP Toolkit.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=("$ROOT/Sources/IPAddress.swift" "$ROOT/Sources/RDAP.swift" "$ROOT/Sources/Subnet.swift" "$ROOT/Sources/Geo.swift" "$ROOT/Sources/NetTools.swift" "$ROOT/Sources/MyIP.swift" "$ROOT/Sources/LaunchAtLogin.swift" "$ROOT/Sources/IconDrawing.swift"
         "$ROOT/Sources/App.swift" "$ROOT/Sources/main.swift")

rm -rf "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon, drawn by the same code as the menu bar icon.
xcrun swiftc -O -swift-version 5 -sdk "$SDK" \
    "$ROOT/Sources/IconDrawing.swift" "$ROOT/Tools/IconGenerator/main.swift" -o "$BUILD/IconGenerator"
rm -rf "$BUILD/AppIcon.iconset"
"$BUILD/IconGenerator" "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

for ARCH in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macosx13.0" \
        "${SOURCES[@]}" -o "$BUILD/IPToolkit-$ARCH"
done
lipo -create "$BUILD/IPToolkit-arm64" "$BUILD/IPToolkit-x86_64" \
    -output "$APP/Contents/MacOS/IPToolkit"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/README.md" "$APP/Contents/Resources/README.md"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
rm -f "$ROOT/dist/IP-Toolkit-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/dist/IP-Toolkit-macOS.zip"
echo "Built: $APP"
