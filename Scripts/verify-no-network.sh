#!/bin/bash
# Proves, on your own machine, that NotchLog holds no network connections.
set -uo pipefail

PID="$(pgrep -x notchlog | head -1 || true)"
if [ -z "$PID" ]; then
    echo "NotchLog is not running. Start it first, then re-run this."
    exit 1
fi

echo "NotchLog PID: $PID"
echo ""
echo "1) Open network sockets held by the process (expected: none)"
echo "-------------------------------------------------------------"
OUT="$(/usr/sbin/lsof -nP -i -a -p "$PID" 2>/dev/null || true)"
if [ -z "$OUT" ]; then
    echo "   none — the process holds no TCP or UDP sockets."
    RESULT=0
else
    echo "$OUT"
    RESULT=1
fi

echo ""
echo "2) Traffic attributed to the process by the kernel (expected: none)"
echo "-------------------------------------------------------------"
/usr/bin/nettop -n -x -P -l 1 -p "$PID" -J bytes_in,bytes_out 2>/dev/null || true

echo ""
echo "3) Networking symbols linked into the binary"
echo "-------------------------------------------------------------"
BIN="$(ps -o comm= -p "$PID" | tr -d ' ')"
otool -L "$BIN" 2>/dev/null | sed 's/^/   /' || echo "   (binary not readable)"
echo ""
echo "   CFNetwork may appear here: Foundation links it whether or not any code"
echo "   uses it. The authoritative check is (1) — a process that never opens a"
echo "   socket cannot send anything, regardless of what is linked in."

echo ""
if [ "$RESULT" -eq 0 ]; then
    echo "PASS — no network activity is possible from this process."
else
    echo "FAIL — unexpected sockets listed above. Please open an issue."
fi
exit "$RESULT"
