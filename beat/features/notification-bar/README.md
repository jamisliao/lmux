# notification-bar

sidebar 底部的通知 bar（plugin，`App/Sources/LmuxNotificationBar/`）。

- `notification-cards.feature`：每則通知顯示成 4 行的卡片（任務名稱、workspace 名稱、2 行訊息、來源分支 `workspace · branch` 與圓角玻璃卡片外觀）；只反白 focused tab 的最新一則；摘要列固定在清單上方，含 Inbox 鈴鐺未讀紅點與 `onAccent` 未讀膠囊。
- 收合與拖曳高度管理（`NotificationBarPlugin.collapsedHeight(pluginRows:)`、`BarLayout`：`isCollapsed`、`collapseDragThreshold`、`collapsedDefaultsKey`、`toggleCollapsed(on:)`、`beginDrag(on:)`、`updateDrag(...)`、`endDrag(on:)`）：支援點擊摘要列或向下拖曳過閾值自動收合並持久化於 `UserDefaults`（保留展開前高度）、向上拖曳平滑展開，以及與 `RootView` 同步的拖曳降級與失焦安全清除。

`@e2e` 場景整合覆蓋於 `lmux-apptest --liquid-glass` / `--liquid-glass-workbench` / `--liquid-glass-restore`（`LiquidGlass.swift`、`LiquidGlassWorkbenchTests.swift`），部分歷史視覺項目紀錄於 `../../changes/archive/2026-11-13-notification-cards-and-compaction-state/manual-verification.md`。
