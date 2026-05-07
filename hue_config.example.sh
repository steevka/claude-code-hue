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

# By design we do NOT set brightness in any PUT — Hue keeps the bulb at
# whatever brightness you last set it to (via the Hue app, switch, or any
# other controller). We only change hue and saturation. Set your bulbs to
# whatever brightness you like; the indicator respects it.

# Snappy transition between modes (idle ↔ working ↔ needs_input). Used for
# the FIRST PUT after a state change — so entering and leaving animations
# feels instant. The slow breathing fade inside each animation is still
# controlled by WORKING_FADE_DECISECONDS / INPUT_TRANSITION_DECISECONDS.
STATE_TRANSITION_DECISECONDS=2  # 200ms — feels instant; raise for softer mode switches

# Indicator mode: "breathing" (default) animates working/needs_input via
# the daemon; "solid" skips the daemon and just snaps to a single color
# per state. Useful when you want zero motion — or when you want the
# absolute lowest-latency feedback.
INDICATOR_MODE=breathing

# Colors used when INDICATOR_MODE=solid (ignored otherwise).
SOLID_WORKING_HUE=50000   # Purple
SOLID_WORKING_SAT=254
SOLID_INPUT_HUE=46920     # Blue
SOLID_INPUT_SAT=254

# Working state — breathing between two colors
WORKING_HUE_A=46920          # Blue
WORKING_HUE_B=50000          # Purple
WORKING_SAT=254
WORKING_FADE_DECISECONDS=30  # 3.0s fade per direction
WORKING_HOLD_SECS=3          # Sleep between PUTs (match the fade time)

# Needs-input state — same breathe rhythm as working (blue ↔ green
# instead of blue ↔ purple). Distinguishes "Claude needs you" from
# "Claude is thinking" while staying in the same family of motion.
INPUT_HUE=46920                  # Blue
INPUT_FLASH_HUE=25500            # Green
INPUT_SAT=254
INPUT_BASE_HOLD_SECS=3           # Seconds on blue per cycle (integer only)
INPUT_FLASH_HOLD_SECS=3          # Seconds on green per cycle (integer only)
INPUT_TRANSITION_DECISECONDS=30  # 3s smooth fade between colors

# Idle state — solid, no animation.
# By default the lamps return to whatever color/on-state they had right
# before Claude started working (snapshot is taken at the resting→animated
# edge, so colors you set during long idle stretches via the Hue app are
# preserved). These values are used only as a fallback when no snapshot
# exists yet (first run, or after `bash reset.sh`).
IDLE_HUE=5000                # Warm amber (fallback only)
IDLE_SAT=200                 # (fallback only)
IDLE_TRANSITION=10           # 1.0s fade in (used for both snapshot restore and fallback)

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
