# `lmux ask` 採原生 SwiftUI 面板與兩階段控制 Socket RPC，不內嵌 WebView 或介入 `lmux-hook`

為避免模型耗費輸出 Token 撰寫 HTML 或破壞 `lmux-hook` 的高頻非阻塞旁聽原則，我們決定在 **右側 Inspector** 以純原生 SwiftUI 實作動態 **待確認面板**，透過既有 `ControlServer` 單行協議（`ask-create` 同步建立 ＋ `ask-wait` 長連線等待）收發與 `ask-me` 相容的 JSON，並在本機直接分析 session 對話紀錄產生零 Token **Session 上下文補充**。

## Considered Options

- **在右側欄內嵌 `WKWebView` 載入 HTML 表單或透過「即時預覽」渲染 Mermaid**：每次提問啟動 WebContent 進程成本高，且 lmux 的 Markdown 預覽為確保安全已停用 JavaScript（`allowsContentJavaScript = false` 與嚴格 CSP）並未內建 `mermaid.min.js`，強行轉開預覽還會覆蓋使用者原本開啟的預覽檔。
- **在 `lmux-hook` 內建 `AskUserQuestion` 攔截與退回政策**：將提示詞規範（如字數門檻、洗 AI 腔、bounce 次數）硬編進 Swift 執行檔會拉高維護成本，並可能影響 `lmux-hook` 的 5 秒非阻塞延遲預算；保留由外部 `ask-me` skill 負責攔截並於偵測到 `$LMUX_CONTROL_SOCKET` 時橋接 `lmux ask`，職責更乾淨。

## Consequences

- `lmux ask` 成為與 `lmux notify`、`lmux wait` 平級的通用受控原語（依 `LMUX_PANE_NONCE` 與外部輸入授權保護），可供 Claude Code、Codex 與本機腳本呼叫；若題目附帶 `mermaid` 欄位，以可折疊等寬程式碼卡加複製按鈕呈現，維持日常零 WebView 與零 JS 膨脹。

來源：`beat/changes/inspector-ask-panel/design.md`（2026-11-24）。
