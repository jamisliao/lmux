#!/bin/bash
# End-to-end message actions on the real Claude Code binary, offline: ✎ edit & resend, × remove,
# ⌘Z undo send (all through Claude Code's own rewind menu, in the running claude), Copy original.
# Headless: no window on screen, no focus change.
#
# Nothing outside a temp dir is read or written: claude runs with its own HOME and
# CLAUDE_CONFIG_DIR in the temp dir (onboarding done, the fake API key approved, the scratch dir
# trusted, only lmux's hooks in its settings), and talks to a local stand-in for the Anthropic API
# (scripts/claude-api-mock.py), which logs every request, so the run can check what Claude really
# sent after a rewind. No login, no network, no cost.
#
#   App/scripts/e2etest.sh            (LMUX_E2E_DUMP=1 prints the screens;
#                                      --bench: rewind timings instead, see RewindBench.swift;
#                                      --hover: hover band / pill / × per turn, see E2EHover.swift;
#                                      LMUX_E2E_THEME=light: Claude's light theme;
#                                      LMUX_E2E_CLAUDE=/path/to/claude picks the binary)
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
cd "$APP_DIR"

# The claude binary itself (a version manager's shim would need the real HOME).
CLAUDE_BIN="${LMUX_E2E_CLAUDE:-}"
if [ -z "$CLAUDE_BIN" ]; then
  CLAUDE_BIN="$( (asdf which claude 2>/dev/null) || command -v claude || true)"
fi
[ -n "$CLAUDE_BIN" ] || { echo "FAIL  [e2e] claude not found (set LMUX_E2E_CLAUDE)"; exit 1; }
CLAUDE_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CLAUDE_BIN")"
echo "      claude: $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null | head -1))"

swift build --product lmux-apptest >/dev/null
(cd ../Core && swift build --product lmux-hook >/dev/null)
BIN="$(swift build --show-bin-path)"

# Short temp path: Unix socket paths are limited to ~104 bytes.
T="$(mktemp -d /tmp/lmux-e2e.XXXXXX)"
T="$(cd "$T" && pwd -P)"
mkdir -p "$T/tmp" "$T/bin" "$T/state" "$T/home/.claude" "$T/work"
WORK="$T/work"
CFG="$T/home/.claude"
cp "$(cd ../Core && swift build --show-bin-path)/lmux-hook" "$T/bin/lmux-hook"
# Only lmux's hooks, written by lmux's own installer into the temp config's settings.
LMUX_STATE_DIR="$T/state" "$T/bin/lmux-hook" install --settings "$CFG/settings.json" --hook-path "$T/bin/lmux-hook" >/dev/null

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
KEY="sk-ant-api03-lmux-e2e-$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
python3 - "$CFG/.claude.json" "$KEY" "$WORK" <<'PY'
import json, os, sys
path, key, work = sys.argv[1:4]
json.dump({"hasCompletedOnboarding": True, "theme": os.environ.get("LMUX_E2E_THEME", "dark"),
           "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []},
           "projects": {work: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True}}},
          open(path, "w"))
PY
# `claude-e2e` in the pane: the real binary with the temp HOME / config and the mock API.
cat > "$T/bin/claude-e2e" <<SH
#!/bin/sh
export HOME='$T/home' CLAUDE_CONFIG_DIR='$CFG' ANTHROPIC_API_KEY='$KEY' ANTHROPIC_BASE_URL='http://127.0.0.1:$PORT'
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 TMPDIR='$T/tmp'
exec '$CLAUDE_BIN' "\$@"
SH
chmod +x "$T/bin/claude-e2e"

python3 "$APP_DIR/scripts/claude-api-mock.py" "$PORT" "$T/api.log" >/dev/null 2>"$T/api.err" &
API_PID=$!

cleanup() {
  pkill -f "lmux-apptest --e2e" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f -- "$CLAUDE_BIN --model claude-e2e-mock" >/dev/null 2>&1 || break
    pkill -f -- "$CLAUDE_BIN --model claude-e2e-mock" 2>/dev/null || true
    sleep 0.5
  done
  kill "$API_PID" 2>/dev/null || true
  # Claude Code keeps per-project scratch under /private/tmp/claude-<uid>/<cwd as a name>: only this run's.
  TOKEN="$(basename "$T")"
  case "$TOKEN" in
    lmux-e2e.??????)
      for d in "/private/tmp/claude-$(id -u)"/*"${TOKEN//./-}"*; do
        [ -d "$d" ] && rm -rf "$d"
      done ;;
  esac
  rm -rf "$T"
}
trap cleanup EXIT

# Running this from inside a Claude Code session must not leak its child-session markers
# (they turn off transcript saving in the Claude we start).
for v in $(env | grep -o '^CLAUDE[A-Z_]*=' | tr -d '=' | grep -v '^CLAUDE_CONFIG_DIR$'); do unset "$v"; done
export TMPDIR="$T/tmp"
export LMUX_HEADLESS=1 LMUX_STATE_DIR="$T/state" LMUX_BIN_DIR="$T/bin"
export LMUX_FONTS_DIR="$APP_DIR/Resources/Fonts" LMUX_CLAUDE_PROJECTS="$CFG/projects"
export LMUX_E2E_CWD="$WORK" LMUX_E2E_API_LOG="$T/api.log" LMUX_E2E_CLAUDE_CMD="'$T/bin/claude-e2e'"
# Plain zsh (no rc files, so no history), from an isolated environment (temp ZDOTDIR / HISTFILE).
source "$APP_DIR/scripts/isolated-shell.sh"
lmux_isolated_shell "$T/shell"
if [ -d "$APP_DIR/build/lmux.app/Contents/Resources/ghostty" ]; then
  export GHOSTTY_RESOURCES_DIR="$APP_DIR/build/lmux.app/Contents/Resources/ghostty"
fi
MODE=--e2e
[ "${1:-}" = "--bench" ] && MODE=--e2e-bench
[ "${1:-}" = "--hover" ] && MODE=--e2e-hover
"$BIN/lmux-apptest" "$MODE" 2>/dev/null | grep -v '^\(info\|debug\|warning\)(' | tee "$T/out.txt"
exit "${PIPESTATUS[0]}"
