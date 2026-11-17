# Design: Apple Liquid Glass UI Styling & Performance Optimization

## Architecture & Visual Tokens

### 1. Material & Depth (材質與深度)
遵循 Apple WWDC 設計原則「Translucency conveys hierarchy」：
- **結構底層（Sidebar）**：採用較具分量感且穩定的毛玻璃材質 (`rgba(18, 22, 30, 0.82)`)。
- **浮動層（Toolbar / Accessory）**：更輕透且具層次感的毛玻璃 (`rgba(22, 27, 38, 0.75)`)。
- **互動卡片（Cards / Items）**：微透表面與高光邊界 (`rgba(255, 255, 255, 0.05)`)。

### 2. Specular Highlights & Ambient Edges (物理光澤倒角)
模擬自然頂部環境光照：
- 頂部邊界：`border-top: 1px solid rgba(255, 255, 255, 0.16)`。
- 內發光與內陰影：`box-shadow: inset 0 1px 0 0 rgba(255, 255, 255, 0.14), inset 0 -1px 0 0 rgba(0, 0, 0, 0.25)`。

### 3. GPU Performance Guard (拖曳效能守護)
- 進入拖曳時，在 `body` 或目標面板加上 `.is-resizing` 類別。
- 樣式規則：
  ```css
  .is-resizing * {
    user-select: none !important;
  }
  .is-resizing .sidebar,
  .is-resizing .inbox-accessory-panel {
    backdrop-filter: none !important;
    -webkit-backdrop-filter: none !important;
    background: rgba(18, 22, 30, 0.96) !important;
    transition: none !important;
  }
  ```
- 釋放拖曳後立刻移除 `.is-resizing`，恢復材質。

### 4. Accessibility
- 支援 `prefers-reduced-transparency: reduce`：降級為實體不透明顏色，完全關閉 `backdrop-filter`。
