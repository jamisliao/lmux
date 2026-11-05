#!/usr/bin/env python3
"""Turn captured Claude Code pty streams (capture.py) into static ANSI screens + a run map
for the contrast apptest. Each screen: Claude's Write preview + permission dialog on the
left, its Edit (diff) preview and the prompt box with the "accept edits on" hint on the right.

  build_fixtures.py CAPTURE_DIR OUT_DIR [THEME...]   Claude screens: claude-<theme>.{ans,json}
  build_fixtures.py CAPTURE_DIR OUT_DIR --markdown    Claude's markdown reply, 4 themes: claude-markdown.{ans,json}
  build_fixtures.py CAPTURE_DIR OUT_DIR --samples     ls / git / ANSI / 256 / truecolor: samples.{ans,json}
The .json lists each run of text (same attributes, one row): its cells, SGR and kind; the
contrast apptest (lmux-apptest --contrast) measures them from the renderer's pixels.
"""
import json, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
if os.environ.get("PYTE_PATH"): sys.path.insert(0, os.environ["PYTE_PATH"])
import pyte

cap, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
COLS, ROWS = 100, 50
NAMES = ["black", "red", "green", "brown", "blue", "magenta", "cyan", "white"]


def faint_as_blink(raw):
    """pyte has no faint: carry SGR 2 as blink (5), which Claude never uses."""
    def fix(m):
        ps = m.group(1).split(";") if m.group(1) else ["0"]
        o, i = [], 0
        while i < len(ps):
            p = ps[i]
            if p in ("38", "48") and i + 1 < len(ps):
                n = 5 if ps[i + 1] == "2" else 3
                o += ps[i:i + n]; i += n; continue
            if p == "2": o.append("5")
            elif p == "22": o += ["22", "25"]
            else: o.append(p)
            i += 1
        return "\x1b[" + ";".join(o) + "m"
    raw = re.sub(r"\x1b\[[>?<=][0-9;]*[a-zA-Z]", "", raw)
    return re.sub(r"\x1b\[([0-9;]*)m", fix, raw)


def screen(path):
    raw = open(path, "rb").read().decode("utf-8", "replace")
    s = pyte.Screen(COLS, ROWS)
    st = pyte.Stream(s)
    st.feed(faint_as_blink(raw))
    return s


def sgr(ch):
    p = []
    if ch.bold: p.append("1")
    if ch.blink: p.append("2")
    if ch.italics: p.append("3")
    if ch.underscore: p.append("4")
    if ch.reverse: p.append("7")
    if ch.strikethrough: p.append("9")
    for val, base in ((ch.fg, 30), (ch.bg, 40)):
        if val == "default": continue
        if val in NAMES: p.append(str(base + NAMES.index(val)))
        elif val.startswith("bright") and val[6:] in NAMES: p.append(str(base + 60 + NAMES.index(val[6:])))
        elif re.fullmatch(r"[0-9a-fA-F]{6}", val):
            p.append(f"{base + 8};2;{int(val[0:2], 16)};{int(val[2:4], 16)};{int(val[4:6], 16)}")
        else: raise SystemExit(f"unknown color {val!r}")
    return ";".join(p)


def rows_of(s):
    return [[s.buffer[y][x] for x in range(COLS)] for y in range(ROWS)]


def text(row):
    return "".join(c.data for c in row)


def crop(rows, start_pat, end_pat, extra=0):
    t = [text(r) for r in rows]
    a = next(i for i, l in enumerate(t) if re.search(start_pat, l))
    b = next(i for i in range(a, len(t)) if re.search(end_pat, t[i]))
    return rows[a:b + 1 + extra]


def graphics(cp):
    return 0x2500 <= cp <= 0x259F or 0x1FB00 <= cp <= 0x1FBFF or 0xE0B0 <= cp <= 0xE0D7


def emit(name, cols_rows, kinds, label):
    """cols_rows: list of rows, each a list of (pyte Char | None); kinds: kind per row.
    Writes NAME.ans and NAME.json (runs: same-attribute glyph cells on one row)."""
    lines, runs = [], []
    for y, row in enumerate(cols_rows):
        line, cur, run = "", None, None
        for x, ch in enumerate(row):
            a = sgr(ch) if ch else ""
            d = ch.data if ch else " "
            if d == "":   # the right half of a wide glyph
                continue
            if a != cur:
                line += "\x1b[0m" + (f"\x1b[{a}m" if a else "")
                cur = a
            line += d
            glyph = d.strip() and not graphics(ord(d[0]))
            key = (a, kinds[y][x] if isinstance(kinds[y], list) else kinds[y])
            if glyph:
                if run and run["key"] == key and x - run["cols"][-1] <= 2:
                    run["cols"].append(x)
                else:
                    run = {"key": key, "row": y, "cols": [x], "text": ""}
                    runs.append(run)
                run["text"] = "".join(row[c].data if row[c] else " " for c in range(run["cols"][0], run["cols"][-1] + 1))
        lines.append(line + "\x1b[0m")
    with open(os.path.join(out, name + ".ans"), "w") as f:
        f.write("\x1b[?25l\x1b[H\x1b[2J" + "\r\n".join(lines))
    js = [{"row": r["row"], "cols": r["cols"], "sgr": r["key"][0], "kind": r["key"][1], "text": r["text"].rstrip()}
          for r in runs]
    with open(os.path.join(out, name + ".json"), "w") as f:
        json.dump({"label": label, "runs": js}, f, ensure_ascii=False, indent=0)
    return len(lines)


def claude_screen(theme):
    W = rows_of(screen(f"{cap}/run-{theme}-Write/preview.bin"))
    E = rows_of(screen(f"{cap}/run-{theme}-Edit/preview.bin"))
    P = rows_of(screen(f"{cap}/run-{theme}-Write/raw.bin"))
    w = crop(W, r"^⏺ Write\(", r"Esc to cancel")
    e = crop(E, r"^⏺ (Update|Edit)\(", r"Esc to cancel")
    p = crop(P, r"^⏺ Done\.", r"accept edits on")
    q = []
    for r in p:   # Claude pads its final screen with blank rows: keep one at most
        if not text(r).strip() and q and not text(q[-1]).strip(): continue
        q.append(r)
    p = q
    print(theme, "write", len(w), "edit", len(e), "prompt", len(p))

    def kinds(block, sep_kind, inner, after):
        ks, seps = [], 0
        for r in block:
            t = text(r)
            if t.lstrip().startswith("╌") or t.startswith("╌"):
                seps += 1; ks.append(sep_kind); continue
            ks.append(inner if seps == 1 else (after if seps >= 2 else "dialog"))
        return ks
    kw = kinds(w, "dialog", "code", "dialog")
    ke = kinds(e, "dialog", "diff", "dialog")
    kp = []
    for r in p:
        t = text(r)
        kp.append("hint" if "accept edits" in t else "prompt" if t.startswith("❯") else "result")
    right = e + [[None] * COLS] + p
    kr = ke + ["result"] + kp
    n = max(len(w), len(right))
    blank = [None] * COLS
    rows, ks = [], []
    for y in range(n):
        lr = w[y] if y < len(w) else blank
        rr = right[y] if y < len(right) else blank
        rows.append(list(lr) + [None, None] + list(rr))
        lk = kw[y] if y < len(kw) else "none"
        rk = kr[y] if y < len(kr) else "none"
        ks.append([lk] * (COLS + 2) + [rk] * COLS)
    return rows, ks


E = "\x1b["
SAMPLES = [
    ("ls", "$ ls --color   (GNU coreutils defaults)"),
    ("ls", f"{E}01;34mSources{E}0m  {E}01;34mTests{E}0m  {E}01;32mbuild.sh{E}0m  {E}01;36mlatest{E}0m  {E}01;31mrelease.tar.gz{E}0m  {E}01;35mlogo.png{E}0m  {E}40;33;01mtty0{E}0m  {E}30;42mshared{E}0m  {E}34;42mtmp{E}0m  README.md"),
    ("ls", "$ ls -G   (macOS, default LSCOLORS)"),
    ("ls", f"{E}34mSources{E}0m  {E}34mTests{E}0m  {E}31mbuild.sh{E}0m  {E}35mlatest{E}0m  {E}32msock{E}0m  {E}33mfifo{E}0m  {E}30;43mshared{E}0m  {E}30;42msticky{E}0m  {E}30;41msetuid{E}0m  README.md"),
    ("git", "$ git diff --color"),
    ("git", f"{E}1mdiff --git a/src/auth/refresh.ts b/src/auth/refresh.ts{E}m"),
    ("git", f"{E}1mindex 3f2a1c9..8be44d0 100644{E}m"),
    ("git", f"{E}1m--- a/src/auth/refresh.ts{E}m"),
    ("git", f"{E}1m+++ b/src/auth/refresh.ts{E}m"),
    ("git", f"{E}36m@@ -36,8 +36,10 @@{E}m export async function refresh(token: string) {{"),
    ("git", "   const claims = verify(token)"),
    ("git", f"{E}31m-  if (await isRevoked(token)) throw new Reused(){E}m"),
    ("git", f"{E}32m+  return db.transaction(async (tx) => {{{E}m"),
    ("git", f"{E}32m+    const row = await tx.lockToken(token){E}m"),
    ("git", f"{E}33mcommit 8be44d0c1f0e2a7b9d6c5e4f3a2b1c0d9e8f7a6b{E}m{E}33m ({E}m{E}1;36mHEAD -> {E}m{E}1;32mmain{E}m{E}33m, {E}m{E}1;31morigin/main{E}m{E}33m){E}m"),
    ("ansi", "ANSI 16 as text on the default background:"),
    ("ansi", " ".join(f"{E}{30 + i}mcolor{i}{E}0m" for i in range(8)) + "  " + f"{E}2mfaint default{E}22m"),
    ("ansi", " ".join(f"{E}{90 + i}mcolor{8 + i}{E}0m" for i in range(8)) + "  " + f"{E}1mbold default{E}22m"),
    ("ansi", "zsh-autosuggestions (fg=8):  $ git commit " + f"{E}38;5;8m-m \"fix the race\"{E}0m"),
    ("256", "256-color text:  " + " ".join(f"{E}38;5;{n}m{n}{E}0m" for n in (237, 240, 243, 246, 250, 254, 22, 28, 88, 124, 130, 136, 25, 31, 61, 97))),
    ("truecolor", "vim-like truecolor (app sets fg and bg):"),
    ("truecolor", f"{E}38;2;220;220;170;48;2;30;30;30m  def total(self) -> float:  {E}0m  {E}38;2;56;58;66;48;2;250;250;250m  def total(self) -> float:  {E}0m  {E}38;2;98;114;164;48;2;40;42;54m  # a comment  {E}0m"),
    ("truecolor", f"{E}38;2;101;123;131mSolarized base00 text, no bg{E}0m  {E}38;2;146;131;116mGruvbox gray, no bg{E}0m  {E}38;2;88;110;117mbase01{E}0m"),
]


def samples():
    s = pyte.Screen(200, len(SAMPLES))
    st = pyte.Stream(s)
    raw = "\r\n".join(l for _, l in SAMPLES)
    st.feed(faint_as_blink(raw.replace("\x1b[38;5;8m", "\x1b[90m")))
    rows = [[s.buffer[y][x] for x in range(200)] for y in range(len(SAMPLES))]
    # 256-color indices: pyte resolves them with xterm's table; keep the index instead.
    out_rows = rows
    return out_rows, [k for k, _ in SAMPLES]


def markdown_screen():
    """Claude's markdown reply (inline code, table, bold, link, list, quote, headings): dark | dark-ansi
    above, light | light-ansi below."""
    blocks = []
    for theme in ("default", "dark-ansi", "light", "light-ansi"):
        R = rows_of(screen(f"{cap}/run-{theme}-Markdown/raw.bin"))
        blocks.append(crop(R, r"^❯ how do I", r"Re-run"))
    rows, ks = [], []
    blank = [None] * COLS
    for top, bottom in ((blocks[0], blocks[1]), (blocks[2], blocks[3])):
        for y in range(max(len(top), len(bottom))):
            a = top[y] if y < len(top) else blank
            b = bottom[y] if y < len(bottom) else blank
            rows.append(list(a) + [None, None] + list(b))
            ks.append("prompt" if y == 0 else "markdown")
        rows.append([None] * (2 * COLS + 2)); ks.append("none")
    return rows, ks


if "--markdown" in sys.argv:
    rows, ks = markdown_screen()
    print("markdown", emit("claude-markdown", rows, ks, "Claude Code markdown reply (dark, dark-ansi | light, light-ansi)"), "rows")
    sys.exit(0)

if "--samples" in sys.argv:
    rows, ks = samples()
    print("samples", emit("samples", rows, ks, "ls / git / ANSI / 256 / truecolor"), "rows")
    sys.exit(0)

for theme in sys.argv[3:] or ["default", "light", "dark-ansi", "light-ansi", "dark-daltonized", "light-daltonized"]:
    if not os.path.exists(f"{cap}/run-{theme}-Edit/preview.bin"):
        print("skip", theme); continue
    rows, ks = claude_screen(theme)
    n = emit(f"claude-{'dark' if theme == 'default' else theme}", rows, ks, f"Claude Code ({theme})")
    print(theme, n, "rows")
