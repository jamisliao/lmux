# lmux App

One window: a SwiftUI sidebar of workspaces, each workspace a split tree of libghostty
surfaces (AppKit). SwiftUI is only in the sidebar and titlebar buttons, never in the
terminal path; no WebKit.

**Build from source**: `App/Frameworks/GhosttyKit.xcframework` links into `vendor/ghostty`, which a fresh
checkout doesn't have. `scripts/bootstrap.sh` clones Ghostty at the commit in `GHOSTTY_COMMIT`, fetches Zig
0.17.0 into `.tools/` (sha256 checked) and builds the xcframework (`--dry-run` prints the plan). Then:

```sh
# set DEVELOPER_DIR if your Xcode isn't the selected one (xcode-select -p), e.g.
# export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
scripts/bootstrap.sh             # once: vendor/ghostty at GHOSTTY_COMMIT, Zig, GhosttyKit.xcframework
App/scripts/bundle.sh            # release build -> App/build/lmux.app (+ bin/lmux, bin/lmux-hook, icon)
open App/build/lmux.app          # run it
App/scripts/apptest.sh           # app harness, headless: workspaces, splits, focus, hooks, CLI, persistence,
                                 #   + a fresh process with a 50MB transcript (memory budget) and key->pty latency
                                 #   + --compat: real programs off the happy path (wide text, 2M lines, binary garbage,
                                 #   title/bell/OSC storms, kitty keys, mouse, 10MB paste, resize storms, vim/less/top,
                                 #   malformed hooks, corrupted layout.json / settings.plist)
App/scripts/apptest.sh --quick   # main pass only (~1 min); scripts/install-git-hooks.sh (opt-in) runs it
                                 #   + Core swift test before every git push
App/scripts/apptest.sh --screenshots DIR   # + DIR/p1-*.png, DIR/p2-*.png, dark and light (offscreen render)
App/scripts/apptest.sh --real-window [DIR] # CI ONLY (refuses unless GITHUB_ACTIONS=true): VISIBLE window driven by real
                                 #   CGEvents: window drag, traffic lights, titlebar buttons, divider/sidebar/window
                                 #   resize, clicks where overlays were, 200 seeded random steps (LMUX_RW_SEED,
                                 #   LMUX_RW_STEPS), idle CPU + display-link threads; screenshots into DIR
App/scripts/e2etest.sh           # message actions on the real Claude Code binary, offline (temp HOME and config,
                                 #   mock API that logs what Claude sends): ✎, × (incl. a turn that wrote a file),
                                 #   ⌘Z while working and after the reply, Copy original; one claude process throughout
App/scripts/imetest.sh           # IME/font/theme checklist, headless (no window, no focus)
App/scripts/imetest.sh --visible # + same checks against the REAL Korean IME (takes focus,
                                 #   switches the input source temporarily)
App/scripts/measure_idle.sh 20            # idle CPU / RSS, 1 pane, headless (exit 1 if CPU >= 1% or RSS >= 300MB)
App/scripts/measure_idle.sh 20 10 2       # 10 panes as 5 workspaces x 2
App/scripts/perf_budget.py [scenario…]    # budgets, headless, on the bundle: idle 20x2, footprint (GPU included), running agents, CPU per
                                          #   hook event, spinner titles, hidden-pane memory, restore 120, History index peak
App/scripts/make-fonts.py assets/fonts/D2Coding-Ver1.3.3-20260725-all.ttc App/Resources/Fonts
                                 # bundled WOFFs from the upstream .ttc; if that file is missing (public repo),
                                 #   the pinned official release zip is downloaded and checked (sha256)
App/scripts/readme.sh            # README hero PNGs + GIFs, offscreen from the real app (fixture sessions
                                 #   replayed by scripts/readme/claude, temp HOME, no model calls)
App/scripts/readme.sh hero       # site hero video (2000 px, H.264 CRF 21 / VP9 CRF 33), posters and the
                                 #   README's animated hero (readme/hero.sh, needs ffmpeg)
```

## Layout

| Target | What |
|---|---|
| `LmuxTerminal` | libghostty runtime + `SurfaceView` (adapted from Ghostty, MIT) |
| `LmuxTokens` | design tokens (`design/Tokens.swift` is a symlink to it) |
| `LmuxUI` | window, sidebar, workspaces/splits, focus, agent awareness, persistence, CLI socket, hooks onboarding |
| `lmux` | the app (`main.swift` only) |
| `lmux-cli` | the `lmux` command, bundled as `Contents/Resources/bin/lmux` (on PATH inside panes) |
| `lmux-apptest`, `lmux-imetest` | headless harnesses |

`lmux-hook` comes from `Core` and is bundled next to the CLI.

## Behavior

- **Shortcuts** (Ghostty `keybind` config wins; menus show the bound key): ⌘N new workspace, ⌘D / ⇧⌘D split
  right / down, ⌘W close pane, ⇧⌘W close workspace, ⌘1–8 workspace (⌘9 last), ⇧⌘[ ⇧⌘] prev/next workspace,
  ⌘[ ⌘] / ⌥⌘arrows move between panes, ⌃⌘arrows resize, ⌃⌘= equalize, ⇧⌘↩ zoom split (View → Zoom Split,
  Ghostty's `toggle_split_zoom`: the focused pane fills the workspace and the others stop rendering; closing or
  splitting while zoomed unzooms first; each workspace's zoom is saved in `layout.json` and comes back on relaunch).
  lmux's own: **⇧⌘J next pane that needs input** (cycles; Ghostty's default ⇧⌘J binding is unbound unless your
  config binds it), ⇧⌘U latest unread (= bell), ⌃⌘S sidebar,
  ⌥⌘C copy Claude's last reply as markdown, ⌘Z undo send (while the toast is up; Ghostty's `undo` routes here).
  Ghostty's own: ⌘F find in scrollback (⌘G / ⇧⌘G next / previous, esc closes), Secure Keyboard Entry (app menu).
  With a non-Latin input source (Korean 2-Set: ⌃⌘S arrives as ㄴ), a ⌘/⌃ key the menus miss is retried as the
  ASCII-capable layout types it. Help menu: Keyboard Shortcuts (README#usage), Report an Issue….
- **Sidebar rows**: press-and-drag past a small threshold reorders (the row lifts and follows the pointer, the others
  slide out of the way and it springs into its slot on drop, instant under Reduce Motion; a row inside a
  multi-selection moves the whole selection in order; Esc springs it back; auto-scroll near the edges), saved to
  `layout.json`, so ⌘1–8 follow it. The row menu has **Clear Status** (resets the badge and ring of every pane in
  the workspace, or the selection, to idle without touching the processes; the next hook updates it again);
  VoiceOver gets Move Up / Move Down.
- **Focus (R6)**: any click on a pane (terminal or header) focuses it; after any click the keyboard is
  always on a visible pane of the selected workspace (never the sidebar, never a hidden pane).
- **Agent state (R13-R15)**: each pane gets `LMUX_PANE_ID`, `LMUX_SOCKET` (hooks) and `LMUX_CONTROL_SOCKET`
  (CLI). Hook events drive `PaneAgent` per pane -> row state (running = neutral spinner, needs input = frost
  dot + ring on the pane, done = check, failed = x), unread badges, bell count. A pane is bound to its first live
  top-level session: lmux-hook reports the claude that ran it (pid, process group, its ancestors' groups), and a
  `claude -p` started inside it (Claude's Bash tool) is in another group with the pane's claude among its ancestors,
  so its events never change the pane's session, state or title. `/clear`, `/resume` and a new claude after quitting
  rebind it (SessionStart from the pane's foreground claude). System notifications are posted
  only from the state machine's `notify` decision (never for the focused pane). Typing into a pane clears its
  needs-input. Claude sends no hook when Esc / ⌃C interrupts a turn, so the key arms one look at ~0.3 s (and, if
  needed, ~1.2 s) at the transcript's newly appended tail: the `[Request interrupted by user…]` marker, or Claude's
  terminal title back to `✳` (Esc before any reply writes no marker) -> `PaneAgent.userInterrupted()`, idle with no
  alert, notification or unread. A hook arriving first cancels the look; an Esc that stopped nothing leaves the pane
  running; nothing runs without the key (no polling). Codex panes are skipped: Codex sends its own `Interrupt` hook.
  **Hooks hint**: a pane whose `claude` has run ~10 s with no hook ever heard (armed by a title change or Return,
  one deferred check) gets one passive card. Which one is decided from where the hooks are and the config dir this
  claude uses (every running Claude Code keeps `<config dir>/sessions/<pid>.json`; `~/.claude*` and
  `~/.config/claude*` are the candidates): not installed (Install Hooks…), another `CLAUDE_CONFIG_DIR` (Install
  There… / Choose Folder…), or started before the install (restart it). OSC 9/777 desktop notifications only update the row text.
  **Known limitation: a wrapped claude** (`script -q log claude`, or claude inside tmux/screen running in a pane)
  gets every hook ignored, so that pane shows no agent state. The wrapper is the pane's foreground process and claude
  runs in its own session on the wrapper's pty, which looks the same to lmux as a claude that isn't the pane's.
  Deciding by claude's controlling tty instead of the foreground group wouldn't change that: script and tmux give
  claude a pty of their own, never the pane's. Run claude directly in the pane.
- **Persistence (R11)**: `layout.json` (workspaces, split tree + ratios, cwd, titles, accents, Claude session
  per pane) in the state dir, saved 1s after a change and on quit. At SessionStart lmux captures how that claude was
  started (`ClaudeCommand`: argv minus prompt / `-p` / `--resume` / `--continue` / `--session-id`, multi-value flags
  such as `--add-dir a b` kept whole) and, apart from it, the claude's environment limited to an explicit allowlist
  of non-secret settings (`HookClient.replayableNames`: CLAUDE_CONFIG_DIR, model names, timeouts, Bedrock/Vertex
  switch; any name matching KEY|TOKEN|SECRET|PASS|AUTH|HEADER|COOKIE|CREDENTIAL|URL|CERT is refused). Restore types
  the command, ending in `--resume <id>`, and hands that env to the restored shell's environment (never typed).
  A pane bound without a SessionStart from a process lmux can't read restores as a plain shell. State files are 0600.
  What is typed is checked: the session id must be a UUID; `--settings`, `--mcp-config`, `--system-prompt` and
  `--append-system-prompt` keep only values that look like file paths (inline JSON or text can hold secrets and is
  dropped with its flag); any control character in argv or env falls back to plain ` claude --resume <id>`;
  quoting holds in fish too; restore types with a leading space (kept out of history by zsh HIST_IGNORE_SPACE / bash
  ignorespace). Only a `transcript_path` shaped like `<config>/projects/<dir>/<uuid>.jsonl` (a regular file of this
  user) is read or carried over a restart.
  An unreadable `layout.json` (or one malformed split), `settings.plist` or `sessions.db` is kept aside as
  `<name>.bad-<unix time>` (0600) and that part starts fresh; nothing is overwritten unseen.
- **Message actions (R8-R10)**: on a pane running Claude Code, hovering a prompt shows `✎ ×`, hovering a reply
  shows Copy original (AppKit overlay, SF font, never in the grid). Rows are mapped to turns by matching `❯` rows
  against the transcript's prompts bottom-up in turn order (`TurnLocator`), so permission menus, the input box and
  repeated prompts never confuse it. ✎ / × = confirm card (says when later turns go too, that changed files stay;
  refuses compacted turns) -> Claude Code's own rewind in the running claude (`Rewind.swift`), never a restart:
  Esc first if Claude is working; refused if the input holds a draft; Esc Esc; ↑ one entry at a time, reading the
  pane after every key (`RewindMenu.read`: the list's highlighted entry, the confirmation's quoted message and
  numbered options) until the highlighted entry is the turn's prompt (as many identical later prompts passed as
  there are); Return; on the confirmation, ↓ / ↑ to "Restore conversation" (never an option that restores code) and
  Return; then ✎ leaves the prompt Claude put back in the input, × clears it with Esc Esc. Anything unexpected (no
  menu, a list that ends, another message quoted, no such option, a timeout) backs out with Esc and shows "Couldn't
  rewind; use Esc Esc in Claude Code". Keys typed into the pane meanwhile are dropped. Claude writes the new branch
  only with the next prompt, so lmux hides the rewound turns (`Pane.rewoundFrom`) until the transcript's chain no
  longer has them or the next SessionStart. `<state>/forgotten/` backups left by the old transcript-editing Forget
  are still deleted 7 days after they were made.
- **Wrong-session guard (R7)**: a legend on the rule above Claude's input, only with 2+ workspaces: the workspace's
  6pt color chip and its title in tertiary text (it follows Claude's input box on the pane's frames: when the
  renderer draws, lmux checks the cursor and moves the label only if it moved, so an idle Claude or a hidden pane costs
  nothing; hidden on Return until the box is redrawn); a typed
  prompt shows "Sent to … Undo ⌘Z" for 3s, and Undo = Esc if working, then rewind that turn: the first turn with
  that text written after Return was pressed (an older identical "yes" is never taken). Esc before any reply makes
  Claude take the turn back by itself (its text in the input); that counts as the rewind. Enter while an IME has marked
  text (Japanese commit) sends nothing and doesn't count for Undo.
- **Transcripts**: hover actions and titles read each pane's transcript through an incremental `TranscriptIndex`
  (Core) on one background queue: only appended bytes are parsed (inode + tail fingerprint, like the History index),
  memory holds one small record per entry, reply markdown and long prompts are read from the file on demand.
- **Start directory**: a new workspace with no directory given (⌘N, +, the menu, Ghostty's `new_tab` /
  `new_window`, closing the last workspace, `lmux new-workspace` without `--cwd`) starts in Ghostty's
  `working-directory` (an absolute path or `~/…` that exists; `home`, unset or anything else: home). It inherits the
  focused pane's directory only when the config asks: `working-directory = inherit`, or
  `window-inherit-working-directory` / `tab-inherit-working-directory = true` set explicitly (Ghostty's default for
  those is true; lmux's default when unset is home). Splits inherit the pane's directory unless
  `split-inherit-working-directory = false` (then `working-directory`). Read with `LmuxConfig.value(of:)` (Ghostty's
  files then lmux's config, `config-file` includes not followed). Restore and the cmux import use saved directories.
- **⌘W**: asks first unless the pane's foreground process is an idle shell.
- **Window**: the red button closes the window, not the sessions: panes keep running, and the Dock icon, ⌘N or a
  second launch bring it back. ⌘Q asks first while a process is running (Ghostty's `confirm-close-surface`);
  SIGTERM / SIGINT / SIGHUP quit the same way without asking, hanging up every pane (no orphaned processes).
  Empty titlebar space drags the window; a double-click there follows System Settings (zoom / minimize / nothing).
  The sidebar / bell / + buttons stay right of the traffic lights whether the sidebar is shown or not.
  A display unplugged, rearranged or woken brings the window back onto a screen (size kept when it fits).
- **Ghostty actions lmux used to drop**: `toggle_fullscreen`, `open_config` (⌘,: the Settings window),
  `prompt_surface_title`, the bell (Dock bounce while lmux isn't frontmost). The View menu has font
  size, Clear Screen and Enter Full Screen; the app menu Settings…, Hide Others, Show All.
- **Pane environment**: lmux drops what it inherited from the process that launched it (CLAUDECODE,
  CLAUDE_CODE_* session markers, CMUX_*, other terminals' TERM_PROGRAM / ITERM_* / KITTY_* / WEZTERM_*, TMUX, a
  foreign GHOSTTY_RESOURCES_DIR) before libghostty starts; libghostty sets TERM / TERM_PROGRAM / COLORTERM as in Ghostty.
- **Korean IME**: the surface's input context doesn't advertise TSM document access, so the first syllable after
  an idle key composes (하이, not ㅎㅏ이; ghostty-org/ghostty#13235), and a key the IME hasn't answered yet never
  sends its own jamo.
- **Titles (R16)**: the session title is the one Claude Code writes into the transcript (`ai-title`; `/rename`
  writes `custom-title`, which locks it like a manual name). lmux reads it through the pane's incremental transcript
  reader off the main thread, at SessionStart and after each Stop (2s debounce), and follows a new one; it never
  calls a model. A rewind reads it again. Row
  titles: manual name, session title, a running command's terminal title, the folder ("Home" for ~), "Terminal";
  status glyphs, path-like titles and a leaked " - Session start" are cleaned, 48 characters max. Double-click a
  pane header or a workspace title (or the context menu) to rename (empty goes back to Claude's title); a manual
  name locks it. Persisted in `layout.json`.
- **History (R12)**: a search field at the bottom of the sidebar (⇧⌘H; hidden while there is no history) that opens
  into the 6 most recent or matching sessions; Esc clears, a second Esc hands the keyboard back. Closed sessions (not open in a pane), Korean full-text search with
  highlighted snippets, click / Enter = resume in a new workspace at the session's cwd (restored from lmux's archive
  first if Claude deleted it). Context menu: Hide, Move to Trash (confirm). The first index runs when History is
  first opened (the field shows as soon as Claude Code has sessions); from then on it is refreshed at launch and after
  Stop/SessionEnd (debounced), never polled. Indexing and archiving run in a short-lived child process
  (`lmux --lmux-index`), so a first index of thousands of sessions never grows the app's memory; it streams each
  transcript line by line and keeps only what the index needs (tool output is skipped). Only sessions at risk
  are archived (LZFSE, files 0600, dirs 0700): last written more than `cleanupPeriodDays - 5` days ago (Claude's
  setting, default 30, read only), or hidden, or moved to the Trash.
- **Codex CLI**: hooks only, never a wrapper. lmux-hook events tagged `codex` drive the same `PaneAgent`: running,
  needs input (a PermissionRequest counts only if the agent doesn't go on within 1 s and approvals aren't
  bypassed, so auto-approved tools, `--yolo` and subagents never notify), done; `Interrupt` -> idle; never failed
  (Codex has no failure event). Restore types `codex resume <id>` with the captured `-m/-s/-a/-p/-c/-C/--add-dir/
  --yolo…` (prompt, images, `--last`, `--worktree` dropped) and replays `CODEX_HOME` through the same env allowlist.
  Titles come from the rollout's `thread_name_updated` (else `session_index.jsonl`); History indexes rollouts next to
  Claude transcripts (only read, never archived); Copy original uses Stop's `last_assistant_message` or the rollout.
  ×, ✎ and ⌘Z undo are refused for Codex panes. If `codex` starts and no hook arrives within 8 s, one note in that
  pane (trust the hooks, or check that hooks are on in Codex), once per launch.
- **Hooks (R17)**: first launch (not headless) shows a sheet (three sample rows, one paragraph, the exact
  `settings.json` diff behind "Show the exact change"); the
  app menu has Install / Uninstall Claude Code Hooks. Install splices lmux's entries into the text (first in each
  event's array, in the file's indentation and line endings), so the diff only adds lines; the original bytes are kept
  in `<state>/hooks-pristine/` (0600) and an uninstall of an untouched file restores them exactly (empty file, `{}`,
  CRLF, `\u` escapes, compact JSON); after Claude rewrote the file, lmux's entries are cut out of the new text.
  Codex's `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`) gets the same treatment, offered after Claude's
  when Codex is on the Mac, except lmux's group is **appended**: Codex keys trust by position, so the user's own
  hooks stay trusted. Codex asks once to trust the new ones ("Trust all and continue"); Settings reads that state
  from `config.toml` and never writes it.
- **Drag & drop, image paste (R18)**: dropped files are inserted as shell-escaped paths (like Ghostty), as a paste;
  an image on the clipboard or dropped (a screenshot) is saved as a temp PNG (0600, pruned after a day) and its path
  pasted, which Claude Code attaches as an image.
- **CLI**: `lmux new-workspace [--cwd DIR] [--cmd CMD]`, `lmux send [--pane ID] TEXT` (`\n` = Return),
  `lmux notify [--title T] TEXT`, `lmux list [--json]` (workspaces, pane ids, titles, cwd, state). Outside lmux the
  CLI talks to `$LMUX_CONTROL_SOCKET`, else the instance of `$LMUX_STATE_DIR`, else the default one. Each pane gets a secret `LMUX_PANE_NONCE` (also still as `LMUX_PANE_TOKEN`, the old name, for one release); from inside a pane, `send` may only
  target that pane (`defaults write dev.lmux.app allowCrossPaneSend -bool true` lifts it, read at each send, no
  relaunch); from outside lmux (no valid token), `send` and `new-workspace --cmd` are refused unless
  `defaults write dev.lmux.app allowExternalSend -bool true` (or `LMUX_ALLOW_EXTERNAL_SEND=1` in lmux's own
  environment, as `scripts/bench.sh` and the test harness do). Both sockets serve only peers of the same uid
  (getpeereid), live in the 0700 state dir (owner-checked at launch), and cap reads (1 MB control, 8 MB hook line)
  and connections. Hook events count only with the pane's `LMUX_PANE_NONCE`, which lmux-hook sends with each one.
  `notify` posts at most one notification per pane per 5s; a burst is coalesced into one with the latest text.
  Without a token, the caller's controlling terminal (socket peer pid -> its tty's foreground group) still names
  the pane. This guards against mistakes (an agent typing into the wrong pane), it is not a security boundary: a
  process that leaves the pane's terminal (`setsid`) counts as outside.

## Environment

- `LMUX_HEADLESS=1`: accessory policy, borderless window off-screen, never activates, no system
  notifications, no onboarding sheet. Requires an explicit `LMUX_STATE_DIR` (automation never touches the real one).
- `LMUX_STATE_DIR`: state dir (default `~/Library/Application Support/lmux`: `layout.json`, `lmux.sock`, `control.sock`).
  It must be owned by you and is kept at 0700 (lmux starts nothing otherwise); state files are 0600.
  If its path is too long for a Unix socket, the sockets go to `/tmp/lmux-<uid>/<hash>` (0700, owner-checked).
- `LMUX_BIN_DIR`, `LMUX_PANE_COMMAND`: test overrides (helper binaries; command run in every pane).
- `LMUX_ALLOW_EXTERNAL_SEND=1` (or `defaults write dev.lmux.app allowExternalSend -bool true`): lets `lmux send`
  and `new-workspace --cmd` work from outside lmux (no pane token); the harnesses and `scripts/bench.sh` set it.
- `CODEX_HOME`: where Codex's `hooks.json`, `config.toml` and sessions are (default `~/.codex`).
- `LMUX_CLAUDE_PROJECTS`: projects dir History reads (default `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`).
  Its index (`sessions.db`) and archive live in the state dir.
- `LMUX_APPEARANCE=dark|light`, `LMUX_SNAPSHOT=out.png`: force appearance; render the window to a PNG and quit.
- Headless only: `LMUX_WINDOW_SIZE=1728x1080` (window size in points, default 1280x800) and
  `LMUX_HEADLESS_BACKGROUND=1` (the window counts as not key, like lmux behind another app: no pane is
  focused, so no cursor blinks and idle panes release their GPU memory), for memory budgets.
- GPU memory: an unfocused pane that hasn't drawn for 3 s releases its render resources and Metal command
  queue (`scripts/ghostty.patch`); once every pane is idle, Metal frees its per-process driver memory
  (~115 MB on Apple silicon). A pane only has focus while the window is key (as in Ghostty), so in the
  background everything goes idle; the focused pane keeps its resources, the others rebuild in ~3 ms.
  `bundle.sh` checks the shipped TTF fonts register with CoreText (`App/scripts/check-fonts.swift`).
- Fonts: D2Coding Regular + Bold are kept in the repo as WOFF (4.3MB, half the upstream .ttc) and
  bundled as TTF (`bundle.sh` unpacks them, tables unchanged: CoreText maps a TTF, but inflates a
  WOFF into ~33MB of heap) in `lmux.app/Contents/Resources/Fonts`, registered per process.
  Korean system language (first launch, persisted as `defaultFontProfile`) → `font-family = D2Coding`;
  otherwise Ghostty's default (JetBrains Mono). Hangul always maps to D2Coding unless the user maps it.
- Theme: `light:Nord Light,dark:Nord`, 14 x 10pt window padding and `unfocused-split-opacity = 1` (no dimming)
  unless the user's Ghostty config sets them.
- Manual IME checklist: `IME_CHECKLIST.md`. Licenses: `THIRD_PARTY_NOTICES.md`.

## Before release

Automated: `apptest.sh` (headless), `imetest.sh` (+ `--visible` real Korean IME on CI), `apptest.sh --real-window`
(CI), Core `swift test`. What CI can't reach is checked by hand on a real Mac, in a fresh user account if possible:

- [ ] Drag the **screenshot floating thumbnail** onto a pane running `claude`: `[Image #1]` (file promise). Drag one
      onto a plain shell: its path is inserted. During the drag only the pane outline highlights, no preview panel.
- [ ] Drag an image from Safari / Chrome onto `claude`: attached as an image (private temp PNG, not the URL).
- [ ] ⌃⇧⌘4 → clipboard, then ⌘V in `claude`: `[Image #1]`. ⌃V in `claude` (Claude reads the clipboard itself) also works.
- [ ] Copy an image in Preview and a file in Finder, ⌘V each in `claude` and in zsh.
- [ ] Korean 2-Set: type 하이 / 안녕하세요 right after launch, after the hooks sheet, after switching apps, in zsh
      and in `claude`. Japanese Romaji: type and convert a word.
- [ ] Two displays: move the window across, unplug the one it's on, plug it back; click and type after each.
- [ ] Display sleep / wake, and a live dark ↔ light switch with `claude` open (its colors follow with `theme: auto`).
- [ ] Stage Manager on: drag the window, switch stages, click and type.
- [ ] Trackpad: momentum scroll in scrollback, in `less` and in `vim` (mouse on); pinch does nothing harmful.
- [ ] ⌘-click a URL opens it; the pointer turns into a hand over links.
- [ ] `vim` (Esc, :wq, mouse), `htop`, `less`, `man ls`, `tmux` in a pane; resize the window while each runs.
- [ ] `yes | head -n 2000000`: the app stays responsive, typing works right after, idle CPU returns under 1%.
- [ ] Launch lmux in the background (`open -g`) on first run: the hooks sheet appears once the window comes forward.
- [ ] Quit with `claude` running (⌘Q asks), `kill <pid>` (no `claude` left: `pgrep -lf claude`), relaunch restores.
