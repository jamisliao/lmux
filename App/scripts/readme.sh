#!/bin/bash
# README visuals, rendered offscreen from the real app (headless: no window on screen, no
# focus taken). Fixture sessions are replayed by App/scripts/readme/claude; no model is called.
#
#   App/scripts/readme.sh        -> assets/screenshots/hero-{dark,light}.png, assets/gifs/*.gif
#   App/scripts/readme.sh --draft DIR   debug build, outputs to DIR only (iterating on scenes)
#   App/scripts/readme.sh hero [--draft DIR]   -> docs/site/video/hero-*.{mp4,webm}, docs/site/img posters,
#                                  assets/screenshots/hero-*.png (see readme/hero.sh; needs ffmpeg)
#
# Everything runs in a temp HOME (~/code/acme-* repos, ~/.claude) so nothing from this Mac
# shows up in the frames, and nothing outside the temp dir is written except the outputs.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
cd "$APP_DIR"
# Release build, so light.gif's numbers are the optimized app's (the harness needs @testable).
CFG=(-c release -Xswiftc -enable-testing)
DRAFT=""
HERO=""
if [ "${1:-}" = hero ]; then HERO=1; shift; fi
if [ "${1:-}" = "--draft" ]; then CFG=(-c debug); DRAFT="${2:?dir}"; fi
swift build "${CFG[@]}" --product lmux-apptest >/dev/null
swift build "${CFG[@]}" --product lmux-cli >/dev/null
(cd ../Core && swift build "${CFG[@]:0:2}" --product lmux-hook >/dev/null)
BIN="$(swift build "${CFG[@]}" --show-bin-path)"

T="$(mktemp -d /tmp/lmux-readme.XXXXXX)"
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"   # removed with $T on exit
APPPID=""
trap 'pkill -f "lmux-apptest --(readme|hero)" 2>/dev/null || true; [ -n "$APPPID" ] && kill $APPPID 2>/dev/null; rm -rf "$T"' EXIT

# light.gif's HUD: the bundled lmux.app (App/scripts/bundle.sh), headless, with light.gif's layout
# (10 workspaces x 2 panes, idle shells, each pane's shell checked live), sampled like
# measure_idle.sh. Frames come from the harness; the harness's own memory is never shown.
source "$APP_DIR/scripts/isolated-shell.sh"
measure_app() {
  local APP="$APP_DIR/build/lmux.app" S="$T/measure"
  [ -x "$APP/Contents/MacOS/lmux" ] || { echo "no $APP: run App/scripts/bundle.sh first" >&2; return 1; }
  mkdir -p "$S/projects"
  # Idle shells, but isolated ones (temp ZDOTDIR / HISTFILE), never the user's login shell.
  lmux_isolated_shell "$S/shell"
  python3 - "$S/layout.json" <<'PY'
import json, sys, uuid
def pane(): return {"pane": {"id": str(uuid.uuid4()).upper()}}
def two(): return {"axis": "horizontal", "ratio": 0.5, "children": [pane(), pane()]}
ws = [{"id": str(uuid.uuid4()).upper(), "accent": i % 8, "root": two()} for i in range(10)]
json.dump({"version": 1, "workspaces": ws, "selected": ws[0]["id"], "sidebarVisible": True, "sidebarWidth": 240},
          open(sys.argv[1], "w"))
PY
  LMUX_HEADLESS=1 LMUX_STATE_DIR="$S" LMUX_CLAUDE_PROJECTS="$S/projects" "$APP/Contents/MacOS/lmux" >/dev/null 2>&1 &
  APPPID=$!
  sleep 8
  # One live login shell per pane (lmux's pty children are login(1), each running the shell).
  local shells
  shells=$(ps -axo ppid=,comm= | awk -v p="$(pgrep -P $APPPID | tr '\n' ' ')" \
    'BEGIN{n=split(p,a," "); for(i=1;i<=n;i++) k[a[i]]=1} ($1 in k) && $2 ~ /(^|\/)-?(zsh|bash|sh|fish)$/ {c++} END{print c+0}')
  [ "$shells" -eq 20 ] || { echo "lmux.app: $shells live shells, expected 20" >&2; kill $APPPID; APPPID=""; return 1; }
  cpu_s() { ps -o cputime= -p "$1" | awk -F'[:.]' '{ if (NF==4) print $1*3600+$2*60+$3+$4/100; else print $1*60+$2+$3/100 }'; }
  local T0 W0 T1 W1 RSS
  T0=$(cpu_s $APPPID); W0=$(date +%s); sleep 20; T1=$(cpu_s $APPPID); W1=$(date +%s)
  RSS=$(( $(ps -o rss= -p $APPPID | tr -d ' ') / 1024 ))
  kill $APPPID; APPPID=""
  echo "cpu=$(echo "scale=2; ($T1 - $T0) * 100 / ($W1 - $W0)" | bc | sed 's/^\./0./') rss=$RSS"
}
ONLY="${README_ONLY:-all}"
[ -n "$HERO" ] && ONLY=hero
if [ "$ONLY" != scenes ] && [ "$ONLY" != hero ]; then
  export LMUX_README_APP_STATS="$(measure_app)"
  echo "lmux.app, 10 workspaces / 20 panes, idle: $LMUX_README_APP_STATS"
fi
mkdir -p "$T/bin" "$T/state" "$T/light" "$T/out" "$T/home/.claude/projects"
cp "$BIN/lmux-cli" "$T/bin/lmux"
cp "$(cd ../Core && swift build "${CFG[@]:0:2}" --show-bin-path)/lmux-hook" "$T/bin/lmux-hook"
cp scripts/readme/claude scripts/readme/codex scripts/readme/fake_claude.py "$T/bin/"
for repo in acme-api:fix/refresh-race acme-ios:ci/flaky-macos acme-web:docs/readme acme-cli:release/v0.1 \
            acme-app:perf/cold-start acme-docs:main acme-infra:infra/plan acme-sdk:feat/retry \
            acme-site:feat/pricing acme-data:main; do
  d="$T/home/code/${repo%%:*}"
  mkdir -p "$d/.git"
  echo "ref: refs/heads/${repo#*:}" > "$d/.git/HEAD"
done

export HOME="$T/home" CFFIXED_USER_HOME="$T/home" CLAUDE_CONFIG_DIR="$T/home/.claude"
export LMUX_HEADLESS=1 LMUX_BIN_DIR="$T/bin" LMUX_FONTS_DIR="$APP_DIR/Resources/Fonts"
export LMUX_CLAUDE_PROJECTS="$T/home/.claude/projects" FAKE_CLAUDE_DIR="$T/home/.claude/projects"
# Pane shell: zsh with only a `~/code/x %` prompt (no global rc files, no host name, no login banner).
mkdir -p "$T/home/.zdot"
echo "PROMPT='%~ %# '" > "$T/home/.zdot/.zshrc"
# Ghostty starts panes through login(1), which resets HOME: the temp one is set here again.
cat > "$T/bin/pane-shell" <<SH
#!/bin/zsh -f
export HOME="$T/home" ZDOTDIR="$T/home/.zdot"
printf '\033[2J\033[3J\033[H'
exec /bin/zsh -d -i
SH
chmod +x "$T/bin/pane-shell"
export LMUX_PANE_COMMAND="$T/bin/pane-shell" LANG=en_US.UTF-8
for v in $(env | grep -o '^\(CLAUDE_CODE\|ANTHROPIC\)[A-Z_]*=' | tr -d '='); do unset "$v"; done
if [ -d "$APP_DIR/build/lmux.app/Contents/Resources/ghostty" ]; then
  export GHOSTTY_RESOURCES_DIR="$APP_DIR/build/lmux.app/Contents/Resources/ghostty"
else
  RES="$APP_DIR/build/test-resources/ghostty"
  mkdir -p "$RES/themes" && cp "$APP_DIR/Resources/themes/"* "$RES/themes/"
  export GHOSTTY_RESOURCES_DIR="$RES"
fi

filter() { grep -v '^\(info\|debug\|warning\)(' || true; }
if [ "$ONLY" = hero ]; then source "$APP_DIR/scripts/readme/hero.sh"; exit 0; fi
[ "$ONLY" = light ] || LMUX_STATE_DIR="$T/state" "$BIN/lmux-apptest" --readme "$T/out" 2>/dev/null | filter
[ "$ONLY" = scenes ] || LMUX_STATE_DIR="$T/light" LMUX_CLAUDE_PROJECTS="$T/light/projects" FAKE_CLAUDE_DIR="$T/light/projects" "$BIN/lmux-apptest" --readme-light "$T/out" 2>/dev/null | filter
if [ -n "$DRAFT" ]; then mkdir -p "$DRAFT" && cp "$T/out/"* "$DRAFT/" && ls -l "$DRAFT"; exit 0; fi

mkdir -p "$ROOT/assets/screenshots" "$ROOT/assets/gifs"
for m in dark light; do
  [ -f "$T/out/hero-$m.png" ] && cp "$T/out/hero-$m.png" "$ROOT/assets/screenshots/hero-$m.png"
done
for g in light needs-input history forget korean-ime; do
  [ -f "$T/out/$g.gif" ] && cp "$T/out/$g.gif" "$ROOT/assets/gifs/$g.gif"
done
ls -l "$ROOT/assets/screenshots" "$ROOT/assets/gifs"
