#!/bin/bash
# plain-text-preview 實作用的指令（給照 tasks.md 實作的 agent 用）。在 worktree 的任何位置執行：
#   beat/changes/plain-text-preview/dev.sh build                build 整個 App package，印出最後 40 行與結束碼
#   beat/changes/plain-text-preview/dev.sh errors 檔名...        build，只列出這些檔案（只寫檔名，例如 Agent.swift）的 error
#   beat/changes/plain-text-preview/dev.sh check                編譯並執行 App/scripts/preview-check.swift
#   beat/changes/plain-text-preview/dev.sh webkit               編譯並執行 App/scripts/preview-webkit-check.swift
#   beat/changes/plain-text-preview/dev.sh apptest-preview      只跑 apptest 的 --preview
#   beat/changes/plain-text-preview/dev.sh apptest-quick        apptest --quick（主要那一輪，要幾分鐘）
#   beat/changes/plain-text-preview/dev.sh new-failures preview|quick   跟 Task 0 的基準比：多出來的 FAIL、不見的檢查
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
# 不讓測試送進使用者正在用的 lmux；避開 Homebrew 的 GNU libtool。
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/usr/bin:$PATH"
OUT="${TMPDIR:-/tmp}/plain-text-preview"
mkdir -p "$OUT"
S=App/Sources/LmuxUI

# 這些檔案裡已經存在的那幾個（前面的 task 還沒建立的檔案不編譯）。
existing() {
  local list=()
  for f in "$@"; do [ -f "$S/$f.swift" ] && list+=("$S/$f.swift"); done
  echo "${list[@]}"
}

case "${1:-}" in
  build)
    (cd App && swift build 2>&1) > "$OUT/build.log"; code=$?
    tail -40 "$OUT/build.log"; echo "BUILD EXIT: $code"; exit $code ;;
  errors)
    shift
    (cd App && swift build 2>&1) > "$OUT/build.log"; code=$?
    total=0
    for f in "$@"; do
      grep -E "/${f}:[0-9]+:[0-9]+: error:" "$OUT/build.log" | sort -u > "$OUT/errors-one.txt"
      n=$(wc -l < "$OUT/errors-one.txt" | tr -d ' ')
      cat "$OUT/errors-one.txt"
      echo "ERRORS IN $f: $n"; total=$((total + n))
    done
    echo "ALL ERRORS IN BUILD: $(grep -cE ': error:' "$OUT/build.log")"
    echo "BUILD EXIT: $code"
    echo "ERRORS TOTAL: $total" ;;
  check)
    # shellcheck disable=SC2046
    swiftc -parse-as-library -o "$OUT/preview-check" $(existing PreviewTarget MarkdownHTML) App/scripts/preview-check.swift \
      && "$OUT/preview-check" ;;
  webkit)
    # shellcheck disable=SC2046,SC2086
    swiftc -parse-as-library -o "$OUT/preview-webkit-check" \
      $(existing PreviewTarget MarkdownHTML PreviewScheme PreviewWatcher PreviewView PreviewViewNavigation) App/scripts/preview-webkit-check*.swift \
      && "$OUT/preview-webkit-check" ;;
  apptest-preview)
    App/scripts/apptest.sh --preview > "$OUT/preview.log" 2>&1; code=$?
    grep -E '^(PASS|FAIL|RESULT)' "$OUT/preview.log"; echo "APPTEST EXIT: $code"; exit $code ;;
  apptest-quick)
    App/scripts/apptest.sh --quick > "$OUT/quick.log" 2>&1; code=$?
    grep -E '^(FAIL|RESULT)' "$OUT/quick.log"; echo "RESULT LINES: $(grep -c '^RESULT' "$OUT/quick.log")"
    echo "APPTEST EXIT: $code"; exit $code ;;
  new-failures)
    mode="${2:-quick}"
    # 只比檢查項目的名稱（去掉「  -- 細節」），細節裡的暫存路徑每次都不同。
    names() { grep "^$1" "$2" 2>/dev/null | sed 's/  -- .*//; s/^[A-Z]*  //' | sort -u; }
    comm -13 <(names FAIL "$OUT/baseline-$mode.log") <(names FAIL "$OUT/$mode.log") > "$OUT/new-failures.txt"
    # 基準有、這次完全沒出現的檢查（某一段當掉了，就不會印 FAIL，只會少掉）。
    comm -23 <(names PASS "$OUT/baseline-$mode.log") <(cat <(names PASS "$OUT/$mode.log") <(names FAIL "$OUT/$mode.log") | sort -u) > "$OUT/missing-checks.txt"
    cat "$OUT/new-failures.txt"
    echo "NEW FAILURES: $(wc -l < "$OUT/new-failures.txt" | tr -d ' ')"
    head -20 "$OUT/missing-checks.txt"
    echo "MISSING CHECKS: $(wc -l < "$OUT/missing-checks.txt" | tr -d ' ')" ;;
  *)
    sed -n 2,10p "$0"; exit 2 ;;
esac
