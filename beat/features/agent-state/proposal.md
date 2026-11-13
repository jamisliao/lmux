# 通知卡片與壓縮中的進行中狀態

## Why

1. **壓縮時 tab 看起來閒置。** 使用者打 `/compact` 後，sidebar 仍顯示完成或閒置，看不出 Claude 正在壓縮。
   - 原因：（修改前）lmux 沒訂閱 `PreCompact`／`PostCompact` hook（`Core/Sources/LmuxHooks/HookInstaller.swift` 的 `events`），狀態機收到也忽略（`AgentState.swift` 的 `case .preCompact, .postCompact, .unknown: break`）。
2. **通知清單看不出哪幾則來自目前 focus 的 tab。** 清單只顯示 workspace 名稱，同一個 workspace 的多個 tab 無法分辨。
3. **通知文字被截斷，看不出原本的任務。** 每則通知只有一行，訊息尾端被 `…` 截掉。使用者不想移動滑鼠去看完整內容。
   - 原本要求跑馬燈。改成卡片：使用者的目標是「不移動滑鼠就看到通知原本的任務在做什麼」，卡片一次顯示任務名稱與兩行訊息，不必等文字捲動。
4. **其他狀態也沒正確顯示在 tab 上。** 使用者回報除了壓縮，還有狀態顯示不對。審查後找到一個：背景子 agent 還在跑時，主 agent 的 Stop 一到 tab 就顯示完成並通知，子 agent 做完後又通知一次。
5. **分不出是哪一次 build。** 使用者同時開正式版與多個自己編的測試版，而 `App/scripts/bundle.sh` 把版本寫死成 `0.0.1`／`1`，每次 build 都一樣。

## What Changes

1. **壓縮中顯示進行中**
   - lmux 多訂閱 2 個 Claude Code hook：`PreCompact`、`PostCompact`。
   - tab 閒置或完成時開始壓縮：改成進行中，記住原本的狀態。
   - 壓縮結束：回到原本的狀態，不發通知。壓縮期間若 tab 已變成等待回應或閒置，不蓋回去。
   - 回合中的自動壓縮：狀態不變（本來就是進行中）。
   - 壓縮期間，sidebar 的 workspace 列第 2 行顯示 `Compacting`，不顯示上一個回合用的工具。
   - 壓縮中按 Esc：Claude 會取消壓縮，tab 視為中斷、改成閒置。
2. **反白 focused tab 的通知**
   - 只反白來自目前 workspace 的 focused tab 的**最新一則**通知卡片。
   - 底色與 sidebar 選取列相同。
3. **通知卡片**
   - 清單的每則通知改成卡片，最多 4 行：任務名稱與經過時間、workspace 名稱、訊息（最多 2 行）。
   - workspace 名稱：workspace 有手動名稱就用它；否則用 tab 工作目錄的資料夾名稱；tab 已關閉時用通知當時的名稱。與第 1 行相同時不顯示。
   - 沒有任務名稱時，第 1 行改成 workspace 名稱，不顯示第 2 行。
   - 訊息是 Claude 最後回覆的第 1 行（lmux 現有規則，最多 200 字）；開頭的 Markdown 標記（`#`、`- `、`* `、`> `、`**…**`，可疊加）不顯示，訊息中間的保留。
   - 清單最上面的摘要列只留鈴鐺與未讀數；第一則未讀通知（沒有未讀時是最新一則）也用卡片顯示。
   - 通知 bar 的最小高度改成「摘要列 + 1 張卡片」。
4. **背景子 agent 還在跑時，tab 維持進行中**
   - 主 agent 的 Stop 帶 `background_tasks` 有還在跑的子 agent 時，tab 維持進行中、不發完成通知；最後一個 Stop 才完成。
   - 背景 shell（例如 dev server）不算，避免 tab 永遠轉圈。
5. **build 版號**
   - build 時由 git 產生版號（`<commit 數>-<commit 短碼>[-dirty]`），寫進 Info.plist 的 `CFBundleVersion`，About 視窗會顯示。
   - 通知 bar 的摘要列右邊用小字顯示同一個版號。

## Impact

- **lmux 原始檔（不含測試）**：改動的檔案從 3 個（`RootView.swift`、`Package.swift`、`main.swift`）增加到 8 個。新增 `Core/Sources/LmuxHooks/HookInstaller.swift`、`AgentState.swift`、`HookEvent.swift`（讀 Stop 的 `background_tasks`）、`App/Sources/LmuxUI/Agent.swift`、`App/scripts/bundle.sh`（2 行：1 行註解、1 行把 build 版號寫進 Info.plist）。rebase 到新版 lmux 時要多檢查這 5 個檔案。另有一個與功能無關的 `Core/Tests/LmuxTranscriptTests/TranscriptIndexTests.swift` 1 行修正（Swift 6.4.2 type-check）。
- **plugin 與腳本（我們自己的檔案）**：`App/Sources/LmuxNotificationBar/` 的 `NotificationBar.swift`、新增 `NotificationCard.swift`、`MessageText.swift`；新增 `App/scripts/` 的 `message-text-check.swift`、`build-id.sh`、`build-id-check.sh`。
- **測試**：`Core/Tests/LmuxHooksTests/` 的 `AgentStateTests.swift`（壓縮、背景子 agent）、`EventParsingTests.swift`（測試用 payload、`background_tasks` 解析）、`InstallerTests.swift`（原本斷言「lmux 不碰使用者自己的 `PreCompact`」，改成「保留使用者的項目，另外加上 lmux 的項目」，加升級與降級測試）。兩個自我檢查腳本（`message-text-check.swift`、`build-id-check.sh`）手動執行，沒有接進 CI。
- **使用者設定檔**：舊的安裝少了 2 個事件，測試版的 Settings → Hooks 會顯示 **Install**（不是 Update，`App/Sources/LmuxUI/SettingsWindow.swift:565`）。按下後 `~/.claude/settings.json` 多 2 個 lmux hook 項目。lmux 不會自動提示這次更新（只在 hook 路徑改變時提示，`App/Sources/LmuxUI/HooksSetup.swift:86`）。
- **與官方 lmux 共存**：兩個 build 的 bundle id 相同，共用 UserDefaults。`/Applications/lmux.app` 若在測試期間重開，可能跳出「更新 hook」；按下去會移除這 2 個 hook，壓縮狀態就不再顯示。
- **壓縮的副作用**（狀態從完成變成進行中再變回完成）：
  - `lmux wait --until any` 會因為壓縮而結束（`stateChangedAt` 會更新）。
  - 沒人看的 tab 被壓縮時，「未看」的呼吸提醒會消失（進行中時清掉 `attentionSince`，回到完成時不發 alert）。
- **畫面**：通知 bar 預設高度變高；同樣高度內顯示的通知數變少。
- **不受影響**：plugin 協定（stdin/stdout JSON）、⇧⌘U 跳到最新未讀、鈴鐺彈出清單、Codex（沒訂閱壓縮事件）。
