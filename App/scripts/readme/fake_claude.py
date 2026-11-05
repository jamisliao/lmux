#!/usr/bin/env python3
# A stand-in for `claude` (started by ./claude) used only to render the README visuals
# (App/scripts/readme.sh).
# It replays a fixture session: draws the transcript the way Claude Code 2.1 lays it out,
# shows the input box, and answers typed prompts with canned replies. Hooks go through
# the real lmux-hook (SessionStart / UserPromptSubmit / Stop / SessionEnd), so lmux sees
# exactly what it sees from Claude Code. No model is ever called.
#
#   claude [--resume ID] [flags...]      session files: $FAKE_CLAUDE_DIR/*/<ID>.{jsonl,json}
#
# <ID>.jsonl is the transcript (Claude Code's format). <ID>.json holds what the screen
# shows per prompt ({"screens": {prompt: text}}), canned replies for new prompts
# ({"replies": [{"match": "...", "screen": "...", "reply": "..."}]}), and optionally a
# permission "dialog" (drawn instead of the input box) or a "working" line. It is re-read
# when it changes, so the harness can raise a permission prompt mid-scene. With a dialog up,
# `1` or Enter approves it: the dialog goes, "approved" (screen text) is added to the last
# turn, "approved_working" becomes the working line and PostToolUse goes to lmux, like Claude
# Code running the approved tool.
#
# Stepped (meta "step": true, the hero video): a reply's screen and the approved text appear
# one line per SIGUSR1, each tool line sending PreToolUse, and SIGUSR2 is 0.1 s of the film:
# the spinner turns one frame, the timer and the token count move, so the harness films the
# stream at its own pace. The working line and footer are Claude Code 2.1's, as captured from
# the real CLI against a local mock API ("✶ Percolating… (6s · ↓ 1.2k tokens)", then
# "✻ Worked for 9s"; "esc to interrupt" moves into the footer meanwhile). "elapsed" and
# "tokens" in the meta are where a turn already under way starts. The pid is in <ID>.pid.
#
# Esc Esc opens Claude Code 2.1's rewind menu, drawn like the real one: ↑ / ↓ pick a message,
# Return, then "Restore conversation" drops it and everything after it from the screen and puts
# its text in the input (the next prompt continues from the turn before it); Esc Esc on a filled
# input clears it.
import glob, json, os, random, re, select, signal, subprocess, sys, termios, time, tty, uuid

args = sys.argv[1:]
# FAKE_AGENT=codex (App/scripts/readme/codex): Codex CLI 0.166's screen and hooks instead.
CODEX = os.environ.get("FAKE_AGENT") == "codex"
sid = os.environ.get("FAKE_CLAUDE_SESSION", "")
if "--resume" in args and args.index("--resume") + 1 < len(args):
    sid = args[args.index("--resume") + 1]
if CODEX and args[:1] == ["resume"] and len(args) > 1:
    sid = args[1]
root = os.environ["FAKE_CLAUDE_DIR"]
# Like Claude Code: <projects>/<project dir>/<session>.jsonl
found = glob.glob(os.path.join(root, "*", sid + ".jsonl"))
tpath = found[0] if found else os.path.join(root, sid + ".jsonl")
mpath = tpath[:-len(".jsonl")] + ".json"
meta, mtime = {}, None


def load_meta():
    global meta, mtime
    try:
        m = os.stat(mpath).st_mtime
        if m != mtime:
            meta, mtime = json.load(open(mpath)), m
            return True
    except Exception:
        pass
    return False


load_meta()
cwd = os.getcwd()
with open(tpath[:-len(".jsonl")] + ".pid", "w") as f:
    f.write(str(os.getpid()))

DIM, RESET, BOLD = "\033[2m", "\033[0m", "\033[1m"
GREEN, GREY = "\033[32m", "\033[90m"


def hook(name, **extra):
    o = {"hook_event_name": name, "session_id": sid, "transcript_path": tpath, "cwd": cwd}
    if CODEX:
        o.update({"model": "gpt-5-codex", "permission_mode": "default", "turn_id": sid[:8]})
    o.update(extra)
    try:
        subprocess.run(["lmux-hook"] + (["codex"] if CODEX else []), input=json.dumps(o).encode(), timeout=2)
    except Exception:
        pass


def turns():
    out = []
    try:
        lines = open(tpath, encoding="utf-8").read().splitlines()
    except Exception:
        return out
    for line in lines:
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") == "user" and isinstance(o.get("message", {}).get("content"), str) \
                and not o.get("isCompactSummary"):
            out.append({"prompt": o["message"]["content"], "reply": None, "leaf": o.get("uuid"), "i": len(out)})
        elif o.get("type") == "assistant" and out:
            out[-1]["leaf"] = o.get("uuid") or out[-1]["leaf"]
            for b in o.get("message", {}).get("content", []):
                if b.get("type") == "text":
                    out[-1]["reply"] = b["text"]
    # Turns a rewind dropped (indices in the file's order).
    return [t for t in out if t["i"] not in rewound]


def cols():
    try:
        return os.get_terminal_size(1).columns
    except Exception:
        return 100


def body(t):
    s = added.get(t["prompt"], meta.get("screens", {}).get(t["prompt"]))
    if s is not None:
        return s
    r = t["reply"] or ""
    lines = r.splitlines() or [""]
    return ("•" if CODEX else GREEN + "⏺" + RESET) + " " + lines[0] + "".join("\n  " + l for l in lines[1:])


buf = ""
working = None
answered = False  # the dialog was approved in this run
added = {}  # screens of prompts answered in this run
# Stepped mode: lines still to show ([prompt, line]), what to do after the last one, the
# spinner frame (Claude Code's glyphs, there and back) and the signals not handled yet.
queue, finish = [], None
SPIN = "·✢✳✶✻✽✽✻✶✳✢·"
spin = 0
signals = {"step": 0, "tick": 0}
# The turn's timer and tokens (stepped): ticks since it started, tokens streamed, the line
# left after it ("✻ Worked for 9s"). Seeded per session: both themes count the same.
work_ticks, tokens, worked = 0, 0, None
# A reply's "pace": its timer runs that many seconds per second of film (the film is a time-lapse
# of a turn that really takes most of a minute).
pace = 1
rng = random.Random(sid)
# The rewind menu (Esc Esc): None, "list" or "confirm"; the highlighted message and option; the
# file-order indices of turns it dropped; when Esc was last pressed (Claude Code's double press).
menu, pick, choice, rewound, last_esc = None, 0, 0, set(), 0.0
REWIND_OPTIONS = ["Restore conversation", "Summarize from here", "Summarize up to here", "Never mind"]


def rewind_key(k):
    """One key while the menu is up, or Esc at the prompt."""
    global menu, pick, choice, last_esc, buf
    if menu is None:
        now = time.time()
        double = now - last_esc < 0.8
        last_esc = 0.0 if double else now
        if double and buf:
            buf = ""
        elif double and not working:
            menu, pick = "list", len(turns())
        return
    n = len(turns())
    if menu == "list":
        if k == "up":
            pick = max(0, pick - 1)
        elif k == "down":
            pick = min(n, pick + 1)
        elif k == "esc":
            menu = None
        elif k == "enter" and pick < n:
            menu, choice = "confirm", 0
    elif k == "up":
        choice = max(0, choice - 1)
    elif k == "down":
        choice = min(len(REWIND_OPTIONS) - 1, choice + 1)
    elif k == "esc":
        menu = "list"
    elif k == "enter":
        if REWIND_OPTIONS[choice] == "Restore conversation":
            shown = turns()
            buf = shown[pick]["prompt"]
            rewound.update(t["i"] for t in shown[pick:])
        menu = None


def kfmt(n):
    return "%d" % n if n < 1000 else "%.1fk" % (n / 1000)


def tilde(path):
    """The fixture's home is a temp dir (…/home): shown as ~ like the real one."""
    i = path.find("/home/")
    return "~" + path[i + len("/home"):] if i >= 0 else path


def draw_codex():
    """Codex CLI 0.166, as captured from the real one against a local mock Responses API."""
    out = ["\033[2J\033[H", "  " + BOLD + ">_ OpenAI Codex" + RESET + DIM + " (v0.166.0)" + RESET + "\n",
           "     " + DIM + tilde(cwd) + RESET + "\n\n"]
    for t in turns():
        out.append(BOLD + "›" + RESET + " " + t["prompt"] + "\n\n" + body(t) + "\n\n")
    if working or meta.get("working"):
        secs = int(meta.get("elapsed", 0) + work_ticks / 10) if not working else int(work_ticks / 10)
        out.append(BOLD + "• Working" + RESET + DIM + " (%ds • esc to interrupt)" % secs + RESET + "\n\n")
    elif worked or meta.get("worked"):
        out.append("  " + DIM + (worked or meta["worked"]) + RESET + "\n\n")
    out.append(BOLD + "›" + RESET + " " + (buf or DIM + "Ask Codex to do anything" + RESET) + "\n\n")
    out.append("  " + DIM + "gpt-5-codex default · " + tilde(cwd) + RESET + "\n")
    out.append("  " + DIM + "← for agents · ? for shortcuts" + RESET)
    out.append("\033[3A\r\033[%dC" % (2 + len(buf)))
    sys.stdout.write("".join(out).replace("\n", "\r\n"))
    sys.stdout.flush()


def draw_rewind(w):
    out = [GREY + "▔" * w + RESET + "\n   Rewind\n\n"]
    items = [t["prompt"] for t in turns()] + [None]
    if menu == "list":
        out.append("   Restore the code and/or conversation to the point before…\n")
        lo = max(0, min(pick - 1, len(items) - 3))
        hi = min(len(items), lo + 3)
        if lo > 0:
            out.append(DIM + "    ↑ %d more above" % lo + RESET + "\n")
        out.append("\n")
        for i in range(lo, hi):
            first = (items[i] or "").split("\n")[0]
            text = "(current)" if items[i] is None else (first[:w - 15] + "…" if len(first) > w - 14 else first)
            out.append(("   ❯ " if i == pick else "     ") + text + "\n")
            if items[i] is not None:
                out.append(DIM + "     No code changes" + RESET + "\n")
            out.append("\n")
        if hi < len(items):
            out.append(DIM + "    ↓ %d more below" % (len(items) - hi) + RESET + "\n")
        out.append(DIM + "   Enter to continue · Esc to cancel" + RESET)
    else:
        out.append("   Confirm you want to restore to the point before you sent this message:\n\n")
        out.append("   │ " + items[pick].split("\n")[0] + "\n   │ " + DIM + "(just now)" + RESET + "\n\n")
        out.append(DIM + "   The conversation will be forked.\n   The code will be unchanged." + RESET + "\n\n")
        for i, label in enumerate(REWIND_OPTIONS):
            out.append(("   ❯ " if i == choice else "     ") + "%d. %s\n" % (i + 1, label))
    return "".join(out) + "\033[?25l"


def draw():
    if CODEX:
        return draw_codex()
    w = cols()
    out = ["\033[2J\033[H"]
    for t in turns():
        out.append(DIM + "❯" + RESET + " " + t["prompt"] + "\n\n" + body(t) + "\n\n")
    if menu:
        sys.stdout.write(("".join(out) + draw_rewind(w)).replace("\n", "\r\n"))
        sys.stdout.flush()
        return
    busy = bool(working or meta.get("working"))
    if busy and meta.get("step"):
        secs = int(meta.get("elapsed", 0) + work_ticks / 10) if not working else int(work_ticks / 10 * pace)
        toks = tokens + (meta.get("tokens", 0) if not working else 0)
        what = "↓ %s tokens" % kfmt(toks) if toks else "thinking"
        out.append(GREEN + SPIN[spin % len(SPIN)] + RESET + " " + (working or meta["working"]) + " " + DIM
                   + "(%ds · %s)" % (secs, what) + RESET + "\n\n")
    elif busy:
        out.append(GREEN + "✻" + RESET + " " + (working or meta["working"]) + DIM + " (esc to interrupt)" + RESET + "\n\n")
    elif worked and meta.get("step"):
        out.append(DIM + "✻ " + worked + RESET + "\n\n")
    if meta.get("dialog") and not answered:
        out.append(GREY + "─" * w + RESET + "\n" + meta["dialog"] + "\033[?25l")
    else:
        out.append("\033[?25h")
        rule = GREY + "─" * w + RESET
        out.append(rule + "\n" + "❯ " + buf + "\n" + rule + "\n")
        if meta.get("step"):
            hint = " · esc to interrupt" if busy else " (shift+tab to cycle)"
            # A narrow pane: Claude Code drops what doesn't fit rather than wrapping.
            tail = " · ← for agents" if w >= 60 else ""
            out.append("  " + DIM + "⏵⏵ accept edits on" + hint + tail + RESET)
        else:
            out.append("  " + DIM + "⏵⏵ accept edits on (shift+tab to cycle)" + RESET)
        # Cursor back into the input box, after the typed text.
        out.append("\033[2A\r\033[%dC" % (2 + sum(2 if ord(ch) > 0x1100 else 1 for ch in buf)))
    sys.stdout.write("".join(out).replace("\n", "\r\n"))
    sys.stdout.flush()


def append(o):
    with open(tpath, "a", encoding="utf-8") as f:
        f.write(json.dumps(o, ensure_ascii=False) + "\n")


def last_uuid():
    u = None
    try:
        for line in open(tpath, encoding="utf-8"):
            try:
                u = json.loads(line).get("uuid") or u
            except Exception:
                pass
    except Exception:
        pass
    return u


def entry(kind, parent, **extra):
    o = {"parentUuid": parent, "isSidechain": False, "userType": "external", "cwd": cwd, "sessionId": sid,
         "version": "2.1.280", "gitBranch": "main", "type": kind, "uuid": str(uuid.uuid4()),
         "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())}
    o.update(extra)
    append(o)
    return o["uuid"]


def submit(prompt):
    global working, finish, work_ticks, tokens, worked, pace
    hook("UserPromptSubmit", prompt=prompt)
    # After a rewind the prompt continues from the last turn kept (a new branch, like Claude Code).
    kept = turns()
    parent = entry("user", kept[-1]["leaf"] if rewound and kept else (None if rewound else last_uuid()), message={"role": "user", "content": prompt}, turnOrigin="human",
                   promptSource="typed")
    r = next((x for x in meta.get("replies", []) if x["match"] in prompt), {"reply": "Done.", "screen": None})
    if meta.get("step") and r.get("screen"):
        working = r.get("working", "Thinking…")
        work_ticks, tokens, worked = 0, 0, None
        pace = float(r.get("pace", 1))
        added[prompt] = ""
        queue.extend([prompt, line] for line in r["screen"].split("\n"))

        def done():
            global working, worked
            working = None
            worked = "Worked for %ds" % max(1, int(work_ticks / 10 * pace))
            leaf = entry("assistant", parent, message={"id": "msg_" + uuid.uuid4().hex[:8], "role": "assistant",
                                                       "content": [{"type": "text", "text": r["reply"]}]})
            append({"type": "last-prompt", "lastPrompt": prompt, "leafUuid": leaf, "sessionId": sid})
            draw()
            hook("Stop", last_assistant_message=r["reply"])
        finish = done
        draw()
        return
    working = "Thinking…"
    draw()
    time.sleep(float(os.environ.get("FAKE_CLAUDE_THINK", "1.2")))
    working = None
    leaf = entry("assistant", parent, message={"id": "msg_" + uuid.uuid4().hex[:8], "role": "assistant",
                                               "content": [{"type": "text", "text": r["reply"]}]})
    append({"type": "last-prompt", "lastPrompt": prompt, "leafUuid": leaf, "sessionId": sid})
    if r.get("screen"):
        added[prompt] = r["screen"]
    draw()
    hook("Stop", last_assistant_message=r["reply"])


def approve():
    global answered, working, work_ticks, tokens
    answered = True
    # The turn goes on: its timer and tokens carry over into the working line.
    work_ticks += int(meta.get("elapsed", 0) * 10)
    tokens += meta.get("tokens", 0)
    t = turns()
    if t and meta.get("approved"):
        added[t[-1]["prompt"]] = body(t[-1])
        if meta.get("step"):
            queue.extend([t[-1]["prompt"], line] for line in meta["approved"].split("\n"))
        else:
            added[t[-1]["prompt"]] += "\n" + meta["approved"]
    working = meta.get("approved_working")
    draw()
    hook("PostToolUse", tool_name=meta.get("dialog_tool", "Bash"))


TOOL = re.compile(r"^⏺ (\w+)\(")
SHOWN_AS = {"Update": "Edit"}  # Claude Code draws Edit as Update(...)


def reveal():
    """Stepped mode: the next queued line, and the last one's finish."""
    global finish
    global tokens
    p, line = queue.pop(0)
    added[p] = added[p] + "\n" + line if added[p] else line
    tokens += len(line) // 3 + rng.randint(4, 30)
    m = TOOL.match(re.sub(r"\x1b\[[0-9;]*m", "", line))
    if m:
        hook("PreToolUse", tool_name=SHOWN_AS.get(m.group(1), m.group(1)))
    if not queue and finish:
        f, finish = finish, None
        f()


def on_signal(name):
    def handler(*_):
        signals[name] += 1
    return handler


def quit_(*_):
    hook("SessionEnd", reason="prompt_input_exit")
    sys.stdout.write("\033[2J\033[H")
    sys.stdout.flush()
    os._exit(0)


fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
signal.signal(signal.SIGWINCH, lambda *_: draw())
signal.signal(signal.SIGUSR1, on_signal("step"))
signal.signal(signal.SIGUSR2, on_signal("tick"))
try:
    hook("SessionStart", source="resume" if "--resume" in args else "startup")
    draw()
    pending = b""
    while True:
        r, _, _ = select.select([fd], [], [], 0.02 if meta.get("step") else 0.2)
        if signals["step"] or signals["tick"]:
            while signals["step"]:
                signals["step"] -= 1
                if queue:
                    reveal()
            spin += signals["tick"]
            if working or meta.get("working"):
                work_ticks += signals["tick"]
                if working and tokens:
                    tokens += sum(rng.randint(0, 22) for _ in range(signals["tick"]))
            signals["tick"] = 0
            draw()
        if not r:
            if load_meta():
                draw()
            continue
        data = os.read(fd, 1024)
        if not data:
            quit_()
        pending += data
        try:
            text, pending = pending.decode("utf-8"), b""
        except UnicodeDecodeError as e:
            text, pending = pending[:e.start].decode("utf-8"), pending[e.start:]
        esc = ""
        for i, ch in enumerate(text):
            if esc:  # rest of an escape sequence (arrows, focus reports)
                esc += ch
                if ch.isalpha() or ch == "~":
                    if esc in ("\x1b[A", "\x1bOA", "\x1b[B", "\x1bOB") and menu:
                        rewind_key("up" if esc[-1] == "A" else "down")
                    esc = ""
                continue
            if ch == "\x03":  # Ctrl-C
                quit_()
            elif ch == "\x1b":
                # A lone Esc (nothing after it in this read, or another Esc): Claude Code's Esc.
                if i + 1 == len(text) or text[i + 1] == "\x1b":
                    rewind_key("esc")
                else:
                    esc = ch
            elif menu:
                if ch in "\r\n":
                    rewind_key("enter")
            elif meta.get("dialog") and not answered:
                if ch in "1\r\n":
                    approve()
            elif ch in "\r\n":
                if buf.strip():
                    p, buf = buf, ""
                    submit(p)
            elif ch in "\x7f\x08":
                buf = buf[:-1]
            elif ch >= " ":
                buf += ch
        draw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
