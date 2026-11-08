#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build=".build/portable-host"
app="$build/BetterCast Portable Host.app"
sender="Sources/BetterCastSender"
mkdir -p "$app/Contents/MacOS"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
target="$(uname -m)-apple-macosx13.0"
xcrun clang -isysroot "$sdk" -target "$target" -fobjc-arc -c "$sender/VirtualDisplay/VirtualDisplay.m" -o "$build/VirtualDisplay.o"
cat > "$build/module.modulemap" <<MODULE
module VirtualDisplayLib {
    header "$PWD/$sender/VirtualDisplay/VirtualDisplay.h"
    export *
}
MODULE
xcrun swiftc -sdk "$sdk" -target "$target" -O -I "$build" \
    "$sender"/{Constants,VirtualDisplayManager,ScreenFit,ScreenRecorder,LegacyDisplayCapture,AudioEncoder,VideoEncoder,LogManager}.swift \
    Sources/BetterCastPortableHost/PortableHost.swift "$build/VirtualDisplay.o" \
    -o "$app/Contents/MacOS/BetterCastPortableHost"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.bettercast.portable.host</string>
<key>CFBundleName</key><string>BetterCast Portable Host</string>
<key>CFBundleExecutable</key><string>BetterCastPortableHost</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSLocalNetworkUsageDescription</key><string>Connect a paired Windows display on the local network.</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
