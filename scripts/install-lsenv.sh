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
    # Keep a pristine backup once; start each install from it so Info.plist is clean
    if [ -f "$BACKUP" ]; then cp -p "$BACKUP" "$PLIST"; else cp -p "$PLIST" "$BACKUP"; fi
    
    # Remove any old LSEnvironment entry
    "$PB" -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null || true

    EXE_NAME=$("$PB" -c "Print :CFBundleExecutable" "$PLIST")
    EXE_PATH="$APP/Contents/MacOS/$EXE_NAME"
    REAL_PATH="${EXE_PATH}.real"

    # Swap original executable with real path if not already swapped
    if [ ! -f "$REAL_PATH" ]; then
      mv "$EXE_PATH" "$REAL_PATH"
    fi

    # Compile the wrapper C binary
    clang -O2 -Wall -arch "$(uname -m)" \
      -DDYLIB_PATH="\"$DYLIB\"" \
      -DDEFAULT_FPS="\"$FPS\"" \
      -o "$EXE_PATH" "$DIR/src/wrapper.c"

    # Replicate entitlements to the wrapper binary
    ENT="/tmp/${EXE_NAME}.entitlements"
    codesign -d --entitlements - --xml "$REAL_PATH" > "$ENT" 2>/dev/null || true
    if [ -f "$ENT" ] && [ -s "$ENT" ]; then
      codesign --force --sign - --entitlements "$ENT" "$EXE_PATH"
    else
      codesign --force --sign - "$EXE_PATH"
    fi
    rm -f "$ENT"

    resign
    "$LSREG" -f "$APP" 2>/dev/null || true

    if codesign --verify --ignore-resources "$APP" 2>/dev/null; then
      echo "signature OK (wrapper + Info.plist sealed)"
    else
      echo "WARNING: main signature failed to verify"; exit 1
    fi
    echo "installed: wrapper binary compiled (target ${FPS} fps). Launch normally from Steam."
    ;;
  uninstall)
    EXE_NAME=$("$PB" -c "Print :CFBundleExecutable" "$PLIST")
    EXE_PATH="$APP/Contents/MacOS/$EXE_NAME"
    REAL_PATH="${EXE_PATH}.real"

    if [ -f "$REAL_PATH" ]; then
      rm -f "$EXE_PATH"
      mv "$REAL_PATH" "$EXE_PATH"
      echo "restored original executable"
    fi
    if [ -f "$BACKUP" ]; then
      cp -p "$BACKUP" "$PLIST"; rm -f "$BACKUP"
      echo "restored original Info.plist"
    fi
    resign
    "$LSREG" -f "$APP" 2>/dev/null || true
    ;;
  status)
    EXE_NAME=$("$PB" -c "Print :CFBundleExecutable" "$PLIST")
    EXE_PATH="$APP/Contents/MacOS/$EXE_NAME"
    REAL_PATH="${EXE_PATH}.real"
    if [ -f "$REAL_PATH" ]; then
      echo "(wrapper binary present)"
    else
      echo "not installed"
    fi
    codesign -dv "$APP" 2>&1 | grep -E 'Signature|flags' || true
    ;;
  *) echo "unknown mode: $MODE"; exit 2;;
esac
