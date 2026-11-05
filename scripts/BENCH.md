# Benchmarking lmux vs cmux

A fair comparison needs the same Mac and the same workload for both apps.
`scripts/bench.sh` measures one app; `scripts/bench-compare.sh` turns two
results into the README table and the `assets/bench-chart*.svg` charts, or a
whole scaling series into one table and `bench-scaling*.svg`.

## Where the README numbers come from

The README table, `assets/bench-scaling*.svg` and the site are one local
run on an M4 Pro Mac (macOS 26.6.2), lmux 0.0.102 vs cmux 0.65.2, made with
the scripts below:

- **Shape**: the scaling series, 1, 10 and 20 workspaces x 2 panes, every
  pane's shell live before measuring (same check as below).
- **Three sides per step**: lmux in front, lmux in the background
  (`LMUX_HEADLESS_BACKGROUND=1`: the window counts as not key, as when
  lmux sits behind another app, so idle panes release their GPU memory;
  see `App/README.md`), and cmux.
- **Interleaved, fresh launches**: for each step, 5 rounds of lmux front,
  lmux background, cmux, each a fresh launch measured by `bench.sh --reps 1`
  (15 s settle, 60 s sample), with 10 s of quiet in between. The 5 runs per
  side are merged into one result and the tables show the median. Doing it
  this way spreads any slow minute on the machine across all three sides
  instead of landing on one.
- **cmux** is launched and primed the way `.github/scripts/cmux-workload.sh`
  does it (`new-workspace`, `new-split right`, `true` sent to every
  surface, exact counts or fail), adapted to run locally: pane shells get
  a throwaway `ZDOTDIR`/`HISTFILE`, and its saved session is deleted after
  each run so nothing is restored into the next one.
- **Screen locked**: the display was locked and asleep for the whole run.
  lmux's front/background split is set by the env var above, so it is
  unaffected, but cmux had no visible window either. cmux's memory moves
  a lot with window state (an earlier run with the screen on measured it
  noticeably differently), so its numbers are one snapshot, not a constant.
- **App size**: `du -sk` of each Apple-silicon `.app`: lmux's arm64 build
  (24.7 MB) and the app inside cmux's `cmux-macos-arm64.dmg` (241.6 MB),
  the same DMG `bench.yml` downloads. cmux's universal `cmux-macos.dmg`
  (x86_64 + arm64) installs a 454 MB app; that is the one memory and CPU
  were measured on, and it runs the same arm64 code.

`bench.yml` below is the reproducible path: anyone can dispatch it and
get both apps on the same GitHub-hosted Mac. Its numbers will be
re-published when lmux launches.

## The standard workload

**10 workspaces x 2 panes = 20 panes**, each an idle login shell, 15 s
settle, then 60 s of sampling. `--workspaces N` keeps the shape (2 panes per
workspace) at another size; the scaling series runs N = 1, 10, 20 (2, 20, 40
panes). `--workload small` (1 workspace, 1 pane, short) is a smoke test only.

**Every pane has a live shell before anything is measured.** cmux starts a
pane's shell lazily (in an early CI run only 4 of its 10 panes had one), so
both apps get the same treatment: `true` is typed into every pane (lmux:
`lmux send`, by `bench.sh`; cmux: each workspace selected once, then `cmux
send` to each surface, by `cmux-workload.sh`). `bench.sh` then counts the
pane shells under the app -- the outermost `zsh`/`bash`/... processes, login
`-zsh` included, subshells not -- waits up to 30 s for the count to reach
the pane count, and exits 3 without measuring unless it's exactly one per
pane. The count is in the JSON (`workload_detail.shells_live`) and in the
tables.

## Repeated measurements (`--reps`)

A single 60 s sample is noisy -- idle CPU in particular can land anywhere in
a wide range depending on what the OS scheduler happens to be doing that
minute, and a one-run series can come out non-monotonic (a bigger workload
measuring as *less* idle CPU than a smaller one) purely from that noise.
`--reps N` (default 1) repeats the whole measurement N times within one
`bench.sh` invocation and reports the **median**, with the **min-max range**
alongside it, instead of a single noisy number:

- **lmux**: each rep is a fully fresh launch -- new temp state dir, launch,
  wait for the workload, prime every pane, measure, kill -- the same
  lifecycle `bench.sh` always gave lmux, just repeated.
- **cmux** (or any attach-only app): `bench.sh` never launches or signals it
  (same rule as always), so a "fresh" rep there is a fresh settle+sample
  window against the one already-running, already-primed instance. Re-priming
  cmux between reps -- if it's ever needed -- is the CI workflow's job (it
  already launches/stops/re-primes cmux once per workspace-count step); this
  script only ever attaches and samples.

Why median instead of mean: a single stalled sample (e.g. a GC pause, a
background OS task) pulls a mean up a lot but barely moves the median, and
the min-max range already shows the reader how wide that stall made things.

Every rep's full result is written to the JSON (`rep_results`), plus
`aggregate.{footprint_mb,cpu_mean_pct,launch_seconds}`, each
`{median, min, max}` across reps. The top-level `memory_mb`/`cpu_pct`/`launch`
fields mirror the *last* rep (for a quick glance at one `jq` query); anything
that compares runs (`bench-compare.sh`, the charts) reads `aggregate`
instead. A result from an older `bench.sh` (no `--reps`, reps implicitly 1,
no `aggregate`) still works everywhere `aggregate` is read: the fallback is
just that single value, with min == max (no visible range).

**Display precision:** idle CPU is shown to **1 decimal place** (e.g.
`0.3 %`), not 2. A 60 s mean's precision doesn't really support a second
decimal digit once you're averaging 5 runs and showing a range anyway, and
one fewer digit makes the median/min-max triplet (`0.3 % (0.1-0.6)`) easier
to read at a glance. Memory footprint stays at 0 decimals (whole MB), as
before. This is a display-only change in `bench.sh` and `bench-compare.sh`.
The README table spells idle CPU out to 2 decimals anyway, because lmux's
sits below 0.1 % and 1 decimal would round it away.

The comparison/scaling series (`.github/workflows/bench.yml`) runs with
**`--reps 5`** by default; see "On CI" below for the runtime cost.

## Running it

### lmux

```sh
scripts/bench.sh App/build/lmux.app --label lmux --out lmux.json                    # 10 x 2
scripts/bench.sh App/build/lmux.app --label lmux --workspaces 20 --out lmux-20.json # 20 x 2
scripts/bench.sh App/build/lmux.app --label lmux --reps 5 --out lmux.json           # 10 x 2, median of 5
```

This script launches lmux itself, **headless** (`LMUX_HEADLESS=1`: no
window on screen, no Dock icon, no stolen focus) and kills it again when
it's done, every time. The workload is a layout restored from a temp state
dir (N workspaces, each split into 2 panes, the same shape the CI cmux run
is built with), so your real lmux state, sockets and History are never
used. `--visible` (CI only, refused unless `GITHUB_ACTIONS=true`) launches
it with a real window instead, so a comparison against a visible cmux
renders the same way on both sides.

### On CI (`.github/workflows/bench.yml`)

`bench.yml` (manual dispatch + weekly) builds lmux, downloads the latest
cmux release DMG, and runs the scaling series on one runner, in a fixed
order: 1, 10, then 20 workspaces x 2 panes, lmux then cmux at each step,
**each with `--reps 5`**. lmux is measured by `bench.sh --visible --reps 5`:
5 fully fresh launches per step. cmux is launched once per step by
`.github/scripts/cmux-workload.sh` (CI only), which builds the same shape
through cmux's own CLI (`new-workspace`, `new-split right`), primes every
pane and fails unless the workspace and pane counts are exact, then
`bench.sh --reps 5` measures it attach-only -- 5 fresh settle+sample windows
against that one launch, never relaunching or re-signaling cmux itself. Each
*step* (workspace count) still starts from a fresh launch of each app: lmux
from a new temp state dir on its first rep, cmux after the previous step's
instance has exited and its saved session file was deleted (so nothing is
restored), with 10 s of quiet between runs on top of each rep's 15 s settle.
If a step fails (e.g. a size the runner can't hold), the series stops there,
the earlier steps are still compared and uploaded, and the job is marked
failed.

**Runtime**: 5 reps/step is roughly 5x the sampling time of a single run.
Per step, lmux is ~5 x (15 s settle + 60 s sample + ~10-15 s launch/workload
overhead) =~ 7-8 min; cmux is one workload build (~15-40 s) plus 5 x (15 s
settle + 60 s sample) =~ 6-7 min. Each step is roughly 14-16 min, so the full
1/10/20 series is roughly 45-55 min of measuring, plus checkout/bundle/
cmux-download overhead -- `bench.yml`'s `timeout-minutes` is set to 90 to
leave headroom.

Artifacts: every step's JSON (every rep, plus median/min/max), `series.md`
(one row per metric -- including a `Reps` row -- one column per step and
app), `bench-scaling.svg` + `-dark.svg` (median memory and idle CPU vs
workspace count, with a min-max whisker per point), and the 10-workspace
pair as the README table (`table.md`) and bar charts (with a min-max tick on
each bar). Nothing is committed.

### cmux

**This needs a fresh cmux instance** -- not the one you use all day, which
this script will never touch. When you're ready to run the real
comparison:

1. Save your work, then quit your current cmux yourself and relaunch it.
2. Build the workload by hand so it matches lmux's:
   - Open 10 workspaces.
   - Split each one once: 20 panes total.
   - Click into every pane and run `true`, so each one has a live shell
     (`bench.sh` refuses to measure otherwise).
   - Let it all sit idle for a few seconds before moving on.
3. Note the app path (usually `/Applications/cmux.app`), then run:

   ```sh
   scripts/bench.sh /Applications/cmux.app --label "cmux 0.65.2" --out cmux.json
   ```

   `bench.sh` never launches or signals cmux -- it only finds the
   already-running process tree and measures it. It errors out if it
   can't find one, so step 1-2 have to happen first.

### Compare and update the chart

```sh
scripts/bench-compare.sh cmux.json lmux.json
```

Prints the measured README table rows (App size, Memory, Idle CPU, Live
shells) and regenerates `assets/bench-chart.svg` + `assets/bench-chart-dark.svg`
in place. Memory and Idle CPU are each the **median across reps**, with a
`(min-max)` suffix when the result has more than one rep (e.g. `90 MB
(88-94)`); a single-rep (or older, pre-`--reps`) result just shows the one
number, same as before. The bar chart draws a thin min-max tick on each bar
for the same reason. Argument order doesn't matter -- each file's `app_kind`
field says which side it is. Either argument can be `TBD` (or any path that
doesn't exist) to render that side as a placeholder.

```sh
scripts/bench-compare.sh --series out/ lmux-*.json cmux-*.json
```

Scaling series: prints app size once, then one table with a row per metric
(panes, live shells, reps, memory footprint, idle CPU mean -- both as
median with a min-max suffix -- and idle CPU p95 from the last rep) and a
column per (workspace count, app), and writes `out/bench-scaling.svg` +
`bench-scaling-dark.svg`: each point on the scaling chart is the median
across reps, with a thin min-max whisker drawn through it (caption: "median
of N runs, bars show min-max"). It doesn't touch `assets/`. Results are
grouped by `app_kind`, so a third side gets its own line: the README chart's
background lmux is the same JSONs with `app_kind` set to `lmux-bg` (and
`label` to `lmux (background)`).

## What gets measured, and how

- **App size**: `du -sk` of the whole `.app` bundle.
- **Process groups**, found without root:
  - `main` / `bundle_helpers`: every process whose executable path lives
    inside the bundle (`Contents/MacOS/...`, embedded helper `.app`s,
    bundled XPC services). This is a plain path-prefix match on `ps -axo
    comm=`, so it also catches Electron-style helper processes, which
    ship inside the bundle regardless of how they're parented.
  - `shell_children`: everything descended from those processes that
    *isn't* in the bundle -- the pane's login shell and whatever runs in
    it (e.g. `claude`). This is terminal overhead the workload itself
    creates, not app bloat, so it's reported separately and excluded from
    the app-size and headline-CPU numbers.
  - `xpc_webkit`: system WebKit/XPC processes the app spawned via
    `responsible pid` rather than a normal parent/child link (relevant
    for an in-app browser built on WKWebView; Electron's own helpers are
    already caught by the bundle-path match above). The kernel only
    reports responsible-pid through `launchctl procinfo`, which requires
    root. Without `sudo`, this group is honestly reported as empty rather
    than guessed by process name -- a name-only guess was tried during
    development and it mis-attributed another, unrelated app's WebKit
    processes to lmux, which has no browser engine at all. Re-run
    `bench.sh` with `sudo` if you need this group measured.
- **Memory**: RSS (`ps -o rss=`) and physical footprint (`footprint -p`,
  falling back to `vmmap --summary`) summed per group. Footprint is the
  headline number in the table -- it's the fairer one.
- **CPU**: `ps -o %cpu=` sampled once a second over the sample window
  (60 s for the standard workload) after a 15 s settle period, mean and
  p95 per group. The headline "Idle CPU" is `main + bundle_helpers +
  xpc_webkit` -- shell children are excluded, same reasoning as above.
- **Launch time**: wall clock from spawning the process to either its
  hook socket appearing or its first child process appearing, whichever
  comes first. Only measured for lmux (which this script launches);
  marked `"manual"` for everything else, since this script never launches
  anything but lmux.

## Known limitations

- `xpc_webkit` needs `sudo` to be non-empty (see above). It's expected to
  always be empty for lmux.
- CPU/memory are sampled from a snapshot of process groups taken right
  after the workload is set up; if the workload changes shape mid-run
  (new panes opened, etc.) the snapshot won't follow it.
- Shell counting matches process names (`zsh`, `bash`, `sh`, `fish`, ...).
  A pane running something else as its program (not a shell) would not be
  counted, and the run would fail rather than measure.
