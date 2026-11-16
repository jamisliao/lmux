# preview

⌘-click 終端機裡的 `.md`／`.html` 路徑，跳出開啟選單，選「在新 tab 預覽」就在 lmux 裡顯示排版後的結果，檔案改變時自動更新。

- `open-menu.feature`：⌘-click 可預覽檔案的路徑跳出開啟選單（在新 tab 預覽、用預設 app 開、在 Finder 顯示、複製路徑）；其他路徑與網址照原本流程。
- `preview-tab.feature`：預覽 tab 的行為：Markdown 與 HTML 渲染、自動更新、連結與返回、可移動／分割／關閉、不還原、CLI 與選單的限制。
- `proposal.md`、`design.md`：來自 change `md-html-preview`（含「已知範圍」與「已查證」的安全說明）。

`@e2e` 場景由 `lmux-apptest --preview` 與 `App/scripts/preview-*.swift` 驗證。只能手動驗證、或自動測試只能用代替品的場景（System 外觀、真的 ⌘W、真的彈出的選單、兩指滑動），清單在封存的 change（`../../changes/archive/2026-11-16-md-html-preview/manual-verification.md`），結果欄還沒填。

程式：`App/Sources/LmuxUI/Preview*.swift`、`MarkdownHTML.swift`、`OpenMenu.swift`；測試：`App/Sources/lmux-apptest/Preview*.swift`、`App/scripts/preview-check.swift`、`preview-webkit-check*.swift`。
