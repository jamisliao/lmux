# 手動驗證：md-html-preview

自動測試涵蓋不到、要使用者在真的 lmux 視窗裡確認的項目。每項做完填「結果」。

先 build：`App/scripts/bundle.sh`（或照 memory 的 lmux-local-build-and-test-pitfalls 做法），開啟新的 lmux.app。

<!-- 只能手動驗證（第 11 列）、或自動測試只能用代替品（第 18 列 ⌘W 用選單項目；第 1、3 列真的彈出的選單用 test hook）的場景，供 feature 檔的 @covered-by 對照 -->
<!-- @feature: preview-tab.feature -->
<!-- @scenario: 外觀設定是 System 時，預覽跟著 macOS 的深淺色切換 -->
<!-- @scenario: 關閉預覽 tab 後，相鄰 tab 成為 focused tab -->
<!-- @feature: open-menu.feature -->
<!-- @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單 -->
<!-- @scenario: 不選任何項目就關掉選單 -->

| # | 對應場景 | 步驟 | 預期 | 結果 |
|---|---|---|---|---|
| 1 | ⌘-click 可預覽檔案的路徑跳出開啟選單 | 在終端機 `cd` 到這個 repo，`echo beat/changes/md-html-preview/design.md`，按住 ⌘ 點那段文字 | 選單出現在滑鼠旁，第 1 列是完整路徑（灰色），下面 4 項 | |
| 2 | 選「在新 tab 預覽」開出預覽 tab | 選「在新 tab 預覽」 | 目前 tab 右邊多一個 tab，標題 `design.md`，內容是排版後的 Markdown | |
| 3 | 不選任何項目就關掉選單 | 再 ⌘-click 一次，按 Esc | 選單關閉，可以直接在終端機打字 | |
| 4 | Markdown 預覽跟著 lmux 的外觀設定切換深淺色 | Settings 把外觀改成 Dark，再改成 Light | 預覽的背景跟著變，不用重開 | |
| 5 | HTML 從網路載入的 script 正常執行 | ⌘-click `~/.obsidian/jamis/摘要報告/20261013_AI_Articles_Summary_recycled_paper.html` → 在新 tab 預覽，點一篇文章 | 文章內容顯示出來（靠 CDN 的 marked.js） | |
| 6 | 點相對路徑的 .md 連結，在同一個預覽 tab 換頁 | 在預覽裡點一個 `.md` 連結，再用觸控板兩指往右滑 | 同一個 tab 換頁、標題跟著換；滑動後回到上一頁 | |
| 7 | 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上 | 在預覽裡選一段文字按 ⌘C，貼到終端機 | 貼上的是選取的文字 | |
| 8 | 檔案內容改變後，預覽自動更新 | 預覽開著時，請 Claude 改那個 .md | 預覽自動顯示新內容 | |
| 9 | （design.md 的 spike S4） | 請 Claude 在回覆裡提到一個 .md 檔路徑，⌘-click 它 | 記錄：選單有沒有出現；路徑是純文字還是 OSC 8 連結（hover 時底部會顯示網址） | |
| 10 | （記憶體，未實測項目） | 開 3 個預覽 tab，看「活動監視器」的 lmux 與 WebKit 程序 | 記錄數字即可 | |
| 11 | 外觀設定是 System 時，預覽跟著 macOS 的深淺色切換 | Settings 外觀設成 System，再切換 macOS 的深淺色 | 預覽跟著 macOS 變 | |
| 12 | （design 未實測：Markdown 裡的網路圖片） | 預覽一個含 `![](https://…png)` 的 .md | 記錄：圖片有沒有顯示 | |
| 13 | 重開 lmux 不還原預覽 tab | 開一個預覽 tab，結束 lmux 再開 | 終端機 tab 都回來，預覽 tab 沒有回來 | |
| 14 | 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上 | 在預覽 tab 上打字 `ls` 按 Enter | 終端機沒有收到 `ls` | |
| 15 | 預覽 tab 上停用只對終端機有意義的功能 | 在預覽 tab 上把滑鼠移過內容 | 沒有出現 Rewind（訊息動作）按鈕 | |
| 16 | （review 發現：預覽 tab 上的確認卡片） | 讓預覽 tab 是 focused tab，按 ⇧⌘W（Close Workspace），再按 Enter | 卡片被確認（workspace 關閉）；重做一次改按 Esc，卡片取消 | |
| 17 | （已知限制） | 預覽 tab 是 focused tab 時，按 Ghostty 的分割方向鍵（例如 ⌘⌥→） | 記錄：沒有反應是已知限制；⌘[、⌘] 仍可切換 pane | |
| 18 | 關閉預覽 tab 後，相鄰 tab 成為 focused tab | 兩個 tab：終端機 A 與預覽 tab P，P 是 focused tab，在預覽上按一下，按 ⌘W | P 關閉，A 成為 focused tab（自動測試用選單項目代替 ⌘W，因為 headless 下 WKWebView 會吃掉 ⌘W） | |
