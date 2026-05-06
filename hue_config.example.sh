#!/bin/bash
# claude-code-hue — user configuration
# Copy this file to `hue_config.sh` and fill in your values.
# `hue_config.sh` is gitignored so your secrets stay local.
#
# Run `bash setup.sh` to discover these values automatically.

# ── Hue Bridge ─────────────────────────────────────────────────────────────
# Your bridge's local IP. Find via: curl https://discovery.meethue.com/
BRIDGE_IP="192.168.X.X"

# App key (called "username" in Hue API). Created by pressing the bridge
# button + POSTing to /api. setup.sh handles this for you.
HUE_USERNAME="paste-your-app-key-here"

# Light IDs to control. Find via: curl http://$BRIDGE_IP/api/$HUE_USERNAME/lights
# Use 1-2 lights for best effect. Color-capable bulbs only (Extended color light).
LIGHT_IDS=(8 9)

# ── Colors & timing ────────────────────────────────────────────────────────
# Hue API ranges:
#   hue: 0-65535 (color wheel)   sat: 0-254   bri: 0-254
#   transitiontime: deciseconds (10 = 1 second)

# Working state — breathing between two colors
WORKING_HUE_A=46920          # Blue
WORKING_HUE_B=50000          # Purple
WORKING_SAT=254
WORKING_BRI=200
WORKING_FADE_DECISECONDS=30  # 3.0s fade per direction
WORKING_HOLD_SECS=3          # Sleep between PUTs (match the fade time)

# Needs-input state — single-color brightness pulse
INPUT_HUE=5000               # Amber
INPUT_SAT=254
INPUT_BRI_HIGH=254
INPUT_BRI_LOW=80
INPUT_FADE_DECISECONDS=8     # 800ms fade
INPUT_HOLD_SECS=0.8

# Idle state — solid, no animation
IDLE_HUE=5000                # Warm amber
IDLE_SAT=200
IDLE_BRI=160
IDLE_TRANSITION=10           # 1.0s fade in

# Off state
OFF_TRANSITION=4             # 400ms fade out

# ── Daemon & cleanup ───────────────────────────────────────────────────────
# Animation daemon auto-exits after this many seconds as a failsafe.
DAEMON_MAX_RUNTIME=1800      # 30 minutes

# Per-state expiration (seconds). When a session's last update is older
# than its state's threshold, the file is dropped from the aggregate and
# deleted. This is what catches tabs closed via Cmd+Q / terminal close
# that never fire SessionEnd — without needing a manual reset.
#
# Defaults reflect natural lifetimes:
#   - "working" should resolve within seconds via Stop; 10 min covers long
#     tool runs (big bash builds, network fetches) but kills ghost states
#   - "needs_input" can wait longer (you walked away from a permission prompt)
#   - "idle" is the resting state — keep effectively indefinite
WORKING_MAX_AGE_SECS=600       # 10 minutes
NEEDS_INPUT_MAX_AGE_SECS=1800  # 30 minutes
IDLE_MAX_AGE_SECS=86400        # 24 hours (final cleanup failsafe)
