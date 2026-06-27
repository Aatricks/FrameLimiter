#!/usr/bin/env bash
# Inspect a target executable and report whether DYLD injection should work
# without re-signing. Pass the path to the Mach-O binary inside the .app.
#
#   scripts/check-target.sh "/path/to/Game.app/Contents/MacOS/Game"
set -euo pipefail
BIN="${1:?usage: check-target.sh /path/to/Contents/MacOS/<executable>}"

echo "== arch =="
file "$BIN"
lipo -archs "$BIN" 2>/dev/null || true

echo "== signature =="
codesign -dvvv "$BIN" 2>&1 | grep -Ei 'flags|TeamIdentifier|Signature' || true

echo "== entitlements =="
codesign -d --entitlements :- "$BIN" 2>/dev/null | tr -d '\0' || true

echo "== restricted segment =="
otool -l "$BIN" | grep -i restrict || echo "  none (DYLD env vars are not stripped)"

echo "== verdict =="
if codesign -dvvv "$BIN" 2>&1 | grep -qiE 'flags=.*runtime'; then
    echo "  hardened runtime present — DYLD_INSERT_LIBRARIES will likely be ignored."
    echo "  Re-sign with disable-library-validation + allow-dyld-environment-variables (see README)."
else
    echo "  no hardened runtime flag — DYLD injection should work; just ad-hoc sign the dylib."
fi
