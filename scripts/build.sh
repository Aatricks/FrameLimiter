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

# Bundle the install machinery so the app is self-contained (works from /Applications).
# install-lsenv.sh resolves wrapper.c + the dylib relative to itself, and flctl sits
# alongside it — mirroring the repo's scripts/ layout, so no code change is needed.
mkdir -p "$APPDIR/Contents/Resources"
cp scripts/install-lsenv.sh  "$APPDIR/Contents/Resources/install-lsenv.sh"
cp scripts/flctl             "$APPDIR/Contents/Resources/flctl"
cp src/wrapper.c             "$APPDIR/Contents/Resources/wrapper.c"
cp build/frame_limiter.dylib "$APPDIR/Contents/Resources/frame_limiter.dylib"
chmod +x "$APPDIR/Contents/Resources/install-lsenv.sh" "$APPDIR/Contents/Resources/flctl"

codesign --force --sign - "$APPDIR"

echo "built:"
echo "  build/frame_limiter.dylib"
echo "  build/minimal_metal_app"
echo "  $APPDIR"
