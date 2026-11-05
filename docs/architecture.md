# How lmux works

Plain Swift on top of libghostty. Nothing in it is a web page, and nothing runs between you
and `claude`.

## Modules

The agent features live in three small libraries (`Core/`), each usable and tested on its own:

- **hooks** (`LmuxHooks`, `lmux-hook`): turns Claude Code hook events into one honest state
  per pane (running, needs you, done, failed), and installs and uninstalls those hooks cleanly.
  Uninstall puts your `settings.json` back exactly as it was; if you edited it since, only
  lmux's lines come out.
- **transcript** (`LmuxTranscript`): reads Claude Code session files incrementally and pulls
  out the original markdown of a reply.
- **sessions** (`LmuxSessions`): indexes every session with full-text search (Korean too),
  archives the ones Claude Code is about to clean up, and resumes them from anywhere.

The app (`App/`) is two more layers:

- **LmuxTerminal**: libghostty glue. One `SurfaceView` per pane (rendering, keyboard and the
  Korean IME fixes), config loading (lmux defaults → your Ghostty config →
  `~/.config/lmux/config`) and live config reload.
- **LmuxUI**: the window, the sidebar, splits, the hover actions over a turn, cards and
  toasts, History, the bell's notification list, Settings and the cmux import. The sidebar,
  the bell list and Settings are SwiftUI; the terminal path never touches it.

## Listening, not wrapping

lmux never wraps `claude`. It only listens. The hooks it installs run a tiny `lmux-hook`
binary that forwards each event, with the pane it came from, over a Unix socket. Nothing
changes how `claude` starts, which flags it gets or what it prints, so a pane is still just a
shell, and Claude Code works the same with or without lmux.

The rest comes from files Claude Code already writes: the transcript gives the original
markdown for Copy original and the turn under the pointer; the session files give History.
To edit or remove a turn, lmux drives Claude Code's own rewind menu in the running `claude`,
reading the pane after every key, and never edits the transcript.

## Where state lives

- `~/Library/Application Support/lmux/`: `layout.json` (workspaces, splits, which Claude
  session each pane resumes), `settings.plist` (lmux's own settings), `sessions.db` (the
  History index), `archive/` (sessions saved from cleanup), and the sockets.
- `~/.config/lmux/config`: terminal settings in Ghostty syntax (theme, font, size, keybinds),
  written by Settings and the cmux import, loaded after `~/.config/ghostty/config`.
- `~/.claude/settings.json`: only the hook entries, and only when you say yes.

The cmux import only reads cmux's files (its Ghostty config, `settings.json`, defaults and
session) and never writes them.

## Tests that stay out of your way

`App/scripts/apptest.sh` drives the real app headless: the window lives off every display,
is never key, and the app never activates, so it can run while you work. Every pane runs an
isolated zsh (`App/scripts/isolated-shell.sh`: a temp `ZDOTDIR` and `HISTFILE`), so test
commands never land in your `~/.zsh_history`, and the run checks that afterwards. State,
sockets, Claude's config dir, lmux's config file and the cmux files all point at temp
directories. Clipboard work uses a private pasteboard. The real-window run
(`--real-window`) moves the pointer and shows a window, so it only runs on CI.
