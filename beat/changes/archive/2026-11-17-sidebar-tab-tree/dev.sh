#!/bin/bash
# sidebar-tab-tree 實作用的指令（給照 tasks.md 實作的 agent 用）。在 worktree 的任何位置執行：
#   beat/changes/sidebar-tab-tree/dev.sh build               build 整個 App package，印出最後 40 行與結束碼
#   beat/changes/sidebar-tab-tree/dev.sh errors 檔名...       build，只列出這些檔案（只寫檔名，例如 Sidebar.swift）的 error
#   beat/changes/sidebar-tab-tree/dev.sh tabs                只跑 apptest.sh --sidebar-tabs
#   beat/changes/sidebar-tab-tree/dev.sh shots               同上，並把 sidebar 的截圖存成 PNG
#   beat/changes/sidebar-tab-tree/dev.sh apptest-quick       apptest --quick（約 10 分鐘）
#   beat/changes/sidebar-tab-tree/dev.sh apptest-full        apptest 全部（CI 跑的那一套）
#   beat/changes/sidebar-tab-tree/dev.sh baseline            quick 與 full 各跑一次，存成基準
#   beat/changes/sidebar-tab-tree/dev.sh new-failures quick|full   跟基準比：多出來的 FAIL、不見的檢查
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
# 不讓測試送進使用者正在用的 lmux。
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
# /usr/bin 在前：避開 Homebrew 的 GNU libtool。
# lmux-dev/bin 更前：它的 swift 包裝腳本改用 native build system，binary 的 SDK 標記才不會是 14.0
# （14.0 時 sidebar 的 ⌘-拖曳檢查會失敗）。這個目錄不存在時沒有作用。
export PATH="$HOME/.local/share/lmux-dev/bin:/usr/bin:$PATH"
OUT="${TMPDIR:-/tmp}/sidebar-tab-tree"
mkdir -p "$OUT"

# run_apptest 名稱 [apptest.sh 的參數]：log 存成 $OUT/名稱.log。
run_apptest() {
  local name="$1"; shift
  App/scripts/apptest.sh "$@" > "$OUT/$name.log" 2>&1; local code=$?
  grep -E '^(FAIL|RESULT)' "$OUT/$name.log"
  echo "RESULT LINES ($name): $(grep -c '^RESULT' "$OUT/$name.log")"
  echo "APPTEST EXIT ($name): $code"
  return $code
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
  tabs)
    App/scripts/apptest.sh --sidebar-tabs > "$OUT/tabs.log" 2>&1; code=$?
    grep -E '^(PASS|FAIL|RESULT)' "$OUT/tabs.log"; echo "TABS EXIT: $code"; exit $code ;;
  shots)
    rm -rf "$OUT/shots"; mkdir -p "$OUT/shots"
    LMUX_TABTREE_SHOTS="$OUT/shots" App/scripts/apptest.sh --sidebar-tabs > "$OUT/shots.log" 2>&1; code=$?
    ls "$OUT/shots"/*.png 2>/dev/null; echo "SHOTS: $(ls "$OUT/shots" | wc -l | tr -d ' ')"; exit $code ;;
  apptest-quick) run_apptest quick --quick; exit $? ;;
  apptest-full)  run_apptest full; exit $? ;;
  baseline)      run_apptest baseline-quick --quick; run_apptest baseline-full ;;
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
