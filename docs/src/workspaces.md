# Workspaces & panes

lmux, a macOS terminal for Claude Code and Codex, has one window, a sidebar of workspaces, and splits inside each one. A workspace is what a window is in other terminals. Panes are the parts of a split, and each pane holds one or more terminals as tabs.

## The sidebar

Each row is a workspace, with its title, git branch and folder, and the state of the agents in it: a spinner while one works, a badge when one needs you, a check when it's done, an × when it failed.

- **Select** a row with a click, or `⌘1`–`⌘8` (`⌘9` is the last one). `⌃⌘[` / `⌃⌘]` go to the previous and next.
- **Select several** with `⌘`-click or `⇧`-click. Closing, Clear Status and dragging then act on the whole selection.
- **Hide the sidebar** with `⌃⌘S`.
- **Right-click** a row for Rename Workspace…, Clear Status and Close Workspace.

## New workspaces

`⌘N`, the `+` button and **Workspace → New Workspace** all open a workspace in your home folder, or in Ghostty's `working-directory` if you set it (a path, `~/…`, or `home`).

To start a new workspace in the focused pane's folder instead, set either of these in your Ghostty config:

```
working-directory = inherit
window-inherit-working-directory = true
```

Ghostty itself inherits by default; lmux doesn't unless you say so. See [Configuration](configuration.md#where-new-workspaces-and-splits-start).

## Splits

- `⌘D` splits the focused pane right, `⇧⌘D` splits it down. Splits nest in any direction.
- `⌘[` / `⌘]` (or `⌥⌘` and an arrow) move between panes. `⌃⌘` and an arrow resizes, `⌃⌘=` makes them equal.
- A split starts in its pane's folder, unless you set `split-inherit-working-directory = false`.
- Click anywhere on a pane to focus it. After any click, the keyboard is on a visible pane of the selected workspace, never the sidebar or a hidden pane.

## Tabs

Every pane has a tab bar, and each tab is its own terminal. It works like cmux's.

- `⌘T` opens a tab in the focused pane, right after the one you're on. So does the terminal button at the right end of the tab bar, or double-clicking an empty spot on it. The two buttons next to it split the pane right and down.
- `⇧⌘[` / `⇧⌘]` (or `⌃⇧⇥` / `⌃⇥`) go to the previous and next tab. `⌃1`–`⌃8` pick a tab by its place, `⌃9` the last one. `⌥⇧⌘[` / `⌥⇧⌘]` move the tab left or right.
- Drag a tab to reorder it. Drop it on another pane's tab bar to move it there, on the middle of a pane to add it to that pane's tabs, or near a pane's edge to split that pane with the tab on that side.
- Double-click a tab to zoom its pane. Double-click again, or click the arrows on the tab, to unzoom.
- `⌘W`, the tab's `×` or a middle-click closes the tab. It asks first unless the tab is an idle shell. The tab to its right comes forward, or the one to its left if it was the last. Closing a pane's last tab closes the pane.
- Right-click a tab for the rest, including Rename Tab… (`⌘R`), Close Other Tabs (`⌥⌘T`), Move Tab (to a new workspace or another one), Pin Tab and Mark Tab as Unread.
- A pinned tab moves to the front of the bar, shows a pin instead of `×`, and stays open until you unpin it. Close Other Tabs leaves it alone.
- A tab that needs you, or has an alert you haven't looked at, gets a blue dot where its `×` goes. The workspace's row in the sidebar shows the state of all its tabs, and `⇧⌘J` or a notification brings the right tab to the front.
- Tabs you can't see don't render, like a workspace you're not on. They keep running, and after a relaunch they come back in order, pinned ones still pinned, with the one you were on in front.
- `lmux new-tab` opens a tab from a script, and `lmux list` shows each tab with its place. See [CLI](cli.md).

To show the tab bar only once a pane has two tabs, turn off **Settings → Appearance → Tab bar on panes with one tab**. Split panes then get a plain title bar, and double-clicking it renames the pane.

## Zoom

`⇧⌘↩` (**View → Zoom Split**) makes the focused pane fill its workspace. The other panes stop rendering until you press it again. Closing or splitting while zoomed unzooms first, and a relaunch brings each workspace back zoomed as you left it.

## Reorder

Press and drag a row to move it. The row lifts and follows the pointer and the others slide out of the way. A small threshold keeps clicks, multi-select and rename working, dragging a row that's part of a selection moves the whole selection in order, and Esc cancels. The order is saved, and `⌘1`–`⌘8` follow it.

## Close

- `⌘W` closes the focused tab; closing a pane's last tab closes the pane. It asks first unless the tab is an idle shell.
- `⇧⌘W` closes the workspace. So does the `×` that appears when you hover a row.
- The window's red button closes the window, not your sessions: panes keep running, and the Dock icon, `⌘N` or opening lmux again bring it back.
- `⌘Q` asks first while something is running (Ghostty's `confirm-close-surface`). Settings → General has the switch.

## Rename

Double-click a workspace's title in the sidebar, or use **Rename Workspace…** from the row's menu. Rename a tab with `⌘R` or **Rename Tab…** from its menu. A name you type stays until you clear it; an empty name goes back to the agent's own title. Without a name, a row shows the title Claude Code or Codex gives the session, else the running command's title, else the folder.

## After a relaunch

Quit lmux (for an update, say), or restart your Mac, and it reopens the same workspaces, splits, folders and window.

- Every Claude Code session resumes with the flags it was started with. A Codex session comes back as `codex resume <id>` with its model, sandbox, approval, profile and `-c` flags.
- A plain shell pane shows its last output (up to 2,000 lines, as plain text) above the new prompt, under a dim "restored from your last session" line. lmux saves it only when you quit, privately, and deletes it once shown. Panes running a full-screen program (vim, less, a TUI) or a command, and agent panes that resume, save nothing.
- Running processes don't survive a quit. A long-running command (a build, a dev server) isn't started again; only Claude Code and Codex sessions resume.
- Whatever was on screen is saved, so if that's ever secrets, turn it off in **Settings → General → Restore terminal output after relaunch**.

If a state file (the layout, the History index, settings) is ever unreadable, lmux keeps it aside as `<name>.bad-<time>` and starts that part fresh instead of writing over it.

## Scrollback and find

`⌘F` searches the focused pane's scrollback, `⌘G` / `⇧⌘G` go to the next and previous match, and Esc closes the search. **View → Clear Screen** clears the pane.

## Drag and drop, images

Drop files on a pane and their paths are inserted, shell-escaped, as in Ghostty. Paste or drop an image (a screenshot, say) and lmux saves it as a private temporary PNG and pastes its path, which Claude Code attaches as an image.

## Displays

Unplug or rearrange displays and the window comes back onto a screen, keeping its size when it fits.
