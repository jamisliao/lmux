# 設計：在 sidebar 展開 workspace 的 tab

行號是 2026-11-17 在 commit `0fc8bed` 查的。

## Approach

### 畫面結構

```
SidebarView
 └── ForEach(model.workspaces)
      └── SidebarRowMotion            ← 既有；量整組的 frame、負責拖曳位移
           └── VStack
                ├── WorkspaceRow      ← 既有；內容不改
                │    └── overlay：展開箭頭（panes.count >= 2 才有）
                └── ForEach(ws.panes) ← 只在 ws.tabsExpanded && panes.count >= 2 時
                     └── SidebarTabChildRow
                          ├── 類型圖示（終端機／預覽）
                          ├── 標題
                          ├── StateIndicator（既有元件；預覽 tab 沒有）
                          └── RowCloseButton（既有元件；hover 才有，釘選的 tab 沒有）
```

### 1. 狀態與儲存

- `Workspace` 加一個屬性 `tabsExpanded = false`。`Workspace` 是 `@Observable`，sidebar 會跟著更新。
- `LayoutFile.WorkspaceState`（`App/Sources/LmuxUI/Persistence.swift:29`）加選填欄位 `tabsExpanded: Bool?`：
  - 展開時存 `true`，收合時不存（與 `pinned` 的寫法相同）。
  - 解碼用 `decodeIfPresent`。這是 `App/Sources/LmuxUI/Persistence.swift:18` 註解的規定：後加的欄位必須選填，舊檔才讀得進來。
  - `init` 的新參數給預設值 `nil`，`App/Sources/LmuxUI/CmuxImport.swift:520` 的呼叫不用改。
- `snapshotLayout()`（`App/Sources/LmuxUI/Persistence.swift:117`）寫出、`restoreLayout()`（`App/Sources/LmuxUI/Persistence.swift:228`）讀回。
- 箭頭與 Tab 子列的顯示條件是 `ws.tabsExpanded && ws.panes.count >= 2`。tab 數掉到 1 時不改 `tabsExpanded`，所以回到 2 個以上會回到原本的狀態。

### 2. Tab 子列的資料來源

| 顯示什麼 | 用什麼 | 出處 |
|---|---|---|
| 有哪些 tab、順序 | `ws.panes`（由左到右、由上到下，每格依 tab 列順序） | `App/Sources/LmuxUI/Model.swift:484`、`App/Sources/LmuxUI/Model.swift:426` |
| 類型 | `pane.preview != nil` 是預覽，否則終端機 | `Model.swift` 的 `Pane.preview` |
| 標題 | `pane.headerTitle`，空字串時用 "Terminal" | `App/Sources/LmuxUI/Model.swift:301` |
| agent 狀態 | `StateIndicator(display: pane.display, unread: …)` | `App/Sources/LmuxUI/Model.swift:253`、`App/Sources/LmuxUI/Sidebar.swift:350` |
| 標示 | `ws.id == model.selectedID && ws.focusedPane === pane` | `Model.swift` 的 `Workspace.focusedPane` |

- 標題用 `headerTitle`，不用 `pane.title`：`pane.title` 是終端機自己送的標題（OSC 0/2）；`headerTitle` 才依序取任務名稱、終端機標題、工作目錄的資料夾名稱。預覽 tab 的 `title` 是檔名（`App/Sources/LmuxUI/Controller.swift:575`）。
- tab 列會替同名的 tab 加區別字尾（`Workspace.headerTitles`），Tab 子列不加。兩處的標題在同名時會不同。
- `unread` 的傳法與 workspace 列一致：有標示的那一列傳 0，其他傳 `pane.unread`。
- 標示的底色用既有的 `T.Colors.rowSelected`（`App/Sources/LmuxTokens/Tokens.swift:134`），視窗不是 key window 時用 `rowSelectedInactive`，與 workspace 列的 `pillColor`（`App/Sources/LmuxUI/Sidebar.swift:333`）相同。

### 3. 操作

| 操作 | 呼叫 | 說明 |
|---|---|---|
| 點展開箭頭 | 新增 `toggleTabsExpanded(_ ws:)`：切換 `ws.tabsExpanded`，然後 `scheduleSave()` | 唯一新增的 controller 方法 |
| 點 Tab 子列 | 既有的 `focus(pane)` | `App/Sources/LmuxUI/Controller.swift:1027`：已經會把被蓋住的 tab 顯示出來、切換 workspace、設定焦點 |
| 點關閉按鈕 | `runningProcess(pane) != nil` 時先 `focus(pane)`，再 `requestClosePane(pane)` | `App/Sources/LmuxUI/MessageActions.swift:814`、`App/Sources/LmuxUI/MessageActions.swift:826` |

- 不新增 `selectTabFromSidebar`：`focus(_:)` 已經做完同樣的事。
- 不直接呼叫 `closePane`（`App/Sources/LmuxUI/Controller.swift:842`）：它不檢查釘選，也不詢問。
- 關閉前先 `focus` 的原因：`requestClosePane` 把詢問卡片顯示在那個 tab 上。那個 tab 在沒選取的 workspace 或被蓋住時，卡片不在畫面上。tab 列的 `requestCloseTab`（`App/Sources/LmuxUI/Tabs.swift:156`）用 `selectTab` 做同一件事，但 `selectTab` 不會切換 workspace。
- 釘選的 tab 不畫關閉按鈕，與 tab 列的 `showsClose`（`App/Sources/LmuxUI/Tabs.swift:628`）一致。

### 4. 展開箭頭的位置與點擊

- 用 `.overlay` 加在 `WorkspaceRow` 上，寫法比照既有的關閉按鈕（`App/Sources/LmuxUI/Sidebar.swift:207`：overlay 在列的點擊手勢之外，點它不會先選取 workspace）。
- 放在列左邊的留白裡：`rowInsetX` 8pt 加 `rowPaddingX` 8pt，共 16pt（`App/Sources/LmuxTokens/Tokens.swift:305`、`App/Sources/LmuxTokens/Tokens.swift:307`）。`WorkspaceRowContent` 不改，所以單一 tab 的列、onboarding 的預覽（`App/Sources/LmuxUI/HooksSetup.swift:357`）、既有的像素測試（`App/Sources/lmux-apptest/Sidebar.swift:151`）都不受影響。
- **未實測**：16pt 的留白放不放得下一個看得清楚的箭頭。實作第一步先截圖確認。放不下時改成在 `WorkspaceRowContent` 的色塊左邊加一格，這會讓所有列的內容右移，上面 3 處都要跟著調整。
- 箭頭收合時朝右、展開時朝下。

### 5. 動畫

- 展開與收合比照 History 區塊的寫法（`App/Sources/LmuxUI/History.swift:430`）：`.animation(T.Motion.reduceMotion ? nil : .easeOut(duration: T.Motion.historyExpand), value: ws.tabsExpanded)`。
- 不新增 Motion token。系統開啟「減少動態效果」時不做動畫，與 sidebar 其他動畫一致。

### 6. 拖曳排序

- **預期 `SidebarReorder.swift` 不用改（推論，未實測）**：每列的 frame 是在 `SidebarRowMotion` 的 content 外層量的（`App/Sources/LmuxUI/Sidebar.swift:122`）。Tab 子列放進同一個 content，frame 就包含它們的高度；`SidebarDragGeometry` 的位移用每列 frame 的高度算（`App/Sources/LmuxUI/SidebarReorder.swift:110`）。
- 拖曳手勢掛在 `WorkspaceRow` 上（`App/Sources/LmuxUI/Sidebar.swift:186`），Tab 子列不掛，所以拖 Tab 子列不會移動 workspace。
- 被拖起來的那一組的底色與陰影畫在 `SidebarRowMotion` 的背景，會包住整組。

### 7. 尺寸

- `LmuxTokens.Layout` 新增 `tabChildRowHeight` 與 `tabChildIndent`。起始值 26pt 與 18pt 沿用上一版設計，**未實測**，實作時截圖調整。
- 標題字型用既有的 `T.Typography.rowSubtitle`。

### 8. 測試

- 場景都放在 `lmux-apptest --sidebar`（`App/Sources/lmux-apptest/Sidebar.swift:52` 的 `runSidebar()`，由 `App/scripts/apptest.sh:145` 執行）。
- `rowPoint`（`App/Sources/lmux-apptest/Tests.swift:51`）用固定列高推算第 n 列的位置。要加上前面已展開 workspace 的 Tab 子列高度，否則展開後點擊位置會錯。
- `Hero.swift` 的 `rowHeight`（`App/Sources/lmux-apptest/Hero.swift:780`）有同樣的假設。預設收合，而且那支測試不展開，預期不受影響（推論，未實測）。
- 拖曳：既有的 `SidebarDragGeometry` 單元檢查（`App/Sources/lmux-apptest/ZoomClearReorder.swift:285`）加一組高度不同的 frame。
- 重開：存出的內容比照 `App/Sources/lmux-apptest/PreviewPersistence.swift:44`，用 `snapshotLayout()` 檢查。讀回（`restoreLayout()`）的檢查寫法未查證，`/beat:plan` 時再定。

## 邊緣情況

| 情況 | 行為 | 依據 |
|---|---|---|
| workspace 有 1 個終端機 tab 與 1 個預覽 tab，展開後重開 lmux | 預覽 tab 不還原，剩 1 個 tab，沒有箭頭。`tabsExpanded` 仍存著，之後開第 2 個 tab 就是展開的 | `App/Sources/LmuxUI/Persistence.swift:124` |
| workspace 只有預覽 tab | 整個 workspace 不存，展開狀態跟著消失 | 同上 |
| 點的 tab 所在的 workspace 正在放大某一格 | 先取消放大再切換 | `focus(_:)` 內的 `unzoom` |
| 從 Tab 子列關到最後剩 1 個 tab | 箭頭與 Tab 子列消失，workspace 還在 | 顯示條件 `panes.count >= 2` |
| 多選 workspace 時點別的 workspace 的 Tab 子列 | 多選結束 | `App/Sources/LmuxUI/Controller.swift:728` 的 `select(_:focusing:)` |
| 舊版 `layout.json` | 全部收合 | `decodeIfPresent` |

## Key Decisions

1. **只有兩層，不依分割分組**
   - 使用者 2026-11-17 選擇。分割出來的 tab 與同一格的 tab 列在同一層。
   - ADR 檢查：只改畫面，改回三層不動儲存格式 → 不難還原 → 不需 ADR。
2. **展開狀態放在 `Workspace`，不放在 `AppModel` 的集合**
   - 放在 workspace 上，workspace 關閉時狀態自然消失，不用另外清理；儲存也跟著既有的 `WorkspaceState`。
   - 另一個做法是 `AppModel.expandedWorkspaceIDs: Set<String>`（上一版設計）：要在關閉 workspace 時清掉 id，`LayoutFile` 頂層也要多一個欄位。
   - ADR 檢查：欄位是選填的，改放別處時舊檔仍讀得進來 → 不難還原 → 不需 ADR。
3. **預設收合；tab 數掉到 1 再回來維持原狀態；展開時 workspace 列不變**
   - 使用者 2026-11-17 三項都選了這個做法。
   - ADR 檢查：都是一兩行的顯示條件 → 不難還原 → 不需 ADR。
4. **切換與關閉沿用既有入口，不新增**
   - `focus(_:)` 與 `requestClosePane(_:)` 已經處理被蓋住的 tab、放大、釘選、詢問。新寫一條路徑會漏掉其中幾項（上一版設計直接呼叫 `closePane`，漏了釘選與詢問）。
   - ADR 檢查：沒有真正的取捨 → 不需 ADR。
5. **tab 列保留**
   - Tab 子列不提供右鍵選單、重新命名、拖曳排序；這些留在 tab 列。
   - ADR 檢查：之後要加不受這次設計限制 → 不需 ADR。

狀態只有展開與收合 2 個，不做狀態機驗證。

## Components

| 檔案 | 改動 |
|---|---|
| `App/Sources/LmuxUI/Model.swift` | `Workspace` 加 `tabsExpanded`。 |
| `App/Sources/LmuxUI/Persistence.swift` | `WorkspaceState` 加選填的 `tabsExpanded`；`snapshotLayout` 寫、`restoreLayout` 讀。 |
| `App/Sources/LmuxUI/Controller.swift` | 加 `toggleTabsExpanded(_:)`。 |
| `App/Sources/LmuxUI/Sidebar.swift` | `SidebarView` 的每組加 `VStack` 與 Tab 子列；`WorkspaceRow` 加展開箭頭的 overlay；新增 `SidebarTabChildRow`。 |
| `App/Sources/LmuxTokens/Tokens.swift` | `Layout` 加 `tabChildRowHeight`、`tabChildIndent`。 |
| `App/Sources/lmux-apptest/Sidebar.swift` | 加本 feature 的場景。 |
| `App/Sources/lmux-apptest/Tests.swift` | `rowPoint` 算入 Tab 子列的高度。 |
| `App/Sources/lmux-apptest/ZoomClearReorder.swift` | `SidebarDragGeometry` 加高度不同的案例。 |
| `App/Sources/LmuxUI/SidebarReorder.swift` | 預期不改（見「拖曳排序」）。 |

## 未查證

1. 16pt 留白放不放得下展開箭頭（見「展開箭頭的位置與點擊」）。
2. `SidebarReorder.swift` 是否真的不用改（見「拖曳排序」）。
3. Tab 子列的高度 26pt 與縮排 18pt。
4. workspace 列與有標示的 Tab 子列同時有底色時，看起來是否清楚。
5. 舊版 lmux 讀到含 `tabsExpanded` 的 `layout.json` 是否正常（依 Swift `Codable` 略過未知 key 的預設行為推論）。
