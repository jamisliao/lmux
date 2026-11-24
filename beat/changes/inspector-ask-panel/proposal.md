# 右側 Inspector 原生問答面板與零 Token Session 上下文補充

## Why

使用 Claude Code 或 Codex 協作開發時，終端機內建的 `AskUserQuestion` 問答框空間極小，塞不下背景說明、程式碼差異與多題結構化決策，導致使用者從別的分頁切回來或中斷一段時間後「冷啟動」看不懂問題脈絡。

改用外部本機網頁（如 `ask-me`）雖然補上了豐富介面，但會跳出多個外部瀏覽器視窗、預設瀏覽器送出後無法自動關閉，也與 lmux 的多 **workspace** 注意力通知系統脫節；而如果讓模型輸出 HTML 或手動把大量程式碼／前情提要重新抄進題目，又會浪費大量輸出 Token。

lmux 本身已經具備純原生 SwiftUI 的 **右側 Inspector**、`ControlServer` 單行 RPC 與長連線等待機制、**通知 bar** 注意力系統，以及可增量讀取 Claude JSONL 與 Codex Rollout 的 `Core/LmuxTranscript` 管線。透過新增 `lmux ask` 原生 CLI 與 **待確認面板**，並由 lmux 在本機直接分析來源 session 的對話紀錄與工作區異動自動產生 **Session 上下文補充**，即可做到：
1. **零 HTML／零 WebView 開銷**：介面完全由原生 SwiftUI 與既有 Liquid Glass 元件繪製，效能與視覺一致。
2. **極省 LLM Token**：模型不需輸出 HTML，也不用重述整個歷史進度或抄寫大段程式碼（改以本機路徑引用 `refs`／`gitDiff` 搭配自動抽取的 **Session 上下文補充**）。
3. **無縫整合多 Agent 工作流**：背景 tab 提問直接觸發 `🔔 需要確認` 與 **通知卡片**，點選即跳回該 **終端機 tab** 並展開 **待確認面板**，同時完整對齊 `ask-me` 的 spec JSON 與回傳契約，讓外部 skill 可直接橋接。

## What Changes

1. **零 Token 本地 Session 上下文抽取（`Core/LmuxTranscript` + `App/LmuxUI`）**：
   - 在 `Core/LmuxTranscript` 新增純對話紀錄脈絡抽取器（過濾 `<synthetic>` 佔位訊息、補齊 Codex 異動檔案解析），並於 `App/LmuxUI` 整合來源 **終端機 tab** 的近期工具呼叫串流與對應工作目錄的 Git 變更狀態，毫秒級組出 **Session 上下文補充**（任務標題與起點目標、最近數輪問答摘要、近期已修改／新建檔案清單、最近關鍵工具紀錄）。
   - 支援無對話紀錄檔的降級情境（如一般 shell 腳本呼叫 `lmux ask`），安全呈現可用欄位而不報錯。

2. **`lmux ask` CLI、兩階段控制通道 RPC 與權限隔離（`App/Sources/lmux-cli` + `App/Sources/LmuxUI`）**：
   - 新增 `lmux ask --spec <path|-> [--timeout <secs>] [--pane <id>] [--lenient]` 與 `lmux ask --wait <sessionId> [--timeout <secs>]`，採與 `ask-me` 完全相容的 spec JSON 輸入（含字串選項簡寫、`Recommended`/`推薦` 後綴正規化、重複 ID/選項檢核與預設字數把關）及 stdout JSON 回傳契約（`submitted` / `pending` + `resume` / `cancelled` + `note` / `lost`）。
   - 控制通道採 `ask-create`（同步單行回覆建立工作階段）＋ `ask-wait`（複用 `ControlServer` 單行長連線等待）兩階段協議，修復 `lmux-cli` 大型 payload 迴圈寫入，並嚴格執行 `LMUX_PANE_NONCE` 與 `allowCrossPaneSend` / `allowExternalSend` 權限隔離，防止跨 pane 偽造提問、跨區讀檔或竊取回覆。
   - 擴充選填的本機引用欄位 `refs`（檔案路徑與行號區間）與 `gitDiff`（檔案路徑），複用 `GitDiffService` 的無跟隨開啟（`O_NOFOLLOW`）與惡意 git filter 隔離環境變數安全讀取。

3. **右側 Inspector 原生 SwiftUI「待確認面板」、焦點防護與注意力連動（`App/Sources/LmuxUI`）**：
   - `InspectorTab` 新增動態 `.ask` 分頁，僅在 **focused tab** 存在未完成 **問答工作階段** 時出現於 **右側 Inspector** 頁籤列（附未答數徽章與窄寬度緊湊標籤），開啟時自動展開並記錄最後一個非問答分頁，送出或取消後自動隱藏並還原原分頁與終端機鍵盤焦點。
   - 以純原生 SwiftUI 逐塊渲染 **Session 上下文補充** 卡片、`intro`／`detail` Markdown 段落／清單與紅綠 ` ```diff `、本機 `refs`／`gitDiff` 折疊卡、`mermaid` 可折疊等寬程式碼卡（附複製語法按鈕，不啟動 WebView）、單／多選卡片（含代價說明與推薦徽章）、多行自由輸入欄與所有題目皆作答後啟用的 `⌘↩` 送出列。
   - 完整處理 AppKit 焦點與快捷鍵邊界：輸入框聚焦時支援標準文字復原／重做／剪下且不誤觸 Claude Rewind；**待確認面板** 可見時攔截 `⌘↩` 絕不漏進終端機 PTY；切換分頁或視窗縮窄時安全歸還焦點。
   - 背景 **終端機 tab** 發起提問時（即使該 tab 的 Agent 正處於執行中），優先顯示需確認狀態、喚醒 `lmux wait --until needs-you` 並推送 **通知卡片** 至 **通知 bar**。
   - 更新 `skills/lmux/SKILL.md` 補充 `lmux ask` 用法。

## Impact

- **模組範圍**：涵蓋 `Core/LmuxTranscript`、`App/lmux-cli`、`App/LmuxUI`、`skills/lmux/SKILL.md` 及對應的 `Core/Tests` 與 `App/Sources/lmux-apptest`。維持 `Core/LmuxTranscript` 不依賴 `LmuxHooks`/`LmuxUI` 的乾淨模組邊界；不修改 `App/Sources/LmuxTerminal` 與 `vendor/ghostty`，亦不改動 `lmux-hook` 的 5 秒非阻塞旁聽行為。
- **向後相容**：未執行 `lmux ask` 時，**右側 Inspector** 維持原有三個分頁、既有 `layout.json` 持久化格式（不持久化暫時性的 `.ask` 分頁）與全部快捷鍵行為完全不變。
- **後續銜接**：完成後，`jkopay-share-skills/skills/ask-me` 僅需在偵測到 `$LMUX_CONTROL_SOCKET` 與 `$LMUX_PANE_ID` 時委派呼叫 `lmux ask`，即可自動切換為 lmux 原生體驗，在外部終端機則維持原有瀏覽器模式。
