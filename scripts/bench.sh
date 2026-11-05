#!/bin/bash
# Fair, scripted benchmark for one app (lmux or cmux): app size, per-group
# process memory (RSS + phys_footprint), idle CPU (mean/p95), and launch
# time (lmux headless only). Writes a JSON result; scripts/bench-compare.sh
# turns two of them into the README table + assets/bench-chart*.svg.
#
#   scripts/bench.sh <app-path> [--label NAME] [--workload small|standard] [--workspaces N] [--reps N] [--out results.json] [--visible]
#
# --reps N (default 1) repeats the measurement N times and writes every rep
# into the JSON (rep_results) plus median/min/max across reps (aggregate):
# for lmux each rep is a fresh launch (own lifecycle: new temp state dir,
# launch, prime, measure, kill); lmux is the only app this script ever
# launches/kills, so it owns that loop. For an attach-only app (e.g. cmux)
# this script never launches or signals it (same rule as always: it's never
# relaunched here), so each rep there is a fresh settle+sample window against
# the one already-running, already-primed instance -- re-priming it between
# reps is the CI workflow's job, same as it's always done once per step (see
# scripts/BENCH.md).
#
# Every pane must have a live shell before anything is measured: lmux's panes get a `true` typed
# into them (`lmux send`), cmux's are primed the same way by .github/scripts/cmux-workload.sh, and
# this script then counts the shell processes under the app and fails (exit 3) unless the count is
# exactly the number of panes. The count goes into the JSON (workload_detail.shells_live).
#
# Safety:
#   - lmux (detected by bundle id / executable name) is the ONLY app this
#     script ever launches, headless (LMUX_HEADLESS=1) unless --visible is
#     given (CI only), never with `open`. Its state lives in a temp dir (never
#     ~/Library/Application Support/lmux). It is killed again on exit, always.
#   - Any other app (e.g. cmux) is NEVER launched or signaled by this
#     script. It must already be running -- set it up by hand first, see
#     scripts/BENCH.md -- and this script only attaches to it to measure.
#
# See scripts/BENCH.md for methodology notes and the manual cmux workload.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/bench.sh <app-path> [--label NAME] [--workload small|standard] [--workspaces N] [--reps N] [--out results.json] [--visible]

  <app-path>                  Path to the .app bundle to measure.
  --label NAME                Label for this run (default: derived from the
                               bundle, e.g. "lmux" or "cmux").
  --workload small|standard   small = quick smoke run (~15s), 1 workspace, 1 pane.
                               standard = the fair-comparison workload: 10
                               workspaces x 2 panes = 20 idle shells, 15s settle,
                               60s sample. (default: standard)
  --workspaces N              standard only: N workspaces x 2 panes instead of 10
                               (the scaling series runs 1, 10 and 20).
  --reps N                    Repeat the measurement N times (default: 1).
                               lmux: each rep is a fresh launch. Attach-only
                               apps (e.g. cmux): each rep is a fresh settle+
                               sample window against the already-running,
                               already-primed instance (never relaunched).
                               Every rep is written to the JSON, plus the
                               median/min/max across reps (see scripts/BENCH.md).
  --out results.json          Where to write the JSON result. (default: results.json)
  --visible                   lmux only, CI only (GITHUB_ACTIONS=true): launch lmux
                               with a real on-screen window (like any other app), not
                               headless, so both sides of a comparison render the same way.
  -h, --help                  Show this help.

lmux is launched by this script (headless unless --visible), with its state in
a temp dir holding the workload's layout, and killed again before it exits.
Any other app (cmux included) is never launched here -- start it yourself
per scripts/BENCH.md, then point this script at it to measure.
EOF
}

die() { echo "bench.sh: $*" >&2; exit 1; }

[ $# -ge 1 ] || { usage >&2; exit 1; }
APP_PATH="$1"; shift
LABEL=""
WORKLOAD="standard"
WORKSPACES=""
REPS="1"
OUT="results.json"
VISIBLE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="${2:?--label needs a value}"; shift 2 ;;
    --workload) WORKLOAD="${2:?--workload needs a value}"; shift 2 ;;
    --workspaces) WORKSPACES="${2:?--workspaces needs a value}"; shift 2 ;;
    --reps) REPS="${2:?--reps needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --visible) VISIBLE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$APP_PATH" in /*) : ;; *) APP_PATH="$(pwd)/$APP_PATH" ;; esac
APP_PATH="${APP_PATH%/}"
[ -d "$APP_PATH" ] || die "no such app bundle: $APP_PATH"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
[ -f "$INFO_PLIST" ] || die "not an app bundle (no Contents/Info.plist): $APP_PATH"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST" 2>/dev/null || true)"
[ -n "$EXEC_NAME" ] || EXEC_NAME="$(basename "$APP_PATH" .app)"
MAIN_BIN="$APP_PATH/Contents/MacOS/$EXEC_NAME"
[ -x "$MAIN_BIN" ] || die "main executable not found/executable: $MAIN_BIN"

APP_SIZE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"

# App kind: only "lmux" ever gets launched by this script. Everything else
# (cmux, or anything else) is attach-only.
lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
APP_KIND="other"
case "$(lc "$BUNDLE_ID")$(lc "$EXEC_NAME")$(lc "$(basename "$APP_PATH")")" in
  *lmux*) APP_KIND="lmux" ;;
esac
case "$(lc "$BUNDLE_ID")$(lc "$EXEC_NAME")$(lc "$(basename "$APP_PATH")")" in
  *cmux*) APP_KIND="cmux" ;;
esac

[ -n "$LABEL" ] || LABEL="$EXEC_NAME"

case "$WORKLOAD" in
  small)    SETTLE=5;  SAMPLE=10; WL_WORKSPACES=1; WL_PANES=1 ;;
  standard) SETTLE=15; SAMPLE=60; WL_WORKSPACES="${WORKSPACES:-10}"; WL_PANES=$((WL_WORKSPACES * 2)) ;;
  *) die "--workload must be 'small' or 'standard', got: $WORKLOAD" ;;
esac
case "$WL_WORKSPACES" in ''|*[!0-9]*|0) die "--workspaces must be a positive integer, got: $WL_WORKSPACES" ;; esac
[ "$WORKLOAD" = standard ] || [ -z "$WORKSPACES" ] || die "--workspaces only applies to --workload standard"
case "$REPS" in ''|*[!0-9]*|0) die "--reps must be a positive integer, got: $REPS" ;; esac

now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }

LAUNCHED_BY_SCRIPT=false
MAIN_PID=""
LAUNCH_MODE="manual"
LAUNCH_SECONDS="null"
WL_CLI_USED=false
WL_ACTUAL_WORKSPACES=1
WL_ACTUAL_PANES=1
WL_NOTE=""
SHELLS_LIVE=0

LMUX_BENCH_STATE=""
cleanup() {
  if [ "$LAUNCHED_BY_SCRIPT" = true ] && [ -n "$MAIN_PID" ]; then
    kill "$MAIN_PID" >/dev/null 2>&1 || true
    sleep 1
    # Belt and suspenders: nothing under this exact bundle path should
    # still be alive. Force-kill any straggler before we exit.
    STRAY="$(ps -axo pid=,comm= | awk -v p="$APP_PATH/" '{line=$0; sub(/^[0-9]+[ \t]+/,"",line); if (index(line,p)==1) print $1}' 2>/dev/null || true)"
    if [ -n "$STRAY" ]; then
      echo "$STRAY" | xargs -I{} kill -9 {} >/dev/null 2>&1 || true
    fi
  fi
  if [ -n "$LMUX_BENCH_STATE" ]; then rm -rf "$LMUX_BENCH_STATE"; fi
  LAUNCHED_BY_SCRIPT=false
  MAIN_PID=""
  LMUX_BENCH_STATE=""
}
trap cleanup EXIT

if [ "$VISIBLE" = true ]; then
  [ "$APP_KIND" = "lmux" ] || die "--visible only applies to lmux (other apps are never launched here)"
  [ "${GITHUB_ACTIONS:-}" = "true" ] || die "--visible is for CI runners only (GITHUB_ACTIONS=true): it shows a window and takes focus"
fi

# --- Acquire the app: fresh launch (lmux, called once per rep below) or ---
# --- attach to an already-running instance (everything else, once). -------
ISOLATED_SHELL_SRC="$(cd "$(dirname "$0")/../App/scripts" && pwd)/isolated-shell.sh"
LMUX_CLI="$APP_PATH/Contents/Resources/bin/lmux"

count_lmux_panes() {
  ps -axo ppid=,comm= | awk -v p="$MAIN_PID" -v b="$MAIN_BIN" '$1==p && index($0,b)==0 {n++} END{print n+0}'
}

acquire_lmux() {
  LAUNCHED_BY_SCRIPT=true
  # The workload is a restored layout in a temp state dir (N workspaces x 2
  # panes, the same shape a cmux run is built with), so the user's real lmux
  # state, sockets and History are never touched. Prints the pane ids.
  LMUX_BENCH_STATE="$(mktemp -d /tmp/lmux-bench.XXXXXX)"
  mkdir -p "$LMUX_BENCH_STATE/projects"
  python3 - "$LMUX_BENCH_STATE/layout.json" "$WL_WORKSPACES" "$WL_PANES" <<'LAYOUT'
import json, sys, uuid
out, nws, npanes = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
counts = [npanes // nws + (1 if i < npanes % nws else 0) for i in range(nws)]
def pane(): return {"pane": {"id": str(uuid.uuid4()).upper()}}
def tree(k):
    if k == 1: return pane()
    return {"axis": "horizontal", "ratio": 1 / k, "children": [pane(), tree(k - 1)]}
ws = [{"id": str(uuid.uuid4()).upper(), "accent": i % 8, "root": tree(k)} for i, k in enumerate(counts)]
json.dump({"version": 1, "workspaces": ws, "selected": ws[0]["id"],
           "sidebarVisible": True, "sidebarWidth": 240}, open(out, "w"))
def ids(n): return [n["pane"]["id"]] if "pane" in n else [i for c in n["children"] for i in ids(c)]
open(out + ".panes", "w").write("\n".join(i for w in ws for i in ids(w["root"])) + "\n")
LAYOUT
  SOCKET_PATH="$LMUX_BENCH_STATE/lmux.sock"
  # The panes' idle shells: an isolated zsh (temp ZDOTDIR / HISTFILE), never the user's login shell.
  source "$ISOLATED_SHELL_SRC"
  lmux_isolated_shell "$LMUX_BENCH_STATE/shell"
  if [ "$VISIBLE" = true ]; then
    LAUNCH_MODE="visible"
    # No first-launch hooks sheet on the runner (it's a CI machine's defaults, not a user's).
    defaults write dev.lmux.app hooksOnboardingDone -bool true
    LMUX_ENV=(LMUX_ALLOW_EXTERNAL_SEND=1 LMUX_STATE_DIR="$LMUX_BENCH_STATE" LMUX_CLAUDE_PROJECTS="$LMUX_BENCH_STATE/projects" LMUX_PANE_COMMAND="$LMUX_PANE_COMMAND")
  else
    LAUNCH_MODE="headless"
    LMUX_ENV=(LMUX_ALLOW_EXTERNAL_SEND=1 LMUX_HEADLESS=1 LMUX_STATE_DIR="$LMUX_BENCH_STATE" LMUX_CLAUDE_PROJECTS="$LMUX_BENCH_STATE/projects" LMUX_PANE_COMMAND="$LMUX_PANE_COMMAND")
  fi

  T0="$(now)"
  env "${LMUX_ENV[@]}" "$MAIN_BIN" >/tmp/lmux-bench.$$.log 2>&1 &
  MAIN_PID=$!

  # Ready = socket appears, or the pty child (login shell) shows up, or timeout.
  READY=false
  for _ in $(seq 1 200); do
    if ! kill -0 "$MAIN_PID" 2>/dev/null; then
      cat /tmp/lmux-bench.$$.log >&2 || true
      die "lmux exited during startup (see log above)"
    fi
    if [ -S "$SOCKET_PATH" ]; then READY=true; break; fi
    if ps -axo pid=,ppid= | awk -v p="$MAIN_PID" '$2==p{found=1} END{exit !found}'; then
      READY=true; break
    fi
    sleep 0.05
  done
  T1="$(now)"
  LAUNCH_SECONDS="$(python3 -c "print(round($T1-$T0,3))")"
  [ "$READY" = true ] || echo "bench.sh: warning: lmux readiness signal not seen within 10s, measuring anyway" >&2

  # Panes actually open = pty children of lmux (one per pane; the History
  # indexer, `lmux --lmux-index`, is not one). Wait up to 10s for all of them.
  for _ in $(seq 1 100); do
    [ "$(count_lmux_panes)" -ge "$WL_PANES" ] && break
    sleep 0.1
  done
  WL_ACTUAL_PANES="$(count_lmux_panes)"
  WL_ACTUAL_WORKSPACES="$WL_WORKSPACES"
  # Make sure every pane's shell is up and has run something: type `true` into each one.
  [ -x "$LMUX_CLI" ] || die "no lmux CLI in the bundle: $LMUX_CLI"
  sleep 2
  while read -r PANE_ID; do
    [ -n "$PANE_ID" ] || continue
    LMUX_CONTROL_SOCKET="$LMUX_BENCH_STATE/control.sock" "$LMUX_CLI" send --pane "$PANE_ID" 'true\n' \
      || die "lmux send to pane $PANE_ID failed"
  done < "$LMUX_BENCH_STATE/layout.json.panes"
  WL_NOTE="restored layout in a temp state dir: $WL_WORKSPACES workspaces, $WL_PANES panes requested, $WL_ACTUAL_PANES pty children seen, \`true\` sent to each pane (lmux send); $LAUNCH_MODE"
  echo "bench.sh: $WL_NOTE" >&2
}

acquire_other() {
  # Attach-only: find the already-running app. Never launch it.
  MAIN_PID="$(pgrep -f "^$MAIN_BIN( |\$)" | head -1 || true)"
  if [ -z "$MAIN_PID" ]; then
    die "no running process found for $MAIN_BIN -- start it yourself and set up the workload first (see scripts/BENCH.md), then re-run"
  fi
  LAUNCH_MODE="manual"
  LAUNCH_SECONDS="null"
  WL_ACTUAL_WORKSPACES="null"
  WL_ACTUAL_PANES="null"
  WL_NOTE="attached to a running app; workload built (and each pane primed) outside this script, see scripts/BENCH.md"
  echo "bench.sh: attaching to already-running $APP_PATH (pid $MAIN_PID). Launch time is not measured (manual)." >&2
}

# --- Live shells -----------------------------------------------------------
# Pane shells under the app's process tree: outermost zsh/bash/sh/fish/... processes (login "-zsh"
# included, subshells not). Every pane must have exactly one before anything is measured: wait up
# to 30s, then fail.
count_shells() {  # $1 = "list" prints the app's whole descendant tree instead of the count
  ROOT_PID="$MAIN_PID" APP_PATH="$APP_PATH" python3 - "${1:-}" <<'SHELLS'
import os, re, subprocess, sys
app = os.environ["APP_PATH"].rstrip("/") + "/"
rows = []
for line in subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout.splitlines():
    m = re.match(r"\s*(\d+)\s+(\d+)\s+(.*)$", line)
    if m: rows.append((int(m.group(1)), int(m.group(2)), m.group(3)))
roots = {p for p, _, c in rows if c.startswith(app)} | {int(os.environ["ROOT_PID"])}
kids = {}
for p, pp, c in rows: kids.setdefault(pp, []).append((p, c))
seen, todo, desc = set(roots), list(roots), []
while todo:
    for p, c in kids.get(todo.pop(), []):
        if p not in seen: seen.add(p); todo.append(p); desc.append((p, c))
SH = {"zsh", "bash", "sh", "fish", "tcsh", "csh", "ksh", "dash", "nu"}
def is_shell(c): return os.path.basename(c).lstrip("-") in SH
comm = {p: c for p, _, c in rows}
parent = {p: pp for p, pp, _ in rows}
if sys.argv[1] == "list":
    for p, c in desc: print(f"  {p} (ppid {parent[p]}) {c}")
else:
    # A pane's shell is the outermost one: its parent (login, or the app) is not a shell itself.
    # Subshells -- $(...) in an rc file, a script, `bash` typed at the prompt -- don't count.
    print(sum(1 for p, c in desc if is_shell(c) and not is_shell(comm.get(parent[p], ""))))
SHELLS
}

check_shells_live() {
  for _ in $(seq 1 60); do
    SHELLS_LIVE="$(count_shells)"
    [ "$SHELLS_LIVE" -ge "$WL_PANES" ] && break
    sleep 0.5
  done
  echo "bench.sh: live shells under the app: $SHELLS_LIVE (expected $WL_PANES)" >&2
  if [ "$SHELLS_LIVE" -ne "$WL_PANES" ]; then
    echo "bench.sh: processes under the app:" >&2
    count_shells list >&2
    echo "bench.sh: $SHELLS_LIVE live shells, expected exactly $WL_PANES (one per pane); not measuring" >&2
    exit 3
  fi
}

# --- App size (constant across reps) ---------------------------------------
APP_SIZE_KB="$(du -sk "$APP_PATH" 2>/dev/null | awk '{print $1}')"
APP_SIZE_MB="$(python3 -c "print(round($APP_SIZE_KB/1024,1))")"

# --- Process discovery, memory, CPU (the hard part lives in Python: ps
# output has arbitrary-width paths/args, and we need percentile math). ---
# Written to a temp file and run outside any command substitution: bash
# 3.2 (macOS's /bin/bash) mis-parses a heredoc nested inside $(...) once
# the body's quote count hits certain parity, so this avoids that nesting
# entirely rather than fighting it. Reused for every rep.
MEASURE_PY="$(mktemp /tmp/lmux-bench-measure.XXXXXX.py)"
MEASURE_OUT="$(mktemp /tmp/lmux-bench-measure.XXXXXX.json)"
REPDIR="$(mktemp -d /tmp/lmux-bench-reps.XXXXXX)"
trap 'rm -rf "$REPDIR"; rm -f "$MEASURE_PY" "$MEASURE_OUT"; cleanup' EXIT
cat > "$MEASURE_PY" <<'PY'
import os, re, subprocess, sys, time, json

app_path = os.environ["APP_PATH"].rstrip("/") + "/"
main_bin = os.environ["MAIN_BIN"]
root_pids = {int(p) for p in os.environ["ROOT_PIDS"].split() if p.strip()}
settle = float(os.environ["SETTLE"])
sample = int(os.environ["SAMPLE"])

def ps_table():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(.*)$", line)
        if m:
            rows.append((int(m.group(1)), int(m.group(2)), m.group(3)))
    return rows

def classify(rows):
    bundle = {pid for pid, ppid, comm in rows if comm == main_bin or comm.startswith(app_path)}
    main = {pid for pid, ppid, comm in rows if comm == main_bin} or set(root_pids)
    if not bundle:
        bundle = set(root_pids)
    helpers = bundle - main

    children = {}
    for pid, ppid, comm in rows:
        children.setdefault(ppid, []).append(pid)

    # XPC/system-WebKit processes the app spawned show up with ppid=1
    # (reparented to launchd), so they can't be found by walking ppid.
    # The only reliable signal is the kernel's "responsible pid", which
    # `launchctl procinfo` only reports when run as root. Try it; if root
    # isn't available, leave this group honestly empty rather than guess
    # by process name (a name match without responsible-pid verification
    # WILL attribute other apps' unrelated WebKit/XPC processes to this
    # one -- tested and confirmed wrong in practice).
    webkit = set()
    webkit_note = ("no 'webkit'-named processes with ppid=1 seen; nothing to attribute"
                   if not any(ppid == 1 and "webkit" in comm.lower() for _, ppid, comm in rows)
                   else "empty: responsible-pid lookup needs root (launchctl procinfo); re-run with sudo to measure this group")
    for pid, ppid, comm in rows:
        if ppid != 1 or "webkit" not in comm.lower() or pid in bundle:
            continue
        try:
            out = subprocess.run(["launchctl", "procinfo", str(pid)], capture_output=True, text=True, timeout=5)
        except Exception:
            break
        if out.returncode != 0:
            webkit_note = "empty: responsible-pid lookup needs root (launchctl procinfo); re-run with sudo to measure this group"
            break
        m = re.search(r"responsible:\s*(\d+)", out.stdout)
        if m and int(m.group(1)) in bundle:
            webkit.add(pid)
            webkit_note = "matched via launchctl procinfo responsible-pid"

    # Transitive descendants of the whole bundle (shells, and whatever
    # runs in them -- e.g. `claude`). Not app overhead: reported apart.
    seen = set(bundle)
    frontier = list(bundle)
    shell_children = set()
    while frontier:
        nxt = []
        for p in frontier:
            for c in children.get(p, []):
                if c in seen:
                    continue
                seen.add(c)
                if c not in webkit:
                    shell_children.add(c)
                nxt.append(c)
        frontier = nxt

    return {
        "main": sorted(main),
        "bundle_helpers": sorted(helpers),
        "xpc_webkit": sorted(webkit),
        "shell_children": sorted(shell_children),
    }, webkit_note

def rss_mb(pids):
    if not pids:
        return 0.0
    out = subprocess.run(["ps", "-o", "rss=", "-p", ",".join(map(str, pids))],
                          capture_output=True, text=True).stdout
    total_kb = sum(int(x) for x in out.split() if x.strip().isdigit())
    return round(total_kb / 1024, 1)

_UNIT = {"B": 1 / 1024 / 1024, "KB": 1 / 1024, "MB": 1, "GB": 1024}

def footprint_mb_one(pid):
    for cmd in (["footprint", "-p", str(pid)], ["vmmap", "--summary", str(pid)]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout
        except Exception:
            continue
        m = re.search(r"phys_footprint:\s*([\d.]+)\s*(KB|MB|GB|B)", out, re.I) \
            or re.search(r"Physical footprint:\s*([\d.]+)\s*([KMG]?B)", out, re.I)
        if m:
            val, unit = float(m.group(1)), m.group(2).upper()
            if unit in ("K",): unit = "KB"
            if unit in ("M",): unit = "MB"
            if unit in ("G",): unit = "GB"
            return val * _UNIT.get(unit, 1)
    return 0.0

def footprint_mb(pids):
    return round(sum(footprint_mb_one(p) for p in pids), 1)

def cpu_pct_snapshot(pids):
    if not pids:
        return {}
    out = subprocess.run(["ps", "-o", "pid=,%cpu=", "-p", ",".join(map(str, pids))],
                          capture_output=True, text=True).stdout
    result = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2:
            result[int(parts[0])] = float(parts[1])
    return result

def mean(xs):
    return round(sum(xs) / len(xs), 2) if xs else 0.0

def p95(xs):
    if not xs:
        return 0.0
    s = sorted(xs)
    idx = max(0, min(len(s) - 1, int(round(0.95 * (len(s) - 1)))))
    return round(s[idx], 2)

groups, webkit_note = classify(ps_table())
all_pids = sorted(set(groups["main"]) | set(groups["bundle_helpers"])
                   | set(groups["xpc_webkit"]) | set(groups["shell_children"]))

time.sleep(settle)

memory_mb = {}
for g, pids in groups.items():
    memory_mb[g] = {"rss": rss_mb(pids), "footprint": footprint_mb(pids)}
app_only_pids = set(groups["main"]) | set(groups["bundle_helpers"]) | set(groups["xpc_webkit"])
memory_mb["app_total"] = {
    "rss": round(memory_mb["main"]["rss"] + memory_mb["bundle_helpers"]["rss"] + memory_mb["xpc_webkit"]["rss"], 1),
    "footprint": round(memory_mb["main"]["footprint"] + memory_mb["bundle_helpers"]["footprint"] + memory_mb["xpc_webkit"]["footprint"], 1),
}

series = {g: [] for g in groups}
series["app_total"] = []
for _ in range(sample):
    snap = cpu_pct_snapshot(all_pids)
    for g, pids in groups.items():
        series[g].append(sum(snap.get(p, 0.0) for p in pids))
    series["app_total"].append(sum(snap.get(p, 0.0) for p in app_only_pids))
    time.sleep(1)

cpu_pct = {"settle_seconds": settle, "sample_seconds": sample}
for g, xs in series.items():
    cpu_pct[g] = {"mean": mean(xs), "p95": p95(xs)}

print(json.dumps({
    "process_groups": {g: {"pids": pids} for g, pids in groups.items()},
    "memory_mb": memory_mb,
    "cpu_pct": cpu_pct,
    "xpc_webkit_note": webkit_note,
}))
PY

# --- Reps: acquire (lmux: fresh each rep; others: once) + settle/sample. ---
if [ "$APP_KIND" != "lmux" ]; then
  acquire_other
fi
for REP in $(seq 1 "$REPS"); do
  echo "bench.sh: rep $REP/$REPS..." >&2
  if [ "$APP_KIND" = "lmux" ]; then
    acquire_lmux
  fi

  check_shells_live

  echo "bench.sh: rep $REP/$REPS: settling ${SETTLE}s, then sampling ${SAMPLE}s (workload=$WORKLOAD)..." >&2
  APP_PATH="$APP_PATH" MAIN_BIN="$MAIN_BIN" ROOT_PIDS="$MAIN_PID" \
    SETTLE="$SETTLE" SAMPLE="$SAMPLE" python3 "$MEASURE_PY" > "$MEASURE_OUT"
  MEASURE_JSON="$(cat "$MEASURE_OUT")"

  jq -n \
    --argjson rep "$REP" \
    --arg launch_mode "$LAUNCH_MODE" \
    --argjson launch_seconds "$LAUNCH_SECONDS" \
    --argjson wl_actual_workspaces "$WL_ACTUAL_WORKSPACES" \
    --argjson wl_actual_panes "$WL_ACTUAL_PANES" \
    --argjson shells_live "$SHELLS_LIVE" \
    --arg wl_note "$WL_NOTE" \
    --argjson measure "$MEASURE_JSON" \
    '{
      rep: $rep,
      launch: { mode: $launch_mode, seconds: $launch_seconds },
      workload_detail: {
        actual_workspaces: $wl_actual_workspaces,
        actual_panes: $wl_actual_panes,
        shells_live: $shells_live,
        note: $wl_note
      }
    } + $measure' > "$REPDIR/rep-$(printf '%03d' "$REP").json"

  if [ "$APP_KIND" = "lmux" ]; then
    cleanup  # fresh launch next rep: kill this one, wipe its temp state dir
  fi
done

# --- Aggregate across reps: median/min/max of footprint and idle-CPU mean,
# plus launch seconds (lmux only; null -> omitted for attach-only apps). ----
REP_RESULTS_JSON="$(jq -s '.' "$REPDIR"/rep-*.json)"
AGGREGATE_JSON="$(python3 -c '
import json, sys, statistics

reps = json.load(sys.stdin)

def stats(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return {"median": round(statistics.median(xs), 3), "min": round(min(xs), 3), "max": round(max(xs), 3)}

print(json.dumps({
    "footprint_mb": stats([r["memory_mb"]["app_total"]["footprint"] for r in reps]),
    "cpu_mean_pct": stats([r["cpu_pct"]["app_total"]["mean"] for r in reps]),
    "launch_seconds": stats([r["launch"]["seconds"] for r in reps]),
}))
' <<<"$REP_RESULTS_JSON")"

TS="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"))')"
OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
ARCH="$(uname -m)"

# Top-level launch/workload_detail/memory_mb/cpu_pct/xpc_webkit_note mirror
# the LAST rep (quick human inspection); `aggregate` + `rep_results` are what
# scripts/bench-compare.sh and the charts actually read.
jq -n \
  --arg label "$LABEL" \
  --arg app_kind "$APP_KIND" \
  --arg app_path "$APP_PATH" \
  --arg bundle_id "$BUNDLE_ID" \
  --arg version "$APP_SIZE_VERSION" \
  --arg workload "$WORKLOAD" \
  --arg timestamp "$TS" \
  --arg os_version "$OS_VERSION" \
  --arg arch "$ARCH" \
  --argjson app_size_mb "$APP_SIZE_MB" \
  --arg launch_mode "$LAUNCH_MODE" \
  --argjson launch_seconds "$LAUNCH_SECONDS" \
  --argjson wl_cli_used "$WL_CLI_USED" \
  --argjson wl_requested_workspaces "$WL_WORKSPACES" \
  --argjson wl_requested_panes "$WL_PANES" \
  --argjson wl_actual_workspaces "$WL_ACTUAL_WORKSPACES" \
  --argjson wl_actual_panes "$WL_ACTUAL_PANES" \
  --argjson shells_live "$SHELLS_LIVE" \
  --arg wl_note "$WL_NOTE" \
  --argjson measure "$MEASURE_JSON" \
  --argjson reps "$REPS" \
  --argjson rep_results "$REP_RESULTS_JSON" \
  --argjson aggregate "$AGGREGATE_JSON" \
  '{
    label: $label,
    app_kind: $app_kind,
    app_path: $app_path,
    bundle_id: $bundle_id,
    version: $version,
    workload: $workload,
    timestamp: $timestamp,
    host: { os_version: $os_version, arch: $arch },
    app_size: { mb: $app_size_mb },
    launch: { mode: $launch_mode, seconds: $launch_seconds },
    workload_detail: {
      cli_used: $wl_cli_used,
      requested_workspaces: $wl_requested_workspaces,
      requested_panes: $wl_requested_panes,
      actual_workspaces: $wl_actual_workspaces,
      actual_panes: $wl_actual_panes,
      shells_expected: $wl_requested_panes,
      shells_live: $shells_live,
      note: $wl_note
    },
    reps: $reps,
    rep_results: $rep_results,
    aggregate: $aggregate
  } + $measure' > "$OUT"

echo "bench.sh: wrote $OUT" >&2
jq -r '"\(.label) [\(.workload_detail.requested_workspaces) ws / \(.workload_detail.shells_live) shells, \(.reps) rep(s)]: app \(.app_size.mb) MB, footprint \(.aggregate.footprint_mb.median) MB (min \(.aggregate.footprint_mb.min) / max \(.aggregate.footprint_mb.max)), idle CPU \(.aggregate.cpu_mean_pct.median)% median (min \(.aggregate.cpu_mean_pct.min) / max \(.aggregate.cpu_mean_pct.max)), launch \(.launch.seconds // "manual")"' "$OUT" >&2
