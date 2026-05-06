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

# Parse Claude Code stdin JSON for session_id and (for Notification hooks) message.
# Falls back to PID for manual calls (no stdin).
SESSION_ID=""
NOTIF_MESSAGE=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
  PARSED=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('session_id', ''))
    print(d.get('message', ''))
except Exception:
    print('')
    print('')
" 2>/dev/null)
  SESSION_ID=$(printf '%s' "$PARSED" | sed -n '1p')
  NOTIF_MESSAGE=$(printf '%s' "$PARSED" | sed -n '2p')
fi
[ -z "$SESSION_ID" ] && SESSION_ID="manual-$$"

# Filter out Claude Code's idle-timeout notification ("waiting for your input"),
# which fires after ~60s of inactivity even when no permission is needed.
# Real permission requests and other actionable notifications still pass through.
if [ "$STATE" = "needs_input" ] && [ -n "$NOTIF_MESSAGE" ]; then
  if echo "$NOTIF_MESSAGE" | grep -qiE "waiting for your input|waiting for input"; then
    exit 0
  fi
fi

SESSION_FILE="$SESSION_DIR/${SESSION_ID}.state"

# Update this session's slot
if [ "$STATE" = "off" ]; then
  rm -f "$SESSION_FILE"
else
  echo "$STATE" > "$SESSION_FILE"
fi

# Aggregate by priority, with per-state expiration that actively prunes
# dead sessions (e.g. a tab closed via Cmd+Q without SessionEnd firing).
# A 'working' state should resolve within seconds via Stop; if it hasn't
# in WORKING_MAX_AGE_SECS, the session is dead and we drop the file now.

mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

NOW=$(date +%s)
ACTIVE_NEEDS=0 ACTIVE_WORKING=0 ACTIVE_IDLE=0

for SF in "$SESSION_DIR"/*.state; do
  [ -f "$SF" ] || continue
  S=$(cat "$SF" 2>/dev/null) || continue
  AGE=$((NOW - $(mtime "$SF")))

  case "$S" in
    needs_input)
      if [ "$AGE" -lt "${NEEDS_INPUT_MAX_AGE_SECS:-1800}" ]; then
        ACTIVE_NEEDS=1
      else
        rm -f "$SF"
      fi
      ;;
    working)
      if [ "$AGE" -lt "${WORKING_MAX_AGE_SECS:-600}" ]; then
        ACTIVE_WORKING=1
      else
        rm -f "$SF"
      fi
      ;;
    idle)
      # Idle is the resting state — never expires for aggregation,
      # but still gets cleaned up after IDLE_MAX_AGE_SECS as a final failsafe.
      if [ "$AGE" -lt "${IDLE_MAX_AGE_SECS:-86400}" ]; then
        ACTIVE_IDLE=1
      else
        rm -f "$SF"
      fi
      ;;
  esac
done

if [ "$ACTIVE_NEEDS" = 1 ]; then
  AGGREGATE=needs_input
elif [ "$ACTIVE_WORKING" = 1 ]; then
  AGGREGATE=working
elif [ "$ACTIVE_IDLE" = 1 ]; then
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
