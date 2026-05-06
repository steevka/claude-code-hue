#!/bin/bash
# claude-code-hue → wire hook entries into ~/.claude/settings.json.
#
# Idempotent: re-running this script removes any existing claude-code-hue
# entries first, then writes the current set. Lets you upgrade without
# accumulating duplicates when we add or change hook coverage.
#
# Other unrelated hooks in your settings.json are left untouched.

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

BACKUP="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$BACKUP"

PROPOSED=$(HOOK_PATH="$HOOK" python3 - "$SETTINGS" <<'PY'
import json, os, sys

settings_path = sys.argv[1]
hook = os.environ['HOOK_PATH']

with open(settings_path) as f:
    cfg = json.load(f)

cfg.setdefault('hooks', {})
hooks = cfg['hooks']

# Tools that mean "Claude is doing work"
WORKING_TOOLS = [
    'Bash', 'Read', 'Write', 'Edit', 'MultiEdit',
    'Glob', 'Grep', 'WebFetch', 'WebSearch',
    'Task', 'NotebookEdit', 'Skill', 'EnterPlanMode',
]
# Tools that mean "Claude is pausing for the user"
INPUT_TOOLS = ['AskUserQuestion', 'ExitPlanMode']

def cmd(state):
    return {'type': 'command', 'command': f'{hook} {state}'}

def entry(state, matcher=None):
    e = {'hooks': [cmd(state)]}
    if matcher:
        e['matcher'] = matcher
    return e

NEW_HOOKS = {
    'SessionStart':     [entry('idle')],
    'UserPromptSubmit': [entry('working')],
    'Stop':             [entry('idle')],
    'SessionEnd':       [entry('off')],
    'PreToolUse':
        [entry('working', t) for t in WORKING_TOOLS] +
        [entry('needs_input', t) for t in INPUT_TOOLS],
    'PostToolUse':      [entry('needs_input', 'AskUserQuestion')],
    'PermissionRequest':[entry('needs_input')],
    'Notification': [
        entry('needs_input', 'permission_prompt|elicitation_dialog'),
        entry('idle',        'idle_prompt'),
    ],
}

# Strip any prior claude-code-hue entries (commands containing the hook path's basename).
# Leaves all unrelated hooks (buddy, caveman, etc.) intact.
def is_ours(entry_):
    for h in entry_.get('hooks', []):
        c = h.get('command', '')
        if 'claude-code-hue' in c or 'hue_hook.sh' in c:
            return True
    return False

removed = 0
for event in list(hooks.keys()):
    before = len(hooks[event])
    hooks[event] = [e for e in hooks[event] if not is_ours(e)]
    removed += before - len(hooks[event])
    if not hooks[event]:
        del hooks[event]

# Add fresh entries
added = 0
for event, entries in NEW_HOOKS.items():
    arr = hooks.setdefault(event, [])
    arr.extend(entries)
    added += len(entries)

print('---SUMMARY---')
print(f'removed: {removed}')
print(f'added: {added}')
print('---SETTINGS---')
print(json.dumps(cfg, indent=2))
PY
)

SUMMARY=$(printf '%s' "$PROPOSED" | sed -n '/^---SUMMARY---$/,/^---SETTINGS---$/p' | sed '1d;$d')
NEW_JSON=$(printf '%s' "$PROPOSED" | sed -n '/^---SETTINGS---$/,$p' | sed '1d')

bold "Proposed changes to $SETTINGS:"
echo "$SUMMARY" | sed 's/^/  /'
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
    ;;
esac
