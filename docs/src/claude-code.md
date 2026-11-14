# Claude Code

<!-- title: Running Claude Code in lmux, a macOS terminal for many sessions · lmux docs -->

lmux is a light macOS terminal built for living in Claude Code. It shows which session needs you, lets you take back a turn, and brings every session back after a relaunch, all without wrapping `claude`.

## The hooks

On first launch lmux offers to add a few hooks to Claude Code's `~/.claude/settings.json`. **Show the exact change** shows the diff first, and the diff only adds lines: lmux splices its entries into your file as it is, in its indentation and line endings.

- Each hook runs lmux's small `lmux-hook` helper, and only inside an lmux pane. In any other terminal, or once lmux is deleted, the hook exits without running anything.
- The original file is kept, so **lmux → Uninstall Claude Code Hooks…** puts it back byte for byte. If you edited it since, only lmux's lines come out.
- Install, update or uninstall them any time from **lmux → Install Claude Code Hooks…** or Settings → General.

If `claude` uses another config folder (`CLAUDE_CONFIG_DIR`), lmux notices; see [Troubleshooting](troubleshooting.md#the-sidebar-never-updates-for-a-claude).

## Status

Each pane's state comes straight from Claude Code's hooks:

- **running**: a spinner on the row.
- **needs you**: a permission or a question. A ring on the pane and a badge on the row, and `⇧⌘J` jumps to it (it cycles through every pane that needs you).
- **done**: a check. **failed**: an ×.

The row and header add a few details, and only when there's something to say:

- **Subagents.** While Claude runs subagents, the row's second line counts them on the right ("3 subagents"). Background subagents count too: if Claude ends its turn while some are still working, the row stays running, and the done alert waits until the last one has reported back and Claude is done. Otherwise the count starts over with each turn.
- **Bypass mode.** In bypass permissions or auto mode, the pane's tab bar shows a small **bypass** or **auto** badge for the tab you're looking at. With the tab bar off, the pane's header shows it (with one pane, the header at the top). It never goes on the row. Claude reports its mode with each hook, so after `⇧Tab` the badge changes with your next prompt or Claude's next tool call, before that tool runs.
- **Usage limits.** When Claude hits a usage limit and says when it resets, the row shows a still clock and "waiting for usage limit · resets 3pm" instead of turning failed: Claude Code continues the task by itself once the limit resets. If it won't (it asks you to press Enter), or 15 minutes after the reset time it still hasn't, you get the usual done alert. A plain 429 with no reset time still shows as failed.
- **No output.** A running row with no hook event and no output for ten minutes says "no output for 12m", even when the pane is hidden. It's a hint, not a state: the row stays running, and the next hook clears it at once, new output within a minute.

Stop Claude with Esc or `⌃C` and its row goes idle within about a second, with no alert. Claude sends no hook when it's interrupted, so lmux takes one look at what Claude just wrote to its transcript when you press the key; nothing polls. An Esc that only closed a menu leaves the row running, and so do Esc and `⌃C` while Claude only waits for background subagents: they keep working.

A `claude -p` that Claude itself starts inside the pane (through its Bash tool) never changes the pane's session, state or title.

## Notifications

One notification per event, never one per subagent, and never for the pane you're looking at. The bell in the titlebar keeps the last 50; `⇧⌘U` jumps to the latest unread.

A row that's been done or waiting for three minutes while you looked elsewhere breathes (its check dims and brightens with a soft glow) until you come back. Pick the delay, turn it off, or add a reminder notification in Settings → Notifications. With Reduce Motion on it gets a still ring instead.

If a hook ever gets missed, right-click the row and choose **Clear Status**. It resets the badge and ring to idle without touching the process, and the next hook updates it again.

## Hover a turn

Hover any turn of a Claude session in its pane:

- `⧉` copies the original markdown of a reply, not terminal soup. `⌥⌘C` does the same for the last reply.
- `✎` rewinds to just before that prompt and puts it back in the input for you to edit.
- `×` rewinds to just before that prompt and leaves the input empty.

### Rewind to a turn

`✎` and `×` use Claude Code's own rewind, the menu Esc Esc opens, in the `claude` that's already running. Nothing restarts, so background shells and MCP servers keep running.

1. A card asks first. If it isn't the last turn, the card says the turns after it go too, just as they would in Claude's own rewind menu. Files changed in those turns stay as they are.
2. lmux presses Esc Esc and moves up the menu one message at a time, reading the screen after every key. It only presses Return on the prompt it's looking for, and only picks **Restore conversation**, never an option that restores code.
3. Claude drops that turn and any after it. With `✎` the prompt is back in the input, ready to edit and send. With `×` the input is left empty.

If Claude is working, lmux presses Esc first to stop it. If the input holds text you haven't sent, lmux leaves it alone and does nothing; send or clear it first. If the menu doesn't look the way lmux expects, it backs out with Esc, changes nothing, and shows "Couldn't rewind; use Esc Esc in Claude Code".

You can't take one turn out of the middle and keep the ones after it: Claude Code's rewind only goes back to a point in the conversation, and that's all lmux uses. You can't rewind to a turn Claude has already compacted.

### Undo send

Sent a prompt to the wrong session? A "Sent to …" toast shows for three seconds. Press `⌘Z` while it's up: lmux stops Claude if it started working, rewinds to just before that prompt, and puts it back in the input.

With two or more workspaces, the line above Claude's input shows the workspace's color and title, so you see where a prompt will go before you press Return.

## Never wraps, never edits a session

`claude` starts, runs and prints exactly as it does without lmux. lmux only listens: to the hooks, and to the transcript files Claude Code already writes.

`✎`, `×` and `⌘Z` don't touch those files either. They press keys in Claude's own rewind menu, so the result is what you'd get doing it by hand: Claude forks the conversation, and the turns you rewound past stay in the session file as an unused branch.

## History

`⇧⌘H` opens History, a search field at the bottom of the sidebar. Every past session (not open in a pane) is searchable, Korean included, with highlighted snippets. Return or a click resumes it in a new workspace in its own folder, with the right CLI. Codex sessions are in there too, marked "Codex". Right-click a result to hide it or move it to the Trash.

Claude Code deletes old sessions after `cleanupPeriodDays` (30 by default). Once you've opened History, lmux quietly archives the sessions that are about to go, so nothing vanishes as long as you open lmux now and then. Until you first open History, lmux indexes nothing.

## Session titles

Each row shows the title Claude Code gives the session (or the name you set with `/rename`), and follows it when Claude writes a new one. lmux never calls a model for it. A name you type yourself is never touched.

## After a relaunch

Quit lmux and every Claude session comes back in its pane as `claude … --resume <id>`, with the flags it was started with. Settings that hold secrets (keys, tokens, URLs) are never carried over or typed. See [Workspaces & panes](workspaces.md#after-a-relaunch).

## Limits

- A wrapped `claude` (inside `script`, or inside tmux or screen running in a pane) shows no agent state: lmux can't tell it's the pane's own. Run `claude` directly in the pane.
- If Claude Code's theme is dark, its prompt row is a dark band on a light lmux theme. Run `/theme` in Claude and pick Auto ([more](troubleshooting.md#why-is-claudes-prompt-a-dark-band-on-a-light-theme)).
