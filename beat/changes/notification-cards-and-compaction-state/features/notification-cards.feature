# language: zh-TW
功能: 通知卡片與 focused tab 反白

  通知 bar 的清單把每則通知顯示成通知卡片：任務名稱、workspace 名稱、最多兩行訊息。
  來自 focused tab 的通知卡片反白。使用者不移動滑鼠，就能看出每則通知的任務與內容，
  以及哪幾則來自目前的 tab。

  身為 同時開很多個 Claude tab 的使用者
  我想要 在通知 bar 直接看到每則通知的任務名稱與較完整的訊息，並分辨哪幾則來自目前的 tab
  以便 不用移動滑鼠、不用切換 tab，就能決定下一個要處理哪個 tab

  版面（示意）:
    ┌ 通知 bar ───────────────────────────┐
    │ plugin 列（零到多列）                │
    │ 摘要列：鈴鐺、未讀數（固定不捲動）   │
    │ ┌ 通知卡片 ─────────────────────────┐ │
    │ │ 任務名稱                   經過時間 │ │
    │ │ workspace 名稱                      │ │
    │ │ 訊息第 1 行                         │ │
    │ │ 訊息第 2 行…                        │ │
    │ └────────────────────────────────────┘ │
    │ （其餘通知卡片，可捲動）             │
    └─────────────────────────────────────┘

  卡片內容的來源:
    | 卡片上的位置   | 來源                                                                 |
    | 任務名稱       | 通知來自的 tab 目前的任務名稱                                        |
    | workspace 名稱 | workspace 的手動名稱；否則 tab 工作目錄的資料夾名稱；否則通知當時的名稱 |
    | 訊息           | Claude 最後回覆的第 1 行，去掉開頭的 Markdown 符號                    |

  關鍵決策:
    **卡片取代跑馬燈**：使用者不想移動滑鼠。卡片一次顯示任務名稱與兩行訊息，不必等文字捲動；閒置時也沒有動畫。
    **任務名稱取目前的值**：通知只記錄它來自哪個 tab。tab 之後換了 session，卡片顯示新的任務名稱。
    **不用 workspace 的自動名稱**：沒有手動名稱的 workspace，名稱就是它 focused tab 的任務名稱，會讓卡片顯示另一個 tab 的任務。
    **最新一則也用卡片**：摘要列只留鈴鐺與未讀數。通知 bar 的最小高度包含一張通知卡片，不拖拉也看得到第一張卡片。
    **反白顏色沿用 sidebar**：反白的底色與 sidebar 選取列相同，「目前的 tab」在兩處看起來一致。

  # --- 通知卡片內容 ---

  @e2e @happy-path
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 通知卡片顯示任務名稱、workspace 名稱與訊息
    假設 一個 **tab** 的工作目錄是 "~/repo/jkopay-ops-api"，它的 **workspace** 沒有手動名稱
    而且 這個 tab 的 **任務名稱** 是 "修正 integration test 失敗"
    當 這個 tab 的回合結束並送出通知
    那麼 **通知 bar** 出現一張 **通知卡片**
    而且 卡片第 1 行是 "修正 integration test 失敗" 與經過時間
    而且 卡片第 2 行是 **workspace 名稱** "jkopay-ops-api"
    而且 卡片其餘部分是 Claude 最後回覆的第 1 行，最多兩行，放不下的部分以 … 結尾

  @e2e @happy-path
  場景: workspace 有手動名稱時，第 2 行用手動名稱
    假設 一個 **tab** 的 **workspace** 手動命名為 "impl agent"
    當 這個 tab 送出通知
    那麼 這則通知的 **通知卡片** 第 2 行是 "impl agent"

  @e2e @edge-case
  場景: 卡片不顯示同一個 workspace 裡另一個 tab 的任務名稱
    假設 一個沒有手動名稱的 **workspace** 有 **tab** A 與 tab B
    而且 tab A 的 **任務名稱** 是 "任務 A"，tab B 的任務名稱是 "任務 B"
    而且 tab A 是 **focused tab**
    當 tab B 送出通知
    那麼 這則通知的 **通知卡片** 第 1 行是 "任務 B"
    而且 卡片上沒有 "任務 A"

  @e2e @edge-case
  場景: 第 2 行與第 1 行相同時不顯示
    假設 一個 **tab** 的 **任務名稱** 與它的 **workspace 名稱** 都是 "lmux"
    當 這個 tab 送出通知
    那麼 這則通知的 **通知卡片** 只顯示一次 "lmux"

  @e2e @edge-case
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 訊息開頭的 Markdown 符號不顯示
    假設 一個 **tab** 的 Claude 最後回覆的第 1 行是 "## 結論"
    當 這個 tab 送出通知
    那麼 這則通知的 **通知卡片** 的訊息是 "結論"

  @e2e @edge-case
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 沒有任務名稱時，第 1 行改用 workspace 名稱
    假設 一則通知來自一個沒有 **任務名稱** 的 **tab**
    那麼 這則通知的 **通知卡片** 第 1 行是 **workspace 名稱** 與經過時間
    而且 卡片沒有 workspace 名稱那一行

  @e2e @edge-case
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: tab 關閉後，卡片仍然顯示
    假設 一則通知來自的 **tab** 已經關閉，它的 **workspace** 還在
    那麼 這則通知的 **通知卡片** 第 1 行是 **workspace 名稱**
    而且 workspace 有手動名稱時是手動名稱，沒有時是通知當時的 workspace 名稱
    而且 卡片仍然顯示訊息

  @e2e @edge-case
  場景: workspace 也關閉後，卡片用通知當時的 workspace 名稱
    假設 一則通知來自的 **workspace** 已經關閉
    那麼 這則通知的 **通知卡片** 第 1 行是通知當時的 workspace 名稱
    而且 卡片仍然顯示訊息

  @e2e @edge-case
  場景: tab 換了 session 後，卡片顯示新的任務名稱
    假設 一則通知來自的 **tab** 之後開始了新的 session
    而且 新 session 的 **任務名稱** 是 "新任務"
    那麼 這則通知的 **通知卡片** 第 1 行是 "新任務"

  # --- 摘要列、排序與高度 ---

  @e2e @happy-path
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 通知 bar 在最小高度時也看得到最新一則未讀通知
    假設 **通知 bar** 是最小高度，而且沒有未讀通知
    當 一個不是 **focused tab** 的 **tab** 送出通知，訊息長到需要兩行
    那麼 **摘要列** 顯示鈴鐺與未讀數 1
    而且 摘要列下方完整顯示這則通知的 **通知卡片**，最後一行沒有被切掉

  @e2e @edge-case
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 清單捲動過後收到新的未讀通知，清單回到最上面
    假設 **通知 bar** 拉高到看得到 3 張以上的 **通知卡片**，而且清單往下捲動過
    當 一個不是 **focused tab** 的 **tab** 送出通知
    那麼 清單捲回最上面，第一張卡片是這則新通知
    而且 **摘要列** 一直固定在清單上方

  @e2e @edge-case
  場景: 沒有通知
    假設 lmux 沒有任何通知
    那麼 **摘要列** 顯示鈴鐺，不顯示未讀數
    而且 摘要列下方顯示 "No notifications"

  # --- focused tab 反白 ---

  @e2e @happy-path
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 只反白來自 focused tab 的通知卡片
    假設 **workspace** "api" 有 **tab** A 與 tab B，兩個 tab 都送過通知
    當 使用者 focus tab A
    那麼 來自 tab A 的 **通知卡片** 底色與 sidebar 的選取列相同
    而且 來自 tab B 的通知卡片不反白
    而且 滑鼠移到反白的卡片上時，底色不變

  @e2e @edge-case
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 同一個 tab 有多則通知時，只反白最新的一張
    假設 **focused tab** A 送過 2 則通知
    那麼 來自 tab A 的最新一張 **通知卡片** 反白
    而且 來自 tab A 的較舊那一張不反白

  @e2e @happy-path
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 換 focus 時，反白跟著移動
    假設 tab A 是 **focused tab**
    當 使用者改為 focus 另一個 workspace 的 tab C
    那麼 來自 tab C 的 **通知卡片** 反白
    而且 來自 tab A 的通知卡片不再反白

  @e2e @edge-case
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: lmux 視窗不在前景時，反白變淡
    假設 tab A 是 **focused tab**
    當 使用者切換到其他 App
    那麼 來自 tab A 的 **通知卡片** 底色與 sidebar 不在前景時的選取列相同

  @e2e @edge-case
  場景: 不是來自 tab 的通知不反白
    假設 一則通知是從 lmux 外面的終端機用 `lmux notify` 送出的
    那麼 這則通知的 **通知卡片** 不反白

  # --- 點擊 ---

  @e2e @happy-path
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 點擊通知卡片跳到它的 tab
    假設 **通知 bar** 有一張來自 **tab** A 的 **通知卡片**
    當 使用者點擊這張卡片
    那麼 tab A 成為 **focused tab**
    而且 這張卡片反白
