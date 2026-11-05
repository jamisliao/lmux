# Codex

<!-- title: Codex CLI in lmux, a macOS terminal for coding agents · lmux docs -->

Codex CLI gets most of what Claude Code gets in lmux, a light macOS terminal on libghostty, by listening only: status, notifications, resume on restart, session titles, History and copy as markdown.

## Setup

If Codex is on your Mac, lmux offers its hooks right after Claude Code's, the same way: **Show the exact change** shows the diff to `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`) first. lmux adds its group after yours, so the hooks you already trusted stay trusted.

**Codex asks once.** Codex runs a new hook only after you trust it. The next time it starts it shows "Hooks need review": choose **Trust all and continue**. If you skip it, Codex runs without them and lmux says so in the pane, once. Settings → General shows whether they're installed and trusted.

Install, update or uninstall them any time from **lmux → Install Codex Hooks…** / **Uninstall Codex Hooks…** or Settings → General.

## Status, from Codex itself

Running, needs you ("Permission: Bash"), done and failed, with the same ring, badge and `⇧⌘J` as Claude Code. They come from Codex itself: its terminal UI reports its state in its own pane with an escape sequence (OSC 7501), so each pane's status is that codex's own. lmux takes it only while `codex` is the pane's foreground program; a codex inside ssh or tmux reports through hooks only.

Stopping Codex yourself (Esc) just sets the row back to idle, with no alert.

Run Codex with approvals bypassed (`--yolo`) and the pane's tab bar shows a small **bypass** badge, as it does for [Claude Code](claude-code.md#status). A running row that goes ten minutes with no output says so ("no output for 12m").

## Notifications, no floods

lmux notifies only when Codex is really waiting for you (an approval it asks you for) and when a turn ends. Auto-approved commands, `--yolo` runs and subagents never ping you.

## Sessions, from the hooks

Resume, History and titles need to know which session runs in which pane, and Codex's hooks tell lmux that. Codex runs every session on one shared background server by default, whose hooks name the pane that started it, so lmux matches a new session, when it starts a turn, to the pane whose codex started a turn at that moment, and only one to one. Two panes prompted in the same second stay unmatched rather than mixed up: their status is still right, and the next prompt matches them.

A Codex background server started outside lmux sends lmux no hooks. Status still works; the session just isn't remembered for resume, and lmux says so once.

## Resume, titles, History

- **Resume on restart**: quit lmux and each Codex pane comes back as `codex resume <id>`, with its model, sandbox, approval, profile and `-c` flags. cmux's Codex panes come back the same way when you import them.
- **Session titles** come from Codex's own thread name.
- **History** (`⇧⌘H`) lists Codex sessions next to Claude's, marked "Codex". lmux only reads them; Codex keeps its own sessions.
- **Copy as markdown**: hover a reply and press `⧉`, or `⌥⌘C` for the last one.

## Limits

Edit and resend (`✎`), remove (`×`) and `⌘Z` undo send are Claude Code only: they drive Claude Code's rewind menu. A Codex turn shows just `⧉`.
