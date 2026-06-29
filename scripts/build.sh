#!/usr/bin/env bash
# Build and ad-hoc-sign the limiter dylib and the minimal test app.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"   # arm64 on Apple Silicon
mkdir -p build

clang -dynamiclib -arch "$ARCH" -O2 -Wall -Wextra \
    -o build/frame_limiter.dylib src/frame_limiter.m \
    -framework Foundation -framework QuartzCore -framework AppKit

# Mandatory on Apple Silicon: all loaded code must carry a valid signature.
codesign --force --sign - build/frame_limiter.dylib

clang -arch "$ARCH" -O2 -Wall -fobjc-arc \
    -o build/minimal_metal_app minimal_metal_app/main.m \
    -framework Cocoa -framework QuartzCore -framework Metal
codesign --force --sign - build/minimal_metal_app

APPDIR="build/FrameLimiter.app"
ARCH="${ARCH:-$(uname -m)}"

mkdir -p "$APPDIR/Contents/MacOS"

clang -arch "$ARCH" -O2 -Wall -fobjc-arc -o "$APPDIR/Contents/MacOS/FrameLimiter" src/FrameLimiterMenu.m -framework Cocoa

cat <<EOF > "$APPDIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FrameLimiter</string>
    <key>CFBundleIdentifier</key>
    <string>com.framelimiter.menu</string>
    <key>CFBundleName</key>
    <string>FrameLimiter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APPDIR"

echo "built:"
echo "  build/frame_limiter.dylib"
echo "  build/minimal_metal_app"
echo "  $APPDIR"
