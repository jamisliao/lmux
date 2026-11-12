# 通知卡片與壓縮中的進行中狀態

## Why

1. **壓縮時 tab 看起來閒置。** 使用者打 `/compact` 後，sidebar 與 tab 列仍顯示完成或閒置，看不出 Claude 正在壓縮。
   - 原因：lmux 沒訂閱 `PreCompact`／`PostCompact` hook（`Core/Sources/LmuxHooks/HookInstaller.swift:27-32`），狀態機收到也忽略（`Core/Sources/LmuxHooks/AgentState.swift:201`）。
2. **通知清單看不出哪幾則來自目前 focus 的 tab。** 清單只顯示 workspace 名稱，同一個 workspace 的多個 tab 無法分辨。
3. **通知文字被截斷，看不出原本的任務。** 每則通知只有一行，訊息尾端被 `…` 截掉。使用者不想移動滑鼠去看完整內容。
   - 原本要求跑馬燈。改成卡片：使用者的目標是「不移動滑鼠就看到通知原本的任務在做什麼」，卡片一次顯示任務名稱與兩行訊息，不必等文字捲動。

## What Changes

1. **壓縮中顯示進行中**
   - lmux 多訂閱 2 個 Claude Code hook：`PreCompact`、`PostCompact`。
   - tab 閒置或完成時開始壓縮：改成進行中，記住原本的狀態。
   - 壓縮結束：回到原本的狀態，不發通知。
   - 回合中的自動壓縮：狀態不變（本來就是進行中）。
2. **反白 focused tab 的通知**
   - 通知來自目前 workspace 的 focused tab 時，通知卡片的底色反白。
   - 底色與 sidebar 選取列相同。
3. **通知卡片**
   - 清單的每則通知改成卡片，最多 4 行：任務名稱與經過時間、workspace 名稱、訊息（最多 2 行）。
   - 沒有任務名稱時，第 1 行改成 workspace 名稱，不顯示第 2 行。
   - 清單最上面的摘要列只留鈴鐺與未讀數；最新一則也用卡片顯示。
   - 通知 bar 的最小高度改成「摘要列 + 1 張卡片」。

4. **審查其他狀態**
   - 使用者回報：除了壓縮，還有其他狀態也沒正確顯示在 tab 上（哪些狀態尚未確認）。
   - 實作前先審查：Claude Code 的每個 hook 事件與通知類型，對照 lmux 的訂閱清單與狀態機。
   - 每個找到的問題補成 `compaction-running-state.feature` 的場景，再實作。

## Impact

- **lmux 原始檔（不含測試）**：改動的檔案從 3 個（`RootView.swift`、`Package.swift`、`main.swift`）增加到 5 個。新增 `Core/Sources/LmuxHooks/HookInstaller.swift`、`Core/Sources/LmuxHooks/AgentState.swift`。rebase 到新版 lmux 時要多檢查這 2 個檔案。
- **plugin 檔案**：`App/Sources/LmuxNotificationBar/NotificationBar.swift`。
- **測試**：`Core/Tests/LmuxHooksTests/AgentStateTests.swift` 新增壓縮的案例；`Core/Tests/LmuxHooksTests/InstallerTests.swift` 原本斷言「lmux 不碰使用者自己的 `PreCompact` hook」，要改成「保留使用者的項目，另外加上 lmux 的項目」。
- **使用者設定檔**：在 Settings → Hooks 按 Update 後，`~/.claude/settings.json` 多 2 個 lmux hook 項目。lmux 不會自動提示這次更新（只在 hook 路徑改變時提示，`App/Sources/LmuxUI/HooksSetup.swift:86`）。
- **與官方 lmux 共存**：`/Applications/lmux.app` 之後若按 Update，會移除這 2 個 hook，壓縮狀態就不再顯示。
- **畫面**：通知 bar 預設高度變高；同樣高度內顯示的通知數變少。
- **不受影響**：plugin 協定（stdin/stdout JSON）、⇧⌘U 跳到最新未讀、鈴鐺彈出清單。
