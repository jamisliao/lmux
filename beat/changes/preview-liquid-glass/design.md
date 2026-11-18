# 設計：Apple Liquid Glass 與雙欄介面 UI 原型

行號是 2026-11-17 在 commit `9d15b95` 查的。

## Approach

### 畫面結構

`preview-mockup.html` 是單一 HTML 檔，CSS、DOM 與 JS 都寫在同一個檔案裡，不靠外部框架或打包工具：

```
body[data-theme="light" | "dark"]
 ├── .mockup-controls                  ← 頂部控制列（淺色/深色主題、左側欄、右側欄 (Inspector)、Inbox 收合）
 └── .lmux-window#window-frame         ← 視窗外框（頂部 ::before 1px 亮邊）
      ├── header.titlebar              ← 紅黃綠鈕、#tb-toggle-left (⌘B)、Branch chip、#tb-toggle-right (⌥⌘B)
      ├── main.window-body
      │    ├── aside#sidebar-left      ← 左側 sidebar（180–400px；#handle-left 水平拖曳調寬）
      │    │    ├── .workspace-list    ← 4 列示意 workspace（點 .ws-row 切換 .selected）
      │    │    ├── .sidebar-history-row ← 搜尋框（僅外觀示意）
      │    │    └── #sidebar-inbox     ← 通知 bar（38–340px；#handle-inbox 垂直拖曳／雙擊收合）
      │    ├── section.content-canvas  ← 中央雙格終端機分割區（各自含 .pane-tab-strip，靜態內容）
      │    └── aside#sidebar-right     ← 右側 Inspector（240–500px；#handle-right 水平拖曳調寬）
      │         ├── .segmented-control ← 分頁切換：即時預覽 / 變更 (Diff) / 執行記錄
      │         └── #tab-content-context ← 依目前分頁替換 HTML
      └── footer#terminal-footer       ← 32px 視窗底部狀態列；點各區塊展開右側 Inspector 並切換分頁
```

### 1. 雙主題與三層 Liquid Glass Token

顏色與模糊半徑都放在 CSS 變數裡，依 `body` 的 `data-theme` 切換：

| 層級 / 變數 | Dark（`:root`，`:11-68`） | Light（`[data-theme="light"]`，`:73-103`） | 套用元件 |
|---|---|---|---|
| 視窗底色 `--bg-window-tint` | `rgba(16, 20, 28, 0.82)` | `rgba(255, 255, 255, 0.28)` | `.lmux-window`（`:334`） |
| 側邊面板 `--glass-sidebar` | `rgba(20, 24, 34, 0.84)` | `rgba(255, 255, 255, 0.34)` | `.sidebar-left`（`:526`）、`.sidebar-right`（`:1515`） |
| 標題／狀態列 `--glass-titlebar` | `rgba(18, 22, 32, 0.86)` | `rgba(255, 255, 255, 0.38)` | `.titlebar`（`:371`）、`.window-footer`（`:1330`） |
| 內凹底色 `--glass-surface-recessed` | `rgba(11, 14, 20, 0.94)` | `rgba(255, 255, 255, 0.44)` | `.terminal-pane`（`:1031`）、預覽位址列與程式碼底框 |
| 卡片底色 `--glass-card` | `rgba(255, 255, 255, 0.045)` | `rgba(255, 255, 255, 0.32)` | `.inspector-card`、`.preview-*-card`、`.diff-file-card` |
| 主模糊 `--glass-blur` | `blur(40px) saturate(210%) contrast(104%)` | `blur(40px) saturate(240%) contrast(105%) brightness(103%)` | `.lmux-window`、`.sidebar-left`、`.sidebar-right` |
| 次模糊 `--glass-blur-subtle` | `blur(24px) saturate(180%)` | `blur(24px) saturate(200%) brightness(102%)` | `.mockup-controls`、`.titlebar`、`.terminal-pane`、`.window-footer` |
| 內層卡片模糊 `--glass-blur-card` | `blur(16px)`（目前寫死，待抽成變數） | `blur(16px)`（目前寫死，待抽成變數） | `.inspector-card`（`:1590`）、`.preview-browser-card`（`:1727`）、`.preview-viewport-card`（`:1845`） |

- **預設主題**：`<body data-theme="light">`（`:1936`）。`setTheme('light' | 'dark')`（`:2436`）改 `document.body` 的 `data-theme`，並切換 `#btn-theme-light` 與 `#btn-theme-dark` 的 `.active`。
- **亮邊與字距**：`.lmux-window::before`（`:343-357`）與 `.window-footer::before`（`:1341-1355`）畫頂部 1px 漸層亮邊；標題類文字（`:186-192`）設 `font-optical-sizing: auto; letter-spacing: -0.015em`。

### 2. 面板收合、快捷鍵、右側 Inspector 與視窗底部狀態列

| 操作 | 呼叫函式 | 行為 |
|---|---|---|
| 收合／展開 sidebar | `toggleSidebar('left')`（`:2443`） | 入口：標題列 `#tb-toggle-left`（`:1976`）、頂部控制列「左側欄」鈕（`:1951`）、快捷鍵 `⌘B`（`:2459-2463`）。切換 `#sidebar-left.collapsed` 並同步 `#tb-toggle-left.active`。 |
| 收合／展開 **右側 Inspector** | `toggleSidebar('right')`（`:2449`） | 入口：標題列 `#tb-toggle-right`（`:2020`）、頂部控制列「右側欄 (Inspector)」鈕（`:1954`）、**視窗底部狀態列** 最右側 `⌥⌘B` 鈕（`:2425`）、快捷鍵 `⌥⌘B`（`:2465-2468`）。切換 `#sidebar-right.collapsed` 並同步 `#tb-toggle-right.active`。 |
| 切換 **右側 Inspector** 分頁 | `switchRightTab(tabName, el)`（`:2574-2785`） | `tabName` 為 `'preview'`、`'diff'`、`'trace'`（也接受 `'context'`），更新 `.segment-btn.active` 並重繪 `#tab-content-context`。 |
| 切換即時預覽示意檔 | `switchPreviewFile(type, el)`（`:2489-2571`） | `type` 為 `'html'`（`preview-mockup.html`）、`'markdown'`（`README.md`）、`'swift'`（`App/Sources/LmuxUI/GlassTokens.swift`），更新 `#preview-url-text`、`#preview-viewport-content` 與 `.preview-file-chip.active`。位址列 `↻`（`:2320`、`:2597`）呼叫 `switchPreviewFile('html')` 重置回 HTML；`↗`（`:2327`、`:2604`）呼叫 `window.open`。 |
| 點 **視窗底部狀態列** 各區 | `openRightPanel(tabName)`（`:2478-2486`） | 若 `#sidebar-right` 是 `.collapsed`，先展開並讓 `#tb-toggle-right` 亮起，再呼叫 `switchRightTab(tabName)`（agent 徽章、最近工具呼叫、Context 用量 → `'trace'`；Git 統計 → `'diff'`；即時預覽鈕 → `'preview'`）。 |

### 3. 通知 bar 與 Workspace 選取

- **選取 workspace**：`selectWorkspace(el)`（`:2472-2475`）清掉其他 `.ws-row.selected`，替被點的列加上 `.selected`。
- **調整與收合通知 bar**：
  - `setupInboxResize()`（`:2835-2882`）把 `#sidebar-inbox` 高度限制在 `38px`–`340px`（往上拖變高）。高度 `<= 42px` 時加上 `.collapsed`（CSS 鎖定 `height: 38px !important`，`:878-880`），大於 `42px` 時移除。
  - 點 `.inbox-summary-row`（`:2122`）、雙擊 `#handle-inbox`（`:2879`）或點頂部控制列「Inbox 收合」鈕（`:1957`）都呼叫 `toggleInboxCollapse()`（`:2885-2893`）；從收合展開時高度重設回 `175px`。
- **點擊通知卡片**：`openInboxNotification(id, workspaceName)`（`:2896-2911`）把未讀卡片 `#inbox-card-<id>` 的 `.unread` 換成 `.read`，呼叫 `updateUnreadBadge()`（`:2913-2924`）重算 `.inbox-card.unread` 數量（歸零時把 `#inbox-badge` 與 `#inbox-dot-indicator` 設成 `display: none`），再找出 `.ws-title` 含 `workspaceName` 的 `.ws-row` 呼叫 `selectWorkspace(row)`。已讀卡片被點時不改未讀數，照常選取對應的 **workspace**。

### 4. 拖曳效能守護（`.is-resizing`）與無障礙降級

- **水平拖曳調寬**：`setupResize(handleId, sidebarId, isLeft)`（`:2788-2832`）在 `pointerdown` 時替 `document.body` 加上 `.is-resizing`，`pointermove` 時把 `#sidebar-left` 限制在 `180px`–`400px`、`#sidebar-right` 限制在 `240px`–`500px`，`pointerup` / `pointercancel` 時移除 `.is-resizing` 與 `.resizing-row`。
- **拖曳期間停用模糊**：`body.is-resizing` 期間固定全域滑鼠游標（水平 `col-resize`，**通知 bar** 垂直拖曳加 `.resizing-row` 改 `row-resize`），並將所有玻璃圖層的 `backdrop-filter` / `-webkit-backdrop-filter` 與 `transition` 設為 `none !important`；`#sidebar-left` 與 `#sidebar-right` 改用不透明底色（深色 `rgba(18, 22, 30, 0.98)`，淺色 `rgba(245, 247, 252, 0.98)`）。
- **無障礙降級**：
  - `@media (prefers-reduced-transparency: reduce)`（`:195-217`）：將 `--glass-blur`、`--glass-blur-subtle`、`--glass-blur-card` 設為 `none !important`，停用全部玻璃圖層的 `backdrop-filter` / `-webkit-backdrop-filter`，並把 `#sidebar-left` 與 `#sidebar-right` 底色改為 `#141822`（深色）與 `#F3F5F9`（淺色）。
  - `@media (prefers-reduced-motion: reduce)`（`:219-225`）：將動畫與 transition 時間設為 `0.01ms !important`。

### 5. 現有 `preview-mockup.html` 待修正的 6 個問題（對照 commit `9d15b95`）

以下 6 處現況與本規格不一致，留在 `/beat:plan` 拆成任務、於 `/beat:apply` 修正：

1. **孤立的無效 CSS 與重複規則（`:289-298`）**：`[data-theme="dark"] .ctrl-pill-btn:hover` 右括號後面多出一段沒有 selector 的 `background: rgba(0, 0, 0, 0.05); border: 1px solid rgba(0, 0, 0, 0.08); }` 與重複的 `.ctrl-pill-btn:hover`，應刪除。
2. **模糊停用清單 selector 寫錯與缺漏（`:165-173`, `:200-208`, `:335`, `:372`, `:527`, `:1516`, `:1590`, `:1727`, `:1845`）**：
   - `:167` 與 `:203` 寫了不存在的 `.inbox-accessory-panel`，實際 DOM class 是 `.sidebar-inbox-accessory`（`:2117`）。
   - `body.is-resizing` 漏了 `.mockup-controls`、`.window-footer`、`.terminal-pane`、`.inspector-card`、`.preview-browser-card`、`.preview-viewport-card`；`prefers-reduced-transparency` 也漏了後五個。
   - `.inspector-card`（`:1590`）、`.preview-browser-card`（`:1727`）、`.preview-viewport-card`（`:1845`）寫死 `blur(16px)`，應抽成 `--glass-blur-card: blur(16px)`。
   - `.lmux-window`（`:335`）、`.titlebar`（`:372`）、`.sidebar-left`（`:527`）、`.sidebar-right`（`:1516`）只寫了 `backdrop-filter`，應補齊 `-webkit-backdrop-filter`。
3. **淺色主題拖曳底色 selector 多了空白（`:180-183`）**：`[data-theme="light"] body.is-resizing` 把 `[data-theme="light"]` 當成 `body` 的上層元素，但 `data-theme="light"` 就掛在 `<body>` 本身（`:1936`），導致淺色模式拖曳時吃不到淺色底而閃成深色底。應改為 `body[data-theme="light"].is-resizing .sidebar-left, body[data-theme="light"].is-resizing .sidebar-right`。
4. **`.activity-bash` 缺 CSS 樣式（`:2770` vs `:1686-1688`）**：`switchRightTab('trace')` 的第三筆工具呼叫用 `.activity-bash`，但 CSS 只定義 `.activity-read`、`.activity-edit`、`.activity-run`。應補上 `.activity-bash` 樣式。
5. **重新整理鈕 `↻` 未同步檔案按鈕亮起狀態（`:2320`, `:2489-2493`, `:2597`）**：`switchPreviewFile(type, el)` 只在有傳 `el` 時更新 `.preview-file-chip.active`；點 `↻` 呼叫 `switchPreviewFile('html')` 沒傳 `el`，導致從 `README.md` 或 `GlassTokens.swift` 按 `↻` 重置回 HTML 時，上方亮起的還是舊檔案鈕。應在未傳 `el` 時自動依 `type` 找到對應的 `.preview-file-chip` 設為 `.active`。
6. **畫面文字寫 `36px` 與實際 `40px` 變數不一致（`:2285`, `:2365`, `:2520`, `:2642`）**：預覽卡片與模擬輸出的文字寫 `blur(36px)` / `36px blur`，應改為與 `--glass-blur` 一致的 `blur(40px)` / `40px blur`。

### 6. 測試設計

比照 `App/scripts/preview-webkit-check*.swift`，以 `beat/changes/preview-liquid-glass/dev.sh check` 編譯並執行 6 支聚焦的 macOS `WKWebView` Swift 檢查模組（`App/scripts/liquid-glass-mockup-check*.swift`，每支皆小於 300 行，開螢幕外的 `WKWebView` 載入 `preview-mockup.html`）：

- **`@e2e` 場景檢查**：
  - 預設 `data-theme="light"`，點深色／淺色鈕切換主題與按鈕 `.active`。
  - sidebar 的 3 個收合入口（標題列、頂部控制列、`⌘B`）與 **右側 Inspector** 的 4 個收合入口（標題列、頂部控制列、**視窗底部狀態列** `⌥⌘B` 鈕、`⌥⌘B` 快捷鍵）收合／展開及 `#tb-toggle-left` / `#tb-toggle-right` 狀態同步。
  - 對調整手把派送 `PointerEvent` 驗證：拖曳中 `body.is-resizing` 讓所有玻璃圖層的 `backdropFilter` / `webkitBackdropFilter` 為 `none`、淺色模式拖曳時 sidebar 底色為 `rgba(245, 247, 252, 0.98)`、放開後恢復模糊；sidebar（`180–400px`）與 **右側 Inspector**（`240–500px`）寬度上下限夾緊；**通知 bar** 往上拖變高、往下拖到 `<= 42px` 自動加上 `.collapsed`、透過 **摘要列**／雙擊手把／頂部控制列 Inbox 鈕收合與展開回 `175px`。
  - 點 `.ws-row` 切換選取；點兩張未讀 **通知卡片** 依序讓未讀數 `2 -> 1 -> 0` 並隱藏 `#inbox-badge` 與 `#inbox-dot-indicator`，點已讀卡片不改未讀數，且都會選取對應的 **workspace**。
  - **右側 Inspector** 三個分頁切換、即時預覽三個檔案切換、點 `↻` 回到 `preview-mockup.html` 並讓 HTML 範例鈕亮起；從收合狀態點 **視窗底部狀態列** 5 個區塊自動展開 **右側 Inspector** 並切到目標分頁。
- **`@behavior` 場景檢查**：
  - 檢查 `document.styleSheets` 的 CSS 規則樹：確認無孤立壞規則、`.activity-bash` 有顏色定義、文案皆為 `40px`，且 `@media (prefers-reduced-transparency: reduce)` 與 `@media (prefers-reduced-motion: reduce)` 規則涵蓋全部玻璃圖層與 `.sidebar-inbox-accessory`。

## Key Decisions

1. **維持單一 HTML 檔 `preview-mockup.html`，不拆多檔或加打包工具**
   - 理由：雙擊檔案或用 lmux **預覽 tab** 就能直接打開看，不用先跑 build。
   - 替代方案：拆成 HTML / CSS / JS 多檔或引入 Vite。
   - ADR 檢查：只影響這個原型檔，隨時可拆 → 不難還原 → **不需 ADR**。
2. **本 change 只管 UI 原型與其驗證腳本，不動 `App/` 下的正式 Swift 程式**
   - 理由：右側 Inspector 與視窗底部狀態列還在設計驗證階段，確定要搬進正式 app 時再開獨立的 change。
   - ADR 檢查：沒有對正式產品做架構承諾 → **不需 ADR**。
3. **封存時放在獨立 capability（不進 `beat/features/preview/`），並在 `GLOSSARY.md` 區分「右側 Inspector」與「預覽 tab」**
   - 理由：`beat/features/preview/` 是正式產品的終端機內 **預覽 tab** 規格，混放會讓人誤以為正式 app 已有右側預覽面板。
   - ADR 檢查：只是文件目錄與用詞分類，很容易搬動 → **不需 ADR**。
4. **用 macOS `WKWebView` Swift 腳本做自動化檢查，不裝 Playwright**
   - 理由：repo 裡已有 `App/scripts/preview-webkit-check.swift` 可沿用，不用為了單一 HTML 原型引入 `node_modules`，而且直接測 WebKit 引擎。
   - ADR 檢查：只是一支測試腳本，隨時能換 → **不需 ADR**。

狀態機檢查：各個開關都是 2 到 3 個狀態的單純切換，沒有並行狀態轉換或重試流程，**不做狀態機驗證**。

## Components

| 檔案 | 改動 |
|---|---|
| `preview-mockup.html` | 原型主體；已修正第 5 節 6 項 CSS／JS／文案缺陷，並補齊 `Option+Cmd+B` `e.code` 辨識、`body.is-resizing` 游標覆蓋及 `setPointerCapture` 防護。 |
| `GLOSSARY.md` | 新增 **UI 原型**、**右側 Inspector**、**視窗底部狀態列** 定義，並說明與 sidebar、**預覽 tab**、**通知 bar** 的區別。 |
| `App/scripts/liquid-glass-mockup-check*.swift` | 新增 6 支 `WKWebView` 自動化檢查模組（主程式、樣式、面板收合、拖曳縮放、通知 bar、Inspector），覆蓋本規格全部 13 個 `@e2e` 與 `@behavior` 場景。 |
| `beat/changes/preview-liquid-glass/dev.sh` | 編譯並執行 `liquid-glass-mockup-check*.swift` 的輔助腳本。 |
| `App/`、`Core/`（正式程式碼） | 不改。 |
