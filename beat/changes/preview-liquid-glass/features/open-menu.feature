# language: zh-TW
功能: ⌘-click 可預覽檔案的路徑時選擇開在哪裡

  終端機輸出裡的可預覽檔案路徑（Markdown、HTML、純文字檔），⌘-click 後跳出開啟選單。使用者可以開在右側即時預覽、
  開成預覽 tab、交給系統預設 app、在 Finder 顯示，或複製路徑。其他路徑與網址照原本流程。

  身為 整天看 Claude 產出文件的使用者
  我想要 ⌘-click 終端機裡的文件、腳本、設定檔路徑時，選擇要開在右側即時預覽或獨立預覽 tab
  以便 不打斷終端版面就能檢視檔案，需要時也能並排對照或交給其他 app

  流程:
    1. 使用者按住 ⌘ 點終端機裡的路徑文字或 OSC 8 連結
    2. Ghostty 偵測路徑；相對路徑用 shell 回報的目前目錄補成絕對路徑
    3. lmux 去掉路徑尾端的 ":行號"，判斷它是不是存在的可預覽檔案
    4. 是：在滑鼠位置跳出開啟選單（按住 ⌃⌘ 點擊可略過選單直接開在新 tab 預覽）。否：照加入選單前的方式開啟

  開啟選單的內容:
    | 位置    | 項目               | 結果                                   |
    | 第 1 列 | 完整路徑（不能點；路徑太長時中間用 … 省略，tooltip 顯示全文） | 讓使用者確認實際要開的檔案             |
    | 第 2 列 | 在右側欄即時預覽   | 展開 **右側 Inspector** 並於「即時預覽」載入該檔案 |
    | 第 3 列 | 在新 tab 預覽      | 開出 **預覽 tab**                      |
    | 第 4 列 | 用預設 app 開      | 與加入選單前的 ⌘-click 相同            |
    | 第 5 列 | 在 Finder 顯示     | Finder 開啟並選取這個檔案              |
    | 第 6 列 | 複製路徑           | 剪貼簿內容是這個檔案的完整路徑         |

  關鍵決策:
    **雙軌預覽保留彈性**：「在右側欄即時預覽」作為預設首項，讓終端版面維持不動；同時保留「在新 tab 預覽」供需要獨立並排編輯／分割比較時使用。
    **沿用 ⌘-click**：使用者原話是「用滑鼠點一下」。不按 ⌘ 的點擊在終端機是選取文字，Ghostty 也只在按住 ⌘ 時開連結。
    **選單第 1 列顯示完整路徑**：OSC 8 連結的文字可以跟實際指向的檔案不同，先讓使用者看到真正要開的檔案。
    **只攔可預覽檔案**：其他路徑與網址照原本流程，不改變既有的連結安全規則。

  # --- 跳出開啟選單 ---

  @e2e @happy-path
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewInteractions.swift
  # @covered-by: beat/changes/archive/2026-11-16-md-html-preview/manual-verification.md
  場景: ⌘-click 可預覽檔案的路徑跳出開啟選單
    假設 一個 **終端機 tab** 的目前目錄裡有 "docs/design.md"
    而且 終端機輸出了文字 "docs/design.md"
    當 使用者按住 ⌘ 點這段文字
    那麼 滑鼠位置跳出 **開啟選單**
    而且 選單第 1 列是 "docs/design.md" 的完整路徑（路徑太長時中間用 … 省略，tooltip 顯示全文），不能點
    而且 選單接著列出 "在右側欄即時預覽"、"在新 tab 預覽"、"用預設 app 開"、"在 Finder 顯示"、"複製路徑"

  @e2e @edge-case
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewInteractions.swift
  場景: 路徑後面帶行號時，去掉行號再判斷
    假設 一個 **終端機 tab** 的目前目錄裡有 "docs/design.md"
    而且 終端機輸出了文字 "docs/design.md:12"
    當 使用者按住 ⌘ 點這段文字
    那麼 跳出 **開啟選單**
    而且 選單第 1 列的路徑結尾是 "docs/design.md"，不含 ":12"

  @e2e @edge-case
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewInteractions.swift
  場景: OSC 8 連結指向本機的可預覽檔案時也跳出開啟選單
    假設 終端機輸出一個 OSC 8 連結，文字是 "設計文件"，指向 "file:///tmp/demo/design.md"
    而且 "/tmp/demo/design.md" 存在
    當 使用者按住 ⌘ 點這個連結
    那麼 跳出 **開啟選單**
    而且 選單第 1 列是 "/tmp/demo/design.md"

  @e2e @edge-case
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewInteractions.swift
  場景大綱: 不是存在的可預覽檔案時，照原本流程
    假設 終端機輸出了文字 "<輸出>"
    而且 <情況>
    當 使用者按住 ⌘ 點這段文字
    那麼 不跳出 **開啟選單**
    而且 這段文字照加入選單前的方式開啟

    例子:
      | 輸出                          | 情況                     |
      | assets/AppIcon.icns           | 這個檔案存在，但不是可預覽檔案 |
      | assets/icon.svg               | 這個檔案是 SVG，不是可預覽檔案 |
      | docs/missing.md               | 這個檔案不存在           |
      | https://example.com/readme.md | 這是網址，不是本機檔案   |

  @e2e @edge-case
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewInteractions.swift
  場景: shell 沒回報目前目錄時，相對路徑照原本流程
    假設 一個 **終端機 tab** 的 shell 沒有回報目前目錄
    而且 終端機輸出了文字 "docs/design.md"
    當 使用者按住 ⌘ 點這段文字
    那麼 不跳出 **開啟選單**
    而且 這段文字照加入選單前的方式開啟

  # --- 選單項目 ---

  @e2e @happy-path
  場景: 選「在右側欄即時預覽」載入檔案至右側 Inspector
    假設 一個 **workspace** 的 **終端機 tab** A 跳出了 "docs/design.md" 的 **開啟選單**
    而且 **右側 Inspector** 目前處於收合或顯示其他分頁的狀態
    當 使用者選 "在右側欄即時預覽"
    那麼 **右側 Inspector** 應自動展開並切換到 "即時預覽" 分頁
    而且 預覽視埠應載入並渲染 "docs/design.md"，且原本終端分割結構維持不變

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/Preview.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewInteractions.swift
  場景: 選「在新 tab 預覽」開出預覽 tab
    假設 一個 **workspace** 有 **終端機 tab** A 與它右邊的 **tab** B
    而且 A 是 **focused tab**
    而且 A 跳出了 "docs/design.md" 的 **開啟選單**
    當 使用者選 "在新 tab 預覽"
    那麼 A 與 B 之間多出一個 **預覽 tab**，顯示 "docs/design.md"
    而且 這個預覽 tab 成為 **focused tab**

  @e2e @edge-case
  場景: 按住 ⌃⌘ 點擊可預覽檔案直接開成預覽 tab
    假設 一個 **workspace** 的 **終端機 tab** A 的目前目錄裡有 "docs/design.md"
    當 使用者同時按住 ⌃ 與 ⌘ 點擊 "docs/design.md"
    那麼 不跳出 **開啟選單**，直接緊鄰 A 開出顯示 "docs/design.md" 的 **預覽 tab**

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/PreviewInteractions.swift
  場景大綱: 選單的其他項目
    假設 一個 **終端機 tab** 跳出了 "docs/design.md" 的 **開啟選單**
    當 使用者選 "<項目>"
    那麼 <結果>
    而且 沒有開出 **預覽 tab**

    例子:
      | 項目           | 結果                                          |
      | 用預設 app 開  | 檔案用系統預設 app 開啟，與加入選單前的 ⌘-click 相同 |
      | 在 Finder 顯示 | Finder 開啟並選取這個檔案                     |
      | 複製路徑       | 剪貼簿內容是這個檔案的完整路徑                |

  @e2e @edge-case
  # @covered-by: App/Sources/lmux-apptest/PreviewInteractions.swift
  # @covered-by: beat/changes/archive/2026-11-16-md-html-preview/manual-verification.md
  場景: 不選任何項目就關掉選單
    假設 一個 **終端機 tab** 跳出了 "docs/design.md" 的 **開啟選單**
    當 使用者按 Esc 或點選單外面
    那麼 選單關閉，沒有開啟任何東西
    而且 鍵盤焦點回到這個終端機 tab
