#!/bin/bash
# claude-code-hue → wipe all runtime state and stop the animation daemon.
# Use when lamps are stuck or behaving oddly:
#   - Daemon left running with stale config after a path change
#   - Phantom "working" state from a Claude Code tab closed via Cmd+Q
#   - You just want to start fresh
#
# Hook commands keep working after reset; the next event repopulates state.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stop daemon if running
if [ -f /tmp/claude_hue_daemon.pid ]; then
  PID=$(cat /tmp/claude_hue_daemon.pid 2>/dev/null || true)
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
fi

# Wipe runtime state
rm -rf /tmp/claude_hue /tmp/claude_hue_state /tmp/claude_hue_daemon.pid

# Turn lamps off, then bring them back to idle
"$SCRIPT_DIR/hue_hook.sh" off > /dev/null 2>&1 || true
sleep 0.5
"$SCRIPT_DIR/hue_hook.sh" idle > /dev/null 2>&1 || true

echo "✓ State cleared. Lamps reset to idle."
