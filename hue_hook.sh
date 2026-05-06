#!/bin/bash
# claude-code-hue → entry point called by Claude Code hooks.
# Multi-session aware: aggregates state across all active Claude Code sessions.
# Priority: needs_input > working > idle > off
#
# Usage: hue_hook.sh <state>
#   states: working | idle | needs_input | off

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/hue_config.sh"

if [ ! -f "$CONFIG" ]; then
  echo "claude-code-hue: missing config at $CONFIG" >&2
  echo "  copy hue_config.example.sh → hue_config.sh and edit, or run: bash setup.sh" >&2
  exit 1
fi

# shellcheck source=hue_config.example.sh
. "$CONFIG"

DAEMON="$SCRIPT_DIR/hue_daemon.sh"
SESSION_DIR="/tmp/claude_hue"
STATE_FILE="/tmp/claude_hue_state"
PID_FILE="/tmp/claude_hue_daemon.pid"

mkdir -p "$SESSION_DIR"

STATE="${1:-}"
[ -z "$STATE" ] && { echo "usage: $0 <working|idle|needs_input|off>" >&2; exit 1; }

# Identify session via Claude Code stdin JSON; fall back to PID for manual calls
SESSION_ID=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
  SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('session_id', ''))
except Exception:
    pass
" 2>/dev/null)
fi
[ -z "$SESSION_ID" ] && SESSION_ID="manual-$$"

SESSION_FILE="$SESSION_DIR/${SESSION_ID}.state"

# Update this session's slot
if [ "$STATE" = "off" ]; then
  rm -f "$SESSION_FILE"
else
  echo "$STATE" > "$SESSION_FILE"
fi

# Failsafe: drop any stale session files (mtime > SESSION_STALE_MINS).
# Catches tabs closed via Cmd+Q / terminal close, which never fire SessionEnd.
find "$SESSION_DIR" -name "*.state" -type f -mmin +"${SESSION_STALE_MINS:-15}" -delete 2>/dev/null

# Aggregate by priority
ALL_STATES=$(cat "$SESSION_DIR"/*.state 2>/dev/null || true)
if echo "$ALL_STATES" | grep -qx "needs_input"; then
  AGGREGATE=needs_input
elif echo "$ALL_STATES" | grep -qx "working"; then
  AGGREGATE=working
elif echo "$ALL_STATES" | grep -qx "idle"; then
  AGGREGATE=idle
else
  AGGREGATE=off
fi

# Debounce: skip if effective state unchanged
LAST=$(cat "$STATE_FILE" 2>/dev/null || true)
if [ "$AGGREGATE" = "$LAST" ]; then
  exit 0
fi
echo "$AGGREGATE" > "$STATE_FILE"

# Kill any running animation daemon
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  [ -n "$OLD_PID" ] && kill "$OLD_PID" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

put() {
  local payload="$1"
  for ID in "${LIGHT_IDS[@]}"; do
    curl -s -m 2 -X PUT \
      "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights/${ID}/state" \
      -d "$payload" > /dev/null 2>&1 &
  done
}

case "$AGGREGATE" in
  working|needs_input)
    nohup "$DAEMON" > /dev/null 2>&1 &
    ;;
  idle)
    put "{\"on\":true,\"hue\":${IDLE_HUE},\"sat\":${IDLE_SAT},\"bri\":${IDLE_BRI},\"transitiontime\":${IDLE_TRANSITION}}"
    ;;
  off)
    put "{\"on\":false,\"transitiontime\":${OFF_TRANSITION}}"
    ;;
esac

exit 0
