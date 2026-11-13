# agent-state

每個 tab 的 agent 狀態（進行中、完成、閒置、等待回應）如何隨 Claude Code 的 hook 事件改變。

- `compaction-running-state.feature`：壓縮時 tab 顯示進行中，結束後回到原本的狀態，不發通知。
- `subagent-running-state.feature`：主回合結束但背景子 agent 還在跑時，tab 維持進行中。
- `proposal.md`、`design.md`：來自 change `notification-cards-and-compaction-state`（涵蓋本資料夾、`notification-bar`、`build` 三個 capability）。

程式：`Core/Sources/LmuxHooks/AgentState.swift`、`HookEvent.swift`、`HookInstaller.swift`；測試：`Core/Tests/LmuxHooksTests/`。
