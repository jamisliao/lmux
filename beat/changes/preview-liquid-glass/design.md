# 設計：Apple Liquid Glass 與雙側邊欄介面重設計 UI 原型

行號是 2026-11-17 在 commit `9d15b95` 查的。

## Approach

### 整體結構

`preview-mockup.html` 是單一自足 HTML 檔案，所有樣式、DOM 與互動腳本皆內嵌其中，不依賴外部 CSS／JS 框架或打包器：

```
body[data-theme="light" | "dark"]
 ├── .mockup-controls                  ← 頂部互動控制列（主題切換、左/右側欄、Inbox 收合）
 └── .lmux-window#window-frame         ← 模擬 macOS 視窗外框（頂部 ::before 1px Specular 高光）
      ├── header.titlebar              ← 紅黃綠鈕、#tb-toggle-left、Branch chip、#tb-toggle-right
      ├── main.window-body
      │    ├── aside#sidebar-left      ← 180–400px；#handle-left 水平拖曳調寬
      │    │    ├── .workspace-list    ← 4 筆示意 workspace 列（點擊 .ws-row 切換 .selected）
      │    │    ├── .sidebar-history-row ← 搜尋框（視覺示意）
      │    │    └── #sidebar-inbox     ← 通知 bar；38–340px，#handle-inbox 垂直拖曳／雙擊收合
      │    ├── section.content-canvas  ← 雙欄終端機分割區（各自含 .pane-tab-strip，靜態示意）
      │    └── aside#sidebar-right     ← 右側 Inspector；240–500px，#handle-right 水平拖曳調寬
      │         ├── .segmented-control ← 分頁切換：即時預覽 / 變更 (Diff) / 執行記錄
      │         └── #tab-content-context ← 依目前分頁動態替換內容
      └── footer#terminal-footer       ← 32px 全寬視窗底部狀態列；點擊各區呼叫 openRightPanel()
```

### 1. 雙主題與三層 Liquid Glass Token 系統

遵循「透明度傳達視窗層級」的原則，依主題將顏色與模糊強度集中於 CSS custom properties：

| 層級 / Token | Dark (`:root`, `:11-68`) | Light (`[data-theme="light"]`, `:73-103`) | 對應元件 |
|---|---|---|---|
| 視窗底色 `--bg-window-tint` | `rgba(16, 20, 28, 0.82)` | `rgba(255, 255, 255, 0.28)` | `.lmux-window` (`:334`) |
| 側邊欄 `--glass-sidebar` | `rgba(20, 24, 34, 0.84)` | `rgba(255, 255, 255, 0.34)` | `.sidebar-left` (`:526`)、`.sidebar-right` (`:1515`) |
| 標題／狀態列 `--glass-titlebar` | `rgba(18, 22, 32, 0.86)` | `rgba(255, 255, 255, 0.38)` | `.titlebar` (`:371`)、`.window-footer` (`:1330`) |
| 內凹終端底 `--glass-surface-recessed` | `rgba(11, 14, 20, 0.94)` | `rgba(255, 255, 255, 0.44)` | `.terminal-pane` (`:1031`)、預覽網址列與程式碼底框 |
| 卡片表面 `--glass-card` | `rgba(255, 255, 255, 0.045)` | `rgba(255, 255, 255, 0.32)` | `.inspector-card`、`.preview-*-card`、`.diff-file-card` |
| 主模糊 `--glass-blur` | `blur(40px) saturate(210%) contrast(104%)` | `blur(40px) saturate(240%) contrast(105%) brightness(103%)` | `.lmux-window`、`.sidebar-left`、`.sidebar-right` |
| 次模糊 `--glass-blur-subtle` | `blur(24px) saturate(180%)` | `blur(24px) saturate(200%) brightness(102%)` | `.mockup-controls`、`.titlebar`、`.terminal-pane`、`.window-footer` |
| 內層卡片微模糊（待統一 token） | 目前寫死 `blur(16px)` | 目前寫死 `blur(16px)` | `.inspector-card` (`:1590`)、`.preview-browser-card` (`:1727`)、`.preview-viewport-card` (`:1845`) |

- **預設主題**：`<body data-theme="light">`（`:1936`）。`setTheme('light' | 'dark')`（`:2436`）更新 `document.body` 的 `data-theme` 屬性並同步 `#btn-theme-light` 與 `#btn-theme-dark` 的 `.active` 狀態。
- **Specular Edge & 光學排版**：`.lmux-window` 邊框與 `.lmux-window::before` 頂部 1px 漸層亮線（`:343-357`）、`.window-footer::before` 頂部高光（`:1341-1355`）模擬頂部環境入射光；`.window-title`、`.section-title`、`.workspace-row-title`、`.tab-title` 套用 `font-optical-sizing: auto; letter-spacing: -0.015em`（`:186-192`）。
- **待統一設計**：內層卡片目前寫死 `backdrop-filter: blur(16px)`，應抽為 CSS 變數 `--glass-blur-card: blur(16px)`，讓後續「拖曳效能守護」與「減少透明度」能在 `:root`／媒體查詢中一次歸零。

### 2. 佈局控制、快捷鍵與右側 Inspector

| 功能 | 實作入口 | 行為說明 |
|---|---|---|
| 左右側欄收合 | `toggleSidebar('left' \| 'right')`（`:2443-2455`） | 切換 `.collapsed`（以負 margin + `translateX` + `opacity: 0` + `pointer-events: none` 搭配 `--spring-smooth` 動畫），並同步 `#tb-toggle-left`／`#tb-toggle-right` 的 `.active`。 |
| 鍵盤快捷鍵 | `window.addEventListener('keydown', ...)`（`:2458-2469`） | `Cmd/Ctrl + B`（無 Alt/Shift）切換左側欄；`Opt + Cmd/Ctrl + B` 切換右側欄，皆呼叫 `e.preventDefault()`。 |
| 右側 Inspector 分頁 | `switchRightTab(tabName, el)`（`:2574-2785`） | 依 `preview`、`diff`、`trace`（亦接受 `context`）更新 `.segment-btn.active` 並重新渲染 `#tab-content-context` 內容。 |
| 即時預覽檔案切換 | `switchPreviewFile(type, el)`（`:2489-2571`） | 切換 `html`（`preview-mockup.html`）、`markdown`（`README.md`）、`swift`（`App/Sources/LmuxUI/GlassTokens.swift`），同步 `#preview-url-text` 與 `#preview-viewport-content`。 |
| 視窗底部狀態列聯動 | `openRightPanel(tabName)`（`:2478-2486`） | 若 `#sidebar-right` 處於 `.collapsed`，先移除 `.collapsed` 並啟用 `#tb-toggle-right`，再呼叫 `switchRightTab(tabName)`。 |

### 3. 通知 bar (Inbox) 與 Workspace 聯動

- **Workspace 選取**：`selectWorkspace(el)`（`:2472-2475`）移除所有 `.ws-row.selected` 並為被點擊列加上 `.selected`。
- **Inbox 高度與收合**：
  - `setupInboxResize()`（`:2835-2882`）監聽 `#handle-inbox` 的 pointer 事件，將高度夾緊於 `38px`–`340px`（`startHeight - delta`，向上拖拉變高）。當 `newHeight <= 42` 時加上 `#sidebar-inbox.collapsed`（CSS 將收合高度鎖在 `38px !important`，`:878-880`），否則移除。
  - 雙擊 `#handle-inbox` 或點擊 `.inbox-summary-row` 觸發 `toggleInboxCollapse()`（`:2885-2893`）；展開時重設高度為 `175px`。
- **通知已讀連動**：`openInboxNotification(id, workspaceName)`（`:2896-2911`）將未讀卡片 `#inbox-card-<id>` 從 `.unread` 轉為 `.read` 並呼叫 `updateUnreadBadge()`（`:2913-2924`）重算未讀數、於歸零時隱藏 `#inbox-badge` 與 `#inbox-dot-indicator`；接著掃描 `.ws-title` 文字包含 `workspaceName` 的 `.ws-row` 並呼叫 `selectWorkspace(row)`。

### 4. 拖曳效能守護（`.is-resizing`）與無障礙降級

- **左右側欄水平拖曳**：`setupResize(handleId, sidebarId, isLeft)`（`:2788-2832`）以 `pointerdown` / `setPointerCapture` / `pointermove` / `pointerup` / `pointercancel` 實作：
  - 左側欄寬度夾緊於 `180px`–`400px`，同步 `--sidebar-left-width`。
  - 右側欄寬度夾緊於 `240px`–`500px`，同步 `--sidebar-right-width`。
  - 拖曳期間於 `document.body` 加上 `.is-resizing`（Inbox 垂直拖曳另加 `.resizing-row` 切換 `cursor: row-resize`），結束或取消時移除。
- **效能守護原理**：在 `body.is-resizing` 狀態下，停用 `user-select`、強迫全域游標一致（避免游標移出 7px handle 時閃爍），並停用所有毛玻璃面板與卡片的 `backdrop-filter` 與 `transition`，讓側邊欄改以不透明／高不透明度純色底（Dark `--bg-resizing-fallback: rgba(18, 22, 30, 0.98)`；Light `rgba(245, 247, 252, 0.98)`）渲染。
- **無障礙媒體查詢**：
  - `@media (prefers-reduced-transparency: reduce)`（`:195-217`）：將 `--glass-blur` 與 `--glass-blur-subtle`（及補齊後的 `--glass-blur-card`）設為 `none !important`，停用全部玻璃元件的 `backdrop-filter`，並將側邊欄背景降級為實體色 `#141822`（Dark）與 `#F3F5F9`（Light）。
  - `@media (prefers-reduced-motion: reduce)`（`:219-225`）：將全域動畫與過渡持續時間壓縮為 `0.01ms !important`。

### 5. 待 `/beat:apply` 修正的現況缺陷（對照 commit `9d15b95`）

交叉核對程式碼後，`preview-mockup.html` 目前有以下 5 處與本設計預期不符的細節，留待 `/beat:plan` 列入任務並在 `/beat:apply` 修正：

1. **孤立 CSS 語法錯誤與重複規則（`:289-298`）**：`[data-theme="dark"] .ctrl-pill-btn:hover` 結束括號後殘留未附著 selector 的 `background: rgba(0, 0, 0, 0.05); border: 1px solid rgba(0, 0, 0, 0.08); }` 及重複的 `.ctrl-pill-btn:hover`。應清除這段殘留片段。
2. **`.is-resizing` 與 `prefers-reduced-transparency` selector 誤寫與遺漏（`:165-173`, `:200-208`）**：
   - CSS 誤寫了不存在的 `.inbox-accessory-panel`，應改為實際 DOM 使用的 `.sidebar-inbox-accessory`（`:2117`）。
   - 兩處清單皆遺漏 `.window-footer`、`.terminal-pane`、`.inspector-card`、`.preview-browser-card`、`.preview-viewport-card`；且後三者的 `backdrop-filter: blur(16px)`（`:1590`, `:1727`, `:1845`）應改為 `var(--glass-blur-card)` 並於 `.is-resizing` 與 `prefers-reduced-transparency` 一併停用。
3. **淺色主題拖曳 fallback selector 多了後代空白（`:180-183`）**：`[data-theme="light"] body.is-resizing .sidebar-left` 與 `[data-theme="light"] body.is-resizing .sidebar-right` 將 `[data-theme="light"]` 寫成 `body` 的祖先，但 `data-theme="light"` 其實直接設在 `<body>`（`:1936`）上，導致淺色模式拖曳時無法匹配並誤吃深色的 `--bg-resizing-fallback`。應改為 `body[data-theme="light"].is-resizing .sidebar-left` 與 `body[data-theme="light"].is-resizing .sidebar-right`。
4. **`.activity-bash` 缺少圖示底色樣式（`:2770` vs `:1686-1688`）**：`switchRightTab('trace')` 產生的第三筆工具呼叫使用 `.activity-bash`，但 CSS 只定義了 `.activity-read`、`.activity-edit`、`.activity-run`。應補上 `.activity-bash`（或共用 `.activity-run` 樣式）。
5. **預覽卡片／模擬文字與實際 blur token 不一致（`:2285`, `:2365`, `:2520`, `:2642`）**：畫面文案寫 `36px blur` / `blur(36px)`，與實際 `--glass-blur: blur(40px)` 不符，應統一為 `blur(40px)`。

### 6. 測試與驗證設計

比照既有的 `App/scripts/preview-webkit-check.swift` 模式，在 `/beat:plan` 與 `/beat:apply` 新增不需 Node／npm 的獨立 macOS `WKWebView` Swift 檢查腳本 `App/scripts/liquid-glass-mockup-check.swift`（單檔 `swiftc` 編譯執行，視窗置於螢幕外）：

- **`@e2e` 互動驗證**（在 `WKWebView` 載入 `preview-mockup.html` 後注入點擊、鍵盤事件與 `PointerEvent` 序列並檢查 DOM 與 `getComputedStyle`）：
  - 預設主題為 `light`、切換 `dark`／`light` 後 `data-theme` 與按鈕 `.active` 正確更新。
  - 左右側欄透過標題列按鈕、頂部控制列與模擬 `Cmd+B`／`Opt+Cmd+B` `KeyboardEvent` 收合／展開同步。
  - 觸發 `pointerdown` → `pointermove` → `pointerup` 驗證寬度與高度夾緊、`body.classList.contains('is-resizing')` 時所有玻璃層 `backdropFilter` / `webkitBackdropFilter` 計算值皆為 `none`、淺色模式下側邊欄背景為 `rgba(245, 247, 252, 0.98)`（而非深色 fallback）、放開後恢復，以及 Inbox 拖曳至 `<= 42px` 自動收合、雙擊重設 `175px`。
  - Workspace 選取切換、Inbox 未讀點擊由 `2 -> 1 -> 0` 隱藏徽章／紅點與點擊已讀不扣減且聯動選取 workspace。
  - Right Inspector 三個分頁與即時預覽三個檔案切換，以及從收合狀態點擊 Footer 五個區塊自動展開並跳至目標分頁。
- **`@behavior` 樣式與規則檢查**（由同支檢查腳本透過 DOM `document.styleSheets` 與 CSS 文字／規則樹檢查）：
  - 無孤立無效 CSS 區塊、`.activity-bash` 具備有效配色規則、所有預覽文案與 `--glass-blur` 一致為 `40px`。
  - `@media (prefers-reduced-transparency: reduce)` 與 `@media (prefers-reduced-motion: reduce)` 規則完整涵蓋所有玻璃層元件與 `.sidebar-inbox-accessory`（`CSSMediaRule` 檢查）。

## Key Decisions

1. **維持單檔自足 `preview-mockup.html`，不拆分成多檔或導入前端建置工具**
   - 理由：原型需能讓開發者直接雙擊或透過 lmux 既有的 **預覽 tab** 即開即看，多檔或 Vite/npm 建置會提高體驗與維護門檻。
   - 替代方案：拆成 HTML + CSS + JS 多檔或引入打包工具（不利單檔預覽分享）。
   - ADR 檢查：只影響單一原型檔、不牽涉跨 change 技術鎖定、隨時可拆分 → 不難還原 → **不需 ADR**。
2. **將本規格定位為「UI 原型規格」，不寫入 `App/` 正式 Swift 改動**
   - 理由：此分支目的在於版面與材質探索驗證，尚未決定將右側 Inspector 與 Footer 原封不動搬進 SwiftUI。
   - 替代方案：直接在本 change 同時規劃 SwiftUI `RootView`／`Tokens` 改動（會過早鎖定尚未定案的產品架構）。
   - ADR 檢查：未來若決定實作進 SwiftUI，會另開新 change 並獨立評估 ADR → 不跨 change 承諾 → **不需 ADR**。
3. **規格封存時採用獨立 capability 名稱（非 `beat/features/preview/`），並在 `GLOSSARY.md` 區分「右側 Inspector」與「預覽 tab」**
   - 理由：`beat/features/preview/` 已用於正式產品的終端機內 **預覽 tab** 規格，混用同一詞彙或目錄會造成 living documentation 語意衝突。
   - 替代方案：放在 `beat/features/preview/` 底下（容易讓人誤以為正式 app 已經實作右側欄預覽器）。
   - ADR 檢查：僅為文件目錄與術語組織，移動檔案成本低 → 不難還原 → **不需 ADR**。
4. **使用 macOS `WKWebView` Swift 腳本驗證原型，不引入 Node／Playwright 依賴**
   - 理由：本 repo 主體為 Swift／Zig，且已有 `App/scripts/preview-webkit-check.swift` 成熟範例，直接復用 `WKWebView` 還能測試最貼近 macOS Safari/WebKit 的 `-webkit-backdrop-filter` 計算結果。
   - 替代方案：安裝 Playwright + Chromium（增加環境依賴且與 macOS 原生 WebKit 渲染差異較大）。
   - ADR 檢查：僅影響原型驗證腳本，隨時可替換 → 不難還原 → **不需 ADR**。

狀態機檢查：各 UI 控制（主題 2 態、側邊欄收合 2 態、Inspector 分頁 3 態、拖曳狀態 2 態、通知已讀 2 態）皆為獨立且低複雜度狀態切換，無併發狀態轉換，**不需執行 `/statechart`**。

## Components

| 檔案 | 改動 |
|---|---|
| `preview-mockup.html` | 本原型主體；現況已存在，待 `/beat:plan` → `/beat:apply` 修正上述第 5 節 5 項 CSS／文案缺陷。 |
| `GLOSSARY.md` | 補齊 **UI 原型**、**右側 Inspector**、**視窗底部狀態列** 定義與關係，區分正式 **預覽 tab** 與 **通知 bar**。 |
| `App/scripts/liquid-glass-mockup-check.swift` | 待 `/beat:plan` → `/beat:apply` 新增的 `WKWebView` 自動化驗證腳本，覆蓋所有 `@e2e` 與 `@behavior` 場景。 |
| `App/`、`Core/`（正式程式碼） | 不改動。 |
