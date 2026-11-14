# 在 lmux 裡預覽 .md 與 .html

## Why

1. **看 agent 產出的文件要離開 lmux。** Claude 在終端機列出 `design.md`、報告 `.html` 的路徑。使用者 ⌘-click 後，lmux 把檔案交給系統預設 app 開啟。
   - 現況：⌘-click 的路徑由 Ghostty 偵測（`vendor/ghostty/src/config/url.zig:76-107`），相對路徑用 shell 回報的目前目錄補成絕對路徑（`vendor/ghostty/src/Surface.zig:2201-2221`），再交給 `GhosttyRuntime.openTerminalURL`（`App/Sources/LmuxTerminal/GhosttyRuntime.swift:298`）。最後由 `NSWorkspace.shared.open` 開啟（`GhosttyRuntime.swift:286`）。
2. **使用者想在點路徑時選擇開在哪裡。** 目前只有一種結果：系統預設 app。
3. **tab 只能裝終端機。** `Pane` 固定持有一個終端機 surface（`App/Sources/LmuxUI/Model.swift:69` `let surface: SurfaceView`），lmux 裡沒有地方顯示文件。lmux 也沒有用到 WebKit（`grep 'WKWebView|import WebKit'` 沒有結果）。

## What Changes

1. **開啟選單**
   - ⌘-click 終端機裡的**可預覽檔案**路徑（`.md`、`.markdown`、`.html`、`.htm`），在滑鼠位置跳出**開啟選單**。
   - 選單第一列顯示完整路徑（不能點；太長時中間省略，完整路徑保留在 tooltip），下面是：在新 tab 預覽、用預設 app 開、在 Finder 顯示、複製路徑。
   - 路徑後面帶 `:行號`（例如 `foo.md:12`）時，去掉行號再判斷。
   - OSC 8 連結指向本機的可預覽檔案（`file://`）時，也跳出開啟選單。
   - 其他路徑與網址、檔案不存在、相對路徑補不成絕對路徑時：照原本流程。
2. **預覽 tab**
   - 「在新 tab 預覽」開出一個**預覽 tab**，插在目前 tab 的右邊（與 ⌘T 相同位置），並成為 focused tab。
   - tab 標題是檔名。
   - 預覽 tab 可以像終端機 tab 一樣移動、分割、關閉。
   - 重開 lmux 不還原預覽 tab。只有預覽 tab 的 workspace 也不還原。
   - 只對終端機有意義的選單項目在預覽 tab 上停用：Find…、Find Next、Find Previous、Undo Send、Copy Original Reply、以及 Ghostty 字級調整與 Clear Screen（`App/Sources/LmuxUI/Menu.swift:69-79, 92-96`）。Paste 沒有指定 target（沿 responder chain 傳遞），controller 無法停用它；改成保證它不會貼進任何終端機。預覽上沒有 Rewind 按鈕。
   - `lmux send` 指定預覽 tab 時回傳錯誤。`lmux list` 不列出預覽 tab。
   - 預覽 tab 選取的文字可以用 ⌘C 複製。
   - 在預覽 tab 上開新 tab 或分割時，新的終端機從檔案所在資料夾開始。
3. **Markdown 渲染**
   - 用 Foundation 的 `AttributedString(markdown:)` 解析，再由 Swift 產生 HTML，顯示在 WKWebView。不新增依賴。
   - 支援：標題、清單、表格、程式碼區塊、引用、callout（`> [!NOTE]` 等）、連結、圖片。
   - 不支援：程式碼上色、mermaid、數學式。mermaid 區塊顯示成一般程式碼區塊。
   - Markdown 裡內嵌的 HTML 標籤顯示成文字，不執行。
   - 深淺色跟著 lmux 的外觀設定（System／Light／Dark，`App/Sources/LmuxUI/Appearance.swift:131-133`）切換。
4. **HTML 渲染**
   - 用 WKWebView 開啟，允許連網，讀得到檔案所在資料夾的檔案。
   - 不保存 cookie 與 storage，關掉預覽 tab 就清掉。
5. **預覽內的連結**
   - 相對路徑的 `.md` 連結：在同一個預覽 tab 換頁，tab 標題跟著換。觸控板兩指往右滑返回上一頁。不設返回快速鍵：⌘[ 已經是 Previous Pane（`App/Sources/LmuxUI/Menu.swift:113`）。
   - http(s) 連結：使用者點了才開，照終端機裡點連結的規則處理（`UntrustedURLAlert`）。頁面的 script 自己觸發的點擊、meta refresh 不會開任何網址，也不會把預覽換成網頁。
6. **自動更新**
   - 檔案內容改變時重新渲染。用「寫暫存檔再改名」方式存檔也要更新。
   - 預覽中的檔案被刪除時，顯示「檔案已不存在」。
7. **讓 tab 能裝終端機以外的內容（重構）**
   - `Pane` 改成兩種內容：終端機、預覽。`Pane.surface` 改成 optional。
   - 重構本身不改變任何既有行為。

## Impact

- **實際改動量：超過「20 個檔案」的上限（整個 branch 相對 `main` 共約 98 個檔案，含 specs 與文件）。** 使用者 2026-11-13 在 explore 對話中同意這次超過，並同意不拆成兩個 change。
  - 上游 `App/Sources/` 共改動 48 個檔案：`LmuxUI` 修改 22 個既有檔案（其中 `Model.swift` 等 16 個檔案處理可選 `.surface`，加上 `Overlays.swift` 等與預覽功能整合），以及 `lmux-apptest` 修改 26 個檔案（25 個既有測試檔的 `pane.surface!` 改動 + `main.swift`）；`lmux-imetest` 0 個檔案。
  - 新增：`LmuxUI` 7 個預覽模組、`lmux-apptest` 3 個測試檔（`Preview.swift`、`PreviewInteractions.swift`、`PreviewPersistence.swift`）、`App/scripts/preview-*.swift` 5 個獨立檢查腳本，並修改 `App/scripts/apptest.sh`。
  - 修改摘要：`Controller.swift`（攔截 ⌘-click、焦點）、`Tabs.swift`、`Persistence.swift`、`ControlServer.swift`（CLI）、`SidebarSelection.swift`（選單停用）、`Overlays.swift`、`Menu.swift`、`MessageActions.swift`（確認卡片與前景程序檢查）、`Titles.swift`（預覽 tab 重新命名提示字樣），以及同步更新 `README.md`、`App/README.md`、`docs/` 說明頁面與 `docs/adr/0001-pane-surface-optional.md`。`GhosttyRuntime.swift` 不改。
- **與上游 lmux 合併的成本變高。** 這個 fork 追蹤 `sooftware/lmux`。本次在 `App/Sources/` 改動 48 個上游檔案，之後每次合併上游都可能在這些檔案衝突。
- **新的系統框架：WebKit。** Apple 內建，不是第三方依賴。
- **安全**：HTML 預覽允許連網，頁面的 JS 可以把頁面自己的內容送到任意網址。頁面的 JS 讀不到本機的其他檔案（2026-11-13 實測，含 security review 找到並修掉的 iframe 繞道）。cookie 與 storage 不保存。Markdown 頁面允許載入網路圖片（打開檔案時圖片的主機會知道）。
- **限制**：預覽 tab 是 focused tab 時，Ghostty 自己的 keybinding（例如分割方向鍵）不會動；⌘[、⌘] 與 tab 切換仍可用。
- **記憶體**：每個預覽 tab 有一個 WKWebView。WebKit 會另外起網頁內容的 process，用量未實測。
- **不受影響**：非可預覽檔案的 ⌘-click、網址、hook、agent 狀態、通知 bar。
