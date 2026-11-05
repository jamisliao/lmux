# lmux vs cmux

<!-- description: lmux is a lightweight alternative to cmux: the same sidebar and splits, built on libghostty, in a 25 MB app with about ten settings. Here's when to pick which. -->

lmux is a lightweight alternative to [cmux](https://github.com/manaflow-ai/cmux). I used cmux every day and liked it a lot, but I only ever touched a small part of it. So I wrote a terminal with just that part. If most of your day is Claude Code or Codex in a handful of panes, lmux is probably enough. If you want everything else cmux does, stay with cmux.

## What's the same

- **The layout.** A sidebar of workspaces on the left and your panes on the right.
- **Splits** in any direction, with shortcuts to move between them.
- **Notifications.** The workspace that needs you lights up in the sidebar, and `⇧⌘U` jumps to the latest unread one.
- **libghostty.** Both are native Swift apps on Ghostty's terminal core, and both read your Ghostty config.
- **Your cmux setup.** On first launch lmux offers to bring over your theme, fonts, shortcuts and open workspaces from cmux.

## What's different

| | cmux 0.65.2 | lmux 0.0.102 |
|---|---|---|
| App size | 242 MB | 25 MB |
| Memory, 20 idle workspaces | 661 MB | 99 MB (235 MB frontmost) |
| CPU, 20 idle workspaces | 8.10% | 0.00% (0.10% frontmost) |
| Settings | about 200 | about 10 |
| Browser panes | Yes, and agents can drive them | No |
| SSH workspaces | Yes | No |
| Scripting | A CLI and a socket API for every action | A [small CLI](cli.md): list panes, send input, open a workspace, post a notification |
| Edit, remove or undo a sent turn (`✎`, `×`, `⌘Z`) | No | Yes, in Claude Code |
| Korean input | Input method fixes listed in its [changelog](https://github.com/manaflow-ai/cmux/blob/main/CHANGELOG.md) | Fixes for Enter, Backspace, Esc and shortcuts mid-syllable, and `⌃C` with the Korean input source on ([details](korean-input.md)) |
| Search past sessions | A [Conversations sidebar](https://github.com/manaflow-ai/cmux/pull/13322), in beta | History (`⇧⌘H`) for every past Claude Code and Codex session |

The numbers are medians of 5 runs on an M4 Pro, with 2 live shells per workspace. lmux frees its GPU memory when it's in the background. The screen was locked during the runs, which puts cmux in the background, so compare it with lmux's background numbers. The full table and the method are on [Performance](performance.md).

## When cmux is the better pick

cmux does a lot that lmux leaves out on purpose. If you need any of this, use cmux:

- **A browser next to your terminal.** cmux opens a real browser in a split, and agents can click, fill in forms, run JavaScript and read the console in it. See its [browser automation](https://cmux.com/docs/browser-automation) docs.
- **SSH workspaces.** `cmux ssh user@remote` opens a workspace on another machine and can attach to tmux sessions there ([SSH and remote](https://cmux.com/docs/ssh)).
- **Agents on a Linux box.** Over SSH, or on a [cmux Cloud](https://github.com/manaflow-ai/cmux/pull/10478) machine (in beta), your agents run on Linux while you drive them from your Mac.
- **Your phone.** The cmux iOS app, in beta on TestFlight, attaches to the terminals on your Mac ([iOS docs](https://cmux.com/docs/ios)).
- **Scripting and automation.** cmux's CLI and socket API can do everything the app can, down to reading the screen and taking screenshots ([CLI reference](https://cmux.com/docs/api)).
- **Claude Code teams.** `cmux claude-teams` opens each teammate in its own split, with its own status in the sidebar.
- **The command palette and sidebar extras.** cmux has a command palette, and its sidebar shows ports, pull requests, logs and progress. It also has a right sidebar for files, pane flash and a custom sidebar tint.
- **Knobs.** cmux has about two hundred settings. lmux has about ten.

lmux isn't planning to add any of these. A browser engine or a remote daemon alone would make it a much bigger app.

## Moving over

[Switching from cmux](from-cmux.md) covers the one-click import, what comes over, what doesn't and how to undo it.

## Coming from Ghostty and tmux

Before cmux, I ran Claude Code in Ghostty with tmux. If that's your setup today, lmux should feel familiar.

- **Your Ghostty config works as is.** Themes, fonts, `keybind` lines and the rest behave the same, and any `keybind` you set overrides lmux's defaults. See [Configuration](configuration.md).
- **No prefix key.** Workspaces replace tmux sessions and windows, and splits replace panes. `⌘D` and `⇧⌘D` split, `⌘[` and `⌘]` move between panes, and `⌘1` to `⌘8` pick a workspace. See [Workspaces & panes](workspaces.md).
- **There's no server.** Running processes don't survive a quit the way they do in a detached tmux session. Claude Code and Codex sessions resume on the next launch, and a plain shell shows its last output above a new prompt, but a build or a dev server has to be started again.
- **Don't run `claude` inside tmux in an lmux pane.** lmux can't tell the session belongs to that pane, so you lose its status in the sidebar. If you need processes that outlive the app, keeping tmux for those is fine.

## FAQ

### Is lmux a fork of cmux?

No. It was written from scratch, it's MIT licensed, and there's no cmux code in it.

### Can I keep cmux installed?

Yes. The import only reads cmux's files and never changes them, and **Undo Import** puts lmux back the way it was.

### Will lmux ever get a browser or SSH workspaces?

No. Claude Code can already drive a browser through an MCP server like Playwright, or through Claude in Chrome, and that works the same in any terminal. You can still run `ssh` in an lmux pane. You just don't get cmux's remote workspaces.
