# 正式 App 1:1 Apple Liquid Glass 雙欄工作台與 Core 遙測管線

## Why

1. **正式 App 需要與設計原型 `preview-mockup.html` 達到 1:1 視覺與工作流對齊**：先前的保守調整僅在舊版 Nord 版面加入極淡邊框與 `1pt` 微光，實際啟動後仍與舊版 UI 高度相似，未能呈現 **High-Key Crystal（淺色）** 與 **Obsidian Midnight（深色）** 的通透玻璃層次、置中 Titlebar 資訊膠囊、**Pane Tab Strip**、**右側 Inspector** 與 **底部狀態列**。
2. **原型中的檢視與監控面板需要真實後端資料支撐**：**右側 Inspector** 的「變更 (Diff)」、「執行記錄」與 **底部狀態列** 的模型、Turn 數、Context Window Token 進度條與 Tool Call 即時串流，目前在 `Core/` 與 `LmuxUI` 尚未暴露完整的資料管線，必須補齊後才能成為真正可用的原生功能。

## What Changes

1. **補齊 Core Agent 遙測與 Git Diff 資料管線（`Core/LmuxHooks`、`Core/LmuxTranscript`、`LmuxUI`）**
   - 擴充讀取 Claude Code transcript（`.jsonl`）的模型名稱與 `usage`（input、cache read/creation、output tokens）及 Codex rollout 的 `token_count` / `model_context_window`，並結合 `HookEvent`（`PreToolUse` / `PostToolUse` / `PostToolUseFailure`）產出 **Agent 遙測**（目前模型、Turn 計數、Context 已用與上限、Cache 命中、估算費用與最近 Tool Call 即時串流）。
   - 新增背景非同步 `GitDiffService`（切換工作區或檔案變更時以 debounce 執行 `git status` / `git diff`），彙整分支名稱、增刪行總計與逐檔 diff hunks；無作用中 Agent 或非 Git 目錄時顯示清楚空狀態（`—` / 提示訊息）。

2. **重構 `LmuxTokens` 為 1:1 雙主題 Apple Liquid Glass 設計系統（`App/Sources/LmuxTokens/Tokens.swift`）**
   - 建立淺色 **High-Key Crystal** 與深色 **Obsidian Midnight** 兩套完整的玻璃底色、物理高光邊緣（Specular Highlight）、微透立體邊框、狀態藥丸色票、**active-ring** 焦點光暈，以及 `44pt` Titlebar、`32pt` **底部狀態列**、`260pt` 左側欄、`320pt` **右側 Inspector** 尺寸常數，並確保主要／次要文字在雙主題皆通過 WCAG AA 對比檢核，同時支援系統「減少透明度」與「減少動態效果」。

3. **實作 1:1 原生三欄玻璃工作台、置中 Titlebar 與雙軌即時預覽（`LmuxUI`、`LmuxNotificationBar`）**
   - **44pt 統一玻璃 Titlebar**：左側配置系統視窗按鈕、左側欄切換鈕（同時支援 `⌘B` 與既有 `⌃⌘S`）、鈴鐺未讀角標與 `+` 新增 **workspace**；中央配置置中玻璃資訊膠囊（狀態燈、名稱、Git 分支與目錄路徑）；右側配置向右分割（`⌘D`）、向下分割（`⇧⌘D`）與 **右側 Inspector** 切換鈕（`⌥⌘B`）。
   - **左側玻璃欄（預設 `260pt`，可調範圍 `180–400pt`）**：上方加入「工作區」標題與狀態篩選按鈕；**workspace** 列改為圓角玻璃卡片、左側 `3pt` 垂直彩色 Accent 條、狀態藥丸、摘要文字與相對時間，同時完整保留右鍵選單、`⌘`/`⇧` 多選、拖曳排序與 Tab 子樹；History 搜尋框移至 **通知 bar** 上方；**通知 bar** 保留拖曳調整手把膠囊、未讀藍點與玻璃通知卡片。
   - **中央圓角終端畫布**：每個分割格採用圓角玻璃卡片與 **active-ring** 焦點光暈，並固定顯示整合式 **Pane Tab Strip**（分頁圓點、標題、關閉鈕、`+` 開分頁鈕與右側分割／關閉操作列），內部仍使用 `libghostty` Metal 原生終端渲染。
   - **右側 Inspector（預設展開 `320pt`，可調範圍 `240–500pt`，`⌥⌘B` 切換）**：提供 Segmented Control 分頁（`即時預覽` / `變更 (Diff)` / `執行記錄`）。**雙軌預覽**：終端機點擊檔案的 **開啟選單** 新增「在右側欄即時預覽」作為首選預設項目，同時保留「在新 tab 預覽」與完整 Split **預覽 tab** 功能；`即時預覽` 分頁提供簡易瀏覽位址列（`‹` `›` `↻`、檔名與 `LIVE` 標記、外開 `↗`）、工作區常用檔案快速切換列與受控 `WKWebView`。
   - **32pt 全寬底部狀態列**：統一顯示 Agent 模型徽章、最近 Tool Call、Turn 數、Context Window Token 進度條、Git 分支 `+adds -dels` 與「即時預覽」/`⌥⌘B` 快捷鈕；點擊任一指標可展開並切換至 **右側 Inspector** 對應分頁。

4. **全面板 `拖曳降級` 守護**
   - 拖曳調整左側欄寬度、**右側 Inspector** 寬度、**通知 bar** 高度、窗格分割線或縮放視窗期間，所有 `NSVisualEffectView` 背景統一進入 `拖曳降級`（暫停背景模糊合成並切換不透明實底），放開或視窗失焦時立即恢復。

## Impact

- **修改模組**：
  - `Core/LmuxHooks/`、`Core/LmuxTranscript/`（擴充模型、Token Usage、Tool Call 歷史與即時串流欄位與測試）
  - `App/Sources/LmuxTokens/Tokens.swift`（及 `design/Tokens.swift`）
  - `App/Sources/LmuxUI/`（Titlebar、Workspace 清單、History 位置調整、Pane 圓角／Tab Strip、**右側 Inspector**、**底部狀態列**、`GitDiffService`、`OpenMenu`、`Persistence` 相容擴充）
  - `App/Sources/LmuxNotificationBar/`（玻璃卡片、未讀點與外觀同步）
  - `App/Sources/lmux-apptest/` 與 `App/scripts/`（更新並擴充對照測試）
  - `beat/CONTEXT.md`、`beat/features/preview/open-menu.feature`（建立 `.orig` 備份後更新）
- **不變**：
  - `App/Sources/LmuxTerminal/` 與 `vendor/ghostty` 終端機核心繪圖路徑完全不變。
  - 既有的鍵盤快捷鍵（含 `⌃⌘S`、`⇧⌘H`、`⌘T`、`⌘D`、`⇧⌘D`）、`MarkdownHTML` CSP 安全隔離、與舊版 `layout.json` 持久化皆維持向後相容。
- **驗證方式**：
  - `swift test --package-path Core` 驗證 Telemetry 與 Transcript/Hook 解析單元測試。
  - `beat/changes/preview-liquid-glass/dev.sh check` 驗證 Token、WCAG AA 對比、`--liquid-glass` App 測試與 `preview-mockup.html`。
  - `App/scripts/apptest.sh --quick`、`--preview` 等相關整合測試，最後以 `App/scripts/bundle.sh` 重建 `App/build/lmux.app` 並實機啟動驗證。
