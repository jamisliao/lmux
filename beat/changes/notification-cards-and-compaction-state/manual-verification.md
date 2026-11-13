# 手動驗證紀錄

- 日期：2026-11-12 至 2026-11-13
- lmux.app commit：`c4573d7`（build 於 2026-11-13；壓縮 Esc 以此版重測；卡片各項以 `ee5c302` 的 build 測，之後 `c4573d7` 只改 `plainMessage` 與 Esc 偵測）
- 未測的項目（使用者選只做重要 3 項）：Step 6-3、6-4、6-5、6-9、6-10、6-16，以及「沒有通知」（6-1）未單獨確認。這些場景在 feature 裡**沒有** `@covered-by`。
- Claude Code 版本：2.1.318

結果欄：通過／失敗／未測。

| feature | 場景 | Task 8 項目 | 結果 | 備註 |
|---|---|---|---|---|
| compaction-running-state | 壓縮期間 workspace 列第 2 行顯示 Compacting | Step 5-2 | 通過 | 轉圈；第 2 行 `Compacting`，不是 `Bash · ls` |
| compaction-running-state | 已完成的 tab 開始壓縮時顯示進行中（實機） | Step 5-2 | 通過 | |
| compaction-running-state | 壓縮結束後回到完成，不發通知（實機） | Step 5-3 | 通過 | 回到 ✓；沒有新通知 |
| compaction-running-state | 閒置的 tab 壓縮結束後回到閒置（實機） | Step 5-4 | 通過 | 壓縮期間 Compacting；完成後沒有圖示（閒置） |
| compaction-running-state | 壓縮期間使用者按 Esc 中斷（實機） | Step 5-5 | 通過（修正後） | 第一次失敗：Claude 取消壓縮，tab 仍轉圈、顯示 Compacting。改 `Agent.swift` 的 Esc 偵測（design A.6，`aa622e4`）並重新 build 後重測：tab 停止轉圈（2026-11-13）。verify 後改成看 `PaneAgent.isCompacting`（`c4573d7`），再重測：tab 馬上停止轉圈，第 2 行也正確 |
| notification-cards | 通知卡片顯示任務名稱、workspace 名稱與訊息 | Step 6-2 | 通過 | 使用者回報（a）任務名稱與時間（b）資料夾名稱（c）訊息（d）未讀圓點「都正常」 |
| notification-cards | workspace 有手動名稱時，第 2 行用手動名稱 | Step 6-3 | 未測 | |
| notification-cards | 卡片不顯示同一個 workspace 裡另一個 tab 的任務名稱 | Step 6-4 | 未測 | |
| notification-cards | 第 2 行與第 1 行相同時不顯示 | Step 6-5 | 未測 | |
| notification-cards | 訊息開頭的 Markdown 符號不顯示 | Step 6-6 | 通過 | 改用 `lmux notify '## 結論'`（Claude 的回覆開頭是 `ClaudeCode:`，測不到）；訊息顯示 `結論`。注意 zsh 要加引號，否則 `#` 被當成註解 |
| notification-cards | 沒有任務名稱時，第 1 行改用 workspace 名稱 | Step 6-7 | 通過 | `lmux notify hi`：第 1 行 `jkopay.batchsystem`，沒有第 2 行（2026-11-13 截圖） |
| notification-cards | tab 關閉後，卡片仍然顯示 | Step 6-8 | 通過 | ⌘W 關掉 shell tab 後卡片還在，第 1 行仍是 workspace 名稱 |
| notification-cards | workspace 也關閉後，卡片用通知當時的 workspace 名稱 | Step 6-9 | 未測 | |
| notification-cards | tab 換了 session 後，卡片顯示新的任務名稱 | Step 6-10 | 未測 | |
| notification-cards | 通知 bar 在最小高度時也看得到最新一則未讀通知 | Step 6-11 | 通過 | 中文 2 行訊息；使用者對 (a)未讀數 (b)兩行完整 (c)上下留白 三項回覆「有」（逐項未分別回報） |
| notification-cards | 清單捲動過後收到新的未讀通知，清單回到最上面 | Step 6-12 | 通過 | 使用者對 (a)自動捲回最上面 (b)摘要列固定 回覆「有」 |
| notification-cards | 沒有通知 | Step 6-1 | 未單獨確認 | 使用者回報「卡片都正常」，未單獨回報 No notifications 那一行 |
| notification-cards | 只反白來自 focused tab 的通知卡片 | Step 6-13 | 通過 | 反白只出現在最新一張；hover 反白卡片，底色不變 |
| notification-cards | 同一個 tab 有多則通知時，只反白最新的一張 | Step 6-13 | 通過（修正後） | 第一次失敗：同一個 tab 的 2 則通知兩張都反白（2026-11-13 截圖）。改成只反白最新一則（`ee5c302`）後重測通過 |
| notification-cards | 換 focus 時，反白跟著移動 | Step 6-14 | 通過 | 點另一個 workspace，反白消失（只驗證消失，沒有第二個 tab 的卡片可移過去） |
| notification-cards | lmux 視窗不在前景時，反白變淡 | Step 6-15 | 通過 | ⌘Tab 切到別的 App，反白變淡 |
| notification-cards | 不是來自 tab 的通知不反白 | Step 6-16 | 未測 | |
| notification-cards | 點擊通知卡片跳到它的 tab | Step 6-17 | 通過 | 跳到該 tab，卡片反白 |
| subagent-running-state | 主回合結束時還有背景子 agent 在跑，tab 維持進行中（實機） | 補充 | 通過 | 自動測試已覆蓋，加實機（2026-11-13）：「已派出」後 tab 維持轉圈，做完後 ✓；「已派出」那個回合沒有發卡片。bar 共 2 張卡片，對應子 agent 做完後 Claude 的 2 次實際回覆（子 agent 的前景 sleep 被擋、改用背景 shell，多出一個回合），不是重複通知 |
| build-version | About 視窗顯示 build 版號 | Task 9 Step 5-1 | 通過 | build `30-9bbee7c`；Info.plist 已用 PlistBuddy 確認 `CFBundleVersion = 30-9bbee7c`。使用者對 3 項檢查回覆「OK」（逐項未分別回報） |
| build-version | 通知 bar 的摘要列顯示同一個 build 版號 | Task 9 Step 5-2 | 通過 | 同上 |
| build-version | sidebar 很窄時，版號先被截斷，未讀數不受影響 | Task 9 Step 5-3 | 通過 | 同上（逐項未分別回報；`layoutPriority(-1)` + `truncationMode(.head)`） |
