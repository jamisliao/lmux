# 在 sidebar 展開 workspace 的 tab

## Why

1. **sidebar 看不到 workspace 裡有哪些 tab**：sidebar 每一列是一個 workspace。要知道某個 workspace 開了哪些 tab，只能先切過去看 tab 列。
2. **切到別的 workspace 的某個 tab 要點 2 次**：先點 workspace 列，再到 tab 列找那個 tab。
3. **workspace 列只顯示一個狀態**：workspace 列顯示所有 tab 裡最需要注意的那個狀態（等待回應 > 進行中 > 失敗 > 完成）。看不出是哪一個 tab 在等、哪一個已經完成。

## What Changes

1. **展開箭頭**
   - workspace 有 2 個以上的 tab 時，workspace 列出現展開箭頭。只有 1 個 tab 時沒有。
   - 點展開箭頭展開或收合 Tab 子列。點它不會切換 workspace。
   - 預設收合。
2. **Tab 子列**
   - 展開後，workspace 的每個 tab 一列，縮排顯示在 workspace 列下方。分割出來的 tab 也列在同一層，不依分割分組。
   - 每列顯示：類型圖示（終端機或預覽）、標題、這個 tab 自己的 agent 狀態。預覽 tab 沒有 agent 狀態。
   - 選取中的 workspace 的 focused tab，它的 Tab 子列有標示。
   - 點 Tab 子列：切換到那個 workspace，那個 tab 成為 focused tab。它原本被同一格的其他 tab 蓋住時，會先顯示出來。
   - 滑鼠移到 Tab 子列上出現關閉按鈕。關閉規則與 tab 列相同：釘選的 tab 沒有關閉按鈕；終端機 tab 還有程式在跑時先詢問。
3. **展開狀態會保存**
   - 每個 workspace 各自記住展開或收合，重開 lmux 後維持。
   - tab 關到剩 1 個時展開箭頭與 Tab 子列消失；之後回到 2 個以上，回到原本的展開狀態。

## 不變

- tab 列（⌘T、⌘W、拖曳、分割按鈕）完全不變。
- workspace 列的內容不變：展開時照常顯示整體狀態與未讀數。
- workspace 列的拖曳排序、⌘-click／⇧-click 多選、批次關閉不變。拖曳已展開的 workspace 時，Tab 子列跟著移動。

## 先不做

- Tab 子列的右鍵選單、雙擊重新命名、拖曳排序（這些操作留在 tab 列）。
- 用鍵盤展開或收合。
- 依分割分組的三層結構。

## Impact

- **版面**：預設收合，所以沒點展開箭頭的使用者只會多看到一個箭頭。展開後 sidebar 變長，長度等於 tab 數乘以 Tab 子列的高度。
- **程式**：改 `Sidebar.swift`、`Model.swift`、`Persistence.swift`、`Controller.swift`（都在 `App/Sources/LmuxUI/`）與 `LmuxTokens/Tokens.swift`；切換與關閉沿用既有的 `focus(_:)` 與 `requestClosePane(_:)`，不新增切換邏輯。細節見 `design.md`。
- **儲存格式**：`layout.json` 的 workspace 多一個選填欄位。舊檔沒有這個欄位，讀進來視為收合；舊版 lmux 讀新檔會略過它（未實測，依 `Persistence.swift:16-18` 的註解與 `decodeIfPresent` 的寫法推論）。
- **測試**：`lmux-apptest --sidebar` 增加場景。既有用固定列高推算位置的測試 helper 要能算入 Tab 子列的高度。
