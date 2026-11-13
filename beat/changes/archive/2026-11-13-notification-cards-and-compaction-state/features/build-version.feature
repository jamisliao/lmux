# language: zh-TW
功能: 自己編的 lmux 顯示 build 版號

  自己編的 lmux.app 在兩個地方顯示 build 版號：選單 About lmux，以及通知 bar 的摘要列。
  版號由 git 自動產生（commit 數與 commit 短碼），不用手動改。
  使用者同時開正式版與多個測試版時，看版號就知道這是哪一次 build。

  身為 同時開正式版與好幾個自己編的測試版的使用者
  我想要 在視窗裡看到這一份 lmux 是哪一次 build 的
  以便 我知道它有沒有我要測的功能，也不會把正式版和測試版搞混

  版號格式:
    `<commit 數>-<commit 短碼>`，例如 `27-c4573d7`。
    工作目錄有尚未提交的改動時，結尾加 `-dirty`。
    不在 git 底下（例如解壓縮的原始碼）時是 `1`（與原本寫死的值相同）。

  關鍵決策:
    **版號由 git 產生，不手動維護**：手動改版號一定會忘記，而且和實際的 commit 對不起來。
    **用 CFBundleVersion，不動 CFBundleShortVersionString**：About 視窗會顯示「Version 0.0.1 (27-c4573d7)」，上游的版本號不變，發佈流程（release/package.sh）也不受影響。
    **通知 bar 顯示同一個版號**：通知 bar 是這個 fork 才有的，正式版沒有，所以看到它就知道是自己編的版本。

  # --- 版號的產生 ---

  @behavior @happy-path
  # @covered-by: App/scripts/build-id-check.sh
  場景: build 版號是 commit 數加 commit 短碼
    假設 一個 git 專案有 3 個 commit，工作目錄沒有未提交的改動
    當 產生 build 版號
    那麼 版號是 "3-" 加上最新 commit 的短碼

  @behavior @edge-case
  # @covered-by: App/scripts/build-id-check.sh
  場景: 有未提交的改動時，版號結尾加 -dirty
    假設 一個 git 專案的工作目錄有尚未提交的改動
    當 產生 build 版號
    那麼 版號結尾是 "-dirty"

  @behavior @edge-case
  # @covered-by: App/scripts/build-id-check.sh
  場景: 不在 git 底下時，版號是 1
    假設 一個資料夾不在任何 git 專案底下
    當 產生 build 版號
    那麼 版號是 "1"

  # --- 顯示 ---

  @e2e @happy-path
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: About 視窗顯示 build 版號
    假設 一個自己編的 lmux.app 已經啟動
    當 使用者開啟選單 lmux → About lmux
    那麼 視窗顯示的版本包含這一次 build 的版號

  @e2e @happy-path
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: 通知 bar 的摘要列顯示同一個 build 版號
    假設 一個自己編的 lmux.app 已經啟動
    那麼 **通知 bar** 的 **摘要列** 右邊用小字顯示這一次 build 的版號
    而且 它和 About 視窗顯示的版號相同

  @e2e @edge-case
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
  場景: sidebar 很窄時，版號先被截斷，未讀數不受影響
    假設 **通知 bar** 有未讀通知
    當 使用者把 sidebar 拉到最窄
    那麼 **摘要列** 的未讀數仍然完整顯示
    而且 版號被截斷或隱藏
