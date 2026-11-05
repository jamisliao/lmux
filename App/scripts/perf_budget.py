#!/usr/bin/env python3
"""Performance budgets of lmux.app, headless (LMUX_HEADLESS=1: no window, no focus change).

    App/scripts/perf_budget.py [scenario ...]     (default: all; needs App/scripts/bundle.sh first)

Scenarios (each prints its numbers and PASS/FAIL against a budget with a wide margin, so a
noisy CI runner doesn't flake but a regression of the kind fixed before does fail):
  idle20      20 workspaces x 2 panes, idle: CPU and footprint
  footprint   phys_footprint (graphics included) of 1 x 2 and 20 x 2 with lmux in the background (window
              not key: no pane focused, idle panes release their GPU memory) and 1 x 2 in front (the
              focused pane keeps its GPU memory); meaningful on a real Mac, see BUDGET
  running     10 x 2, the 18 hidden panes' Claude running, a tool event every 1.5s each (12 events/s)
  events      per hook event app CPU (10 events/s into running hidden panes)
              (both: the same tool call over and over, so the rows' text stays put; an event that
              changes what a row says costs a SwiftUI row update + a Core Animation commit on top)
  titles      9 hidden panes repaint a spinner title (OSC 2) every 100ms
  hidden      memory per workspace: never shown vs shown once then hidden
  tabs        memory per tab behind another (never shown / shown once), the tab bar of 20 x 2 one-tab
              panes (on vs off), and 1 pane + 9 tabs behind it in front vs in the background
  restore     120 workspaces x 1 pane (same folder) restored: ready time, then new workspace time
  indexer     History first index of a synthetic corpus with big transcripts: peak footprint

Every pane runs an isolated zsh (temp ZDOTDIR / HISTFILE), Claude is never started (hook events
are synthetic, sent on the real hook socket), and state, projects and config are temp dirs.
"""
import ctypes, ctypes.util, json, os, plistlib, random, shutil, signal, socket, subprocess, sys, tempfile, time, uuid

APP = os.environ.get("LMUX_APP", os.path.join(os.path.dirname(os.path.abspath(__file__)), "../build/lmux.app"))
EXE = os.path.join(APP, "Contents/MacOS/lmux")

# Budgets: measured values (release, M-series laptop) are in the PR; these leave 2-5x room.
BUDGET = {
    "idle20_cpu_pct": 0.8, "idle20_foot_mb": 420,
    # phys_footprint incl. graphics. Real Mac (M4 Pro, macOS 26): background 1x2 / 20x2 ~45 / ~99 MB,
    # 1x2 in front ~182 MB; before the idle GPU release they were 235 / 340 / 235. The background caps
    # (>= 2x) fail when Metal's per-process driver memory (~115 MB) stays held; the front one only
    # catches gross growth. GitHub's macOS VM barely counts GPU memory: there these pass either way.
    "foot_bg_1x2_mb": 100, "foot_bg_20x2_mb": 200, "foot_fg_1x2_mb": 300,
    "running_cpu_pct": 1.5,
    "event_cpu_ms": 1.5,
    "titles_cpu_pct": 2.5,
    "never_shown_mb": 8, "shown_hidden_mb": 12,
    "tab_never_shown_mb": 8, "tab_shown_hidden_mb": 12, "tab_bar_40_mb": 8, "foot_bg_1x10tabs_mb": 110,
    "restore120_ready_s": 3.0, "new_ws_at120_ms": 600,
    "indexer_peak_mb": 150,
}

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)


class RU(ctypes.Structure):  # rusage_info_v4 (proc_pid_rusage flavor 4), the fields we read come first
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint "
        "proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups "
        "child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten "
        "qos_default qos_maintenance qos_background qos_utility qos_legacy qos_user_initiated qos_user_interactive "
        "billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles "
        "billed_energy serviced_energy interval_max_phys_footprint runnable_time").split()]


class TB(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = TB()
libc.mach_timebase_info(ctypes.byref(_tb))
TICK = _tb.numer / _tb.denom / 1e9


def usage(pid):
    r = RU()
    if libc.proc_pid_rusage(int(pid), 4, ctypes.byref(r)) != 0:
        raise RuntimeError(f"lmux {pid} is gone")
    return (r.user_time + r.system_time) * TICK, r.phys_footprint / 2**20


def cpu_pct(pid, secs):
    c0, _ = usage(pid); t0 = time.time()
    time.sleep(secs)
    c1, foot = usage(pid)
    return 100 * (c1 - c0) / (time.time() - t0), foot


def hist_stamp():
    try:
        st = os.stat(os.path.expanduser("~/.zsh_history")); return (st.st_size, int(st.st_mtime))
    except FileNotFoundError:
        return None


def tree(k, axis="horizontal"):
    if k == 1:
        pid = str(uuid.uuid4()).upper(); return {"pane": {"id": pid}}, [pid]
    a = k // 2; nxt = "vertical" if axis == "horizontal" else "horizontal"
    l, li = tree(a, nxt); r, ri = tree(k - a, nxt)
    return {"axis": axis, "ratio": a / k, "children": [l, r]}, li + ri


class Lmux:
    """One headless lmux on a temp state dir with a restored layout of `workspaces` x `per` panes."""

    def __init__(self, workspaces, per, env=None, tabs=1, settings=None):
        self.dir = tempfile.mkdtemp(prefix="lmux-perf.", dir="/tmp")  # short: socket paths < 104 bytes
        state = os.path.join(self.dir, "s"); os.makedirs(state)
        self.panes = []
        ws = []
        for i in range(workspaces):
            t, ids = tree(per)
            if tabs > 1:  # one leaf (per == 1) holding `tabs` tabs, the first shown
                extra = [str(uuid.uuid4()).upper() for _ in range(tabs - 1)]
                t = {"pane": t["pane"], "tabs": [t["pane"]] + [{"id": e} for e in extra], "selectedTab": 0}; ids += extra
            ws.append({"id": str(uuid.uuid4()).upper(), "accent": i % 8, "root": t}); self.panes.append(ids)
        if ws:
            json.dump({"version": 1, "workspaces": ws, "selected": ws[0]["id"], "sidebarVisible": True, "sidebarWidth": 240},
                      open(os.path.join(state, "layout.json"), "w"))
        plistlib.dump(dict({"remindAfterMinutes": 0}, **(settings or {})), open(os.path.join(state, "settings.plist"), "wb"))
        sh = os.path.join(self.dir, "sh"); os.makedirs(os.path.join(sh, "zdot"))
        hist = os.path.join(sh, "zsh_history"); open(hist, "w").close()
        open(os.path.join(sh, "zdot/.zshrc"), "w").write(f"HISTFILE='{hist}'\nPROMPT='%~ %# '\n")
        self.pane_shell = os.path.join(sh, "pane-shell")
        # Each pane leaves its LMUX_PANE_NONCE here: the app drops hook events and `send`s without it.
        self.tokens_file, self.tokens = os.path.join(self.dir, "tokens"), {}
        open(self.pane_shell, "w").write(f"#!/bin/sh\nexport ZDOTDIR='{sh}/zdot' HISTFILE='{hist}' SHELL_SESSIONS_DISABLE=1\n"
                                         f'echo "$LMUX_PANE_ID $LMUX_PANE_NONCE" >> \'{self.tokens_file}\'\n'
                                         'exec /bin/zsh "$@"\n')
        os.chmod(self.pane_shell, 0o755)
        cfg = os.path.join(self.dir, "claude"); self.projects = os.path.join(cfg, "projects"); os.makedirs(self.projects)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE", "LMUX_", "GHOSTTY_", "TERM_PROGRAM", "CMUX_"))}
        self.env.update({"LMUX_HEADLESS": "1", "LMUX_STATE_DIR": state, "LMUX_PANE_COMMAND": self.pane_shell,
                         "SHELL_SESSIONS_DISABLE": "1", "HISTFILE": hist, "CLAUDE_CONFIG_DIR": cfg,
                         "LMUX_CLAUDE_PROJECTS": self.projects, "LMUX_CONFIG_FILE": os.path.join(self.dir, "config"),
                         "LMUX_CMUX_HOME": os.path.join(self.dir, "no-cmux"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        self.env.update(env or {})
        self.ctl_sock = os.path.join(state, "control.sock"); self.hook_sock = os.path.join(state, "lmux.sock")
        self.proc = None

    def __enter__(self):
        t0 = time.time()
        self.proc = subprocess.Popen([EXE], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=self.dir)
        self.pid = self.proc.pid
        end = t0 + 60
        while time.time() < end:
            try:
                if self.ctl({"cmd": "list"}, timeout=0.5).get("ok"): break
            except OSError:
                time.sleep(0.02)
        else:
            raise RuntimeError("lmux did not answer on its control socket")
        self.ready_s = time.time() - t0
        return self

    def __exit__(self, *a):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try: self.proc.wait(5)
            except subprocess.TimeoutExpired: self.proc.kill()
        shutil.rmtree(self.dir, ignore_errors=True)

    def ctl(self, req, timeout=30):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(timeout)
        s.connect(self.ctl_sock); s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            d = s.recv(65536)
            if not d: break
            buf += d
        s.close(); return json.loads(buf)

    def token(self, pane):
        if pane not in self.tokens:
            self.tokens = dict(l.split() for l in open(self.tokens_file) if len(l.split()) == 2)
        return self.tokens[pane]

    def hook(self, sock, pane, payload):
        sock.sendall((json.dumps({"lmux": 1, "pane": pane, "token": self.token(pane), "sent_ns": time.time_ns(),
                                  "hook": payload}) + "\n").encode())

    def states(self):
        return {p["id"]: p for ws in self.ctl({"cmd": "list"})["workspaces"] for p in ws["panes"]}

    def hook_socket(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(self.hook_sock); return s

    def start_claude(self, sock, panes):
        for i, p in enumerate(panes):
            ev = {"session_id": f"perf-{i}", "cwd": "/tmp"}
            self.hook(sock, p, dict(ev, hook_event_name="SessionStart", source="startup"))
            self.hook(sock, p, dict(ev, hook_event_name="UserPromptSubmit", prompt="go"))
        end = time.time() + 10
        while any(self.states()[p]["state"] != "running" for p in panes):
            if time.time() > end: raise RuntimeError("hook events had no effect: the panes' Claude never started running")
            time.sleep(0.2)

    def wait_shells(self, n, timeout=30):
        """Until `n` panes started their shell (login(1) runs it with the pane-shell path in argv)."""
        end = time.time() + timeout
        while time.time() < end:
            if len(subprocess.run(["pgrep", "-f", self.pane_shell], capture_output=True, text=True).stdout.split()) >= n: return
            time.sleep(0.3)


results, failures = [], []


def check(name, value, budget, unit):
    ok = value < budget
    results.append((name, value, budget, unit, ok))
    print(f"{'PASS' if ok else 'FAIL'}  [perf] {name}: {value:.3g}{unit} (budget < {budget}{unit})", flush=True)
    if not ok: failures.append(name)


def s_idle20():
    with Lmux(20, 2) as L:
        L.wait_shells(40); time.sleep(10)
        cpu, foot = cpu_pct(L.pid, 20)
        check("idle 20x2 CPU", cpu, BUDGET["idle20_cpu_pct"], "%")
        check("idle 20x2 footprint", foot, BUDGET["idle20_foot_mb"], "MB")


def s_footprint():
    # Headless LMUX_HEADLESS_BACKGROUND=1: the window counts as not key, like lmux behind another app.
    for (w, per), key in (((1, 2), "foot_bg_1x2_mb"), ((20, 2), "foot_bg_20x2_mb")):
        with Lmux(w, per, env={"LMUX_HEADLESS_BACKGROUND": "1"}) as L:
            L.wait_shells(w * per); time.sleep(12)  # idle GPU release after 3 s without a frame
            check(f"footprint {w}x{per}, lmux in the background", usage(L.pid)[1], BUDGET[key], "MB")
    with Lmux(1, 2) as L:
        L.wait_shells(2); time.sleep(12)
        check("footprint 1x2, lmux in front (focused pane blinking)", usage(L.pid)[1], BUDGET["foot_fg_1x2_mb"], "MB")


def s_running():
    with Lmux(10, 2) as L:
        L.wait_shells(20); time.sleep(6)
        hidden = [p for ws in L.panes[1:] for p in ws]
        s = L.hook_socket(); L.start_claude(s, hidden)
        c0, _ = usage(L.pid); t0 = time.time(); n = 0
        while time.time() - t0 < 20:
            p = hidden[n % len(hidden)]
            L.hook(s, p, {"session_id": f"perf-{hidden.index(p)}", "cwd": "/tmp", "tool_name": "Bash",
                          "tool_input": {"command": "npm test"}, "hook_event_name": "PreToolUse" if n % 2 == 0 else "PostToolUse"})
            n += 1; time.sleep(1 / 12)
        c1, _ = usage(L.pid); s.close()
        check("18 hidden panes running, 12 tool events/s: CPU", 100 * (c1 - c0) / (time.time() - t0), BUDGET["running_cpu_pct"], "%")


def s_events():
    with Lmux(20, 1) as L:
        L.wait_shells(20); time.sleep(6)
        hidden = [ws[0] for ws in L.panes[1:]]
        s = L.hook_socket(); L.start_claude(s, hidden); time.sleep(2)
        base, _ = cpu_pct(L.pid, 8)
        c0, _ = usage(L.pid); t0 = time.time(); n = 0
        while time.time() - t0 < 15:
            p = hidden[n % len(hidden)]
            L.hook(s, p, {"session_id": f"perf-{hidden.index(p)}", "cwd": "/tmp", "tool_name": "Bash",
                          "tool_input": {"command": "npm test"}, "hook_event_name": "PreToolUse" if n % 2 == 0 else "PostToolUse"})
            n += 1; time.sleep(0.1)
        wall = time.time() - t0; c1, _ = usage(L.pid); s.close()
        per = 1000 * ((c1 - c0) - base / 100 * wall) / n
        check("app CPU per hook event (one at a time, 10/s, same tool call)", per, BUDGET["event_cpu_ms"], "ms")


def s_titles():
    with Lmux(10, 1) as L:
        L.wait_shells(10); time.sleep(6)
        spin = os.path.join(L.dir, "spin.py")
        open(spin, "w").write("import sys,time\ng='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'\ni=0\nwhile True:\n i+=1\n"
                              " sys.stdout.write('\\x1b]2;%s Fixing the refund validation\\x07'%g[i%10]);sys.stdout.flush();time.sleep(0.1)\n")
        for ws in L.panes[1:]:
            L.ctl({"cmd": "send", "pane": ws[0], "token": L.token(ws[0]), "text": f"/usr/bin/python3 {spin}\n"})
        time.sleep(4)
        if not all("Fixing the refund validation" in L.states()[ws[0]]["title"] for ws in L.panes[1:]):
            raise RuntimeError("the spinner never ran: its panes' titles did not change")
        cpu, _ = cpu_pct(L.pid, 15)
        check("9 hidden panes repainting a spinner title 10x/s: CPU", cpu, BUDGET["titles_cpu_pct"], "%")


def s_hidden():
    k = 10
    with Lmux(1, 1) as L:
        L.wait_shells(1); time.sleep(8); a = usage(L.pid)[1]
    with Lmux(1 + k, 1) as L:
        L.wait_shells(1 + k); time.sleep(10); b = usage(L.pid)[1]
    check("memory per never-shown workspace", (b - a) / k, BUDGET["never_shown_mb"], "MB")
    with Lmux(1, 1) as L:
        L.wait_shells(1); time.sleep(8); c = usage(L.pid)[1]
        for _ in range(k):
            L.ctl({"cmd": "new-workspace"}); time.sleep(1.5)  # selected (shown), then hidden by the next one
        time.sleep(8); d = usage(L.pid)[1]
    check("memory per workspace shown once, then hidden", (d - c) / k, BUDGET["shown_hidden_mb"], "MB")


def s_tabs():
    k = 9
    with Lmux(1, 1) as L:
        L.wait_shells(1); time.sleep(8); a = usage(L.pid)[1]
    with Lmux(1, 1, tabs=1 + k) as L:
        L.wait_shells(1 + k); time.sleep(10); b = usage(L.pid)[1]
    print(f"      1 pane: {a:.1f}MB; with {k} tabs behind it (never shown): {b:.1f}MB", flush=True)
    check("memory per tab behind another, never shown", (b - a) / k, BUDGET["tab_never_shown_mb"], "MB")
    with Lmux(1, 1) as L:
        L.wait_shells(1); time.sleep(8); c = usage(L.pid)[1]
        for _ in range(k):
            L.ctl({"cmd": "new-tab"}); time.sleep(1.5)  # shown, then put behind by the next one
        time.sleep(8); d = usage(L.pid)[1]
    print(f"      1 pane: {c:.1f}MB; after {k} tabs each shown once: {d:.1f}MB", flush=True)
    check("memory per tab shown once, then behind another", (d - c) / k, BUDGET["tab_shown_hidden_mb"], "MB")
    foot = {}
    for on in (True, False):
        with Lmux(20, 2, env={"LMUX_HEADLESS_BACKGROUND": "1"}, settings={"tabBarWithOneTab": on}) as L:
            L.wait_shells(40); time.sleep(12)
            foot[on] = usage(L.pid)[1]
    print(f"      20x2 one-tab panes in the background: tab bar on {foot[True]:.1f}MB, off {foot[False]:.1f}MB", flush=True)
    check("the tab bar on 40 one-tab panes (20x2, on minus off)", foot[True] - foot[False], BUDGET["tab_bar_40_mb"], "MB")
    with Lmux(1, 1, tabs=1 + k, env={"LMUX_HEADLESS_BACKGROUND": "1"}) as L:
        L.wait_shells(1 + k); time.sleep(12); bg = usage(L.pid)[1]
    with Lmux(1, 1, tabs=1 + k) as L:
        L.wait_shells(1 + k); time.sleep(12); fg = usage(L.pid)[1]
    print(f"      1 pane + {k} tabs behind it: lmux in front {fg:.1f}MB, in the background {bg:.1f}MB", flush=True)
    check(f"footprint 1 pane + {k} tabs, lmux in the background", bg, BUDGET["foot_bg_1x10tabs_mb"], "MB")


def s_restore():
    with Lmux(120, 1) as L:
        check("restore 120 workspaces x 1 pane (same folder): ready", L.ready_s, BUDGET["restore120_ready_s"], "s")
        L.wait_shells(120, timeout=60); time.sleep(5)
        walls = []
        for _ in range(5):
            t0 = time.time(); L.ctl({"cmd": "new-workspace"}); L.ctl({"cmd": "list"}); walls.append(1000 * (time.time() - t0))
            time.sleep(0.5)
        check("new workspace next to 120 others (median of 5)", sorted(walls)[2], BUDGET["new_ws_at120_ms"], "ms")


def s_indexer():
    root = tempfile.mkdtemp(prefix="lmux-perf-index.", dir="/tmp")
    try:
        random.seed(7)
        words = "refund validation 환불 금액 검증 login bug test fix cache index session sidebar terminal render pane".split()
        projects = os.path.join(root, "projects")
        # 12 sessions of 25-45MB (mostly tool output, like long agent runs) + 40 small ones: ~450MB.
        sizes = [random.randint(25, 45) << 20 for _ in range(12)] + [random.randint(20, 400) << 10 for _ in range(40)]
        for s, size in enumerate(sizes):
            proj = os.path.join(projects, f"-tmp-proj{s % 5}"); os.makedirs(proj, exist_ok=True)
            sid = f"{s:08d}-0000-4000-8000-{s:012d}"
            c = f'"isSidechain":false,"userType":"external","cwd":"/tmp/proj{s % 5}","sessionId":"{sid}","version":"2.1.280","timestamp":"2026-10-01T10:00:00Z"'
            parent, n, w = "null", 0, 0
            with open(os.path.join(proj, sid + ".jsonl"), "w") as f:
                while w < size:
                    n += 1
                    prompt = json.dumps(" ".join(random.choice(words) for _ in range(30)))
                    blob = json.dumps(" ".join(random.choice(words) for _ in range(random.randint(2000, 40000))))
                    lines = [
                        '{"parentUuid":%s,%s,"type":"user","message":{"role":"user","content":%s},"uuid":"%s-u%d","turnOrigin":"human"}' % (parent, c, prompt, sid, n),
                        '{"parentUuid":"%s-u%d",%s,"type":"assistant","message":{"id":"m%d","role":"assistant","content":[{"type":"tool_use","id":"t%d","name":"Bash","input":{"command":"cat log"}}]},"uuid":"%s-t%d"}' % (sid, n, c, n, n, sid, n),
                        '{"parentUuid":"%s-t%d",%s,"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%d","content":%s}]},"uuid":"%s-r%d","toolUseResult":{"stdout":%s}}' % (sid, n, c, n, blob, sid, n, blob),
                        '{"parentUuid":"%s-r%d",%s,"type":"assistant","message":{"id":"m%da","role":"assistant","content":[{"type":"text","text":"Done"}]},"uuid":"%s-a%d"}' % (sid, n, c, n, sid, n),
                    ]
                    for l in lines: f.write(l + "\n"); w += len(l) + 1
                    parent = f'"{sid}-a{n}"'
        os.makedirs(os.path.join(root, "archive"))
        out = subprocess.run(["/usr/bin/time", "-l", EXE, "--lmux-index", "refresh", os.path.join(root, "sessions.db"), projects,
                              os.path.join(root, "archive")], capture_output=True, text=True)
        peak = next((int(l.split()[0]) for l in out.stderr.splitlines() if "peak memory footprint" in l), None)
        if out.returncode != 0 or peak is None:
            print(f"FAIL  [perf] History first index did not run: {out.returncode} {out.stderr[-300:]}"); failures.append("indexer"); return
        check(f"History first index of {sum(sizes) >> 20}MB (12 sessions of 25-45MB): peak footprint", peak / 2**20,
              BUDGET["indexer_peak_mb"], "MB")
    finally:
        shutil.rmtree(root, ignore_errors=True)


SCENARIOS = {"idle20": s_idle20, "footprint": s_footprint, "running": s_running, "events": s_events, "titles": s_titles,
             "hidden": s_hidden, "tabs": s_tabs, "restore": s_restore, "indexer": s_indexer}

if __name__ == "__main__":
    if not os.path.exists(EXE):
        sys.exit(f"no bundle at {APP}: run App/scripts/bundle.sh first")
    names = sys.argv[1:] or list(SCENARIOS)
    h0 = hist_stamp()
    for n in names:
        SCENARIOS[n]()
    if hist_stamp() != h0:
        print(f"FAIL  [hygiene] ~/.zsh_history changed during the run ({h0} -> {hist_stamp()})"); failures.append("history")
    else:
        print(f"PASS  [hygiene] ~/.zsh_history untouched ({h0})")
    print(f"{len(results) - len([r for r in results if not r[4]])}/{len(results)} budgets met")
    sys.exit(1 if failures else 0)
