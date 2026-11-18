# 正式 App 1:1 Apple Liquid Glass 雙欄工作台與 Core 遙測管線 — 技術設計

## Approach

本設計在保留根目錄設計原型 [preview-mockup.html](../../preview-mockup.html) 作為驗收與視覺對照基準的前提下，從 `Core/` 資料層到 `App/` 三欄原生介面全面實現 1:1 的 Apple Liquid Glass 工作台，同時延續 lmux「不包裹 CLI、只旁聽並以 AppKit/Metal 呈現極致流暢終端機」的核心架構。

```mermaid
flowchart TB
  subgraph Core ["Core Telemetry & Session Layer"]
    Hooks["LmuxHooks (PreToolUse / PostToolUse / Stop)"]
    ClaudeT["LmuxTranscript (model / message.usage incremental)"]
    CodexT["CodexRollout (token_count / context_window)"]
  end

  subgraph Services ["App Services (Background / MainActor)"]
    Tel["AgentTelemetryAggregator (per-Pane model, turns, tokens, tools)"]
    Git["GitDiffService (debounced async git status + diff hunks)"]
    Prev["WorkspacePreviewCoordinator (WKWebView + PreviewScheme)"]
  end

  subgraph Chrome ["1:1 Liquid Glass Window Chrome"]
    TB["Titlebar 44pt (Controls + Centered Workspace Chip + Split/⌥⌘B)"]
    Left["Left Glass Sidebar 260pt (Cards + Filter + History + NotificationBar)"]
    Center["Center Canvas (Rounded Glass Pane + Pane Tab Strip + SurfaceView)"]
    Right["Right Glass Inspector 320pt (即時預覽 | 變更 Diff | 執行記錄)"]
    Footer["Window Footer 32pt (Agent/Tool/Turn | Context Gauge | Git/Preview/⌥⌘B)"]
  end

  Hooks --> Tel
  ClaudeT --> Tel
  CodexT --> Tel
  Tel --> Footer
  Tel --> Right
  Git --> Footer
  Git --> Right
  Git --> TB
  Prev --> Right
  Chrome -->|"isResizing drag guard"| Chrome
```

### 1. Core Telemetry 擴充（`Core/LmuxHooks` + `Core/LmuxTranscript`）
- **資料模型（`Core/Sources/LmuxTranscript/AgentTelemetry.swift` 等）**：
  - `AgentTelemetrySnapshot`：`model: String?`、`turnCount: Int`、`contextUsedTokens: Int`、`contextLimitTokens: Int`、`systemPromptTokens: Int`、`historyTokens: Int`、`cacheReadTokens: Int`、`estimatedCostUSD: Double?`、`lastUpdated: Date?`。
  - **Claude JSONL 增量抽取**：擴充 `Transcript.Outline` / 增量掃描器（`outlineKeys` 與 `message` 解析保留 `model` 與 `usage` 物件），累加最新 API 回應的 `input_tokens`、`cache_read_input_tokens`、`cache_creation_input_tokens` 與 `output_tokens` 算出目前 Context 佔用與快取命中率，並依模型家族對應預設 Context 上限（如 Claude 200k / 1M）與費率估算。對無 `usage` 欄位或半行損毀的 JSON 安全略過，絕不崩潰或產生負值。
  - **Codex Rollout 增量抽取**：擴充 `CodexRollout` 解析 `token_count` / `turn_context` 裡的 `model_context_window`、`last_token_usage` 與 `model`，統一匯入 `AgentTelemetrySnapshot`。
- **即時 Tool Call 串流（`Core/LmuxHooks/HookEvent.swift` + `AgentState.swift` / `LmuxUI/Agent.swift`）**：
  - `HookEvent` 在 `PreToolUse`、`PostToolUse`、`PostToolUseFailure` 已有 `toolName`、`toolArgument`、`toolUseID`、`sentAtNanos`。
  - 在 `Pane`（或 `PaneTelemetryModel`）維護上限 50 筆的 `ToolCallEntry` 環形陣列：`id`（`toolUseID` 或 fallback）、`name`、`category`（`read` / `edit` / `bash` / `search` / `other` 對應圖示與色彩）、`detail`、`startedAtNanos`、`durationMs: Int?`、`status`（`.running` / `.succeeded` / `.failed`）。

### 2. 背景 `GitDiffService` 與檔案掃描（`App/Sources/LmuxUI/GitDiffService.swift`）
- 追蹤目前選取 `Workspace` 的作用目錄（取 `focusedPane?.cwd` 或最近已知有效目錄），切換 **workspace** 或收到 Hook／檔案觸發時在背景佇列 debounce（200ms）執行 `git rev-parse --is-inside-work-tree`、`git status --porcelain=v1`、`git diff --numstat`（含 staged 與 unstaged）與受限行數的 `git diff --unified=3`（避免超大二進位檔卡頓，超過上限顯示截斷提示）。
- 發布 `@Observable` `GitDiffSnapshot`：`isGitRepo: Bool`、`branch: String?`、`totalAdded: Int`、`totalDeleted: Int`、`files: [GitDiffFile]`（每檔含 `path`、`status`、`added`、`deleted`、`lines: [DiffLine]`）。非 Git 目錄設定 `isGitRepo = false`，讓 **右側 Inspector** 與 **底部狀態列** 呈現清晰空狀態。
- 同服務（或協作 helper）同步提供目前工作區目錄下最多 N 筆熱門 **可預覽檔案**（`README.md`、近期修改的 `.md` / `.html` / `.swift` 等），供 **右側 Inspector**「即時預覽」快速切換列使用。

### 3. 1:1 Apple Liquid Glass Token（`App/Sources/LmuxTokens/Tokens.swift`）
- 對照 [preview-mockup.html](../../preview-mockup.html) 重調淺色（High-Key Crystal）與深色（Obsidian Midnight）全套色彩與版面常數：
  - **標題列與雙側邊欄玻璃**：更新 `sidebarTint`、`windowBackgroundTint`、`titlebarBackground`、`rightSidebarTint`、`glassCard`、`glassCardHover`、`glassCardSelected`、`glassSurfaceRecessed`、`specularHighlight`（淺色 `0.88–0.95`、深色 `0.18–0.32`）、`glassBorder`（淺色 `0.70–0.82` 白邊、深色 `0.10–0.16` 白邊）、`activePaneRing`（`0x0A84FF` / Nord focus blue 搭配外圍微光）。
  - **狀態藥丸色彩**：`statusRunningPill`（藍底+藍字）、`statusNeedsInputPill`（琥珀底+字）、`statusDonePill`（綠底+字）、`statusIdlePill`（中性玻璃）。
  - **尺寸常數**：`titlebarHeight = 44`、`footerHeight = 32`、`leftSidebarWidth = 260`（180–400）、`rightInspectorWidth = 320`（240–500）、`paneCornerRadius = 10`、`paneGap = 8`、`paneTabStripHeight = 30`。
  - **對比與降級**：保留 `AccessibilityTests` / `liquid-glass-app-check` 對全部選取列、狀態藥丸、搜尋框與 **底部狀態列** 文字對比 >= 4.5:1 的檢核；`accessibilityDisplayShouldReduceTransparency` 與 `Motion.reduceMotion` 全域生效。

### 4. 三欄＋狀態列視窗骨架與 1:1 原生元件（`App/Sources/LmuxUI/` + `LmuxNotificationBar/`）
- **`RootView.swift` 視窗版面引擎**：
  - 全域最上方為統一的 **`44pt` Glass Titlebar**（覆蓋整窗寬度，包含交通燈、左側欄按鈕 `⌘B` / `⌃⌘S`、鈴鐺與未讀角標、`+` 新增 **workspace**、置中 `WorkspaceChipBadge`、右側分割按鈕 `⌘D` / `⇧⌘D` 與 `⌥⌘B`）。
  - 最下方保留完整 **`32pt` Glass Window Footer（`WindowFooterView`）**，左右對齊 `bounds.width`。
  - 中間區塊 (`H = totalHeight - titlebar - footer`) 由左至右為：
    1. 左側邊欄：`SidebarBackdrop`（含 `NSVisualEffectView` + 高光邊）+ `LeftSidebarHeader`（`工作區` 標題 + 狀態篩選按鈕）+ `SidebarView`（Workspace 清單 + History 搜尋列）+ `NotificationBar` 配件 + 垂直調整手把 `SidebarResizeHandle`。
    2. 中央終端畫布：可留適當邊距顯示玻璃底座（`paneGap`），內部配置各圓角分割窗格。
    3. 右側分割調整手把 `RightInspectorResizeHandle` + **右側 Inspector**（`RightInspectorBackdrop` + `RightInspectorView`，預設展開，寬度持久化於 `layout.json`）。
- **Workspace 卡片重構（`Sidebar.swift`）**：
  - 卡片改為圓角 `8pt` 玻璃卡片，左側 `3pt` 垂直 Accent 條，第 1 行左側標題／右側狀態藥丸（`⚡ 執行中` / `🔔 需要確認` / `✓ 測試通過` / `閒置`；hover 時保留快速關閉 ×），第 2 行左側最新 agent 摘要／目錄、右側相對時間。
  - **100% 保留** `SidebarTabChildren`（Tab 子樹展開）、`⌘`/`⇧` 多選、`SidebarRowMotion` 拖曳重排與右鍵選單，加上標題列篩選（全部／進行中／需要確認）。
- **History 與 NotificationBar（`History.swift`、`NotificationBar.swift`、`NotificationCard.swift`）**：
  - `HistorySection` 固定置於 Workspace 清單底部、**通知 bar** 上方，採用玻璃膠囊搜尋框（`⇧⌘H` 快捷與既有搜尋結果清單向上／浮層展開不遮擋下方通知列）。
  - `NotificationBar` 呈現圓角玻璃配件框（上緣 `6pt` 膠囊拖曳把手、Inbox 標題 + 鈴鐺紅點 + 未讀藍數膠囊 + 收合箭頭、圓角玻璃 **通知卡片** 含未讀藍點、標題、經過時間、`workspace · branch` 與兩行摘要）。
- **中央圓角分塊與 `Pane Tab Strip`（`PaneViews.swift`、`Tabs.swift`）**：
  - 每個終端分割葉節點改包進帶有圓角 `10pt`、`1px` 玻璃邊框與聚焦 `active-ring` 藍框光暈的容器內。
  - 上方統一渲染 **`Pane Tab Strip`（`30pt`）**，左側列出分頁膠囊（活躍狀態亮點、標題、關閉 `×`）與 `+` 開分頁鈕，右側列出向右分割、向下分割與關閉分塊鈕；既有分頁拖拽重排／跨格分割、雙擊改名、點選切換與 `libghostty` 鍵盤轉發維持完整行為。
- **右側 Inspector（`RightInspectorView.swift` + `InspectorPreviewHost.swift`）**：
  - Segmented Control 切換三個分頁：
    - **即時預覽**：Browser 網址卡（`‹` `›` `↻`、檔案圖示、目前相對路徑、`LIVE` 綠色標籤、外開 `↗`）、快速檔案 chip 列、受控 `WKWebView` 視埠（復用 `PreviewView` / `PreviewScheme` / `PreviewWatcher` 與安全規則）與底部狀態列（`WKWebView Pipeline (Metal)` / `Auto-reload on save`）。
    - **變更 (Diff)**：Working Tree 摘要卡片（分支、檔案數、`+adds -dels`）+ 逐檔 Diff 卡片（紅刪除 `-` / 綠新增 `+`  monospace 等寬列）；點擊檔案標題可於需要時開啟預覽。
    - **執行記錄**：Card 1「Context Window (Token 負載)」（百分比徽章、藍紫漸層進度條、已用/上限、2×2 明細：系統／輸入、對話輸出、Cache 命中、估計費用）；Card 2「最近執行的工具 (Tool Calls)」即時串流列表（工具類型彩色圖示方塊、工具名、參數摘要、耗時 / 進行中狀態）。
- **全域 `拖曳降級` 協調**：
  - 左側欄寬度、`右側 Inspector` 寬度、**通知 bar** 高度、`SplitContainerView` 分割線及 `NSWindow` live resize 皆統一驅動 `AppBackdropCoordinator`（同步設定左／右／頂／底四個 `NSVisualEffectView` 背景為 `isResizing = true`），並保留 `didResignKey`、`didResignActive`、`@GestureState` 與 `viewWillMove(toWindow: nil)` 全方位自動清理。

---

## Key Decisions

1. **雙軌預覽模型（Right Inspector Live Preview + Split Preview Tab）** — 詳見 [docs/adr/0002-dual-track-inspector-preview.md](../../../docs/adr/0002-dual-track-inspector-preview.md)。
   - **開啟選單**第一項新增「在右側欄即時預覽」，保留「在新 tab 預覽」；同時按住 `⌃⌘` 點擊終端機路徑可略過選單直接開成 **預覽 tab**。
2. **單層 Backdrop Material 搭配半透明覆層與 `拖曳降級` 守護** — 詳見 [docs/adr/0003-single-backdrop-glass-simulation.md](../../../docs/adr/0003-single-backdrop-glass-simulation.md)。
   - 僅大面板底層掛載 `NSVisualEffectView`，清單卡片與分頁以半透明色票＋高光邊框實現同等視覺，拖曳時全面轉不透明實底。
3. **Hook 即時事件 + JSONL 增量解析雙軌收集 Agent 遙測** — 詳見 [docs/adr/0004-hybrid-hook-and-jsonl-telemetry.md](../../../docs/adr/0004-hybrid-hook-and-jsonl-telemetry.md)。
   - 確保工具狀態毫秒級反映，同時具備模型／Token／Cache／費用精確統計，無需輪詢外部程式。
4. **相容既有關閉與快速鍵習慣**：
   - `⌘B`（與原型一致）與既有 `⌃⌘S` 皆綁定左側欄開關；`⌥⌘B` 綁定 **右側 Inspector** 開關；`layout.json` 新增之 `inspectorVisible`、`inspectorWidth`、`inspectorTab` 為 optional 欄位，舊版檔案預設展開顯示 `preview`（`320pt`）。

---

## Components

| 檔案 / 模組 | 職責與改動重點 |
|---|---|
| `Core/Sources/LmuxTranscript/AgentTelemetry.swift`、`Transcript.swift`、`CodexRollout.swift` | 增量抽取 Claude `model`/`usage` 與 Codex `token_count`/`model_context_window`，定義 `AgentTelemetrySnapshot` 與容錯測試。 |
| `Core/Sources/LmuxHooks/HookEvent.swift`、`AgentState.swift` | 擴充工具呼叫開始／結束／失敗追蹤結構（`ToolCallEntry`）與 Turn 計數統計，支援即時串流。 |
| `App/Sources/LmuxTokens/Tokens.swift`（與 `design/Tokens.swift`） | 實作 1:1 淺／深雙主題 Liquid Glass 色彩、尺寸（`44/32/260/320`）、圓角、光暈邊框與狀態藥丸色票。 |
| `App/Sources/LmuxUI/GitDiffService.swift` | 背景非同步執行 `git status` / `git diff`，彙整分支、增刪行總計、Diff hunks 與工作區可預覽檔案快捷清單。 |
| `App/Sources/LmuxUI/AgentTelemetryStore.swift`、`Agent.swift` | 彙整 Hook 與 Transcript/Rollout 增量結果，提供 per-Pane／per-Workspace 的 `@Observable` 模型、Turn、Token 與 Tool Calls。 |
| `App/Sources/LmuxUI/RootView.swift`、`WindowFooterView.swift`、`TitlebarView.swift` | 重構為 44pt Unified Titlebar（含置中膠囊）+ 三欄工作區 + 32pt 全寬 **底部狀態列**，統一 `isResizing` 拖曳降級協調。 |
| `App/Sources/LmuxUI/Sidebar.swift`、`History.swift` | 升級 **workspace** 玻璃卡片（垂直色條、狀態藥丸、篩選鈕，保留多選／拖曳／子樹）；將 History 搜尋移動至 **通知 bar** 上方。 |
| `App/Sources/LmuxUI/PaneViews.swift`、`Tabs.swift` | 升級中央分割葉為 `10pt` 圓角卡片 + Focus `active-ring` 藍框與整合式 **Pane Tab Strip**。 |
| `App/Sources/LmuxUI/RightInspectorView.swift`、`OpenMenu.swift`、`Persistence.swift` | 實作 **右側 Inspector** 三分頁（即時預覽含 `PreviewView` 複用／Diff／執行記錄）；更新 **開啟選單** 與持久化欄位。 |
| `App/Sources/LmuxNotificationBar/NotificationBar.swift`、`NotificationCard.swift` | 調整 **通知 bar** 為玻璃圓角配件、未讀藍點與鐘形紅點回饋，同步全域 `isResizing`。 |
| `Core/Tests/`、`App/Sources/lmux-apptest/`、`App/scripts/` | 補齊 Telemetry 單元測試、更新 `OpenMenu` 測試與 `LiquidGlass` / Inspector / Footer / Resize E2E 驗收測試。 |
