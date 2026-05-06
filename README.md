# claude-code-hue

Turn your Philips Hue lamps into a status indicator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Lamps breathe when Claude is working, glow amber when it's done, switch off when the session ends.

Inspired by [bobek-balinek/claude-lamp](https://github.com/bobek-balinek/claude-lamp), which does the same thing for Moonside lamps over BLE. This is the HTTP/Hue Bridge variant — pure bash, no Python or BLE dependencies.

## What it does

| State | Lamps show | Triggered by |
|---|---|---|
| **Working** | Blue ↔ purple breathing | Prompt submit, tool use (Bash, Read, Write, Edit, Grep, WebFetch, etc.) |
| **Idle** | Solid warm amber | Claude finishes responding, session start, idle prompt |
| **Needs input** | Amber 5s ↔ purple 2s pulsing | Permission request, plan approval, question, notification |
| **Off** | Lamps off | Session end |

Multi-session aware: if you have several Claude Code tabs open, the lamps reflect the highest-priority state across all of them. So one tab idling while another is mid-tool-call still shows the working animation.

## Prerequisites

- macOS or Linux
- `bash`, `curl`, `python3` (for JSON parsing — already on every modern macOS / Linux)
- Philips Hue Bridge v2 on your local network
- 1-2 color-capable Hue bulbs (Extended color light)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed

## Install

```bash
git clone https://github.com/steevka/claude-code-hue.git ~/github/claude-code-hue
cd ~/github/claude-code-hue
chmod +x *.sh
bash setup.sh         # discovers bridge, creates app key, picks lights, writes hue_config.sh
bash install-hooks.sh # adds hook entries to ~/.claude/settings.json (with confirmation)
```

Restart Claude Code. Lamps should respond on the next session start.

## Customization

All knobs live in `hue_config.sh` (created by `setup.sh`, gitignored). Edit it, save it — no restart needed. Live daemons pick up new values on the next state change.

### Change colors

The Hue API uses a 0-65535 color wheel:

| Color | Hue value |
|---|---|
| Red | 0 |
| Orange | 5000 |
| Yellow | 12750 |
| Green | 25500 |
| Teal | 35000 |
| Cyan | 40000 |
| Blue | 46920 |
| Purple | 50000 |
| Pink | 56100 |

Examples:

```bash
# Soft green ↔ blue breathing while working
WORKING_HUE_A=25500
WORKING_HUE_B=46920

# Red flash for needs_input
INPUT_HUE=0
```

> **Tip:** the default working pair (`46920` blue and `50000` purple) sits close together on the wheel for a subtle effect. Spread them further apart for a more dramatic transition.

### Change breathing speed

```bash
# Slower breath: 5s fade, 5s hold
WORKING_FADE_DECISECONDS=50
WORKING_HOLD_SECS=5
```

`*_FADE_DECISECONDS` is in tenths of a second (Hue API native unit). `*_HOLD_SECS` should match — that's how long each color is held before fading to the next.

### The "needs input" attention indicator

Wired by default via the `Notification` hook. The hook fires for permission requests and Claude Code's idle-timeout ("waiting for your input"); we filter the latter out by inspecting the notification message, so only actionable events trigger the lamps.

The visual is deliberately subtle: solid amber base (looks identical to idle most of the time) with a 500ms green flash every 10 seconds. Easy to leave on while you work in another tab.

Tune via `INPUT_FLASH_HUE`, `INPUT_BASE_HOLD_SECS`, `INPUT_FLASH_HOLD_SECS` in `hue_config.sh`.

## Hook coverage

Pattern lifted from [bobek-balinek/claude-lamp](https://github.com/bobek-balinek/claude-lamp). The default install wires:

- `SessionStart` → idle
- `UserPromptSubmit` → working
- `Stop` → idle
- `SessionEnd` → off
- `PreToolUse` per-tool: most tools (Bash, Read, Write, Edit, Grep, etc.) → working; `AskUserQuestion`, `ExitPlanMode` → needs_input
- `PostToolUse` for `AskUserQuestion` → needs_input
- `PermissionRequest` → needs_input
- `Notification` with matchers: `permission_prompt|elicitation_dialog` → needs_input; `idle_prompt` → idle

The Notification matcher is the key trick. Claude Code fires `Notification` for both real attention events (permission, elicitation) and idle-timeout (`idle_prompt`). Routing `idle_prompt` to `idle` (not `needs_input`) keeps the lamps from pulsing every minute you walk away to read a long response.

## Files

```
claude-code-hue/
├── hue_hook.sh          # entry point; called by Claude Code hooks
├── hue_daemon.sh        # animation loop; auto-launched for animated states
├── hue_config.sh        # your config (created by setup.sh, gitignored)
├── hue_config.example.sh # template; copy to hue_config.sh manually if not using setup.sh
├── setup.sh             # interactive bridge discovery + key creation + light picker
├── install-hooks.sh     # merges hook entries into ~/.claude/settings.json
├── reset.sh             # wipe runtime state, kill daemon, return to idle
├── LICENSE
└── README.md
```

Runtime state lives in `/tmp/claude_hue/` — one file per active Claude Code session.

## Troubleshooting

**Lamps don't respond.**
- Confirm `hue_config.sh` exists and has real values (`grep -v paste-your-app-key hue_config.sh`)
- Run `bash hue_hook.sh idle` from the terminal — should make lamps go amber. If that fails, the hooks aren't the problem; the script + bridge connection is.
- Check that hooks were added: `grep claude-code-hue ~/.claude/settings.json`

**Stuck on one color, or phantom "working" pulse when nothing is running.**
- A Claude Code tab closed via Cmd+Q or terminal-close doesn't fire `SessionEnd`, so the session's last state would otherwise hang around.
- The aggregator prunes these automatically: `working` states older than `WORKING_MAX_AGE_SECS` (default 10 min) get dropped on the next hook fire. Lights self-correct as soon as another session triggers any hook event.
- If you want it to clear faster, lower `WORKING_MAX_AGE_SECS` in `hue_config.sh`.
- Last resort if something genuinely goes sideways: `bash reset.sh` (kills daemon, wipes runtime state).

**Pulsing constantly when no prompt is waiting.**
- You probably wired the `Notification` hook. Remove it (see "Enable the needs input pulse" above for context — Claude Code fires `Notification` on idle timeout, not just permission prompts).

**Multiple sessions fighting each other.**
- That shouldn't happen — the hook aggregates across sessions by priority. If it does, check `ls /tmp/claude_hue/` and remove any orphaned state files.

## Uninstall

```bash
# Remove hooks
sed -i.bak '/claude-code-hue/d' ~/.claude/settings.json   # quick + dirty; review the diff
# Or restore the backup install-hooks.sh made: ~/.claude/settings.json.bak.YYYYMMDD-HHMMSS

# Remove the repo
rm -rf ~/github/claude-code-hue
rm -rf /tmp/claude_hue /tmp/claude_hue_state /tmp/claude_hue_daemon.pid
```

## Credits

- Architecture inspired by [bobek-balinek/claude-lamp](https://github.com/bobek-balinek/claude-lamp) — a BLE-based variant for Moonside lamps. If you have a Moonside instead of Hue, go there.
- Hue API docs: [https://developers.meethue.com/develop/get-started-2/](https://developers.meethue.com/develop/get-started-2/)

## License

MIT — see [LICENSE](LICENSE).
