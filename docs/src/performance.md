# Performance

lmux's one rule is to stay light. It's a 25 MB native macOS terminal that idles near 0% CPU, whether you have one workspace open or twenty.

## The numbers

Both apps on the same Mac, opened with 1, 10 and 20 workspaces (2 live shells each) and left idle. Lower is better. lmux lets go of its GPU memory when it isn't the app you're looking at, so it's measured twice: in front, and in the background behind another app.

| | cmux 0.65.2 | lmux, in front | lmux, in the background |
|---|---:|---:|---:|
| App size | 242 MB | **25 MB** | **25 MB** |
| Memory, 1 workspace | 398 MB | **182 MB** | **45 MB** |
| Memory, 10 workspaces | 548 MB | **207 MB** | **71 MB** |
| Memory, 20 workspaces | 661 MB | **235 MB** | **99 MB** |
| Idle CPU, 1 workspace | 7.16 % | **0.07 %** | **0.00 %** |
| Idle CPU, 10 workspaces | 7.39 % | **0.12 %** | **0.00 %** |
| Idle CPU, 20 workspaces | 8.10 % | **0.10 %** | **0.00 %** |
| Settings | ~200 | **~10** | **~10** |

Idle CPU is the one you feel: that's your battery, with twenty agents sitting there waiting for you to read what they wrote.

## How it was measured

- An M4 Pro Mac on macOS 26.6.2, lmux 0.0.102 vs cmux 0.65.2, with `scripts/bench.sh`.
- 2 panes per workspace, every pane's shell live before measuring (a command is typed into each; the run stops unless the count is exact).
- For each size, 5 interleaved rounds of lmux in front, lmux in the background and cmux, each a fresh launch with 15 s to settle and 60 s of sampling. The table shows the medians.
- Memory is the physical footprint of all of the app's processes. App size is the Apple-silicon `.app` on disk. The shells and agents inside the panes are the same on both sides and aren't counted: this is the terminal's own cost.
- The screen was locked during the run, so cmux was in the background too, and its memory moves a lot with window state: read its column as one snapshot. lmux's 0.07–0.12 % spread is within run-to-run noise.

The full method, and how to run it yourself (locally or on a GitHub-hosted Mac), is in [scripts/BENCH.md](https://github.com/sooftware/lmux/blob/main/scripts/BENCH.md).

## Why it stays light

- Native Swift on libghostty: no browser engine, no Electron.
- Windows that are hidden, minimized or covered stop drawing. Nothing animates unless it means something, and what does animate runs on Core Animation, off the main thread.
- An unfocused pane that hasn't drawn for 3 seconds releases its GPU resources, and rebuilds them in about 3 ms when it's needed again.
- Nothing polls: agent state comes from hooks and from the agents' own reports.
- History's first index runs in a short-lived helper process, so indexing thousands of sessions never grows the app's memory.

## Budgets in CI

CI fails any change that pushes idle CPU over budget: under 1% CPU and 300 MB, with 1 pane and with 10 panes across 5 workspaces. Busy cases have budgets too: 20 idle workspaces, agents working in hidden panes, CPU per hook event, spinner titles, memory of hidden panes, restoring 120 workspaces and History's first index.
