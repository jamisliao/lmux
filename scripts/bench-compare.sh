#!/bin/bash
# Compare two scripts/bench.sh results: print the README table row and
# regenerate assets/bench-chart.svg + bench-chart-dark.svg from them.
#
#   scripts/bench-compare.sh a.json b.json
#   scripts/bench-compare.sh --series OUTDIR r1.json r2.json ...
#
# --series takes the results of a scaling run (both apps, several workspace
# counts), prints one markdown table (a row per metric, a column per
# (step, app)) and writes OUTDIR/bench-scaling.svg + bench-scaling-dark.svg:
# memory and idle CPU vs workspace count, one line per app. assets/ and the
# README are not touched in this mode.
#
# Either side can be "missing" -- pass its path as "TBD", "-", or any path
# that doesn't exist -- and that side renders as a TBD placeholder in both
# the table and the chart. Which JSON is "cmux" and which is "lmux" is read
# from each file's "app_kind" field (set by bench.sh), not argument order.
#
# A result measured with bench.sh --reps N (N > 1) carries an "aggregate" of
# median/min/max across reps; this script reads that instead of the single
# in-place value wherever it's present, so every number here is a median
# with its min-max range shown alongside (older, reps=1 results still work:
# min == max, so no range is shown). See scripts/BENCH.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/assets"

usage() {
  cat <<'EOF'
Usage: scripts/bench-compare.sh a.json b.json
       scripts/bench-compare.sh --series OUTDIR r1.json r2.json ...

  a.json, b.json   Result files from scripts/bench.sh, in either order.
                    Pass "TBD" (or "-", or a nonexistent path) for a side
                    that hasn't been measured yet.
  --series OUTDIR  Scaling table for any number of results (grouped by
                    app_kind and workspace count); the scaling chart SVGs
                    go to OUTDIR.
EOF
}

if [ "${1:-}" = "--series" ]; then
  [ $# -ge 3 ] || { usage >&2; exit 1; }
  OUTDIR="$2"; shift 2
  mkdir -p "$OUTDIR"
  SERIES_PY="$(mktemp /tmp/lmux-bench-series.XXXXXX.py)"
  trap 'rm -f "$SERIES_PY"' EXIT
  cat > "$SERIES_PY" <<'SERIES'
import json, sys, os
outdir, files = sys.argv[1], sys.argv[2:]
runs = {}
for f in files:
    d = json.load(open(f))
    runs[(d.get("app_kind") or "?", d["workload_detail"]["requested_workspaces"])] = d
kinds = [k for k in ("cmux", "lmux") if any(k == r[0] for r in runs)] + sorted({r[0] for r in runs} - {"cmux", "lmux"})
steps = sorted({r[1] for r in runs})
first = {k: next(d for (kk, _), d in sorted(runs.items()) if kk == k) for k in kinds}
label = {k: first[k]["label"] for k in kinds}
reps_seen = {d.get("reps", 1) for d in runs.values()}
reps_note = f"median of {reps_seen.pop()} runs, bars show min–max" if len(reps_seen) == 1 and next(iter(reps_seen), 1) > 1 else None

# median()/rng() read bench.sh's per-run `aggregate` (added for --reps); a
# run with no aggregate (reps=1 from an older result) falls back to its
# single value, with min == max == that value (no visible range).
def median(d, key):
    a = (d.get("aggregate") or {}).get(key)
    if a:
        return a["median"]
    return {"footprint_mb": d["memory_mb"]["app_total"]["footprint"],
            "cpu_mean_pct": d["cpu_pct"]["app_total"]["mean"]}[key]

def rng(d, key):
    a = (d.get("aggregate") or {}).get(key)
    if a:
        return a["min"], a["max"]
    v = median(d, key)
    return v, v

def fmt_agg(d, key, suffix, dec):
    v, (lo, hi) = median(d, key), rng(d, key)
    if hi > lo:
        return f"{v:.{dec}f}{suffix} ({lo:.{dec}f}–{hi:.{dec}f})"
    return f"{v:.{dec}f}{suffix}"

print("App size: " + ", ".join(f"{label[k]} {first[k]['app_size']['mb']:.1f} MB" for k in kinds)
      + (f" -- {reps_note}" if reps_note else "") + "\n")
cols = [(n, k) for n in steps for k in kinds]
rows = [
    ("Panes (workspaces x 2)", lambda d: f"{d['workload_detail']['requested_panes']}"),
    ("Live shells", lambda d: f"{d['workload_detail']['shells_live']}"),
    ("Reps", lambda d: f"{d.get('reps', 1)}"),
    ("Memory footprint (median, min–max)", lambda d: fmt_agg(d, "footprint_mb", " MB", 0)),
    ("Idle CPU mean (median, min–max)", lambda d: fmt_agg(d, "cpu_mean_pct", " %", 1)),
    ("Idle CPU p95 (last rep)", lambda d: f"{d['cpu_pct']['app_total']['p95']:.1f} %"),
]
print("| | " + " | ".join(f"{n} ws, {label[k].split()[0]}" for n, k in cols) + " |")
print("|---|" + "---:|" * len(cols))
for name, fn in rows:
    print(f"| {name} | " + " | ".join("-" if (k, n) not in runs else fn(runs[(k, n)]) for n, k in cols) + " |")

# --- Scaling chart: memory and idle CPU vs workspace count. Each point is
# the median across reps; a thin min-max whisker is drawn around it. -------
def tick(v):  # a round grid step giving 4-5 lines up to v
    for e in range(-3, 7):
        for m in (1, 2, 2.5, 5):
            if m * 10 ** e * 5 >= v:
                return m * 10 ** e
    return v

def render(theme):
    if theme == "light":
        title, muted, lab, grid = "#2E3440", "#5B657A", "#4C566A", "#D3D9E3"
        color = {"cmux": "#4C566A", "lmux": "#4C6E99", "lmux-bg": "#6FA5B8"}
    else:
        title, muted, lab, grid = "#ECEFF4", "#99A2B3", "#C4CBD7", "#3B4252"
        color = {"cmux": "#D8DEE9", "lmux": "#88C0D0", "lmux-bg": "#5E81AC"}
    W, H = 760, 330
    panels = [("Memory", "all app processes, MB", "footprint_mb", 0),
              ("Idle CPU", "60 s mean, %", "cpu_mean_pct", 1)]
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">',
         '  <title id="t">lmux vs cmux: memory and idle CPU vs workspace count</title>']
    desc = "; ".join(f"{label[k]} at {n} workspaces: {median(runs[(k, n)], 'footprint_mb'):.0f} MB, "
                     f"{median(runs[(k, n)], 'cpu_mean_pct'):.1f}% CPU" for k in kinds for n in steps if (k, n) in runs)
    desc_suffix = f" {reps_note.capitalize()}." if reps_note else ""
    o.append(f'  <desc id="d">{desc}. 2 idle shells per workspace. Lower is better.{desc_suffix}</desc>')
    o.append('  <g font-family="-apple-system, BlinkMacSystemFont, \'Segoe UI\', Helvetica, Arial, sans-serif">')
    o.append(f'    <text x="0" y="20" font-size="15" font-weight="600" fill="{title}">Same Mac, more workspaces</text>')
    subtitle = "2 idle shells per workspace, each step a fresh launch. Lower is better."
    if reps_note:
        subtitle += f" {reps_note.capitalize()}."
    o.append(f'    <text x="0" y="40" font-size="12" fill="{muted}">{subtitle}</text>')
    x = W
    for k in reversed(kinds):  # right-aligned, each entry as wide as its label
        x -= round(18 + 6.6 * len(label[k]) + 20)
        o.append(f'    <rect x="{x}" y="11" width="12" height="12" rx="3" fill="{color.get(k, lab)}"/>'
                 f'<text x="{x + 18}" y="21" font-size="12" fill="{lab}">{label[k]}</text>')
    pw, top, ph = 300, 92, 170
    xmax = max(steps)
    for pi, (name, sub, key, dec) in enumerate(panels):
        x0 = 44 + pi * (pw + 86)
        o.append(f'    <text x="{x0 - 44}" y="{top - 24}" font-size="13" font-weight="600" fill="{title}">{name}'
                 f'<tspan font-size="11" font-weight="400" fill="{muted}" dx="8">{sub}</tspan></text>')
        vmax = max(rng(d, key)[1] for d in runs.values()) or 1
        st = tick(vmax * 1.1)
        ymax = st
        while ymax < vmax * 1.1:
            ymax += st
        X = lambda n: x0 + pw * n / xmax
        Y = lambda v: top + ph - ph * v / ymax
        label_y = {}  # value labels that would overlap at a step stack upwards, higher value on top
        for n in steps:
            prev = None
            for k in sorted((k for k in kinds if (k, n) in runs), key=lambda k: median(runs[(k, n)], key)):
                y = Y(median(runs[(k, n)], key)) - 7
                if prev is not None and y > prev - 12:
                    y = prev - 12
                label_y[(k, n)] = prev = y
        t = 0.0
        while t <= ymax + 1e-9:
            o.append(f'    <line x1="{x0}" x2="{x0 + pw}" y1="{Y(t):.1f}" y2="{Y(t):.1f}" stroke="{grid}" stroke-width="1"/>')
            o.append(f'    <text x="{x0 - 6}" y="{Y(t) + 4:.1f}" font-size="10" text-anchor="end" fill="{muted}">{round(t, 4):g}</text>')
            t += st
        for n in steps:
            o.append(f'    <text x="{X(n):.1f}" y="{top + ph + 16}" font-size="10" text-anchor="middle" fill="{muted}">{n}</text>')
        o.append(f'    <text x="{x0 + pw / 2:.0f}" y="{top + ph + 34}" font-size="11" text-anchor="middle" fill="{lab}">workspaces</text>')
        for k in kinds:
            pts = [(n, median(runs[(k, n)], key), rng(runs[(k, n)], key)) for n in steps if (k, n) in runs]
            c = color.get(k, lab)
            if len(pts) > 1:
                o.append(f'    <polyline points="{" ".join(f"{X(n):.1f},{Y(v):.1f}" for n, v, _ in pts)}" fill="none" stroke="{c}" stroke-width="2"/>')
            for n, v, (lo, hi) in pts:
                if hi > lo:  # min-max whisker: a thin vertical bar with end caps, behind the point
                    cap = 4
                    o.append(f'    <line x1="{X(n):.1f}" x2="{X(n):.1f}" y1="{Y(hi):.1f}" y2="{Y(lo):.1f}" stroke="{c}" stroke-width="1.5" stroke-opacity="0.5"/>')
                    o.append(f'    <line x1="{X(n) - cap:.1f}" x2="{X(n) + cap:.1f}" y1="{Y(hi):.1f}" y2="{Y(hi):.1f}" stroke="{c}" stroke-width="1.5" stroke-opacity="0.5"/>')
                    o.append(f'    <line x1="{X(n) - cap:.1f}" x2="{X(n) + cap:.1f}" y1="{Y(lo):.1f}" y2="{Y(lo):.1f}" stroke="{c}" stroke-width="1.5" stroke-opacity="0.5"/>')
                o.append(f'    <circle cx="{X(n):.1f}" cy="{Y(v):.1f}" r="3.5" fill="{c}"/>')
                o.append(f'    <text x="{X(n) + (6 if n < xmax else -6):.1f}" y="{label_y[(k, n)]:.1f}" font-size="10" font-weight="600" '
                         f'text-anchor="{"start" if n < xmax else "end"}" fill="{title}" style="font-variant-numeric: tabular-nums">{v:.{dec}f}</text>')
    stamp = min(d["timestamp"] for d in runs.values())[:10]
    footer = f"scripts/bench.sh, standard workload (N workspaces x 2 panes), {stamp}."
    if reps_note:
        footer += f" Each point: {reps_note}."
    o.append(f'    <text x="0" y="{H - 6}" font-size="11" fill="{muted}">{footer}</text>')
    o.append('  </g>')
    o.append('</svg>')
    return "\n".join(o) + "\n"

for theme, name in (("light", "bench-scaling.svg"), ("dark", "bench-scaling-dark.svg")):
    with open(os.path.join(outdir, name), "w") as f:
        f.write(render(theme))
print(f"\nWrote {outdir}/bench-scaling.svg and bench-scaling-dark.svg", file=sys.stderr)
SERIES
  python3 "$SERIES_PY" "$OUTDIR" "$@"
  exit 0
fi

[ $# -eq 2 ] || { usage >&2; exit 1; }

HELPER="$(mktemp /tmp/lmux-bench-compare.XXXXXX.py)"
trap 'rm -f "$HELPER"' EXIT

cat > "$HELPER" <<'PY'
import json, os, sys

def load(arg):
    if arg in ("TBD", "-", "") or not os.path.isfile(arg):
        return None
    with open(arg) as f:
        return json.load(f)

def metrics(d):
    if d is None:
        return None
    # footprint_mb/cpu_mean are the median across reps (bench.sh's `aggregate`,
    # added for --reps); *_min/*_max give the range for a whisker. A result
    # with no aggregate (reps=1, from an older bench.sh) falls back to its
    # single value, with min == max (no visible range).
    agg = d.get("aggregate") or {}
    footprint_agg = agg.get("footprint_mb") or {}
    cpu_agg = agg.get("cpu_mean_pct") or {}
    footprint = footprint_agg.get("median", d["memory_mb"]["app_total"]["footprint"])
    cpu_mean = cpu_agg.get("median", d["cpu_pct"]["app_total"]["mean"])
    return {
        "label": d.get("label") or d.get("app_kind") or "?",
        "app_size_mb": d["app_size"]["mb"],
        "footprint_mb": footprint,
        "footprint_min": footprint_agg.get("min", footprint),
        "footprint_max": footprint_agg.get("max", footprint),
        "cpu_mean": cpu_mean,
        "cpu_min": cpu_agg.get("min", cpu_mean),
        "cpu_max": cpu_agg.get("max", cpu_mean),
        "reps": d.get("reps", 1),
        "workload": d.get("workload", "?"),
        "shells": d.get("workload_detail", {}).get("shells_live"),
        "timestamp": d.get("timestamp", "?"),
    }

a_raw, b_raw = load(sys.argv[1]), load(sys.argv[2])
assets_dir = sys.argv[3]

sides = [(sys.argv[1], a_raw), (sys.argv[2], b_raw)]
cmux = next((d for _, d in sides if d and d.get("app_kind") == "cmux"), None)
lmux = next((d for _, d in sides if d and d.get("app_kind") == "lmux"), None)
leftover = [d for _, d in sides if d is not None and d is not cmux and d is not lmux]
if cmux is None and leftover:
    cmux = leftover.pop(0)
    print(f"bench-compare.sh: warning: {sys.argv[1] if cmux is a_raw else sys.argv[2]} has no recognizable app_kind, assuming it's the cmux side", file=sys.stderr)
if lmux is None and leftover:
    lmux = leftover.pop(0)
    print("bench-compare.sh: warning: remaining file assumed to be the lmux side", file=sys.stderr)

cmux_m, lmux_m = metrics(cmux), metrics(lmux)

# --- Markdown table row (paste into README's "## how light" table) ------
def fmt(v, suffix, decimals=0):
    return "TBD" if v is None else f"{v:.{decimals}f}{suffix}"

def fmt_range(m, key, suffix, decimals=0):
    # Median, with a (min-max) suffix when the result has more than 1 rep.
    if m is None:
        return "TBD"
    v, lo, hi = m[key], m[f"{key.split('_')[0]}_min"], m[f"{key.split('_')[0]}_max"]
    if m["reps"] > 1 and hi > lo:
        return f"{v:.{decimals}f}{suffix} ({lo:.{decimals}f}–{hi:.{decimals}f})"
    return f"{v:.{decimals}f}{suffix}"

cmux_label = cmux_m["label"] if cmux_m else "cmux"
lmux_label = lmux_m["label"] if lmux_m else "lmux"
print(f"|                        | {cmux_label} | {lmux_label} |")
print("|------------------------|------------:|-----:|")
print(f"| App size               | {fmt(cmux_m and cmux_m['app_size_mb'], ' MB')} | {fmt(lmux_m and lmux_m['app_size_mb'], ' MB')} |")
print(f"| Memory (all processes) | {fmt_range(cmux_m, 'footprint_mb', ' MB')} | {fmt_range(lmux_m, 'footprint_mb', ' MB')} |")
print(f"| Idle CPU               | {fmt_range(cmux_m, 'cpu_mean', ' %', 1)} | {fmt_range(lmux_m, 'cpu_mean', ' %', 1)} |")
print(f"| Live shells            | {fmt(cmux_m and cmux_m['shells'], '')} | {fmt(lmux_m and lmux_m['shells'], '')} |")

# --- SVG chart generation ------------------------------------------------
BLOCKS = [
    {"title": "App size", "sub": "on disk", "metric": "app_size_mb", "range": None, "suffix": " MB", "decimals": 0,
     "title_y": 88, "sub_y": 106, "sep_y": 132},
    {"title": "Memory", "sub": "all processes, idle", "metric": "footprint_mb", "range": ("footprint_min", "footprint_max"), "suffix": " MB", "decimals": 0,
     "title_y": 162, "sub_y": 180, "sep_y": 206},
    {"title": "Idle CPU", "sub": "60 s average", "metric": "cpu_mean", "range": ("cpu_min", "cpu_max"), "suffix": " %", "decimals": 1,
     "title_y": 236, "sub_y": 254, "sep_y": None},
]
# Per block, row A = cmux slot (upper), row B = lmux slot (lower). Offsets
# are relative to title_y and match the hand-authored template exactly.
ROW_A = {"label_dy": -4, "bar_top_dy": -15, "bar_bot_dy": -1, "value_dy": -3}
ROW_B = {"label_dy": 20, "line_dy": 16, "value_dy": 21}

X0, WIDTH, RADIUS, VALUE_X, LABEL_X = 214, 420, 4, 644, 202

def bar_path(x0, y_top, y_bot, w):
    w = int(round(max(8, min(w, 530))))
    r = RADIUS
    return (f"M{x0} {y_top} H{x0+w-r} A{r} {r} 0 0 1 {x0+w} {y_top+r} "
            f"V{y_bot-r} A{r} {r} 0 0 1 {x0+w-r} {y_bot} H{x0} Z")

def render(theme):
    if theme == "light":
        bg_title, bg_muted, bg_label, bg_div = "#2E3440", "#5B657A", "#4C566A", "#D3D9E3"
        cmux_color, lmux_color = "#4C566A", "#4C6E99"   # Nord nord3, frost blue
    else:
        bg_title, bg_muted, bg_label, bg_div = "#ECEFF4", "#99A2B3", "#C4CBD7", "#3B4252"
        cmux_color, lmux_color = "#D8DEE9", "#88C0D0"   # Nord nord4, frost blue

    svg = []
    svg.append('<svg xmlns="http://www.w3.org/2000/svg" width="760" height="318" '
                'viewBox="0 0 760 318" role="img" aria-labelledby="t d">')
    svg.append('  <title id="t">cmux vs lmux: app size, memory, idle CPU</title>')

    def desc_part(name, m):
        if m is None:
            return f"{name}: to be measured (TBD)"
        return (f"{name}: app {m['app_size_mb']:.0f} MB, memory {m['footprint_mb']:.0f} MB "
                f"(all processes), idle CPU {m['cpu_mean']:.1f}%")
    svg.append(f'  <desc id="d">{desc_part(cmux_label, cmux_m)}. {desc_part(lmux_label, lmux_m)}. '
               f'Lower is better.</desc>')

    svg.append('  <g font-family="-apple-system, BlinkMacSystemFont, \'Segoe UI\', Helvetica, Arial, sans-serif">')
    svg.append(f'    <text x="0" y="20" font-size="15" font-weight="600" fill="{bg_title}">Same Mac, same workload</text>')
    svg.append(f'    <text x="0" y="40" font-size="12" fill="{bg_muted}">Lower is better. Each metric is scaled to the larger of the two.</text>')
    svg.append(f'    <g font-size="12" fill="{bg_label}">')
    if cmux_m:
        svg.append(f'      <rect x="564" y="11" width="12" height="12" rx="3" fill="{cmux_color}"/><text x="582" y="21">{cmux_label}</text>')
    else:
        svg.append(f'      <line x1="564" x2="576" y1="17" y2="17" stroke="{cmux_color}" stroke-width="1.5" stroke-dasharray="2 3" stroke-linecap="round"/><text x="582" y="21">{cmux_label} (TBD)</text>')
    if lmux_m:
        svg.append(f'      <rect x="672" y="11" width="12" height="12" rx="3" fill="{lmux_color}"/><text x="690" y="21">{lmux_label}</text>')
    else:
        svg.append(f'      <line x1="672" x2="684" y1="17" y2="17" stroke="{lmux_color}" stroke-width="1.5" stroke-dasharray="2 3" stroke-linecap="round"/><text x="690" y="21">{lmux_label} (TBD)</text>')
    svg.append('    </g>')

    for b in BLOCKS:
        cv = cmux_m[b["metric"]] if cmux_m else None
        lv = lmux_m[b["metric"]] if lmux_m else None
        svg.append(f'    <text x="0" y="{b["title_y"]}" font-size="13" font-weight="600" fill="{bg_title}">{b["title"]}</text>')
        svg.append(f'    <text x="0" y="{b["sub_y"]}" font-size="11" fill="{bg_muted}">{b["sub"]}</text>')

        ay = b["title_y"] + ROW_A["label_dy"]
        a_bar_top = b["title_y"] + ROW_A["bar_top_dy"]
        a_bar_bot = b["title_y"] + ROW_A["bar_bot_dy"]
        a_val_y = b["title_y"] + ROW_A["value_dy"]
        by_ = b["title_y"] + ROW_B["label_dy"]
        b_line_y = b["title_y"] + ROW_B["line_dy"]
        b_val_y = b["title_y"] + ROW_B["value_dy"]

        larger = max([v for v in (cv, lv) if v is not None] or [0]) or 1

        def whisker(m, v, y_lo, y_hi):
            # Thin min-max tick across the bar's end, only when the result
            # has >1 rep and an actual range (skipped for App size, which
            # isn't reps-aggregated).
            if b["range"] is None or m is None or m["reps"] <= 1:
                return
            lo_key, hi_key = b["range"]
            lo, hi = m[lo_key], m[hi_key]
            if hi <= lo:
                return
            x_lo, x_hi = X0 + WIDTH * lo / larger, X0 + WIDTH * hi / larger
            svg.append(f'    <line x1="{x_lo:.1f}" x2="{x_hi:.1f}" y1="{(y_lo+y_hi)/2:.1f}" y2="{(y_lo+y_hi)/2:.1f}" stroke="{bg_title}" stroke-width="1.5" stroke-opacity="0.45"/>')
            for x in (x_lo, x_hi):
                svg.append(f'    <line x1="{x:.1f}" x2="{x:.1f}" y1="{y_lo}" y2="{y_hi}" stroke="{bg_title}" stroke-width="1.5" stroke-opacity="0.45"/>')

        svg.append(f'    <text x="{LABEL_X}" y="{ay}" font-size="11" text-anchor="end" fill="{bg_label}">{cmux_label.split()[0]}</text>')
        if cv is not None:
            w = WIDTH * cv / larger
            svg.append(f'    <path d="{bar_path(X0, a_bar_top, a_bar_bot, w)}" fill="{cmux_color}"/>')
            whisker(cmux_m, cv, a_bar_top, a_bar_bot)
            svg.append(f'    <text x="{VALUE_X}" y="{a_val_y}" font-size="12" font-weight="600" fill="{bg_title}" style="font-variant-numeric: tabular-nums">{cv:.{b["decimals"]}f}{b["suffix"]}</text>')
        else:
            mid = (a_bar_top + a_bar_bot) // 2
            svg.append(f'    <line x1="{X0}" x2="{X0+WIDTH}" y1="{mid}" y2="{mid}" stroke="{cmux_color}" stroke-width="1.5" stroke-dasharray="2 4" stroke-linecap="round" stroke-opacity="0.7"/>')
            svg.append(f'    <text x="{VALUE_X}" y="{a_val_y}" font-size="12" font-weight="600" fill="{bg_muted}">TBD</text>')

        svg.append(f'    <text x="{LABEL_X}" y="{by_}" font-size="11" text-anchor="end" fill="{bg_label}">{lmux_label.split()[0]}</text>')
        if lv is not None:
            w = WIDTH * lv / larger
            bar_top_b, bar_bot_b = b_line_y - 7, b_line_y + 7
            svg.append(f'    <path d="{bar_path(X0, bar_top_b, bar_bot_b, w)}" fill="{lmux_color}"/>')
            whisker(lmux_m, lv, bar_top_b, bar_bot_b)
            svg.append(f'    <text x="{VALUE_X}" y="{b_val_y}" font-size="12" font-weight="600" fill="{bg_title}" style="font-variant-numeric: tabular-nums">{lv:.{b["decimals"]}f}{b["suffix"]}</text>')
        else:
            svg.append(f'    <line x1="{X0}" x2="{X0+WIDTH}" y1="{b_line_y}" y2="{b_line_y}" stroke="{lmux_color}" stroke-width="1.5" stroke-dasharray="2 4" stroke-linecap="round" stroke-opacity="0.7"/>')
            svg.append(f'    <text x="{VALUE_X}" y="{b_val_y}" font-size="12" font-weight="600" fill="{bg_muted}">TBD</text>')

        if b["sep_y"] is not None:
            svg.append(f'    <line x1="0" x2="760" y1="{b["sep_y"]}" y2="{b["sep_y"]}" stroke="{bg_div}" stroke-width="1"/>')

    def footer_part(name, m):
        if m is None:
            return f"{name}: to be measured by scripts/bench.sh"
        reps_part = f", median of {m['reps']} runs (min–max shown)" if m["reps"] > 1 else ""
        return f"{name}: scripts/bench.sh, {m['workload']} workload{reps_part}, {m['timestamp'][:10]}"
    svg.append(f'    <text x="0" y="310" font-size="11" fill="{bg_muted}">{footer_part(cmux_label, cmux_m)}. {footer_part(lmux_label, lmux_m)}.</text>')
    svg.append('  </g>')
    svg.append('</svg>')
    return "\n".join(svg) + "\n"

with open(os.path.join(assets_dir, "bench-chart.svg"), "w") as f:
    f.write(render("light"))
with open(os.path.join(assets_dir, "bench-chart-dark.svg"), "w") as f:
    f.write(render("dark"))
print(f"\nWrote {assets_dir}/bench-chart.svg and bench-chart-dark.svg", file=sys.stderr)
PY

python3 "$HELPER" "$1" "$2" "$ASSETS_DIR"
