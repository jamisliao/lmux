# Quick start

lmux is a light macOS terminal for Claude Code and Codex. Its first launch takes a minute: two offers, each with one button, and then it's a terminal.

## First launch

1. **Coming from cmux?** If cmux is on your Mac, lmux first shows what it found ("Theme, font, 12 shortcuts and 5 open workspaces") and one button: **Bring over my cmux setup**. Nothing is imported until you click it, and cmux's own files are never changed. See [Switching from cmux](from-cmux.md).
2. **The Claude Code hooks.** Next lmux offers to install a few Claude Code hooks, which is how it knows what each `claude` is doing. **Show the exact change** shows the diff to your `settings.json` before anything is touched. Say yes.
3. **The Codex hooks**, if Codex CLI is on your Mac: the same offer, with the diff to `~/.codex/hooks.json`. The next time Codex starts it asks once to trust the new hooks: choose **Trust all and continue**.

You can say no to all of it. lmux is then a plain Ghostty-based terminal with a sidebar and splits, and both offers stay in the app menu and in Settings (`⌘,` → General) for later.

## Your first workspace

lmux opens with one workspace in your home folder. A workspace is a row in the sidebar holding one or more panes:

- `⌘N` opens another workspace. `⌘1`–`⌘8` switch between them.
- `⌘D` splits the focused pane right, `⇧⌘D` splits it down. `⌘[` / `⌘]` move between panes.
- `⌘W` closes a pane, `⇧⌘W` the whole workspace.

Run `claude` (or `codex`) in a pane. The row starts telling you what it's doing: a spinner while it works, a ring and a badge when it needs you, a check when it's done.

## Five things to try

1. **Let an agent wait for you.** Start a task in one workspace that will ask for a permission, switch to another, and keep working. When it asks, its row gets a badge and its pane a ring. `⇧⌘J` jumps straight to it.
2. **Take a prompt back.** Send something to the wrong session, then press `⌘Z` while the "Sent to …" toast is up. Or hover an earlier turn and press `×`: Claude rewinds to just before it, and that turn and everything after it are gone. (Claude Code only; see [Claude Code](claude-code.md#rewind-to-a-turn).)
3. **Copy a reply as real markdown.** `⌥⌘C` copies Claude's last reply as the markdown it wrote, not the terminal's wrapped text. Hovering a reply and pressing `⧉` does the same for any reply.
4. **Find last week's session.** `⇧⌘H` opens History. Type a word you remember, press Return, and the session resumes in a new workspace in its own folder.
5. **Quit and come back.** Quit lmux with sessions running, then open it again. The same workspaces, splits and folders come back, and every session resumes.

Next: everything about [workspaces & panes](workspaces.md), or the full list of [shortcuts](shortcuts.md).
