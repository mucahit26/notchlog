#!/bin/bash
# Removes NotchLog. Collected data is kept unless --purge is passed.
set -euo pipefail

LABEL="com.mucahit26.notchlog"
APP_DIR="$HOME/Library/Application Support/NotchLog"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGFILE="$HOME/Library/Logs/NotchLog.log"

echo "==> Stopping"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x notchlog 2>/dev/null || true

echo "==> Removing agent and app"
rm -f "$PLIST" "$LOGFILE"
rm -rf "$APP_DIR/NotchLog.app"

if [ "${1:-}" = "--purge" ]; then
    echo "==> Deleting collected data"
    rm -rf "$APP_DIR"
    echo "Removed, including the database and any exports."
else
    # Never silently delete the user's data. It is a record of their own activity
    # and deleting it is not implied by "uninstall the program".
    echo ""
    echo "Removed. Your collected data was KEPT at:"
    echo "  $APP_DIR"
    echo "Delete it with:  Scripts/uninstall.sh --purge"
fi
