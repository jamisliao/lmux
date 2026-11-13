# language: zh-TW
功能: 壓縮中顯示進行中

  Claude Code 壓縮對話時，lmux 把 tab 標成進行中；壓縮結束後回到原本的狀態。
  lmux 從 Claude Code 的 hook 得知壓縮的開始（PreCompact）與結束（PostCompact，
  或 SessionStart 的 source 為 compact）。

  身為 整天在 lmux 裡用 Claude Code 的使用者
  我想要 在 Claude 壓縮對話時看到 tab 是進行中
  以便 我不會以為 Claude 已經閒置，而在壓縮期間輸入或切走

  資料流:
    Claude Code ──PreCompact／PostCompact／SessionStart(compact)──▶ lmux-hook
      ──▶ lmux 狀態機（每個 tab 一份）──▶ sidebar 的 workspace 列（轉圈圖示）

  關鍵決策:
    **壓縮結束不發通知**：壓縮不是一個回合。回到原本的狀態即可，不多發一則「完成」通知。
    **只在閒置或完成時改成進行中**：回合中的自動壓縮本來就是進行中，狀態不變，也不記住任何東西。
    **兩種結束回報都接受**：PostCompact 與 SessionStart(compact) 都代表壓縮結束；先到的那個生效，後到的不再改變狀態。
    **舊安裝要手動更新**：lmux 只在 hook 路徑改變時自動提示更新。已安裝 hook 的使用者要在 Settings → Hooks 按 Install（舊安裝少了壓縮事件，顯示為未安裝），才會加入 PreCompact 與 PostCompact。

  # --- 手動壓縮 ---

  @behavior @happy-path
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 已完成的 tab 開始壓縮時顯示進行中
    假設 一個 **tab** 是 **完成**
    當 使用者在這個 tab 開始 **壓縮**
    那麼 這個 tab 是 **進行中**

  @behavior @happy-path
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 壓縮結束後回到完成，不發通知
    假設 一個 **完成** 的 **tab** 正在 **壓縮**
    當 Claude Code 回報壓縮結束
    那麼 這個 tab 回到 **完成**
    而且 lmux 不發出新的通知

  @e2e @happy-path
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 壓縮期間 workspace 列第 2 行顯示 Compacting
    假設 一個 **tab** 的上一個回合用過 Bash 工具，回合已經 **完成**
    當 使用者在這個 tab 開始 **壓縮**
    那麼 sidebar 的 workspace 列第 2 行顯示 "Compacting"
    而且 不顯示上一個回合的 Bash 工具

  @behavior @happy-path
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 閒置的 tab 壓縮結束後回到閒置
    假設 一個 **閒置** 的 **tab** 開始 **壓縮**
    當 Claude Code 回報壓縮結束
    那麼 這個 tab 回到 **閒置**
    而且 lmux 不發出新的通知

  @behavior @edge-case
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 兩種結束回報都送來時只處理第一個
    假設 一個 **完成** 的 **tab** 正在 **壓縮**
    當 Claude Code 先送 PostCompact，再送 source 為 compact 的 SessionStart
    那麼 這個 tab 是 **完成**
    而且 lmux 不發出新的通知

  @behavior @error-handling
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 沒收到結束回報時，閒置提醒讓 tab 回到原本的狀態
    假設 一個 **完成** 的 **tab** 正在 **壓縮**
    而且 Claude Code 沒有回報壓縮結束
    當 Claude Code 送出 **閒置提醒**
    那麼 這個 tab 回到 **完成**
    而且 lmux 不發出新的通知

  @behavior @edge-case
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 壓縮期間使用者按 Esc 中斷
    假設 一個 **完成** 的 **tab** 正在 **壓縮**
    當 lmux 判定使用者按 Esc 中斷了 Claude
    那麼 這個 tab 是 **閒置**
    而且 之後收到的壓縮結束回報不改變這個 tab 的狀態

  @behavior @edge-case
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 壓縮期間使用者送出新的 prompt
    假設 一個 **完成** 的 **tab** 正在 **壓縮**
    當 使用者送出新的 prompt
    那麼 這個 tab 是 **進行中**
    而且 之後收到的壓縮結束回報不改變這個 tab 的狀態

  # --- 自動壓縮 ---

  @behavior @edge-case
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 回合中的自動壓縮結束後，tab 不算在壓縮中
    假設 一個 **進行中** 的 **tab** 在回合中自動 **壓縮**，壓縮已經結束
    當 使用者按 Esc
    那麼 這個 tab 照一般的中斷規則判斷，不會因為剛壓縮過就直接視為中斷

  @behavior @happy-path
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 回合中的自動壓縮不改變狀態
    假設 一個 **tab** 是 **進行中**
    當 Claude Code 在回合中自動開始 **壓縮**，接著回報壓縮結束
    那麼 這個 tab 仍然是 **進行中**
    而且 lmux 不發出新的通知

  # --- hook 安裝 ---

  @behavior @happy-path
  # @covered-by: Core/Tests/LmuxHooksTests/InstallerTests.swift
  場景: 更新 hook 時加入壓縮事件，保留使用者自己的壓縮 hook
    假設 使用者的 Claude Code 設定檔有舊版 lmux 裝的 hook，其中沒有 PreCompact 與 PostCompact
    而且 設定檔有使用者自己的 PreCompact hook
    當 lmux 更新 hook
    那麼 設定檔的 PreCompact 與 PostCompact 各有一個 lmux 的項目
    而且 使用者自己的 PreCompact hook 仍然保留
