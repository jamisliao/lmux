# preview

⌘-click 終端機裡的 `.md`／`.html`／純文字檔路徑，跳出開啟選單，選「在新 tab 預覽」就在 lmux 裡顯示排版後的結果（或原樣顯示純文字），檔案改變時自動更新。

- `open-menu.feature`：⌘-click 可預覽檔案的路徑跳出 5 項開啟選單（在右側欄即時預覽、在新 tab 預覽、用預設 app 開、在 Finder 顯示、複製路徑）；其他路徑與網址照原本流程。
- `preview-tab.feature`：預覽 tab 的行為：Markdown 與 HTML 渲染、自動更新、連結與返回、可移動／分割／關閉、不還原、CLI 與選單的限制。
- `plain-text-preview.feature`：純文字檔（macOS UTType `public.text`，排除 Markdown、HTML、RTF、SVG）的預覽行為：原樣等寬顯示、不執行、自動換行、深淺色、編碼與大小限制、自動更新、頁內連結不換頁與安全規則。
- `proposal.md`、`design.md`：來自 change `plain-text-preview`（前一個 change `md-html-preview` 的規格保留在封存目錄）。

`@e2e` 場景由 `lmux-apptest --preview` 與 `App/scripts/preview-*.swift` 驗證。只能手動驗證、或自動測試只能用代替品的場景（System 外觀、真的 ⌘W、真的彈出的選單、兩指滑動），清單在封存的 change（`../../changes/archive/2026-11-16-md-html-preview/manual-verification.md`），結果欄還沒填。

程式：`App/Sources/LmuxUI/Preview*.swift`、`MarkdownHTML.swift`、`OpenMenu.swift`；測試：`App/Sources/lmux-apptest/Preview*.swift`、`App/scripts/preview-check.swift`、`preview-webkit-check*.swift`。
