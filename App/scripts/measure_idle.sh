#!/bin/bash
# Measure idle CPU and RSS of lmux.app, headless (LMUX_HEADLESS=1: no window on
# screen, no focus change, no Dock icon). State lives in a temp dir.
#   App/scripts/measure_idle.sh [seconds] [panes] [panes-per-workspace] [running]
#     defaults: 20s, 1 pane. Example: measure_idle.sh 30 10 2  -> 5 workspaces x 2 panes
#     (the restored layout selects the first workspace; the others are hidden).
#     running: that many panes (the first pane of each workspace, in order) are put in the
#     agent "running" state the real way: lmux-hook, run by the pane's own shell through the
#     hook socket (SessionStart + UserPromptSubmit + PreToolUse), then the shell execs `sleep`
#     so the pane keeps a live foreground process. Example: measure_idle.sh 20 3 1 3 -> 3
#     workspaces, each row with a turning spinner.
#   History isn't indexed (that waits until History is first opened; its first index is
#   measured by perf_budget.py indexer).
set -euo pipefail
SECS="${1:-20}"
PANES="${2:-1}"
PER="${3:-$PANES}"
RUNNING="${4:-0}"
APP="$(cd "$(dirname "$0")/.." && pwd)/build/lmux.app"
STATE="$(mktemp -d /tmp/lmux-measure.XXXXXX)"
# The panes' shells: an isolated zsh (temp ZDOTDIR / HISTFILE), never the user's login shell.
source "$(cd "$(dirname "$0")" && pwd)/isolated-shell.sh"
HIST0="$(history_stamp)"
lmux_isolated_shell "$STATE/shell"
python3 - "$STATE/layout.json" "$PANES" "$PER" <<'PY'
import json, sys, uuid
out, n, per = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def tree(k, axis="horizontal"):
    if k == 1:
        return {"pane": {"id": str(uuid.uuid4()).upper()}}
    a = k // 2
    nxt = "vertical" if axis == "horizontal" else "horizontal"
    return {"axis": axis, "ratio": a / k, "children": [tree(a, nxt), tree(k - a, nxt)]}
ws, left, i = [], n, 0
while left > 0:
    k = min(per, left)
    ws.append({"id": str(uuid.uuid4()).upper(), "accent": i % 8, "root": tree(k)})
    print(json.dumps(ws[-1]["root"]).split('"id": "')[1].split('"')[0], file=open(out + ".first", "a"))
    left -= k; i += 1
json.dump({"version": 1, "workspaces": ws, "selected": ws[0]["id"],
           "sidebarVisible": True, "sidebarWidth": 240}, open(out, "w"))
PY
mkdir -p "$STATE/projects"
LMUX_CLAUDE_PROJECTS="${LMUX_CLAUDE_PROJECTS:-$STATE/projects}" \
  LMUX_ALLOW_EXTERNAL_SEND=1 LMUX_HEADLESS=1 LMUX_STATE_DIR="$STATE" "$APP/Contents/MacOS/lmux" >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; sleep 0.5; rm -rf "$STATE"' EXIT
sleep 6   # let the shells start and settle
if [ "$RUNNING" -gt 0 ]; then
  CLI="$APP/Contents/Resources/bin/lmux"; HOOK="$APP/Contents/Resources/bin/lmux-hook"
  n=0
  for PANE_ID in $(cat "$STATE/layout.json.first"); do
    [ $n -ge "$RUNNING" ] && break
    S="measure-$n"
    J='"session_id":"'$S'","cwd":"/tmp"'
    cat > "$STATE/agent-$n.sh" <<AGENT
#!/bin/sh
printf '%s' '{"hook_event_name":"SessionStart",$J,"source":"startup"}' | '$HOOK'
printf '%s' '{"hook_event_name":"UserPromptSubmit",$J,"prompt":"x"}' | '$HOOK'
printf '%s' '{"hook_event_name":"PreToolUse",$J,"tool_name":"Bash","tool_input":{"command":"swift build"}}' | '$HOOK'
exec sleep 100000
AGENT
    chmod +x "$STATE/agent-$n.sh"
    LMUX_CONTROL_SOCKET="$STATE/control.sock" "$CLI" send --pane "$PANE_ID" "exec $STATE/agent-$n.sh\n" >/dev/null
    n=$((n + 1))
  done
  sleep 4
  RUN_NOW=$(LMUX_CONTROL_SOCKET="$STATE/control.sock" "$CLI" list | grep -c '\[running\]' || true)
  echo "running panes: $RUN_NOW of $RUNNING requested"
  if [ "$RUN_NOW" != "$RUNNING" ]; then echo "FAIL  only $RUN_NOW of $RUNNING panes reached the running state"; exit 1; fi
  sleep 4
fi

cpu_s() { ps -o cputime= -p "$1" | awk -F'[:.]' '{ if (NF==4) print $1*3600+$2*60+$3+$4/100; else print $1*60+$2+$3/100 }'; }
T0=$(cpu_s $PID); W0=$(date +%s)
# top samples once per second; first sample is meaningless (no delta) so drop it.
TOPCPU=$(top -l $((SECS+1)) -s 1 -pid $PID -stats cpu | awk '$1 ~ /^[0-9.]+$/ {print $1}' | tail -n +2)
T1=$(cpu_s $PID); W1=$(date +%s)
RSS_KB=$(ps -o rss= -p $PID | tr -d ' ')
# Descendants (login, shells) for the all-process total.
DESC=$(pgrep -P $PID || true); ALL="$DESC"
for d in $DESC; do ALL="$ALL $(pgrep -P $d || true)"; done
CHILD_KB=0; for d in $ALL; do k=$(ps -o rss= -p $d 2>/dev/null | tr -d ' '); CHILD_KB=$((CHILD_KB + ${k:-0})); done
echo "panes=$PANES per-workspace=$PER running=$RUNNING pid=$PID window=$((W1-W0))s"
LINKS=$(sample $PID 1 2>/dev/null | grep -E "^ *[0-9]+ Thread_[0-9]+.*CVDisplayLink" -c || true)
echo "CVDisplayLink threads: $LINKS"
echo "cpu time used: $(echo "$T1 - $T0" | bc) s  => avg $(echo "scale=3; ($T1 - $T0) * 100 / ($W1 - $W0)" | bc)% of one core"
echo "top samples (%): $(echo $TOPCPU | tr '\n' ' ')"
echo "RSS app: $((RSS_KB / 1024)) MB   children ($(echo $ALL | wc -w | tr -d ' ') procs): $((CHILD_KB / 1024)) MB   total: $(((RSS_KB + CHILD_KB) / 1024)) MB"

# Budget (R1): idle CPU < 1% of one core and the lmux process < 300 MB.
AVG=$(echo "scale=3; ($T1 - $T0) * 100 / ($W1 - $W0)" | bc)
FAIL=0
if [ "$(echo "$AVG >= 1" | bc)" = 1 ]; then echo "FAIL  idle CPU ${AVG}% >= 1%"; FAIL=1; fi
if [ $((RSS_KB / 1024)) -ge 300 ]; then echo "FAIL  RSS $((RSS_KB / 1024)) MB >= 300 MB"; FAIL=1; fi
if [ "$(history_stamp)" != "$HIST0" ]; then echo "FAIL  ~/.zsh_history changed during the run"; FAIL=1; fi
[ $FAIL = 0 ] && echo "PASS  idle budget: CPU ${AVG}% < 1%, RSS $((RSS_KB / 1024)) MB < 300 MB"
exit $FAIL
