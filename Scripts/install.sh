#!/bin/bash
# Builds NotchLog from source and installs it as a LaunchAgent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.mucahit26.notchlog"
APP_DIR="$HOME/Library/Application Support/NotchLog"
APP="$APP_DIR/NotchLog.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGFILE="$HOME/Library/Logs/NotchLog.log"

echo "==> Checking prerequisites"
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || { echo "error: macOS 14 or later required (found $(sw_vers -productVersion))" >&2; exit 1; }
command -v swift >/dev/null || {
    echo "error: Swift not found. Install the Command Line Tools:  xcode-select --install" >&2
    exit 1
}
echo "    macOS $(sw_vers -productVersion), $(swift --version 2>&1 | head -1)"

echo "==> Building (this takes a minute on first run)"
cd "$ROOT"
swift build -c release

echo "==> Running self-test"
./.build/release/notchlog selftest

echo "==> Assembling app bundle"
BUILT="$("$ROOT/Scripts/bundle.sh")"

echo "==> Stopping any running instance"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x notchlog 2>/dev/null || true
sleep 1

echo "==> Installing to $APP"
mkdir -p "$APP_DIR"
chmod 700 "$APP_DIR"
rm -rf "$APP"
cp -R "$BUILT" "$APP"

echo "==> Writing LaunchAgent"
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOGFILE")"
sed -e "s|__BINARY__|$APP/Contents/MacOS/notchlog|g" \
    -e "s|__LOGFILE__|$LOGFILE|g" \
    "$ROOT/Resources/launchagent.plist.template" > "$PLIST"

echo "==> Starting"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2

if pgrep -x notchlog >/dev/null; then
    echo ""
    echo "NotchLog is running. Move the pointer to the notch to open it."
    echo ""
    echo "  Data       : $APP_DIR"
    echo "  Log        : $LOGFILE"
    echo "  Verify     : Scripts/verify-no-network.sh"
    echo "  Uninstall  : Scripts/uninstall.sh"
    echo ""
    echo "macOS lists it under System Settings > General > Login Items >"
    echo "\"Allow in the Background\". That entry is how it starts at login."
else
    echo "error: it did not start. Check $LOGFILE" >&2
    exit 1
fi
