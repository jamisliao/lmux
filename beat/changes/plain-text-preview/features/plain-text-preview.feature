# language: zh-TW
功能: 純文字檔的預覽

  ⌘-click 終端機裡的純文字檔路徑（例如 .sh、.yaml、.log），也跳出開啟選單。
  選「在新 tab 預覽」後，預覽 tab 以等寬字型原樣顯示檔案內容，不執行、不上色。
  哪些檔案算純文字檔，由 macOS 的類型判斷決定。

  身為 整天看 agent 產出腳本、設定檔、記錄檔的使用者
  我想要 ⌘-click 這些檔案的路徑時，在 lmux 裡直接看到原文
  以便 不離開 lmux、也不必另外開編輯器，就能確認檔案內容

  流程:
    1. 使用者 ⌘-click 終端機裡的路徑
    2. lmux 去掉尾端的 ":行號"，問 macOS 這個副檔名是不是純文字
    3. 是純文字、而且不是 Markdown、HTML、RTF、SVG：跳出開啟選單
    4. 選「在新 tab 預覽」：預覽 tab 把內容跳脫後放進等寬字型的頁面

  關鍵決策:
    **只看 macOS 的類型判斷**：使用者選擇不維護副檔名清單。代價是 .ts、.env 這類系統不認為是文字的檔案不支援，結果也可能因電腦裝了哪些 app 而不同。
    **原樣顯示、不執行**：純文字檔可能是 shell script。預覽只顯示文字，內容裡的 HTML 標籤也顯示成文字。
    **自動換行**：不換行會出現橫向捲動，和觸控板兩指滑動返回上一頁的手勢衝突。
    **不跳到行號**：使用者選擇從檔案開頭顯示。

  背景:
    假設 一個 **終端機 tab** 的目前目錄裡有 "scripts/deploy.sh"、"config/app.yaml"、"logs/run.log"

  # --- 判斷是不是純文字檔 ---

  @e2e @happy-path
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景大綱: ⌘-click 純文字檔的路徑跳出開啟選單
    假設 目前目錄裡有 "<路徑>"
    而且 終端機輸出了文字 "<路徑>"
    當 使用者按住 ⌘ 點這段文字
    那麼 滑鼠位置跳出 **開啟選單**
    而且 選單裡有 "在新 tab 預覽"

    例子:
      | 路徑             |
      | notes/todo.txt   |
      | scripts/deploy.sh |
      | config/app.yaml  |
      | config/app.yml   |
      | data/result.json |
      | logs/run.log     |
      | tools/check.py   |

  @e2e @edge-case
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景大綱: macOS 不認為是純文字、或被排除的檔案，照原本流程
    假設 目前目錄裡有 "<路徑>"
    而且 終端機輸出了文字 "<路徑>"
    當 使用者按住 ⌘ 點這段文字
    那麼 不跳出 **開啟選單**
    而且 這段文字照加入選單前的方式開啟

    例子:
      | 路徑           | 原因                              |
      | docs/intro.rtf | RTF 是富文字，被排除              |
      | assets/logo.svg | SVG 是圖片，被排除               |
      | web/app.ts     | macOS 把 .ts 認成影片，不是純文字 |
      | config/.env    | macOS 沒有 .env 的類型，不是純文字 |

  # --- 顯示原文 ---

  @e2e @happy-path
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景: 純文字檔以等寬字型原樣顯示
    假設 "scripts/deploy.sh" 的內容有一行 "echo '<b>done</b>'"
    當 使用者 ⌘-click "scripts/deploy.sh" 並選 "在新 tab 預覽"
    那麼 開出一個 **預覽 tab**，標題是 "deploy.sh"
    而且 預覽以等寬字型顯示檔案的每一行
    而且 "<b>done</b>" 原樣顯示成文字，不是粗體

  @e2e @edge-case
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景: 有執行權限的 shell script 只顯示，不執行
    假設 "scripts/deploy.sh" 有執行權限，執行時會建立 "/tmp/deploy-ran"
    當 使用者 ⌘-click "scripts/deploy.sh" 並選 "在新 tab 預覽"
    那麼 **預覽 tab** 顯示 "scripts/deploy.sh" 的內容
    而且 "/tmp/deploy-ran" 不存在

  @e2e @edge-case
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  場景: 很長的一行自動換行
    假設 "logs/run.log" 有一行比預覽 tab 還寬
    當 使用者在 **預覽 tab** 開啟 "logs/run.log"
    那麼 這一行折成多行顯示
    而且 預覽沒有橫向捲動

  @e2e @edge-case
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景: 路徑帶行號時，從檔案開頭顯示
    假設 終端機輸出了文字 "config/app.yaml:42"
    當 使用者 ⌘-click 這段文字並選 "在新 tab 預覽"
    那麼 **開啟選單** 第 1 列的路徑結尾是 "config/app.yaml"，不含 ":42"
    而且 **預覽 tab** 從檔案的第 1 行開始顯示

  @e2e @happy-path
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景: 純文字預覽跟著 lmux 的外觀設定切換深淺色
    假設 **預覽 tab** 正在顯示 "config/app.yaml"
    當 使用者把 lmux 的外觀設定從 Light 改成 Dark
    那麼 預覽改用深色背景與淺色文字

  @e2e @edge-case
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  場景: 內容有不是 UTF-8 的位元組
    假設 "logs/run.log" 有幾個不是 UTF-8 的位元組，其他內容是正常文字
    當 使用者在 **預覽 tab** 開啟 "logs/run.log"
    那麼 那幾個位元組顯示成替代字元
    而且 其他內容照常顯示

  @e2e @edge-case
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  場景: 檔案超過大小上限
    假設 "logs/run.log" 超過預覽的大小上限
    當 使用者在 **預覽 tab** 開啟 "logs/run.log"
    那麼 預覽顯示「檔案太大，無法預覽」與完整路徑

  # --- 自動更新 ---

  @e2e @happy-path
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景: 純文字檔內容改變後，預覽自動更新
    假設 **預覽 tab** 正在顯示 "config/app.yaml"
    當 另一個程式在 "config/app.yaml" 加上一行 "debug: true"
    那麼 預覽顯示新加的 "debug: true"，不需要使用者操作

  @e2e @edge-case
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景: 預覽中的純文字檔被刪除
    假設 **預覽 tab** 正在顯示 "config/app.yaml"
    當 "config/app.yaml" 被刪除
    那麼 預覽顯示「檔案已不存在」與完整路徑

  # --- 開啟選單的其他項目與預覽裡的連結（行為不變） ---

  @e2e @edge-case
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景: shell script 選「用預設 app 開」仍被安全規則擋下
    假設 "scripts/deploy.sh" 跳出了 **開啟選單**
    當 使用者選 "用預設 app 開"
    那麼 lmux 顯示擋下這個檔案的提示，和加入純文字預覽前一樣
    而且 "scripts/deploy.sh" 沒有被開啟或執行
    而且 沒有開出 **預覽 tab**

  @e2e @edge-case
  # @covered-by: App/scripts/preview-webkit-check-text.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景: Markdown 預覽裡連到純文字檔的連結不換頁
    假設 **預覽 tab** 正在顯示 "docs/guide.md"
    而且 "docs/guide.md" 有一個相對路徑連結指向 "../config/app.yaml"
    當 使用者點這個連結
    那麼 預覽仍顯示 "docs/guide.md"
    而且 沒有開出新的 **tab**
