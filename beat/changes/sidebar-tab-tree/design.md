# 設計：在側邊欄以樹狀結構展開 Workspace 的 Tab

## Approach

```
SidebarView
 └── ForEach(workspaces)
      ├── WorkspaceRow (Header)
      │    ├── ChevronButton (▶/▼，只有 panes.count >= 2 時顯示)
      │    ├── AccentChip
      │    ├── Title & Meta (路徑/分支)
      │    └── Aggregated AgentStatus (收合時顯示整體狀態)
      │
      └── SidebarTabChildrenView (展開時顯示)
           └── ForEach(ws.panes)
                └── SidebarTabChildRow
                     ├── TabTypeIcon (>_ 或 📄)
                     ├── TabTitle (Claude 任務名 / 指令 / 預覽檔名)
                     ├── Individual AgentStatus (專屬狀態燈號)
                     └── HoverCloseButton (✕ 關閉此 Tab)
```

### 1. 模型與狀態（`App/Sources/LmuxUI/Model.swift`）

1. **展開狀態記錄**：
   - `AppModel` 新增 `public var expandedWorkspaceIDs: Set<String> = []`。
   - 狀態儲存：在現有工作區狀態存檔（`saveState` / `restoreState`）中加入 `expandedWorkspaceIDs`，讓使用者手動展開/收合的狀態在重新啟動後自動恢復。
2. **Tab 列表獲取**：
   - 目前 `Workspace.panes` 已可依序取得該工作區底下的所有 `Pane`（在 lmux 中每個終端機或預覽 tab 均為一個 `Pane`）。
   - 當 `ws.panes.count >= 2` 時，視為多分頁工作區，可供展開。

### 2. 視圖與動態（`App/Sources/LmuxUI/Sidebar.swift`）

1. **折疊箭頭（`ChevronButton`）**：
   - 位於 `WorkspaceRow` 最左側。
   - 當 `ws.panes.count >= 2` 時顯示；單一分頁時替換為固定寬度的透明佔位（`chevronPlaceholder`），維持 Workspace 標題與圖示的垂直對齊線。
   - 點擊箭頭呼叫 `controller.toggleWorkspaceExpansion(ws.id)`，以 Apple 原生彈簧動態（`T.Motion.spring`）驅動 $0^\circ \leftrightarrow 90^\circ$ 旋轉。
2. **子列視圖（`SidebarTabChildRow`）**：
   - 緊接在 `WorkspaceRow` 下方，左側縮排 $18\text{pt}$，高度設定為 $26\text{pt}$。
   - **類型圖示**：若為終端機 tab 顯示等寬 `>_`，若為預覽 tab（`pane.preview != nil`）顯示 `doc.text`。
   - **標題文字**：顯示 `pane.title`（Claude 任務名、前景程式名稱，或預覽檔案名稱）。
   - **獨立狀態燈號**：終端機 tab 獨立綁定自己的狀態（執行中 spinner、✓、待輸入 badge），預覽 tab 則不帶狀態燈號。
   - **焦點標記**：當該 pane 為該 workspace 的 `focusedPane` 且該 workspace 被選取時，以 `accent-blue-subtle` 背景高亮。
   - **懸停關閉按鈕**：滑鼠移入時顯示微型 `✕`，點擊呼叫 `controller.closePane(pane)`。
3. **展開/收合容器（`SidebarTabChildrenView`）**：
   - 採用縱向折疊容器，透過 `withAnimation(T.Motion.spring)` 帶動高度平滑過渡，下方的其他 Workspace 列自然滑動避讓。

### 3. 控制器互動（`App/Sources/LmuxUI/Controller.swift`）

1. **展開/收合切換**：
   - 新增 `toggleWorkspaceExpansion(_ id: String)`：切換 `model.expandedWorkspaceIDs` 中的存在狀態。
2. **從側邊欄點選 Tab**：
   - 新增 `selectTabFromSidebar(_ ws: Workspace, pane: Pane)`：
     1. 若 `model.selectedID != ws.id`，先切換至該工作區（`selectWorkspace(ws)`）。
     2. 切換焦點至該 pane（`focus(pane)`），若該 pane 位於某個非前景的 tab，自動切換該分割窗格的 `selectedTab`。

### 4. 側邊欄拖曳排序相容（`App/Sources/LmuxUI/SidebarReorder.swift`）

- 現有拖曳排序由 `SidebarDragGeometry` 依 Workspace 高度計算位移。
- 當 Workspace 展開時，整組（父列＋所有展開的子列）視為單一連續區塊進行拖曳與位移計算，確保拖曳排序邏輯一致。

---

## Key Decisions

1. **扁平列出所有 Tab，不以 Pane（分割窗格）分層**
   - 使用者 2026-11-17 選擇扁平列出（選項 A）。
   - 不論 Workspace 內部是否有垂直或水平分割，側邊欄一律只維持「Workspace → Tab」兩層深度，避免過度嵌套造成視覺雜亂。
   - ADR 檢查：純視圖層展示，未來若要分組亦容易切換 → 不需 ADR。
2. **漸進折疊（僅在分頁數 $\ge 2$ 時顯示箭頭）**
   - 只有一個 Tab 時無須展開，隱藏箭頭可保持一般工作區的極簡乾淨。
   - ADR 檢查：符合 macOS 習慣，易還原 → 不需 ADR。
3. **雙軌並存（保留頂端水平 Tab bar）**
   - 側邊欄負責全貌瀏覽與跨 Workspace 導覽，窗格頂端水平 Tab bar 負責單一窗格內的快速鍵與分割操作。
   - ADR 檢查：完全向下相容既有操作習慣 → 不需 ADR。
4. **狀態持久化**
   - 記憶展開/收合狀態，避免每次重開 app 所有專案皆被還原為預設收合。
   - ADR 檢查：標準 UI 行為 → 不需 ADR。

---

## Components

| 檔案 | 改動 |
|---|---|
| `App/Sources/LmuxUI/Model.swift` | `AppModel` 新增 `expandedWorkspaceIDs: Set<String>` 與狀態持久化。 |
| `App/Sources/LmuxUI/Sidebar.swift` | `WorkspaceRow` 增設展開箭頭；新增 `SidebarTabChildRow` 與展開動畫容器。 |
| `App/Sources/LmuxUI/Controller.swift` | 新增 `toggleWorkspaceExpansion` 與 `selectTabFromSidebar` 方法。 |
| `App/Sources/LmuxUI/SidebarReorder.swift` | 適應動態高度（展開後的 Workspace 區塊整組拖曳位移）。 |
| `App/Sources/lmux-apptest/Sidebar.swift` | 新增側邊欄樹狀展開、子分頁切換與關閉之自動化測試。 |
