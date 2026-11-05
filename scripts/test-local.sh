#!/bin/bash
# The CI suite on this Mac, headless: nothing shows on screen and no input source changes.
#   scripts/test-local.sh           Core tests, bundle, apptest, imetest, idle and perf budgets, docs
#   scripts/test-local.sh --quick   Core tests, bundle, apptest --quick, imetest, docs
# Left out: the real-IME and real-window jobs, which need a visible window. Run those by hand
# (App/scripts/imetest.sh --visible) when nobody is using the Mac.
set -uo pipefail
cd "$(dirname "$0")/.."

quick=0
[ "${1:-}" = "--quick" ] && quick=1

# swift build needs a full Xcode (the Command Line Tools lack the SwiftUI macro plugin).
if [ -z "${DEVELOPER_DIR:-}" ] && xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
  xcode="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null | head -1)"
  [ -n "$xcode" ] && export DEVELOPER_DIR="$xcode/Contents/Developer"
fi

logs="${LOGS:-$(mktemp -d -t lmux-test-local)}"
mkdir -p "$logs"
echo "Logs: $logs${DEVELOPER_DIR:+ (DEVELOPER_DIR=$DEVELOPER_DIR)}"

failed=()
step() {
  local name="$1"; shift
  printf '%-28s' "$name"
  local start=$SECONDS
  if "$@" > "$logs/$name.log" 2>&1; then
    echo "PASS  $((SECONDS - start))s"
  else
    echo "FAIL  $((SECONDS - start))s  ($logs/$name.log)"
    failed+=("$name")
  fi
}

# apptest.sh, imetest.sh, measure_idle.sh and perf_budget.py go headless on their own, each with a
# private LMUX_STATE_DIR. Don't export LMUX_HEADLESS here: lmux refuses it without a state dir.
step core       bash -c 'cd Core && swift test'
step bundle     App/scripts/bundle.sh
if [ -d App/build/lmux.app ]; then
  if [ $quick = 1 ]; then step apptest App/scripts/apptest.sh --quick
  else step apptest App/scripts/apptest.sh; fi
  step imetest    App/scripts/imetest.sh
  if [ $quick = 0 ]; then
    step idle-1     App/scripts/measure_idle.sh 20 1
    step idle-10    App/scripts/measure_idle.sh 20 10 2
    step perf       python3 App/scripts/perf_budget.py
  fi
fi
[ -f scripts/build-docs.py ] && step docs python3 scripts/build-docs.py --check

if [ ${#failed[@]} -gt 0 ]; then
  echo "FAILED: ${failed[*]}"
  exit 1
fi
echo "All passed."
