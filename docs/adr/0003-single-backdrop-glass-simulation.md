# 單一 Backdrop Material 配半透明覆層模擬 Liquid Glass 卡片

視覺上對齊 `preview-mockup.html` 的雙主題 Apple Liquid Glass（High-Key Crystal 淺色高透玻璃與 Obsidian Midnight 深色玻璃），但原生 AppKit/SwiftUI 端僅在 Titlebar、左側欄、**右側 Inspector** 與 **底部狀態列** 底層掛載單層 `NSVisualEffectView`，不在捲動中的每張 Workspace 卡片、通知卡片或 **Pane Tab Strip** 標籤上逐一疊加系統模糊材質；卡片層次改由高對比半透明覆層、物理高光細邊與陰影模擬，並配合全域 `isResizing` 拖曳降級，避免捲動或拉寬面板時因多重離屏高斯模糊造成 libghostty 終端機掉幀。

## Considered Options

- **比照 CSS 對每張卡片與分頁掛載 `.ultraThinMaterial`／獨立 `NSVisualEffectView`**：捲動與視窗縮放時合成器負載成倍放大，難以維持終端機 60fps。
- **全部面板皆用固定半透明實色、不開啟系統毛玻璃**：無法呈現桌布透光折射感與 macOS 原生 Liquid Glass 質感。

來源：`beat/changes/preview-liquid-glass/design.md`（2026-11-18）。
