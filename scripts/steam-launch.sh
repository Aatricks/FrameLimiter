#!/bin/bash
# macOS Steam launch wrapper.
#
# macOS Steam does NOT shell-parse launch options (no /bin/sh), so the Linux-style
# "VAR=value %command%" form fails with "failed to start process … os error 260".
# Use this wrapper instead. In Steam → game → Properties → Launch Options:
#
#   "/Users/aatricks/Documents/Dev/FrameLimiter/scripts/steam-launch.sh" %command%
#
# Override the target / dylib via the environment if you like:
#   FRAME_LIMIT_FPS=60 "/abs/scripts/steam-launch.sh" %command%

DIR="$(cd "$(dirname "$0")/.." && pwd)"

export DYLD_INSERT_LIBRARIES="${DYLD_INSERT_LIBRARIES:-$DIR/build/frame_limiter.dylib}"
: "${FRAME_LIMIT_FPS:=80}";                  export FRAME_LIMIT_FPS
: "${FRAME_LIMIT_FILE:=$HOME/.framelimiter.fps}"; export FRAME_LIMIT_FILE
: "${MTL_HUD_ENABLED:=1}";                   export MTL_HUD_ENABLED

# Live retuning while the game runs:   echo 30 > ~/.framelimiter.fps

# The limiter also logs via os_log; watch it live with:
#   log stream --style compact --predicate 'eventMessage CONTAINS "framelimiter"'
exec "$@"
