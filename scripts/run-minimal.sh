#!/usr/bin/env bash
# Run the minimal test app, optionally with the limiter injected.
#   scripts/run-minimal.sh            # uncapped (no injection)
#   scripts/run-minimal.sh 80         # cap to 80
#   FRAME_LIMIT_LOG=1 scripts/run-minimal.sh 30
set -euo pipefail
cd "$(dirname "$0")/.."

FPS="${1:-${FRAME_LIMIT_FPS:-}}"
DYLIB="$PWD/build/frame_limiter.dylib"

if [ -n "$FPS" ]; then
    exec env \
        DYLD_INSERT_LIBRARIES="$DYLIB" \
        FRAME_LIMIT_FPS="$FPS" \
        FRAME_LIMIT_LOG="${FRAME_LIMIT_LOG:-1}" \
        ./build/minimal_metal_app
else
    exec ./build/minimal_metal_app
fi
