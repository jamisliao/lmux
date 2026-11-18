# 正式 App Apple Liquid Glass 視覺材質與拖曳零開銷守護

## Why

1. **正式 macOS App 需要同步落實 Apple Liquid Glass 層次與閱讀體驗**：先前已先透過根目錄的 **UI 原型**（`preview-mockup.html`）驗證了淺／深雙主題的玻璃表面層次、頂部 1pt 入射光高光（Specular Highlight）、微透卡片邊框與調整手把回饋，但正式 `lmux.app`（`LmuxTokens`、`LmuxUI`、`LmuxNotificationBar`）仍停留在舊版平面色塊與單純分隔線，啟動 App 時無法實際體驗新設計。
2. **拖曳調整面板與分割窗格時需要停用即時毛玻璃重繪以維持流暢度**：`SidebarBackdrop` 使用 `NSVisualEffectView(.sidebar, .behindWindow)` 進行背景混合；在拖曳調整 sidebar 寬度、**通知 bar** 高度、分割窗格比例或視窗縮放期間，若每個影格都重算毛玻璃模糊會增加合成器負擔。需要在拖曳期間自動切換為不透明實底（Opaque Fallback），放開後立即恢復毛玻璃。

## What Changes

1. **擴充 `LmuxTokens`（`App/Sources/LmuxTokens/Tokens.swift`）的 Liquid Glass 視覺 Token**
   - 在維持既有 Nord 色票與 WCAG AA 對比度（確保既有對比測試不退化）的前提下，新增淺／深雙主題 Liquid Glass 語意色與尺寸：
     - `Colors.specularHighlight`：頂部 1pt 物理入射光亮邊（淺色高光、深色微光）。
     - `Colors.glassBorder`：選取膠囊、搜尋框與 **通知卡片** 的微透立體邊框。
     - `Colors.dragHandlePill` / `Colors.dragHandlePillActive`：**通知 bar** 調整手把的膠囊指示條顏色（一般／hover 或拖曳中）。
     - `Layout.dragHandlePillWidth`、`Layout.dragHandlePillHeight`：調整手把膠囊尺寸常數。
2. **升級 Sidebar、標題列與通知 bar 的 Liquid Glass 視覺層次（`LmuxUI` + `LmuxNotificationBar`）**
   - `SidebarBackdrop`（`RootView.swift`）：在毛玻璃與色調層之上繪製頂部 1pt `specularHighlight`（全螢幕或無透明度降級時自動調整），讓 sidebar 具備 Liquid Glass 的物理邊緣光澤。
   - `WorkspaceRowContent`、`HistorySection`（`Sidebar.swift`, `History.swift`）與 `NotificationCard`（`NotificationCard.swift`）：選取中的 **workspace** 列、反白的 **通知卡片** 與 History 搜尋框加上 `glassBorder` 微透立體細邊框。
   - `BarResizeHandle`（`NotificationBar.swift`）：在頂部 1pt 分隔線下方加入居中膠囊把手（hover 或拖曳時切換為 `dragHandlePillActive`），提升可發現性與操作回饋。
3. **實作拖曳與視窗縮放期間的 GPU 零開銷守護（`RootView.swift`、`PaneViews.swift`、`NotificationBar.swift`）**
   - `SidebarBackdrop` 新增 `isResizing: Bool` 狀態並納入 `isOpaqueFallback`（`forceOpaque || isResizing || accessibilityDisplayShouldReduceTransparency`）。
   - 當使用者拖曳 `SidebarResizeHandle`（調整 sidebar 寬度）、`SplitView`（調整分割窗格）、`BarResizeHandle`（調整 **通知 bar** 高度）或視窗處於 live resize 時，將 `sidebarBackdrop.isResizing` 設為 `true`（隱藏 `NSVisualEffectView` 並改用不透明 `sidebarBackground`）；放開滑鼠、結束縮放或視窗失焦時立即恢復為 `false`。
   - 支援系統「減少透明度」（`accessibilityDisplayShouldReduceTransparency`）與「減少動態效果」（`LmuxTokens.Motion.reduceMotion`）。
4. **升級內建預覽 tab（`App/Sources/LmuxUI/MarkdownHTML.swift`）為雙主題 Liquid Glass 卡片樣式**
   - 更新 `MarkdownHTML.css`（淺色與 `@media (prefers-color-scheme: dark)` 深色雙主題）：為程式碼區塊（`<pre>`）、提示框（`.callout`）與表格（`<table>` / `<th>`）加入微透玻璃表面、圓角、1px 邊框與頂部內高光，並加入 `@media (prefers-reduced-transparency: reduce)` 實底降級，同時保留既有 CSP 與 DOM 結構相容性。
5. **保留 `preview-mockup.html` 作為視覺對照原型**
   - 保留根目錄 **UI 原型** `preview-mockup.html` 與其 `WKWebView` 檢查腳本作為設計基準。

## Impact

- **修改模組**：
  - `App/Sources/LmuxTokens/Tokens.swift`（與符號連結 `design/Tokens.swift`）
  - `App/Sources/LmuxUI/RootView.swift`、`Sidebar.swift`、`History.swift`、`PaneViews.swift`、`MarkdownHTML.swift`
  - `App/Sources/LmuxNotificationBar/NotificationBar.swift`、`NotificationCard.swift`
  - `App/Sources/lmux-apptest/`（新增 Liquid Glass token、拖曳 `isResizing` 降級與預覽頁樣式測試）
- **不變**：
  - `Core/` 與 `LmuxTerminal`（libghostty 終端機渲染路徑）完全不變；SwiftUI 仍僅用於 sidebar、標題列按鈕與 **通知 bar**，絕不進入終端機表面。
  - 既有鍵盤快捷鍵、持久化格式（`layout.json`）與 `MarkdownHTML` 的 CSP 安全限制完全相容。
- **驗證方式**：
  - 透過 `App/scripts/bundle.sh` 建置正式 `App/build/lmux.app` 並啟動實測。
  - 透過 `App/scripts/apptest.sh --quick`、`App/scripts/apptest.sh --preview` 與 `beat/changes/preview-liquid-glass/dev.sh check` 進行自動化驗證。
