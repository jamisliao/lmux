# language: zh-TW
功能: 右側 Inspector 原生問答面板與零 Token Session 上下文補充

  透過 `lmux ask` CLI 在 **右側 Inspector** 以純原生 SwiftUI 呈現多題結構化問答，並直接分析來源
  **終端機 tab** 的對話紀錄、工具呼叫與工作區異動，以零額外 LLM Token 自動產生 **Session 上下文補充**，
  讓使用者從別的工作區切回來時也能立刻掌握前後文並完成決策。

  身為 同時管理多個 Claude Code 與 Codex **workspace** 的開發者
  我想要 在不跳出終端機、不消耗 HTML 輸出 Token 的前提下，於 **右側 Inspector** 看到附帶 session 脈絡與程式碼差異的原生問答表單
  以便 快速理解 Agent 為什麼發問、確認影響範圍並一鍵送出決策

  架構流程:
    Claude / Codex / ask-me ──(ask-create + ask-wait RPC)──▶ ControlServer (Unix Socket + Nonce 驗權)
                                                                    │
                                                                    ▼
                                                            AskSessionStore (per-Tab FIFO)
                                                             ├──▶ Transcript + ToolStream + Git ──▶ Session 上下文補充 (0 Token)
                                                             ├──▶ AskRefLoader (O_NOFOLLOW + 安全 Git Diff)
                                                             └──▶ 注意力連動 (優先需確認狀態 + 通知卡片 + lmux wait)
                                                                    │
                                                                    ▼
                                                       右側 Inspector「待確認面板」(純 SwiftUI + 焦點/快捷鍵防護)
                                                                    │ (全題作答後送出 / 取消)
                                                                    ▼
                                                       Stdout JSON 回到授權的呼叫端 CLI

  關鍵設計決策:
    **零 HTML 純原生 SwiftUI**：表單、分段 Markdown、紅綠 Diff 與本機檔案引用全部以原生元件呈現，完全不建立 `WKWebView`；遇 `mermaid` 欄位以可折疊等寬程式碼卡呈現並提供複製語法操作，避免啟動網頁引擎或覆蓋使用者原本的即時預覽檔案。
    **本機零 Token 抽取上下文**：lmux 直接利用既有增量解析的對話紀錄（含 Claude 與 Codex）與工具串流組出 **Session 上下文補充**，避免模型耗費大量輸出 Token 重複敘述歷史進度。
    **兩階段單行 RPC 與嚴格租戶隔離**：拆為建立與等待兩次單行請求以契合既有 Socket 協定，並驗證來源 **終端機 tab** 憑證，防止跨分頁偽造提問、越權讀檔或竊取回覆。
    **動態頁籤與焦點安全防護**：**待確認面板** 僅於 **focused tab** 有未完成 **問答工作階段** 時出現；自由輸入框支援標準文字復原而不誤觸對話回溯，且面板可見時的送出快捷鍵絕不漏進終端機。

  背景:
    假設 lmux 應用程式已啟動並監聽控制 socket，且存在一個作用中的 **workspace** 與 **終端機 tab**

  # ===========================================================================
  # 1. 零 Token Session 上下文補充抽取
  # ===========================================================================

  @behavior @happy-path
  # @covered-by: Core/Tests/LmuxTranscriptTests/TranscriptContextExtractorTests.swift
  場景: 從 Claude 與 Codex 對話紀錄本機抽取 Session 上下文補充
    假設 來源 **終端機 tab** 具有多輪 Claude Code 或 Codex 對話紀錄、已修改檔案紀錄與近期工具呼叫
    當 該 tab 發起新的 **問答工作階段**
    那麼 系統應在零額外 LLM 呼叫下自動產生 **Session 上下文補充**
    而且 內容應包含任務標題或起點目標、最近數輪問答重點、已異動或新建檔案清單與屬於該 tab 工作目錄的近期工具及 Git 狀態

  @behavior @edge-case
  # @covered-by: Core/Tests/LmuxTranscriptTests/TranscriptContextExtractorTests.swift
  場景: 對話紀錄缺少、含損毀行或合成佔位訊息時安全降級產生上下文補充
    假設 來源 **終端機 tab** 沒有對話紀錄檔，或紀錄檔包含不完整 JSON 行與合成佔位訊息
    當 系統為該 **問答工作階段** 抽取 **Session 上下文補充**
    那麼 系統應略過合成佔位訊息與損毀行，保留可用的工作區或工具訊號，不應崩潰或阻擋提問顯示

  # ===========================================================================
  # 2. lmux ask CLI 提問、逾時續等、規格檢核與權限隔離
  # ===========================================================================

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/InspectorAskTests.swift
  場景: 透過 lmux ask 發起多題提問並在全題作答送出後回傳完整答案
    假設 來源 **終端機 tab** 透過 `lmux ask` 提交包含前情提要、單選題（含字串簡寫或推薦標記）、多選題與開放題的規格檔
    當 **右側 Inspector** 展開 **待確認面板** 且尚有題目未作答時送出操作應維持停用且快捷鍵不漏入終端機
    當 使用者完成所有題目的選項勾選或自由補充文字並送出
    那麼 `lmux ask` 應於標準輸出印出已送出狀態、正規化後的選取標籤陣列與補充文字並以零結束碼離開
    而且 **待確認面板** 應自動隱藏並還原送出前的檢視分頁，鍵盤焦點回到終端機

  @e2e @edge-case
  # @covered-by: App/Sources/lmux-apptest/InspectorAskTests.swift
  場景: 提問等待逾時時保留表單，後續透過授權的 wait 領取結果
    假設 來源 **終端機 tab** 發起 **問答工作階段** 且指定短暫等待時間
    當 等待時間屆滿而使用者尚未送出
    那麼 `lmux ask` 應印出待處理狀態、工作階段識別碼與續等指令並正常結束，且 **待確認面板** 仍維持開啟不丟失
    當 使用者隨後在 **待確認面板** 送出答案，且同一授權來源以該識別碼執行續等指令
    那麼 續等指令應立即取得該次送出的完整答案，不應開啟第二份重複表單

  @e2e @error-handling
  # @covered-by: App/Sources/lmux-apptest/InspectorAskTests.swift
  場景: 使用者取消、來源 tab 關閉、規格不合法或跨分頁未授權呼叫時妥善處理
    假設 一個 **終端機 tab** 正在等待 **問答工作階段** 回覆
    當 使用者在 **待確認面板** 點選取消，或關閉該來源 **終端機 tab**
    那麼 等待中的 `lmux ask` 應立即解除阻塞並印出對應的取消（附提示說明）或遺失狀態
    當 呼叫端傳入重複題目識別碼、重複選項、缺少必要說明或損毀的規格檔，或未經授權嘗試指定其他分頁及領取他人答案
    那麼 `lmux ask` 應拒絕執行並回報清楚錯誤訊息、以非零結束碼離開，不建立或洩漏工作階段

  # ===========================================================================
  # 3. 純原生 SwiftUI 渲染、輸入框編輯快捷鍵與本機引用安全邊界
  # ===========================================================================

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/InspectorAskTests.swift
  場景: 待確認面板以原生元件呈現分段 Markdown、Diff、本機引用與 Mermaid 程式碼卡
    假設 一個 **問答工作階段** 包含多段 Markdown 與清單說明、diff 程式碼區塊、本機檔案行號引用、Git Diff 引用與 Mermaid 語法
    當 **右側 Inspector** 渲染 **待確認面板**
    那麼 面板應在不建立內嵌網頁檢視的前提下，保留段落與清單結構原生顯示 **Session 上下文補充**、紅綠差異行與本機程式碼片段
    而且 Mermaid 區塊應顯示為可折疊等寬程式碼卡並提供複製語法操作，不覆蓋「即時預覽」原有檔案
    而且 在自由輸入欄編輯文字時執行復原操作應復原輸入文字，不應誤觸終端機對話回溯

  @behavior @error-handling
  # @covered-by: App/Sources/lmux-apptest/InspectorAskTests.swift
  場景: 本機檔案與 Git 引用越界、指向危險／二進位檔案或新倉庫未追蹤檔時安全處理
    假設 提問規格中的本機引用包含上層目錄遍歷、指向工作區外的符號連結、特殊裝置檔、二進位檔，或位於無初始提交倉庫的新增未追蹤檔
    當 系統解析該題的本機檔案引用與 Git Diff 引用
    那麼 越界、符號連結逃逸與非純文字檔案應被拒絕讀取並顯示安全降級提示，且絕不執行儲存庫內的自訂 Git 過濾器指令
    而且 位於工作區內的未追蹤純文字新檔仍應正確顯示新增內容差異

  # ===========================================================================
  # 4. 多工作區注意力連動與切換隔離
  # ===========================================================================

  @e2e @happy-path
  # @covered-by: App/Sources/lmux-apptest/InspectorAskTests.swift
  場景: 背景執行中的 workspace 提問時優先顯示需確認並發送通知卡片，點擊後切入待確認面板
    假設 使用者目前檢視 **workspace** A，而背景 **workspace** B 正在執行代理人的 **終端機 tab** 發起 **問答工作階段**
    當 提問建立完成
    那麼 使用者目前的畫面與焦點應維持在 **workspace** A 不被強行打斷
    而且 **workspace** B 與該分頁應由執行中轉為顯示需要確認狀態，喚醒等待需確認狀態的監聽指令，並於 **通知 bar** 新增對應的 **通知卡片**
    當 使用者點擊該 **通知卡片** 或切換至該分頁
    那麼 視窗應聚焦 **workspace** B 的該來源 **終端機 tab**，並自動展開 **右側 Inspector** 顯示其 **待確認面板**

  @e2e @edge-case
  # @covered-by: App/Sources/lmux-apptest/InspectorAskTests.swift
  場景: 多個 tab 各自擁有獨立問答工作階段且切換分頁或縮放視窗時同步隔離與歸還焦點
    假設 **終端機 tab** A 與 **終端機 tab** B 各自有未完成的 **問答工作階段**，且 **終端機 tab** C 沒有待答提問
    當 使用者在 tab A、tab B 與 tab C 之間切換 **focused tab**
    那麼 **右側 Inspector** 應分別呈現 tab A 與 tab B 各自獨立的作答草稿與題目內容
    而且 切至 tab C 時應隱藏 **待確認面板** 頁籤、退回一般檢視分頁並將鍵盤焦點歸還給終端機
