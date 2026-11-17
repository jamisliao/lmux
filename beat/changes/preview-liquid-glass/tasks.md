# Implementation Tasks: preview-liquid-glass

- [x] Task 1: 拖曳 GPU 效能守護 (Performance Guard)
  - 在拖曳開始時於 `document.body` 注入 `.is-resizing` 類別，拖曳結束時移除。
  - 在 CSS 中對 `.is-resizing` 下的所有面板強制設為 `backdrop-filter: none !important; background: rgba(18, 22, 30, 0.98) !important;`，避免 GPU 連續計算卷積模糊。

- [x] Task 2: Apple Liquid Glass 視覺精緻化 (Visual Refinement)
  - 調整 `--glass-sidebar`、`--glass-titlebar`、`--glass-card` 的分層濃度與飽和度。
  - 增強物理頂部倒角高光（Specular Edge）與多重邊界陰影。
  - 精細化卡片與選取狀態的微發光層次。

- [x] Task 3: 文字排版與 Vibrancy 對比度 (Typography & Vibrancy)
  - 強化 SF Pro / 系統字體的大標題負字距 (`letter-spacing: -0.015em`)。
  - 調整次要標籤與文字透明度，確保文字在磨砂背景上高度清晰易讀。

- [x] Task 4: 系統降級與無障礙支援 (Accessibility & Fallback)
  - 增加 `@media (prefers-reduced-transparency: reduce)` 支援。
  - 增加 `@media (prefers-reduced-motion: reduce)` 支援。
