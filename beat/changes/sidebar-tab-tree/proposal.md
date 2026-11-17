# 在側邊欄以樹狀結構展開 Workspace 的 Tab

## Why

1. **跨 Workspace 導覽時無法在側邊欄看到內部 Tab 全貌**：目前左側 Sidebar 每一列是一個 Workspace，使用者無法直接在側邊欄得知各 Workspace 內部開了哪些 Tab（例如哪個是 Claude Code 終端機、哪個在看伺服器 log、哪個在預覽文件）。
2. **切換多分頁路徑較長**：當使用者有多個 Workspace、每個 Workspace 有多個分頁時，必須先點選 Workspace，再移至右側頂端分頁列尋找並點擊分頁。若側邊欄支援展開，使用者可直接從側邊欄點選目標 Tab 一步到位。
3. **Agent 狀態在 Workspace 層級被聚合**：目前 Workspace 列只能顯示聚合後的燈號（例如只要有一個 Tab 正在執行就顯示 spinner），無法一眼看出「到底是哪一個 Tab 在跑、哪一個 Tab 已完成或需要確認」。

## What Changes

1. **折疊箭頭與展開控制 (Accordion Disclosure Tree)**
   - 當 Workspace 內的 Tab 數量 $\ge 2$ 時，列首顯示微型折疊箭頭（`▶` 收合 / `▼` 展開）。
   - 若只有 $1$ 個 Tab，箭頭自動隱藏並留白對齊，避免干擾單一分頁的專案。
   - 點擊箭頭展開或收合該 Workspace 的 Tab 列表；展開/收合狀態會被記憶，lmux 重開後維持。
2. **Tab 子項目列 (Child Tab Rows)**
   - 展開後縮排列出該 Workspace 底下的所有 Tab（終端機 tab 與預覽 tab）。
   - **類型圖示**：終端機 Tab 顯示等寬 `>_`，預覽 Tab 顯示文件圖示。
   - **分頁標題**：顯示該 Tab 的名稱（Claude session 標題、執行中的前景指令、或預覽檔案名稱）。
   - **獨立狀態燈號**：各 Tab 顯示自己專屬的 Agent 狀態（獨立旋轉 spinner、完成 ✓、待輸入 badge）。
   - **焦點標記**：目前獲得焦點的 Tab 會以微光高亮背景顯示。
   - **懸停關閉**：滑鼠移入 Tab 子列時顯示微型 `✕`，點擊可直接關閉該 Tab（最後一個 Tab 關閉時該窗格隨之關閉）。
   - **點擊跳轉**：點擊 Tab 子列直接切換至該 Workspace 並將焦點切換到該 Tab。
3. **雙軌並存**
   - 右側終端機窗格頂端的「水平分頁列（Tab bar）」完全保留，既有的 `⌘T`、`⌘W`、分割按鈕與拖曳不受影響。
4. **不變**
   - Workspace 列本身的拖曳排序行為不變（拖曳 Workspace 列時，展開的子項目隨同整組移動）。
   - Workspace 列的多選（`⌘`-click / `⇧`-click）與批次操作（批次關閉、清除狀態）不變。

## Impact

- **版面影響**：展開多個 Workspace 的 Tab 後，側邊欄垂直內容會變長，但使用者可隨時手動點箭頭收合，不影響清爽度。
- **程式影響**：
  - `Model.swift`：`AppModel` 需記錄每個 Workspace 的展開狀態（`expandedWorkspaceIDs: Set<String>`）。
  - `Sidebar.swift`：`WorkspaceRow` 增設展開箭頭；新增 `SidebarTabChildRow` 與展開動畫容器。
  - `Controller.swift`：新增側邊欄點擊 Tab 子項目的跳轉焦點方法（`selectTabFromSidebar`）。
- **效能**：子列僅為輕量 SwiftUI 視圖，不影響背景終端機或 GPU 記憶體釋放機制。
