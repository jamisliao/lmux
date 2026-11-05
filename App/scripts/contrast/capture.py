#!/usr/bin/env python3
"""Run the real Claude Code CLI against mock_api.py (a local fake Messages API: no model is
called, no login needed) inside a pty, and save what it draws: onboarding with THEME picked,
the Write / Edit preview with its permission dialog (preview.bin), then option 2 ("accept edits")
and the prompt box (raw.bin). HOME and CLAUDE_CONFIG_DIR are temp dirs under OUT_DIR: the
user's ~/.claude is never read or written. Then build_fixtures.py makes the .ans / .json.

  capture.py OUT_DIR THEME TOOL   THEME: default|light|dark-ansi|light-ansi|dark-daltonized|light-daltonized
                                  TOOL: Write|Edit|Markdown (CLAUDE_BIN: the claude binary, default: on PATH)
  Needs pyte (pip install pyte; PYTE_PATH: its site-packages if not importable).
"""
import re, json, os, pty, select, shutil, signal, socket, struct, fcntl, termios, time, subprocess, sys

out_dir, theme, tool = sys.argv[1], sys.argv[2], sys.argv[3]
here = os.path.dirname(os.path.abspath(__file__))
CLAUDE = os.environ.get("CLAUDE_BIN") or shutil.which("claude")
COLS, ROWS = 100, 50

root = os.path.join(out_dir, f"run-{theme}-{tool}")
shutil.rmtree(root, ignore_errors=True)
home, cfg, cwd = (os.path.join(root, d) for d in ("home", "cfg", "work"))
for d in (home, cfg, cwd):
    os.makedirs(d)
cwd = os.path.realpath(cwd)
key = "sk-ant-api03-mock-" + "x" * 60
state = {
    "hasCompletedOnboarding": True, "lastOnboardingVersion": "2.1.280", "numStartups": 5,
    "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []},
    "projects": {cwd: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True, "allowedTools": []}},
    "autoUpdates": False, "hasSeenTasksHint": True, "tipsHistory": {},
}
if theme != "default":
    state["theme"] = theme
for d in (cfg, home):
    with open(os.path.join(d, ".claude.json"), "w") as f: json.dump(state, f)
if tool == "Edit":
    sys.path.insert(0, here)
    os.environ["MOCK_CWD"] = cwd
    src = open(os.path.join(here, "mock_api.py")).read()
    py = src.split("PY = '''")[1].split("'''")[0]
    open(os.path.join(cwd, "invoice.py"), "w").write(py)

s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
srv = subprocess.Popen([sys.executable, os.path.join(here, "mock_api.py"), str(port)],
                       env={**os.environ, "MOCK_TOOL": tool, "MOCK_CWD": cwd, "MOCK_LOG": os.path.join(root, "api.log")})
time.sleep(0.5)

env = {
    "HOME": home, "CLAUDE_CONFIG_DIR": cfg, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "TERM": "xterm-256color", "COLORTERM": "truecolor", "LANG": "en_US.UTF-8",
    "ANTHROPIC_API_KEY": key, "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
    "DISABLE_TELEMETRY": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
    "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1", "TERM_PROGRAM": "ghostty",
}
prompt = {"Write": "create invoice.py", "Edit": "skip paid invoices in total()"}.get(tool, "how do I free the uv cache?")
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execve(CLAUDE, [CLAUDE, "--model", "haiku", prompt], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
if os.environ.get("PYTE_PATH"): sys.path.insert(0, os.environ["PYTE_PATH"])
import pyte
scr = pyte.Screen(COLS, ROWS); st = pyte.ByteStream(scr)
pick = {"default": None, "dark": "Dark mode", "light": "Light mode", "dark-ansi": "Dark mode (ANSI", "light-ansi": "Light mode (ANSI",
        "dark-daltonized": "Dark mode (colorblind", "light-daltonized": "Light mode (colorblind"}
done_steps = set(); last_act = 0; preview_at = None
buf = bytearray(); t0 = time.time()
end = time.time() + float(os.environ.get("CAP_SECS", "40"))
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        buf += data
        # answer terminal queries minimally (DA1, cursor position)
        if b"\x1b[6n" in data: os.write(fd, b"\x1b[1;1R")
        if b"\x1b[?u" in data: os.write(fd, b"\x1b[?0u")
        if b"\x1b[>0q" in data: os.write(fd, b"\x1bP>|ghostty 1.3.0\x1b\\")
        if b"\x1b[c" in data: os.write(fd, b"\x1b[?62;22c")
        st.feed(data)
    text = "\n".join(scr.display)
    if time.time() - last_act < 1.0:
        continue
    def act(name, keys):
        global last_act
        print("ACT", name, keys, file=sys.stderr); os.write(fd, keys); last_act = time.time(); done_steps.add(name)
        open(os.path.join(root, "steps.log"), "a").write(name + "\n" + text + "\n=====\n")
    if "Choose the text style" in text and len([x for x in done_steps if x.startswith("theme")]) < 4 and time.time() - t0 > 4:
        lines = scr.display
        num = {"default": None, "dark": 2, "light": 3, "dark-daltonized": 4, "light-daltonized": 5, "dark-ansi": 6, "light-ansi": 7}[theme]
        cur = next(i for i, l in enumerate(lines) if "\u276f" in l and re.search(r"\d\.", l))
        tgt = cur if num is None else next(i for i, l in enumerate(lines) if re.match(r"\s*(\u276f)?\s*%d\. " % num, l))
        keys = (b"\x1b[B" if tgt > cur else b"\x1b[A") * abs(tgt - cur) + b"\r"
        act("theme%d" % len(done_steps), keys if not done_steps else b"\r")
    elif "Do you want to use this API key" in text and "key" not in done_steps:
        act("key", b"\x1b[A\r")
    elif ("Security notes" in text or "Press Enter to continue" in text) and time.time() - last_act > 1.5 and len(done_steps) < 8:
        act("enter%d" % len(done_steps), b"\r")
    elif "Yes, I trust this folder" in text and "trust" not in done_steps:
        act("trust", b"\x1b[B\r" if "\u276f No" in text else b"\r")
    elif ("Do you want to create" in text or "Do you want to make this edit" in text) and preview_at is None:
        preview_at = time.time()
    if tool == "Markdown" and "Re-run" in text and "Done." in text and "trust" in done_steps:
        if "md_at" not in globals(): md_at = time.time()
        if time.time() - md_at > 2: break
    if preview_at and "preview" not in done_steps and time.time() - preview_at > 2:
        open(os.path.join(root, "preview.bin"), "wb").write(bytes(buf))
        act("preview", b"\x1b[B\r")   # 2. Yes, and switch to accept edits
    if "preview" in done_steps and "accept edits on" in text and "Done." in text:
        if "done_at" not in globals(): done_at = time.time()
        if time.time() - done_at > 2: break
os.kill(pid, signal.SIGKILL)
srv.terminate()
open(os.path.join(root, "raw.bin"), "wb").write(bytes(buf))
open(os.path.join(root, "screen.txt"), "w").write("\n".join(scr.display))
print(root, len(buf))
