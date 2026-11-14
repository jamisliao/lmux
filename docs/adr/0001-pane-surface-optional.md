# Pane.surface 改成 optional，讓 tab 能裝終端機以外的內容

為了加入預覽 tab（顯示 .md 與 .html），`Pane` 改成持有「終端機」或「預覽」其中一種內容，`Pane.surface` 因此變成 optional。我們選這個做法，是因為大部分漏改的地方會直接編譯失敗（例外：`===`、`!==` 與 `makeFirstResponder(_:)` 接受 optional，這幾處要人工確認）；代價是動到 48 個上游檔案（`LmuxUI` 22 個、`lmux-apptest` 26 個，其中 25 個測試檔改用 `.surface!`；`lmux-imetest` 0 個），之後合併上游 lmux 時衝突會變多。

## Considered Options

- **預覽 tab 背後仍跑一個 shell，把預覽蓋在 surface 上**：約 6 個檔案，但漏改一處時鍵盤輸入會跑進看不見的 shell，沒有任何錯誤訊息。
- **預覽 tab 用獨立型別，`Pane` 不動**：要改 tab 樹的 API，正式程式 23 個檔案、測試 34 個檔案，沒有比較省。
- **`surface` 宣告成 `SurfaceView!`**：測試不用改，但漏改一處就讓 lmux 當掉，所有 tab 的 shell 跟著結束。

來源：`beat/changes/md-html-preview/design.md` 的 Key Decision 1（2026-11-13）。
