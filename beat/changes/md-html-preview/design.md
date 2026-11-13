# 設計：在 lmux 裡預覽 .md 與 .html

## Approach

依序做三段。A 完成並通過檢查點，才開始 B。

```
A 重構（行為不變）──▶ 檢查點：build + apptest 全過 ──▶ B spike ──▶ C 功能
```

### A. 讓 tab 能裝終端機以外的內容（重構）

1. `Pane`（`App/Sources/LmuxUI/Model.swift:67`）改成持有一種內容：
   ```swift
   enum Content { case terminal(SurfaceView), preview(PreviewView) }
   let content: Content
   var surface: SurfaceView? { if case .terminal(let s) = content { return s }; return nil }
   var preview: PreviewView? { if case .preview(let p) = content { return p }; return nil }
   ```
   - 現有的 `init(id:surface:)`（`Model.swift:226`）保留，另加 `init(id:preview:)`。
2. LmuxUI 18 個檔案、101 處 `.surface`：逐一判斷 surface 為 nil 時該怎麼做。只有兩種結果：跳過，或回傳「不是終端機」。
3. 測試 26 個檔案、289 處：機械式改成 `surface!`。測試只建立終端機 tab，`!` 不會失敗。
4. 這一段不新增任何預覽功能，`.preview` 還沒有地方建立。

**檢查點**：`swift build` 成功，`App/scripts/apptest.sh --quick` 全部通過。沒過不往下做。

### B. Spike（先驗證，再寫功能）

| # | 要驗證的事 | 通過條件 | 不通過時 |
|---|---|---|---|
| S1 | 自訂 scheme（`lmux-preview`）提供 Markdown 頁面與相對路徑圖片；在頁面之間換頁後，兩指滑動能返回 | 圖片顯示；滑動返回到上一頁 | 改成把 HTML 寫到暫存檔，用 `loadFileURL` |
| S2 | `loadFileURL(_:allowingReadAccessTo:)` 開 HTML，讀得到同資料夾的 CSS 與圖片；`../` 外的檔案讀不到 | 同資料夾的資源載入成功 | 記錄限制，寫進 Risks |
| S3 | 很大的 .md（以使用者 vault 裡最大的 .md 為準）解析時間 | 解析不卡住主執行緒 | 解析放背景執行緒（本來就這樣設計），只記錄數字 |
| S4 | Claude Code 在 lmux 裡印出的路徑是純文字，還是 OSC 8 `file://` 連結 | 知道是哪一種 | 兩種都已支援，只記錄結果 |
| S5 | FSEvents 收得到「寫暫存檔再改名」與直接改寫兩種存檔 | 兩種都觸發重新渲染 | 改成「監看資料夾 + 監看檔案」兩個 `DispatchSource` |

### C. 功能

#### C.1 開啟選單（`open-menu.feature`）

1. **攔截點**：`GhosttyRuntime.openTerminalURL`（`App/Sources/LmuxTerminal/GhosttyRuntime.swift:298`）。
   - 加一個靜態回呼 `openFile`，寫法比照同檔的 `openURL`（`GhosttyRuntime.swift:286`）。LmuxTerminal 不能依賴 LmuxUI，所以由 LmuxUI 在啟動時設定這個回呼。
   - `openTerminalURL` 多一個參數 `view: SurfaceView?`，預設 nil。呼叫處（`GhosttyRuntime.swift:240`）傳入 `view`。既有測試（`App/Sources/lmux-apptest/Parity.swift:191-221`）不傳，行為不變。
   - kind 是 `UNKNOWN`（⌘-click 的文字），或 `OSC8` 且是 `file://` 時，先問 `openFile`。回傳 true 就結束，false 就走原本流程。
2. **判斷是不是可預覽檔案**（新檔 `PreviewTarget.swift`，只用 Foundation，可單獨測試）：
   1. 去掉尾端的 `:數字` 或 `:數字:數字`。Ghostty 只在路徑存在時才補成絕對路徑（`vendor/ghostty/src/Surface.zig:2211-2216`），所以 `docs/a.md:12` 會以相對路徑傳進來。
   2. 相對路徑：用這個 tab 的 `Pane.cwd` 補成絕對路徑。`cwd` 是 nil 就走原本流程。
   3. `file://` 轉成路徑。
   4. 副檔名（不分大小寫）是 `md`、`markdown`、`html`、`htm`，而且檔案存在、不是資料夾，才回傳 true。
3. **選單**：`NSMenu.popUp(positioning:at:in:)`，位置是滑鼠在 surface 裡的座標。
   - 第 1 列：完整路徑，停用狀態。路徑太長時中間用 … 省略。
   - 「用預設 app 開」：走原本流程（`UntrustedURLAlert.open`），結果與加入選單前相同。
   - 「在 Finder 顯示」：`NSWorkspace.shared.activateFileViewerSelecting`。
   - 「複製路徑」：寫入 `GhosttyRuntime.standardPasteboard`。
   - 選單關閉後呼叫 `focusCurrent()`，焦點回到終端機。
   - 測試用 `testHook` 回答選單，比照 `UntrustedURLAlert.testHook`（`App/Sources/LmuxTerminal/UntrustedURL.swift:350`）。

#### C.2 預覽 tab（`preview-tab.feature` 的 tab 行為）

1. **建立**：`Tabs.swift` 加 `newPreviewTab(_ url: URL, after pane: Pane)`，插入位置的算法與 `newTab`（`App/Sources/LmuxUI/Tabs.swift:25-32`）相同，再呼叫既有的 `insert`。
2. **標題**：檔名。換頁後跟著換。
3. **目前目錄**：`Pane.cwd` 設成檔案所在資料夾。這樣 ⌘T 與分割會沿用它（`Tabs.swift:28`），sidebar 也顯示這個資料夾。
4. **焦點**：`focusCurrent()`（`App/Sources/LmuxUI/Controller.swift:964-976`）在預覽 tab 時，把 first responder 交給 WKWebView。
5. **選單列**：lmux 的 Copy 是 `copy:`、target 是 nil（`App/Sources/LmuxUI/Menu.swift:71`），沿 responder chain 交給 WKWebView。Find…／Find Next／Find Previous／Paste／Undo Send／Copy Original Reply（`Menu.swift:69-78`）在預覽 tab 是 focused tab 時停用。每一項都用 apptest 確認，不靠「responder chain 裡沒人處理就會自動停用」的推論。
6. **不顯示**：Rewind 按鈕、捲軸 overlay（`SurfaceScroller`）、拖放檔案的提示。
7. **CLI**（`App/Sources/LmuxUI/ControlServer.swift`）：
   - `list`（`:325`）：不列出預覽 tab。`tabs` 欄位（同一格的 tab 數）照實際數量算，包含預覽 tab，讓 `tab` 的位置編號保持正確。
   - `send`（`:346`）：目標是預覽 tab 時，回傳 `not a terminal: <id>`。
8. **存檔與還原**（`App/Sources/LmuxUI/Persistence.swift`）：存檔時略過預覽 tab；略過後沒有 tab 的 workspace 也不存。

#### C.3 渲染（`preview-tab.feature` 的 Markdown 與 HTML）

新檔 `Preview.swift`：`PreviewView`（一個 `NSView`，裡面是 `WKWebView`）。

1. **共用設定**：每個預覽 tab 一個 `WKWebViewConfiguration`，`websiteDataStore = .nonPersistent()`，`allowsBackForwardNavigationGestures = true`。
2. **Markdown**：載入 `lmux-preview:///<絕對路徑>`。
   - `WKURLSchemeHandler` 收到 `.md` 請求：在背景執行緒讀檔、用 `MarkdownHTML` 轉成 HTML 後回傳。其他副檔名直接回傳檔案內容，MIME 由副檔名決定。
   - 相對路徑的圖片與 `.md` 連結會自動解析成同一個 scheme，所以圖片、換頁、返回都由 WebKit 處理。
   - 這個 scheme 的頁面關閉 JavaScript（`WKWebpagePreferences.allowsContentJavaScript = false`，在導覽決策時設定）。
3. **`MarkdownHTML`**（新檔 `MarkdownHTML.swift`，只用 Foundation，可單獨測試）：
   - `AttributedString(markdown:, options: .init(interpretedSyntax: .full))`，依 `presentationIntent` 輸出區塊，依 `inlinePresentationIntent`、`link`、`imageURL` 輸出行內元素。2026-11-13 實測過這些屬性都有值。
   - 所有文字都做 HTML 跳脫。`inlineHTML`／`blockHTML` 也當成文字跳脫，所以內嵌的 HTML 不會執行。
   - callout：引用的第 1 段開頭是 `[!類型]` 時，輸出提示框。標題是 `[!類型]` 後面的文字；沒有文字時用類型名稱，第一個字母大寫（`NOTE` → `Note`）。認得的類型（note、tip、important、warning、caution）用各自的顏色，其他類型用 note 的顏色。
   - 程式碼區塊：`<pre><code>`，不上色。語言名稱放在 `class`，留給以後加上色。
   - CSS 寫在 Swift 字串裡，用 `prefers-color-scheme` 切換深淺色。WKWebView 跟著 `NSApp.appearance`（`App/Sources/LmuxUI/Appearance.swift:131-133`），所以會跟 lmux 的外觀設定一致。
4. **HTML**：`loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())`。2026-11-13 spike 用同樣設定開使用者 vault 的報告，CDN 的 script 載入成功。
5. **在 Markdown 與 HTML 之間換頁**（`WKNavigationDelegate`）：
   - 要前往 `file://` 的 `.md`：取消，改載入 `lmux-preview://` 的同一個路徑。
   - 要前往 `lmux-preview://` 的 `.html`：取消，改用 `loadFileURL`。
   - 要前往 http(s)，而且是使用者點擊（`navigationType == .linkActivated`）：取消，交給 `UntrustedURLAlert.open`。頁面自己載入的 http(s) 資源不受影響。
6. **自動更新**：FSEvents 監看檔案所在資料夾（`kFSEventStreamCreateFlagFileEvents`）。事件的路徑是目前顯示的檔案時，重新載入。換頁後改看新的檔案。
   - 檔案不存在：顯示「檔案已不存在」與完整路徑。Markdown 由 scheme handler 回傳這個頁面；HTML 用 `loadHTMLString`。
   - 只看目前顯示的檔案。只改同資料夾的 CSS 或圖片時不會更新（見 Risks）。

## Key Decisions

1. **`Pane.surface` 改成 optional（使用者選的方案 1）。**
   - 理由：漏改的地方會編譯失敗，不會漏。
   - 替代方案：
     - 方案 2：預覽 tab 背後仍跑一個 shell，把 WKWebView 蓋在 surface 上。約 6 個檔案，但漏改一處時，鍵盤輸入會跑進看不見的 shell，沒有錯誤訊息。否決。
     - 預覽 tab 用獨立型別，`Pane` 不動：要改 tab 樹的 API，正式程式 23 個檔案、測試 34 個檔案，沒有比較省。否決。
     - `surface` 宣告成 `SurfaceView!`：測試不用改，但漏改一處 lmux 就當掉，所有 tab 的 shell 一起結束。否決。
   - 代價：動到 44 個上游檔案，之後合併上游 lmux 時衝突變多。
   - ADR 判斷：難以改回（44 個檔案）、看到程式碼會意外（為什麼每個 surface 都是 optional）、有真的取捨（三個替代方案）→ 符合三個條件，使用者同意寫 ADR。See `docs/adr/0001-pane-surface-optional.md`.
2. **一個 change，超過 20 個檔案。**
   - 理由：使用者 2026-11-13 決定。用 A 段之後的檢查點，保留「重構先驗證」的好處。
   - ADR 判斷：流程決定，不是架構 → 不寫 ADR。
3. **Markdown 用 Foundation 解析，Swift 產生 HTML，不加依賴。**
   - 理由：使用者要原生 Swift；Foundation 的解析器已能解析需要的語法（2026-11-13 實測）。
   - 替代方案：打包 JS 的 markdown 解析器。否決：新增依賴，使用者不要。
   - ADR 判斷：只影響 `MarkdownHTML.swift`，容易換 → 不寫 ADR。
4. **Markdown 走自訂 scheme，HTML 走 `loadFileURL`。**
   - 理由：Markdown 要即時轉換，還要讓相對路徑的圖片與換頁照常運作，自訂 scheme 一次解決。依使用者的 Orca 筆記（`~/.obsidian/jamis/Projects/Orca/Orca - Markdown 與 HTML 渲染呈現架構分析.md`，不是 Orca 原始碼），Orca 的 `orca-preview://` 也用自訂 scheme。Markdown 頁面關閉 JavaScript，所以 scheme 可以提供任意本機檔案而不會外流。HTML 頁面會執行 JavaScript，如果也走這個 scheme，頁面就能讀任意本機檔案再送上網路，所以 HTML 改用 WebKit 的檔案存取限制。
   - 替代方案：`loadHTMLString(_:baseURL:)`。否決：本機圖片能不能載入、返回能不能用，都沒把握（未實測）。
   - ADR 判斷：只在 `Preview.swift` 裡，容易改 → 不寫 ADR。
5. **HTML 允許連網，不保存 cookie 與 storage。**
   - 理由：使用者 vault 的 331 個 HTML 有 254 個從 CDN 載入 script。使用者選 A。
   - ADR 判斷：一個設定值，容易改 → 不寫 ADR。
6. **不設返回快速鍵。**
   - 理由：⌘[ 是 Previous Pane（`App/Sources/LmuxUI/Menu.swift:113`）。返回用觸控板兩指滑動（WebKit 內建）。
   - ADR 判斷：容易改 → 不寫 ADR。
7. **OSC 8 的 `file://` 連結也跳出開啟選單。**
   - 理由：S4 還沒查證 Claude Code 印的是純文字還是 OSC 8。兩種都支援，結果都對。選單第 1 列顯示真正的路徑，連結文字騙不了使用者。
   - ADR 判斷：容易改 → 不寫 ADR。

## Components

| 檔案 | 類型 | 改動 |
|---|---|---|
| `App/Sources/LmuxUI/Model.swift` | lmux 原始檔 | A：`Pane.Content`、`surface` 改 optional、`init(id:preview:)` |
| LmuxUI 其他 17 個用到 `.surface` 的檔案 | lmux 原始檔 | A：處理 surface 是 nil（Controller、MessageActions、Rewind、Search、Agent、Tabs、PaneViews、Scrollback、CmuxImport、RootView、Menu、Snapshot、Persistence、HooksHint、CodexSetup、Attention、Appearance） |
| `App/Sources/lmux-apptest/`、`App/Sources/lmux-imetest/` 共 26 個檔案 | lmux 測試 | A：`surface` → `surface!` |
| `App/Sources/LmuxTerminal/GhosttyRuntime.swift` | lmux 原始檔 | C.1：`openFile` 回呼、`openTerminalURL` 的 `view` 參數 |
| `App/Sources/LmuxUI/PaneViews.swift` | lmux 原始檔 | A：`PaneView` 依內容放 surface 或 `PreviewView`；C.2.6 預覽不放 scroller |
| `App/Sources/LmuxUI/Tabs.swift` | lmux 原始檔 | C.2：`newPreviewTab` |
| `App/Sources/LmuxUI/Controller.swift` | lmux 原始檔 | C.1：設定 `openFile`、跳出選單；C.2：`focusCurrent` |
| `App/Sources/LmuxUI/Menu.swift` | lmux 原始檔 | C.2.5：預覽 tab 時停用的項目 |
| `App/Sources/LmuxUI/ControlServer.swift` | lmux 原始檔 | C.2.7：`list`、`send` |
| `App/Sources/LmuxUI/Persistence.swift` | lmux 原始檔 | C.2.8：略過預覽 tab |
| `App/Sources/LmuxUI/PreviewTarget.swift` | 新檔 | C.1.2：路徑正規化與判斷 |
| `App/Sources/LmuxUI/MarkdownHTML.swift` | 新檔 | C.3.3：Markdown 轉 HTML |
| `App/Sources/LmuxUI/Preview.swift` | 新檔 | C.3：`PreviewView`、scheme handler、導覽、FSEvents |
| `App/scripts/preview-check.swift` | 新檔（腳本） | `PreviewTarget` 與 `MarkdownHTML` 的自我檢查，比照 `message-text-check.swift` 用 `swiftc` 單獨編譯執行 |
| `App/Sources/lmux-apptest/Preview.swift` | 新檔（測試） | `@e2e` 場景 |

WebKit 要不要在 `App/Package.swift` 加 `.linkedFramework("WebKit")`：Swift 的 `import WebKit` 應該會自動連結（未實測）。build 失敗再加。

### 測試方式

- `@behavior` 場景：`App/scripts/preview-check.swift`（`swiftc` 編譯 `PreviewTarget.swift`、`MarkdownHTML.swift` 與這支腳本後執行）。
- `@e2e` 場景：`App/scripts/apptest.sh --quick` 加上新的 `Preview.swift`。測試前先 `unset` 所有 `LMUX_*` 變數，免得指令送進使用者正在用的 lmux。
- 畫面相關（深淺色、圖片、兩指滑動、選單位置）：使用者手動驗證，紀錄寫在 `manual-verification.md`。

### Risks

- **未實測**：WKWebView 有沒有實作 `paste:` 與 `performFindPanelAction:`。有的話，C.2.5 的停用要明確處理，不能靠 responder chain。apptest 逐項確認。
- **未實測**：每個預覽 tab 的記憶體用量。WebKit 會另外起網頁內容的 process。
- **未實測**：自訂 scheme 的頁面載入 http(s) 圖片會不會被擋。Markdown 引用網路圖片的情況，S1 一起測。
- **限制**：只改同資料夾的 CSS 或圖片，預覽不會自動更新。要看新樣式得關掉再開。
- **限制**：HTML 讀不到所在資料夾以外的檔案（例如 `../assets/x.css`）。S2 確認。
- **未查證**：HTML 頁面的 JavaScript 能不能用 `fetch` 讀同資料夾的其他檔案。能的話，頁面可以讀同資料夾的檔案再送上網路。使用者已接受「允許連網」的風險；S2 一併記錄結果。
- **合併上游**：A 段動到 44 個上游檔案。合併 `sooftware/lmux` 新版時，這些檔案都可能衝突。
- 本機 build 與測試的已知問題（GNU libtool、`LMUX_*` 變數、Xcode 27 的 swiftbuild）見 memory 的 lmux-local-build-and-test-pitfalls。
