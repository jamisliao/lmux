---
change: preview-liquid-glass
date: 2026-11-20
sha: 8301a5b
mode: incremental
round: 5
base: f93ae7b
findings:
  - { id: F1, severity: CRITICAL, dimension: 1B, scenario: "按住 ⌃⌘ 點擊可預覽檔案直接開成預覽 tab", file: "App/Sources/LmuxUI/OpenMenu.swift:33", fix: "Ghostty 只在修飾鍵恰為 ⌘ 時偵測連結（vendor/ghostty/src/Surface.zig:4490、4535），⌃⌘ 分支在正式路徑走不到；改成在 SurfaceView 自行處理 ⌃⌘，或從規格、design Key Decision 1、ADR 0002 移除此捷徑，並補走真實滑鼠事件的測試、更正 manual-verification.md:45", status: fixed }
  - { id: F2, severity: CRITICAL, dimension: 4, scenario: "左側 workspace 卡片顯示彩色識別條與狀態藥丸並保留多選與排序", file: "App/Sources/LmuxUI/SidebarSelection.swift:16", fix: "⇧-click 範圍選取改用 model.filteredWorkspaces 計算，或切換篩選時清除多選，並補「篩選中範圍選取不含隱藏列」的 apptest", status: fixed }
  - { id: F3, severity: CRITICAL, dimension: 4, scenario: "Git Diff 服務讀取工作區變更統計與檔案 hunks，非 Git 目錄呈現空狀態", file: "App/Sources/LmuxUI/GitDiffService.swift:79", fix: "全域選項 --attr-source 只有較新的 git 認得，舊版 /usr/bin/git 會讓 numstat、diff、status 與 --cached 備援全部失敗而顯示乾淨工作樹；失敗時改成不帶此選項重跑或改用環境變數，空 tree hash 改用 git hash-object 取得，並補舊版 git 備援的測試", status: open }
---

# Verify Report — preview-liquid-glass

結論：1 個 CRITICAL（F3）未解決，不可 archive。修之前先人工 review `8301a5b`（見 Divergence），再跑 `/beat:apply preview-liquid-glass fix-from-verify`。

## 本次執行

| 項目 | 內容 |
|---|---|
| 模式 | incremental：上一輪 sha `f93ae7b` 是 HEAD `8301a5b` 的祖先（`git merge-base --is-ancestor` 成立） |
| 輪次 | 5。套用 round cap：只記錄 CRITICAL 與舊 finding 的複查 |
| 強度 | standard（status.yaml 沒有 `preset`）：兩個 subagent 平行執行 |
| 範圍 | `f93ae7b..8301a5b`：1 個 commit、38 個檔案；依 `@covered-by` 對到 24 個相關場景 |
| 沒重讀 | `liquid-glass-redesign-mockup.feature` 的 13 個場景（`@covered-by` 目標不在 diff 內） |

## 舊 finding 複查

| id | 結果 | 依據（兩個 subagent 各自確認） |
|---|---|---|
| F1 | fixed | ⌃⌘ 分支、`clickModifiersOverride`、場景、測試都已移除；design、ADR 0002、manual-verification、`beat/features/preview/README.md` 已同步。只剩 `tasks.md:742-757` 還寫著舊內容（SUGGESTION，未記錄） |
| F2 | fixed | `SidebarSelection.swift:14` 改用 `filteredWorkspaces`；`Model.swift:793` 切換篩選時清除多選；`LiquidGlass.swift:358-380` 有 apptest，先斷言兩端之間確實有隱藏列 |

## CRITICAL

### F3 舊版 git 不認得 `--attr-source`，Diff 分頁會顯示「乾淨」且沒有錯誤訊息（Dimension 4）

- 位置：`App/Sources/LmuxUI/GitDiffService.swift:79`（`diffGlobalArgs`）。numstat、diff、status 都帶它，`--cached` 備援也帶同一個參數。
- 來源：`8301a5b` 新增（`git diff f93ae7b..HEAD -- GitDiffService.swift` 有 `+ let diffGlobalArgs = ["--attr-source=..."]`）。
- 失敗流程（subagent 讀程式碼得出，未實際執行）：
  - git 遇到不認得的全域選項會以 exit 129 結束。
  - `rev-parse` 沒帶這個選項，所以 `isGitRepo == true`、有分支名稱。
  - `buildSnapshot` 拿到空輸出：Diff 分頁和底部狀態列顯示 0 個變更檔案。
  - SHA-256 repo 的空 tree hash 不是 `4b825dc…`，結果相同。
- 版本前提：
  - 專案最低支援 macOS 14（`App/Package.swift:24`），程式寫死 `/usr/bin/git`（`design.md:51`）。
  - `--attr-source` 加入的版本：WebSearch 摘要指向 RelNotes 2.41.0（verification subagent 寫 2.40）。RelNotes 原文未讀。
  - macOS 14 上 Apple Git 的實際版本：未查證（verification subagent 說是 2.39.x）。
  - 本機是 git 2.54.0（Apple Git-157），所以本機測試重現不了。
- 分級：verification subagent 判 CRITICAL，code-reviewer 判 WARNING。依規則 CRITICAL 不降級，記為 CRITICAL。
- 修正方向：
  - exit 129 時不帶這個選項重跑，或改用環境變數。
  - 空 tree hash 改用 `git hash-object -t tree /dev/null` 取得。
  - 補「舊版 git 備援」測試；在 `design.md:51` 記下 git 版本要求。

## Divergence

- open 數：本輪 CRITICAL 1，上一輪 2，沒有變多。
- 但上一個修正 commit `8301a5b` 改過的檔案裡出現至少 3 個新 finding，舊 finding 都沒有復發，依規則判定 **diverging=yes**：
  - `GitDiffService.swift`：F3；另有 filter 覆寫沒涵蓋 `config.worktree` 與 `info/attributes`（未記錄）。
  - `LiquidGlassTelemetryTests.swift:386-391`：新的 codex `resetToolStream` 測試沒走到 `Agent.swift:182-186`，拿掉新程式也會綠燈（未記錄）。
  - `InspectorPreviewPane.swift:33-35`：預覽檔被刪後切換 workspace，右側欄仍顯示上一個 workspace 的預覽（未記錄）。
  - `beat/features/preview/open-menu.feature`：`.orig` 被改名回 living 檔，等於在 archive 前就先同步（未記錄；validate-beat error）。
- 建議：下一輪 fix 前，人工 review `8301a5b`，重點是 GitDiffService 的強化與 `.orig` 改名。

## 未記錄（第 5 輪只計數）

+14 warnings not recorded（round 5）、+11 suggestions not recorded（round 5）。兩份報告重複的項目已合併計算一次。

- 14 個 WARNING 中，10 個是第 4 輪已計數的 lint 項目：缺 user story 2、`@covered-by` 指向非測試檔 7、缺 `preset` 1。
- 其餘 4 個來自這次 diff，列在 Divergence。

## Round cap

第 5 輪還出現 CRITICAL，代表這個 change 範圍太大。F3 修完後，後續工作建議拆成較小的 change。

## Shared files

這次 diff 動到多個場景共用的檔案：`Controller.swift`、`Tabs.swift`、`Model.swift`、`Tokens.swift`、`RootView.swift`。要不要跑 `/beat:verify preview-liquid-glass full` 由使用者決定；archive 不要求。

## Lint（step 2b）

- `validate-beat.mjs --change preview-liquid-glass`：exit 1，2 error、1 warning。
  - error：`gherkin.modified` 列了 `beat/features/preview/open-menu.feature`，但 `.orig` 不存在（`8301a5b` 把 `.orig` 改名回 living 檔）。
  - error：`verification.critical` 是 2，verify.md 只有 1 個 open（本次寫入後解除）。
  - warning：缺 `preset`。
- `lint-features.mjs --require-covered-by`（本 change 3 個 feature）：exit 1，2 error（user story；subagent 判斷是 linter 不認得「身為／我想要／以便」）、7 warning（`@covered-by` 指向非測試檔）。

## Testing Context

- Drive mode：gherkin-driven；testing.required 未設定，視為 required；source：normal。
- 37 個場景：@e2e 30、@behavior 7。
- Modified files：`beat/features/preview/open-menu.feature`。`.orig` 已不在，改用 `git show f93ae7b:beat/features/preview/open-menu.feature.orig` 比對。語意差異（新增「在右側欄即時預覽」、刪除 ⌃⌘ 場景）與 `PreviewInteractions.swift` 的斷言一致。
- **自動化測試（step 4）未執行**：`swift test --package-path Core` 被權限規則拒絕。需要使用者自己跑：
  - `export PATH="/usr/bin:$PATH"; swift test --package-path Core`
  - `export PATH="$HOME/.local/share/lmux-dev/bin:/usr/bin:$PATH"; beat/changes/preview-liquid-glass/dev.sh check`
  - 有失敗時，每個失敗的測試都要補記為 CRITICAL。

## Final Assessment

1 critical issue(s) found. Fix before archiving.

---

## Test Trust Audit 補充驗證（2026-11-21 工作樹，未重跑 Beat Round 6）

> 本節記錄針對 uncommitted 工作樹進行的 Swift Test Trust Audit（弱斷言掃描＋隔離沙盒 Diff 突變驗證）結果，不更動上方 Beat Round 5 Frontmatter。

### 補強的測試與非空轉斷言

- `Core/Tests/LmuxHooksTests/ToolCallStreamTests.swift:36-77`：
  - 設定固定 `sentAtNanos` 驗證 `Interrupt`（`durationMs == 75`）與 `MainStop`（`durationMs == 250`），殺死 `ToolCallStream.swift:124` 的 `/ 1_000_000` 單位突變。
  - 新增 `fallbackBash` 與 `fallbackOther` 後接無 ID 的 `PostToolUse("Bash")`，驗證僅完成名稱相符的 running entry（`fbBashEntry?.status == .succeeded`、`durationMs == 300`、`fbOtherEntry?.status == .running`），殺死 `ToolCallStream.swift:105` 的 `&& -> ||` 突變。
- `Core/Tests/LmuxTranscriptTests/AgentTelemetryTests.swift:124-137`：
  - 新增 `tokZeroWindow`（`model_context_window: 0`），驗證增量 `rollout.update()` 與靜態 `CodexRollout.parse` 皆保留先前 `contextLimitTokens == 200_000`，殺死 `CodexRollout.swift:305` 的 `limit > 0 -> limit >= 0` 突變。
- `App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift:830-947`：
  - 新增同前綴兄弟目錄 `unbornSiblingEvil` 與 `siblingSymlink`，驗證 `!GitDiffService.isPathContained(siblingSecret, inDirectory: unbornRepo.path)` 且 `readUntrackedLines` 回空，殺死 `GitDiffService.swift:29` 缺少尾斜線（`dirURL.path + "/"` -> `dirURL.path`）突變。
  - 改以 `fifoHoldFd`（`O_RDONLY | O_NONBLOCK`）搭配 `fifoWriterFd` 寫入 `"fifo-leak\n"` 後關閉寫端製造乾淨 EOF（避免先前 `O_RDWR` 因 `EAGAIN` 被 `try? fh.read` 吞掉），殺死 `GitDiffService.swift:345` 的 `S_IFREG` 防護繞過突變。
  - 新增 `buildBoundaryConfigPayload`（17 個 key，512 KiB vs `+1` byte），驗證剛好 `GitDiffService.maxFilterEnvBytes` 成功且 `+1` byte 於 `hash-object`/`diff`/`status` 前 fail-closed，殺死 `GitDiffService.swift:200` 的 `<= -> <` 與放寬上限突變。

### 突變測試統計（`/tmp/lmux-mut-audit` 隔離沙盒，驗證後已移除）

| 目標範圍 | 補強前 | 補強後 | 備註 |
|---|---|---|---|
| `Core/` diff 突變（`swift_mutate_diff.py core`） | `39 KILLED / 10 SURVIVED`（49 項） | **`40 KILLED / 6 SURVIVED`**（46 項） | 4 個非等價缺口全轉 KILLED；其餘 6 項皆為等價突變（`ToolCallStream.swift:92, 99, 111, 123`、`AgentTelemetry.swift:68` fallback 同費率、`TranscriptIndex.swift:195` 在 `L258` `isHumanPrompt` 已先排除 `isSidechain`） |
| `App/` 安全／邊界目標突變（`swift_mutate_app_fast.py`） | `11 KILLED / 5 SURVIVED`（16 項） | **`13 KILLED / 3 SURVIVED`**（16 項全跑，FIFO EOF 修正前）；目標 3 項缺口重跑 **`3/3 KILLED`** | `isPathContained_noslash`、`totalEnvBytes_strict_lt`、`untracked_fifo_S_IFREG_skip` 全轉 KILLED；16 項中另 2 項未於 FIFO 修正後重跑為 `required_override_disabled` 與 `unsafe_scalar_skip` |

### 最後編輯後的實機驗證（於真實工作樹執行）

- 清理確認：`rm -rf /tmp/lmux-mut-audit` 且 `test ! -e /tmp/lmux-mut-audit` 通過，工作樹無測試殘留。
- `beat/changes/preview-liquid-glass/dev.sh check && App/scripts/apptest.sh --preview && swift test --package-path Core`：全部通過（exit `0`）：
  - `APP TOKEN CHECK: ok`
  - `App` harness suites：`80/80`、`53/53`、`6/6`、`79/79`（`--liquid-glass-telemetry`）、`152/152`、`7/7` 全數 PASS。
  - `Core`：`LmuxTranscriptTests`（`3`＋`0` tests）、`LmuxHooksTests`（`1` test）與 Swift Testing（`64`＋`34`＋`125` tests）全數 PASS。

