#!/bin/bash
# claude-code-hue → animation daemon.
# Loops PUTs to the Hue Bridge while state is animated (working / needs_input).
# Uses fine-grained sleep with state checks so it exits cleanly when state
# changes — without leaving the lamps stuck on whatever color was just fired.
# Auto-exits after DAEMON_MAX_RUNTIME seconds as a failsafe.
#
# Launched in background by hue_hook.sh; not run directly by the user.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/hue_config.sh"

if [ ! -f "$CONFIG" ]; then
  exit 1
fi

# shellcheck source=hue_config.example.sh
. "$CONFIG"

STATE_FILE="/tmp/claude_hue_state"
PID_FILE="/tmp/claude_hue_daemon.pid"

echo $$ > "$PID_FILE"
# On TERM/INT: kill any in-flight child curls so they can't land at the
# bridge after we're gone (which would fight the new state PUT the hook
# is about to fire). Then remove pid file and exit.
cleanup() {
  rm -f "$PID_FILE"
  pkill -P $$ 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT
# Ignore SIGHUP — survive parent shell exiting.
trap '' HUP

START=$(date +%s)

# Track previous state so we can use a fast transition on the first PUT
# after a state change (snap into the new color), then revert to the
# slow in-state breathing fade.
LAST_STATE=""
STATE_TRANS="${STATE_TRANSITION_DECISECONDS:-2}"

put() {
  local payload="$1"
  for ID in "${LIGHT_IDS[@]}"; do
    curl -s -m 2 -X PUT \
      "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights/${ID}/state" \
      -d "$payload" > /dev/null 2>&1 &
  done
}

# Sleep in 100ms ticks, returning early if state changes away from $expected.
# Returns 0 if full duration slept; 1 if state changed (caller should bail).
state_sleep() {
  local seconds="$1"
  local expected="$2"
  local ticks=$((seconds * 10))
  local i=0
  while [ "$i" -lt "$ticks" ]; do
    sleep 0.1
    i=$((i + 1))
    [ "$(cat "$STATE_FILE" 2>/dev/null || true)" != "$expected" ] && return 1
  done
  return 0
}

while true; do
  # Failsafe: exit after MAX_RUNTIME
  NOW=$(date +%s)
  if [ $((NOW - START)) -ge "$DAEMON_MAX_RUNTIME" ]; then
    rm -f "$PID_FILE"
    exit 0
  fi

  # Stop if we've been replaced by a newer daemon (PID file mismatch)
  if [ ! -f "$PID_FILE" ] || [ "$(cat "$PID_FILE" 2>/dev/null)" != "$$" ]; then
    exit 0
  fi

  STATE=$(cat "$STATE_FILE" 2>/dev/null || true)

  # First PUT after a state change uses STATE_TRANS (fast snap).
  # Subsequent PUTs in the same state use the slow breathing fade.
  if [ "$STATE" != "$LAST_STATE" ]; then
    ENTRY_TRANS="$STATE_TRANS"
  else
    ENTRY_TRANS=""
  fi
  LAST_STATE="$STATE"

  case "$STATE" in
    working)
      TRANS="${ENTRY_TRANS:-$WORKING_FADE_DECISECONDS}"
      put "{\"on\":true,\"hue\":${WORKING_HUE_A},\"sat\":${WORKING_SAT},\"transitiontime\":${TRANS}}"
      state_sleep "$WORKING_HOLD_SECS" working || continue
      put "{\"on\":true,\"hue\":${WORKING_HUE_B},\"sat\":${WORKING_SAT},\"transitiontime\":${WORKING_FADE_DECISECONDS}}"
      state_sleep "$WORKING_HOLD_SECS" working || continue
      ;;
    needs_input)
      TRANS="${ENTRY_TRANS:-$INPUT_TRANSITION_DECISECONDS}"
      put "{\"on\":true,\"hue\":${INPUT_HUE},\"sat\":${INPUT_SAT},\"transitiontime\":${TRANS}}"
      state_sleep "$INPUT_BASE_HOLD_SECS" needs_input || continue
      put "{\"on\":true,\"hue\":${INPUT_FLASH_HUE},\"sat\":${INPUT_SAT},\"transitiontime\":${INPUT_TRANSITION_DECISECONDS}}"
      state_sleep "$INPUT_FLASH_HOLD_SECS" needs_input || continue
      ;;
    *)
      rm -f "$PID_FILE"
      exit 0
      ;;
  esac
done
