# Features

Everything lmux does, in one page. For the short version, see the [README](../README.md); for GIFs, see [the tour](tour.md). The full docs, page by page, are at [lmux.dev/docs](https://lmux.dev/docs/).

## Light

- A 25 MB app on libghostty. Native Swift, no browser engine, no Electron, about ten settings.
- Windows that are hidden, minimized or covered stop drawing. Nothing animates unless it means something, and what does animate runs on Core Animation, off the main thread.
- CI fails any change that pushes idle CPU over budget, both with idle shells and with agents running. Busy cases have budgets too: agents working in hidden panes, hook events, spinner titles, restoring 120 workspaces and History's first index.
- Numbers and methodology: [scripts/BENCH.md](../scripts/BENCH.md).

## Bring your cmux setup

On first launch, if cmux is on your Mac, lmux shows what it found ("Theme, font, 12 shortcuts and 5 open workspaces") and one button: **Bring over my cmux setup** (or press Return). Nothing is imported until you click it, and cmux's own files are never changed. The same sheet is under **lmux → Import from cmux…**.

- theme, fonts (Nerd Font fallbacks included), shortcuts, appearance and notifications
- your open workspaces (from every cmux window) with their names, colors, directories, splits and Claude Code / Codex sessions, which resume where they were

The empty shell lmux opened on first launch steps aside so your cmux workspaces start at the top (only if you haven't typed in it).

**Choose what to import…** shows a checkbox per part if you want only some of it. Afterwards the sheet says what came over and, in one line, what lmux doesn't have (the browser, SSH workspaces…), so nothing disappears silently.

Changed your mind? **Undo Import** (in the sheet, and as **lmux → Undo cmux Import** until you quit) puts `~/.config/lmux/config` back exactly as it was, restores lmux's settings and closes the imported workspaces. Any you've changed since (split, renamed) stay open.

## Workspaces and splits

- Workspaces in the sidebar with branch and directory. Hover a row and `×` closes it; `⌘`-click or `⇧`-click picks several.
- Press-and-drag a row to reorder it (a small threshold keeps clicks, multi-select and rename working); dragging a row that's part of a selection moves the whole selection, in order. Esc cancels. The order is saved and `⌘1`–`⌘8` follow it.
- Splits in any direction, `⌘[` / `⌘]` to move between panes.
- A new workspace (`⌘N`, `+`, the menu) starts in your home folder, or in Ghostty's `working-directory` if you set it (a path, `~/…`, or `home`). To start it in the focused pane's folder instead, set `working-directory = inherit` or `window-inherit-working-directory = true` in your Ghostty config. Ghostty itself inherits by default; lmux doesn't unless you say so. A split starts in its pane's folder, unless you set `split-inherit-working-directory = false`. A relaunch brings every pane back in its own folder either way.
- `⇧⌘↩` (**View → Zoom Split**) maximizes the focused pane within its workspace; the rest stop rendering until you toggle it back. Closing or splitting while zoomed unzooms first. A relaunch brings each workspace back zoomed as you left it.
- Your `~/.config/ghostty/config` is read, and a `keybind` there wins over lmux's defaults.
- Unplug or rearrange displays and the window comes back onto a screen, keeping its size when it fits.

## Tabs

Every pane has a tab bar, and each tab is its own terminal. It looks and works like cmux's.

- `⌘T` opens a tab right after the one you're on. So does the terminal button at the right end of the bar, or a double-click on its empty part; the two buttons next to it split the pane right and down.
- `⇧⌘[` / `⇧⌘]` (or `⌃⇧⇥` / `⌃⇥`) switch tabs, `⌃1`–`⌃8` pick one by its place, `⌃9` the last. `⌥⇧⌘[` / `⌥⇧⌘]` move the tab. Workspaces moved to `⌃⌘[` / `⌃⌘]`, as in cmux; `⌘1`–`⌘9` still pick one.
- Drag a tab to reorder it. Drop it on another pane's bar to move it there, on the middle of a pane to add it to that pane's tabs, or near a pane's edge to split that pane with the tab on that side.
- `⌘W`, the tab's `×` or a middle-click closes the tab; it asks first unless the tab is an idle shell. The tab to its right comes forward, or the one to its left if it was the last. Closing a pane's last tab closes the pane. Double-click a tab to zoom its pane.
- Right-click a tab for the rest, in cmux's order: Rename Tab… (`⌘R`), Close Tabs to Left / Right, Close Other Tabs (`⌥⌘T`), Move Tab (to a new workspace or another one, or the pane beside it), Pin Tab and Mark Tab as Unread.
- A pinned tab sits at the front of the bar with a pin instead of `×`, and nothing closes it until you unpin it: `×`, middle-click and `⌘W` beep, Close Others skips it.
- A tab that needs you, or has an alert you haven't seen, gets a blue dot where its `×` goes; the workspace's row shows the state of all its tabs, and `⇧⌘J` or a notification brings the right tab to the front. In bypass or auto mode the shown tab's bar carries the **bypass** / **auto** badge.
- Tabs you can't see don't render, like a hidden workspace's panes. They keep running, and after a relaunch they come back in order, pinned ones still pinned, with the one you were on in front.
- The bar shows on every pane, one tab or more (cmux's default). To show it only once a pane has two tabs, turn off **Settings → Appearance → Tab bar on panes with one tab**; split panes then get a plain title bar.
- `lmux new-tab` opens a tab from a script, and `lmux list` shows each tab with its place (`tab 2/3`). See [the CLI](https://lmux.dev/docs/cli/).

## Agent status

- Running, needs you, done or failed, straight from Claude Code's hooks, and for Codex from what Codex itself reports in its terminal (plus its hooks for the session).
- Stopping Codex yourself (Esc) just sets the row back to idle, no alert.
- With Codex, lmux notifies only when Codex is really waiting for you (an approval it asks you for) and when a turn ends. Auto-approved commands, `--yolo` runs and subagents never ping you.
- A ring on the pane and a badge on the row when an agent needs you. `⇧⌘J` jumps to it.
- Stop Claude Code with Esc or `⌃C` and its row goes idle within about a second: no alert, no notification, no done ✓. Claude sends no hook when it's interrupted, so lmux takes one look at what Claude just wrote to its transcript when you press the key (nothing polls). Esc that only closed a menu leaves the row running.
- One notification per event (plus an optional reminder if you turn it on), never one per subagent. The bell keeps the last 50.
- While Claude runs subagents, the row counts them ("3 subagents"). In bypass permissions or auto mode (Codex: `--yolo`), the pane's tab bar (or header) shows a small **bypass** or **auto** badge.
- A usage limit isn't a failure: the row shows a still clock and "waiting for usage limit · resets 3pm", since Claude Code continues by itself once it resets. If it won't, or still hasn't 15 minutes after the reset, you get the usual done alert.
- A running row with no hook event and no output for ten minutes says "no output for 12m", hidden panes included. Just a hint: new output clears it within a minute.
- A row that's been done or waiting for three minutes while you looked elsewhere breathes (its check dims and brightens with a soft accent glow behind it) until you come back. Pick the delay or turn it off in Settings; with Reduce Motion on it gets a still ring instead.
- If a hook gets missed, a row's **Clear Status** (right-click, works on a multi-selection too) resets its badge and ring to idle by hand, without touching the agent process; the next hook event updates it normally again.
- If a `claude` has been running in a pane for about ten seconds and lmux has heard no hook from it, that pane gets one calm card saying so, with the likely reason and a button: the hooks aren't installed, they're in `~/.claude` while this `claude` uses another `CLAUDE_CONFIG_DIR` (**Install There…** or **Choose Folder…**), or this `claude` started before you installed them (restart it). Once a hook arrives from a pane, it never asks again.

## Undo for the wrong session

Hover any turn of a Claude session:

- `⧉` copies the original markdown, not terminal soup. `⌥⌘C` does the same for the last reply.
- `×` rewinds to just before that prompt: that turn and everything after it are gone from the conversation. The session keeps running; lmux drives Claude Code's own rewind (Esc Esc), so background shells and MCP servers aren't touched. Files changed in those turns stay as they are.
- `✎` does the same rewind and puts the prompt back in the input to edit.

Sent to the wrong one? `⌘Z` while the "Sent to …" toast is up.

With Codex, `⧉` and `⌥⌘C` work the same. `×`, `✎` and `⌘Z` undo are Claude Code only, so a Codex turn shows just `⧉`.

A `!` shell command shows just `⧉` too. Rewinding to one would leave Claude Code's input stuck in shell mode.

## Sessions

- **Restart and pick up where you left off.** Quit lmux (for an update, say) and it reopens the same workspaces, splits, directories and window, and every Claude session resumes with the flags it was started with. A Codex session comes back as `codex resume <id>` with its model, sandbox, approval, profile and `-c` flags.
- **Your shell output comes back too.** A plain shell pane shows its last output (up to 2,000 lines, as plain text) above the new prompt, under a dim "restored from your last session" line. lmux saves it only when you quit, in its private state dir (readable only by you), and deletes it once it's shown. Panes in a full-screen program (vim, less, a TUI) or running something, and agent panes that resume, save nothing. Whatever was on screen is saved, so turn it off in **Settings → General → Restore terminal output after relaunch** if that's ever secrets.
- **History** (`⇧⌘H`): every past session is searchable, Korean included, and resumes from any directory with the right CLI. Codex sessions are in there too, marked "Codex".
- Once you've opened History, sessions are quietly archived before Claude Code's cleanup deletes them, so nothing vanishes as long as you open lmux now and then. (Until then lmux doesn't index anything.) Codex keeps its own sessions, so lmux only reads them.
- If a state file (the layout, the History index, settings) is ever unreadable, lmux keeps it aside as `<name>.bad-<time>` and starts that part fresh, instead of writing over it.
- **Session titles from the agent.** Each session shows the title Claude Code gives it (or the name you set with `/rename`), or Codex's own thread name, and follows it when the agent writes a new one. lmux never calls a model for it. Names you type yourself are never touched.

## Codex

Codex CLI gets most of what Claude Code gets, by listening only:

- **Status and notifications**: running, needs you ("Permission: Bash"), done and failed, with the same ring, badge and `⇧⌘J`. They come from Codex itself: its terminal UI reports its state in its own pane (OSC 7501), so each pane's status is that codex's, even when its hooks can't say which pane they're from. lmux takes it only while codex is the pane's foreground program (a codex inside ssh or tmux reports through hooks only). Stopping it with Esc sets the row back to idle with no alert.
- **Sessions from hooks**: resume, History and titles need to know which session runs in which pane, which Codex's hooks tell. Codex runs all sessions on one shared background server by default, whose hooks name the pane that started it, so lmux matches a new session, when it starts a turn, to the pane whose codex started a turn at that moment, and only one to one (two panes prompted in the same second, or a codex outside lmux prompting as a pane's does, stay unmatched rather than mixed up; their status is still right, and the next prompt matches them). A background server started outside lmux sends lmux no hooks: status works, the session isn't remembered for resume (lmux says so once).
- **No floods**: lmux notifies only when Codex is really waiting for you and when a turn ends. Auto-approved commands, `--yolo` runs and subagents never ping you.
- **Resume on restart** as `codex resume <id>`, with its model, sandbox, approval, profile and `-c` flags. cmux's Codex panes come back the same way when you import.
- **Session titles** from Codex's own thread name, **History** (marked "Codex") and **copy as markdown** (`⧉`, `⌥⌘C`).
- **Claude Code only**: edit and resend (`✎`), remove (`×`) and `⌘Z` undo send. A Codex turn shows just `⧉`.

The hooks go in `~/.codex/hooks.json` (or `$CODEX_HOME/hooks.json`), and Codex asks once to trust them; see [below](#never-wraps-claude-or-codex).

## Any agent, and agents driving lmux

- **Any agent, via OSC 7501.** A program that prints its own status, as Codex does, gets the same ring, badge and one notification per wait: `printf '\e]7501;state=blocked:app=my-agent\e\\'`, from `my-agent` itself (a file shown with `cat` can't). Status only, no session. See [any agent](agents.md#any-agent-osc-7501).
- **`lmux wait`.** An agent in one pane can start another in a new workspace (`lmux new-workspace --background --cmd "codex '…'"`, which doesn't switch your screen), block until it's done or needs you (`lmux wait <pane>`, event-driven, no polling), and read its reply. `lmux list --json` names each pane's agent, state and session. There's a Claude Code skill for it; see [lmux for agents](agents.md).

## Korean input

- lmux fixes the cases where upstream Ghostty drops or mangles Hangul while composing: Enter, Shift+Enter, Backspace on the last jamo, Esc, `⌘T` and `⌘V` mid-syllable, and the first jamo committing on its own.
- Shortcuts with `⌃` or `⌥` (`⌃⌘S`, `⌥⌘C`…) work with the Korean input source on, too.
- Hangul renders in D2Coding at exactly two cells, whatever Latin font you use. D2Coding is the default on Korean systems.

## Settings

`⌘,` opens a real Settings window: a gallery of 26 popular themes (Nord by default; Catppuccin, Tokyo Night, Gruvbox, Solarized, Dracula and more), fonts, appearance, notifications and general options.

Your `~/.config/ghostty/config` is read; Settings saves to `~/.config/lmux/config`, which wins for the keys it sets.

**Allow other apps to send input to lmux** (Settings → General, off by default) lets scripts like Raycast or Hammerspoon use `lmux send`, `lmux new-workspace --cmd` and `lmux new-tab --cmd` from outside lmux. Leave it off unless you need it; from inside a pane they always work.

## Never wraps `claude` or `codex`

lmux only listens, through hooks and the files the agents already write. `claude` and `codex` start, run and print exactly as they do without lmux. Before installing the hooks lmux shows the exact diff to your `settings.json` (Claude Code) or `~/.codex/hooks.json` (Codex, or `$CODEX_HOME/hooks.json`); uninstall puts it back byte for byte, and if you edited it since, only lmux's lines come out. lmux adds its Codex hooks after yours, so the hooks you already trusted stay trusted.

**Codex asks once.** Codex runs a new hook only after you trust it: the next time it starts it shows "Hooks need review", and you choose **Trust all and continue**. If you skip it, Codex runs without them and lmux says so in the pane, once.

## Troubleshooting

### Why is Claude's prompt a dark band on a light theme?

Claude Code's own theme defaults to dark, so it paints its prompt row dark whatever your terminal looks like. Run `/theme` in Claude and pick Auto. It then follows lmux's colors, light or dark.

### What does lmux write to disk, and how do I remove it?

Its state dir `~/Library/Application Support/lmux` (layout, settings, the sessions index, the History archive, any `forgotten/` backups left by older versions (deleted after 7 days), `hooks-pristine/`, and between a quit and the next launch `scrollback/`, your shell panes' last output), `~/.config/lmux/config`, and the hooks it adds to `~/.claude/settings.json` (and `~/.codex/hooks.json` if you use Codex). To remove it all: lmux → Uninstall Claude Code Hooks… (and Uninstall Codex Hooks…), delete the app, then delete those two paths and its preferences (`defaults delete dev.lmux.app`: the hooks offer you answered and Secure Keyboard Entry). lmux itself makes no network calls.

### The sidebar never updates for a `claude`

Usually the hooks aren't where that `claude` looks for them. If you export `CLAUDE_CONFIG_DIR` in your shell rc and open lmux from the Dock, lmux installs the hooks into `~/.claude/settings.json` while `claude` reads another folder. lmux notices (a card in the pane: "lmux isn't receiving Claude Code hooks from this pane") and offers to install them in the right one.

### Why does macOS ask lmux for permissions?

Programs you start in a terminal borrow its identity for macOS privacy prompts (Accessibility, Automation, Contacts, Full Disk Access…), so when a script or app you launch from lmux wants one, macOS asks about lmux. That's macOS, and Terminal, iTerm2 and Ghostty work the same way. lmux needs none of these for its own features, so grant only what the program you're running needs, or start that program outside the terminal.

### macOS keeps asking even though lmux is already allowed

macOS remembers a permission together with the app's signature. If an older lmux with a different signature (a build from source, say) was allowed, System Settings still shows lmux as on, but the lmux you run now doesn't match it, so macOS asks again. Reset that entry once and allow it at the next prompt:

```sh
tccutil reset Accessibility dev.lmux.app   # or ScreenCapture, AppleEvents…
```

The same goes for Screen Recording: after switching from a dev build, lmux can keep asking for it although it's ON in System Settings. Reset it and allow it once:

```sh
tccutil reset ScreenCapture dev.lmux.app
```
