# 正式 App Apple Liquid Glass 視覺材質與拖曳零開銷守護 — 技術設計

## Approach

本次改動在保留根目錄 **UI 原型**（`preview-mockup.html`）作為視覺對照基準的同時，將 Apple Liquid Glass 的雙主題材質層次、1pt 物理入射光高光（Specular Highlight）、微透立體卡片邊框與拖曳期間的 GPU 零開銷守護，正式落實到 macOS 原生 Swift App（`LmuxTokens`、`LmuxUI`、`LmuxNotificationBar`）與內建 **預覽 tab**（`MarkdownHTML`）。

```
┌─────────────────────────────────────────────────────────────────────────┐
│ NSWindow (RootView)                                                     │
│ ┌──────────────────────────┬──────────────────────────────────────────┐ │
│ │ Sidebar Column           │ Content Column                           │ │
│ │  SidebarBackdrop         │  ContentHeaderView (1pt bottom rule)     │ │
│ │  ├─ NSVisualEffectView   │  ─────────────────────────────────────── │ │
│ │  ├─ sidebarTint          │  SplitView / Pane Leaves                 │ │
│ │  └─ topSpecular (1pt)    │  ├─ Terminal SurfaceView (libghostty)    │ │
│ │  SidebarView (SwiftUI)   │  └─ PreviewView (WKWebView MarkdownHTML) │ │
│ │  ├─ WorkspaceRow (glass) │     └─ Liquid Glass <pre>/callout/table  │ │
│ │  └─ HistorySection       │                                          │ │
│ │  NotificationBar         │                                          │ │
│ │  ├─ BarResizeHandle(pill)│                                          │ │
│ │  └─ NotificationCard     │                                          │ │
│ └──────────────────────────┴──────────────────────────────────────────┘ │
│            ▲                                   ▲                        │
│            └── SidebarResizeHandle / SplitView / BarResizeHandle ───────┘
│                拖曳或視窗 Live Resize 時：sidebarBackdrop.isResizing = true
│                → 隱藏 NSVisualEffectView、改繪製不透明 sidebarBackground
└─────────────────────────────────────────────────────────────────────────┘
```

### 1. `LmuxTokens` 雙主題 Liquid Glass 語意 Token（`App/Sources/LmuxTokens/Tokens.swift`）

- 在不破壞既有 Nord 調色盤與 WCAG AA 對比度（`P2Tests.swift:925-952`）的前提下，擴充 `LmuxTokens.Colors` 與 `LmuxTokens.Layout`：
  - `sidebarTint`：維持既有 Nord 淺／深色調與透明度設定，搭配頂部高光與選取邊框呈現玻璃層次。
  - `specularHighlight`：`DynamicColor(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.65, darkAlpha: 0.12)`，用於 `SidebarBackdrop` 頂部與 **通知 bar** 上緣的 1pt 物理高光亮邊。
  - `glassBorder`：`DynamicColor(light: Nord.nord0, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.11)`，用於選取中的 **workspace** 列、反白的 **通知卡片** 與 History 搜尋框的 0.5–1pt 微透立體邊框。
  - `dragHandlePill` / `dragHandlePillActive`：`DynamicColor` 用於 **通知 bar** 頂部調整手把的居中膠囊條（平時低調微透，游標移入或拖曳時增亮）。
  - `Layout.dragHandlePillWidth: CGFloat = 24`、`Layout.dragHandlePillHeight: CGFloat = 2.5`。

### 2. 原生 Sidebar、標題列與通知 bar 的玻璃表面與立體邊框（`LmuxUI` + `LmuxNotificationBar`）

- **`SidebarBackdrop`（`App/Sources/LmuxUI/RootView.swift`）**：
  - 除了 `material`（`NSVisualEffectView(.sidebar, .behindWindow)`）與 `tint`（`ColorView`）外，新增 1pt 高的頂部高光視圖 `specular = ColorView(T.Colors.specularHighlight.nsColor)`。
  - 當 `matchColor == nil` 且非不透明降級時顯示 `specular`；若設定了跟隨終端機底色（`matchColor != nil`）或處於不透明降級時自動調整，確保視覺自然。
- **`WorkspaceRowContent` 與 `HistorySection`（`App/Sources/LmuxUI/Sidebar.swift`、`History.swift`）**：
  - 當 `selected` 或 `inSelection` 為 `true` 時，在圓角膠囊背景（`RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)`）上疊加 `.strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)`，呈現 Liquid Glass 選取膠囊的邊緣折射感。
- **`NotificationCard` 與 `BarResizeHandle`（`App/Sources/LmuxNotificationBar/`）**：
  - `NotificationCard` 在 `highlighted`（來自 **focused tab** 的最新通知）或 `hover` 時，於圓角背景加上微透 `glassBorder` 細邊框。
  - `BarResizeHandle` 的高度調整為 `6pt`，除了最上方的 1pt 分隔線外，中央繪製 `24×2.5pt` 的圓角膠囊指示條（`Capsule()`），在 hover 或拖曳中（`dragStart != nil`）切換為 `T.Colors.dragHandlePillActive.color`。

### 3. 拖曳調整大小與視窗縮放期間的 GPU 零開銷守護（`isResizing`）

- **`SidebarBackdrop.isResizing`（`App/Sources/LmuxUI/RootView.swift`）**：
  - 新增 `public internal(set) var isResizing = false { didSet { if isResizing != oldValue { update() } } }`。
  - `var isOpaqueFallback: Bool` 更新為：
    ```swift
    forceOpaque || isResizing || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    ```
  - 當 `isOpaqueFallback == true` 時，`material.isHidden = true` 並將 `tint.color` 切換為不透明的 `T.Colors.sidebarBackground.nsColor`，完全省去 `NSVisualEffectView` 在每個拖曳 frame 的背景高斯模糊合成開銷。
- **四個觸發入口與失焦保護**：
  1. **`SidebarResizeHandle`（水平拉寬 sidebar，`RootView.swift`）**：新增 `onDragStateChange: ((Bool) -> Void)?`，在 `mouseDown` 設 `isResizing = true`、`mouseUp` 設 `isResizing = false`。
  2. **`SplitView`（拉動窗格分割線，`PaneViews.swift`）**：在分割線 `mouseDown` / `mouseUp` 通知 `RootView` 切換 `isResizing`。
  3. **`BarResizeHandle`（垂直拉高通知 bar，`NotificationBar.swift` + `SidebarAccessory.swift`）**：透過 `LmuxController.setSidebarResizing(_ active: Bool)` 在 `DragGesture.onChanged` 首個事件設為 `true`、`onEnded` 設為 `false`。
  4. **視窗 Live Resize 與失焦清理（`RootView.swift`）**：監聽 `NSWindow.willStartLiveResizeNotification`（設 `isResizing = true`）、`NSWindow.didEndLiveResizeNotification` 與 `NSWindow.didResignKeyNotification` / `NSApplication.didResignActiveNotification`（設 `isResizing = false`），確保拖曳途中若切換應用程式或視窗失焦，絕不會卡在 `isResizing == true`。

### 4. 內建預覽 tab 的雙主題 Liquid Glass 樣式（`App/Sources/LmuxUI/MarkdownHTML.swift`）

- 更新 `MarkdownHTML.css`：
  - 在 `:root`（淺色 High-Key Crystal）與 `@media (prefers-color-scheme: dark)`（深色 Obsidian Midnight）定義玻璃表面變數（`--glass-surface`、`--glass-border`、`--glass-highlight`、`--glass-shadow`）。
  - `<pre>`、`.callout`、`<table>` 與 `<th>` 套用圓角、1px 微透邊框與 `box-shadow: inset 0 1px 0 var(--glass-highlight)` 頂部亮邊。
  - 加入 `@media (prefers-reduced-transparency: reduce)` 與 `@media (prefers-reduced-motion: reduce)` 規則，在系統開啟無障礙降級時改用不透明實底並停用過渡動畫。
  - 完全不動 `MarkdownHTML.csp` 與 `textCSP`，維持既有安全性與測試相容性。

### 5. 自動化驗證與實機測試策略

- **正式 App 自動化測試（`App/Sources/lmux-apptest/`）**：
  - `@behavior`：驗證 `LmuxTokens` 新增的 Liquid Glass 色彩／尺寸 token 在淺色與深色外觀下皆可正常解析、WCAG AA 對比度全數通過，且 `MarkdownHTML.page` 輸出包含雙主題玻璃變數、頂部內高光與 `prefers-reduced-transparency` / `prefers-reduced-motion` 規則。
  - `@e2e`：在 `lmux-apptest` 驗證 `SidebarBackdrop` 一般狀態啟用 `NSVisualEffectView` 與 `specular` 亮邊、在 `SidebarResizeHandle` / `SplitView` / `BarResizeHandle` / 視窗 live resize 期間自動進入 `isResizing == true`（`material.isHidden == true`、改用不透明 `sidebarBackground`），並在放開滑鼠或視窗失焦後恢復 `isResizing == false`。
- **保留 UI 原型檢查（`App/scripts/liquid-glass-mockup-check*.swift`）**：
  - `beat/changes/preview-liquid-glass/dev.sh check` 同時驗證 **UI 原型** 與正式 App 的檢查。
- **實機建置與啟動**：
  - 連結 `vendor/ghostty` 後透過 `App/scripts/bundle.sh` 產出 `App/build/lmux.app` 並啟動供使用者直接操作測試。

---

## Key Decisions

1. **維持單一 `SidebarBackdrop` 的 `NSVisualEffectView`，不在個別 SwiftUI 列上疊加多層 `Material`**
   - 理由：macOS 視窗中重疊多個 `NSVisualEffectView` 或 SwiftUI `.ultraThinMaterial` 會在捲動與展開時倍增離屏模糊合成成本。在單一 `SidebarBackdrop` 上方用微透色塊（`rowSelected` + `glassBorder` + 1pt `specularHighlight`）即可達成 Liquid Glass 層次，同時維持極致效能。
   - 替代方案：在每個 `WorkspaceRow` 與 `NotificationCard` 掛載獨立的 SwiftUI `Material`。
   - ADR 檢查：遵循專案既有 `App/README.md` 與 `POLISH.md` 的單一背景材質原則，且僅影響內部視圖繪製 → 不難還原、不令人意外 → **不需 ADR**。

2. **拖曳時透過 `SidebarBackdrop.isResizing` 切換不透明 `sidebarBackground` 作為 GPU 守護**
   - 理由：`SidebarBackdrop` 原本就有 `isOpaqueFallback`（處理 `forceOpaque` 與系統「減少透明度」）。將 `SidebarResizeHandle`、`SplitView`、`BarResizeHandle` 與視窗 live resize 統一匯流到 `isResizing`，只需幾行程式碼就能在所有縮放路徑零延遲暫停 `NSVisualEffectView`，並在視窗失焦時自動復原。
   - 替代方案：調整 `CAFilter` 模糊半徑或完全不做拖曳降級。
   - ADR 檢查：局部於 `RootView` / `SidebarBackdrop` 的狀態旗標，隨時可調整 → **不需 ADR**。

3. **保留根目錄 `preview-mockup.html` 與其 `WKWebView` 檢查腳本作為設計參考**
   - 理由：使用者確認保留 `preview-mockup.html` 作為視覺對照基準，同時在正式 App 落實方案 A。
   - ADR 檢查：單純保留對照檔案 → **不需 ADR**。

狀態機檢查：`SidebarBackdrop` 的材質狀態僅由布林旗標（`forceOpaque`、`isResizing`、`accessibilityDisplayShouldReduceTransparency`、`matchColor != nil`）組合決定（`< 4` 個狀態、無並行或重試流程），**不需執行 `/statechart` 形式化驗證**。

架構中樞檢查：本次改動完全在既有 `LmuxTokens`、`LmuxUI`、`LmuxNotificationBar` 模組職責內演進，未新增或拆分模組，不需新增 `beat/ARCHITECTURE.md`。

---

## Components

| 檔案 | 改動說明 |
|---|---|
| `App/Sources/LmuxTokens/Tokens.swift` | 新增 `Colors.specularHighlight`、`Colors.glassBorder`、`Colors.dragHandlePill`、`Colors.dragHandlePillActive` 與 `Layout.dragHandlePillWidth` / `dragHandlePillHeight`，並確保 WCAG AA 對比測試通過。 |
| `App/Sources/LmuxUI/RootView.swift` | `SidebarBackdrop` 新增頂部 1pt `specular` 亮邊與 `isResizing` 狀態；`SidebarResizeHandle` 新增 `onDragStateChange`；監聽視窗 live resize 與 `didResignKey` / `didResignActive` 自動重置 `isResizing`。 |
| `App/Sources/LmuxUI/PaneViews.swift` | `SplitContainerView` 在拖曳分割線 `mouseDown` / `mouseUp` 時回呼切換 `isResizing`。 |
| `App/Sources/LmuxUI/Sidebar.swift`、`History.swift` | `WorkspaceRowContent` 選取膠囊、`HistorySection` 搜尋框與 `HistoryRow` 選取列加上 `glassBorder` 微透立體邊框。 |
| `App/Sources/LmuxUI/SidebarAccessory.swift` | `LmuxController` 新增 `public func setSidebarResizing(_ active: Bool)` 供 `LmuxNotificationBar` 在拖曳手把時同步 `isResizing`。 |
| `App/Sources/LmuxNotificationBar/NotificationBar.swift`、`NotificationCard.swift` | `BarResizeHandle` 新增居中膠囊指示條並在拖曳時呼叫 `setSidebarResizing`；`NotificationCard` 反白與 hover 狀態加上 `glassBorder` 微透邊框。 |
| `App/Sources/LmuxUI/MarkdownHTML.swift` | 升級預覽頁 CSS 為淺／深雙主題 Liquid Glass 卡片風格（保留既有 `--bg` / `--fg` 相容性，新增 `--glass-*`、`inset` 頂部亮邊與 `prefers-reduced-transparency` / `prefers-reduced-motion` 降級）。 |
| `App/Sources/lmux-apptest/LiquidGlass.swift`、`App/scripts/liquid-glass-app-check.swift` | 新增正式 App 的 Liquid Glass tokens、拖曳 `isResizing` 降級／失焦恢復、通知 bar／卡片玻璃細節與 `MarkdownHTML` 樣式檢查。 |
| `preview-mockup.html`、`App/scripts/liquid-glass-mockup-check*.swift` | 保留作為 **UI 原型** 對照與 `WKWebView` 驗證腳本。 |
