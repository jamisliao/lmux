# Switching from cmux

lmux is a lightweight alternative to cmux that borrows its layout, so the sidebar and splits work the way you're used to. Moving over should feel like setting up a new browser that offers to import everything from Chrome.

## Import

On first launch, if cmux is on your Mac, lmux shows what it found ("Theme, font, 12 shortcuts and 5 open workspaces") and one button: **Bring over my cmux setup** (or press Return). Nothing is imported until you click it, and cmux's own files are never changed. The same sheet is under **lmux → Import from cmux…** and Settings → General.

What comes over:

- your theme, fonts (Nerd Font fallbacks included), shortcuts, appearance and notification settings
- your open workspaces, from every cmux window, with their names, colors, folders and splits
- the Claude Code and Codex sessions in them, which resume where they were

The empty shell lmux opened on first launch steps aside so your cmux workspaces start at the top (only if you haven't typed in it).

**Choose what to import…** shows a checkbox per part if you want only some of it. Afterwards the sheet says what came over and, in one line, what lmux doesn't have, so nothing disappears silently.

## Undo Import

Changed your mind? **Undo Import** (in the sheet, and as **lmux → Undo cmux Import** until you quit) puts `~/.config/lmux/config` back exactly as it was, restores lmux's settings and closes the imported workspaces. Any you've changed since (split, renamed) stay open.

## What isn't supported

lmux leaves these out on purpose. The import tells you which of them you were using:

- browser panes and the browser's settings
- SSH and remote workspaces
- custom commands and automation (lmux has a [small CLI](cli.md) instead)
- the command palette
- sidebar extras: ports, pull requests, logs, progress
- the right sidebar (files), pane flash and a custom sidebar tint
- the telemetry setting (lmux has no telemetry to set)

A browser pane doesn't come over; the rest of its workspace does, including terminal tabs, in order and still pinned.

## What's the same, what's different

- **Shortcuts**: the ones you changed in cmux come over as Ghostty `keybind` lines in `~/.config/lmux/config`. lmux's defaults are in [Shortcuts](shortcuts.md). Tabs use cmux's keys: `⌘T`, `⇧⌘[` / `⇧⌘]`, `⌃1`–`⌃8` (`⌃9` for the last), and `⌃⌘[` / `⌃⌘]` for workspaces.
- **Tabs in a pane** look and work like cmux's: the same tab bar, buttons, drag and drop, and right-click menu, minus the browser and remote items.
- **One window.** lmux has one window; workspaces from all your cmux windows land in its sidebar, in order.
- **Settings**: about ten instead of about two hundred. See [Configuration](configuration.md).
- **Agent status** comes from Claude Code's hooks and from Codex itself, and lmux never wraps either. See [Claude Code](claude-code.md).
- What lmux adds: edit, remove or undo a turn you've already sent, without restarting Claude. The rest is in [lmux vs cmux](vs-cmux.md).

If you rely on what lmux leaves out, cmux is the better fit, and it's a great app.
