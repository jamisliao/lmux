#!/bin/bash
# Run the lmux IME checklist in-process and headless: no window is shown, no
# focus is taken, nothing appears in the Dock (prohibited activation policy,
# borderless off-screen windows). Exit code 0 = all checks passed.
#
#   App/scripts/imetest.sh                       simulated Korean 2-Set, Pinyin and Japanese IMEs (default)
#   App/scripts/imetest.sh --visible             + checks against the REAL Korean IME
#                                                (shows a window, takes focus and
#                                                temporarily switches the input source)
#   App/scripts/imetest.sh --visible --probe     print the real IME's call traces, then run every shortcut
#                                                (Shortcuts.swift) against it: about 3 minutes
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
cd "$APP_DIR"
swift build --product lmux-imetest >/dev/null
BIN="$(swift build --show-bin-path)/lmux-imetest"
# Everything the harness writes to the temp dir (sink scripts, pasted images) goes in one run dir.
export TMPDIR="$(mktemp -d /tmp/lmux-imetest-run.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT
# Its panes are byte sinks, never a shell; anything that does start one gets an isolated zsh.
source "$APP_DIR/scripts/isolated-shell.sh"
HIST0="$(history_stamp)"
lmux_isolated_shell "$TMPDIR/shell"
# Fonts are normally registered from lmux.app/Contents/Resources/Fonts.
export LMUX_FONTS_DIR="$APP_DIR/Resources/Fonts"
export LMUX_HEADLESS=1
# Theme files as bundled in lmux.app (Contents/Resources/ghostty/themes).
RES="$APP_DIR/build/test-resources/ghostty"
mkdir -p "$RES/themes" && cp "$APP_DIR/Resources/themes/"* "$RES/themes/"
export GHOSTTY_RESOURCES_DIR="$RES"
set +e
"$BIN" "$@" 2>/dev/null | grep -v '^\(info\|debug\|warning\)('
st=${PIPESTATUS[0]}
set -e
if ls -d "$TMPDIR"/lmux-imetest-* >/dev/null 2>&1; then
  echo "FAIL  [hygiene] the harness left its temp dir behind: $(ls -d "$TMPDIR"/lmux-imetest-*)"; st=1
else
  echo "PASS  [hygiene] the harness removed its temp dir"
fi
if [ "$(history_stamp)" != "$HIST0" ]; then echo "FAIL  [hygiene] ~/.zsh_history changed during the run"; st=1
else echo "PASS  [hygiene] ~/.zsh_history untouched"; fi
exit $st
