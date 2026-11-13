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

**A'. 背景子 agent（`subagent-running-state.feature`）**

| 事件（主 agent） | 條件 | 結果 |
|---|---|---|
| `stop` | `background_tasks` 有 `type == "subagent"` 且 `status == "running"` 的項目 | `state = .running`，不發 alert，**不清掉** `activeSubagents` |
| `stop` | 其他（沒有，或只有背景 shell，或子 agent 已結束） | 照原本規則（完成 + alert，清掉 `activeSubagents`） |

- `HookEvent` 新欄位 `runningBackgroundSubagents: Int`：數 `background_tasks` 裡 `type == "subagent"` 且 `status == "running"` 的項目。
- 後續的 `SubagentStop`、`UserPromptSubmit`（task-notification）、最後一個 `Stop` 都照原本規則；沒收到時，`idle_prompt` 照原本規則補成完成。
- 已知限制：背景子 agent 跑超過閒置提醒的間隔時，`idle_prompt` 會讓 tab 提早顯示完成（未實測間隔）。
5. App 端（`App/Sources/LmuxUI/Agent.swift` 的 `processHook`）：主 agent 的 `preCompact` 把 `pane.lastTool` 設成 `"Compacting"`。進行中時 workspace 列第 2 行顯示 `lastTool`（`App/Sources/LmuxUI/Model.swift:611-614`），所以壓縮期間顯示 `Compacting`，而不是上一個回合的工具。下一個 `PreToolUse` 或 `UserPromptSubmit` 會照原本規則覆蓋或清掉它。
6. App 端的 Esc 偵測（`Agent.swift` 的 `interruptKeyPressed`）：壓縮中（`pane.agent.isCompacting`，即 lmux 標成 running 的壓縮；回合中的自動壓縮、壓縮結束後都是 false，verify 審查指出原本看 `lastTool` 文字會在回合中壓縮後誤判）按 Esc，在第 2 次檢查（900ms）時視為中斷，tab 改成閒置。原因：**實機確認（2026-11-12 18:10）**壓縮中按 Esc，Claude 會取消壓縮，但 tab 仍顯示 `Compacting`；取消壓縮不寫 transcript 的中斷標記，標題也沒變回 `✳`。限制：Esc 若沒有取消壓縮（例如壓縮其實繼續），tab 會顯示閒置，直到下一個事件。

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
4. 反白：只反白**來自 focused tab 的最新一則**通知（`NotificationList` 用 `model.notifications.first { $0.paneID == focusedPaneID }` 找出，傳給卡片的 `highlighted`；同一個 tab 的舊通知不反白，使用者實機回報 2026-11-13）。畫圓角底色，比照 `WorkspaceRow.pillColor`（`App/Sources/LmuxUI/Sidebar.swift:333-337`）：`rowSelected`，視窗非作用中（`controlActiveState == .inactive`）用 `rowSelectedInactive`。沒反白時維持 hover 底色；反白的卡片在 hover 時底色不變。底色左右緣比照 sidebar 列，內縮 `T.Layout.rowInsetX`。
5. 高度：`minHeight(pluginRows:)` 改成 `handleHeight + plugin 列 + 分隔線 + rowHeight（摘要列）+ NotificationCard.maxHeight`。`maxHeight` 用實際字型的行高計算：SF 與 PingFang（中文）取較大值，避免中文內容在最小高度被切掉。

### D. build 版號（`build-version.feature`）

1. `App/scripts/build-id.sh`（新）：印出版號。`git rev-list --count HEAD` 加 `-` 加 `git rev-parse --short HEAD`；`git status --porcelain` 不是空的就加 `-dirty`；不在 git 底下、或 git 不可用時印 `1`。
2. `App/scripts/bundle.sh`（改 1 行）：Info.plist 寫好後，用 PlistBuddy 把 `CFBundleVersion` 設成 `build-id.sh` 的輸出。不動 `CFBundleShortVersionString`（上游版本；`release/package.sh:91-92` 發佈時自己會改寫，不受影響）。
3. `NotificationSummaryRow`（plugin）：讀 `Bundle.main.infoDictionary?["CFBundleVersion"]`，在未讀數左邊用 `rowMeta` 字型、`textTertiary` 顏色顯示；`lineLimit(1)`、`truncationMode(.head)`、低 `layoutPriority`，窄的時候先被截斷；`.help("lmux build <版號>")`。
4. 為什麼用 `git rev-list --count HEAD` 而不是「從 base commit 起算」：base 是上游某個 commit，rebase 之後會變，寫死會錯；總數單調遞增，足以分辨先後。代價：rebase 後同一份程式的數字會變。
5. 為什麼 `dirty` 看 `git status --porcelain`：測試版常在未提交的狀態下 build，要看得出來。代價：`beat/` 文件改動也算 dirty（未區分）。

### C. 其他狀態的審查（實作的第一步）

使用者回報除了壓縮，還有其他狀態沒正確顯示在 tab 上。審查步驟：

1. 在 repo 外的暫時專案裝「只把 stdin 寫進 log」的 hook（`.claude/settings.local.json`，不動 `~/.claude/settings.json`），記錄三種情況的真實事件順序：完成時 `/compact`、閒置時 `/compact`、壓縮中按 Esc。
2. 列出 Claude Code 文件上的全部 hook 事件與 `Notification` 的 `notification_type`（[Hooks reference](https://code.claude.com/docs/en/hooks)），確認本機 `claude --version` 支援 `PostCompact`。
3. 逐一對照：lmux 有沒有訂閱（`HookInstaller.events`）、狀態機怎麼處理（`PaneAgent.handle`）、sidebar 怎麼顯示。
4. 請使用者列出看過的錯誤情境，逐一對照到步驟 3 的結果。
5. 每個確認的問題：在 `compaction-running-state.feature` 補場景，在本文件的 A 節補規則，再實作。改到 A 節既有規則時，直接改 Task 3。
6. 沒有對應 hook、無法修正的情境：記在「風險」。

#### 審查結果（進行中，2026-11-12）

使用者回報的兩種情境：**子 agent 執行中**、**等我回答問題**，tab 顯示不對（細節待使用者描述）。

lmux 目前訂閱 16 個事件。Claude Code 2.1.318 的 binary 內還有這些名稱（只確認字串存在，是否為 hook 事件、何時觸發：未查證）：`PermissionDenied`、`PostToolBatch`、`TaskCreated`、`TaskCompleted`、`TeammateIdle`、`UserPromptExpansion`。

| 情境 | 目前行為（來源） | 可能的問題（未實測） |
|---|---|---|
| 子 agent 執行中 | 主 agent 的 `Stop` 一到就變成完成，並清掉子 agent 計數（`Core/Sources/LmuxHooks/AgentState.swift:177-184`）；之後子 agent 的事件不會讓它回到進行中（`AgentStateTests.swift:104-109`） | **已查證（2026-11-12 16:29，`compact-probe/events2.log`）**：派出背景子 agent 後，主 agent 的 `Stop` 在 16:29:06 到，其 `background_tasks` 有 `{"type":"subagent","status":"running"}`；子 agent 到 16:29:16 才 `SubagentStop`。這 10 秒 tab 顯示完成並發通知。16:29:17 又來一個 `UserPromptSubmit`（內容是 `<task-notification>`），16:29:19 再 `Stop` 一次，所以會發兩次完成通知。修法：A'。 |
| 等我回答問題 | 已查證：在 `permission_mode: auto` 下，`AskUserQuestion` 的事件順序是 `PreToolUse` → `PermissionRequest` → `Notification(permission_prompt)` → `PostToolUse`，lmux 都會處理，**這個模式下重現不了**。**結論（2026-11-12 17:00）：無法重現，這次不修。** 在 `--permission-mode default` 下再記錄一次，仍沒有任何權限提示：使用者的 `~/.claude/settings.json` 有 `"defaultMode": "auto"`，`touch` 指令被自動核准（`PreToolUse` 後 1 秒就 `PostToolUse`，沒有 `PermissionRequest`）。使用者再被問時說「當時 Claude 沒有在問問題，tab 顯示完成 ✓」，這是正確的顯示（Claude 回合結束、等使用者），不是錯誤。若之後在真實使用中遇到 Claude 明確在等回答卻沒顯示需要輸入，請記下當時的事件再回報。需要輸入的來源：`PermissionRequest`、`Notification`（`permission_prompt` 等）、`AskUserQuestion`、`ExitPlanMode`、`Elicitation`；已在等待時，第二個提問不更新原因與訊息（`AgentState.swift:95-100`）；回到進行中靠同一個 agent 的下一個工具事件 | 拒絕權限時可能沒有任何事件（`PermissionDenied` 未訂閱），tab 停在需要輸入，直到下一個工具事件或 `Stop` |

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
| `Core/Sources/LmuxHooks/AgentState.swift` | lmux 原始檔 | `stateBeforeCompaction` 與 A.3 的規則；A' 的規則；類別說明註解補規則 |
| `Core/Sources/LmuxHooks/HookEvent.swift` | lmux 原始檔 | A'：新欄位 `runningBackgroundSubagents`（使用者 2026-11-12 同意修改） |
| `App/Sources/LmuxUI/Agent.swift` | lmux 原始檔 | A.5：`preCompact` 時 `lastTool = "Compacting"` |
| `Core/Tests/LmuxHooksTests/AgentStateTests.swift` | lmux 測試 | `compaction-running-state.feature` 的狀態機場景 |
| `Core/Tests/LmuxHooksTests/InstallerTests.swift` | lmux 測試 | 第 99-100 行原本斷言 lmux 不碰 `PreCompact`；改成「使用者的項目保留，另有一個 lmux 項目」；加升級與降級測試 |
| `App/Sources/LmuxNotificationBar/NotificationCard.swift` | plugin（新） | 卡片、反白、任務名稱與 workspace 名稱的取法 |
| `App/scripts/build-id.sh`、`App/scripts/build-id-check.sh` | 腳本（新） | D.1：產生 build 版號；自我檢查（在暫時的 git 專案裡跑） |
| `App/scripts/bundle.sh` | lmux 原始檔 | D.2：1 行，把 build 版號寫進 Info.plist |
| `App/Sources/LmuxNotificationBar/MessageText.swift`、`App/scripts/message-text-check.swift` | plugin（新） | `plainMessage`：只拿掉開頭的 Markdown 標記；自我檢查（`swiftc` 單獨編譯執行，比照 `plugin-protocol-check.swift`） |
| `App/Sources/LmuxNotificationBar/NotificationBar.swift` | plugin | 摘要列、清單、`minHeight` |

### 測試方式

- A（Core）：`cd Core && swift test`（swift-testing，全部測試）。
- A（App）與 B：`App/scripts/apptest.sh --quick`（回歸）；build `App/build/lmux.app`，使用者依手動驗證紀錄逐項確認 `@e2e` 場景。

### 風險

- **已查證（2026-11-12，Claude Code 2.1.318，完成後手動 `/compact`）**：實際事件順序是 `PreCompact(manual)` → `SessionStart(compact)` → `PostCompact(manual)`。不送 `UserPromptSubmit`，壓縮後不送 `Stop`。所以 A.3 的規則不用改：`SessionStart(compact)` 先到、先結束壓縮，`PostCompact` 之後到、不再改變狀態。來源：scratchpad 的 `compact-probe/events.jsonl`。
- **未查證**：閒置時 `/compact`（沒有先送 prompt）的事件順序，推論與上面相同。
- **未查證**：壓縮中按 Esc，lmux 的 Esc 偵測（`App/Sources/LmuxUI/Agent.swift:308-331` 的 `interruptKeyPressed`，看 transcript 的中斷標記或終端機標題）是否成立。不成立時，tab 會維持進行中，直到閒置提醒。
- 壓縮的副作用：`lmux wait --until any` 會因壓縮結束；沒人看的 tab 被壓縮後，「未看」的呼吸提醒會消失（`App/Sources/LmuxUI/Attention.swift:32-37,151-155`）。這次不修。
- `/Applications/lmux.app` 按 Update 會移除這 2 個 hook（`HookInstaller.swift:124-125` 移除 lmux 不再使用的事件）。兩個 build 共用 UserDefaults（bundle id 相同），正式版重開時可能跳出更新提示。
- 目前 `~/.claude/settings.json` 的 lmux hook 指向 worktree 的 `App/build/lmux.app`。重新 build 時，正在用的 lmux 會暫時收不到狀態。
- `Core/Sources/LmuxHooks/HookEvent.swift:19-21,41` 的註解說 `PostCompact` 只有 Codex 送，與 Claude Code 現況不符。檔案不在這次的修改範圍，不改。
- 卡片的 `maxHeight` 用 `NSLayoutManager.defaultLineHeight` 估計 SwiftUI `Text` 的行高，未實測；Task 8 用中文內容確認最後一行沒被切掉。
