# claude-code-hue

Turn your Philips Hue lamps into a status indicator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Lamps breathe when Claude is working, glow amber when it's done, switch off when the session ends.

Inspired by [bobek-balinek/claude-lamp](https://github.com/bobek-balinek/claude-lamp), which does the same thing for Moonside lamps over BLE. This is the HTTP/Hue Bridge variant — pure bash, no Python or BLE dependencies.

## What it does

| State | Lamps show | Triggered by |
|---|---|---|
| **Working** | Blue ↔ purple breathing | `UserPromptSubmit`, `PreToolUse` |
| **Idle** | Solid warm amber | `SessionStart`, `Stop` |
| **Needs input** | Amber pulse (off by default) | `Notification` (see Customization) |
| **Off** | Lamps off | `SessionEnd` |

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

### Enable the "needs input" pulse

Disabled by default because Claude Code's `Notification` hook fires on idle-timeout (after ~60s of waiting), which causes constant phantom pulses while you're reading output.

To enable, add this entry to `~/.claude/settings.json` under `hooks`:

```json
"Notification": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "/path/to/claude-code-hue/hue_hook.sh needs_input"
      }
    ]
  }
]
```

## Why these hooks (and not others)

The default install wires `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `Stop`, and `SessionEnd`. We deliberately leave out:

- **`Notification`** — fires on idle timeout in addition to permission prompts, causing phantom pulses
- **`PostToolUse`** — fires on every tool completion, would create chatter against the working animation
- **`SubagentStop`** — fires inside subagent runs that are still part of an active session

The five enabled hooks give a clean working / idle / off cycle with no surprises.

## Files

```
claude-code-hue/
├── hue_hook.sh          # entry point; called by Claude Code hooks
├── hue_daemon.sh        # animation loop; auto-launched for animated states
├── hue_config.sh        # your config (created by setup.sh, gitignored)
├── hue_config.example.sh # template; copy to hue_config.sh manually if not using setup.sh
├── setup.sh             # interactive bridge discovery + key creation + light picker
├── install-hooks.sh     # merges hook entries into ~/.claude/settings.json
├── LICENSE
└── README.md
```

Runtime state lives in `/tmp/claude_hue/` — one file per active Claude Code session.

## Troubleshooting

**Lamps don't respond.**
- Confirm `hue_config.sh` exists and has real values (`grep -v paste-your-app-key hue_config.sh`)
- Run `bash hue_hook.sh idle` from the terminal — should make lamps go amber. If that fails, the hooks aren't the problem; the script + bridge connection is.
- Check that hooks were added: `grep claude-code-hue ~/.claude/settings.json`

**Stuck on one color.**
- Daemon may be running with a stale state. Reset: `~/.claude/hue_hooks/hue_hook.sh off` then a fresh state.
- Or hard reset: `rm -rf /tmp/claude_hue /tmp/claude_hue_state /tmp/claude_hue_daemon.pid`

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
