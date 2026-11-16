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
     1. 副檔名是 `md`、`markdown` → `.markdown`；`html`、`htm` → `.html`（與現有 `isMarkdown`、`isHTML` 相同）。
     2. 其他：`UTType(filenameExtension:)` 屬於 `.text`，而且不屬於 `.rtf`、`.svg` → `.text`。
     3. 其餘回傳 nil。
   - `isText(_:)` 與 `usesPreviewScheme(_:)`（`.markdown` 或 `.text`）。
   - `resolve` 的兩處副檔名檢查（`:106`、`:111`）改成 `kind(...) != nil`。symlink 的目標也要是同一種 `Kind`。
   - `extensions`（`:6`）不再需要，刪除。呼叫端只有 `resolve`（`rg -F 'extensions' App/Sources App/scripts` 在預覽程式裡只命中 `:6`、`:106`、`:111`）。
2. **產生頁面**
   - `MarkdownHTML` 新增 `textPage(_ text: String, title: String)`：用現有的 `shellPage`（`MarkdownHTML.swift:11-17`，已含 CSP 與 `color-scheme`）與 `escape`（`:147`），內容放進 `<pre class="plain">`。
   - CSS 加 `.plain`：等寬字型、`white-space: pre-wrap`、`overflow-wrap: anywhere`。顏色沿用現有的 `--bg`、`--fg` 變數，所以深淺色跟 Markdown 一樣切換。
3. **scheme 回應**（`App/Sources/LmuxUI/PreviewScheme.swift:75-87`）
   - 加 `.text` 分支：讀檔方式、大小上限（`maxMarkdownBytes`）、太大／不存在／讀不了的頁面，都與 Markdown 分支相同。
   - 以 `String(decoding:as: UTF8.self)` 解讀（與 Markdown 相同），無效位元組變成替代字元。
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
| `App/Sources/LmuxUI/MarkdownHTML.swift` | `textPage`；CSS 加 `.plain` |
| `App/Sources/LmuxUI/PreviewScheme.swift` | `.text` 分支 |
| `App/Sources/LmuxUI/PreviewView.swift` | 三處 `isMarkdown` 改成 `usesPreviewScheme`／`kind` |
| `App/Sources/LmuxUI/PreviewViewNavigation.swift` | `lmux-preview` 的 `.text` 導覽規則 |
| `App/scripts/preview-check.swift` | `kind` 判斷（含排除與不支援的例子）、`textPage` 跳脫；更新原本以 `Tabs.swift` 當「不可預覽」的檢查 |
| `App/scripts/preview-webkit-check-view.swift` | 純文字頁面顯示、JavaScript 不執行、Markdown 連到 `.txt` 不換頁、自動更新、刪除 |
| `App/Sources/lmux-apptest/PreviewInteractions.swift` | ⌘-click 純文字檔跳出開啟選單、`.sh` 選「用預設 app 開」被擋 |

### 邊緣情況

| 情況 | 結果 |
|---|---|
| `a.txt` 是指向 `b.md` 的 symlink | 種類不同，顯示「檔案已不存在」（與現有 Markdown 的 symlink 規則相同） |
| 空檔案 | 顯示空白頁面 |
| `.sh` 有執行權限 | 只讀取內容，不執行 |
| 沒有副檔名（`Makefile`） | `UTType` 查不到，不是純文字檔，照原本流程 |
| `.log` 持續寫入 | 每次變動都重新載入；捲動位置會不會跳回開頭：未查證，apply 時實測 |
