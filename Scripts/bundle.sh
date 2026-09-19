#!/bin/bash
# Assembles NotchLog.app from the SwiftPM build product.
#
# No Xcode is involved: an .app bundle is three directories, a copy and a plist.
# A bundle is used rather than a bare binary because without CFBundleIdentifier the
# code signature, UserDefaults suite and LaunchServices registration are all
# synthesized and unstable, and LSUIElement is what guarantees no Dock icon ever
# flashes on launch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
BIN="$ROOT/.build/$CONFIG/notchlog"
OUT="${1:-$ROOT/.build/NotchLog.app}"

[ -x "$BIN" ] || { echo "error: $BIN not found — run 'swift build -c release' first" >&2; exit 1; }
VERSION="$("$BIN" version)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/notchlog"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist.template" > "$OUT/Contents/Info.plist"

# Ad-hoc signature with the hardened runtime. This cannot be notarized (that needs a
# paid Developer ID), which is exactly why this project ships as source rather than as
# a downloadable binary: a locally built app carries no quarantine flag and no Gatekeeper
# warning. The hardened runtime blocks DYLD_INSERT_LIBRARIES and unsigned code injection.
#
# App Sandbox is deliberately NOT used: a sandboxed process cannot exec /usr/bin/nettop
# (which needs the network-statistics kernel control socket) and no public entitlement
# grants it, so sandboxing would break the core function outright.
# The entitlements file is required, not optional: under the hardened runtime macOS
# refuses Calendar access outright without com.apple.security.personal-information.calendars
# — the request returns false with no error and TCC never shows a dialog.
codesign --force --options runtime \
    --entitlements "$ROOT/Resources/NotchLog.entitlements" \
    --sign - "$OUT" >/dev/null

# Verify the entitlement survived signing. Losing it fails silently at runtime — the
# calendar simply never gets permission — so it is worth asserting here rather than
# discovering it as a bug report.
if ! codesign -d --entitlements - "$OUT" 2>/dev/null \
     | tr -d '\0' | grep -q "com.apple.security.personal-information.calendars"; then
    echo "error: calendar entitlement missing from the signed bundle" >&2
    exit 1
fi

echo "$OUT"
