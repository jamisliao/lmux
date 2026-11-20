# lmux

lmux 是一款面向 Claude Code 與 Codex CLI 工作流的原生 macOS 多工終端機應用程式（基於 Swift／AppKit／libghostty）。

## Language

**workspace**:
代表一組獨立的工作區，內含多個分割視圖與分頁、工作目錄及關聯的執行紀錄。
_Avoid_: project, session group, space

**tab**:
位於中央分割格內的單一分頁（可能是 **終端機 tab** 或 **預覽 tab**），對應程式中的 `Pane`。
_Avoid_: window tab, pane session

**終端機 tab**:
位於中央分割格內、由 `libghostty` 驅動的終端機分頁。
_Avoid_: terminal pane, shell session

**預覽 tab**:
位於中央分割格內、以 `WKWebView` 渲染 **可預覽檔案** 的獨立分頁。
_Avoid_: preview window, inline preview

**focused tab**:
使用者目前正在操作、擁有鍵盤焦點的分頁（可能是 **終端機 tab** 或 **預覽 tab**）。
_Avoid_: current tab, active pane

**可預覽檔案**:
支援於內建預覽檢視的本機檔案類型（Markdown、HTML 或純文字檔案）。
_Avoid_: viewable doc, preview doc

**開啟選單**:
在 **終端機 tab** 內按住 `⌘` 點擊 **可預覽檔案** 路徑或連結時彈出的快速選單。
_Avoid_: context menu, link popup

**通知 bar**:
停靠於左側欄最底部的折疊式通知配件區，包含調整把手、摘要列與 **通知卡片** 清單。
_Avoid_: inbox footer, notification drawer

**通知卡片**:
顯示在 **通知 bar** 內的單則訊息卡片，對應來源分頁的任務名稱、**workspace** 與回覆摘要。
_Avoid_: toast, alert item

**右側 Inspector**:
停靠於視窗右側的可調寬面板（預設開啟），整合「即時預覽」、「變更 (Diff)」與「執行記錄」三個檢視分頁。
_Avoid_: right sidebar, inspector drawer, preview panel

**底部狀態列**（原型稱 **視窗底部狀態列**）:
跨越整個視窗底部的系統列，即時顯示目前 **workspace** 的 **Agent 遙測**、Git 變更統計與 **右側 Inspector** 快捷控制。
_Avoid_: footer bar, status strip, telemetry bar

**Pane Tab Strip**:
位於中央每個分割格頂部的圓角分頁與分割操作列，管理該格內的所有 **終端機 tab** 與 **預覽 tab**。
_Avoid_: inline tab bar, pane header

**Agent 遙測**:
從 Claude Code / Codex 的 Hook 事件與對話紀錄檔即時萃取的模型名稱、Turn 計數、Context Window 用量與工具呼叫串流資訊。
_Avoid_: agent stats, token metrics

**拖曳降級**:
在拖曳調整邊欄寬度、**通知 bar** 高度、窗格分割線或縮放視窗期間，暫時停用背景毛玻璃模糊混合以確保 60fps 流暢度的保護機制。
_Avoid_: blur-off, opaque fallback mode

**UI 原型**:
位於根目錄的單檔互動式 HTML 原型（`preview-mockup.html`），用來對照驗證雙主題液態玻璃外觀與工作台互動；原型裡的 **視窗底部狀態列** 即對應正式 App 的 **底部狀態列**。
_Avoid_: mockup HTML

**摘要列**:
**通知 bar** 最上方顯示鈴鐺與未讀數、支援點擊收合通知清單的固定列。
_Avoid_: notification header

**High-Key Crystal / Obsidian Midnight**:
lmux 雙主題 Apple Liquid Glass 視覺模式：淺色高透 **High-Key Crystal** 與深色沉穩 **Obsidian Midnight**。

**active-ring**:
目前擁有鍵盤焦點之中央分割格周圍顯示的 `1.5pt` 藍色聚焦邊框光環（與未讀待輸入的琥珀色光環區隔）。

## Relationships

- 每個 **workspace** 擁有一棵分割樹，每個葉節點（分割格）上方有一個 **Pane Tab Strip**，管理一個以上的 **終端機 tab** 或 **預覽 tab**
- 整個視窗同一時間只有一個 **focused tab**
- **底部狀態列** 與 **右側 Inspector** 的「變更 (Diff)」、「執行記錄」會跟著目前選取的 **workspace** 與 **focused tab** 即時切換
- **可預覽檔案** 透過 **開啟選單** 可開啟在 **右側 Inspector** 的「即時預覽」，或開成獨立 **預覽 tab**

## Example dialogue

> **Developer:** "我在終端機按 ⌘ 點擊 `README.md`，應該開在 **預覽 tab** 還是 **右側 Inspector**？"
> **Product:** "預設從 **開啟選單** 的第一項開在 **右側 Inspector** 的「即時預覽」不打斷終端機版面；需要並排比較時，依然能選「在新 tab 預覽」開成 **預覽 tab**。"

## Flagged ambiguities

- 「預覽」過去僅指分割窗格內的 **預覽 tab**；擴充 **右側 Inspector** 後，兩者以名詞嚴格區分：「即時預覽」指 **右側 Inspector** 分頁，「**預覽 tab**」指中央分割格內的獨立分頁。
- 「狀態列／footer」與「通知 bar」容易混淆：位於左側欄下方的為 **通知 bar**，跨越整個視窗最底部的為 **底部狀態列**。
