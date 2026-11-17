# Proposal: Preview Mockup Apple Liquid Glass UI Styling

## Problem Statement
`preview-mockup.html` 原型目前在調整大小（drag-to-resize）過程中直接連帶重繪大面積的 `backdrop-filter: blur(...)`，造成 GPU 在逐影格高斯模糊計算上面臨龐大開銷；同時，目前的深色磨砂玻璃材質在層級光澤、Specular Edge（物理頂部倒角高光）、Vibrancy 文字對比度上仍有提升空間，尚未達到 Apple WWDC 設計指南所推崇的頂級精緻度。

## Proposed Changes
1. **GPU 負載歸零（拖曳無玻璃特效）**：
   - 在拖曳調整大小（drag-to-resize）期間，透過 `.is-resizing` 狀態停用即時毛玻璃重繪，改採低開銷硬體加速指示線或純色邊框，徹底消除 GPU 卷積負擔。
2. **Apple Liquid Glass 視覺精緻化**：
   - 重新配置材料層次（Sidebar / Titlebar / Floating Bar / Cards）。
   - 引入物理入射光光澤（Specular Highlight 頂部 1px 亮邊與環境光內陰影）。
   - 強化文字可讀性（Vibrancy、文字對比度、光學字距負微調）。
3. **無障礙與系統降級**：
   - 補齊 `@media (prefers-reduced-transparency)` 與 `@media (prefers-reduced-motion)`。

## Scope
- 修改範圍局限於 `preview-mockup.html`。
- 不影響後端 Swift 代碼或現有生產環境檔案。
