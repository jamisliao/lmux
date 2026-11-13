# notification-bar

sidebar 底部的通知 bar（plugin，`App/Sources/LmuxNotificationBar/`）。

- `notification-cards.feature`：每則通知顯示成 4 行的卡片（任務名稱、workspace 名稱、2 行訊息）；只反白 focused tab 的最新一則；摘要列固定在清單上方。

`@e2e` 場景靠手動驗證，紀錄在封存的 change 裡（`../../changes/archive/2026-11-13-notification-cards-and-compaction-state/manual-verification.md`）。部分場景未手動驗證，沒有 `@covered-by`。
