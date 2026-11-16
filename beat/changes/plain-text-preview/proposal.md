# 在預覽 tab 以原文顯示純文字檔

## Why

1. **agent 常印出的腳本、設定檔、記錄檔，無法在 lmux 裡看。** 現在只有 Markdown 與 HTML 是可預覽檔案（`App/Sources/LmuxUI/PreviewTarget.swift:6` 的 `extensions` 只有 `md`、`markdown`、`html`、`htm`）。⌘-click 其他檔案時，lmux 照原本流程交給系統預設 app（`App/Sources/LmuxUI/OpenMenu.swift:27-37`）。
2. **`.sh` 連預設 app 都開不了。** 原本流程把 script 當成可執行的檔案擋下（`App/Sources/LmuxTerminal/UntrustedURL.swift:234-254` 的 `isUnsafeFile`，類型清單在 `:326`）。2026-11-16 本機實測：`UTType(filenameExtension: "sh")` 是 `public.shell-script`，屬於 `script`。所以使用者完全看不到 `.sh` 的內容。

## What Changes

1. **純文字檔也是可預覽檔案**
   - 系統判斷為純文字（UTType 屬於 `public.text`）的檔案，⌘-click 也跳出開啟選單。
   - 排除：Markdown 與 HTML（照舊渲染）、RTF、SVG。
   - 只看系統判斷，不另外維護補充清單。2026-11-16 本機實測：
     - 是純文字檔：`txt`、`sh`、`zsh`、`yaml`、`yml`、`json`、`toml`、`log`、`py`、`swift`、`csv`、`xml`、`sql`、`diff`。
     - 不是：`ts`（系統認成 MPEG-2 影片）、`env`、`gitignore`、`lock`、`jsonl`（系統沒有對應類型）。
     - 部分副檔名的結果取決於裝了哪些 app。例如本機裝了 CotEditor，`conf` 是 `com.coteditor.conf`。
2. **預覽 tab 顯示原文**
   - 等寬字型，內容原樣顯示，例如 `<b>` 顯示成文字。不執行、不上色。
   - 長的一行自動換行，不出現橫向捲動。
   - 深淺色跟著 lmux 的外觀設定切換。
   - 以 UTF-8 解讀，無法解讀的位元組顯示成替代字元。
   - 檔案太大、被刪除、讀不了時，顯示和 Markdown 相同的提示頁。檔案改變時自動更新。
   - 路徑帶 `:行號` 時，去掉行號，從檔案開頭顯示，不跳到那一行。
3. **不變**
   - 開啟選單的項目與順序不變。`.sh` 選「用預設 app 開」，仍被既有的安全規則擋下。
   - Markdown 與 HTML 預覽裡的連結規則不變。連到純文字檔的連結，點了不會換頁。

## Impact

- **行為改變**：⌘-click 原始碼或設定檔的路徑（例如 `Tabs.swift:42`），以前直接用預設 app 開，現在先跳出開啟選單，要多選一次「用預設 app 開」。使用者 2026-11-16 選這個範圍時，已知道這個代價。
- **修改既有規格**：`beat/features/preview/open-menu.feature`。它「存在但不是可預覽檔案」的例子原本是 `Tabs.swift`，這個 change 之後 `Tabs.swift` 會變成可預覽檔案。
- **程式**：只改 fork 自己新增的預覽檔案。`PreviewTarget`、`PreviewScheme`、`PreviewView`、`PreviewViewNavigation`、`MarkdownHTML` 都不在 upstream（`git cat-file -e origin/main:<path>` 皆不存在），不增加與 upstream 合併的衝突面。預估改 5 個原始碼檔，加上既有的預覽檢查腳本。
- **安全**：純文字頁面和 Markdown 一樣走 `lmux-preview` scheme，不執行 JavaScript，也帶 CSP；內容全部做 HTML 跳脫。lmux 不會執行被預覽的檔案。
- **效能**：轉換在主執行緒，大小上限與 Markdown 相同（2 MB）。未實測接近上限的檔案要轉多久。
- **未查證**：`.log` 持續寫入時，每次自動更新後捲動位置會不會跳回開頭。
