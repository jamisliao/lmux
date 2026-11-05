# Contributing to lmux

Thanks for even thinking about it.

## The scope rule

lmux stays light: features many people use stay; things that are mostly weight go. And it never
wraps `claude` or `codex`: lmux listens through hooks and the files the agents already write, so
both run exactly the same with or without it. Before
writing code for something new, it's worth asking in an issue first — "how many people would
use this, and what does it cost" (app size, idle CPU/memory, settings, complexity) is the actual
bar, not "would this be nice." See the README's
["Why not lmux?"](README.md#lmux-vs-cmux) list for what's
already been left out, and why.

**No code from cmux.** lmux is inspired by cmux's layout and ideas, but cmux is GPL-licensed and
lmux is MIT. Nothing copied or adapted from cmux's source goes into this repo, ever — UX can be
mirrored, code cannot.

## Building from source

```sh
scripts/bootstrap.sh     # clones Ghostty at the pinned commit, fetches Zig, builds GhosttyKit.xcframework
App/scripts/bundle.sh    # builds lmux.app
```

See `release/RELEASING.md` for what each of those actually does.

## Tests

```sh
cd Core && swift test                 # hooks (Claude Code and Codex), transcripts, sessions, security
App/scripts/apptest.sh                # headless app harness (workspaces, splits, hooks -> sidebar, CLI, persistence)
App/scripts/apptest.sh --quick        # same, skipping the slower restore / large-transcript / latency runs
App/scripts/imetest.sh                # IME/font/theme, headless (real-IME checks only run on CI)
```

`scripts/test-local.sh` runs all of the above plus the idle and perf budgets and the docs check, headless, and prints one PASS/FAIL line per step (`--quick` for the short version). It's the same suite CI runs, minus the real-IME and real-window jobs, which need a visible window.

Optional: `scripts/install-git-hooks.sh` installs a pre-push hook that runs `swift test` and
`apptest.sh --quick` before every push (`git push --no-verify` skips it once).

The harnesses run lmux headless with their own `LMUX_STATE_DIR`, never your real one, and set
`LMUX_ALLOW_EXTERNAL_SEND=1` so they can drive panes from outside (see below).

## The security model, briefly

Keep these intact; `lmux-apptest --security` (part of `apptest.sh`) checks them.

- Each pane gets a secret `LMUX_PANE_NONCE` (also as `LMUX_PANE_TOKEN`, the old name, for one release). A hook event counts only for the pane its token names,
  and `lmux send` from inside a pane may only target that pane.
- From outside lmux (no valid token), `lmux send` and `new-workspace --cmd` are refused unless
  `defaults write dev.lmux.app allowExternalSend -bool true` or `LMUX_ALLOW_EXTERNAL_SEND=1` is in
  lmux's own environment.
- The state dir is 0700 and must be owned by you (lmux starts nothing otherwise); state files are
  0600. Both sockets live there and serve only the same uid.
- Anything lmux types into a shell to restore a session is checked first: UUID session ids,
  no control characters, an allowlist of non-secret env.

## The perf budget

CI enforces an idle budget on every PR (`App/scripts/measure_idle.sh`): idle CPU under 1% and
RSS under 300 MB, with 1 pane and with 10 panes across 5 workspaces. `App/scripts/perf_budget.py`
adds the busy cases: 20 workspaces idle, agents working in hidden panes, CPU per hook event,
spinner titles, memory of hidden panes, restoring 120 workspaces and the History first index.
A change that blows a budget needs to explain why before it's worth merging — see the scope rule above.

## Before opening a PR

- Keep changes focused; unrelated cleanup makes review harder, not easier.
- Run the tests above locally (`Core swift test` + `App/scripts/apptest.sh --quick` at minimum).
- Match the existing code style rather than introducing a new one.
- Fill in the PR template — the tests you ran, not just the ones that exist.
- Small, explained PRs get reviewed faster than large, unexplained ones.
