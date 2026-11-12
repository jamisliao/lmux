# lmux（本機客製版）

lmux 是給整天使用 Claude Code 與 Codex 的 macOS 終端機。本機客製版在 sidebar 底部加上常駐的通知 bar 與 plugin 系統。

## Language

### 版面

**workspace**:
sidebar 上的一列，含一個或多個 **tab**。
_Avoid_: 專案、sidebar 列

**tab**:
workspace 裡的一個終端機；lmux 程式碼裡每個 tab 都是一個 `Pane`。
_Avoid_: pane（在規格中）、分頁、視窗

**focused tab**:
目前選取的 **workspace** 裡持有鍵盤焦點的 **tab**。
_Avoid_: 目前的 tab、active tab、選取的 tab

### Agent 狀態

**進行中**:
tab 裡的 agent 正在工作的狀態。
_Avoid_: running、working、busy、執行中

**完成**:
tab 的 agent 回合已結束、結果等使用者看的狀態（sidebar 顯示 ✓）。
_Avoid_: done、結束

**閒置**:
tab 沒有回合在跑、也沒有待看結果的狀態。
_Avoid_: idle、空閒

**壓縮**:
Claude Code 把對話整理成摘要，手動（`/compact`）或自動觸發。
_Avoid_: compacting、compaction、壓縮對話

**閒置提醒**:
Claude Code 在使用者一段時間沒輸入時送出的提醒（Notification hook 的 `idle_prompt`）。
_Avoid_: idle prompt、逾時通知

### 通知 bar

**通知 bar**:
sidebar 底部常駐的區塊，由上而下是 plugin 列、**摘要列**、**通知卡片**清單。
_Avoid_: second bar、底部 bar、sidebar accessory

**摘要列**:
通知 bar 清單最上面的一列，顯示鈴鐺與未讀數。
_Avoid_: 標題列、header

**通知卡片**:
通知 bar 清單裡一則通知的顯示。
_Avoid_: 通知列、row、清單項目

**workspace 名稱**:
通知卡片上代表通知來源的名稱：workspace 的手動名稱；沒有時是 tab 工作目錄的資料夾名稱；tab 已關閉時是通知當時的名稱。
_Avoid_: workspace 標題、sidebar 列名稱（lmux 的自動名稱會跟著 focused tab 變，不能拿來代表通知來源）

**任務名稱**:
Claude 替一個 **tab** 的 session 取的標題，或使用者用 `/rename`、lmux 重新命名取的名稱。
_Avoid_: session 名稱、標題、tab 名稱

## Relationships

- 一個 **workspace** 有一個或多個 **tab**；同一時間最多一個 **focused tab**。
- 一則通知來自零個或一個 **tab**（從 tab 外面用 `lmux notify` 送的通知沒有 tab）。
- 一個 **tab** 有零個或一個 **任務名稱**（不是 Claude、或 Claude 還沒取標題時沒有）。
- 一則通知在 **通知 bar** 裡對應一張 **通知卡片**。

## Example dialogue

> **Dev:** 「這張**通知卡片**要反白嗎？」
> **使用者:** 「看它來自哪個 **tab**。是目前的 **focused tab** 就反白；同一個 **workspace** 的其他 tab 不反白。」
> **Dev:** 「卡片第一行寫什麼？」
> **使用者:** 「寫**任務名稱**。那個 tab 已經關掉、拿不到任務名稱，就寫 **workspace** 名稱。」

## Flagged ambiguities

- 「tab」：使用者說的 tab 等於 lmux 程式碼的 `Pane`（`App/Sources/LmuxUI/Tabs.swift:7-9`：每個 tab 都是一個 Pane）。規格一律用 **tab**。
- 「標題」：可能指 workspace 名稱、終端機標題（OSC 0/2）或 session 標題。規格中 session 標題一律叫 **任務名稱**；workspace 的叫「workspace 名稱」。
- 「tab 沒顯示進行中」：進行中的轉圈圖示畫在 sidebar 的 workspace 列（`App/Sources/LmuxUI/Sidebar.swift:400`）；tab 列只畫待回應／未讀徽章（`App/Sources/LmuxUI/Tabs.swift:527-528`）。規格中「顯示進行中」指 workspace 列的轉圈圖示，狀態本身屬於 **tab**。
