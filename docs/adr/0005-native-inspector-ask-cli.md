# `lmux ask` 採原生 SwiftUI 面板與控制 Socket 長連線，不內嵌 WebView 或介入 `lmux-hook`

為避免模型耗費輸出 Token 撰寫 HTML 或破壞 `lmux-hook` 的高頻非阻塞旁聽原則，我們決定在 **右側 Inspector** 以純原生 SwiftUI 實作動態 **待確認面板**，透過既有 `ControlServer` 長連線（`lmux ask --spec`／`--wait`）收發與 `ask-me` 相容的 JSON，並在本機直接分析 session 對話紀錄產生零 Token **Session 上下文補充**。

## Considered Options

- **在右側欄內嵌 `WKWebView` 直接載入 HTML 表單**：每次提問都須啟動額外 WebContent 進程、與原生 Liquid Glass 雙主題／鍵盤焦點同步成本高，且若由模型產出 HTML 會顯著增加輸出 Token。
- **在 `lmux-hook` 內建 `AskUserQuestion` 攔截與退回政策**：將提示詞規範（如字數門檻、洗 AI 腔、bounce 次數）硬編進 Swift 執行檔會拉高維護成本，並可能影響 `lmux-hook` 的 5 秒非阻塞延遲預算；保留由外部 `ask-me` skill 負責攔截並於偵測到 `$LMUX_CONTROL_SOCKET` 時橋接 `lmux ask`，職責更乾淨。

## Consequences

- `lmux ask` 成為與 `lmux notify`、`lmux wait` 平級的通用原語，可供 Claude Code、Codex 與任何本機腳本呼叫；若題目附帶 `mermaid` 欄位，預設以等寬程式碼呈現並提供一鍵轉開「即時預覽」繪圖，維持日常零 WebView 開銷。

來源：`beat/changes/inspector-ask-panel/design.md`（2026-11-24）。
