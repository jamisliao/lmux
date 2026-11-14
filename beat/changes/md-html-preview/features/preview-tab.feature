# language: zh-TW
功能: 預覽 tab

  預覽 tab 在 lmux 裡顯示 .md 的排版結果或 .html 頁面，檔案改變時自動更新。
  它跟終端機 tab 一樣可以移動、分割、關閉，但沒有終端機，也沒有 agent 狀態。

  身為 邊看 agent 改文件、邊看結果的使用者
  我想要 在 lmux 的 tab 裡直接看到 .md 與 .html 渲染後的樣子，而且內容跟著檔案更新
  以便 不切換到其他 app，就能確認 agent 寫出來的文件

  Markdown 支援範圍:
    | 語法                               | 顯示方式                           |
    | 標題、清單、表格、引用、連結、圖片 | 排版後的樣子                       |
    | callout（引用第 1 行是 [!類型]）   | 提示框                             |
    | 程式碼區塊（含 mermaid）           | 等寬字加底色，不上色               |
    | 內嵌的 HTML 標籤                   | 顯示成文字，不執行                 |
    | 數學式                             | 顯示原本的文字                     |

  關鍵決策:
    **Markdown 不加依賴**：Foundation 內建的解析器能解析標題、表格、程式碼區塊、引用、圖片與連結（2026-11-13 實測）。
    **不上色、不支援 mermaid**：找不到對應的系統 API（未查證）。使用者的 Obsidian vault 7937 個 .md 只有 38 個用 mermaid。
    **Markdown 裡的 HTML 不執行**：HTML 預覽允許連網，Markdown 預覽若再執行內嵌 script，等於讓任何 .md 都能連網執行程式。
    **HTML 允許連網**：使用者 vault 的 331 個 HTML 有 254 個從 CDN 載入 script；擋網路時這些 script 不會載入（2026-11-13 實測）。
    **不保存 cookie 與 storage**：預覽之間不共享登入狀態，關掉 tab 就清掉。
    **監看資料夾，不只監看檔案**：有些工具存檔時先寫暫存檔再改名，原本監看的檔案會被換掉。
    **重開 lmux 不還原**：預覽 tab 開起來很快，不值得多存一種 tab。

  # --- Markdown 渲染 ---

  @e2e @happy-path
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/scripts/preview-webkit-check.swift
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: Markdown 顯示成排版後的樣子
    假設 "design.md" 含有標題、清單、表格、程式碼區塊與引用
    當 使用者用 **預覽 tab** 開啟它
    那麼 標題、清單、表格、程式碼區塊與引用都顯示成排版後的樣子
    而且 畫面上看不到 "#"、"|"、"```" 這些 Markdown 符號

  @behavior @happy-path
  # @covered-by: App/scripts/preview-check.swift
  場景大綱: callout 顯示成提示框
    假設 Markdown 有一段引用，第 1 行是 "<第 1 行>"
    當 這份 Markdown 在 **預覽 tab** 顯示
    那麼 這段引用顯示成提示框，標題是 "<標題>"
    而且 畫面上看不到 "[!"

    例子:
      | 第 1 行           | 標題    |
      | > [!NOTE]         | Note    |
      | > [!warning] 小心 | 小心    |

  @behavior @edge-case
  # @covered-by: App/scripts/preview-check.swift
  場景: 程式碼區塊不上色，mermaid 區塊顯示成一般程式碼區塊
    假設 Markdown 有一個 swift 程式碼區塊與一個 mermaid 程式碼區塊
    當 這份 Markdown 在 **預覽 tab** 顯示
    那麼 兩個區塊都顯示成等寬字加底色的原始文字

  @behavior @edge-case
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/scripts/preview-webkit-check.swift
  場景: Markdown 裡的 HTML 標籤顯示成文字，不執行
    假設 Markdown 有一段文字 "前文 <script>alert(1)</script> 後文"
    當 這份 Markdown 在 **預覽 tab** 顯示
    那麼 畫面上顯示 "<script>alert(1)</script>" 這段文字
    而且 沒有執行任何 script

  @e2e @edge-case
  # @covered-by: App/scripts/preview-webkit-check.swift
  場景: Markdown 用相對路徑引用的圖片顯示出來
    假設 "docs/design.md" 引用了 "img/flow.png"
    而且 "docs/img/flow.png" 存在
    當 使用者用 **預覽 tab** 開啟 "docs/design.md"
    那麼 預覽裡顯示這張圖片

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: Markdown 預覽跟著 lmux 的外觀設定切換深淺色
    假設 一個 **預覽 tab** 正在顯示 Markdown
    當 使用者把 lmux 的外觀設定從 Light 改成 Dark
    那麼 預覽的背景與文字改成深色配色，不用重新開啟
    而且 外觀設定是 System 時，預覽跟著 macOS 的深淺色切換

  # --- HTML 渲染 ---

  @e2e @happy-path
  # @covered-by: App/scripts/preview-webkit-check.swift
  場景: HTML 從網路載入的 script 正常執行
    假設 "report.html" 從 CDN 載入一個 JS 函式庫
    當 使用者用 **預覽 tab** 開啟它
    那麼 這個函式庫載入成功，頁面上依賴它的內容顯示出來

  @e2e @happy-path
  # @covered-by: App/scripts/preview-webkit-check.swift
  場景: HTML 讀得到同資料夾的 CSS 與圖片
    假設 "site/index.html" 引用了 "site/style.css" 與 "site/logo.png"
    當 使用者用 **預覽 tab** 開啟 "site/index.html"
    那麼 頁面套用了 "style.css" 的樣式，也顯示 "logo.png"

  @e2e @edge-case
  # @covered-by: App/scripts/preview-webkit-check.swift
  場景: 重新開啟預覽時，不保留上一次的 cookie 與 storage
    假設 一個 **預覽 tab** 開啟的 HTML 在 localStorage 存了一筆資料
    而且 使用者關掉這個預覽 tab
    當 使用者再用新的 **預覽 tab** 開啟同一個 HTML
    那麼 頁面讀不到上一次存的資料

  # --- 自動更新 ---

  @e2e @happy-path
  # @covered-by: App/scripts/preview-webkit-check.swift
  場景: 檔案內容改變後，預覽自動更新
    假設 一個 **預覽 tab** 正在顯示 "design.md"
    當 另一個程式改寫了 "design.md" 的內容
    那麼 預覽顯示新的內容，使用者不用做任何操作

  @e2e @edge-case
  # @covered-by: App/scripts/preview-webkit-check.swift
  場景: 以「寫暫存檔再改名」方式存檔，預覽也會更新
    假設 一個 **預覽 tab** 正在顯示 "design.md"
    當 另一個程式把新內容寫到暫存檔，再改名蓋掉 "design.md"
    那麼 預覽顯示新的內容
    而且 之後再改 "design.md"，預覽仍然會更新

  @e2e @error-handling
  # @covered-by: App/scripts/preview-webkit-check.swift
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 預覽中的檔案被刪除
    假設 一個 **預覽 tab** 正在顯示 "design.md"
    當 "design.md" 被刪除
    那麼 預覽顯示「檔案已不存在」與這個檔案的完整路徑
    而且 這個預覽 tab 仍然留著，使用者自己關掉

  # --- 預覽裡的連結 ---

  @e2e @happy-path
  # @covered-by: App/scripts/preview-webkit-check.swift
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 點相對路徑的 .md 連結，在同一個預覽 tab 換頁
    假設 一個 **預覽 tab** 正在顯示 "docs/a.md"，裡面有連到 "b.md" 的連結
    而且 "docs/b.md" 存在
    當 使用者點這個連結
    那麼 同一個預覽 tab 改成顯示 "docs/b.md"，tab 標題改成 "b.md"
    而且 沒有開出新的 **tab**

  @e2e @happy-path
  # @covered-by: App/scripts/preview-webkit-check.swift
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 在預覽裡用觸控板兩指往右滑，回到上一頁
    假設 一個 **預覽 tab** 從 "docs/a.md" 點連結換到了 "docs/b.md"
    當 使用者在預覽上用觸控板兩指往右滑
    那麼 預覽 tab 回到 "docs/a.md"，tab 標題改回 "a.md"

  @e2e @happy-path
  # @covered-by: App/scripts/preview-webkit-check.swift
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 點網址連結，照終端機裡點連結的規則處理
    假設 一個 **預覽 tab** 正在顯示的頁面有連到 "https://example.com" 的連結
    當 使用者點這個連結
    那麼 這個網址的處理方式，與在終端機 ⌘-click 同一個網址相同
    而且 預覽 tab 仍然顯示原本的頁面
    而且 頁面的 script 自己觸發點擊、或用 meta refresh 跳轉時，不會開啟任何網址，預覽仍然顯示原本的頁面

  # --- tab 行為 ---

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 預覽 tab 的標題是檔名
    當 使用者用 **預覽 tab** 開啟 "/Users/me/repo/docs/design.md"
    那麼 這個預覽 tab 的標題是 "design.md"

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 預覽 tab 可以像終端機 tab 一樣移動與分割
    假設 一個 **workspace** 有 **終端機 tab** A 與 **預覽 tab** P
    當 使用者把 P 拖到 A 的右側分割
    那麼 A 與 P 左右並排，P 仍然顯示原本的檔案

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 關閉預覽 tab 後，相鄰 tab 成為 focused tab
    假設 一個 **workspace** 有 **終端機 tab** A 與 **預覽 tab** P 左右並排
    而且 P 是 **focused tab**
    當 使用者按 ⌘W 關閉 P
    那麼 P 消失，A 成為 **focused tab**

  @e2e @edge-case
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 在預覽 tab 上開新 tab，新的終端機從檔案所在資料夾開始
    假設「新 tab 沿用目前目錄」的設定為開啟
    而且 **預覽 tab** P 顯示 "/Users/me/repo/docs/design.md"，P 是 **focused tab**
    當 使用者按 ⌘T
    那麼 新的 **終端機 tab** 的目前目錄是 "/Users/me/repo/docs"

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上
    假設 一個 **workspace** 有 **終端機 tab** A 與 **預覽 tab** P
    而且 P 是 **focused tab**
    當 使用者打字 "ls" 再按 Enter
    那麼 A 的終端機沒有收到 "ls"

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 在預覽 tab 選取文字並按 ⌘C 會複製到剪貼簿
    假設 一個 **workspace** 有 **預覽 tab** P，裡面顯示文字
    當 使用者在 P 選取一段文字，按 ⌘C
    那麼 剪貼簿內容是選取的那段文字

  @e2e @edge-case
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 預覽 tab 上停用只對終端機有意義的功能
    假設 **預覽 tab** P 是 **focused tab**
    當 使用者打開選單列
    那麼 "Find…"、"Find Next"、"Find Previous"、"Undo Send"、"Copy Original Reply" 與 Ghostty 字級調整／Clear Screen 是停用狀態
    而且 "Close Pane"、"Move Tab Right"、"Split Right" 仍然可以用
    而且 按 Paste 不會貼進任何終端機
    而且 預覽上沒有 Rewind 按鈕

  @e2e @error-handling
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: CLI 指定預覽 tab 時回傳錯誤
    假設 **預覽 tab** P 存在
    當 使用者執行 "lmux send"，目標是 P
    那麼 指令失敗，錯誤訊息說明 P 不是終端機
    而且 "lmux list" 的結果不列出 P

  @e2e @edge-case
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  場景: 重開 lmux 不還原預覽 tab
    假設 **workspace** W1 有 **終端機 tab** A 與 **預覽 tab** P
    而且 **workspace** W2 只有 **預覽 tab**
    當 使用者結束 lmux 再重新開啟
    那麼 W1 還原，只有 A
    而且 W2 不還原
