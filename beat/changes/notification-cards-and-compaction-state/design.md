# 設計：通知卡片與壓縮中的進行中狀態

## Approach

兩個獨立部分，各自可以單獨實作與測試。

### A. 壓縮中顯示進行中（lmux 核心）

1. `HookInstaller.events` 加入 `"PreCompact"`、`"PostCompact"`。lmux 在使用者按 Update 時把這 2 個事件寫進 `~/.claude/settings.json`。
2. `PaneAgent` 加一個欄位 `stateBeforeCompaction: AgentState?`：壓縮開始前的狀態；nil 表示目前不是 lmux 標出來的壓縮。
3. `PaneAgent.handle` 的規則：

| 事件（主 agent） | 條件 | 結果 |
|---|---|---|
| `preCompact` | `state` 是 `.idle` 或 `.done` | 記住 `state`，改成 `.running`，不發 alert |
| `preCompact` | 其他狀態（回合中的自動壓縮、等待回應） | 不變 |
| `postCompact` | `stateBeforeCompaction != nil` | 回到記住的狀態，清掉，不發 alert |
| `sessionStart`（`source == "compact"`） | `stateBeforeCompaction != nil` | 同上 |
| `notification`（`idle_prompt`） | `stateBeforeCompaction != nil` | 同上（取代原本「補一個 done + alert」的路徑） |
| `userPromptSubmit`、`stop`、`stopFailure`、`interrupt`、`sessionEnd`、`sessionStart`（非 compact） | — | 清掉 `stateBeforeCompaction`，其餘照原本規則 |
| `userInterrupted()`（lmux 偵測到 Esc） | — | 清掉 `stateBeforeCompaction`，其餘照原本規則 |

4. 子 agent 的 `preCompact`／`postCompact`（`isSubagent`）不處理。

### B. 通知卡片與反白（plugin，`App/Sources/LmuxNotificationBar/NotificationBar.swift`）

1. `NotificationSummaryRow` 改成只顯示鈴鐺與未讀數；沒有通知時，下方顯示 "No notifications"。
2. 新增 `NotificationCard`，取代 `NotificationListRow`。清單顯示**全部**通知（不再 `dropFirst()`），順序不變：未讀在前、已讀在後，各自由新到舊。
3. 卡片內容：

| 行 | 有任務名稱 | 沒有任務名稱 |
|---|---|---|
| 1 | 任務名稱 + 經過時間 | workspace 名稱 + 經過時間 |
| 2 | workspace 名稱 | （不顯示） |
| 3-4 | `entry.message`，`lineLimit(2)`，尾端截斷 | 同左 |

   - 任務名稱：在所有 workspace 的 `panes` 裡找 `id == entry.paneID` 的 pane，取 `pane.titleState.title`（空字串視為沒有）。
   - workspace 名稱：沿用現有 `notificationLine` 的規則：workspace 還在用目前名稱，否則用 `entry.title`。
   - 未讀圓點與字重沿用現有規則（未讀：圓點 + 較深的字色）。
4. 反白：`entry.paneID == model.selected?.focusedPane?.id` 時畫圓角底色，形狀與顏色比照 `WorkspaceRow.pillColor`（`App/Sources/LmuxUI/Sidebar.swift:333-337`）：`rowSelected`，視窗非作用中（`controlActiveState == .inactive`）用 `rowSelectedInactive`。沒反白時維持現有的 hover 底色；反白的卡片在 hover 時底色不變。
5. 高度：`minHeight(pluginRows:)` 改成 `handleHeight + plugin 列 + 分隔線 + rowHeight（摘要列）+ cardMaxHeight`。`cardMaxHeight` 依 4 行的字型行高、行距與上下 padding 計算（用 `LmuxTokens` 的值）。

### C. 其他狀態的審查（實作 A 之前做）

使用者回報除了壓縮，還有其他狀態沒正確顯示在 tab 上。審查步驟：

1. 列出 Claude Code 文件上的全部 hook 事件與 `Notification` 的 `notification_type`（[Hooks reference](https://code.claude.com/docs/en/hooks)）。
2. 逐一對照：lmux 有沒有訂閱（`HookInstaller.events`）、狀態機怎麼處理（`PaneAgent.handle`）、sidebar 怎麼顯示。
3. 請使用者列出看過的錯誤情境，逐一對照到步驟 2 的結果。
4. 每個確認的問題：在 `compaction-running-state.feature` 補場景，在本文件的 A 節補規則，再實作。
5. 沒有對應 hook、無法修正的情境：記在「風險」。

## Key Decisions

1. **壓縮結束回到原本狀態，不發通知。**
   - 理由：壓縮不是一個回合；多一則「完成」通知會干擾。
   - 替代方案：結束時改成完成並發通知。否決：使用者沒要求，而且手動 `/compact` 的人正看著這個 tab。
   - ADR 判斷：容易改回（一行規則）→ 不寫 ADR。
2. **用 `stateBeforeCompaction` 記住原本狀態，而不是一律回到完成。**
   - 理由：閒置的 tab 也可能被壓縮（Claude Code 的 auto 也包含閒置時的壓縮，見 [Hooks reference](https://code.claude.com/docs/en/hooks)）；一律回到完成會把閒置的 tab 標成 ✓。
   - ADR 判斷：不意外、容易改 → 不寫 ADR。
3. **新 hook 靠使用者在 Settings 按 Update 加入，不改自動提示的條件。**
   - 現況：`installedHookIsStale` 只比對 hook 路徑（`App/Sources/LmuxUI/HooksSetup.swift:35-39`）；事件缺少不會提示。
   - 理由：改自動提示要多動一個 lmux 原始檔（`HooksSetup.swift`），並處理「每個路徑只問一次」的記錄（`updateOfferedKey`）。這個 fork 只有一位使用者，按一次 Update 就好。
   - 代價：忘了按 Update 時，壓縮狀態不會顯示，而且沒有任何提示。
   - ADR 判斷：容易改（之後再加提示條件即可）→ 不寫 ADR。
4. **任務名稱在顯示時讀取，不在通知當下記錄。**
   - 理由：`NotificationEntry` 是 lmux 核心的型別（`App/Sources/LmuxUI/Model.swift:694`）；加欄位要改核心。
   - 代價：tab 換了 session 後，舊通知顯示新的任務名稱。
   - ADR 判斷：容易改 → 不寫 ADR。
5. **卡片取代跑馬燈。**
   - 理由：使用者不想移動滑鼠；一直捲動的跑馬燈會在閒置時持續耗 CPU（未實測多少），而 lmux 的 apptest 有閒置 CPU 檢查。
   - ADR 判斷：UI 選擇，容易改 → 不寫 ADR。

## Components

| 檔案 | 類型 | 改動 |
|---|---|---|
| `Core/Sources/LmuxHooks/HookInstaller.swift` | lmux 原始檔 | `events` 加 2 個事件 |
| `Core/Sources/LmuxHooks/AgentState.swift` | lmux 原始檔 | `stateBeforeCompaction` 與上表規則；類別說明註解補一條規則 |
| `Core/Tests/LmuxHooksTests/AgentStateTests.swift` | lmux 測試 | `compaction-running-state.feature` 的狀態機場景 |
| `Core/Tests/LmuxHooksTests/InstallerTests.swift` | lmux 測試 | 第 87-100 行原本斷言 lmux 不碰 `PreCompact`；改成「使用者的項目保留，另有一個 lmux 項目」 |
| `App/Sources/LmuxNotificationBar/NotificationBar.swift` | plugin | 摘要列、`NotificationCard`、反白、`minHeight` |

### 測試方式

- A：`cd Core && swift test`（swift-testing）。
- B：build `App/build/lmux.app`，使用者手動確認 `notification-cards.feature` 的 `@e2e` 場景。

### 風險

- **未查證**：Claude Code 對 `/compact` 是否送 `UserPromptSubmit`。如果會送，原本就該顯示進行中；使用者回報沒顯示，推論為不送。實作後用真的 `/compact` 確認。
- **未查證**：Claude Code 是否保證送出 `PostCompact`。兩種結束回報都接受，再加上閒置提醒作為後備。
- `/Applications/lmux.app` 按 Update 會移除這 2 個 hook（`HookInstaller.swift:124-125` 移除 lmux 不再使用的事件）。
- 目前 `~/.claude/settings.json` 的 14 個 lmux hook 指向 worktree 的 `App/build/lmux.app`。重新 build 時，正在用的 lmux 會暫時收不到狀態。
