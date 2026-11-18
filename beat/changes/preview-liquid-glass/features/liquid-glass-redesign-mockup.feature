# language: zh-TW
功能: Apple Liquid Glass 與雙欄介面 UI 原型

  preview-mockup.html 是單檔互動式 UI 原型，用來試做 lmux 的雙主題 Apple Liquid Glass 材質、
  左側 sidebar 與通知 bar 拖曳調高、右側 Inspector，以及橫跨視窗底部的視窗底部狀態列。
  本規格只描述這份 UI 原型的呈現與操作行為，不改正式 Swift 程式。

  作為 設計與評估 lmux 下一版介面體驗的開發者與使用者
  我想要 在單檔 UI 原型裡直接操作雙主題玻璃材質、面板收合調寬、右側 Inspector 切換與拖曳停用模糊效果
  這樣 在動手改 SwiftUI／AppKit 之前，就能先確認版面配置、視覺層次與拖曳手感

  版面結構:
    +-------------------------------------------------------------------------+
    | Mockup Controls (淺色/深色主題 · 左側欄 · 右側欄 (Inspector) · Inbox)   |
    +-------------------------------------------------------------------------+
    | Titlebar (紅黃綠鈕 · 左側欄鈕 ⌘B · 分割鈕 · 右側欄鈕 ⌥⌘B)              |
    +------------------+----------------------------------+-------------------+
    | Sidebar (Left)   | Center Split Canvas              | 右側 Inspector    |
    | - Workspaces     |  +-------------+ +-------------+ | - 即時預覽        |
    | - History Search |  | Pane 1 Tabs | | Pane 2 Tabs | | - 變更 (Diff)     |
    | - 通知 bar       |  | Terminal    | | Terminal    | | - 執行記錄        |
    |   (可垂直調高)   |  +-------------+ +-------------+ |                   |
    +------------------+----------------------------------+-------------------+
    | 視窗底部狀態列 (Agent · 工具呼叫 · Context 用量 · Git 變更 · 預覽 · ⌥⌘B)|
    +-------------------------------------------------------------------------+

  關鍵決策:
    **單檔零建置依賴**：維持單一 HTML 檔案內嵌 CSS 與 JS，直接用瀏覽器或 lmux 預覽 tab 就能開，不加打包工具。
    **預設淺色、支援切換深色**：預設顯示淺色玻璃主題確認高通透層次，並保留深色主題比對暗色對比度。
    **拖曳時停用全部玻璃圖層的模糊**：拖曳調寬或調高期間，連同視窗、面板、控制列與內層卡片一併停用模糊濾鏡，避免局部元件繼續重算高斯模糊。
    **示意按鈕不做假動作**：新增 workspace、分割窗格、關閉分頁、歷史搜尋與預覽上下頁鈕只畫外觀，不實作行為。

  不在範圍內:
    正式 macOS SwiftUI／AppKit 程式改動、真實終端機 PTY 連線、本機檔案監看與 Git 指令執行。

  背景:
    假設 使用者開啟 **UI 原型**（預設為淺色玻璃主題，sidebar、**通知 bar** 與 **右側 Inspector** 皆為展開狀態）

  # --- 雙主題視覺與無障礙降級 ---

  @e2e @happy-path
  # @covered-by: App/scripts/liquid-glass-mockup-check.swift
  場景: 預設顯示淺色主題並可在淺色與深色之間切換
    那麼 **UI 原型** 套用淺色玻璃主題，且淺色主題鈕亮起
    當 使用者點深色主題鈕
    那麼 UI 原型改套用深色玻璃主題
    而且 深色主題鈕亮起、淺色主題鈕取消亮起
    當 使用者再點淺色主題鈕
    那麼 UI 原型恢復套用淺色玻璃主題

  @behavior @edge-case
  # @covered-by: App/scripts/liquid-glass-mockup-check-styles.swift
  場景: 系統開啟減少透明度時停用全部毛玻璃模糊
    假設 使用者的系統偏好設定開啟「減少透明度」
    那麼 **UI 原型** 的頂部控制列、視窗外框、標題列、sidebar、**通知 bar**、**視窗底部狀態列**、終端機窗格與 **右側 Inspector** 內層卡片皆停用毛玻璃模糊濾鏡
    而且 sidebar 與右側 Inspector 改用不透明實心底色

  @behavior @edge-case
  # @covered-by: App/scripts/liquid-glass-mockup-check-styles.swift
  場景: 系統開啟減少動態效果時縮短動畫與過渡時間
    假設 使用者的系統偏好設定開啟「減少動態效果」
    那麼 **UI 原型** 的動畫與過渡轉場時間皆縮短為近乎即時完成

  # --- 面板收合、拖曳調大小與效能守護 ---

  @e2e @happy-path
  # @covered-by: App/scripts/liquid-glass-mockup-check-panels.swift
  場景大綱: 用按鈕或快捷鍵收合與展開 sidebar 及右側 Inspector
    當 使用者透過 <操作方式> 切換 <目標面板>
    那麼 <目標面板> 收合，且 <對應標題列鈕> 取消亮起
    當 使用者再透過 <操作方式> 切換 <目標面板>
    那麼 <目標面板> 展開，且 <對應標題列鈕> 亮起

    例子:
      | 目標面板       | 操作方式                  | 對應標題列鈕   |
      | sidebar        | 標題列左側欄鈕            | 標題列左側欄鈕 |
      | sidebar        | 頂部控制列左側欄鈕        | 標題列左側欄鈕 |
      | sidebar        | 快捷鍵 ⌘B                 | 標題列左側欄鈕 |
      | 右側 Inspector | 標題列右側欄鈕            | 標題列右側欄鈕 |
      | 右側 Inspector | 頂部控制列右側欄鈕        | 標題列右側欄鈕 |
      | 右側 Inspector | 視窗底部狀態列 ⌥⌘B 鈕     | 標題列右側欄鈕 |
      | 右側 Inspector | 快捷鍵 ⌥⌘B                | 標題列右側欄鈕 |

  @e2e @happy-path
  場景: 拖曳調整面板寬度時停用全部毛玻璃模糊並在放開後恢復
    當 使用者按住並水平拖曳 sidebar 的調整手把
    那麼 **UI 原型** 進入調整尺寸狀態，包含 **右側 Inspector**、**通知 bar** 與 **視窗底部狀態列** 在內的全部毛玻璃面板與卡片皆暫停模糊濾鏡與過渡動畫
    而且 sidebar 在淺色主題拖曳期間維持淺色不透明實底，不會變成深色底
    而且 sidebar 寬度跟著滑鼠水平移動更新
    當 使用者放開滑鼠結束拖曳
    那麼 UI 原型離開調整尺寸狀態並恢復毛玻璃模糊濾鏡

  @e2e @edge-case
  場景: 水平拖曳調寬受最小與最大寬度限制
    當 使用者把 sidebar 往左拖超過最小寬度限制
    那麼 sidebar 寬度停在最小寬度下限
    當 使用者把 **右側 Inspector** 往左拖超過最大寬度限制
    那麼 右側 Inspector 寬度停在最大寬度上限

  @e2e @happy-path
  場景: 垂直拖曳調整通知 bar 高度並在拉到過低時自動收合
    當 使用者按住並往上拖曳 **通知 bar** 頂部的調整手把
    那麼 **UI 原型** 進入垂直調整尺寸狀態並停用毛玻璃模糊濾鏡
    而且 通知 bar 高度在不超過上限的範圍內跟著增加
    當 使用者把通知 bar 往下拖到收合臨界高度以下並放開
    那麼 通知 bar 自動收合，且 UI 原型恢復毛玻璃模糊濾鏡

  @e2e @edge-case
  # @covered-by: App/scripts/liquid-glass-mockup-check-panels.swift
  場景大綱: 透過摘要列、雙擊手把或頂部控制列切換通知 bar 收合與展開
    當 使用者透過 <收合操作> 切換 **通知 bar**
    那麼 通知 bar 收合（只露出 **摘要列**）
    當 使用者再透過 <展開操作> 切換通知 bar
    那麼 通知 bar 展開並回到預設高度

    例子:
      | 收合操作               | 展開操作               |
      | 點擊通知 bar 的摘要列  | 點擊通知 bar 的摘要列  |
      | 點擊通知 bar 的摘要列  | 雙擊通知 bar 調整手把  |
      | 點擊頂部控制列 Inbox 鈕 | 點擊頂部控制列 Inbox 鈕 |

  # --- Workspace 選取與通知 bar 互動 ---

  @e2e @happy-path
  場景: 點 sidebar 的 workspace 列切換選取狀態
    假設 sidebar 清單第一個 **workspace** 目前是選取狀態
    當 使用者點另一個 workspace 列
    那麼 被點擊的 workspace 列變成唯一選取狀態

  @e2e @happy-path
  場景: 點未讀通知卡片標記已讀並選取對應 workspace
    假設 **通知 bar** 有 2 張未讀的 **通知卡片**，**摘要列** 的未讀徽章顯示 2 且鈴鐺紅點可見
    當 使用者點來自 "web-client-auth" 的未讀通知卡片
    那麼 這張通知卡片變成已讀樣式
    而且 未讀徽章減為 1，鈴鐺紅點維持可見
    而且 sidebar 的 "web-client-auth" **workspace** 列變成選取狀態
    當 使用者再點另一張未讀通知卡片
    那麼 所有通知卡片皆為已讀，未讀徽章與鈴鐺紅點隱藏

  @e2e @edge-case
  場景: 點已讀通知卡片仍選取對應 workspace 且不扣減未讀數
    假設 **通知 bar** 裡來自 "lmux-glass-design" 的 **通知卡片** 是已讀狀態，且目前選取的 **workspace** 不是 "lmux-glass-design"
    當 使用者點這張已讀通知卡片
    那麼 未讀徽章數字不變
    而且 sidebar 的 "lmux-glass-design" workspace 列變成選取狀態

  # --- 右側 Inspector 與視窗底部狀態列連動 ---

  @e2e @happy-path
  場景: 在右側 Inspector 切換三個分頁、切換預覽範例檔與重新整理
    假設 **右側 Inspector** 目前停在「即時預覽」分頁
    當 使用者點即時預覽分頁裡的 Markdown 範例鈕
    那麼 預覽位址顯示 "README.md"，且預覽視口顯示 Markdown 排版示意內容
    當 使用者點即時預覽分頁裡的 Swift 範例鈕
    那麼 預覽位址顯示 "App/Sources/LmuxUI/GlassTokens.swift"，且預覽視口顯示程式碼示意內容
    當 使用者點預覽位址列的重新整理鈕
    那麼 預覽位址回到 "preview-mockup.html"，且 HTML 範例鈕重新亮起
    當 使用者點右側 Inspector 的「變更 (Diff)」分頁
    那麼 右側 Inspector 顯示 Git 變更狀態與檔案差異卡片
    當 使用者點右側 Inspector 的「執行記錄」分頁
    那麼 右側 Inspector 顯示 Context Window 用量條與最近執行的工具呼叫清單

  @e2e @happy-path
  場景大綱: 點視窗底部狀態列各區塊自動展開右側 Inspector 並切到對應分頁
    假設 **右側 Inspector** 目前是收合狀態
    當 使用者點 **視窗底部狀態列** 的 <觸發區塊>
    那麼 右側 Inspector 自動展開，且標題列右側欄鈕亮起
    而且 右側 Inspector 切到 <目標分頁> 分頁

    例子:
      | 觸發區塊            | 目標分頁    |
      | agent 模型徽章      | 執行記錄    |
      | 最近工具呼叫區塊    | 執行記錄    |
      | Context Window 區塊 | 執行記錄    |
      | Git 變更統計徽章    | 變更 (Diff) |
      | 即時預覽快捷鈕      | 即時預覽    |
