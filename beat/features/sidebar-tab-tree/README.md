# sidebar-tab-tree

workspace 有 2 個以上的 tab 時，sidebar 的 workspace 列出現展開箭頭；展開後每個 tab 在下方有一列 Tab 子列，顯示類型、標題與該 tab 自己的 agent 狀態，點一下即可切換過去或關閉。

- `sidebar-tab-tree.feature`：展開箭頭出現時機與點擊行為、展開狀態保存在 `layout.json`、Tab 子列內容與狀態顯示、跨 workspace 切換、關閉規則（釘選與執行中詢問）、拖曳排序。
- `proposal.md`、`design.md`：來自 change `sidebar-tab-tree`。

`@e2e` 場景由 `lmux-apptest --sidebar-tabs`（及 `--sidebar-tabs-restore`）驗證。

程式：`App/Sources/LmuxUI/SidebarTabs.swift`、`Sidebar.swift`、`Model.swift`、`Persistence.swift`、`App/Sources/LmuxTokens/Tokens.swift`；測試：`App/Sources/lmux-apptest/SidebarTabs.swift`、`Tests.swift`。
