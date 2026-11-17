# 設計：純文字檔的預覽

## Approach

```
⌘-click 路徑 ─▶ PreviewTarget.resolve ─▶ PreviewTarget.kind ─┬─ .markdown ─▶ lmux-preview ─▶ MarkdownHTML.page
                                                              ├─ .text ─────▶ lmux-preview ─▶ MarkdownHTML.textPage（<pre>）
                                                              └─ .html ─────▶ loadFileURL（不變）
```

沿用 md-html-preview 的架構（`beat/features/preview/design.md`），只多一種「走 `lmux-preview` scheme 的頁面」。

1. **判斷**（`App/Sources/LmuxUI/PreviewTarget.swift`）
   - 新增 `enum Kind { case markdown, html, text }` 與 `static func kind(_ url: URL) -> Kind?`：
     1. 先問 `isMarkdown`、`isHTML`（規則只有一份）→ `.markdown`／`.html`。
     2. 其他：`UTType(filenameExtension:)` 屬於 `.text`，而且不屬於 `.html`、`.rtf`、`.svg`、`net.daringfireball.markdown` → `.text`（例如 `.mdown` 不算純文字檔；`.xhtml` 在本機是 `public.xhtml`，不屬於 `.html`，算純文字檔，plan 階段實測）。
     3. 其餘回傳 nil。
   - `isText(_:)` 與 `usesPreviewScheme(_:)`（`.markdown` 或 `.text`）。
   - `resolve` 的兩處副檔名檢查（`:106`、`:111`）改成 `kind(...) != nil`。symlink 的目標也要是同一種 `Kind`。這一步放在最後一個程式 task：前面的 task 完成前，⌘-click 純文字檔不會跳出選單，每個 commit 都不會出現「跳出選單卻顯示錯誤頁」的中間狀態。
   - `extensions`（`:6`）不再需要，刪除。呼叫端只有 `resolve`（`rg -F 'extensions' App/Sources App/scripts` 在預覽程式裡只命中 `:6`、`:106`、`:111`）。
2. **產生頁面**
   - `MarkdownHTML` 新增 `textPage(_ text: String, title: String)`：用現有的 `shellPage`（`MarkdownHTML.swift:11-17`，含 `color-scheme`）與 `escape`（`:147`），內容放進 `<pre class="plain">`。
   - 純文字頁用更嚴的 CSP `textCSP`（`default-src 'none'; style-src 'unsafe-inline'`）：純文字頁用不到圖片，萬一跳脫出錯也載入不了外部網址。`shellPage` 多一個 `csp` 參數，預設值是原本的 CSP。
   - CSS 加 `.plain`：等寬字型、`white-space: pre-wrap`、`overflow-wrap: anywhere`。顏色沿用現有的 `--bg`、`--fg` 變數，所以深淺色跟 Markdown 一樣切換。
3. **scheme 回應**（`App/Sources/LmuxUI/PreviewScheme.swift:75-87`）
   - 加 `.text` 分支：讀檔方式、大小上限（`maxMarkdownBytes`）、太大／不存在／讀不了的頁面，都與 Markdown 分支相同。
   - 以 `String(decoding:as: UTF8.self)` 解讀（與 Markdown 相同），無效位元組變成替代字元。
   - 純文字檔**只當整頁回應**：`response(for:mainDocument:)` 的 `mainDocument` 由 `webView(_:start:)` 以 `task.request.mainDocumentURL == url` 判斷。Markdown 頁面用 `<img>` 之類引用純文字檔時仍然拒絕。證據（plan 階段實測）：新檢查用 `MockSchemeTask` 經過 `webView(_:start:)`，子資源請求被拒、整頁請求有回應；既有檢查「scheme 拒收非圖片（.txt）」（`App/scripts/preview-webkit-check.swift:194`）維持通過；中文加空格的檔名，整頁比對仍成立。
   - Markdown 與純文字檔用 `switch PreviewTarget.kind(file)` 選頁面，以後加新的 `Kind` 時編譯器會提醒。
4. **預覽 tab**（`App/Sources/LmuxUI/PreviewView.swift`）
   - `show`（`:124`）、載入失敗（`:238`）、檔案監看（`:315-316`）裡代表「走 lmux-preview」的 `isMarkdown`，改成 `usesPreviewScheme`；對真實路徑的檢查改成「`kind(real) == kind(file)`」。
5. **導覽**（`App/Sources/LmuxUI/PreviewViewNavigation.swift:69-78`）
   - `lmux-preview` 網址是 `.text` 時：只有 Swift 主動載入、重新載入、上一頁／下一頁才允許，並關閉 JavaScript。頁面裡的連結點擊一律取消，什麼都不開。
   - 這樣保留現有行為：今天 Markdown 頁面連到 `.txt` 時，會走到 `openHTMLFromPreview`（`:180-183`），它只接受 HTML，所以什麼都不做。
   - `file://` 導覽（`handleFileMainFrameNavigation`，`:192` 起）不改。
6. **不改**：`OpenMenu.swift`（直接用 `PreviewTarget.resolve`）、開啟選單的項目、`UntrustedURL`、tab 標題（頁面 `<title>` 是檔名，與 Markdown 相同）。

## Key Decisions

1. **用 macOS 的 UTType 判斷純文字，不維護副檔名清單。**
   - 使用者 2026-11-16 選擇「系統判斷」（選項 C），並選擇只處理正常情況：不補 `ts`、`env` 等漏掉的副檔名，只排除 RTF 與 SVG。
   - 替代方案：固定清單（只做 `txt`／`sh`／`yaml`／`yml`，或再加常見設定檔）；系統判斷加補充清單。
   - 代價：結果取決於電腦裝了哪些 app（本機 `conf` 是 `com.coteditor.conf`）。
   - ADR 檢查：要改回清單只需改 `kind` 一個函式，不算難以還原 → 不寫 ADR。
2. **用副檔名查 UTType，不讀檔案本身的 content type。**
   - 與現有的 `isMarkdown`、`isHTML` 一致，都只看副檔名。
   - 檔案被刪除後仍能判斷種類，監看才能顯示「檔案已不存在」（`PreviewView.swift:315-316` 對已刪除的檔案也要知道它是哪一種）。
   - ADR 檢查：不難還原 → 不寫 ADR。
3. **沿用 `lmux-preview` scheme 產生 `<pre>` 頁面。**
   - 替代 1：`loadFileURL` 直接載入文字檔。WebKit 依 MIME 決定怎麼顯示：`.xml` 可能被當成文件渲染，而且會牽進 HTML 的資料夾授權與 JavaScript 規則。
   - 替代 2：用 `NSTextView` 顯示。要在 `Pane` 加第三種內容（`App/Sources/LmuxUI/Model.swift` 的 `Content`），改動面大很多。
   - 選擇的做法：不執行 JavaScript、CSP、HTML 跳脫，都已由 md-html-preview 的檢查腳本驗證過，只多一種頁面。
   - ADR 檢查：只影響預覽內部，不難還原 → 不寫 ADR。
4. **長行自動換行。** 預覽開了兩指滑動返回（`App/Sources/LmuxUI/PreviewView.swift:38` 的 `allowsBackForwardNavigationGestures = true`）。橫向捲動會和這個手勢衝突。
5. **預覽裡連到純文字檔的連結不換頁。** 維持現有行為，縮小這次的範圍（使用者 2026-11-16 同意）。

## Components

| 檔案 | 改動 |
|---|---|
| `App/Sources/LmuxUI/PreviewTarget.swift` | `Kind`、`kind`、`isText`、`usesPreviewScheme`；`resolve` 改用 `kind`；刪除 `extensions` |
| `App/Sources/LmuxUI/MarkdownHTML.swift` | `textPage`、`textCSP`；`shellPage` 加 `csp` 參數；CSS 加 `pre.plain` |
| `App/Sources/LmuxUI/PreviewScheme.swift` | 純文字檔只當整頁回應（`mainDocument`）；註解同步 |
| `App/Sources/LmuxUI/PreviewView.swift` | 三處 `isMarkdown` 改成 `usesPreviewScheme`／`kind`；註解同步 |
| `App/Sources/LmuxUI/PreviewViewNavigation.swift` | `lmux-preview` 的 `.text` 導覽規則 |
| `App/scripts/preview-check.swift` | `kind` 判斷（失敗訊息附 UTType）、`textPage` 跳脫、`resolve`；原本以 `notes.txt` 當「不可預覽」的例子改成 `AppIcon.icns` |
| `App/scripts/preview-webkit-check-text.swift`（新增） | scheme 的整頁／子資源、顯示、導覽、自動更新、捲動位置、symlink |
| `App/scripts/preview-webkit-check.swift` | 呼叫新的檢查；總時限 120 → 240 秒 |
| `App/Sources/lmux-apptest/PreviewText.swift`（新增） | ⌘-click → 開啟選單 → 預覽 tab、lmux 外觀設定、自動更新、頁內連結、`.sh`／`.command` 被擋 |
| `App/Sources/lmux-apptest/Preview.swift` | 呼叫 `runPreviewTextChecks` |
| `App/Sources/lmux-apptest/PreviewInteractions.swift` | 原本以 `notes.txt` 當「不是可預覽檔案」的例子改成 `icon.svg` |

### 邊緣情況

| 情況 | 結果 |
|---|---|
| `a.txt` 是指向 `b.md` 的 symlink | 種類不同，顯示「檔案已不存在」（與現有 Markdown 的 symlink 規則相同） |
| 空檔案 | 顯示空白頁面 |
| `.sh` 有執行權限 | 只讀取內容，不執行 |
| 沒有副檔名（`Makefile`、`.env`） | `pathExtension` 是空字串，不查 UTType，不是純文字檔，照原本流程 |
| `.md` 是指向 `.html` 的 symlink | 改版前會跳出選單、預覽顯示「檔案已不存在」；改版後種類不同，照原本流程（行為變更，`preview-check` 有檢查） |
| `.command`、`.tool` | 本機 UTType 是 `com.apple.terminal.shell-script`，屬於純文字，可以預覽；「用預設 app 開」被 `UntrustedURL` 的副檔名規則擋下（apptest 有檢查） |
| 內容含雙向控制字元或零寬字元（例如 U+202E） | 原樣交給 WebKit，畫面上可能重排或看不見。**待使用者決定**是否改成顯示可見標記（security review 提出） |
| tab 開著時，LaunchServices 的類型登記改變（例如新裝的 app 宣告了 `.conf`） | 監看重新判斷種類，可能改顯示「檔案已不存在」。執行中的 process 的 UTType 結果會不會即時改變：未查證 |
| 剛建立檔案就馬上開啟 | plan 階段的 WebKit 檢查偶發失敗過：推測監看收到建檔事件，在新頁面載入完成前重新載入了上一頁（未證實）。Markdown 也走同一段監看程式，不是這個 change 新增的。測試改成先建好檔案、等 0.5 秒再開 |
| `.log` 持續寫入 | 每次變動都重新載入；捲動位置不變，不跳回開頭（plan 階段在真的 WKWebView 實測：更新前後 `scrollY` 都是 9002） |
