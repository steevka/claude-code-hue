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
SNAPSHOT_FILE="/tmp/claude_hue/snapshot.txt"

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

# Manual / CLI-driven invocations get a "manual-*" session id. They should
# act on this invocation (so terminal tests still work) but must NOT linger
# in the aggregator across future hook events — otherwise a stale `bash
# hue_hook.sh needs_input` from a debugging session pins the lights to
# blue for 30 minutes. Clean up the file at exit.
case "$SESSION_ID" in
  manual-*)
    trap 'rm -f "$SESSION_FILE"' EXIT
    ;;
esac

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

daemon_alive() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

ensure_daemon() {
  if ! daemon_alive; then
    rm -f "$PID_FILE"
    nohup "$DAEMON" > /dev/null 2>&1 &
  fi
}

# Stop the daemon and wait for it to actually exit (its TERM trap kills
# any in-flight child curls so they can't race ahead of our static PUT).
stop_daemon() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      local i=0
      while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 8 ]; do
        sleep 0.05
        i=$((i + 1))
      done
    fi
    rm -f "$PID_FILE"
  fi
}

# Capture each light's current color state from the bridge so we can
# restore it on the next idle transition. Skips brightness (per design,
# we never touch bri). Snapshot is taken at the moment we leave the
# resting state — so any color the user set via the Hue app while idle
# is preserved across the upcoming animation.
snapshot_lights() {
  : > "$SNAPSHOT_FILE"
  for ID in "${LIGHT_IDS[@]}"; do
    local body payload
    body=$(curl -s -m 2 "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights/${ID}" 2>/dev/null) || continue
    [ -z "$body" ] && continue
    payload=$(printf '%s' "$body" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    s = d.get("state", {})
    out = {"on": bool(s.get("on", True))}
    mode = s.get("colormode")
    # Hue app uses xy by default; phone color picker sends xy.
    # hue/sat fields can be stale when colormode is xy or ct, so always
    # honor colormode when picking which fields to round-trip.
    if mode == "xy" and isinstance(s.get("xy"), list) and len(s["xy"]) == 2:
        out["xy"] = s["xy"]
    elif mode == "ct" and "ct" in s:
        out["ct"] = s["ct"]
    elif "hue" in s and "sat" in s:
        out["hue"] = s["hue"]
        out["sat"] = s["sat"]
    print(json.dumps(out, separators=(",", ":")))
except Exception:
    pass
' 2>/dev/null)
    [ -n "$payload" ] && printf '%s|%s\n' "$ID" "$payload" >> "$SNAPSHOT_FILE"
  done
}

# Restore each light from the snapshot. Returns 0 on success, 1 if no
# usable snapshot exists (caller should fall back to IDLE_HUE/IDLE_SAT).
restore_lights() {
  [ -s "$SNAPSHOT_FILE" ] || return 1
  local pids=() id payload with_trans trans
  trans="${STATE_TRANSITION_DECISECONDS:-2}"
  while IFS='|' read -r id payload; do
    [ -z "$id" ] && continue
    [ -z "$payload" ] && continue
    # Inject transitiontime by replacing the trailing `}` with `,"transitiontime":N}`
    with_trans="${payload%\}},\"transitiontime\":${trans}}"
    curl -s -m 2 -X PUT \
      "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights/${id}/state" \
      -d "$with_trans" > /dev/null 2>&1 &
    pids+=($!)
  done < "$SNAPSHOT_FILE"
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  return 0
}

# Pick the right solid-mode payload for an animated state and fire it.
put_solid_for_state() {
  case "$1" in
    working)
      put_sync "{\"on\":true,\"hue\":${SOLID_WORKING_HUE},\"sat\":${SOLID_WORKING_SAT},\"transitiontime\":${STATE_TRANSITION_DECISECONDS:-2}}"
      ;;
    needs_input)
      put_sync "{\"on\":true,\"hue\":${SOLID_INPUT_HUE},\"sat\":${SOLID_INPUT_SAT},\"transitiontime\":${STATE_TRANSITION_DECISECONDS:-2}}"
      ;;
  esac
}

# Apply the indicator for an animated state. Solid mode snaps to a
# single color; breathing mode hands off to the animation daemon.
# Used by both the debounce self-heal path and the main state-change
# dispatch so the two stay in lockstep.
apply_animated() {
  if [ "${INDICATOR_MODE:-breathing}" = "solid" ]; then
    stop_daemon
    put_solid_for_state "$1"
  else
    ensure_daemon
  fi
}

# Synchronous PUT: fire all light updates in parallel, then wait for them
# to complete before returning. Used for static state transitions where
# we don't want to race with the daemon's last in-flight PUT.
put_sync() {
  local payload="$1"
  local pids=()
  for ID in "${LIGHT_IDS[@]}"; do
    curl -s -m 2 -X PUT \
      "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights/${ID}/state" \
      -d "$payload" > /dev/null 2>&1 &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

# Debounce: skip the full update path if effective state unchanged.
# But still self-heal: in breathing mode, relaunch the daemon if it died;
# in solid mode, ensure no leftover daemon is still animating and re-PUT
# the solid color in case the user just flipped mode mid-state.
LAST=$(cat "$STATE_FILE" 2>/dev/null || true)
if [ "$AGGREGATE" = "$LAST" ]; then
  case "$AGGREGATE" in
    working|needs_input) apply_animated "$AGGREGATE" ;;
  esac
  exit 0
fi
echo "$AGGREGATE" > "$STATE_FILE"

case "$AGGREGATE" in
  working|needs_input)
    # On the resting→animated edge, snapshot the lights' current color so
    # we can put it back on the next idle transition. Skip if we're just
    # animated→animated (snapshot already taken on the original entry).
    case "$LAST" in
      working|needs_input) ;;
      *) snapshot_lights ;;
    esac
    apply_animated "$AGGREGATE"
    ;;
  idle)
    stop_daemon
    if ! restore_lights; then
      put_sync "{\"on\":true,\"hue\":${IDLE_HUE},\"sat\":${IDLE_SAT},\"transitiontime\":${STATE_TRANSITION_DECISECONDS:-2}}"
    fi
    ;;
  off)
    stop_daemon
    put_sync "{\"on\":false,\"transitiontime\":${OFF_TRANSITION}}"
    ;;
esac

exit 0
