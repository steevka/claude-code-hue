#!/bin/bash
# claude-code-hue → wire hook entries into ~/.claude/settings.json.
# Shows a diff before changing anything. User confirms with y/N.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/hue_hook.sh"
SETTINGS="$HOME/.claude/settings.json"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; }

if [ ! -x "$HOOK" ]; then
  fail "hue_hook.sh not found or not executable at $HOOK"
  echo "  did you run setup.sh first? did you chmod +x the scripts?"
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/hue_config.sh" ]; then
  fail "hue_config.sh missing — run: bash setup.sh"
  exit 1
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

# Backup
BACKUP="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

# Compute proposed merge with python3
PROPOSED=$(HOOK_PATH="$HOOK" python3 - "$SETTINGS" <<'PY'
import json, os, sys

settings_path = sys.argv[1]
hook = os.environ['HOOK_PATH']

with open(settings_path) as f:
    cfg = json.load(f)

cfg.setdefault('hooks', {})
hooks = cfg['hooks']

ENTRIES = {
    'SessionStart':     f'{hook} idle',
    'UserPromptSubmit': f'{hook} working',
    'PreToolUse':       f'{hook} working',
    'Stop':             f'{hook} idle',
    'SessionEnd':       f'{hook} off',
}

added = []
for event, command in ENTRIES.items():
    arr = hooks.setdefault(event, [])
    # Skip if already present (idempotent re-run)
    already = any(
        any(h.get('command') == command for h in entry.get('hooks', []))
        for entry in arr
    )
    if not already:
        arr.append({'hooks': [{'type': 'command', 'command': command}]})
        added.append(event)

print('---ADDED---')
print('\n'.join(added) if added else '(nothing — all hooks already wired)')
print('---SETTINGS---')
print(json.dumps(cfg, indent=2))
PY
)

ADDED=$(printf '%s' "$PROPOSED" | sed -n '/^---ADDED---$/,/^---SETTINGS---$/p' | sed '1d;$d')
NEW_JSON=$(printf '%s' "$PROPOSED" | sed -n '/^---SETTINGS---$/,$p' | sed '1d')

bold "Proposed additions to $SETTINGS:"
echo "$ADDED" | sed 's/^/  + /'
echo
read -r -p "Apply these changes? [y/N] " ANSWER
case "$ANSWER" in
  [yY]*)
    printf '%s\n' "$NEW_JSON" > "$SETTINGS"
    ok "Updated $SETTINGS"
    echo "  Backup: $BACKUP"
    echo
    bold "Restart Claude Code for the new hooks to take effect."
    ;;
  *)
    rm -f "$BACKUP"
    echo "Aborted. Settings unchanged."
    echo
    bold "If you'd rather paste the snippet manually, here it is:"
    echo
    HOOK_PATH="$HOOK" python3 - <<'PY'
import json, os
hook = os.environ['HOOK_PATH']
ENTRIES = {
    'SessionStart':     f'{hook} idle',
    'UserPromptSubmit': f'{hook} working',
    'PreToolUse':       f'{hook} working',
    'Stop':             f'{hook} idle',
    'SessionEnd':       f'{hook} off',
}
snippet = {
    'hooks': {
        event: [{'hooks': [{'type': 'command', 'command': cmd}]}]
        for event, cmd in ENTRIES.items()
    }
}
print(json.dumps(snippet, indent=2))
PY
    ;;
esac
