#!/usr/bin/env bash
# Wrapper launch command for Steam, used only if setting DYLD_INSERT_LIBRARIES
# directly in the launch options does not propagate to the game process.
#
# In Steam → game → Properties → Launch Options, set:
#   /absolute/path/to/scripts/steam-launch.sh %command%
#
# Override the target / dylib via the environment if you like:
#   FRAME_LIMIT_FPS=60 /abs/scripts/steam-launch.sh %command%
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"

export DYLD_INSERT_LIBRARIES="${DYLD_INSERT_LIBRARIES:-$DIR/build/frame_limiter.dylib}"
: "${FRAME_LIMIT_FPS:=80}"
export FRAME_LIMIT_FPS

exec "$@"
