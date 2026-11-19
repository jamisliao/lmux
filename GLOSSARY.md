# lmux（本機客製版）

lmux 是給整天使用 Claude Code 與 Codex 的 macOS 終端機。本機客製版在 sidebar 底部加上常駐的通知 bar 與 plugin 系統。

## Language

### 版面

**workspace**:
sidebar 上的一列，含一個或多個 **tab**。
_Avoid_: 專案、sidebar 列

**tab**:
workspace 裡的一格內容，是 **終端機 tab** 或 **預覽 tab**；lmux 程式碼裡每個 tab 都是一個 `Pane`。
_Avoid_: pane（在規格中）、分頁、視窗

**終端機 tab**:
跑 shell 的 **tab**。agent 狀態、通知、Claude 產生的任務名稱都只屬於終端機 tab。
_Avoid_: terminal pane、shell tab

**focused tab**:
目前選取的 **workspace** 裡持有鍵盤焦點的 **tab**。
_Avoid_: 目前的 tab、active tab、選取的 tab

**展開箭頭**:
sidebar 上 workspace 列左側用來展開或收合其底下 **tab** 列表的箭頭按鈕（▶ / ▼）。
_Avoid_: disclosure triangle、折疊鈕、下拉箭頭

**Tab 子列**:
sidebar 展開 workspace 後，縮排顯示在該 workspace 下方的個別 **tab** 項目列。
_Avoid_: tab row、子項目、分頁列

**Pane Tab Strip**（原稱 **tab 列**）:
終端機區域上方橫向排列同一格裡各個 **tab** 與右側分割／關閉操作按鈕的那一列。
_Avoid_: tab bar、分頁列、水平分頁列

**釘選的 tab**:
固定在 **Pane Tab Strip**（**tab 列**）最前面、不能用關閉按鈕或 ⌘W 關閉的 **tab**。
_Avoid_: pinned tab、固定分頁

### 預覽

**可預覽檔案**:
lmux 能在 **預覽 tab** 顯示的本機檔案：Markdown（`.md`、`.markdown`）、HTML（`.html`、`.htm`），或 **純文字檔**。
_Avoid_: 文件、doc、網頁

**純文字檔**:
macOS 判斷為純文字的本機檔案，例如 `.txt`、`.sh`、`.yaml`、`.json`、`.log`。不含 Markdown、HTML、RTF、SVG。哪些副檔名算純文字檔由 macOS 的類型判斷決定，lmux 不另外維護清單。
_Avoid_: 文字檔、txt 檔、原始碼檔、code file

**預覽 tab**:
顯示一個 **可預覽檔案** 的 **tab**：Markdown 與 HTML 顯示渲染結果，**純文字檔** 顯示原文。沒有終端機，也沒有 agent 狀態。
_Avoid_: preview tab、文件 tab、viewer、Quick Look

**開啟選單**:
在終端機 ⌘-click **可預覽檔案** 的路徑時，在滑鼠位置跳出的選單，讓使用者選擇開在哪裡。
_Avoid_: 右鍵選單、context menu、開啟方式

### Agent 狀態

**進行中**:
tab 裡的 agent 正在工作的狀態。
_Avoid_: running、working、busy、執行中

**完成**:
tab 的 agent 回合已結束、結果等使用者看的狀態（sidebar 顯示 ✓）。
_Avoid_: done、結束

**等待回應**:
tab 裡的 agent 停下來等使用者回答或核准的狀態。
_Avoid_: 待回應、待輸入、needs input、等待確認

**閒置**:
tab 沒有回合在跑、也沒有待看結果的狀態。
_Avoid_: idle、空閒

**背景子 agent**:
Claude 以背景模式（`run_in_background`）派出、主回合結束後仍在工作的子 agent。
_Avoid_: 背景工作、background task（背景 shell 也叫 background task，但不算在內）

**build 版號**:
自己編的 lmux.app 的識別碼，格式 `<commit 數>-<commit 短碼>[-dirty]`，存在 Info.plist 的 `CFBundleVersion`。
_Avoid_: 版本號（指 `CFBundleShortVersionString`，那是上游的版本）、commit 號

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

### UI 原型

**UI 原型**:
用來探索與驗證介面視覺與版面互動的單檔互動式 HTML 原型（`preview-mockup.html`），不影響正式 macOS Swift 程式。
_Avoid_: 正式介面、mockup 網頁、preview 頁面

**右側 Inspector**:
視窗右側可收合與調寬（`⌥⌘B`）的輔助面板，提供「即時預覽」、「變更 (Diff)」與「執行記錄」三個分頁（最早見於 **UI 原型**，現已實作於正式 macOS App）。
_Avoid_: 右側欄、預覽面板、預覽 tab

**底部狀態列**（原型稱 **視窗底部狀態列**）:
橫跨視窗最底部的常駐狀態列，用來顯示目前 agent、工具活動、context 負載與 Git 變更並快速展開 **右側 Inspector**（現已實作於正式 macOS App）。
_Avoid_: 底部 bar（這是指左側 **通知 bar**）、footer、狀態 bar

## Relationships

- 一個 **workspace** 有一個或多個 **tab**；同一時間最多一個 **focused tab**。
- 有 2 個以上 **tab** 的 **workspace** 才有 **展開箭頭**；展開後每個 **tab** 對應一列 **Tab 子列**。
- 一則通知來自零個或一個 **終端機 tab**（從 tab 外面用 `lmux notify` 送的通知沒有 tab）。**預覽 tab** 不送通知。
- 一個 **終端機 tab** 有零個或一個 **任務名稱**（不是 Claude、或 Claude 還沒取標題時沒有）。**預覽 tab** 沒有 Claude agent 的任務名稱，但使用者仍可透過雙擊標題或右鍵選單在 lmux 手動重新命名其 tab 標題。
- 一則通知在 **通知 bar** 裡對應一張 **通知卡片**。
- 一份 **UI 原型** 包含標題列、左側 sidebar（裝 **workspace** 清單與 **通知 bar**）、中央分割區、**右側 Inspector** 與 **視窗底部狀態列**。
- 一個 **預覽 tab** 同一時間顯示一個 **可預覽檔案**；在預覽裡點連結換頁後，仍是同一個預覽 tab。

## Example dialogue

> **Dev:** 「這張**通知卡片**要反白嗎？」
> **使用者:** 「看它來自哪個 **tab**。是目前的 **focused tab** 就反白；同一個 **workspace** 的其他 tab 不反白。」
> **Dev:** 「卡片第一行寫什麼？」
> **使用者:** 「寫**任務名稱**。那個 tab 已經關掉、拿不到任務名稱，就寫 **workspace** 名稱。」

## Flagged ambiguities

- 「tab」：使用者說的 tab 等於 lmux 程式碼的 `Pane`（`App/Sources/LmuxUI/Tabs.swift:7-9`：每個 tab 都是一個 Pane）。規格一律用 **tab**。加入預覽後，`Pane` 不一定有終端機；只講其中一種時用 **終端機 tab** 或 **預覽 tab**。
- 「預覽」：可能指 macOS 的 Quick Look、Settings 裡的主題預覽，或 lmux 裡的 **預覽 tab**。正式規格中「預覽」只指 **預覽 tab**；在 **UI 原型** 裡位於右側面板的預覽分頁一律寫為 **右側 Inspector** 的「即時預覽分頁」，不與 **預覽 tab** 混稱。
- 「sidebar」與「右側 Inspector」：正式 lmux 只有左邊一個 sidebar；在 **UI 原型** 裡，左邊裝 **workspace** 清單與 **通知 bar** 的那一欄照舊叫 sidebar（畫面上的控制鈕文字寫「左側欄」），右邊的面板一律叫 **右側 Inspector**（畫面上的控制鈕文字寫「右側欄 (Inspector)」），規格內文不把 **右側 Inspector** 簡稱為「右側欄」。
- 「底部 bar」與「狀態列」：sidebar 底部的通知區塊一律叫 **通知 bar**（在 **UI 原型** 畫面標題標示為 Inbox）；橫跨整個 **UI 原型** 視窗最底部的那一列叫 **視窗底部狀態列**。
- 「點一下路徑」：使用者原話是「用滑鼠點一下」。lmux 沿用 Ghostty 的規則：按住 ⌘ 再點才開連結（`vendor/ghostty/src/config/Config.zig:4089`、`vendor/ghostty/src/Surface.zig:4490`）。不按 ⌘ 的點擊會選取文字，所以規格用 ⌘-click。
- 「文字檔」：可能指任何文字內容的檔案（含 Markdown、HTML），也可能只指不渲染、直接顯示原文的檔案。規格中後者叫 **純文字檔**；Markdown 與 HTML 雖然 macOS 也判斷為文字，不算純文字檔。系統判斷不是文字的副檔名（例如被認成影片的 `.ts`、沒有對應類型的 `.env`）也不算，即使內容是文字（2026-11-16 本機實測）。
- 「標題」：可能指 workspace 名稱、終端機標題（OSC 0/2）或 session 標題。規格中 session 標題一律叫 **任務名稱**；workspace 的叫「workspace 名稱」。
- 「tab 沒顯示進行中」：進行中的轉圈圖示畫在 sidebar 的 workspace 列（`App/Sources/LmuxUI/Sidebar.swift:400`）；**tab 列** 只畫等待回應／未讀徽章（`App/Sources/LmuxUI/Tabs.swift:542`）。規格中「顯示進行中」沒寫位置時指 workspace 列的轉圈圖示；指 **Tab 子列** 時要寫明「Tab 子列顯示進行中」。狀態本身屬於 **tab**。
