#!/bin/bash
# claude-code-hue → flip INDICATOR_MODE in hue_config.sh between
# "breathing" and "solid". Run with no args to see the current mode,
# or pass `breathing` / `solid` to set it.
#
# Lets you A/B test the two indicator styles without editing the
# config file by hand. The next hook event picks up the change
# (and the breathing daemon, if running, exits cleanly on the next
# resting transition).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/hue_config.sh"

if [ ! -f "$CONFIG" ]; then
  echo "missing $CONFIG — run setup.sh first" >&2
  exit 1
fi

CURRENT=$(grep -E '^INDICATOR_MODE=' "$CONFIG" | head -1 | cut -d= -f2 | tr -d '"')
CURRENT="${CURRENT:-breathing}"

if [ $# -eq 0 ]; then
  echo "INDICATOR_MODE=$CURRENT"
  echo "usage: $0 breathing|solid|toggle"
  exit 0
fi

case "$1" in
  breathing|solid) NEW="$1" ;;
  toggle)
    if [ "$CURRENT" = "breathing" ]; then NEW=solid; else NEW=breathing; fi
    ;;
  *) echo "unknown mode: $1 (expected breathing|solid|toggle)" >&2; exit 1 ;;
esac

if grep -qE '^INDICATOR_MODE=' "$CONFIG"; then
  # macOS sed needs '' after -i; portable form is to write to a tmp file
  TMP=$(mktemp)
  awk -v mode="$NEW" '/^INDICATOR_MODE=/ { print "INDICATOR_MODE=" mode; next } { print }' "$CONFIG" > "$TMP"
  mv "$TMP" "$CONFIG"
else
  printf '\nINDICATOR_MODE=%s\n' "$NEW" >> "$CONFIG"
fi

echo "INDICATOR_MODE: $CURRENT → $NEW"
