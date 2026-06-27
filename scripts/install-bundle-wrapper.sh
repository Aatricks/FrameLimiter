#!/bin/bash
# Inject frame_limiter by wrapping a game's bundle executable.
#
# macOS Steam can't pass environment variables through launch options (it treats the
# first token of %command% as the program path — "failed to start process … os error
# 260"). The reliable method is to replace the bundle's main executable with a small
# wrapper that sets DYLD_INSERT_LIBRARIES and execs the real binary. Steam then launches
# the game normally, with NO launch options.
#
# Reversible and idempotent:
#   scripts/install-bundle-wrapper.sh install   "/path/Game.app" [FPS]
#   scripts/install-bundle-wrapper.sh uninstall "/path/Game.app"
#   scripts/install-bundle-wrapper.sh status    "/path/Game.app"
#
# A game update re-downloads the original executable and silently removes the wrapper;
# just re-run 'install' afterwards.
set -euo pipefail

MODE="${1:-}"; APP="${2:-}"; FPS="${3:-80}"
[ -n "$MODE" ] && [ -n "$APP" ] || { echo "usage: $0 install|uninstall|status \"/path/Game.app\" [fps]"; exit 2; }
[ -d "$APP" ] || { echo "no such app bundle: $APP"; exit 1; }

DIR="$(cd "$(dirname "$0")/.." && pwd)"
DYLIB="$DIR/build/frame_limiter.dylib"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
MACOS="$APP/Contents/MacOS"
WRAP="$MACOS/$EXE"
REAL="$MACOS/$EXE.framelimiter-orig"

case "$MODE" in
  install)
    echo "WARNING: this method replaces the executable and breaks macOS Game Mode and the"
    echo "         >60 fullscreen path. Use scripts/install-lsenv.sh instead. Continuing in 3s..."
    sleep 3
    [ -f "$DYLIB" ] || { echo "dylib missing — run 'make build' first: $DYLIB"; exit 1; }
    if [ -f "$REAL" ]; then echo "already wrapped (real binary at: $REAL)"; exit 0; fi
    file "$WRAP" | grep -q 'Mach-O' || { echo "refusing: '$WRAP' is not a Mach-O executable"; exit 1; }
    mv "$WRAP" "$REAL"
    {
      printf '%s\n' '#!/bin/bash'
      printf '%s\n' '# frame_limiter wrapper — restore with: install-bundle-wrapper.sh uninstall'
      printf '%s\n' 'D="${0%/*}"'
      printf 'export DYLD_INSERT_LIBRARIES=%q\n' "$DYLIB"
      printf '%s\n' 'export FRAME_LIMIT_FPS="${FRAME_LIMIT_FPS:-'"$FPS"'}"'
      printf '%s\n' 'export FRAME_LIMIT_FILE="${FRAME_LIMIT_FILE:-$HOME/.framelimiter.fps}"'
      printf '%s\n' 'export MTL_HUD_ENABLED="${MTL_HUD_ENABLED:-1}"'
      printf 'exec "$D/%s" "$@"\n' "$EXE.framelimiter-orig"
    } > "$WRAP"
    chmod +x "$WRAP"
    echo "installed: $WRAP  (target ${FPS} fps; original at $REAL)"
    echo "Clear this game's Steam launch options and launch normally."
    ;;
  uninstall)
    if [ -f "$REAL" ]; then mv -f "$REAL" "$WRAP"; echo "restored original: $WRAP"; else echo "not wrapped"; fi
    ;;
  status)
    if [ -f "$REAL" ]; then echo "WRAPPED  (original: $REAL)"; else echo "not wrapped"; fi
    ;;
  *) echo "unknown mode: $MODE"; exit 2;;
esac
