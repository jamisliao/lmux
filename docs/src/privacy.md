# Privacy & files on disk

lmux, a macOS terminal for Claude Code and Codex, makes no network calls at all: no telemetry, no crash reports, not even an update check (Homebrew does that). Everything it knows stays in a few files on your Mac, listed here with how to remove each one.

## What lmux writes

### Its state folder

`~/Library/Application Support/lmux/`, readable only by you (the folder is 0700, the files 0600):

| file | what it is |
|---|---|
| `layout.json` | your workspaces, splits, folders, titles and which session runs in each pane |
| `settings.plist` | lmux's own settings (see [Configuration](configuration.md#settings)) |
| `sessions.db` | the History index, made once you first open History |
| `archive/` | compressed copies of sessions Claude Code is about to clean up, so History keeps them |
| `forgotten/` | transcript backups from older lmux versions, which edited transcripts to forget a turn; deleted 7 days after they were made |
| `hooks-pristine/` | your hook files as they were before lmux's hooks went in, for an exact uninstall |
| `scrollback/` | your shell panes' last output, only between a quit and the next launch |
| `lmux.sock`, `control.sock` | the sockets the hooks and the CLI talk to |
| `<name>.bad-<time>` | a state file lmux couldn't read, kept aside instead of written over |

### Elsewhere

- `~/.config/lmux/config`: the theme, font and size from Settings, and what a cmux import brings, in Ghostty's syntax.
- `~/Library/Preferences/dev.lmux.app.plist`: macOS preferences, such as **Allow other apps to send input to lmux**.
- Pasted or dropped images, saved as temporary PNGs in your user's temp folder (`lmux-paste`), and removed after a day.

## What lmux changes in your agents' files

- **Hooks**: a few entries in Claude Code's `~/.claude/settings.json` (or the folder your `CLAUDE_CONFIG_DIR` names), and in `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`) if you use Codex. Only after you say yes to a diff you can read, and they come out exactly with **lmux → Uninstall Claude Code Hooks…** and **Uninstall Codex Hooks…**.
- **`✎`, `×` and `⌘Z` undo**: lmux changes no files for these. They drive Claude Code's own rewind menu, so Claude forks the conversation as it does when you rewind by hand, and the turns rewound past stay in the session file. See [Claude Code](claude-code.md#never-wraps-never-edits-a-session).
- **History**: resuming a session Claude Code already deleted puts it back from lmux's archive first. **Move to Trash** on a History result moves that session's file to the Trash.

lmux only reads Codex's sessions; it never changes them.

## Removing it all

1. **lmux → Uninstall Claude Code Hooks…** (and **Uninstall Codex Hooks…**).
2. Delete the app, then the two folders and the preferences:

```sh
rm -rf ~/Library/Application\ Support/lmux ~/.config/lmux
defaults delete dev.lmux.app 2>/dev/null
```

`brew uninstall --zap --cask lmux` deletes the app, the state folder and the preferences in one go; `~/.config/lmux` and the hooks are still yours to remove. See [Install](install.md#uninstalling-cleanly).

## What macOS asks about

lmux needs no privacy permissions for its own features. When macOS asks about lmux (Accessibility, Screen Recording, Full Disk Access…), it's for a program you started in a pane, which borrows the terminal's identity; see [Troubleshooting](troubleshooting.md#why-does-macos-ask-lmux-for-permissions).
