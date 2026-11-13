# 手動驗證紀錄

- 日期：2026-11-12
- lmux.app commit：6c59c97 之後的 build（含 Task 0–7；`git rev-parse --short HEAD` 填最終值）
- Claude Code 版本：2.1.318

結果欄：通過／失敗／未測。

| feature | 場景 | Task 8 項目 | 結果 | 備註 |
|---|---|---|---|---|
| compaction-running-state | 壓縮期間 workspace 列第 2 行顯示 Compacting | Step 5-2 | 通過 | 轉圈；第 2 行 `Compacting`，不是 `Bash · ls` |
| compaction-running-state | 已完成的 tab 開始壓縮時顯示進行中（實機） | Step 5-2 | 通過 | |
| compaction-running-state | 壓縮結束後回到完成，不發通知（實機） | Step 5-3 | 通過 | 回到 ✓；沒有新通知 |
| compaction-running-state | 閒置的 tab 壓縮結束後回到閒置（實機） | Step 5-4 | 通過 | 壓縮期間 Compacting；完成後沒有圖示（閒置） |
| compaction-running-state | 壓縮期間使用者按 Esc 中斷（實機） | Step 5-5 | 通過（修正後） | 第一次失敗：Claude 取消壓縮，tab 仍轉圈、顯示 Compacting。改 `Agent.swift` 的 Esc 偵測（design A.6，`aa622e4`）並重新 build 後重測：tab 停止轉圈（2026-11-13） |
| notification-cards | 通知卡片顯示任務名稱、workspace 名稱與訊息 | Step 6-2 | 未測 | |
| notification-cards | workspace 有手動名稱時，第 2 行用手動名稱 | Step 6-3 | 未測 | |
| notification-cards | 卡片不顯示同一個 workspace 裡另一個 tab 的任務名稱 | Step 6-4 | 未測 | |
| notification-cards | 第 2 行與第 1 行相同時不顯示 | Step 6-5 | 未測 | |
| notification-cards | 訊息開頭的 Markdown 符號不顯示 | Step 6-6 | 未測 | |
| notification-cards | 沒有任務名稱時，第 1 行改用 workspace 名稱 | Step 6-7 | 未測 | |
| notification-cards | tab 關閉後，卡片仍然顯示 | Step 6-8 | 未測 | |
| notification-cards | workspace 也關閉後，卡片用通知當時的 workspace 名稱 | Step 6-9 | 未測 | |
| notification-cards | tab 換了 session 後，卡片顯示新的任務名稱 | Step 6-10 | 未測 | |
| notification-cards | 通知 bar 在最小高度時也看得到最新一則未讀通知 | Step 6-11 | 未測 | |
| notification-cards | 清單捲動過後收到新的未讀通知，清單回到最上面 | Step 6-12 | 未測 | |
| notification-cards | 沒有通知 | Step 6-1 | 未測 | |
| notification-cards | 只反白來自 focused tab 的通知卡片 | Step 6-13 | 未測 | |
| notification-cards | 換 focus 時，反白跟著移動 | Step 6-14 | 未測 | |
| notification-cards | lmux 視窗不在前景時，反白變淡 | Step 6-15 | 未測 | |
| notification-cards | 不是來自 tab 的通知不反白 | Step 6-16 | 未測 | |
| notification-cards | 點擊通知卡片跳到它的 tab | Step 6-17 | 未測 | |
| subagent-running-state | 主回合結束時還有背景子 agent 在跑，tab 維持進行中（實機） | 補充 | 未測 | 自動測試已覆蓋；實機未測 |
