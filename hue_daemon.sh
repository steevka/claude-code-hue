#!/bin/bash
# claude-code-hue → animation daemon.
# Loops PUTs to the Hue Bridge while state is animated (working / needs_input).
# Reads /tmp/claude_hue_state every cycle. Exits when state is no longer animated.
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
trap 'rm -f "$PID_FILE"; exit 0' TERM INT

START=$(date +%s)

put() {
  local payload="$1"
  for ID in "${LIGHT_IDS[@]}"; do
    curl -s -m 2 -X PUT \
      "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights/${ID}/state" \
      -d "$payload" > /dev/null 2>&1 &
  done
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
  case "$STATE" in
    working)
      put "{\"on\":true,\"hue\":${WORKING_HUE_A},\"sat\":${WORKING_SAT},\"bri\":${WORKING_BRI},\"transitiontime\":${WORKING_FADE_DECISECONDS}}"
      sleep "$WORKING_HOLD_SECS"
      put "{\"on\":true,\"hue\":${WORKING_HUE_B},\"sat\":${WORKING_SAT},\"bri\":${WORKING_BRI},\"transitiontime\":${WORKING_FADE_DECISECONDS}}"
      sleep "$WORKING_HOLD_SECS"
      ;;
    needs_input)
      # Solid amber base
      put "{\"on\":true,\"hue\":${INPUT_HUE},\"sat\":${INPUT_SAT},\"bri\":${INPUT_BRI},\"transitiontime\":${INPUT_TRANSITION_DECISECONDS}}"
      sleep "$INPUT_BASE_HOLD_SECS"
      # Brief flash in contrast color
      put "{\"on\":true,\"hue\":${INPUT_FLASH_HUE},\"sat\":${INPUT_SAT},\"bri\":${INPUT_FLASH_BRI},\"transitiontime\":${INPUT_TRANSITION_DECISECONDS}}"
      sleep "$INPUT_FLASH_HOLD_SECS"
      ;;
    *)
      rm -f "$PID_FILE"
      exit 0
      ;;
  esac
done
