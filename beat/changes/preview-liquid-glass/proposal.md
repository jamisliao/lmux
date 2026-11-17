# Apple Liquid Glass 與雙欄介面 UI 原型

## Why

1. **改正式 Swift 程式前，需要先確認新版面與玻璃層次**：目前 lmux 只有左側 sidebar（含 **workspace** 清單與底部的 **通知 bar**），預覽與 agent 資訊散在分割區裡。要試「**右側 Inspector** + 橫跨視窗底部的 **視窗底部狀態列** + 雙主題 Apple Liquid Glass」的配置，直接改 SwiftUI 來回調整太慢，先做一份瀏覽器或 **預覽 tab** 點開就能互動的 **UI 原型** 比較快。
2. **確認拖曳調整面板大小時怎麼避免 `backdrop-filter` 掉幀**：多個玻璃圖層同時開高斯模糊時，拉動 sidebar、**右側 Inspector** 或 **通知 bar** 若每一個 frame 都重算模糊，GPU 負擔很大。原型用來實測「拖曳時暫停模糊、放開後恢復」的做法，以及系統開啟「減少透明度」與「減少動態效果」時的降級畫面。

## What Changes

1. **新增單檔 UI 原型 `preview-mockup.html`**
   - 單一 HTML 檔（內嵌 CSS 與原生 JavaScript），不靠打包工具或外部套件。
2. **淺色／深色雙主題 Liquid Glass 與無障礙降級**
   - 預設是淺色主題（High-Key Crystal），可從頂部控制列切到深色主題（Obsidian Midnight）。
   - 分層設定視窗、sidebar／**右側 Inspector**、標題列／**視窗底部狀態列** 與內層卡片的透明度、模糊半徑、頂部 1px 亮邊與內外陰影。
   - 支援 `prefers-reduced-transparency`（停用全部玻璃圖層的模糊濾鏡，sidebar 與 **右側 Inspector** 改用不透明底色）與 `prefers-reduced-motion`（縮短動畫與過渡時間）。
3. **面板收合、拖曳調大小與拖曳期間停用模糊**
   - 標題列按鈕、頂部控制列與快捷鍵可收合或展開 sidebar（`⌘B`）與 **右側 Inspector**（`⌥⌘B`，**視窗底部狀態列** 最右邊也有一顆 `⌥⌘B` 鈕）；收合時標題列對應按鈕取消亮起。
   - sidebar 與 **右側 Inspector** 可水平拖曳調寬（有最小與最大寬度限制）；**通知 bar** 可垂直拖曳調高、拉到過低時自動收合，也能點 **摘要列**、雙擊調整手把或點頂部控制列的「Inbox 收合」鈕切換收合／展開。
   - 拖曳任一調整手把期間，全部玻璃面板與卡片暫停模糊濾鏡與過渡動畫，sidebar 與 **右側 Inspector** 改用對應主題的不透明底色；放開滑鼠後恢復。
4. **右側 Inspector、視窗底部狀態列與通知互動**
   - **右側 Inspector** 可在「即時預覽」、「變更 (Diff)」與「執行記錄」三個分頁間切換。「即時預覽」分頁可切換 HTML、Markdown（`README.md`）與 Swift（`GlassTokens.swift`）三份示意內容；點重新整理鈕 `↻` 會切回 HTML 並讓 HTML 檔案鈕亮起，點 `↗` 則在新分頁開啟目前頁面。
   - **視窗底部狀態列** 顯示目前 agent 模型、最近工具呼叫、Context Window 用量與 Git 變更統計；點各區塊會展開已收合的 **右側 Inspector** 並切到對應分頁。
   - 點 sidebar 的 **workspace** 列可切換選取狀態；點 **通知 bar** 裡的未讀 **通知卡片** 會改成已讀、扣減未讀數（歸零時隱藏未讀徽章與鈴鐺紅點），並選取對應的 **workspace** 列。

## 不變

- `App/` 與 `Core/` 下的 Swift 與 Ghostty 程式碼不變。
- 正式產品既有的 **預覽 tab**（`beat/features/preview/`）與 **通知 bar** 規格不變。

## 先不做

- 不接真實的終端機 PTY、本機檔案監看或 Git 指令。
- 畫面中僅供版面示意的按鈕不做動作：視窗紅黃綠鈕、新增 workspace `⌘T`、分割窗格 `⌘D` / `⇧⌘D`、終端機分頁新增／關閉、歷史搜尋框篩選、預覽位址列的上一頁／下一頁鈕。
- 不實作 `⌘⇧R` 快捷鍵（收合 **右側 Inspector** 固定用 `⌥⌘B`）。

## Impact

- **檔案**：新增根目錄 `preview-mockup.html`；更新 `GLOSSARY.md` 與 `beat/changes/preview-liquid-glass/` 下的規格檔。不動正式 Swift 原始碼，合併上游零衝突。
- **現有 `preview-mockup.html` 待修正的 6 個問題（排入 `/beat:plan` → `/beat:apply`）**：
  1. `preview-mockup.html:289-298` 殘留沒有 selector 的孤立 CSS 屬性與重複的 `.ctrl-pill-btn:hover`。
  2. `.is-resizing` 與 `prefers-reduced-transparency` 把 `.sidebar-inbox-accessory`（`:2117`）誤寫成不存在的 `.inbox-accessory-panel`（`:167`, `:203`）；`.is-resizing` 漏了 `.mockup-controls`、`.window-footer`、`.terminal-pane`、`.inspector-card`、`.preview-browser-card`、`.preview-viewport-card`（`prefers-reduced-transparency` 也漏了後五個，且三張卡片在 `:1590`, `:1727`, `:1845` 寫死 `blur(16px)`）；另外 `.lmux-window`（`:335`）、`.titlebar`（`:372`）、`.sidebar-left`（`:527`）、`.sidebar-right`（`:1516`）漏寫 `-webkit-backdrop-filter`。
  3. 淺色主題拖曳底色 selector 誤寫成 `[data-theme="light"] body.is-resizing`（`:180-181`，多了一個空白），因為 `data-theme="light"` 直接掛在 `<body>` 上，導致淺色模式拖曳時匹配不到而閃成深色底。
  4. 執行記錄分頁的 `.activity-bash`（`:2770`）沒有對應的 CSS 樣式（CSS 只寫了 `.activity-read`、`.activity-edit`、`.activity-run`）。
  5. 即時預覽位址列的重新整理鈕 `↻`（`:2320`, `:2597`）呼叫 `switchPreviewFile('html')` 時沒傳按鈕元素，切到 `README.md` 或 `GlassTokens.swift` 後按 `↻`，畫面回到 HTML 但上方的 `.preview-file-chip.active` 還停在舊檔案鈕（`:2489-2493`）。
  6. 即時預覽卡片與模擬訊息寫 `blur(36px)` / `36px blur`（`:2285`, `:2365`, `:2520`, `:2642`），與實際 `--glass-blur: blur(40px)` 不一致。
- **測試**：在 `/beat:plan` 與 `/beat:apply` 新增 `App/scripts/liquid-glass-mockup-check.swift`（比照 `App/scripts/preview-webkit-check.swift`，用 macOS `WKWebView` 載入 `preview-mockup.html` 檢查 DOM 互動、計算樣式與上述 6 項修正）。
