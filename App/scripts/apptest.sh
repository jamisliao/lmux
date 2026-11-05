#!/bin/bash
# Headless app harness: workspaces, splits, focus-by-click, hooks -> sidebar ->
# notify decision, CLI, hooks installer, persistence round trip. No window is
# shown, no focus is taken, no system notification is posted, and nothing
# outside a temp dir is written (state dir, sockets and settings.json are temp).
#
#   App/scripts/apptest.sh                  run the checks (panes that run a shell get an isolated zsh:
#                                           temp ZDOTDIR / HISTFILE, see isolated-shell.sh)
#   App/scripts/apptest.sh --quick          only the main pass (no restore / 50MB transcript / latency runs)
#   App/scripts/apptest.sh --rewind         only ✎ × ⌘Z on the fake rewind menu (part of the main pass too)
#   App/scripts/apptest.sh --screenshots D  also write D/p1-dark.png and D/p1-light.png
#   App/scripts/apptest.sh --real-window [SHOTS_DIR]
#                                           CI ONLY (refuses unless GITHUB_ACTIONS=true): a VISIBLE window
#                                           driven by real CGEvents (window drag, traffic lights, titlebar
#                                           buttons, clicks after every overlay, 200 randomized steps)
set -euo pipefail
if [ "${1:-}" = "--real-window" ] && [ "${GITHUB_ACTIONS:-}" != "true" ]; then
  echo "apptest.sh --real-window shows a window and moves the pointer: GitHub Actions only (GITHUB_ACTIONS=true)" >&2
  exit 2
fi
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
cd "$APP_DIR"
swift build --product lmux-apptest >/dev/null
swift build --product lmux-cli >/dev/null
(cd ../Core && swift build --product lmux-hook >/dev/null)
BIN="$(swift build --show-bin-path)"

# Short temp path: Unix socket paths are limited to ~104 bytes.
T="$(mktemp -d /tmp/lmux-apptest.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/sink" "$T/state" "$T/tmp"
# Panes that run a shell get an isolated zsh (temp ZDOTDIR and HISTFILE), never the user's.
source "$APP_DIR/scripts/isolated-shell.sh"
HIST0="$(history_stamp)"
lmux_isolated_shell "$T/shell"
# The harness's own temp files (pasted images, diffs, config snippets) go in the run dir.
ORIG_TMP="${TMPDIR:-/tmp}"
before_tmp="$(ls -d "$ORIG_TMP"/lmux-* 2>/dev/null | sort || true)"
export TMPDIR="$T/tmp"
leftovers() {
  # No lmux-* temp dir from this run may be left behind in the real temp dir.
  local after new
  after="$(ls -d "$ORIG_TMP"/lmux-* 2>/dev/null | sort || true)"
  new="$(comm -13 <(echo "$before_tmp") <(echo "$after") | grep -v '^$' || true)"
  if [ -n "$new" ]; then echo "FAIL  [hygiene] temp dirs left behind: $new"; return 1; fi
  echo "PASS  [hygiene] no temp dirs left behind in $ORIG_TMP"
}
# Every window of this run's processes stays off every display, and none of them is a regular
# (Dock / ⌘Tab) app: the window server is polled every 50 ms for the whole run (window-watch.swift).
WATCH_BIN="$APP_DIR/.build/window-watch"
if [ ! -x "$WATCH_BIN" ] || [ "$APP_DIR/scripts/window-watch.swift" -nt "$WATCH_BIN" ]; then
  xcrun swiftc -O "$APP_DIR/scripts/window-watch.swift" -o "$WATCH_BIN"
fi
if [ "${1:-}" != "--real-window" ]; then
  "$WATCH_BIN" $$ "$T/watch.out" "$T/watch.stop" &
  WATCH=$!
fi
windows_unseen() {
  touch "$T/watch.stop"; wait "$WATCH" 2>/dev/null || true
  if [ -s "$T/watch.out" ]; then
    echo "FAIL  [hygiene] a test window reached a display or a test process was a regular app:"; sed 's/^/      /' "$T/watch.out"
    return 1
  fi
  echo "PASS  [hygiene] no window of this run on any display, no test process in the Dock / ⌘Tab (polled every 50 ms)"
}
history_unchanged() {
  # No pane of this run may have written the user's shell history.
  local now; now="$(history_stamp)"
  if [ "$now" != "$HIST0" ]; then echo "FAIL  [hygiene] ~/.zsh_history changed during the run ($HIST0 -> $now)"; return 1; fi
  echo "PASS  [hygiene] ~/.zsh_history untouched (size/mtime $now)"
}
cp "$BIN/lmux-cli" "$T/bin/lmux"
cp "$(cd ../Core && swift build --show-bin-path)/lmux-hook" "$T/bin/lmux-hook"
cat > "$T/sink.sh" <<'SINK'
#!/bin/sh
# Pane stand-in: raw pty, everything the terminal writes lands in a file named by LMUX_PANE_ID.
stty raw echo
: > "$LMUX_SINK_DIR/$LMUX_PANE_ID.bin"
env > "$LMUX_SINK_DIR/$LMUX_PANE_ID.env"
touch "$LMUX_SINK_DIR/$LMUX_PANE_ID.ready"
exec /bin/cat > "$LMUX_SINK_DIR/$LMUX_PANE_ID.bin"
SINK
chmod +x "$T/sink.sh"

export LMUX_HEADLESS=1 LMUX_STATE_DIR="$T/state" LMUX_BIN_DIR="$T/bin" LMUX_SINK_DIR="$T/sink"
export LMUX_FONTS_DIR="$APP_DIR/Resources/Fonts" LMUX_SCRIPTS_DIR="$APP_DIR/scripts"
export CLAUDE_CONFIG_DIR="$T/claude"   # never the real ~/.claude
export CODEX_HOME="$T/codex" LMUX_CODEX_HOME="$T/codex"   # never the real ~/.codex
export LMUX_CONFIG_FILE="$T/lmux-config"   # never the real ~/.config/lmux/config
export LMUX_CMUX_HOME="$T/no-cmux"         # cmux import reads only fixtures, never the real cmux
export LMUX_ALLOW_EXTERNAL_SEND=1          # the harness drives panes with `lmux send` from outside (security.swift turns it off)
RES="$APP_DIR/build/test-resources/ghostty"
mkdir -p "$RES/themes" && cp "$APP_DIR/Resources/themes/"* "$RES/themes/"
export GHOSTTY_RESOURCES_DIR="$RES"

filter() { grep -v '^\(info\|debug\|warning\)(' || true; }
status=0
if [ "${1:-}" = "--real-window" ]; then
  unset LMUX_HEADLESS
  [ -n "${2:-}" ] && export LMUX_SHOTS_DIR="$2"
  LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --real-window 2>/dev/null | filter || status=1
  exit $status
fi
if [ "${1:-}" = "--rewind" ]; then
  LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --rewind 2>/dev/null | filter || status=1
  exit $status
fi
LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" 2>/dev/null | filter || status=1
# Titlebar buttons and ⇧⌘H in the real titled chrome (built off screen, never shown).
mkdir -p "$T/titlebar"
LMUX_STATE_DIR="$T/titlebar" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --titlebar 2>/dev/null | filter || status=1
# Sidebar: the row × on hover, ⌘/⇧-click multi-selection, closing idle shells and busy panes.
mkdir -p "$T/sidebar"
LMUX_STATE_DIR="$T/sidebar" "$BIN/lmux-apptest" --sidebar 2>/dev/null | filter || status=1
# Split zoom, manual Clear Status, and sidebar drag-to-reorder.
mkdir -p "$T/zoomclear"
LMUX_STATE_DIR="$T/zoomclear" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --zoom-clear-reorder 2>/dev/null | filter || status=1
# Tabs inside a pane (keys, strip, status across tabs, splits, CLI, layout.json), then the relaunch.
mkdir -p "$T/tabs"
for phase in --pane-tabs --pane-tabs-restore; do
  LMUX_STATE_DIR="$T/tabs" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" $phase 2>/dev/null | filter || status=1
done
# Where a new workspace / split starts (Ghostty's working-directory keys, written to a temp lmux config;
# never the user's Ghostty config), then a relaunch: saved panes keep their directories.
mkdir -p "$T/nwd/state" "$T/nwd/sink"
cat > "$T/nwd/pwd.sh" <<'PWD'
#!/bin/sh
pwd -P > "$LMUX_SINK_DIR/$LMUX_PANE_ID.pwd"
exec /bin/cat > /dev/null
PWD
chmod +x "$T/nwd/pwd.sh"
for phase in --new-workspace-dir --new-workspace-dir-restore; do
  LMUX_STATE_DIR="$T/nwd/state" LMUX_SINK_DIR="$T/nwd/sink" LMUX_PANE_COMMAND="$T/nwd/pwd.sh" \
    LMUX_IGNORE_GHOSTTY_CONFIG=1 LMUX_CONFIG_FILE="$T/nwd/lmux-config" \
    "$BIN/lmux-apptest" $phase 2>/dev/null | filter || status=1
done
# Settings (themes, font, toggles; lmux's config is $LMUX_CONFIG_FILE) and the cmux import from fixtures.
mkdir -p "$T/settings"
LMUX_STATE_DIR="$T/settings" LMUX_CONFIG_FILE="$T/settings/lmux-config" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --settings 2>/dev/null | filter || status=1
# Unattended rows: the breathing reminder (fake clock) and its idle cost.
mkdir -p "$T/attention"
LMUX_STATE_DIR="$T/attention" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --attention 2>/dev/null | filter || status=1
# Running rows' subagent count, the bypass / auto badge, the usage-limit wait, the quiet hint (fake clock).
mkdir -p "$T/extras"
LMUX_STATE_DIR="$T/extras" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --status-extras 2>/dev/null | filter || status=1
# The bell's notification list.
mkdir -p "$T/bell"
LMUX_STATE_DIR="$T/bell" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --bell 2>/dev/null | filter || status=1
# Esc / Ctrl+C stops Claude with no hook: the transcript's interrupt marker turns the row idle.
mkdir -p "$T/escidle"
LMUX_STATE_DIR="$T/escidle" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --esc-idle 2>/dev/null | filter || status=1
# Any agent's own status (OSC 7501 app=), lmux wait, lmux list --json.
mkdir -p "$T/agents"
LMUX_STATE_DIR="$T/agents" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --agents 2>/dev/null | filter || status=1
# Codex CLI: a fake codex in a pane (real payloads, real lmux-hook), then the restore of that pane.
mkdir -p "$T/codex-state"
LMUX_STATE_DIR="$T/codex-state" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --codex 2>/dev/null | filter || status=1
LMUX_STATE_DIR="$T/codex-state" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --codex-restore 2>/dev/null | filter || status=1
# Security: pane tokens on both sockets, external send off by default, typed commands, transcript
# paths, the state dir, link labels, socket read caps.
mkdir -p "$T/security"
LMUX_STATE_DIR="$T/security" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --security 2>/dev/null | filter || status=1
# Contrast: Claude Code's real output (its dark and light themes) and ls / git / ANSI samples stay
# readable in every theme pair, measured from the renderer's pixels (fixtures: scripts/contrast).
mkdir -p "$T/contrast"
# Hermetic: lmux's defaults only, never the user's Ghostty config (LMUX_CONFIG_FILE is a temp path).
LMUX_STATE_DIR="$T/contrast" LMUX_CONTRAST_DIR="$APP_DIR/scripts/contrast" LMUX_PANE_COMMAND="$T/sink.sh" \
  LMUX_IGNORE_GHOSTTY_CONFIG=1 LMUX_CONFIG_FILE="$T/contrast/lmux-config" \
  "$BIN/lmux-apptest" --contrast 2>/dev/null | filter || status=1
# Ghostty parity: the scrollback's overlay scroller, link hover and ⌘-click (opening is captured).
mkdir -p "$T/parity"
LMUX_STATE_DIR="$T/parity" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --parity 2>/dev/null | filter || status=1
# A new user's first days: the README's shortcut table on a real (isolated) zsh, a keybind in the
# "user's" Ghostty config (XDG_CONFIG_HOME on a temp dir), edge cases, cmux leftovers.
mkdir -p "$T/newuser" "$T/xdg"
LMUX_STATE_DIR="$T/newuser" XDG_CONFIG_HOME="$T/xdg" "$BIN/lmux-apptest" --newuser 2>/dev/null | filter || status=1
# Where features meet (restore without hooks, zoom + arrows / attention, undo with an image, Clear
# Status vs pending work, drag + selection change): a real isolated zsh with a fake claude / codex
# first on its PATH (the phase writes them), so a resumed session never starts a real agent.
mkdir -p "$T/regress/state" "$T/regress/fakebin"
( lmux_isolated_shell "$T/regress/shell"
  echo "PATH='$T/regress/fakebin':\$PATH" >> "$T/regress/shell/zdot/.zshrc"
  LMUX_STATE_DIR="$T/regress/state" LMUX_QA_FAKEBIN="$T/regress/fakebin" \
    GHOSTTY_RESOURCES_DIR="$APP_DIR/../vendor/ghostty/zig-out/share/ghostty" \
    "$BIN/lmux-apptest" --regressions 2>/dev/null | filter ) || status=1
# Quitting by signal (kill, logout) hangs up the panes' processes like ⌘Q: none is orphaned.
swift build --product lmux >/dev/null
mkdir -p "$T/term"
cat > "$T/long.sh" <<'LONG'
#!/bin/sh
echo $$ > "$LMUX_SINK_DIR/long.pid"
exec /bin/sleep 600
LONG
chmod +x "$T/long.sh"
LMUX_STATE_DIR="$T/term" LMUX_PANE_COMMAND="$T/long.sh" "$BIN/lmux" >/dev/null 2>&1 &
APP=$!
for _ in $(seq 50); do [ -s "$T/sink/long.pid" ] && break; sleep 0.1; done
CHILD="$(cat "$T/sink/long.pid" 2>/dev/null || echo)"
kill -TERM $APP 2>/dev/null || true
gone=0
for _ in $(seq 20); do
  if [ -n "$CHILD" ] && ! kill -0 "$CHILD" 2>/dev/null && ! kill -0 $APP 2>/dev/null; then gone=1; break; fi
  sleep 0.1
done
if [ -n "$CHILD" ] && [ $gone = 1 ]; then
  echo "PASS  [lifecycle] SIGTERM quits lmux and its pane's process is gone within 2s"
else
  echo "FAIL  [lifecycle] SIGTERM: pane process ${CHILD:-?} or lmux $APP still running"; status=1
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null; kill -9 $APP 2>/dev/null || true
fi
rm -f "$T/sink/long.pid"
# One lmux per state dir, even when two start at the same moment (Finder double-launch, login
# item + click): the second hands off to the first and exits 0 without restoring the layout,
# so every pane runs once.
cat > "$T/race.sh" <<'RACE'
#!/bin/sh
echo $$ >> "$LMUX_SINK_DIR/race.pids"
exec /bin/sleep 600
RACE
chmod +x "$T/race.sh"
race_ok=0
for round in 1 2 3; do
  rm -rf "$T/race"; mkdir -p "$T/race"; : > "$T/sink/race.pids"
  LMUX_STATE_DIR="$T/race" LMUX_PANE_COMMAND="$T/race.sh" "$BIN/lmux" >/dev/null 2>&1 &
  A=$!
  LMUX_STATE_DIR="$T/race" LMUX_PANE_COMMAND="$T/race.sh" "$BIN/lmux" >/dev/null 2>&1 &
  B=$!
  for _ in $(seq 50); do [ -s "$T/sink/race.pids" ] && break; sleep 0.1; done
  sleep 2
  alive=""; for p in $A $B; do kill -0 $p 2>/dev/null && alive="$alive $p"; done
  panes="$(wc -l < "$T/sink/race.pids" | tr -d ' ')"
  loser_status=x
  for p in $A $B; do
    if ! kill -0 $p 2>/dev/null; then set +e; wait $p; loser_status=$?; set -e; fi
  done
  # A third launch while one runs: hands off and exits 0 right away.
  set +e
  LMUX_STATE_DIR="$T/race" LMUX_PANE_COMMAND="$T/race.sh" "$BIN/lmux" >/dev/null 2>&1
  third=$?
  set -e
  panes_after="$(wc -l < "$T/sink/race.pids" | tr -d ' ')"
  if [ "$(echo $alive | wc -w | tr -d ' ')" = 1 ] && [ "$panes" = 1 ] && [ "$loser_status" = 0 ] && [ "$third" = 0 ] \
     && [ "$panes_after" = 1 ]; then
    race_ok=$((race_ok + 1))
  else
    echo "      race round $round: alive=[$alive] panes=$panes loser_exit=$loser_status third_exit=$third panes_after=$panes_after"
  fi
  for p in $A $B; do kill -TERM $p 2>/dev/null || true; done
  for p in $A $B; do set +e; wait $p 2>/dev/null; set -e; done
  for c in $(cat "$T/sink/race.pids"); do kill "$c" 2>/dev/null || true; done
done
if [ $race_ok = 3 ]; then
  echo "PASS  [single-instance] two lmux started at once: one runs (one pane), the other exits 0 unrestored; a third hands off (3/3)"
else
  echo "FAIL  [single-instance] concurrent launches: $race_ok/3 rounds clean"; status=1
fi
rm -f "$T/sink/race.pids"
if [ "${1:-}" = "--quick" ]; then leftovers || status=1; history_unchanged || status=1; windows_unseen || status=1; exit $status; fi
rm -f "$T/sink/"*
LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --restore 2>/dev/null | filter || status=1
# A fresh process (no panes left over from the run above), so its memory is the app's.
mkdir -p "$T/big"
LMUX_STATE_DIR="$T/big" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --big 2>/dev/null | filter || status=1
# Idle surfaces release their GPU memory and rebuild it on the next frame (scripts/ghostty.patch),
# under output, resize, zoom, split / close, occlusion, an appearance change and 220 cycles.
mkdir -p "$T/gpuidle"
LMUX_STATE_DIR="$T/gpuidle" LMUX_IGNORE_GHOSTTY_CONFIG=1 LMUX_CONFIG_FILE="$T/gpuidle/lmux-config" \
  "$BIN/lmux-apptest" --gpu-idle 2>/dev/null | filter || status=1
# Clicks the event queue held back (delivered directly, the queued copy later): every one still
# lands once and keeps its ⌘ / ⇧ / ⌥ (they used to come from whatever event was current).
mkdir -p "$T/late-titlebar" "$T/late-sidebar"
LMUX_APPTEST_LATE_COPY=1 LMUX_STATE_DIR="$T/late-titlebar" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --titlebar 2>/dev/null | filter || status=1
LMUX_APPTEST_LATE_COPY=1 LMUX_STATE_DIR="$T/late-sidebar" "$BIN/lmux-apptest" --sidebar 2>/dev/null | filter || status=1
# Key -> pty latency (headless; reported, not asserted against Ghostty).
mkdir -p "$T/lat"
LMUX_STATE_DIR="$T/lat" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --latency 2>/dev/null | filter || status=1
# Everyday terminal work off the happy path: real programs (python fixtures, vim, less, top) in the
# isolated shell, wide text, huge output, storms, kitty keys, mouse, pastes, resizes, corrupted state files.
mkdir -p "$T/compat"
# vim / less / top need xterm-ghostty's terminfo (the test resources dir has themes only).
LMUX_COMPAT_TERMINFO="$APP_DIR/../vendor/ghostty/zig-out/share/terminfo" LMUX_STATE_DIR="$T/compat" "$BIN/lmux-apptest" --compat 2>/dev/null \
  | filter || status=1
# Terminal output across a relaunch: plain shell panes save it at quit, the next launch shows it
# above the new prompt. Real isolated zsh with Ghostty's shell integration (knows "at a prompt").
mkdir -p "$T/scrollback"
GHOSTTY_RESOURCES_DIR="$APP_DIR/../vendor/ghostty/zig-out/share/ghostty" LMUX_STATE_DIR="$T/scrollback" \
  "$BIN/lmux-apptest" --scrollback 2>/dev/null | filter || status=1
GHOSTTY_RESOURCES_DIR="$APP_DIR/../vendor/ghostty/zig-out/share/ghostty" LMUX_STATE_DIR="$T/scrollback" \
  "$BIN/lmux-apptest" --scrollback-restore 2>/dev/null | filter || status=1
if [ "${1:-}" = "--screenshots" ]; then
  mkdir -p "$T/shots"
  # Real shells with shell integration (titles, OSC 7 cwd) need the bundle's resources.
  if [ -d "$APP_DIR/build/lmux.app/Contents/Resources/ghostty/shell-integration" ]; then
    export GHOSTTY_RESOURCES_DIR="$APP_DIR/build/lmux.app/Contents/Resources/ghostty"
  fi
  LMUX_STATE_DIR="$T/shots" "$BIN/lmux-apptest" --screenshots "${2:?dir}" 2>/dev/null | filter
fi
leftovers || status=1
history_unchanged || status=1
windows_unseen || status=1
exit $status
