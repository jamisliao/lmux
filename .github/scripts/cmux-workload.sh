#!/bin/bash
# .github/scripts/cmux-workload.sh start <cmux.app> [workspaces]
# .github/scripts/cmux-workload.sh stop
#
# CI only (refuses unless GITHUB_ACTIONS=true): launches a FRESH cmux on the runner (visible; it's not
# anyone's Mac) and builds the benchmark workload through cmux's own CLI, the same shape bench.sh restores
# for lmux: N workspaces (default 10) x 2 idle login-shell panes. cmux starts a pane's shell lazily, so
# every workspace is selected once and every surface gets `true` typed into it (`cmux send`); the first
# workspace is selected again at the end. `scripts/bench.sh <cmux.app> --workspaces N` then attaches,
# checks there is exactly one live shell per pane, and measures. Fails unless the workspace and pane
# counts are exact. `stop` kills only the cmux this script started (pid file), waits for it to exit and
# deletes its saved session, so the next start is fresh (no restored workspaces).
# Prints KEY=VALUE lines (and appends them to $GITHUB_OUTPUT): workspaces, panes, socket_mode, note.
set -euo pipefail
[ "${GITHUB_ACTIONS:-}" = "true" ] || { echo "cmux-workload: CI only (GITHUB_ACTIONS != true); refusing" >&2; exit 2; }

PIDFILE="${RUNNER_TEMP:-/tmp}/cmux-workload.pid"
LOG="${RUNNER_TEMP:-/tmp}/cmux-app.log"
out() { echo "$1"; [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1" >> "$GITHUB_OUTPUT"; }
# Saved session (Application Support/cmux/session-<bundle id>[-previous].json) and window state.
forget_session() {  # $1: bundle id
  rm -f "$HOME/Library/Application Support/cmux/session-$1"*.json
  rm -rf "$HOME/Library/Saved Application State/$1.savedState"
}

if [ "${1:-}" = "stop" ]; then
  if [ -f "$PIDFILE" ]; then
    read -r PID APP_ID < "$PIDFILE"
    kill "$PID" 2>/dev/null || true
    for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
    kill -9 "$PID" 2>/dev/null || true
    sleep 1
    forget_session "$APP_ID"
    rm -f "$PIDFILE"
  fi
  exit 0
fi
[ "${1:-}" = "start" ] || { echo "usage: $0 start <cmux.app> [workspaces] | stop" >&2; exit 1; }
APP="${2:?cmux.app path}"; WS="${3:-10}"; PANES=$((WS * 2))
APP="${APP%/}"
EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
MAIN="$APP/Contents/MacOS/$EXEC"
CLI="$(find "$APP/Contents" -type f -name cmux -perm -u+x -not -path '*/MacOS/*' | head -1)"
[ -x "$CLI" ] || { echo "cmux-workload: no cmux CLI inside $APP" >&2; exit 1; }
echo "cmux: $("$CLI" version 2>/dev/null || true)  bundle=$BUNDLE_ID cli=$CLI"
if pgrep -f "^$MAIN( |\$)" >/dev/null; then echo "cmux-workload: a cmux is already running; not touching it" >&2; exit 1; fi

# A CI machine's defaults, not a user's: no update checks/prompts during the measurement.
defaults write "$BUNDLE_ID" SUEnableAutomaticChecks -bool false || true
forget_session "$BUNDLE_ID"

launch() {  # $@: extra env
  env "$@" "$MAIN" >"$LOG" 2>&1 &
  echo "$! $BUNDLE_ID" > "$PIDFILE"
  for _ in $(seq 1 60); do
    kill -0 "$(cut -d' ' -f1 "$PIDFILE")" 2>/dev/null || { cat "$LOG" >&2; echo "cmux-workload: cmux exited" >&2; return 1; }
    "$CLI" ping >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# cmux's default socket mode (cmuxOnly) only admits processes started inside cmux, so the CLI on the
# runner is refused; allowAll lets it in. Only the socket's access policy differs.
export CMUX_QUIET=1
SOCKET_MODE="allowAll"
launch CMUX_SOCKET_MODE=allowAll || { echo "cmux-workload: no socket with CMUX_SOCKET_MODE=allowAll" >&2; "$CLI" socket-status --json >&2 || true; exit 1; }
out "socket_mode=$SOCKET_MODE"
sleep 3

# Workspace handles from `--json list-workspaces` (ref if present, else id), in sidebar order.
refs() {
  "$CLI" --json list-workspaces 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
ws = d.get("workspaces", d) if isinstance(d, dict) else d
for w in ws or []:
    print(w.get("ref") or w.get("id"))'
}
count_panes() {  # $1: workspace handle
  "$CLI" --json list-panes --workspace "$1" 2>/dev/null | python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("panes", [])))'
}
n="$(refs | wc -l | tr -d ' ')"
[ "$n" -ge 1 ] || { echo "cmux-workload: list-workspaces returned nothing:" >&2; "$CLI" --json list-workspaces >&2 || true; exit 1; }
# list-workspaces can lag a new-workspace by a moment: create the missing ones from one count, then
# wait for the list to settle at exactly WS before splitting.
while [ "$n" -lt "$WS" ]; do "$CLI" new-workspace; n=$((n + 1)); done
for _ in $(seq 1 20); do [ "$(refs | wc -l | tr -d ' ')" -eq "$WS" ] && break; sleep 0.5; done
# One right split in every workspace: 2 panes each.
for ref in $(refs); do
  "$CLI" new-split right --workspace "$ref"
done
sleep 3

# Live shells: select each workspace (cmux starts a pane's shell lazily) and type `true` into every
# terminal surface in it. Surface refs are whatever "surface:N" strings its panel list contains.
surfaces() {  # $1: workspace handle
  "$CLI" --json list-panels --workspace "$1" 2>/dev/null | python3 -c '
import json, re, sys
seen = []
def walk(v):
    if isinstance(v, dict): [walk(x) for x in v.values()]
    elif isinstance(v, list): [walk(x) for x in v]
    elif isinstance(v, str) and re.fullmatch(r"surface:\d+", v) and v not in seen: seen.append(v)
walk(json.load(sys.stdin)); print("\n".join(seen))'
}
sent=0
for ref in $(refs); do
  "$CLI" select-workspace --workspace "$ref" >/dev/null
  sleep 1
  for s in $(surfaces "$ref"); do
    "$CLI" send --workspace "$ref" --surface "$s" 'true\n' >/dev/null && sent=$((sent + 1))
  done
done
"$CLI" select-workspace --workspace "$(refs | head -1)" >/dev/null
sleep 3

panes=0
for ref in $(refs); do panes=$((panes + $(count_panes "$ref"))); done
nws="$(refs | wc -l | tr -d ' ')"
"$CLI" tree || true
out "workspaces=$nws"
out "panes=$panes"
out "primed=$sent"
out "note=cmux launched fresh on the runner (saved session deleted); workload built via cmux CLI (new-workspace, new-split right); each workspace selected and \`true\` sent to its $sent surfaces; socket mode: $SOCKET_MODE"
if [ "$nws" -ne "$WS" ] || [ "$panes" -ne "$PANES" ] || [ "$sent" -ne "$PANES" ]; then
  echo "cmux-workload: wanted $WS workspaces / $PANES panes / $PANES primed, got $nws / $panes / $sent" >&2
  "$CLI" --json list-panels --workspace "$(refs | head -1)" >&2 || true
  exit 1
fi
