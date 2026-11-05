## What

<!-- What changes, and why. -->

## Tests

- [ ] `cd Core && swift test`
- [ ] `App/scripts/apptest.sh` (headless app harness)
- [ ] `App/scripts/imetest.sh` (IME/font/theme, headless); real-IME checks run on CI (`imetest.sh --visible`)
- [ ] `App/scripts/measure_idle.sh 20` and `20 10 2` (idle CPU < 1%, RSS < 300 MB)
- [ ] `App/scripts/perf_budget.py` if the change touches hooks, titles, the sidebar, panes or History
- [ ] `App/scripts/e2etest.sh` if message actions / hooks changed (the real Claude Code binary, offline)
- [ ] Manual items left in `App/IME_CHECKLIST.md` if input handling changed
