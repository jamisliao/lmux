# Core Agent 遙測採 Hook 即時事件與 JSONL 增量讀取雙軌彙整

**Agent 遙測**（模型名稱、Turn 次數、Context Window token 用量、估算費用與最近 Tool Call 串流）在 `Core` 層拆分兩條來源合併：工具開始／完成／失敗與耗時透過既有 `lmux-hook` Unix socket 即時接收以達到亞秒級更新；模型與 `usage`（input / cache read / cache creation / output tokens）則由 `LmuxTranscript` 增量讀取 Claude `.jsonl` 與 Codex `CodexRollout` 檔案取得，維持「lmux 只旁聽不包裹 CLI」原則，不透過子程序或輪詢外部 API 干擾使用者終端機。

## Considered Options

- **僅依賴 Hook payload 取得所有遙測**：Claude Code / Codex Hook stdin 未攜帶完整 context token 與 cache 命中明細，無法算出準確負載百分比。
- **以定時器重讀整份對話檔或呼叫外部狀態命令**：長對話下 I/O 與 CPU 成本過高，且會干擾互動會話。

來源：`beat/changes/preview-liquid-glass/design.md`（2026-11-18）。
