#!/bin/bash
# Inject frame_limiter without changing the game's executable identity.
#
# This is the macOS install method: it adds an LSEnvironment dictionary to the app's
# Info.plist (so LaunchServices sets DYLD_INSERT_LIBRARIES when the game launches) and
# ad-hoc re-signs the bundle. The original executable still launches AS ITSELF, so macOS
# Game Mode and the fullscreen direct-to-display path (which lets the game exceed the
# 60 Hz compositor) keep working — unlike replacing the executable with a wrapper.
#
# Reversible and idempotent:
#   scripts/install-lsenv.sh install   "/path/Game.app" [FPS]
#   scripts/install-lsenv.sh uninstall "/path/Game.app"
#   scripts/install-lsenv.sh status    "/path/Game.app"
#
# Re-run 'install' after a game update (updates restore the original Info.plist/signature).
set -euo pipefail

MODE="${1:-}"; APP="${2:-}"; FPS="${3:-80}"
[ -n "$MODE" ] && [ -n "$APP" ] || { echo "usage: $0 install|uninstall|status \"/path/Game.app\" [fps]"; exit 2; }
[ -d "$APP" ] || { echo "no such app bundle: $APP"; exit 1; }

DIR="$(cd "$(dirname "$0")/.." && pwd)"
DYLIB="$DIR/build/frame_limiter.dylib"
PLIST="$APP/Contents/Info.plist"
# Backup lives OUTSIDE the bundle — any stray file inside Contents/ breaks the code seal.
STATE="$HOME/.framelimiter/backups"
BACKUP="$STATE/$(basename "$APP").Info.plist.bak"
PB=/usr/libexec/PlistBuddy
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

resign() {
  # Preserve the game's entitlements (disable-library-validation, get-task-allow) and
  # re-seal the (modified) Info.plist. No --deep: nested dylibs keep their signatures.
  codesign --force --sign - --preserve-metadata=entitlements,flags "$APP"
}

case "$MODE" in
  install)
    [ -f "$DYLIB" ] || { echo "dylib missing — run 'make build' first: $DYLIB"; exit 1; }
    mkdir -p "$STATE"
    # Keep a pristine backup once; start each install from it so LSEnvironment is clean.
    if [ -f "$BACKUP" ]; then cp -p "$BACKUP" "$PLIST"; else cp -p "$PLIST" "$BACKUP"; fi
    "$PB" -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null || true
    "$PB" -c "Add :LSEnvironment dict" "$PLIST"
    "$PB" -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $DYLIB" "$PLIST"
    "$PB" -c "Add :LSEnvironment:FRAME_LIMIT_FPS string $FPS" "$PLIST"
    "$PB" -c "Add :LSEnvironment:FRAME_LIMIT_FILE string $HOME/.framelimiter.fps" "$PLIST"
    "$PB" -c "Add :LSEnvironment:MTL_HUD_ENABLED string 1" "$PLIST"
    resign
    "$LSREG" -f "$APP" 2>/dev/null || true
    # Verify the main executable + Info.plist seal (what AMFI gates launch on). We ignore
    # nested resource seals: some games (e.g. Hades II's Backtrace.framework) ship with
    # loose nested signatures that fail a recursive verify but launch fine.
    if codesign --verify --ignore-resources "$APP" 2>/dev/null; then
      echo "signature OK (main executable + Info.plist sealed)"
    else
      echo "WARNING: main signature failed to verify"; exit 1
    fi
    echo "installed: LSEnvironment injected (target ${FPS} fps). Clear Steam launch options; launch normally."
    ;;
  uninstall)
    if [ -f "$BACKUP" ]; then
      cp -p "$BACKUP" "$PLIST"; rm -f "$BACKUP"; resign; "$LSREG" -f "$APP" 2>/dev/null || true
      echo "restored original Info.plist and signature"
    else
      "$PB" -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null && { resign; "$LSREG" -f "$APP" 2>/dev/null || true; echo "removed LSEnvironment"; } || echo "not installed"
    fi
    ;;
  status)
    if "$PB" -c "Print :LSEnvironment" "$PLIST" 2>/dev/null; then echo "(LSEnvironment present)"; else echo "not installed"; fi
    codesign -dv "$APP" 2>&1 | grep -E 'Signature|flags' || true
    ;;
  *) echo "unknown mode: $MODE"; exit 2;;
esac
