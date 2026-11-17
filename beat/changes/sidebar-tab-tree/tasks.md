# 在 sidebar 展開 workspace 的 tab — 實作計畫

> **給執行的 agent：** 照順序一次做一個 task。每個 step 做完，把 `- [ ]` 改成 `- [x]`。

**Goal:** workspace 有 2 個以上的 tab 時，sidebar 的 workspace 列出現展開箭頭；展開後每個 tab 一列 Tab 子列，可以點它切換、關閉。

**Architecture:** 展開狀態存在 `Workspace.tabsExpanded`，寫進 `layout.json` 的選填欄位。Tab 子列要顯示的內容先算成 `SidebarTabItem`（純資料），view 只畫它，測試直接檢查它。切換沿用 `focus(_:)`，關閉沿用 `requestClosePane(_:)`。新程式碼集中在新檔 `App/Sources/LmuxUI/SidebarTabs.swift`，`Sidebar.swift` 只加兩處。

**Tech Stack:** Swift、SwiftPM、SwiftUI、AppKit。沒有第三方依賴。

**規格來源：** `beat/changes/sidebar-tab-tree/` 的 `proposal.md`、`design.md`、`features/sidebar-tab-tree.feature`。用詞依 `GLOSSARY.md`。

**plan 階段的驗證：** 這份計畫的程式碼**全部沒有編譯過**（plan 階段沒有執行 `swift build` 與 apptest 的權限）。行號是 2026-11-17 在 commit `509118e` 查的。寫明「未查證」的地方，執行時依該步驟的指示先查。

**與 design.md 的差異：**
- 新程式碼放在新檔 `App/Sources/LmuxUI/SidebarTabs.swift`，不放進 `Controller.swift` 與 `Sidebar.swift`（這兩個檔已經 1556 行與 562 行）。
- 多一個 controller 方法 `closeTabFromSidebar(_:)`（design 寫「唯一新增的是 toggle」）：把「有程式在跑先切過去，再詢問」包成一個可以測的入口。
- `AppModel` 多一個 `hoveredTabRowID`，作法比照既有的 `hoveredRowID`，測試才能指定滑鼠在哪一列。
- 測試放在新檔 `App/Sources/lmux-apptest/SidebarTabs.swift` 與新模式 `--sidebar-tabs`，不加進 `Sidebar.swift`（已 360 行）。
- 點 Tab 子列走新的 `clickTabRow(_:)`：先結束 sidebar 的多選，再 `focus`。design 的邊緣情況表寫「多選結束」，但 `focus` 只在換 workspace 時才結束多選（`Controller.swift:735-739`）。點選取中 workspace 的 Tab 子列時多選會留著，下一次按 × 會關掉所有選取的 workspace。
- 展開與收合的動畫由 `toggleTabsExpanded` 用 `withAnimation` 帶動，不在 `SidebarView` 的 body 掛 `.animation`。掛在 body 會讓整個清單在任何 workspace 的 tab 數改變時重畫；`Sidebar.swift:30-34` 刻意避免這件事。
- Tab 子列的狀態圖示多傳 `waiting`：等使用額度重設時顯示時鐘，與 workspace 列一致。
- `closeTabFromSidebar` 自己先擋釘選的 tab。`requestClosePane` 只在那一格有 tab 列時才擋（`MessageActions.swift:815`）。

**review 發現的 design 問題（展開箭頭的位置）：** design 寫「列左邊有 16pt 留白」。實際上列的底色從 x=8 開始、圓角 8pt（`Sidebar.swift:330`、`Tokens.swift:279`），底色外面只有 8pt。14pt 的箭頭範圍落在 x 1…15，會壓在底色的左緣上；它也比 × 的 20pt 點擊範圍小。所以 Task 8 做出箭頭後先截圖，**停下來請使用者決定**，才繼續。使用者決定改成「所有列的內容右移」時，Task 8 之後要重新規劃：那要改 `WorkspaceRowContent`、`HooksSetup.swift:357`、`lmux-apptest/Sidebar.swift:151`，這份計畫沒有涵蓋。Task 0–7 不依賴箭頭的位置。

## Global Constraints

- 只在 worktree `/Users/jamis.liao/opensource/lmux/.worktrees/feat/sidebar-tab-tree` 裡工作。不要 `cd` 到 `/Users/jamis.liao/opensource/lmux`（那是 main）。
- 不新增任何第三方依賴。只用 Apple 的框架。
- 只改每個 task 的「Files」列出的檔案。看到其他想改的地方，記下來，最後回報，不要改。
- 新程式碼的註解用繁體中文。介面上的英文字串（`"Show Tabs"` 這類）維持英文，與既有介面一致。
- build、測試一律用 `beat/changes/sidebar-tab-tree/dev.sh`（Task 0 建立）。它會先 `unset LMUX_*`：這個 session 跑在使用者正在用的 lmux 裡，不 unset 的話，測試會送進使用者的 lmux。
- **指令被權限擋下時**（`Permission denied`）：不要換寫法繞過。停下來，請使用者用 `! beat/changes/sidebar-tab-tree/dev.sh <指令>` 自己跑，再讀 `${TMPDIR:-/tmp}/sidebar-tab-tree/` 底下的 log。
- 每個 task 結束都要 commit。commit message 用繁體中文，結尾加執行者自己的 `Co-Authored-By` 行。
- 不可以 `git push`。不可以 `git commit --no-verify`。
- 不可以為了讓測試通過而修改測試的預期值。
- **停止規則：** 驗證的結果跟「預期」不同時，最多修兩次。兩次後還是不同，就停下來，回報：task 編號、跑的指令、完整輸出。不要自己換做法。
  - 寫著「確認失敗」的步驟：結果跟預期不同（例如沒有失敗），就停下來回報。不要為了讓它失敗去改程式。
- **程式碼沒編譯過：** 編譯錯誤若是拼字、型別標註、`await`／`@MainActor` 這類，直接修，並在回報時列出改了什麼。若是「計畫用到的既有函式不存在或簽名不同」，停下來回報。
- **跑很久的指令：** `apptest-quick` 約 10 分鐘。工具有逾時限制時改成背景執行：
  `nohup beat/changes/sidebar-tab-tree/dev.sh apptest-quick > "${TMPDIR:-/tmp}/sidebar-tab-tree/run.out" 2>&1 &`，之後每 60 秒 `tail -3` 那個檔，看到 `APPTEST EXIT` 才算跑完。

## Quality Principles

**Testing:** Tests verify behavior (return values, state changes, responses), not wiring.
If the main assertion is `toHaveBeenCalledWith`, rewrite to assert on the function's output.

**Code:** No single new file exceeds ~300 lines. If it grows past that, split into focused sub-modules.

## 共用指令（`dev.sh`，Task 0 建立）

| 指令 | 做什麼 | 成功時最後一行 |
|---|---|---|
| `beat/changes/sidebar-tab-tree/dev.sh build` | build 整個 App package | `BUILD EXIT: 0` |
| `beat/changes/sidebar-tab-tree/dev.sh errors A.swift B.swift` | build，只列出這些檔案的 error | `ERRORS TOTAL: 0` |
| `beat/changes/sidebar-tab-tree/dev.sh tabs` | 只跑 `apptest.sh --sidebar-tabs`（Task 1 之後才有） | `TABS EXIT: 0` |
| `beat/changes/sidebar-tab-tree/dev.sh apptest-quick` | apptest 主要那一輪（約 10 分鐘） | 看 `new-failures quick` |
| `beat/changes/sidebar-tab-tree/dev.sh apptest-full` | apptest 全部（CI 跑的那一套，比 quick 久） | 看 `new-failures full` |
| `beat/changes/sidebar-tab-tree/dev.sh baseline` | quick 與 full 各跑一次，存成基準 | 兩行 `APPTEST EXIT` |
| `beat/changes/sidebar-tab-tree/dev.sh new-failures quick` 或 `full` | 跟 Task 0 的基準比：多出來的 FAIL、不見的檢查 | `NEW FAILURES: 0` 與 `MISSING CHECKS: 0` |
| `beat/changes/sidebar-tab-tree/dev.sh shots` | 跑 `--sidebar-tabs`，把 sidebar 的截圖存成 PNG（Task 8 之後才有圖） | 列出 PNG 的路徑 |

## 檔案一覽

| 檔案 | 新增／修改 | 負責 | Task |
|---|---|---|---|
| `beat/changes/sidebar-tab-tree/dev.sh` | 新增 | 實作用的指令 | 0 |
| `App/scripts/apptest.sh` | 修改 | `--sidebar-tabs` 模式與主流程呼叫 | 1 |
| `App/Sources/lmux-apptest/main.swift` | 修改 | 兩個新模式的分派 | 1 |
| `App/Sources/lmux-apptest/SidebarTabs.swift` | 新增 | 本 feature 的全部檢查 | 1–4、6–9 |
| `App/Sources/LmuxUI/Model.swift` | 修改 | `Workspace.tabsExpanded` 等 3 個屬性（2）；`AppModel.hoveredTabRowID`（9） | 2、9 |
| `App/Sources/LmuxUI/SidebarTabs.swift` | 新增 | controller 方法、`SidebarTabItem`、Tab 子列與展開箭頭的 view | 2、4、6、8、9 |
| `App/Sources/LmuxUI/Persistence.swift` | 修改 | `tabsExpanded` 的存與讀 | 3 |
| `App/Sources/LmuxTokens/Tokens.swift` | 修改 | 3 個尺寸 | 5 |
| `App/Sources/lmux-apptest/Tests.swift` | 修改 | `rowPoint` 算入 Tab 子列的高度 | 5 |
| `App/Sources/LmuxUI/Sidebar.swift` | 修改 | 每組加 Tab 子列（6）；workspace 列加展開箭頭（8） | 6、8 |
| `beat/changes/sidebar-tab-tree/features/sidebar-tab-tree.feature` | 修改 | `@covered-by` | 10 |
| `docs/features.md` | 修改 | 說明可以展開 tab | 10 |

## 場景對照

| 場景（`sidebar-tab-tree.feature`） | Task |
|---|---|
| 有多個 tab 的 workspace 可以展開與收合 | 8 |
| 只有 1 個 tab 的 workspace 沒有展開箭頭 | 2、8 |
| 開出第 2 個 tab 時預設收合 | 2 |
| 點展開箭頭不切換 workspace | 8 |
| 重開 lmux 後維持展開狀態 | 3 |
| tab 數回到 2 個以上時回到原本的展開狀態 | 2 |
| 分割出來的 tab 也列在同一層 | 4 |
| Tab 子列顯示 tab 的類型與標題 | 4（內容）、6（畫面） |
| Tab 子列顯示該 tab 自己的 agent 狀態（3 個例子） | 4（內容）、6（畫面）、8（轉圈） |
| 預覽 tab 的 Tab 子列沒有狀態圖示 | 4（內容）、6（畫面） |
| 展開時 workspace 列照常顯示整體狀態 | 8 |
| 點 Tab 子列切換到另一個 workspace 的 tab | 6 |
| 只有 focused tab 的 Tab 子列有標示 | 4（內容）、6（畫面） |
| 從 Tab 子列關閉 tab | 9 |
| 釘選的 tab 的 Tab 子列沒有關閉按鈕 | 9 |
| 關閉還有程式在跑的終端機 tab 會先詢問 | 9 |
| 拖曳已展開的 workspace 時 Tab 子列跟著移動 | 7 |
| 拖 Tab 子列不會移動 workspace | 7 |

design「邊緣情況」表的對照：放大某一格時點 Tab 子列（6）、多選時點 Tab 子列（6）、1 個終端機 tab 加 1 個預覽 tab 重開（3）、舊版 `layout.json`（3）、關到剩 1 個 tab（2、9）。

---

### Task 0: `dev.sh` 與基準

**Files:**
- Create: `beat/changes/sidebar-tab-tree/dev.sh`

**Interfaces:**
- Produces: 上面「共用指令」表的指令；基準 log `${TMPDIR:-/tmp}/sidebar-tab-tree/baseline-quick.log` 與 `baseline-full.log`。

- [ ] **Step 1: 確認 worktree 有 Ghostty**

Run: `ls -d vendor/ghostty/macos/GhosttyKit.xcframework`
Expected: 印出這個路徑。印出 `No such file` 就停下來回報（`vendor` 應該是指到主 checkout 的 symlink）。

- [ ] **Step 2: 建立 `beat/changes/sidebar-tab-tree/dev.sh`**

```bash
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
```

Run: `chmod +x beat/changes/sidebar-tab-tree/dev.sh`

- [ ] **Step 3: 確認 build 通過**

Run: `beat/changes/sidebar-tab-tree/dev.sh build`
Expected: 最後一行 `BUILD EXIT: 0`。

- [ ] **Step 4: 存基準**

Run: `beat/changes/sidebar-tab-tree/dev.sh baseline`（quick 約 10 分鐘，full 更久；逾時就照 Global Constraints 用背景執行，指令換成 `baseline`，看到 `APPTEST EXIT (baseline-full)` 才算跑完）
Expected: `APPTEST EXIT (baseline-quick): 0` 與 `APPTEST EXIT (baseline-full): 0`，沒有 `FAIL` 行。
（2026-11-17 在同樣的程式碼上，quick 是 1696 PASS、0 FAIL；full 那次沒跑過。有 FAIL 也繼續：之後只看 `new-failures`。回報時列出基準的 FAIL。）

- [ ] **Step 5: Commit**

```bash
git add beat/changes/sidebar-tab-tree/dev.sh
git commit -m "chore(sidebar-tab-tree): 新增實作用的 dev.sh"
```

---

### Task 1: 測試模式 `--sidebar-tabs` 的骨架

**Files:**
- Create: `App/Sources/lmux-apptest/SidebarTabs.swift`
- Modify: `App/Sources/lmux-apptest/main.swift:137`
- Modify: `App/scripts/apptest.sh`（`run_preview_suite` 之後、`--sidebar` 那一行之後）

**Interfaces:**
- Produces:
  - `func runSidebarTabs() async -> Int32`、`func runSidebarTabsRestore() async -> Int32`
  - `func stageTabWorkspaces(_ c: LmuxController, _ spec: [(title: String, tabs: Int)]) async -> [Workspace]`
  - `App/scripts/apptest.sh --sidebar-tabs`

- [ ] **Step 1: 建立 `App/Sources/lmux-apptest/SidebarTabs.swift`**

```swift
import AppKit
import LmuxTokens
import SwiftUI
@testable import LmuxUI

// `lmux-apptest --sidebar-tabs`／`--sidebar-tabs-restore`：在 sidebar 展開 workspace 的 tab
// （beat: sidebar-tab-tree.feature）。pane 跑隔離的 zsh，headless。

/// 開出 spec 列的 workspace（閒置的 shell），每個共有 tabs 個終端機 tab（都在同一格）。
/// 原有的 workspace 全部關掉；第 1 個是選取中的 workspace。
@MainActor
func stageTabWorkspaces(_ c: LmuxController, _ spec: [(title: String, tabs: Int)]) async -> [Workspace] {
    let old = c.model.workspaces
    var made: [Workspace] = []
    for s in spec {
        let ws = c.newWorkspace(cwd: "/tmp", select: false)
        ws.customTitle = s.title
        for _ in 1..<max(1, s.tabs) { _ = c.newTab(ws.panes[0], select: false) }
        made.append(ws)
    }
    for o in old { c.closeWorkspace(o) }
    c.model.workspaces = made
    c.select(made[0])
    c.model.selection = []
    c.model.hoveredRowID = nil
    _ = await waitFor(10) {
        made.flatMap(\.panes).allSatisfy { $0.surface!.foregroundPID > 0 && c.runningProcess($0) == nil }
    }
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    await sleepMs(200)
    return made
}

@MainActor
func runSidebarTabs() async -> Int32 {
    let r = Report()
    let c = makeController()

    // ------------------------------------------------------------- 佈置
    r.section = "tab tree: setup"
    let staged = await stageTabWorkspaces(c, [("A", 3), ("B", 1)])
    r.check("佈置：A 有 3 個 tab、B 有 1 個，A 是選取中的 workspace",
            staged[0].panes.count == 3 && staged[1].panes.count == 1 && c.model.selected === staged[0],
            "\(staged.map { $0.panes.count })")

    return finish(r, c)
}

@MainActor
func runSidebarTabsRestore() async -> Int32 {
    let r = Report()
    r.section = "tab tree: relaunch"
    let c = makeController()
    r.check("重開：有 workspace 讀回來", !c.model.workspaces.isEmpty)
    return finish(r, c)
}
```

- [ ] **Step 2: 在 `main.swift` 加分派**

在 `} else if args.contains("--sidebar") {` 這一行**之前**插入（放前面，讀的人才不會誤以為 `--sidebar` 會吃掉它）：

```swift
            } else if args.contains("--sidebar-tabs-restore") {
                code = await runSidebarTabsRestore()
            } else if args.contains("--sidebar-tabs") {
                code = await runSidebarTabs()
```

同一個檔案最上面的模式清單註解，在 `--sidebar` 那一行下面加一行：

```swift
//   lmux-apptest --sidebar-tabs  sidebar 展開 workspace 的 tab（接著跑 --sidebar-tabs-restore）
```

- [ ] **Step 3: 在 `apptest.sh` 加模式**

在這 4 行之後：

```bash
if [ "${1:-}" = "--preview" ]; then
  run_preview_suite
  exit $status
fi
```

插入：

```bash
# Sidebar tab tree (beat: sidebar-tab-tree.feature): expand a workspace's tabs, then the relaunch.
run_sidebar_tabs_suite() {
  mkdir -p "$T/sidebar-tabs"
  for phase in --sidebar-tabs --sidebar-tabs-restore; do
    LMUX_STATE_DIR="$T/sidebar-tabs" LMUX_IGNORE_GHOSTTY_CONFIG=1 "$BIN/lmux-apptest" $phase 2>/dev/null | filter || status=1
  done
}
if [ "${1:-}" = "--sidebar-tabs" ]; then
  run_sidebar_tabs_suite
  exit $status
fi
```

在這一行之後：

```bash
LMUX_STATE_DIR="$T/sidebar" "$BIN/lmux-apptest" --sidebar 2>/dev/null | filter || status=1
```

插入一行：

```bash
run_sidebar_tabs_suite
```

檔案開頭的用法註解，在 `--preview` 那一行下面加一行：

```bash
#   App/scripts/apptest.sh --sidebar-tabs   only the sidebar tab tree suite (--sidebar-tabs, --sidebar-tabs-restore)
```

- [ ] **Step 4: 確認新模式會跑**

Run: `beat/changes/sidebar-tab-tree/dev.sh tabs`
Expected: 2 行 `PASS`（`佈置`、`重開`）、2 行 `RESULT: PASS`、`TABS EXIT: 0`。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/lmux-apptest/SidebarTabs.swift App/Sources/lmux-apptest/main.swift App/scripts/apptest.sh
git commit -m "test(sidebar-tab-tree): 新增 --sidebar-tabs 測試模式的骨架"
```

---

### Task 2: 展開狀態與切換

**Files:**
- Modify: `App/Sources/LmuxUI/Model.swift:487`（`Workspace` 的 `focusedPane` 之後）
- Create: `App/Sources/LmuxUI/SidebarTabs.swift`
- Test: `App/Sources/lmux-apptest/SidebarTabs.swift`

**Interfaces:**
- Produces:
  - `Workspace.tabsExpanded: Bool`（可讀寫，預設 `false`）
  - `Workspace.showsTabDisclosure: Bool`（`panes.count >= 2`）
  - `Workspace.showsTabChildren: Bool`（`tabsExpanded && showsTabDisclosure`）
  - `LmuxController.toggleTabsExpanded(_ ws: Workspace)`

- [ ] **Step 1: 寫檢查**

在 `runSidebarTabs()` 的 `return finish(r, c)` **之前**加：

```swift
    // ------------------------------------------------------------- 展開狀態
    // @feature: sidebar-tab-tree.feature
    // @scenario: 只有 1 個 tab 的 workspace 沒有展開箭頭
    // @scenario: 開出第 2 個 tab 時預設收合
    // @scenario: tab 數回到 2 個以上時回到原本的展開狀態
    r.section = "tab tree: state"
    var ws = await stageTabWorkspaces(c, [("A", 1)])
    let a = ws[0]
    r.check("只有 1 個 tab：沒有展開箭頭，也沒有 Tab 子列", !a.showsTabDisclosure && !a.showsTabChildren)
    c.toggleTabsExpanded(a)
    r.check("…展開狀態設成展開，仍然沒有 Tab 子列", a.tabsExpanded && !a.showsTabChildren)
    c.toggleTabsExpanded(a)

    let second = c.newTab(a.panes[0], select: false)!
    r.check("開出第 2 個 tab：有展開箭頭，預設收合", a.showsTabDisclosure && !a.tabsExpanded && !a.showsTabChildren)
    c.toggleTabsExpanded(a)
    r.check("切換一次：展開", a.showsTabChildren)
    c.toggleTabsExpanded(a)
    r.check("再切換一次：收合", !a.showsTabChildren)

    c.toggleTabsExpanded(a)
    c.closePane(second)
    r.check("展開後關到剩 1 個 tab：展開箭頭與 Tab 子列都消失", !a.showsTabDisclosure && !a.showsTabChildren)
    _ = c.newTab(a.panes[0], select: false)
    r.check("…再開 1 個 tab：回到展開", a.showsTabDisclosure && a.showsTabChildren && a.panes.count == 2)
```

- [ ] **Step 2: 確認失敗**

Run: `beat/changes/sidebar-tab-tree/dev.sh errors SidebarTabs.swift`
Expected: `ERRORS TOTAL` 大於 0，錯誤訊息提到 `showsTabDisclosure`、`showsTabChildren`、`tabsExpanded` 或 `toggleTabsExpanded` 不存在。

- [ ] **Step 3: 在 `Model.swift` 的 `Workspace` 加屬性**

在 `public var focusedPane: Pane?` 這一行之後加：

```swift
    /// sidebar 是否展開這個 workspace 的 Tab 子列（beat: sidebar-tab-tree.feature）。存進 layout.json。
    /// 只剩 1 個 tab 時不顯示 Tab 子列，但這個值不變，所以 tab 數回到 2 個以上會回到原本的狀態。
    public var tabsExpanded = false
    /// 有 2 個以上的 tab 才有展開箭頭。
    public var showsTabDisclosure: Bool { panes.count >= 2 }
    /// sidebar 現在要不要畫這個 workspace 的 Tab 子列。
    public var showsTabChildren: Bool { tabsExpanded && showsTabDisclosure }
```

- [ ] **Step 4: 建立 `App/Sources/LmuxUI/SidebarTabs.swift`**

```swift
import AppKit
import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

// 在 sidebar 展開 workspace 的 tab（beat: sidebar-tab-tree.feature）：展開狀態的切換、
// Tab 子列要顯示的內容，以及畫它們的 view。

extension LmuxController {
    /// 點展開箭頭：展開或收合這個 workspace 的 Tab 子列，並存檔。不切換 workspace。
    /// 動畫由這裡帶動（下面的 workspace 列跟著滑動）；系統開「減少動態效果」時不做動畫。
    public func toggleTabsExpanded(_ ws: Workspace) {
        withAnimation(T.Motion.reduceMotion ? nil : .easeOut(duration: T.Motion.historyExpand)) {
            ws.tabsExpanded.toggle()
        }
        scheduleSave()
    }
}
```

- [ ] **Step 5: 確認通過**

Run: `beat/changes/sidebar-tab-tree/dev.sh tabs`
Expected: `[tab tree: state]` 沒有 `FAIL` 行，`TABS EXIT: 0`。

- [ ] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/Model.swift App/Sources/LmuxUI/SidebarTabs.swift App/Sources/lmux-apptest/SidebarTabs.swift
git commit -m "feat(sidebar-tab-tree): workspace 記錄 Tab 子列的展開狀態"
```

---

### Task 3: 展開狀態存進 `layout.json`

**Files:**
- Modify: `App/Sources/LmuxUI/Persistence.swift:29-51`（`WorkspaceState`）、`:162-163`（`snapshotLayout`）、`:256`（`restoreLayout`）
- Test: `App/Sources/lmux-apptest/SidebarTabs.swift`

**Interfaces:**
- Consumes: `Workspace.tabsExpanded`（Task 2）
- Produces: `LayoutFile.WorkspaceState.tabsExpanded: Bool?`（展開時 `true`，收合時 `nil`）

- [ ] **Step 1: 寫檢查（存）**

在 `runSidebarTabs()` 的 `return finish(r, c)` **之前**加。這一段要留在函式的最後面：它佈置的 workspace 是 `--sidebar-tabs-restore` 要讀的。之後的 task 都把新檢查加在這一段**之前**。

```swift
    // ------------------------------------------------------------- 存檔（這一段留在最後）
    // @feature: sidebar-tab-tree.feature
    // @scenario: 重開 lmux 後維持展開狀態
    r.section = "tab tree: save"
    let saved = await stageTabWorkspaces(c, [("A", 2), ("B", 2)])
    c.toggleTabsExpanded(saved[0])
    // 1 個終端機 tab 加 1 個預覽 tab：預覽 tab 不存，重開後只剩 1 個 tab，但展開狀態要留著。
    let mixed = c.newWorkspace(cwd: "/tmp", select: false)
    mixed.customTitle = "P"
    let note = paths.stateDir.appendingPathComponent("note.md")
    try? "# note\n".write(to: note, atomically: true, encoding: .utf8)
    _ = c.newPreviewTab(note, after: mixed.panes[0])
    c.toggleTabsExpanded(mixed)
    c.select(saved[0])
    let layout = c.snapshotLayout()
    let sa = layout.workspaces.first { $0.id == saved[0].id }
    let sb = layout.workspaces.first { $0.id == saved[1].id }
    let sp = layout.workspaces.first { $0.id == mixed.id }
    r.check("存檔：展開的 A 存 true，收合的 B 不存這個欄位", sa?.tabsExpanded == true && sb != nil && sb?.tabsExpanded == nil,
            "\(String(describing: sa?.tabsExpanded)) \(String(describing: sb?.tabsExpanded))")
    r.check("…有預覽 tab 的 P 展開時也存 true", mixed.showsTabChildren && sp?.tabsExpanded == true)
    let old = #"{"id":"w","accent":0,"root":{"pane":{"id":"p"}}}"#
    let decoded = try? JSONDecoder().decode(LayoutFile.WorkspaceState.self, from: Data(old.utf8))
    r.check("沒有這個欄位的舊檔讀得進來，視為收合", decoded != nil && decoded?.tabsExpanded == nil)
    let future = #"{"id":"w","accent":0,"someFutureKey":1,"root":{"pane":{"id":"p"}}}"#
    r.check("多了不認得的欄位也讀得進來（舊版 lmux 讀新檔的情況）",
            (try? JSONDecoder().decode(LayoutFile.WorkspaceState.self, from: Data(future.utf8))) != nil)
    c.saveNow()
    try? JSONSerialization.data(withJSONObject: ["a": saved[0].id, "b": saved[1].id, "p": mixed.id])
        .write(to: paths.stateDir.appendingPathComponent("sidebar-tabs-expect.json"))
```

- [ ] **Step 2: 寫檢查（讀）**

把 `runSidebarTabsRestore()` 整個換成：

```swift
@MainActor
func runSidebarTabsRestore() async -> Int32 {
    let r = Report()
    r.section = "tab tree: relaunch"
    guard let d = try? Data(contentsOf: paths.stateDir.appendingPathComponent("sidebar-tabs-expect.json")),
          let e = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
        print("FAIL  [tab tree: relaunch] no expectations from --sidebar-tabs"); return 1
    }
    let c = makeController()
    let a = c.model.workspaces.first { $0.id == e["a"] }
    let b = c.model.workspaces.first { $0.id == e["b"] }
    r.check("重開：A 與 B 都讀回來，各有 2 個 tab", a?.panes.count == 2 && b?.panes.count == 2,
            "\(String(describing: a?.panes.count)) \(String(describing: b?.panes.count))")
    r.check("…A 仍然展開", a?.showsTabChildren == true)
    r.check("…B 仍然收合", b?.tabsExpanded == false && b?.showsTabChildren == false)
    if let p = c.model.workspaces.first(where: { $0.id == e["p"] }) {
        r.check("…P 的預覽 tab 沒讀回來，剩 1 個 tab：沒有 Tab 子列，但展開狀態還在",
                p.panes.count == 1 && p.tabsExpanded && !p.showsTabChildren, "\(p.panes.count) \(p.tabsExpanded)")
        _ = c.newTab(p.panes[0], select: false)
        r.check("…P 再開 1 個 tab：直接是展開的", p.showsTabChildren)
    } else {
        r.check("…P 讀回來了", false)
    }
    return finish(r, c)
}
```

- [ ] **Step 3: 確認失敗**

Run: `beat/changes/sidebar-tab-tree/dev.sh errors SidebarTabs.swift`
Expected: `ERRORS TOTAL` 大於 0，錯誤訊息提到 `WorkspaceState` 沒有 `tabsExpanded`。

- [ ] **Step 4: 改 `WorkspaceState`（`Persistence.swift:29-51`）**

在 `public var zoomedPane: String?` 之後加：

```swift
        /// sidebar 展開了這個 workspace 的 Tab 子列（beat: sidebar-tab-tree.feature）。收合時不存；舊檔沒有這個欄位。
        public var tabsExpanded: Bool?
```

把 memberwise `init` 換成（多一個有預設值的參數，`CmuxImport.swift:520` 的呼叫不用改）：

```swift
        public init(id: String, customTitle: String?, accent: Int, focusedPane: String?, zoomedPane: String? = nil,
                    tabsExpanded: Bool? = nil, root: NodeState) {
            self.id = id; self.customTitle = customTitle; self.accent = accent; self.focusedPane = focusedPane
            self.zoomedPane = zoomedPane; self.tabsExpanded = tabsExpanded; self.root = root
        }
```

在 `init(from:)` 裡，`zoomedPane = try c.decodeIfPresent(...)` 那一行之後加：

```swift
            tabsExpanded = try c.decodeIfPresent(Bool.self, forKey: .tabsExpanded)
```

- [ ] **Step 5: 存與讀**

`snapshotLayout()`（`:162-163`）把：

```swift
            return .init(id: ws.id, customTitle: ws.customTitle, accent: ws.accent,
                         focusedPane: focused, zoomedPane: zoomed, root: root)
```

換成：

```swift
            return .init(id: ws.id, customTitle: ws.customTitle, accent: ws.accent,
                         focusedPane: focused, zoomedPane: zoomed,
                         tabsExpanded: ws.tabsExpanded ? true : nil, root: root)
```

`restoreLayout()`（`:256`）在 `ws.customTitle = w.customTitle` 之後加：

```swift
            ws.tabsExpanded = w.tabsExpanded ?? false
```

- [ ] **Step 6: 確認通過**

Run: `beat/changes/sidebar-tab-tree/dev.sh tabs`
Expected: `[tab tree: save]` 與 `[tab tree: relaunch]` 沒有 `FAIL` 行，`TABS EXIT: 0`。

- [ ] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/Persistence.swift App/Sources/lmux-apptest/SidebarTabs.swift
git commit -m "feat(sidebar-tab-tree): 展開狀態存進 layout.json"
```

---

### Task 4: Tab 子列要顯示的內容（`SidebarTabItem`）

**Files:**
- Modify: `App/Sources/LmuxUI/SidebarTabs.swift`
- Test: `App/Sources/lmux-apptest/SidebarTabs.swift`

**Interfaces:**
- Produces:
  - `struct SidebarTabItem: Identifiable, Equatable`，欄位依序是 `id: String`、`title: String`、`isPreview: Bool`、`display: AgentDisplay`、`waiting: Bool`、`unread: Int`、`focused: Bool`、`closable: Bool`
  - `Workspace.tabItems(selected: Bool) -> [SidebarTabItem]`（`selected`：這個 workspace 是不是選取中的 workspace）

- [ ] **Step 1: 先查「等待回應」的 hook 寫法**

Run: `rg -n 'hook\("(PermissionRequest|Notification)"' App/Sources/lmux-apptest | head -5`
Expected: 至少 1 行。2026-11-17 查到的是 `PaneTabs.swift:528`：`hook("PermissionRequest", session: "tab-s1", #""tool_name":"Bash""#)`。Step 2 的 `needHook` 照這個寫法；查到的寫法不同就照查到的改，沒有任何結果就停下來回報。

- [ ] **Step 2: 寫檢查**

加在「存檔（這一段留在最後）」那一段**之前**：

```swift
    // ------------------------------------------------------------- Tab 子列的內容
    // @feature: sidebar-tab-tree.feature
    // @scenario: 分割出來的 tab 也列在同一層
    // @scenario: Tab 子列顯示 tab 的類型與標題
    // @scenario: Tab 子列顯示該 tab 自己的 agent 狀態
    // @scenario: 預覽 tab 的 Tab 子列沒有狀態圖示
    // @scenario: 只有 focused tab 的 Tab 子列有標示
    r.section = "tab tree: content"
    ws = await stageTabWorkspaces(c, [("S", 2)])
    let s = ws[0]
    let leftTabs = s.root.find(s.panes[0])!.tabs.map(\.id)
    let right = c.split(s.panes[0], .right)!
    _ = await waitFor(5) { right.surface!.foregroundPID > 0 }
    r.check("分割：左邊那格的 2 個 tab 依 tab 列順序，然後是右邊那格的 tab",
            s.tabItems(selected: true).map(\.id) == leftTabs + [right.id], "\(s.tabItems(selected: true).map(\.id))")

    ws = await stageTabWorkspaces(c, [("T", 4)])
    let t = ws[0]
    let idle = t.focusedPane!
    let others = t.panes.filter { $0 !== idle }
    let (run, done, need) = (others[0], others[1], others[2])
    run.titleState.title = "fix login"
    let doc = paths.stateDir.appendingPathComponent("design.md")
    try? "# design\n".write(to: doc, atomically: true, encoding: .utf8)
    let pv = c.newPreviewTab(doc, after: idle)!
    c.focus(idle)
    func item(_ p: Pane, selected: Bool = true) -> SidebarTabItem? { t.tabItems(selected: selected).first { $0.id == p.id } }
    r.check("終端機 tab：終端機類型，標題是任務名稱", item(run)?.isPreview == false && item(run)?.title == "fix login", item(run)?.title ?? "nil")
    r.check("預覽 tab：文件類型，標題是檔名", item(pv)?.isPreview == true && item(pv)?.title == "design.md", item(pv)?.title ?? "nil")

    // needHook：照 Step 1 查到的寫法。
    let needHook = hook("PermissionRequest", session: "s-need", #""tool_name":"Bash""#)
    let prompt = #""prompt":"hi""#
    _ = sendHook(pane: run.id, hook("SessionStart", session: "s-run"))
    _ = sendHook(pane: run.id, hook("UserPromptSubmit", session: "s-run", prompt))
    _ = sendHook(pane: done.id, hook("SessionStart", session: "s-done"))
    _ = sendHook(pane: done.id, hook("UserPromptSubmit", session: "s-done", prompt))
    _ = sendHook(pane: done.id, hook("Stop", session: "s-done"))
    _ = sendHook(pane: need.id, hook("SessionStart", session: "s-need"))
    _ = sendHook(pane: need.id, hook("UserPromptSubmit", session: "s-need", prompt))
    _ = sendHook(pane: need.id, needHook)
    _ = await waitFor(5) { run.agent.state == .running && done.agent.state == .done && need.needsInput }
    func isRunning(_ d: AgentDisplay?) -> Bool { if case .running = d { return true }; return false }
    func isDone(_ d: AgentDisplay?) -> Bool { if case .done = d { return true }; return false }
    func isNeedsInput(_ d: AgentDisplay?) -> Bool { if case .needsInput = d { return true }; return false }
    r.check("進行中的 tab：Tab 子列是進行中", isRunning(item(run)?.display), "\(String(describing: item(run)?.display))")
    r.check("完成的 tab：Tab 子列是完成", isDone(item(done)?.display), "\(String(describing: item(done)?.display))")
    r.check("等待回應的 tab：Tab 子列是等待回應", isNeedsInput(item(need)?.display), "\(String(describing: item(need)?.display))")
    r.check("閒置的 tab：沒有狀態", item(idle)?.display == .idle)
    r.check("預覽 tab：沒有狀態，也沒有未讀數", item(pv)?.display == .idle && item(pv)?.unread == 0)

    let marked = t.tabItems(selected: true).filter(\.focused).map(\.id)
    r.check("選取中的 workspace：只有 focused tab 的 Tab 子列有標示", marked == [idle.id], "\(marked)")
    r.check("…有標示的那一列不顯示未讀數", item(idle)?.unread == 0)
    r.check("沒選取的 workspace：Tab 子列都沒有標示", t.tabItems(selected: false).allSatisfy { !$0.focused })
```

- [ ] **Step 3: 確認失敗**

Run: `beat/changes/sidebar-tab-tree/dev.sh errors SidebarTabs.swift`
Expected: `ERRORS TOTAL` 大於 0，錯誤訊息提到 `SidebarTabItem` 或 `tabItems` 不存在。

- [ ] **Step 4: 在 `App/Sources/LmuxUI/SidebarTabs.swift` 加 `SidebarTabItem`**

加在檔案最後：

```swift
/// 一列 Tab 子列要顯示的內容。view 只畫這個；測試直接檢查它。
struct SidebarTabItem: Identifiable, Equatable {
    /// 這個 tab（Pane）的 id。
    let id: String
    let title: String
    /// 預覽 tab（文件圖示）；否則是終端機 tab。
    let isPreview: Bool
    /// 這個 tab 自己的 agent 狀態。預覽 tab 沒有 agent，永遠是閒置。
    let display: AgentDisplay
    /// 進行中，但在等使用額度重設：畫時鐘，不畫轉圈（與 workspace 列一致）。
    let waiting: Bool
    let unread: Int
    /// 選取中的 workspace 的 focused tab：這一列有標示。
    let focused: Bool
    /// 釘選的 tab 不能關，沒有關閉按鈕。
    let closable: Bool
}

extension Workspace {
    /// 這個 workspace 的 Tab 子列，由上而下：每一格由左到右、由上到下，格內依 tab 列的順序。
    /// `selected`：這個 workspace 是不是選取中的 workspace（不是的話沒有任何一列有標示）。
    func tabItems(selected: Bool) -> [SidebarTabItem] {
        panes.map { pane in
            let focused = selected && focusedPane === pane
            let title = pane.headerTitle
            return SidebarTabItem(id: pane.id,
                                  title: title.isEmpty ? "Terminal" : title,
                                  isPreview: pane.preview != nil,
                                  display: pane.display,
                                  waiting: pane.agent.usageLimitResets != nil,
                                  unread: focused ? 0 : pane.unread,
                                  focused: focused,
                                  closable: !pane.pinned)
        }
    }
}
```

- [ ] **Step 5: 確認通過**

Run: `beat/changes/sidebar-tab-tree/dev.sh tabs`
Expected: `[tab tree: content]` 沒有 `FAIL` 行，`TABS EXIT: 0`。

這一段只檢查「要顯示什麼」（`SidebarTabItem`）。「實際畫出來的樣子」在 Task 6 檢查。

「預覽 tab：文件類型，標題是檔名」失敗、而且印出的標題不是 `design.md` 時，停下來回報印出的標題（`headerTitle` 對預覽 tab 回什麼，plan 階段只讀過程式、沒有執行）。

- [ ] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/SidebarTabs.swift App/Sources/lmux-apptest/SidebarTabs.swift
git commit -m "feat(sidebar-tab-tree): 算出每列 Tab 子列要顯示的內容"
```

---

### Task 5: Tab 子列的尺寸，以及測試 helper `rowPoint`

**Files:**
- Modify: `App/Sources/LmuxTokens/Tokens.swift:319`（`rowCloseButtonSize` 之後）
- Modify: `App/Sources/lmux-apptest/Tests.swift:51-62`（`rowPoint`）

`rowPoint` 是 7 支既有測試共用的 helper。這個 task 只做它與尺寸，並跑整輪 quick 確認沒有弄壞既有測試。所有 workspace 都收合時，這個改動不影響任何位置。

**Interfaces:**
- Consumes: `Workspace.showsTabChildren`（Task 2）
- Produces:
  - `LmuxTokens.Layout.tabChildRowHeight`（26）、`tabChildIndent`（18）、`tabDisclosureSize`（14）
  - `rowPoint(_:_:)` 會算入上面已展開的 workspace 的 Tab 子列高度

- [ ] **Step 1: 加尺寸（`Tokens.swift`）**

在 `public static let rowCloseButtonSize: CGFloat = 20` 之後加：

```swift
        /// Sidebar 的 Tab 子列（beat: sidebar-tab-tree.feature）：列高、標題相對 workspace 列內容的縮排，
        /// 以及展開箭頭的點擊範圍（箭頭本身 8pt）。
        public static let tabChildRowHeight: CGFloat = 26
        public static let tabChildIndent: CGFloat = 18
        public static let tabDisclosureSize: CGFloat = 14
```

- [ ] **Step 2: `rowPoint` 算入 Tab 子列的高度（`Tests.swift:51-62`）**

把 `let above = ...` 那一行換成：

```swift
    // 已展開的 workspace，下面還有它的 Tab 子列（beat: sidebar-tab-tree.feature）。
    func kids(_ ws: Workspace) -> CGFloat {
        ws.showsTabChildren ? CGFloat(ws.panes.count) * (LmuxTokens.Layout.tabChildRowHeight + LmuxTokens.Layout.rowGap) : 0
    }
    let above = ws.prefix(i).reduce(CGFloat(0)) { $0 + h($1) + kids($1) + LmuxTokens.Layout.rowGap }
```

- [ ] **Step 3: 確認 build 通過**

Run: `beat/changes/sidebar-tab-tree/dev.sh errors Tests.swift Tokens.swift`
Expected: `ERRORS TOTAL: 0`、`BUILD EXIT: 0`。

- [ ] **Step 4: 確認沒有弄壞既有的檢查**

Run: `beat/changes/sidebar-tab-tree/dev.sh apptest-quick`，跑完後 `beat/changes/sidebar-tab-tree/dev.sh new-failures quick`
Expected: `NEW FAILURES: 0`、`MISSING CHECKS: 0`。
（這個 helper 在上面有展開的 workspace 時算得對不對，Task 6 的「A 展開時，A 下面的 B 還點得到」會檢查。）

- [ ] **Step 5: Commit**

```bash
git add App/Sources/LmuxTokens/Tokens.swift App/Sources/lmux-apptest/Tests.swift
git commit -m "test(sidebar-tab-tree): 新增 Tab 子列的尺寸，rowPoint 算入 Tab 子列的高度"
```

---

### Task 6: 畫出 Tab 子列，點它切換

**Files:**
- Modify: `App/Sources/LmuxUI/SidebarTabs.swift`
- Modify: `App/Sources/LmuxUI/Sidebar.swift:52-58`
- Test: `App/Sources/lmux-apptest/SidebarTabs.swift`

**Interfaces:**
- Consumes: `SidebarTabItem`、`Workspace.tabItems(selected:)`、`Workspace.showsTabChildren`（Task 2、4）；Task 5 的 3 個尺寸與 `rowPoint`
- Produces:
  - `LmuxController.clickTabRow(_ pane: Pane)`
  - `struct SidebarTabChildren: View`（`ws`、`selected`、`hoverEnabled`、`controller`）
  - `struct SidebarTabChildRow: View`（`item`、`pane`、`hover`、`controller`）
  - 測試用：`func tabChildPoint(_ c: LmuxController, _ ws: Workspace, _ k: Int) -> NSPoint`

- [ ] **Step 1: 寫檢查**

在 `App/Sources/lmux-apptest/SidebarTabs.swift` 的 `stageTabWorkspaces` 之後加 helper：

```swift
/// `ws` 的第 k 列 Tab 子列的中心點（sidebar host 座標）。要先展開。
@MainActor
func tabChildPoint(_ c: LmuxController, _ ws: Workspace, _ k: Int) -> NSPoint {
    let L = LmuxTokens.Layout.self
    let host = c.root.sidebarHost
    let i = c.model.workspaces.firstIndex { $0 === ws } ?? 0
    let row = rowPoint(c, i)
    let h = ws.showsStateLine ? L.workspaceRowHeightDouble : L.workspaceRowHeightSingle
    let down = h / 2 + L.rowGap + CGFloat(k) * (L.tabChildRowHeight + L.rowGap) + L.tabChildRowHeight / 2
    return NSPoint(x: row.x, y: host.isFlipped ? row.y + down : row.y - down)
}

/// `ws` 的第 k 列 Tab 子列中間一塊的像素（標題的位置），用來比較「有沒有變」。
@MainActor
func tabChildPixels(_ c: LmuxController, _ ws: Workspace, _ k: Int) -> Data? {
    let p = tabChildPoint(c, ws, k)
    return sidebarPixels(c, NSRect(x: p.x - 40, y: p.y - 8, width: 80, height: 16))
}
```

在 `runSidebarTabs()` 開頭的 `let c = makeController()` 之後加：

```swift
    let host = c.root.sidebarHost
    /// 等 sidebar 重新排版。
    func settle() async { host.layoutSubtreeIfNeeded(); await sleepMs(300) }
```

加在「存檔（這一段留在最後）」那一段**之前**：

```swift
    // ------------------------------------------------------------- 點 Tab 子列
    // @feature: sidebar-tab-tree.feature
    // @scenario: 點 Tab 子列切換到另一個 workspace 的 tab
    r.section = "tab tree: click"
    ws = await stageTabWorkspaces(c, [("A", 1), ("B", 2)])
    let wb = ws[1]
    let t1 = wb.focusedPane!
    let t2 = wb.panes.first { $0 !== t1 }!
    c.toggleTabsExpanded(wb)
    await settle()
    r.check("佈置：A 是選取中的 workspace，B 的 T1 顯示在最前面、T2 被蓋住",
            c.model.selected === ws[0] && wb.root.find(t2)?.shownTab === t1)
    let k2 = wb.panes.firstIndex { $0 === t2 }!
    await click(host, at: tabChildPoint(c, wb, k2))
    _ = await waitFor(2) { c.model.selected === wb && wb.focusedPane === t2 }
    r.check("點 T2 的 Tab 子列：B 成為選取中的 workspace", c.model.selected === wb, c.model.selected?.title ?? "nil")
    r.check("…T2 顯示在它那一格的最前面，並成為 focused tab", wb.root.find(t2)?.shownTab === t2 && wb.focusedPane === t2)
    r.check("…鍵盤焦點也在 T2", firstResponderPane(c) === t2)
    let k1 = wb.panes.firstIndex { $0 === t1 }!
    await click(host, at: tabChildPoint(c, wb, k1))
    _ = await waitFor(2) { wb.focusedPane === t1 }
    r.check("再點 T1 的 Tab 子列：T1 回到最前面", wb.root.find(t1)?.shownTab === t1 && wb.focusedPane === t1)

    // workspace 列的位置：展開的在下面時不受影響；展開的在上面時往下移一組的高度。
    await click(host, at: rowPoint(c, 0))
    _ = await waitFor(2) { c.model.selected === ws[0] }
    r.check("B 展開時，B 上面的 A 的 workspace 列位置不變，還點得到", c.model.selected === ws[0])
    ws = await stageTabWorkspaces(c, [("A", 2), ("B", 1)])
    c.toggleTabsExpanded(ws[0])
    await settle()
    await click(host, at: rowPoint(c, 1))
    _ = await waitFor(2) { c.model.selected === ws[1] }
    r.check("A 展開時，A 下面的 B 的 workspace 列還點得到", c.model.selected === ws[1], c.model.selected?.title ?? "nil")

    // 多選時點 Tab 子列：和點 workspace 列一樣，多選結束。
    let ma = ws[0]
    c.select(ma)
    c.setSelection([ma.id, ws[1].id], anchor: ma.id)
    await settle()
    let other = ma.panes.first { $0 !== ma.focusedPane }!
    r.check("佈置：A 與 B 都在多選裡，A 是選取中的 workspace", c.model.isMultiSelection && c.model.selected === ma)
    await click(host, at: tabChildPoint(c, ma, ma.panes.firstIndex { $0 === other }!))
    _ = await waitFor(2) { ma.focusedPane === other }
    r.check("多選時點選取中 workspace 的 Tab 子列：切到那個 tab，多選結束",
            ma.focusedPane === other && !c.model.isMultiSelection, "\(c.model.selection.count)")

    // 放大某一格時點另一格的 tab：先取消放大。
    ws = await stageTabWorkspaces(c, [("Z", 1)])
    let z = ws[0]
    let zLeft = z.panes[0]
    let zRight = c.split(zLeft, .right)!
    _ = await waitFor(5) { zRight.surface!.foregroundPID > 0 }
    c.focus(zLeft)
    c.toggleZoom(for: zLeft)
    c.toggleTabsExpanded(z)
    await settle()
    r.check("佈置：Z 放大左邊那一格", z.zoomedPane === zLeft)
    await click(host, at: tabChildPoint(c, z, z.panes.firstIndex { $0 === zRight }!))
    _ = await waitFor(2) { z.focusedPane === zRight }
    r.check("放大時點另一格的 Tab 子列：取消放大，那個 tab 成為 focused tab", z.zoomedPane == nil && z.focusedPane === zRight)

    // ------------------------------------------------------------- 畫出來的樣子
    // @feature: sidebar-tab-tree.feature
    // @scenario: Tab 子列顯示 tab 的類型與標題
    // @scenario: Tab 子列顯示該 tab 自己的 agent 狀態
    // @scenario: 預覽 tab 的 Tab 子列沒有狀態圖示
    // @scenario: 只有 focused tab 的 Tab 子列有標示
    r.section = "tab tree: render"
    let anyPane = z.panes[0]
    /// 把一列 Tab 子列畫到畫面外，回傳像素。
    func shot(preview: Bool, _ display: AgentDisplay, focused: Bool = false) -> Data? {
        let item = SidebarTabItem(id: anyPane.id, title: "x", isPreview: preview, display: display, waiting: false,
                                  unread: 0, focused: focused, closable: true)
        return renderBytes(SidebarTabChildRow(item: item, pane: anyPane, hover: false, controller: c),
                           size: NSSize(width: 240, height: LmuxTokens.Layout.tabChildRowHeight), dark: false)
    }
    let plain = shot(preview: false, .idle)
    r.check("完成的終端機 tab 畫出來與閒置的不同（有 ✓）", plain != nil && shot(preview: false, .done(nil)) != plain)
    r.check("等待回應的終端機 tab 畫出來與閒置的不同", shot(preview: false, .needsInput(nil)) != plain)
    r.check("預覽 tab 的類型圖示與終端機 tab 的不同", shot(preview: true, .idle) != plain)
    r.check("預覽 tab 不畫狀態圖示（給它完成狀態，畫出來仍與閒置相同）", shot(preview: true, .done(nil)) == shot(preview: true, .idle))
    r.check("有標示的那一列畫出來與沒有標示的不同", shot(preview: false, .idle, focused: true) != plain)

    ws = await stageTabWorkspaces(c, [("A", 2), ("B", 2)])
    c.toggleTabsExpanded(ws[0])
    c.toggleTabsExpanded(ws[1])
    await settle()
    let fb = ws[1].panes.firstIndex { $0 === ws[1].focusedPane }!
    let whileA = tabChildPixels(c, ws[1], fb)
    c.select(ws[1])
    await settle()
    r.check("A 與 B 都展開：B 被選取後，B 的 focused tab 那一列才有標示（那一列的畫面變了）",
            whileA != nil && tabChildPixels(c, ws[1], fb) != whileA)
```

- [ ] **Step 2: 確認失敗**

Run: `beat/changes/sidebar-tab-tree/dev.sh errors SidebarTabs.swift`
Expected: `ERRORS TOTAL` 大於 0，錯誤訊息提到 `SidebarTabChildRow` 不存在。

- [ ] **Step 3: 在 `App/Sources/LmuxUI/SidebarTabs.swift` 加 `clickTabRow`**

在 `extension LmuxController` 裡，`toggleTabsExpanded` 之後加：

```swift
    /// 點一列 Tab 子列：切換到那個 tab（必要時先切換 workspace、把被蓋住的 tab 顯示出來、取消放大）。
    /// 和點 workspace 列一樣，會結束 sidebar 的多選。
    public func clickTabRow(_ pane: Pane) {
        guard let ws = pane.workspace else { return }
        if model.isMultiSelection { setSelection([], anchor: ws.id) }
        focus(pane)
    }
```

- [ ] **Step 4: 在同一個檔案加 view**

加在檔案最後：

```swift
/// 一個 workspace 的 Tab 子列。自成一個 view：tab 的標題或狀態改變時，只重畫這一塊，不重畫整個 sidebar。
struct SidebarTabChildren: View {
    let ws: Workspace
    /// 這個 workspace 是不是選取中的 workspace。
    let selected: Bool
    /// 拖曳 workspace 列的期間不顯示 hover。
    let hoverEnabled: Bool
    let controller: LmuxController

    var body: some View {
        if ws.showsTabChildren {
            VStack(spacing: T.Layout.rowGap) {
                ForEach(ws.tabItems(selected: selected)) { item in
                    if let pane = ws.panes.first(where: { $0.id == item.id }) {
                        SidebarTabChildRow(item: item, pane: pane, hover: false, controller: controller)
                    }
                }
            }
        }
    }
}

/// 一列 Tab 子列：類型圖示、標題、這個 tab 自己的狀態。點它切換到這個 tab。
struct SidebarTabChildRow: View {
    let item: SidebarTabItem
    let pane: Pane
    let hover: Bool
    let controller: LmuxController
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.isPreview ? "doc.text" : "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(T.Colors.textTertiary.color)
                .frame(width: 14)
            Text(item.title)
                .font(T.Typography.rowSubtitle.font)
                .foregroundStyle((item.focused ? T.Colors.textPrimary : T.Colors.textSecondary).color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.isPreview {
                StateIndicator(display: item.display, unread: item.unread,
                               pulse: controller.model.pulseMotion, reduceMotion: controller.model.reduceMotion,
                               waiting: item.waiting)
            }
        }
        .padding(.leading, T.Layout.rowPaddingX + T.Layout.tabChildIndent)
        .padding(.trailing, T.Layout.rowPaddingX)
        .frame(maxWidth: .infinity, minHeight: T.Layout.tabChildRowHeight, maxHeight: T.Layout.tabChildRowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous).fill(fill))
        .padding(.horizontal, T.Layout.rowInsetX)
        .contentShape(Rectangle())
        .onTapGesture { controller.clickTabRow(pane) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.focused ? [.isSelected, .isButton] : [.isButton])
    }

    /// 底色：有標示的那一列與 workspace 列的選取底色相同；滑鼠在上面時是 hover 色。
    private var fill: Color {
        if item.focused { return (activeState == .inactive ? T.Colors.rowSelectedInactive : T.Colors.rowSelected).color }
        return hover ? T.Colors.rowHover.color : .clear
    }
}
```

（`hover: false` 與 `hoverEnabled` 還沒用到，是 Task 9 要接的。）

- [ ] **Step 5: 在 `Sidebar.swift` 把 Tab 子列放進每一組（`:52-58`）**

把：

```swift
                                    WorkspaceRow(ws: ws, disambiguator: names[ws.id], selected: ws.id == model.selectedID,
                                                 inSelection: model.isInSelection(ws),
                                                 hover: drag == nil && model.hoveredRowID == ws.id,
                                                 controller: controller, rowFrames: rowFrames)
```

換成：

```swift
                                    // workspace 列與它的 Tab 子列是同一組（beat: sidebar-tab-tree.feature）：
                                    // 外層量到的 frame 包含 Tab 子列，拖曳時整組一起移動。
                                    VStack(spacing: T.Layout.rowGap) {
                                        WorkspaceRow(ws: ws, disambiguator: names[ws.id], selected: ws.id == model.selectedID,
                                                     inSelection: model.isInSelection(ws),
                                                     hover: drag == nil && model.hoveredRowID == ws.id,
                                                     controller: controller, rowFrames: rowFrames)
                                        SidebarTabChildren(ws: ws, selected: ws.id == model.selectedID,
                                                           hoverEnabled: drag == nil, controller: controller)
                                    }
```

先確認要換掉的 4 行與檔案裡的完全相同；不同就停下來回報。不要在這裡加 `.animation`：動畫由 `toggleTabsExpanded` 的 `withAnimation` 帶動。

- [ ] **Step 6: 確認通過**

Run: `beat/changes/sidebar-tab-tree/dev.sh tabs`
Expected: `[tab tree: click]` 與 `[tab tree: render]` 沒有 `FAIL` 行，`TABS EXIT: 0`。

- [ ] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/SidebarTabs.swift App/Sources/LmuxUI/Sidebar.swift App/Sources/lmux-apptest/SidebarTabs.swift
git commit -m "feat(sidebar-tab-tree): sidebar 畫出 Tab 子列，點它切換到那個 tab"
```

---

### Task 7: 拖曳排序

**Files:**
- Test: `App/Sources/lmux-apptest/SidebarTabs.swift`

design 預期 `SidebarReorder.swift` 不用改（未實測）。這個 task 只加檢查，而且排在展開箭頭與關閉之前：推論錯的話要早點知道。檢查失敗就停下來回報，不要自己改 `SidebarReorder.swift` 或 `Sidebar.swift`。

沒有自動檢查的部分（放進 Task 10 的手動確認）：拖曳途中 Tab 子列是否跟著 workspace 列一起移動；⌘ 多選裡有展開的 workspace 時一起拖。

**Interfaces:**
- Consumes: `dragRow(_:from:to:modifiers:)`（`ZoomClearReorder.swift:13`）、`SidebarDragGeometry`、`tabChildPoint`

- [ ] **Step 1: 寫檢查**

加在「存檔（這一段留在最後）」那一段**之前**：

```swift
    // ------------------------------------------------------------- 拖曳排序
    // @feature: sidebar-tab-tree.feature
    // @scenario: 拖曳已展開的 workspace 時 Tab 子列跟著移動
    // @scenario: 拖 Tab 子列不會移動 workspace
    r.section = "tab tree: drag"
    // 一組的高度不同時（workspace 列 34 + 2 列 Tab 子列各 26 + 間距 4 = 94），位移照高度算。
    let geo = SidebarDragGeometry(order: ["a", "b", "c"], moving: ["a"],
                                  frames: ["a": CGRect(x: 0, y: 0, width: 200, height: 94),
                                           "b": CGRect(x: 0, y: 98, width: 200, height: 34),
                                           "c": CGRect(x: 0, y: 136, width: 200, height: 34)], gap: 4)
    let shifts = geo.offsets(grabbed: "a", dropIndex: 2)
    r.check("位移：展開的 A 拖到最後，B 與 C 各往上移 A 整組的高度加間距", shifts["b"] == -98 && shifts["c"] == -98, "\(shifts)")

    func order() -> String { c.model.workspaces.map(\.title).joined() }
    ws = await stageTabWorkspaces(c, [("A", 2), ("B", 1), ("C", 1)])
    let ga = ws[0]
    c.toggleTabsExpanded(ga)
    await settle()
    // design 的未查證第 2 項：sidebar 量每一組的 frame 時，有沒有把 Tab 子列算進去。
    let L = LmuxTokens.Layout.self
    let groupHeight = (ga.showsStateLine ? L.workspaceRowHeightDouble : L.workspaceRowHeightSingle)
        + 2 * (L.tabChildRowHeight + L.rowGap)
    let measured = host.rootView.rowFrames.frames[ga.id]?.height ?? 0
    r.check("sidebar 量到的 A 那一組的高度包含 2 列 Tab 子列（拖曳的位移用這個高度算）",
            abs(measured - groupHeight) < 1, "\(measured) vs \(groupHeight)")
    // 「往下」在 host 座標裡是哪個方向：第 1 列到第 2 列的方向。
    let step = rowPoint(c, 1).y - rowPoint(c, 0).y
    let below = NSPoint(x: rowPoint(c, 2).x, y: rowPoint(c, 2).y + (step > 0 ? 400 : -400))
    await dragRow(host, from: tabChildPoint(c, ga, 0), to: below)
    await sleepMs(400)
    r.check("拖 A 的 Tab 子列：順序不變", order() == "ABC" && c.model.sidebarDrag == nil, order())
    await dragRow(host, from: rowPoint(c, 0), to: below)
    _ = await waitFor(2) { order() != "ABC" }
    r.check("拖 A 的 workspace 列到 C 的下方：順序變成 B、C、A", order() == "BCA", order())
    r.check("…A 仍然展開，有 2 列 Tab 子列", ga.showsTabChildren && ga.tabItems(selected: true).count == 2)
    host.layoutSubtreeIfNeeded()
    await sleepMs(300)
    let last = ga.panes.first { $0 !== ga.focusedPane }!
    await click(host, at: tabChildPoint(c, ga, ga.panes.firstIndex { $0 === last }!))
    _ = await waitFor(2) { ga.focusedPane === last }
    r.check("…Tab 子列跟著 A 到新位置，還點得到", ga.focusedPane === last)
```

- [ ] **Step 2: 執行**

Run: `beat/changes/sidebar-tab-tree/dev.sh tabs`
Expected: `[tab tree: drag]` 沒有 `FAIL` 行，`TABS EXIT: 0`。
（這個 task 沒有「確認失敗」：它驗證的是 Task 6 已經做出來的行為。）

有 `FAIL` 時停下來回報：哪一行、印出的順序或位移。design 的「拖曳排序」一節寫明這是未實測的推論。

- [ ] **Step 3: Commit**

```bash
git add App/Sources/lmux-apptest/SidebarTabs.swift
git commit -m "test(sidebar-tab-tree): 展開的 workspace 拖曳時 Tab 子列跟著移動"
```

---

### Task 8: 展開箭頭

**Files:**
- Modify: `App/Sources/LmuxUI/SidebarTabs.swift`
- Modify: `App/Sources/LmuxUI/Sidebar.swift:207-233`（`WorkspaceRow` 的關閉按鈕 overlay 之後；`closeTrailing` 之前）
- Test: `App/Sources/lmux-apptest/SidebarTabs.swift`

這個 task 先做出箭頭、截圖給使用者看，**使用者確認位置後才寫檢查**（見前面「review 發現的 design 問題」）。所以沒有「確認失敗」的步驟。

**Interfaces:**
- Consumes: `LmuxController.toggleTabsExpanded(_:)`、`Workspace.showsTabDisclosure`、`LmuxTokens.Layout.tabDisclosureSize`、`tabChildPoint`、`settle()`
- Produces:
  - `struct TabDisclosureButton: View`（`expanded: Bool`、`action: () -> Void`）
  - `WorkspaceRow.disclosureLeading: CGFloat`（1）
  - 測試用：`func disclosureRect(_ c: LmuxController, _ ws: Workspace) -> NSRect`、`func saveSidebarShot(_ c: LmuxController, _ name: String)`

- [ ] **Step 1: 在 `App/Sources/LmuxUI/SidebarTabs.swift` 加 `TabDisclosureButton`**

加在檔案最後：

```swift
/// workspace 列的展開箭頭：收合時朝右，展開時朝下。
struct TabDisclosureButton: View {
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(T.Colors.textTertiary.color)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: T.Layout.tabDisclosureSize, height: T.Layout.tabDisclosureSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide Tabs" : "Show Tabs")
        .accessibilityLabel(expanded ? "Hide Tabs" : "Show Tabs")
    }
}
```

- [ ] **Step 2: 在 `Sidebar.swift` 的 `WorkspaceRow` 加 overlay**

在關閉按鈕的 overlay 結束之後（`.padding(.trailing, Self.closeTrailing)` 之後的兩個 `}`，約 `:216`），`.onHover {` **之前**加：

```swift
            // 展開箭頭（beat: sidebar-tab-tree.feature）：和 × 一樣在列的點擊手勢之外，點它不會先選取這一列。
            // 放在列左邊的留白，不動列的內容。
            .overlay(alignment: .topLeading) {
                if ws.showsTabDisclosure {
                    TabDisclosureButton(expanded: ws.tabsExpanded) { controller.toggleTabsExpanded(ws) }
                        .padding(.top, Self.closeTop(detail != nil) + (T.Layout.rowCloseButtonSize - T.Layout.tabDisclosureSize) / 2)
                        .padding(.leading, Self.disclosureLeading)
                }
            }
```

在 `static let closeTrailing = ...` 那一行之前加：

```swift
    /// 展開箭頭左邊的留白：14pt 的點擊範圍落在 x 1…15，在色塊（x 16 起）的左邊。
    static let disclosureLeading: CGFloat = 1
```

- [ ] **Step 3: 加截圖的 helper 與截圖用的佈置**

在 `App/Sources/lmux-apptest/SidebarTabs.swift` 的 `tabChildPixels` 之後加：

```swift
/// `ws` 的展開箭頭的範圍（sidebar host 座標）：workspace 列左邊的留白，垂直對齊第 1 行。
@MainActor
func disclosureRect(_ c: LmuxController, _ ws: Workspace) -> NSRect {
    let L = LmuxTokens.Layout.self
    let host = c.root.sidebarHost
    let i = c.model.workspaces.firstIndex { $0 === ws } ?? 0
    let two = ws.showsStateLine
    let h = two ? L.workspaceRowHeightDouble : L.workspaceRowHeightSingle
    let s = L.tabDisclosureSize
    let center = rowPoint(c, i).y
    let fromTop = (host.isFlipped ? center : host.bounds.height - center) - h / 2
        + WorkspaceRow.closeTop(two) + (L.rowCloseButtonSize - s) / 2
    let y = host.isFlipped ? fromTop : host.bounds.height - fromTop - s
    return NSRect(x: WorkspaceRow.disclosureLeading, y: y, width: s, height: s)
}

/// 設了 LMUX_TABTREE_SHOTS（`dev.sh shots` 會設）時，把 sidebar 現在的樣子存成 <name>.png，給人看。
/// sidebar 的底色是另一個 view 畫的，所以圖的背景是透明的。
@MainActor
func saveSidebarShot(_ c: LmuxController, _ name: String) {
    guard let dir = env["LMUX_TABTREE_SHOTS"], !dir.isEmpty else { return }
    let host = c.root.sidebarHost
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
}
```

在 `runSidebarTabs()` 裡，加在「存檔（這一段留在最後）」那一段**之前**：

```swift
    // ------------------------------------------------------------- 截圖（給人看；不是檢查）
    if env["LMUX_TABTREE_SHOTS"] != nil {
        ws = await stageTabWorkspaces(c, [("alpha", 3), ("beta", 1), ("gamma", 2), ("delta", 2)])
        let appearance0 = NSApp.appearance
        for (name, dark) in [("light", false), ("dark", true)] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            ws[0].tabsExpanded = false
            c.select(ws[0]); c.setSelection([], anchor: ws[0].id); c.model.hoveredRowID = nil
            await settle()
            saveSidebarShot(c, "1-collapsed-selected-\(name)")       // 選取中的列：箭頭壓在底色左緣上嗎
            c.model.hoveredRowID = ws[2].id
            await settle()
            saveSidebarShot(c, "2-collapsed-hover-\(name)")          // 滑鼠在另一列上
            c.model.hoveredRowID = nil
            c.setSelection([ws[0].id, ws[2].id], anchor: ws[0].id)
            await settle()
            saveSidebarShot(c, "3-collapsed-multiselect-\(name)")    // 多選
            c.setSelection([], anchor: ws[0].id)
            ws[0].tabsExpanded = true
            ws[3].tabsExpanded = true
            await settle()
            saveSidebarShot(c, "4-expanded-\(name)")                 // 展開：縮排、列高、標示
        }
        NSApp.appearance = appearance0
        ws[3].tabsExpanded = false
    }
```

- [ ] **Step 4: 截圖**

Run: `beat/changes/sidebar-tab-tree/dev.sh shots`
Expected: 列出 8 個 PNG（`1-collapsed-selected-light.png` … `4-expanded-dark.png`），`SHOTS: 8`。

- [ ] **Step 5: 停下來，請使用者看圖決定**

把 8 個 PNG 的完整路徑給使用者，問這一題，然後**等回答**：

> 展開箭頭現在放在 workspace 列左邊的留白（x 1…15）。選取中、滑鼠在上面、多選這 3 種列有底色，底色從 x=8 開始。請看圖：箭頭看得清楚嗎？壓在底色左緣上可以接受嗎？
> 1. 可以，繼續。
> 2. 不行，改成所有列的內容右移，箭頭放在色塊左邊。

- 回答 1：繼續 Step 6。
- 回答 2：停止。回報「Task 8 之後要重新規劃」，不要自己改 `WorkspaceRowContent`。Step 1–3 的改動先不 commit，留在工作目錄。
- 使用者要調整數值（例如 `disclosureLeading`、箭頭大小）：改 `Sidebar.swift` 的 `disclosureLeading` 或 `Tokens.swift` 的 `tabDisclosureSize`，回到 Step 4。`disclosureRect` 讀的是同樣的常數，不用改。

- [ ] **Step 6: 寫檢查**

加在「截圖」那一段**之前**：

```swift
    // ------------------------------------------------------------- 展開箭頭
    // @feature: sidebar-tab-tree.feature
    // @scenario: 有多個 tab 的 workspace 可以展開與收合
    // @scenario: 只有 1 個 tab 的 workspace 沒有展開箭頭
    // @scenario: 點展開箭頭不切換 workspace
    // @scenario: 展開時 workspace 列照常顯示整體狀態
    r.section = "tab tree: disclosure"
    func clickDisclosure(_ w: Workspace) async {
        let f = disclosureRect(c, w)
        await click(host, at: NSPoint(x: f.midX, y: f.midY))
        await settle()
    }
    ws = await stageTabWorkspaces(c, [("A", 1)])
    let noArrow = sidebarPixels(c, disclosureRect(c, ws[0]))
    _ = c.newTab(ws[0].panes[0], select: false)
    await settle()
    r.check("開出第 2 個 tab 後，workspace 列左邊畫出展開箭頭（同一個位置的像素變了）",
            noArrow != nil && sidebarPixels(c, disclosureRect(c, ws[0])) != noArrow)

    ws = await stageTabWorkspaces(c, [("A", 3), ("B", 1), ("C", 2)])
    let (da, db, dc) = (ws[0], ws[1], ws[2])
    await clickDisclosure(da)
    r.check("點 A 的展開箭頭：展開", da.showsTabChildren)
    var reached: [String] = []
    for k in 0..<3 {
        await click(host, at: tabChildPoint(c, da, k))
        _ = await waitFor(2) { da.focusedPane === da.panes[k] }
        if da.focusedPane === da.panes[k] { reached.append(da.panes[k].id) }
    }
    r.check("…下方有 3 列 Tab 子列，每一列都點得到", reached == da.panes.map(\.id), "\(reached.count)")
    await clickDisclosure(da)
    r.check("再點一次：收合", !da.showsTabChildren)
    let focusedBefore = da.focusedPane
    await click(host, at: rowPoint(c, 1))
    _ = await waitFor(2) { c.model.selected === db }
    r.check("…Tab 子列消失：B 的 workspace 列回到 A 的正下方", c.model.selected === db && da.focusedPane === focusedBefore)

    await clickDisclosure(db)
    r.check("只有 1 個 tab 的 B：點同一個位置不會展開", !db.tabsExpanded && !db.showsTabChildren)

    c.select(da)
    await settle()
    let keyboard = firstResponderPane(c)
    await clickDisclosure(dc)
    r.check("A 是選取中的 workspace 時點 C 的展開箭頭：C 展開", dc.showsTabChildren)
    r.check("…A 仍然是選取中的 workspace", c.model.selected === da, c.model.selected?.title ?? "nil")
    r.check("…鍵盤焦點沒有被箭頭拿走", keyboard != nil && firstResponderPane(c) === keyboard)

    // 進行中的 tab：收合時只有 workspace 列轉圈；展開後 workspace 列照常轉圈，那個 tab 的 Tab 子列也轉圈。
    ws = await stageTabWorkspaces(c, [("R", 2)])
    let rw = ws[0]
    let runner = rw.panes.first { $0 !== rw.focusedPane }!
    _ = sendHook(pane: runner.id, hook("SessionStart", session: "s-spin"))
    _ = sendHook(pane: runner.id, hook("UserPromptSubmit", session: "s-spin", #""prompt":"hi""#))
    _ = await waitFor(5) { runner.agent.state == .running }
    await settle()
    let spinsCollapsed = spinningViews(c)
    r.check("收合：workspace 列有 1 個轉圈圖示", spinsCollapsed == 1, "\(spinsCollapsed)")
    await clickDisclosure(rw)
    r.check("展開：workspace 列照常轉圈，進行中的 tab 的 Tab 子列也轉圈（共 2 個）", spinningViews(c) == 2, "\(spinningViews(c))")
```

- [ ] **Step 7: 確認通過**

Run: `beat/changes/sidebar-tab-tree/dev.sh tabs`
Expected: `[tab tree: disclosure]` 沒有 `FAIL` 行，`TABS EXIT: 0`。

- 「只有 1 個 tab 的 B：點同一個位置不會展開」之後，B 可能被選取（點到的是 workspace 列）。這是預期的，下一行有 `c.select(da)`。
- 「收合：workspace 列有 1 個轉圈圖示」印出 0 時停下來回報：`spinningViews`（`AttentionTests.swift`）在這個測試模式下數不數得到轉圈，plan 階段沒有執行過。

- [ ] **Step 8: 確認沒有弄壞其他測試**

Run: `beat/changes/sidebar-tab-tree/dev.sh apptest-quick`，跑完後 `beat/changes/sidebar-tab-tree/dev.sh new-failures quick`
Expected: `NEW FAILURES: 0`、`MISSING CHECKS: 0`。
（箭頭會出現在其他測試裡有 2 個以上 tab 的 workspace 列上，所以這裡跑整輪。）

- [ ] **Step 9: Commit**

```bash
git add App/Sources/LmuxUI/SidebarTabs.swift App/Sources/LmuxUI/Sidebar.swift App/Sources/lmux-apptest/SidebarTabs.swift
git commit -m "feat(sidebar-tab-tree): workspace 列加上展開箭頭"
```

---

### Task 9: 從 Tab 子列關閉 tab

**Files:**
- Modify: `App/Sources/LmuxUI/Model.swift:758`（`AppModel.hoveredRowID` 之後）
- Modify: `App/Sources/LmuxUI/SidebarTabs.swift`
- Test: `App/Sources/lmux-apptest/SidebarTabs.swift`

**Interfaces:**
- Consumes: `SidebarTabChildren`、`SidebarTabChildRow`、`SidebarTabItem.closable`、`tabChildPoint`
- Produces:
  - `AppModel.hoveredTabRowID: String?`（滑鼠所在的 Tab 子列的 tab id）
  - `LmuxController.closeTabFromSidebar(_ pane: Pane)`

- [ ] **Step 1: 寫檢查**

加在「存檔（這一段留在最後）」那一段**之前**：

```swift
    // ------------------------------------------------------------- 從 Tab 子列關閉
    // @feature: sidebar-tab-tree.feature
    // @scenario: 從 Tab 子列關閉 tab
    // @scenario: 釘選的 tab 的 Tab 子列沒有關閉按鈕
    // @scenario: 關閉還有程式在跑的終端機 tab 會先詢問
    r.section = "tab tree: close"
    /// 把滑鼠放到 `p` 的 Tab 子列上，點關閉按鈕的位置（列的最右邊那一格）。
    func clickTabClose(_ w: Workspace, _ p: Pane) async {
        c.model.hoveredTabRowID = p.id
        host.layoutSubtreeIfNeeded()
        await sleepMs(150)
        let k = w.panes.firstIndex { $0 === p } ?? 0
        let x = host.bounds.width - WorkspaceRow.closeTrailing - LmuxTokens.Layout.rowCloseButtonSize / 2
        await click(host, at: NSPoint(x: x, y: tabChildPoint(c, w, k).y))
        c.model.hoveredTabRowID = nil
        await sleepMs(150)
    }
    ws = await stageTabWorkspaces(c, [("A", 3)])
    let ca = ws[0]
    c.toggleTabsExpanded(ca)
    host.layoutSubtreeIfNeeded()
    await sleepMs(300)
    let victim = ca.panes.first { $0 !== ca.focusedPane }!
    await clickTabClose(ca, victim)
    _ = await waitFor(3) { ca.panes.count == 2 }
    r.check("點閒置 tab 的關閉按鈕：這個 tab 關閉", ca.panes.count == 2 && !ca.panes.contains { $0 === victim })
    r.check("…下方剩 2 列 Tab 子列", ca.showsTabChildren && ca.tabItems(selected: true).count == 2)

    let pinned = ca.panes.first { $0 !== ca.focusedPane }!
    c.togglePin(pinned)
    r.check("釘選的 tab：Tab 子列沒有關閉按鈕", ca.tabItems(selected: true).first { $0.id == pinned.id }?.closable == false)
    await clickTabClose(ca, pinned)
    await sleepMs(300)
    r.check("…點那個位置不會關閉它", ca.panes.count == 2 && ca.panes.contains { $0 === pinned })
    r.check("…那一下點到的是列本身（沒有按鈕接走）：它成為 focused tab", ca.focusedPane === pinned)

    let busyScript = paths.stateDir.appendingPathComponent("busy.sh")
    try? "#!/bin/sh\nexec /bin/sleep 600\n".write(to: busyScript, atomically: true, encoding: .utf8)
    chmod(busyScript.path, 0o755)
    ws = await stageTabWorkspaces(c, [("A", 1), ("B", 1)])
    let cb = ws[1]
    let busy = c.newTab(cb.panes[0], program: busyScript.path, select: false)!
    _ = await waitFor(10) { busy.surface!.foregroundPID > 0 && c.runningProcess(busy) == "sleep" }
    c.toggleTabsExpanded(cb)
    host.layoutSubtreeIfNeeded()
    await sleepMs(300)
    r.check("佈置：A 是選取中的 workspace，B 的 T 還有程式在跑、被蓋住",
            c.model.selected === ws[0] && c.runningProcess(busy) == "sleep" && cb.root.find(busy)?.shownTab !== busy)
    await clickTabClose(cb, busy)
    _ = await waitFor(3) { c.cardShown(busy) }
    r.check("點 T 的關閉按鈕：B 成為選取中的 workspace，T 成為 focused tab", c.model.selected === cb && cb.focusedPane === busy)
    r.check("…T 上出現是否關閉的詢問", c.cardShown(busy))
    r.check("…T 還沒關閉", cb.panes.contains { $0 === busy } && cb.panes.count == 2)
    busy.view.overlay.card?.confirm.performClick()
    _ = await waitFor(3) { cb.panes.count == 1 }
    r.check("確認之後：T 關閉，B 剩 1 個 tab，展開箭頭與 Tab 子列消失",
            cb.panes.count == 1 && !cb.showsTabDisclosure && !cb.showsTabChildren)
```

- [ ] **Step 2: 確認失敗**

Run: `beat/changes/sidebar-tab-tree/dev.sh errors SidebarTabs.swift`
Expected: `ERRORS TOTAL` 大於 0，錯誤訊息提到 `AppModel` 沒有 `hoveredTabRowID`。

- [ ] **Step 3: 在 `Model.swift` 的 `AppModel` 加屬性**

在 `public var hoveredRowID: String?` 之後加：

```swift
    /// 滑鼠所在的 Tab 子列（那個 tab 的 id）：這一列顯示關閉按鈕（beat: sidebar-tab-tree.feature）。
    public var hoveredTabRowID: String?
```

- [ ] **Step 4: 在 `App/Sources/LmuxUI/SidebarTabs.swift` 加關閉的入口**

在 `extension LmuxController` 裡，`clickTabRow` 之後加：

```swift
    /// 點 Tab 子列的關閉按鈕。規則與 tab 列相同（`requestClosePane`）：閒置的 shell 直接關；
    /// 還有程式在跑就先詢問。詢問的卡片顯示在那個 tab 上，所以先切過去（它可能在沒選取的
    /// workspace，或被同一格的其他 tab 蓋住），使用者才看得到。
    public func closeTabFromSidebar(_ pane: Pane) {
        // 釘選的 tab 不能關。Tab 子列本來就不畫它的關閉按鈕；這裡再擋一次，
        // 因為 requestClosePane 只在那一格有 tab 列時才擋。
        if pane.pinned { NSSound.beep(); return }
        if runningProcess(pane) != nil { focus(pane) }
        requestClosePane(pane)
    }
```

- [ ] **Step 5: 接上 hover 與關閉按鈕**

`SidebarTabChildren` 裡，把：

```swift
                        SidebarTabChildRow(item: item, pane: pane, hover: false, controller: controller)
```

換成：

```swift
                        SidebarTabChildRow(item: item, pane: pane,
                                           hover: hoverEnabled && controller.model.hoveredTabRowID == item.id,
                                           controller: controller)
```

`SidebarTabChildRow` 裡，把 `StateIndicator(...)` 那 3 行換成（滑鼠在上面、而且可以關時，讓出位置給關閉按鈕）：

```swift
                StateIndicator(display: item.display, unread: item.unread,
                               pulse: controller.model.pulseMotion, reduceMotion: controller.model.reduceMotion,
                               waiting: item.waiting)
                    .opacity(hover && item.closable ? 0 : 1)
```

在 `.onTapGesture { controller.clickTabRow(pane) }` 之後加：

```swift
            // 在列的點擊手勢之外：點關閉按鈕不會先切換到這個 tab。釘選的 tab 沒有關閉按鈕。
            .overlay(alignment: .trailing) {
                if hover && item.closable {
                    RowCloseButton(label: "Close \(item.title)", help: "Close Tab") {
                        controller.closeTabFromSidebar(pane)
                    }
                    .padding(.trailing, WorkspaceRow.closeTrailing)
                }
            }
            .onHover { inside in
                if inside { controller.model.hoveredTabRowID = item.id }
                else if controller.model.hoveredTabRowID == item.id { controller.model.hoveredTabRowID = nil }
            }
```

- [ ] **Step 6: 確認通過**

Run: `beat/changes/sidebar-tab-tree/dev.sh tabs`
Expected: `[tab tree: close]` 沒有 `FAIL` 行，`TABS EXIT: 0`。

- [ ] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/Model.swift App/Sources/LmuxUI/SidebarTabs.swift App/Sources/lmux-apptest/SidebarTabs.swift
git commit -m "feat(sidebar-tab-tree): 從 Tab 子列關閉 tab，規則與 tab 列相同"
```

---

### Task 10: 收尾

**Files:**
- Modify: `beat/changes/sidebar-tab-tree/features/sidebar-tab-tree.feature`
- Modify: `docs/features.md:27`

- [ ] **Step 1: 跑全部的 apptest**

Run: `beat/changes/sidebar-tab-tree/dev.sh apptest-full`（比 quick 久；逾時就用背景執行，看到 `APPTEST EXIT (full)` 才算跑完），跑完後 `beat/changes/sidebar-tab-tree/dev.sh new-failures full`
Expected: `NEW FAILURES: 0`、`MISSING CHECKS: 0`。`${TMPDIR:-/tmp}/sidebar-tab-tree/full.log` 裡有 `[tab tree:` 開頭的檢查，而且都是 `PASS`。
（full 比 quick 多跑 `--restore`、`--compat` 與第二次 `--sidebar`。Task 3 改了存檔格式，Task 6、8 改了 sidebar 的點擊位置，所以收尾跑 full。）

- [ ] **Step 2: 加 `@covered-by`**

在 feature 檔的每個場景（共 18 個，含 1 個場景大綱），標籤那一行（`@e2e ...`）與 `場景:`／`場景大綱:` 之間加一行：

```gherkin
  # @covered-by: App/Sources/lmux-apptest/SidebarTabs.swift
```

Run: `node /Users/jamis.liao/.claude/plugins/cache/beat/beat/0.7.0/skills/design/scripts/lint-features.mjs beat/changes/sidebar-tab-tree/features/sidebar-tab-tree.feature`
Expected: `0 error(s)`。

- [ ] **Step 3: 更新 `docs/features.md:27`**

把：

```markdown
- Workspaces in the sidebar with branch and directory. Hover a row and `×` closes it; `⌘`-click or `⇧`-click picks several.
```

換成：

```markdown
- Workspaces in the sidebar with branch and directory. Hover a row and `×` closes it; `⌘`-click or `⇧`-click picks several. A workspace with two or more tabs has a disclosure arrow: expand it to list its tabs with each one's own status, click a tab to jump to it.
```

Run: `if [ -f scripts/build-docs.py ]; then python3 scripts/build-docs.py --check; fi`
Expected: 結束碼 0（2026-11-17 這個 worktree 沒有 `scripts/build-docs.py`，所以不會執行任何檢查）。失敗時把輸出貼進回報，不要自己改 `build-docs.py`。

- [ ] **Step 4: 重新截圖，列出要請使用者手動確認的項目**

Run: `beat/changes/sidebar-tab-tree/dev.sh shots`
Expected: `SHOTS: 8`。

回報時附上 8 個 PNG 的完整路徑，並原樣列出下面的項目，請使用者開 app 確認。這些是自動檢查看不出來的：

1. Tab 子列的高度（26pt）與縮排（18pt）看起來對嗎？
2. 選取中的 workspace 列與有標示的 Tab 子列同時有底色，分得出來嗎？視窗不在最前面時呢？
3. 標題很長時有沒有正確截斷？
4. 滑鼠移到 Tab 子列上：× 出現、狀態圖示讓出位置，移開後恢復。
5. 展開與收合：下面的 workspace 列是滑動，不是跳過去。系統開「減少動態效果」時直接切換。
6. tab 很多（例如 15 個）時展開，sidebar 可以捲動。
7. 拖曳已展開的 workspace 列：拖的途中 Tab 子列跟著移動。
8. ⌘ 多選 2 個 workspace（其中 1 個展開）一起拖：順序正確。
9. 一個 tab 在等使用額度重設時：workspace 列與它的 Tab 子列都顯示時鐘。

後續（不在這個 change）：README 的示意圖（`assets/screenshots/hero-*.png`）的場景有 4 個 tab 的 workspace（`Hero.swift:725-728`），下次跑 `App/scripts/readme.sh` 重新產生時會多出展開箭頭。

- [ ] **Step 5: Commit**

```bash
git add beat/changes/sidebar-tab-tree/features/sidebar-tab-tree.feature docs/features.md
git commit -m "docs(sidebar-tab-tree): 場景加上 @covered-by，features.md 說明展開 tab"
```
