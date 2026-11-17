# language: zh-TW
功能: 側邊欄樹狀展開與切換 Workspace 的 Tab

  在左側 sidebar 中，當 workspace 擁有多個 tab 時，左側顯示展開箭頭。
  使用者點擊展開箭頭可展開或收合 Tab 子列，並可直接點選各個 Tab 子列切換焦點。

  身為 同時在多個 workspace 進行多項任務的使用者
  我想要 在 sidebar 展開 workspace 查看它底下的所有 tab
  以便 一眼掌握所有任務的分佈與狀態，並能直接點擊目標 tab 一步切換

  關鍵決策:
    **漸進折疊（手動箭頭）**：只有分頁數 >= 2 時顯示展開箭頭；單一分頁不顯示箭頭，保持介面簡潔。
    **扁平列出所有 Tab**：不管該 workspace 內部是否有分割（Split），一律扁平列出所有 Tab，點擊直接切換並聚焦該 tab。
    **雙軌並存**：右側窗格頂端的水平分頁列完全保留，不改變既有快速切換與分割習慣。
    **狀態記憶**：展開與收合狀態被記錄，重開 app 後保留。

  # --- 展開與收合 ---

  @happy-path
  場景: 多個 tab 的 workspace 顯示展開箭頭並可展開與收合
    假設 一個 **workspace** 擁有 2 個以上的 **tab**
    那麼 該 workspace 在 sidebar 的列首顯示 **展開箭頭**
    當 使用者點擊 **展開箭頭**
    那麼 該 workspace 下方展開顯示其 **Tab 子列** 列表
    當 使用者再次點擊 **展開箭頭**
    那麼 該 workspace 下方的 **Tab 子列** 列表收合隱藏

  @edge-case
  場景: 單一 tab 的 workspace 不顯示展開箭頭
    假設 一個 **workspace** 只有 1 個 **tab**
    那麼 該 workspace 在 sidebar 的列首不顯示 **展開箭頭**

  # --- 點擊與導覽 ---

  @happy-path
  場景: 點擊 Tab 子列直接切換 workspace 並聚焦該 tab
    假設 一個未選取的 **workspace** A 處於展開狀態，且包含 **tab** T1 與 **tab** T2
    當 使用者在 sidebar 點擊 T2 的 **Tab 子列**
    那麼 A 成為被選取的 **workspace**
    而且 T2 成為 **focused tab**
    而且 T2 的 **Tab 子列** 顯示為焦點狀態

  # --- 圖示與狀態 ---

  @happy-path
  場景: Tab 子列獨立顯示類型圖示與 agent 狀態
    假設 一個 **workspace** 展開顯示其 **Tab 子列**
    而且 該 workspace 包含一個正在進行中的 **終端機 tab**，與一個已完成的 **終端機 tab**，以及一個 **預覽 tab**
    那麼 終端機 tab 的 **Tab 子列** 顯示終端機類型圖示
    而且 正在進行中的終端機 tab 顯示進行中 spinner
    而且 已完成的終端機 tab 顯示完成標記
    而且 預覽 tab 顯示文件類型圖示

  # --- 關閉與生命週期 ---

  @edge-case
  場景: 從 Tab 子列關閉 tab
    假設 一個 **workspace** 擁有 2 個 **tab**，且處於展開狀態
    當 使用者將滑鼠移至其中一個 **Tab 子列** 並點擊關閉按鈕
    那麼 該 tab 被關閉
    而且 該 workspace 剩餘 1 個 tab，其 **展開箭頭** 自動隱藏

  @edge-case
  場景: 重新啟動後保留展開狀態
    假設 使用者展開了 **workspace** A，且收合了 **workspace** B
    當 lmux 重新啟動後
    那麼 A 保持展開狀態，且 B 保持收合狀態
