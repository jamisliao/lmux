#!/bin/bash
# The REAL Codex CLI in headless lmux panes, against a local mock of the Responses API
# (codex-mock.py): no login, no API key, no network. CODEX_HOME, HOME and the work dir are temp
# dirs; panes run the isolated zsh. Needs `codex` on PATH (any version with hooks, 0.166+).
#
#   App/scripts/codexreal.sh [DIR]     DIR: where CODEX_HOME / HOME / work go (default: the run's temp dir)
#
# Runs three times (see CodexReal.swift): Codex as installed (its shared app-server daemon runs
# every session's hooks with the environment of the codex that started it), with the daemon off
# (`features.daemon_auto_start = false`, as a user may set it), and with a daemon started outside
# lmux already running.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
CODEX="$(command -v codex)" || { echo "codexreal.sh: codex not on PATH" >&2; exit 2; }
cd "$APP_DIR"
swift build --product lmux-apptest >/dev/null
(cd ../Core && swift build --product lmux-hook >/dev/null)
BIN="$(swift build --show-bin-path)"
T="$(mktemp -d /tmp/lmux-cxreal.XXXXXX)"   # short: Unix socket paths
B="$(mkdir -p "${1:-$T}" && cd "${1:-$T}" && pwd -P)/codexreal.$$"
mkdir -p "$T/bin" "$T/state" "$T/tmp" "$B/codex" "$B/home" "$B/work"
MOCK=""
# Codex leaves its app-server daemon behind: only the ones running from this run's CODEX_HOME.
kill_codex() {
  # Its daemon stopped the way Codex does it (a killed one leaves state that fails the next codex).
  [ -d "$B/codex/app-server-daemon" ] && env -i HOME="$B/home" CODEX_HOME="$B/codex" PATH="$PATH" "$CODEX" app-server daemon stop >/dev/null 2>&1
  pgrep -f "$B/codex/" | xargs kill 2>/dev/null || true
}
cleanup() {
  [ -n "$MOCK" ] && kill "$MOCK" 2>/dev/null
  kill_codex
  pkill -f "lmux-apptest --codex-real" 2>/dev/null || true
  rm -rf "$T" "$B"
}
trap cleanup EXIT
source "$APP_DIR/scripts/isolated-shell.sh"
HIST0="$(history_stamp)"
lmux_isolated_shell "$T/shell"
cat >> "$T/shell/zdot/.zshrc" <<RC
export HOME='$B/home' CODEX_HOME='$B/codex' MOCK_KEY=mock PATH='$(dirname "$CODEX")':\$PATH
RC
export TMPDIR="$T/tmp"
cp "$(cd ../Core && swift build --show-bin-path)/lmux-hook" "$T/bin/lmux-hook"
MOCK_PORT_FILE="$T/port" MOCK_LOG="$T/mock.log" python3 "$APP_DIR/scripts/codex-mock.py" &
MOCK=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
status=0
run_mode() {
  sleep 1; rm -rf "$T/state" "$B/codex" "$B/home" "$B/work" 2>/dev/null || { sleep 2; rm -rf "$B/codex"; }; mkdir -p "$T/state" "$B/codex" "$B/home" "$B/work"
  FEATURES=""; [ "$1" = nodaemon ] && FEATURES=$'[features]\ndaemon_auto_start = false'
  git init -q "$B/work"
  cat > "$B/codex/config.toml" <<TOML
model = "gpt-5-codex"
model_provider = "mock"
[model_providers.mock]
name = "mock"
base_url = "http://127.0.0.1:$(cat "$T/port")/v1"
wire_api = "responses"
env_key = "MOCK_KEY"
[projects."$(cd "$B/work" && pwd -P)"]
trust_level = "trusted"
$FEATURES
TOML
  # The user's own hook, which lmux's install keeps and its uninstall gives back byte for byte.
  printf '{\n  "hooks": {\n    "Stop": [\n      {\n        "hooks": [\n          {\n            "type": "command",\n            "command": "true"\n          }\n        ]\n      }\n    ]\n  }\n}\n' > "$B/codex/hooks.json"

  export LMUX_HEADLESS=1 LMUX_STATE_DIR="$T/state" LMUX_BIN_DIR="$T/bin"
  export LMUX_FONTS_DIR="$APP_DIR/Resources/Fonts"
  export CLAUDE_CONFIG_DIR="$T/claude" CODEX_HOME="$B/codex" LMUX_CODEX_HOME="$B/codex"
  export LMUX_CONFIG_FILE="$T/lmux-config" LMUX_CMUX_HOME="$T/no-cmux" LMUX_QA_CODEX_WORK="$B/work"
  export GHOSTTY_RESOURCES_DIR="$APP_DIR/../vendor/ghostty/zig-out/share/ghostty" LMUX_QA_CODEX_MODE="$1"
  if [ "$1" = outside ]; then
    env -i HOME="$B/home" CODEX_HOME="$B/codex" PATH="$PATH" MOCK_KEY=mock "$CODEX" app-server daemon start >/dev/null 2>&1
  fi
  filter() { grep -v '^\(info\|debug\|warning\)(' || true; }
  echo "INFO  [codex real] mode: $1"
  "$BIN/lmux-apptest" --codex-real 2>/dev/null | filter || status=1
  kill_codex
  "$BIN/lmux-apptest" --codex-real-restore 2>/dev/null | filter || status=1
  kill_codex
}
for m in ${LMUX_QA_CODEX_MODES:-daemon nodaemon outside}; do run_mode "$m"; done
now="$(history_stamp)"
if [ "$now" != "$HIST0" ]; then echo "FAIL  [hygiene] ~/.zsh_history changed"; status=1; fi
exit $status
