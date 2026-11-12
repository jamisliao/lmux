# 設計：通知卡片與壓縮中的進行中狀態

## Approach

兩個獨立部分，各自可以單獨實作與測試。B 部分不依賴 A 部分。

### A. 壓縮中顯示進行中（lmux 核心）

1. `HookInstaller.events` 加入 `"PreCompact"`、`"PostCompact"`。使用者在 Settings → Hooks 按 Install（舊安裝不完整時顯示 Install）後，lmux 把這 2 個事件寫進 `~/.claude/settings.json`。
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
5. App 端（`App/Sources/LmuxUI/Agent.swift` 的 `processHook`）：主 agent 的 `preCompact` 把 `pane.lastTool` 設成 `"Compacting"`。進行中時 workspace 列第 2 行顯示 `lastTool`（`App/Sources/LmuxUI/Model.swift:611-614`），所以壓縮期間顯示 `Compacting`，而不是上一個回合的工具。下一個 `PreToolUse` 或 `UserPromptSubmit` 會照原本規則覆蓋或清掉它。

### B. 通知卡片與反白（plugin，`App/Sources/LmuxNotificationBar/`）

1. `NotificationSummaryRow` 只顯示鈴鐺與未讀數，固定在清單上方（不跟著捲動）；沒有通知時，下方顯示 "No notifications"。
2. 新增 `NotificationCard.swift`，取代 `NotificationListRow`。清單顯示**全部**通知（不再 `dropFirst()`），順序不變：未讀在前、已讀在後，各自由新到舊。第一張卡片換人時，清單自動捲回最上面。
3. 卡片內容：

| 行 | 有任務名稱 | 沒有任務名稱 |
|---|---|---|
| 1 | 任務名稱 + 經過時間 | workspace 名稱 + 經過時間 |
| 2 | workspace 名稱（與第 1 行相同時不顯示） | （不顯示） |
| 3-4 | 訊息，`lineLimit(2)`，尾端截斷 | 同左 |

   - 找 pane：在所有 workspace 的 `panes` 裡找 `id == entry.paneID`（tab 被移到別的 workspace 也找得到）。
   - 任務名稱：pane 的 `titleState.title` 不是空字串時，用 `pane.headerTitle`（與 tab 列、sidebar 相同的清理規則，`Model.swift:278-288`）。否則沒有任務名稱。
   - workspace 名稱：
     1. 含這個 pane 的 workspace（找不到就用 `entry.workspaceID` 的 workspace）有手動名稱（`customTitle` 去掉空白後不是空字串）→ `workspace.title`。
     2. 否則 pane 還在且有 `cwd` → cwd 的資料夾名稱。
     3. 否則 → `entry.title`（通知當時的 workspace 名稱）。
     - 不用 `workspace.title` 的自動名稱：沒有手動名稱時，它就是 focused tab 的任務名稱（`Model.swift:543-551`），會讓卡片顯示另一個 tab 的任務。
   - 訊息：`entry.message`（Claude 最後回覆的第 1 行，最多 200 字，`App/Sources/LmuxUI/Agent.swift:841-843`），去掉開頭的 `#`、`**`、`- `、`* ` 與空白。
   - 字重：未讀 medium、已讀 regular（沿用現有規則）；未讀有圓點。
4. 反白：`entry.paneID == model.selected?.focusedPane?.id` 時畫圓角底色，比照 `WorkspaceRow.pillColor`（`App/Sources/LmuxUI/Sidebar.swift:333-337`）：`rowSelected`，視窗非作用中（`controlActiveState == .inactive`）用 `rowSelectedInactive`。沒反白時維持 hover 底色；反白的卡片在 hover 時底色不變。底色左右緣比照 sidebar 列，內縮 `T.Layout.rowInsetX`。
5. 高度：`minHeight(pluginRows:)` 改成 `handleHeight + plugin 列 + 分隔線 + rowHeight（摘要列）+ NotificationCard.maxHeight`。`maxHeight` 用實際字型的行高計算：SF 與 PingFang（中文）取較大值，避免中文內容在最小高度被切掉。

### C. 其他狀態的審查（實作的第一步）

使用者回報除了壓縮，還有其他狀態沒正確顯示在 tab 上。審查步驟：

1. 在 repo 外的暫時專案裝「只把 stdin 寫進 log」的 hook（`.claude/settings.local.json`，不動 `~/.claude/settings.json`），記錄三種情況的真實事件順序：完成時 `/compact`、閒置時 `/compact`、壓縮中按 Esc。
2. 列出 Claude Code 文件上的全部 hook 事件與 `Notification` 的 `notification_type`（[Hooks reference](https://code.claude.com/docs/en/hooks)），確認本機 `claude --version` 支援 `PostCompact`。
3. 逐一對照：lmux 有沒有訂閱（`HookInstaller.events`）、狀態機怎麼處理（`PaneAgent.handle`）、sidebar 怎麼顯示。
4. 請使用者列出看過的錯誤情境，逐一對照到步驟 3 的結果。
5. 每個確認的問題：在 `compaction-running-state.feature` 補場景，在本文件的 A 節補規則，再實作。改到 A 節既有規則時，直接改 Task 3。
6. 沒有對應 hook、無法修正的情境：記在「風險」。

## Key Decisions

1. **壓縮結束回到原本狀態，不發通知。**
   - 理由：壓縮不是一個回合；多一則「完成」通知會干擾。
   - 替代方案：結束時改成完成並發通知。否決：使用者沒要求，而且手動 `/compact` 的人正看著這個 tab。
   - ADR 判斷：容易改回（一行規則）→ 不寫 ADR。
2. **用 `stateBeforeCompaction` 記住原本狀態，而不是一律回到完成。**
   - 理由：閒置的 tab 也可能被壓縮（Claude Code 的 auto 也包含閒置時的壓縮，見 [Hooks reference](https://code.claude.com/docs/en/hooks)）；一律回到完成會把閒置的 tab 標成 ✓。
   - ADR 判斷：不意外、容易改 → 不寫 ADR。
3. **新 hook 靠使用者在 Settings 按 Install 加入，不改自動提示的條件。**
   - 現況：`installedHookIsStale` 只比對 hook 路徑（`App/Sources/LmuxUI/HooksSetup.swift:35-39`）；事件缺少不會提示。但 Settings 會顯示 "Not installed" 與 Install 按鈕（`HooksSetup.swift:48-50`、`SettingsWindow.swift:565-570`）。
   - 理由：改自動提示要多動 `HooksSetup.swift`，並處理「每個路徑只問一次」的記錄（`updateOfferedKey`）。這個 fork 只有一位使用者，按一次 Install 就好。
   - 代價：忘了按時，壓縮狀態不會顯示；只有 Settings 裡看得到提示。
   - ADR 判斷：容易改 → 不寫 ADR。
4. **任務名稱在顯示時讀取，不在通知當下記錄。**
   - 理由：`NotificationEntry` 是 lmux 核心的型別（`App/Sources/LmuxUI/Model.swift:694`）；加欄位要改核心。
   - 代價：tab 換了 session 後，舊通知顯示新的任務名稱。
   - ADR 判斷：容易改 → 不寫 ADR。
5. **卡片取代跑馬燈。**
   - 理由：使用者不想移動滑鼠；一直捲動的跑馬燈會在閒置時持續耗 CPU（未實測多少），而 lmux 的 apptest 有閒置 CPU 檢查。
   - ADR 判斷：UI 選擇，容易改 → 不寫 ADR。
6. **workspace 名稱不用 lmux 的自動名稱。**
   - 理由：見 B.3。使用者選「手動名稱，否則資料夾名稱」。
   - ADR 判斷：容易改 → 不寫 ADR。
7. **訊息維持 lmux 現有的「回覆第 1 行」。**
   - 理由：改成多行要改 `Agent.swift` 的 `firstLine`，會一起改到 sidebar 第 2 行與系統通知。使用者的回覆第 1 行就是結論，資訊量足夠。
   - ADR 判斷：容易改 → 不寫 ADR。

## Components

| 檔案 | 類型 | 改動 |
|---|---|---|
| `Core/Sources/LmuxHooks/HookInstaller.swift` | lmux 原始檔 | `events` 加 2 個事件 |
| `Core/Sources/LmuxHooks/AgentState.swift` | lmux 原始檔 | `stateBeforeCompaction` 與 A.3 的規則；類別說明註解補一條規則 |
| `App/Sources/LmuxUI/Agent.swift` | lmux 原始檔 | A.5：`preCompact` 時 `lastTool = "Compacting"` |
| `Core/Tests/LmuxHooksTests/AgentStateTests.swift` | lmux 測試 | `compaction-running-state.feature` 的狀態機場景 |
| `Core/Tests/LmuxHooksTests/InstallerTests.swift` | lmux 測試 | 第 99-100 行原本斷言 lmux 不碰 `PreCompact`；改成「使用者的項目保留，另有一個 lmux 項目」；加升級與降級測試 |
| `App/Sources/LmuxNotificationBar/NotificationCard.swift` | plugin（新） | 卡片、反白、任務名稱與 workspace 名稱的取法 |
| `App/Sources/LmuxNotificationBar/NotificationBar.swift` | plugin | 摘要列、清單、`minHeight` |

### 測試方式

- A（Core）：`cd Core && swift test`（swift-testing，全部測試）。
- A（App）與 B：`App/scripts/apptest.sh --quick`（回歸）；build `App/build/lmux.app`，使用者依手動驗證紀錄逐項確認 `@e2e` 場景。

### 風險

- **未查證**：Claude Code 對 `/compact` 送出的事件順序（會不會送 `UserPromptSubmit`、壓縮後會不會送 `Stop`、`PostCompact` 與 `SessionStart(compact)` 誰先到）。C.1 先記錄真實順序，再實作 Task 3。如果壓縮後會送 `Stop`，A.3 的規則要改（`Stop` 會先清掉記住的狀態並發 done alert）。
- **未查證**：壓縮中按 Esc，lmux 的 Esc 偵測（`App/Sources/LmuxUI/Agent.swift:308-331` 的 `interruptKeyPressed`，看 transcript 的中斷標記或終端機標題）是否成立。不成立時，tab 會維持進行中，直到閒置提醒。
- 壓縮的副作用：`lmux wait --until any` 會因壓縮結束；沒人看的 tab 被壓縮後，「未看」的呼吸提醒會消失（`App/Sources/LmuxUI/Attention.swift:32-37,151-155`）。這次不修。
- `/Applications/lmux.app` 按 Update 會移除這 2 個 hook（`HookInstaller.swift:124-125` 移除 lmux 不再使用的事件）。兩個 build 共用 UserDefaults（bundle id 相同），正式版重開時可能跳出更新提示。
- 目前 `~/.claude/settings.json` 的 lmux hook 指向 worktree 的 `App/build/lmux.app`。重新 build 時，正在用的 lmux 會暫時收不到狀態。
- `Core/Sources/LmuxHooks/HookEvent.swift:19-21,41` 的註解說 `PostCompact` 只有 Codex 送，與 Claude Code 現況不符。檔案不在這次的修改範圍，不改。
- 卡片的 `maxHeight` 用 `NSLayoutManager.defaultLineHeight` 估計 SwiftUI `Text` 的行高，未實測；Task 8 用中文內容確認最後一行沒被切掉。
