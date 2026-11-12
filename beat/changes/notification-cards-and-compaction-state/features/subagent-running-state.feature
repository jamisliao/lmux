# language: zh-TW
功能: 背景子 agent 還在跑時，tab 維持進行中

  Claude 把工作派給背景子 agent 後，主回合會先結束。這時 tab 仍然顯示進行中，
  等背景子 agent 做完、Claude 接著回應並結束，tab 才顯示完成，只發一則完成通知。
  lmux 從 Claude Code 主 agent 的 Stop 事件裡的 `background_tasks` 知道還有沒有背景子 agent 在跑。

  身為 同時開很多個 Claude tab 的使用者
  我想要 背景子 agent 還在工作時，tab 不要顯示完成
  以便 我不會太早去看結果，也不會被「完成」通知打斷兩次

  實測的事件順序（Claude Code 2.1.318）:
    UserPromptSubmit → PreToolUse(Agent) → SubagentStart → PostToolUse(Agent)
      → Stop（background_tasks 有一個 subagent，status running）
      → 子 agent 的工具事件… → SubagentStop
      → UserPromptSubmit（內容是 task-notification）→ Stop（background_tasks 沒有 subagent）

  關鍵決策:
    **只看子 agent，不看背景 shell**：背景 shell（例如 dev server）可能一直不結束，若算進去 tab 會永遠轉圈。
    **最後一個 Stop 才發完成通知**：中間那個 Stop 不發通知。
    **沒收到後續事件時由閒置提醒收尾**：沿用現有規則（閒置提醒把進行中的 tab 改成完成）。

  @behavior @happy-path
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 主回合結束時還有背景子 agent 在跑，tab 維持進行中
    假設 一個 **tab** 是 **進行中**，Claude 已經派出一個 **背景子 agent**
    當 Claude 的主回合結束，而這個背景子 agent 仍在執行
    那麼 這個 tab 仍然是 **進行中**
    而且 lmux 不發出完成通知

  @behavior @happy-path
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 背景子 agent 做完、Claude 回應完後，tab 顯示完成並只通知一次
    假設 一個 **tab** 因為 **背景子 agent** 還在跑而維持 **進行中**
    當 背景子 agent 結束，Claude 接著回應並結束主回合，這時已經沒有背景子 agent
    那麼 這個 tab 是 **完成**
    而且 整段過程 lmux 只發出一則完成通知

  @behavior @edge-case
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 還在跑的只有背景 shell 時，主回合結束就是完成
    假設 一個 **tab** 是 **進行中**，Claude 啟動了一個背景 shell
    當 Claude 的主回合結束，背景 shell 仍在執行
    那麼 這個 tab 是 **完成**
    而且 lmux 發出完成通知

  @behavior @edge-case
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 背景子 agent 已經結束時，主回合結束就是完成
    假設 一個 **tab** 是 **進行中**
    當 Claude 的主回合結束，回報中的背景子 agent 都已經結束
    那麼 這個 tab 是 **完成**
    而且 lmux 發出完成通知

  @behavior @error-handling
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
  場景: 沒收到背景子 agent 的後續事件時，閒置提醒讓 tab 顯示完成
    假設 一個 **tab** 因為 **背景子 agent** 還在跑而維持 **進行中**
    而且 lmux 之後沒有收到任何子 agent 或主回合的事件
    當 Claude 送出 **閒置提醒**
    那麼 這個 tab 是 **完成**
    而且 lmux 發出一則完成通知
