# lmux agent guide

You're an agent helping someone set up lmux. This file is everything you need, in one place. Human docs: https://lmux.dev/docs/

Walk the person through it step by step. Ask before changing any file, show them each command before you run it, and let them click the buttons in lmux themselves.

## What lmux is

- A light, native macOS terminal for living in Claude Code and Codex all day. 25 MB, built on libghostty, idles near 0% CPU.
- One window: a sidebar of **workspaces** (like tabs), each holding one or more **panes** (splits in any direction).
- It shows each agent's state per pane (running, needs you, done, failed), lets the user take back a Claude Code turn, and resumes every Claude Code and Codex session after a relaunch.
- It never wraps `claude` or `codex`. It listens to their hooks and reads the files they already write. `✎`, `×` and `⌘Z` drive Claude Code's own rewind menu in the running `claude`; lmux never edits a transcript.
- No network calls at all: no telemetry, no update check.

## Requirements

- macOS 14 (Sonoma) or later, Apple silicon. Check with `sw_vers -productVersion` and `uname -m` (must print `arm64`).
- Not for Linux or Windows.

## Install

```sh
brew install --cask sooftware/tap/lmux
```

This installs `/Applications/lmux.app` and links the `lmux` CLI onto `PATH`. Without Homebrew: download the .dmg from https://github.com/sooftware/lmux/releases and drag lmux.app to Applications. Inside any lmux pane, `lmux` is always on `PATH`.

Update with `brew upgrade --cask lmux`. Quitting for an update loses nothing: workspaces, splits, folders and agent sessions come back.

## First launch (the user clicks; you explain)

1. **cmux import** (only if cmux is installed): a sheet lists what it found and offers **Bring over my cmux setup**. It imports theme, fonts, shortcuts, appearance, notifications and open workspaces with their Claude Code / Codex sessions. Nothing changes in cmux's files. **Undo Import** reverts it until lmux quits. Not imported (lmux doesn't have them): browser panes, SSH/remote workspaces, custom commands, command palette, sidebar extras (ports, PRs, logs, progress).
2. **Claude Code hooks**: lmux offers to add hooks to `~/.claude/settings.json`. **Show the exact change** shows the diff (it only adds lines). Recommend yes: without hooks there's no agent status. The hooks do nothing outside an lmux pane.
3. **Codex hooks** (only if Codex is installed): same, in `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`). Then the next time `codex` starts it shows "Hooks need review": the user must choose **Trust all and continue**.

All of these stay available later: the lmux app menu (Import from cmux…, Install / Uninstall Claude Code Hooks…, Install / Uninstall Codex Hooks…) and Settings (`⌘,`) → General.

## Verify it works

Ask the user to run `claude` in an lmux pane and send a prompt. The sidebar row should show a spinner, then a check when done. Inside the pane, `lmux list` prints workspaces and panes with each pane's state (`idle`, `running`, `needs input`, `done`, `failed`).

## Daily shortcuts

| action | keys |
|---|---|
| new workspace | `⌘N` |
| split right / down | `⌘D` / `⇧⌘D` |
| close pane / workspace | `⌘W` / `⇧⌘W` |
| switch workspace | `⌘1`–`⌘8`, `⌘9` last, `⇧⌘[` / `⇧⌘]` |
| move between panes | `⌘[` / `⌘]` |
| zoom focused pane | `⇧⌘↩` |
| jump to the agent that needs you | `⇧⌘J` |
| latest unread | `⇧⌘U` |
| History (search past sessions) | `⇧⌘H` |
| copy / edit & resend / remove a turn | hover it, then `⧉` / `✎` / `×` |
| copy last reply as markdown | `⌥⌘C` |
| undo the prompt just sent | `⌘Z` while the "Sent to …" toast is up |
| find in scrollback | `⌘F` |
| toggle sidebar | `⌃⌘S` |
| Settings | `⌘,` |

`✎`, `×` and `⌘Z` undo are Claude Code only.

## Configuration

- lmux reads the user's Ghostty config as is: `~/.config/ghostty/config` (also `config.ghostty`, and `~/Library/Application Support/com.mitchellh.ghostty/config`). Themes, fonts, `keybind`, colors and padding work as in Ghostty.
- lmux's own file, `~/.config/lmux/config` (Ghostty syntax), is loaded last and wins. Settings writes theme, font and size there.
- Defaults when unset: `theme = light:Nord Light,dark:Nord`, window padding 14 x 10, `minimum-contrast = 2` (unreadable text drawn black or white), no dimming of unfocused splits. Font: JetBrains Mono, or D2Coding on Korean systems.
- New workspaces start in home, or in `working-directory` if set. To inherit the focused pane's folder: `working-directory = inherit` or `window-inherit-working-directory = true`. Splits inherit their pane's folder unless `split-inherit-working-directory = false`.
- A `keybind` overrides lmux's defaults. Ghostty actions map onto lmux: `new_window` = new workspace, `new_split:right|down`, `close_surface` = close pane, `close_window` = close workspace, `goto_tab:N`, `next_tab`, `previous_tab`, `goto_split:next|previous`, `toggle_split_zoom`.
- Other settings (about ten) are in Settings and stored in `~/Library/Application Support/lmux/settings.plist`: appearance, sidebar matches terminal background, notification sound, Dock badge, ring on a pane that needs you, reminder delay (default 3 minutes), reminder notification, ask before quitting, restore terminal output after relaunch, allow other apps to send input.

## CLI

```sh
lmux list [--json]                          # workspaces, panes, ids, titles, folders, states
lmux send [--pane ID] "text\n"              # type into a pane; \n = Return; default: this pane
lmux new-workspace [--cwd DIR] [--cmd CMD] [--background]  # prints the new workspace and pane ids
lmux wait ID [--until idle|done|needs-you|any] [--timeout S] [--json]  # block until that agent gets there
lmux notify [--title T] "text"              # a notification for this pane (max 1 per 5 s)
```

- From inside a pane, `send` may only target that same pane. Lift with `defaults write dev.lmux.app allowCrossPaneSend -bool true`.
- From outside lmux, `send` and `new-workspace --cmd` are refused unless Settings → General → **Allow other apps to send input to lmux** is on (`defaults write dev.lmux.app allowExternalSend -bool true`). Don't turn it on unless the user needs it.
- `lmux wait` exits 0 when the target got there, 1 on `--timeout`, 2 when it's gone, 3 on other errors. Always pass `--timeout`. Details and a worked example: https://lmux.dev/docs/cli/ and `docs/agents.md`.
- Any agent can show its status with OSC 7501 (`printf '\e]7501;state=blocked:app=my-agent\e\\'`, printed by `my-agent` itself): https://lmux.dev/docs/any-agent/

## Troubleshooting

- **Claude's prompt is a dark band on a light theme**: in Claude Code run `/theme` and pick Auto.
- **The sidebar never updates for a `claude`**: hooks are usually in the wrong folder. If `CLAUDE_CONFIG_DIR` is exported in the shell rc, lmux (opened from the Dock) installed into `~/.claude`. The pane shows a card after ~10 s with **Install There…** / **Choose Folder…**. A `claude` started before the hooks were installed needs a restart. A `claude` inside `script`, tmux or screen shows no state: run it directly in the pane.
- **Codex shows nothing**: the hooks weren't trusted. Restart `codex` and choose **Trust all and continue**. Inside ssh or tmux, status comes only through hooks.
- **A row is stuck**: right-click it → **Clear Status**.
- **macOS asks lmux for Accessibility, Screen Recording…**: it's for a program run in the pane (programs borrow the terminal's identity). lmux needs none for itself. If it keeps asking although allowed (after a dev build): `tccutil reset Accessibility dev.lmux.app` or `tccutil reset ScreenCapture dev.lmux.app`, then allow once.
- **`lmux: lmux is not running`**: open lmux first.

## Files lmux writes

- `~/Library/Application Support/lmux/` (0700): `layout.json`, `settings.plist`, `sessions.db` (History index), `archive/`, `forgotten/` (backups from older versions' Forget, deleted after 7 days), `hooks-pristine/`, `scrollback/` (between quit and relaunch), sockets.
- `~/.config/lmux/config`, `~/Library/Preferences/dev.lmux.app.plist`, temporary pasted images (`lmux-paste` in the temp folder, removed after a day).
- Hooks in `~/.claude/settings.json` and `~/.codex/hooks.json`.

## Uninstall

1. In lmux: **Uninstall Claude Code Hooks…** and **Uninstall Codex Hooks…** (restores the files exactly if unedited).
2. `brew uninstall --zap --cask lmux` (or move lmux.app to the Trash).
3. `rm -rf ~/Library/Application\ Support/lmux ~/.config/lmux` and `defaults delete dev.lmux.app`.

## Links

- Docs: https://lmux.dev/docs/
- Source and issues: https://github.com/sooftware/lmux
