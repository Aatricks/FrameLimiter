#!/bin/bash
# install-lsenv.sh — inject frame_limiter into a .app by swapping its executable for a
# tiny C wrapper that sets DYLD_INSERT_LIBRARIES + the FRAME_LIMIT_* vars and then
# execv's the real binary (renamed to <exe>.real). The wrapper is re-signed with the
# app's own entitlements and the bundle is re-sealed, so macOS Game Mode and the
# fullscreen direct-to-display path keep working — unlike a plain executable swap that
# changes the signing identity.
#
# The injected dylib is published to a stable path (~/.framelimiter/frame_limiter.dylib)
# and that path is baked into the wrapper, so moving, rebuilding, or deleting this repo
# does not silently orphan an already-installed game.
#
#   scripts/install-lsenv.sh install   "/path/Game.app" [FPS]   # install / refresh (safe to re-run)
#   scripts/install-lsenv.sh uninstall "/path/Game.app"         # revert this bundle to original
#   scripts/install-lsenv.sh status    "/path/Game.app"         # show install state
#   scripts/install-lsenv.sh cli                                # symlink flctl into ~/.local/bin
#   scripts/install-lsenv.sh clean                              # remove the shared dylib + control files
#
# Re-run 'install' after a game update. It detects (via a marker string) whether the
# on-disk binary is our wrapper or a fresh game binary and never clobbers the real one;
# if anything fails mid-install, a trap restores a launchable executable.
#
# Run install/uninstall with the game closed.
set -euo pipefail

MODE="${1:-}"

# Resolve the wrapper source, dylib, and flctl for BOTH layouts: the repo (this script in
# scripts/, sources in ../src and ../build) and a self-contained app bundle (this script
# copied into Contents/Resources/ alongside the same files). flctl sits next to this
# script in both layouts.
SELF="$(cd "$(dirname "$0")" && pwd)"
FLCTL="$SELF/flctl"
if [ -f "$SELF/../src/wrapper.c" ]; then
  WRAPPER_SRC="$SELF/../src/wrapper.c"; DYLIB="$SELF/../build/frame_limiter.dylib"
elif [ -f "$SELF/wrapper.c" ]; then
  WRAPPER_SRC="$SELF/wrapper.c";        DYLIB="$SELF/frame_limiter.dylib"
else
  WRAPPER_SRC="$SELF/../src/wrapper.c"; DYLIB="$SELF/../build/frame_limiter.dylib"
fi
STABLE_HOME="$HOME/.framelimiter"
STABLE_DYLIB="$STABLE_HOME/frame_limiter.dylib"
STATE="$STABLE_HOME/backups"
CTRL="$HOME/.framelimiter.fps"
PB=/usr/libexec/PlistBuddy
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
MARKER="FRAMELIMITER_WRAPPER_v1"

# Detect ANY FrameLimiter wrapper — current builds AND older pre-marker ones. Every
# wrapper references the ~/.framelimiter control files, so this lowercase token is a
# reliable cross-version signal; a real game binary won't contain it. Using only the
# explicit MARKER here was a destructive bug: an older markerless wrapper was misread as
# a real game binary, and its .real (the actual game) got moved/deleted.
is_wrapper() { grep -aiq 'framelimiter' "$1" 2>/dev/null; }

# ---- modes that take no app bundle ----
case "$MODE" in
  cli)
    mkdir -p "$HOME/.local/bin"
    ln -sf "$FLCTL" "$HOME/.local/bin/flctl"
    echo "linked flctl -> $HOME/.local/bin/flctl"
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) echo "note: add ~/.local/bin to your PATH to call 'flctl' directly";;
    esac
    exit 0
    ;;
  clean)
    rm -f "$CTRL" "$CTRL.last" \
          "$HOME/.framelimiter.hud" "$HOME/.framelimiter.bgfps" \
          "$HOME/.framelimiter.status" "$HOME/.framelimiter.log"
    rm -f "$HOME"/.framelimiter.status.tmp.* 2>/dev/null || true
    rm -f "$STABLE_DYLIB"
    rm -f "$HOME/.local/bin/flctl" 2>/dev/null || true
    echo "removed the shared dylib, control files, and the flctl symlink"
    echo "note: 'uninstall' any still-wrapped game bundles first"
    exit 0
    ;;
esac

# ---- modes that operate on an app bundle ----
APP="${2:-}"; FPS="${3:-80}"
[ -n "$MODE" ] && [ -n "$APP" ] || {
  echo "usage: $0 install|uninstall|status \"/path/Game.app\" [fps] | cli | clean"; exit 2; }
[ -d "$APP" ] || { echo "no such app bundle: $APP"; exit 1; }

PLIST="$APP/Contents/Info.plist"
EXE_NAME=$("$PB" -c "Print :CFBundleExecutable" "$PLIST")
EXE_PATH="$APP/Contents/MacOS/$EXE_NAME"
REAL_PATH="${EXE_PATH}.real"

resign() {
  # Preserve the game's entitlements (disable-library-validation, get-task-allow) and
  # re-seal the bundle. No --deep: nested dylibs keep their own signatures.
  codesign --force --sign - --preserve-metadata=entitlements,flags "$APP"
}

case "$MODE" in
  install)
    [ -f "$DYLIB" ] || { echo "dylib missing — run 'make build' first: $DYLIB"; exit 1; }

    MOVED_REAL=0
    WROTE_WRAPPER=0
    rollback() {
      rc=$?
      [ "$rc" -eq 0 ] && return
      if [ "$MOVED_REAL" -eq 1 ] && [ -f "$REAL_PATH" ]; then
        # We stashed the original this run — put it back so the bundle is launchable.
        rm -f "$EXE_PATH"; mv -f "$REAL_PATH" "$EXE_PATH"
        codesign --force --sign - --preserve-metadata=entitlements,flags "$APP" 2>/dev/null || true
        echo "install failed (rc=$rc) — restored the original executable" >&2
      elif [ "$WROTE_WRAPPER" -eq 1 ] && [ -f "$REAL_PATH" ]; then
        # Reinstall path: a recompile failed over an existing install. Fall back to the
        # plain original so the game still launches (uncapped); user can reinstall.
        rm -f "$EXE_PATH"; cp -p "$REAL_PATH" "$EXE_PATH"
        codesign --force --sign - --preserve-metadata=entitlements,flags "$APP" 2>/dev/null || true
        echo "install failed (rc=$rc) — left the original executable in place (uncapped)" >&2
      fi
    }
    trap rollback EXIT

    mkdir -p "$STABLE_HOME" "$STATE"

    # Publish the dylib to a stable, repo-independent location (shared by every installed
    # game; refreshed on each install).
    cp -f "$DYLIB" "$STABLE_DYLIB"
    codesign --force --sign - "$STABLE_DYLIB"

    # Legacy cleanup: older versions added an LSEnvironment dict. Remove it if present,
    # backing up the plist once so uninstall can restore it.
    if "$PB" -c "Print :LSEnvironment" "$PLIST" >/dev/null 2>&1; then
      BACKUP="$STATE/$(basename "$APP").Info.plist.bak"
      [ -f "$BACKUP" ] || cp -p "$PLIST" "$BACKUP"
      "$PB" -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null || true
    fi

    if is_wrapper "$EXE_PATH"; then
      # Already our wrapper: the real binary is preserved at .real. Just refresh below.
      [ -f "$REAL_PATH" ] || {
        echo "ERROR: wrapper present but $REAL_PATH missing — corrupt install."
        echo "Reinstall the game from Steam, then run install again."; exit 1; }
    else
      # A genuine game binary: a fresh install, OR a post-update binary that replaced our
      # wrapper. It is authoritative → stash it as .real, overwriting any stale .real.
      mv -f "$EXE_PATH" "$REAL_PATH"
      MOVED_REAL=1
    fi

    # Compile the wrapper into the executable slot, baking in the stable dylib path.
    clang -O2 -Wall -arch "$(uname -m)" \
      -DDYLIB_PATH="\"$STABLE_DYLIB\"" \
      -DDEFAULT_FPS="\"$FPS\"" \
      -o "$EXE_PATH" "$WRAPPER_SRC"
    WROTE_WRAPPER=1

    # Replicate the real binary's entitlements onto the wrapper, then re-seal the bundle.
    ENT="$(mktemp -t framelimiter.entitlements)"
    if codesign -d --entitlements - --xml "$REAL_PATH" > "$ENT" 2>/dev/null && [ -s "$ENT" ]; then
      codesign --force --sign - --entitlements "$ENT" "$EXE_PATH"
    else
      codesign --force --sign - "$EXE_PATH"
    fi
    rm -f "$ENT"

    resign
    "$LSREG" -f "$APP" 2>/dev/null || true

    codesign --verify --ignore-resources "$APP" 2>/dev/null \
      || { echo "WARNING: main signature failed to verify"; exit 1; }
    echo "signature OK (wrapper + bundle sealed)"

    # Seed the live control file with the default ONLY if absent, so the file remains the
    # persistent source of truth across launches (a prior 'flctl off' is not clobbered).
    [ -f "$CTRL" ] || echo "$FPS" > "$CTRL"

    trap - EXIT
    echo "installed: wrapper compiled (target ${FPS} fps, dylib ${STABLE_DYLIB}). Launch normally from Steam."
    ;;

  uninstall)
    if is_wrapper "$EXE_PATH" && [ -f "$REAL_PATH" ]; then
      rm -f "$EXE_PATH"; mv -f "$REAL_PATH" "$EXE_PATH"
      echo "restored original executable"
    elif [ -f "$REAL_PATH" ]; then
      # The current exe is not our wrapper (e.g. a game update replaced it). Keep it and
      # just drop the now-stale stash.
      rm -f "$REAL_PATH"
      echo "current executable is not the wrapper; removed stale ${EXE_NAME}.real"
    else
      echo "not installed (no wrapper, no .real)"
    fi
    BACKUP="$STATE/$(basename "$APP").Info.plist.bak"
    if [ -f "$BACKUP" ]; then
      cp -p "$BACKUP" "$PLIST"; rm -f "$BACKUP"
      echo "restored original Info.plist"
    fi
    resign
    "$LSREG" -f "$APP" 2>/dev/null || true
    echo "note: control files and the shared dylib remain; run '$0 clean' to remove them"
    ;;

  status)
    if is_wrapper "$EXE_PATH"; then
      echo "installed (wrapper present)"
      [ -f "$REAL_PATH" ] && echo "  original: $REAL_PATH" \
                          || echo "  WARNING: $REAL_PATH missing (corrupt install)"
      [ -f "$STABLE_DYLIB" ] && echo "  dylib: $STABLE_DYLIB" \
                             || echo "  WARNING: $STABLE_DYLIB missing (game will run uncapped)"
    else
      echo "not installed"
    fi
    codesign -dv "$APP" 2>&1 | grep -E 'Signature|flags' || true
    ;;

  *) echo "unknown mode: $MODE"; exit 2;;
esac
