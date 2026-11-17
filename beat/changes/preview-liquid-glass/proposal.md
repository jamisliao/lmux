# Apple Liquid Glass 與雙側邊欄介面重設計 UI 原型

## Why

1. **在動手改正式 SwiftUI／AppKit 程式前，需要先驗證新版版面與視覺層次**：目前 lmux 只有左側 **workspace** 列表與底部的 **通知 bar**，預覽與 agent 上下文仍分散在分割窗格裡。如果要探索「**右側 Inspector** + 橫跨視窗的 **視窗底部狀態列** + 雙主題 Apple Liquid Glass」的新介面配置，直接在 Swift 程式碼裡反覆試調成本太高，需要一個可在瀏覽器或 lmux **預覽 tab** 即開即測的互動式 **UI 原型**。
2. **驗證玻璃材質在大量拖曳調寬時的 GPU 開銷策略**：多層 `backdrop-filter` 高斯模糊在側邊欄或 **通知 bar** 拖曳調整尺寸時若逐影格重算，容易造成掉幀；原型需要實際驗證「拖曳期間暫停模糊、放開後立即恢復」的手感，以及對系統「減少透明度」與「減少動態效果」無障礙設定的降級表現。

## What Changes

1. **新增單檔互動式 UI 原型（`preview-mockup.html`）**
   - 自足的單一 HTML 檔案（內嵌 CSS 與 vanilla JavaScript），無需建置工具或外部相依即可在瀏覽器或 WebKit 檢視。
2. **Light／Dark 雙主題 Liquid Glass 視覺系統與無障礙降級**
   - 預設採用淺色高光模式（High-Key Crystal），可透過頂部控制列即時切換為深色模式（Obsidian Midnight）。
   - 建立分層玻璃透明度、Specular Edge 頂部高光邊線、內外陰影與文字視覺對比。
   - 支援系統 `prefers-reduced-transparency`（停用全部毛玻璃濾鏡並降級為不透明底色）與 `prefers-reduced-motion`（縮短過渡與動畫時間）。
3. **雙側邊欄佈局、快捷鍵收合與拖曳效能守護**
   - 標題列與頂部控制列支援收合／展開左側欄（`⌘B`）與右側欄（`⌥⌘B`），按鈕啟用狀態與側邊欄狀態保持同步。
   - 左右側欄支援水平拖曳調寬並限制最小／最大寬度；左側 **通知 bar** 支援垂直拖曳調高、拖至最小臨界值自動收合、雙擊調整手把或點擊 **摘要列** 切換收合／展開。
   - 拖曳任一側邊欄或 **通知 bar** 期間，全域進入調整狀態，暫停全部玻璃圖層的模糊重繪與過渡動畫，拖曳結束後立即恢復。
4. **右側 Inspector、視窗底部狀態列與通知互動**
   - **右側 Inspector** 透過分段切換列在「即時預覽」、「變更（Diff）」與「執行記錄」三個分頁間切換；「即時預覽」分頁可進一步切換模擬的 HTML、Markdown（`README.md`）與 Swift Token（`GlassTokens.swift`）檢視內容。
   - **視窗底部狀態列**橫跨整個視窗底部，顯示目前 agent 模型、最近工具呼叫、Context Window 使用量與 Git 變更摘要；點擊各區塊可自動展開 **右側 Inspector** 並切至對應分頁。
   - 點擊左側 **workspace** 列可切換選取焦點；點擊 **通知 bar** 裡的未讀 **通知卡片**，會標記為已讀、遞減並適時隱藏未讀徽章／鈴鐺紅點，並將對應 **workspace** 設為選取狀態。

## 不變

- `App/` 與 `Core/` 下的正式 Swift / Ghostty 程式碼完全不變，不影響現有應用程式行為與測試。
- 正式產品既有的 **預覽 tab**（`beat/features/preview/`）與左側 **通知 bar** 規格不變。

## 先不做

- 不實作模擬資料以外的真實終端機 PTY、檔案監看或 Git 指令整合。
- 不實作畫面中裝飾性控制項的動作（視窗紅黃綠控制鈕、新增 workspace `⌘T`、視窗分割 `⌘D` / `⇧⌘D`、終端機分頁新增／關閉、歷史紀錄搜尋框篩選、右側預覽器的上一頁／下一頁按鈕）。
- `⌘⇧R` 快捷鍵不納入實作（右側欄維持使用 `⌥⌘B`）。

## Impact

- **檔案範圍**：
  - 新增根目錄原型檔 `preview-mockup.html`。
  - 新增與重整 Beat 規格與詞彙：`beat/changes/preview-liquid-glass/`、`GLOSSARY.md`。
  - 不修改任何 Swift 原始碼，與上游 lmux 合併零衝突。
- **現況缺陷修正（待 `/beat:plan` → `/beat:apply` 處理）**：交叉檢視既有的 `preview-mockup.html` 後，發現 5 處與本規格預期行為不符之處需於後續實作階段修補：
  1. 樣式表第 289–298 行殘留無 selector 的孤立 CSS 片段與重複 `.ctrl-pill-btn:hover` 規則。
  2. `.is-resizing` 與 `prefers-reduced-transparency` 誤寫了不存在的 `.inbox-accessory-panel`（DOM 實為 `.sidebar-inbox-accessory`），且遺漏了 `.window-footer`、`.terminal-pane`、`.inspector-card`、`.preview-browser-card`、`.preview-viewport-card` 的 `backdrop-filter` 停用（後面三者寫死了 `blur(16px)` 而非使用 token）。
  3. 淺色主題拖曳 fallback selector 誤寫為 `[data-theme="light"] body.is-resizing`（多了一個後代空白，導致 `<body data-theme="light">` 永遠匹配不到，淺色模式拖曳時會閃成深色底）。
  4. 執行記錄分頁的 `bash` 工具項目（`.activity-bash`）缺少對應 CSS 色彩規則。
  5. 即時預覽分頁卡片與模擬記錄文字仍顯示 `blur(36px)`，與實際的 `40px` blur token 不一致。
- **驗證方式**：後續於 `/beat:plan` 與 `/beat:apply` 建立不依賴 Node/npm 的 macOS `WKWebView` Swift 檢查腳本（比照 `App/scripts/preview-webkit-check.swift` 模式），驗證主題切換、鍵盤快捷鍵、Inspector 分頁切換、Inbox 未讀數連動與 `.is-resizing` 樣式行為，並同步驗證上述 5 處修正。
