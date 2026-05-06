#!/bin/bash
# claude-code-hue interactive setup wizard.
# Discovers your Hue Bridge, creates an app key, lists your lights,
# and writes hue_config.sh — all without touching ~/.claude/settings.json.
#
# After this completes, run: bash install-hooks.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE="$SCRIPT_DIR/hue_config.example.sh"
CONFIG="$SCRIPT_DIR/hue_config.sh"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$1"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$1"; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$1" >&2; }
ask()   { printf '\033[36m?\033[0m %s ' "$1"; }

# ── Preflight ──────────────────────────────────────────────────────────────
for cmd in curl python3 grep sed; do
  command -v "$cmd" > /dev/null 2>&1 || { fail "missing required command: $cmd"; exit 1; }
done

if [ -f "$CONFIG" ]; then
  warn "hue_config.sh already exists at $CONFIG"
  ask "Overwrite? [y/N]"
  read -r ANSWER
  case "$ANSWER" in [yY]*) ;; *) echo "Aborted."; exit 0 ;; esac
fi

bold "── claude-code-hue setup ─────────────────────────────"
echo

# ── Step 1: Discover bridge ────────────────────────────────────────────────
bold "Step 1/4: Find your Hue Bridge"
echo "Querying https://discovery.meethue.com/ ..."
DISCOVERY=$(curl -s -m 10 https://discovery.meethue.com/ || true)
DISCOVERED_IP=$(printf '%s' "$DISCOVERY" | python3 -c "
import sys, json
try:
    arr = json.load(sys.stdin)
    if arr and 'internalipaddress' in arr[0]:
        print(arr[0]['internalipaddress'])
except Exception:
    pass
" 2>/dev/null || true)

if [ -n "$DISCOVERED_IP" ]; then
  ok "Found bridge at $DISCOVERED_IP"
  ask "Use this address? [Y/n]"
  read -r ANSWER
  case "$ANSWER" in [nN]*) DISCOVERED_IP="" ;; esac
fi

if [ -z "$DISCOVERED_IP" ]; then
  ask "Enter your bridge IP (e.g. 192.168.1.42):"
  read -r DISCOVERED_IP
  [ -z "$DISCOVERED_IP" ] && { fail "no IP provided"; exit 1; }
fi

BRIDGE_IP="$DISCOVERED_IP"

# Verify reachable (Hue v2 API serves config on /api/0/config without auth)
if ! curl -s -m 5 "http://${BRIDGE_IP}/api/0/config" | grep -q "bridgeid"; then
  fail "couldn't reach bridge at http://${BRIDGE_IP}/api/0/config"
  echo "  check the IP and that you're on the same network as the bridge."
  exit 1
fi
ok "Bridge reachable"
echo

# ── Step 2: App key ────────────────────────────────────────────────────────
bold "Step 2/4: Create an app key"
echo "Press the round button on top of your Hue Bridge."
ask "Press it now, then hit Enter..."
read -r _

RESPONSE=$(curl -s -m 5 -X POST "http://${BRIDGE_IP}/api" \
  -H "Content-Type: application/json" \
  -d '{"devicetype":"claude-code-hue#'"$(hostname -s)"'"}')

HUE_USERNAME=$(printf '%s' "$RESPONSE" | python3 -c "
import sys, json
try:
    arr = json.load(sys.stdin)
    if isinstance(arr, list) and arr and 'success' in arr[0]:
        print(arr[0]['success']['username'])
except Exception:
    pass
" 2>/dev/null || true)

if [ -z "$HUE_USERNAME" ]; then
  fail "couldn't create app key. Bridge response:"
  echo "  $RESPONSE"
  echo "  most common cause: button not pressed within 30s. Try again."
  exit 1
fi
ok "App key created"
echo

# ── Step 3: Pick lights ────────────────────────────────────────────────────
bold "Step 3/4: Pick your lights"
LIGHTS_JSON=$(curl -s -m 5 "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights")

printf '%s' "$LIGHTS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('  ID  Name                                  Type')
print('  ──  ────────────────────────────────────  ─────────────────')
for k, v in sorted(d.items(), key=lambda kv: int(kv[0])):
    name = v.get('name', '?')[:36]
    typ = v.get('type', '?')
    print(f'  {k:>2}  {name:<36}  {typ}')
"
echo
echo "Pick 1-2 color-capable lights (Extended color light)."
ask "Light IDs separated by spaces (e.g. 8 9):"
read -r LIGHT_INPUT
[ -z "$LIGHT_INPUT" ] && { fail "no IDs provided"; exit 1; }

# Validate that each ID exists
for id in $LIGHT_INPUT; do
  EXISTS=$(printf '%s' "$LIGHTS_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('yes' if '$id' in d else 'no')
")
  if [ "$EXISTS" != "yes" ]; then
    fail "light ID $id not found on bridge"
    exit 1
  fi
done
ok "Light IDs validated"
echo

# ── Step 4: Write config ───────────────────────────────────────────────────
bold "Step 4/4: Write configuration"

# Format LIGHT_IDS as a bash array literal
LIGHT_IDS_ARRAY="LIGHT_IDS=($LIGHT_INPUT)"

# Copy example, substitute the three values
sed \
  -e "s|^BRIDGE_IP=.*|BRIDGE_IP=\"$BRIDGE_IP\"|" \
  -e "s|^HUE_USERNAME=.*|HUE_USERNAME=\"$HUE_USERNAME\"|" \
  -e "s|^LIGHT_IDS=.*|$LIGHT_IDS_ARRAY|" \
  "$EXAMPLE" > "$CONFIG"

ok "Wrote $CONFIG"
echo

# ── Smoke test ─────────────────────────────────────────────────────────────
bold "Smoke test: flashing lights twice"
for _ in 1 2; do
  for id in $LIGHT_INPUT; do
    curl -s -m 2 -X PUT "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights/${id}/state" \
      -d '{"on":true,"bri":254,"transitiontime":0}' > /dev/null &
  done
  sleep 0.6
  for id in $LIGHT_INPUT; do
    curl -s -m 2 -X PUT "http://${BRIDGE_IP}/api/${HUE_USERNAME}/lights/${id}/state" \
      -d '{"on":false,"transitiontime":0}' > /dev/null &
  done
  sleep 0.6
done
ok "Flash test complete (did you see them?)"
echo

bold "── Setup complete ────────────────────────────────────"
echo
echo "Next: wire the hooks into Claude Code."
echo "  bash install-hooks.sh"
echo
echo "Or add the hook entries manually — see README.md."
