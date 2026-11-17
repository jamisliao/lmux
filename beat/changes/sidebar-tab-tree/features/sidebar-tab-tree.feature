# language: zh-TW
功能: 在 sidebar 展開 workspace 的 tab

  workspace 有 2 個以上的 tab 時，sidebar 的 workspace 列出現展開箭頭。
  展開後，每個 tab 在 workspace 列下方有一列 Tab 子列，顯示它的類型、標題與 agent 狀態。
  點 Tab 子列就切換到那個 tab。終端機區域上方的 tab 列照舊。

  身為 同時在多個 workspace 各開幾個 tab 的使用者
  我想要 在 sidebar 展開 workspace，看到它的每個 tab 與各自的狀態
  以便 不必先切換 workspace，就知道哪個 tab 在等我，並且點一下就過去

  關鍵決策:
    **只有兩層**：workspace 底下直接列出所有 tab，分割出來的 tab 也在同一層。使用者 2026-11-17 選擇不依分割分組。
    **預設收合**：沒點展開箭頭時，sidebar 的長度跟現在一樣。使用者 2026-11-17 決定。
    **展開狀態跟著 workspace**：每個 workspace 各自記住，重開 lmux 後維持；tab 數掉到 1 個再回來也維持。使用者 2026-11-17 決定。
    **workspace 列不變**：展開時照常顯示整體狀態，展開與收合看到的 workspace 列一樣。使用者 2026-11-17 決定。
    **關閉規則與 tab 列相同**：釘選的 tab 不能關；還有程式在跑的終端機 tab 先詢問。同一個 tab 從兩個地方關，結果要一樣。
    **tab 列保留**：Tab 子列用來看全貌與跨 workspace 切換；⌘T、⌘W、拖曳與分割仍在 tab 列。

  不在範圍內:
    Tab 子列的右鍵選單、雙擊重新命名、拖曳排序，以及用鍵盤展開或收合。

  # --- 展開與收合 ---

  @e2e @happy-path
  場景: 有多個 tab 的 workspace 可以展開與收合
    假設 一個 **workspace** 有 3 個 **tab**
    那麼 它的 workspace 列有 **展開箭頭**
    當 使用者點 **展開箭頭**
    那麼 workspace 列下方出現 3 列 **Tab 子列**
    當 使用者再點一次 **展開箭頭**
    那麼 這 3 列 **Tab 子列** 消失

  @e2e @edge-case
  場景: 只有 1 個 tab 的 workspace 沒有展開箭頭
    假設 一個 **workspace** 只有 1 個 **tab**
    那麼 它的 workspace 列沒有 **展開箭頭**
    而且 它的下方沒有 **Tab 子列**

  @e2e @edge-case
  場景: 開出第 2 個 tab 時預設收合
    假設 一個 **workspace** 只有 1 個 **tab**，而且使用者沒有展開過它
    當 使用者在這個 workspace 開第 2 個 **tab**
    那麼 它的 workspace 列出現 **展開箭頭**
    而且 它的下方沒有 **Tab 子列**

  @e2e @edge-case
  場景: 點展開箭頭不切換 workspace
    假設 **workspace** A 是選取中的 workspace
    而且 **workspace** B 有 2 個 **tab**，而且是收合的
    當 使用者點 B 的 **展開箭頭**
    那麼 B 的下方出現 **Tab 子列**
    而且 A 仍然是選取中的 workspace

  # --- 展開狀態的保存 ---

  @e2e @happy-path
  場景: 重開 lmux 後維持展開狀態
    假設 **workspace** A 與 **workspace** B 各有 2 個 **終端機 tab**
    而且 使用者展開了 A，B 維持收合
    當 使用者重開 lmux
    那麼 A 是展開的
    而且 B 是收合的

  @e2e @edge-case
  場景: tab 數回到 2 個以上時回到原本的展開狀態
    假設 一個展開的 **workspace** 有 2 個 **tab**
    當 使用者關閉其中 1 個 **tab**
    那麼 它的 **展開箭頭** 與 **Tab 子列** 都消失
    當 使用者在這個 workspace 再開 1 個 **tab**
    那麼 它的 **展開箭頭** 出現
    而且 它的下方有 2 列 **Tab 子列**

  # --- Tab 子列的內容 ---

  @e2e @happy-path
  場景: 分割出來的 tab 也列在同一層
    假設 一個 **workspace** 分割成左右兩格，左邊那格有 2 個 **tab**，右邊那格有 1 個 **tab**
    當 使用者展開這個 workspace
    那麼 它的下方有 3 列 **Tab 子列**
    而且 順序是左邊那格的 2 個 tab（依 **tab 列** 的順序），然後是右邊那格的 tab

  @e2e @happy-path
  場景: Tab 子列顯示 tab 的類型與標題
    假設 一個展開的 **workspace** 有一個 **任務名稱** 是 "fix login" 的 **終端機 tab**
    而且 它還有一個顯示 "design.md" 的 **預覽 tab**
    那麼 終端機 tab 的 **Tab 子列** 顯示終端機圖示與 "fix login"
    而且 預覽 tab 的 **Tab 子列** 顯示文件圖示與 "design.md"

  @e2e @happy-path
  場景大綱: Tab 子列顯示該 tab 自己的 agent 狀態
    假設 一個展開的 **workspace** 有 2 個 **終端機 tab**，其中 T 是 <狀態>，另一個是 **閒置**
    那麼 T 的 **Tab 子列** 顯示<圖示>
    而且 另一個 tab 的 **Tab 子列** 沒有狀態圖示

    例子:
      | 狀態         | 圖示           |
      | **進行中**   | 轉圈圖示       |
      | **完成**     | ✓              |
      | **等待回應** | 等待回應的標記 |

  @e2e @edge-case
  場景: 預覽 tab 的 Tab 子列沒有狀態圖示
    假設 一個展開的 **workspace** 有一個 **進行中** 的 **終端機 tab** 與一個 **預覽 tab**
    那麼 預覽 tab 的 **Tab 子列** 沒有狀態圖示

  @e2e @edge-case
  場景: 展開時 workspace 列照常顯示整體狀態
    假設 一個收合的 **workspace** 有一個 **進行中** 的 **終端機 tab**
    而且 它的 workspace 列顯示轉圈圖示
    當 使用者展開這個 workspace
    那麼 它的 workspace 列仍然顯示轉圈圖示

  # --- 切換 tab ---

  @e2e @happy-path
  場景: 點 Tab 子列切換到另一個 workspace 的 tab
    假設 **workspace** A 是選取中的 workspace
    而且 **workspace** B 是展開的，有 **tab** T1 與 T2，T1 顯示在最前面
    當 使用者點 T2 的 **Tab 子列**
    那麼 B 成為選取中的 workspace
    而且 T2 顯示在它那一格的最前面，並成為 **focused tab**

  @e2e @happy-path
  場景: 只有 focused tab 的 Tab 子列有標示
    假設 **workspace** A 與 **workspace** B 都是展開的，各有 2 個 **tab**
    而且 A 是選取中的 workspace，它的 **focused tab** 是 T1
    那麼 T1 的 **Tab 子列** 有標示
    而且 A 的另一列 **Tab 子列** 沒有標示
    而且 B 的 **Tab 子列** 都沒有標示

  # --- 從 Tab 子列關閉 tab ---

  @e2e @happy-path
  場景: 從 Tab 子列關閉 tab
    假設 一個展開的 **workspace** 有 3 個 **閒置** 的 **終端機 tab**
    當 使用者把滑鼠移到其中一列 **Tab 子列**，點它的關閉按鈕
    那麼 這個 tab 關閉
    而且 這個 workspace 的下方剩 2 列 **Tab 子列**

  @e2e @edge-case
  場景: 釘選的 tab 的 Tab 子列沒有關閉按鈕
    假設 一個展開的 **workspace** 有一個 **釘選的 tab**
    當 使用者把滑鼠移到它的 **Tab 子列**
    那麼 這列沒有關閉按鈕

  @e2e @edge-case
  場景: 關閉還有程式在跑的終端機 tab 會先詢問
    假設 **workspace** A 是選取中的 workspace
    而且 **workspace** B 是展開的，它的 **終端機 tab** T 還有程式在跑
    當 使用者點 T 的 **Tab 子列** 的關閉按鈕
    那麼 B 成為選取中的 workspace，T 成為 **focused tab**
    而且 T 上出現是否關閉的詢問
    而且 T 還沒關閉

  # --- 拖曳排序 ---

  @e2e @edge-case
  場景: 拖曳已展開的 workspace 時 Tab 子列跟著移動
    假設 sidebar 由上而下是 **workspace** A、B、C，A 是展開的，有 2 個 **tab**
    當 使用者把 A 的 workspace 列拖到 C 的下方
    那麼 sidebar 由上而下是 B、C、A
    而且 A 的 2 列 **Tab 子列** 仍然在 A 的 workspace 列下方

  @e2e @edge-case
  場景: 拖 Tab 子列不會移動 workspace
    假設 sidebar 由上而下是 **workspace** A、B，A 是展開的
    當 使用者按住 A 的一列 **Tab 子列** 往下拖
    那麼 sidebar 由上而下仍然是 A、B
