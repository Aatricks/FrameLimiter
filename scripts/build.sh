#!/usr/bin/env bash
# Build and ad-hoc-sign the limiter dylib and the minimal test app.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"   # arm64 on Apple Silicon
mkdir -p build

clang -dynamiclib -arch "$ARCH" -O2 -Wall -Wextra \
    -o build/frame_limiter.dylib src/frame_limiter.m \
    -framework Foundation -framework QuartzCore

# Mandatory on Apple Silicon: all loaded code must carry a valid signature.
codesign --force --sign - build/frame_limiter.dylib

clang -arch "$ARCH" -O2 -Wall -fobjc-arc \
    -o build/minimal_metal_app minimal_metal_app/main.m \
    -framework Cocoa -framework QuartzCore -framework Metal
codesign --force --sign - build/minimal_metal_app

echo "built:"
echo "  build/frame_limiter.dylib"
echo "  build/minimal_metal_app"
