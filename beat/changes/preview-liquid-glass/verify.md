---
change: preview-liquid-glass
date: 2026-11-20
sha: f93ae7b
mode: full
round: 4
findings:
  - { id: F1, severity: CRITICAL, dimension: 1B, scenario: "按住 ⌃⌘ 點擊可預覽檔案直接開成預覽 tab", file: "App/Sources/LmuxUI/OpenMenu.swift:33", fix: "Ghostty 只在修飾鍵恰為 ⌘ 時偵測連結（vendor/ghostty/src/Surface.zig:4490、4535），⌃⌘ 分支在正式路徑走不到；改成在 SurfaceView 自行處理 ⌃⌘，或從規格、design Key Decision 1、ADR 0002 移除此捷徑，並補走真實滑鼠事件的測試、更正 manual-verification.md:45", status: fixed }
  - { id: F2, severity: CRITICAL, dimension: 4, scenario: "左側 workspace 卡片顯示彩色識別條與狀態藥丸並保留多選與排序", file: "App/Sources/LmuxUI/SidebarSelection.swift:16", fix: "⇧-click 範圍選取改用 model.filteredWorkspaces 計算，或切換篩選時清除多選，並補「篩選中範圍選取不含隱藏列」的 apptest", status: open }
---

# Verify Report — preview-liquid-glass

結論：2 個 CRITICAL 未解決，不可 archive。先跑 `/beat:apply preview-liquid-glass fix-from-verify`。

## 本次執行

| 項目 | 內容 |
|---|---|
| 模式 | full。上一次的 `verification` 沒有 `sha`，無法做 incremental |
| 輪次 | 4（推定）。上一次紀錄沒有 `round`；git 紀錄顯示重新設計（2e194c6）後已有 3 次 verify 結果寫入 status.yaml（critical 6 → 3 → 0） |
| 強度 | standard（status.yaml 沒有 `preset`）：兩個 subagent 平行執行 |
| 收斂規則 | 第 4 輪套用 round cap：只記錄 CRITICAL 與舊 finding 的複查。上一輪沒有 verify.md，所以沒有可複查的舊 finding |

## Summary

| Dimension | Status | CRITICAL | 未記錄（第 4 輪只計數） |
|---|---|---|---|
| 1 Gherkin 品質與覆蓋 | fail | 1（F1） | 7 WARNING、5 SUGGESTION |
| 2 Proposal 對齊 | pass | 0 | 0 |
| 3 Design 遵循 | partial | 0 | 1 WARNING、1 SUGGESTION |
| 4 程式碼品質 | with fixes | 1（F2） | 6 WARNING、11 SUGGESTION |
| 5 Living docs（advisory） | partial | 0 | 4 WARNING、3 SUGGESTION |

+17 warnings not recorded（round 4）、+20 suggestions not recorded（round 4）。兩份報告重複的項目已合併計算一次。

## CRITICAL

### F1 ⌃⌘ 點擊直接開預覽 tab 在真實 app 觸發不了（Dimension 1B）

- 位置：`App/Sources/LmuxUI/OpenMenu.swift:33-35`；場景在 `open-menu.feature:115-120`
- 原因（verification subagent 讀程式碼得出，未實際執行）：
  - Ghostty 只在滑鼠修飾鍵「完全等於」⌘ 時才把點擊當成連結：`vendor/ghostty/src/Surface.zig:4490`（OSC 8）、`:4535`（一般連結）。
  - lmux 會把 ⌃ 一起傳給 Ghostty（`App/Sources/LmuxTerminal/SurfaceView.swift:536`、`GhosttyInput.swift:28`），所以 `openTerminalLink` 不會被呼叫。
- 測試為何綠燈：`PreviewInteractions.swift:148-162` 用 `clickModifiersOverride` 直接呼叫 `openTerminalLink`，繞過 Ghostty。
- `manual-verification.md:45` 把這項記為「通過」，與上面的分析矛盾。
- code-reviewer 也獨立提到這一點（以 SUGGESTION 提出，已併入 F1）。
- 修正方向（需要先決定）：
  - (a) 在 SurfaceView 的滑鼠事件自行處理 ⌃⌘。
  - (b) 從 `open-menu.feature`、design.md Key Decision 1、`docs/adr/0002-dual-track-inspector-preview.md` 移除這個捷徑。

### F2 篩選中 ⇧-click 會選到看不見的 workspace，關閉時一起刪掉（Dimension 4）

- 位置：`App/Sources/LmuxUI/SidebarSelection.swift:16-19`
- 原因（code-reviewer 讀程式碼得出，未實際執行）：
  - 範圍選取用 `model.workspaces`（全部），篩選只影響 sidebar 畫什麼（`Sidebar.swift:50`）。
  - ⌘W 或列上的 × 會關閉整個選取範圍，含隱藏列。pane 閒置時不會跳確認，scrollback 與 layout 直接遺失。
  - 拖曳排序在篩選時有擋（`Sidebar.swift:218,228`），範圍選取沒有。
- 屬於本 change：`filteredWorkspaces` 在 main 不存在（`git grep filteredWorkspaces main -- App/Sources` 沒有結果），是本 change 新增的篩選功能。
- 修正方向：範圍改用 `model.filteredWorkspaces`，或切換篩選時清除多選；補一個 apptest。

## Divergence

- 本輪記錄的 open 數（CRITICAL 2）大於上一輪（CRITICAL 0、passed），依規則判定 **diverging=yes**。
- 但兩個 CRITICAL 都不在上一個修正 commit（f93ae7b）改過的檔案裡：
  - `SidebarSelection.swift`：本分支沒改過，問題來自本 change 新增的篩選。
  - `OpenMenu.swift`：⌃⌘ 分支來自 76cd65e，最後一次修改是 a6d6aac。
- 所以這比較像前幾輪漏抓，不是修正打開新問題。仍建議修之前先人工決定 F1 的方向。
- 第 4 輪還出現 CRITICAL，代表這個 change 範圍太大。這次修完後，後續工作建議拆成較小的 change。

## Lint（step 2b）

- `validate-beat.mjs --change`：0 error、3 warning（缺 `preset`、缺 `verification.sha`、缺 verify.md；後兩項本次寫入後解除）。
- `lint-features.mjs --require-covered-by`（本 change 3 個 feature）：2 error（`liquid-glass-app.feature`、`open-menu.feature` 缺 user story；subagent 判斷是 linter 不認得「身為／以便」）、7 warning。
- lint error 屬 WARNING，第 4 輪只計數，已含在上面的 +17。

## Testing Context

- Drive mode：gherkin-driven；testing.required 未設定，視為 required；source：normal。
- @e2e 31 個、@behavior 7 個場景，全部有 `@covered-by` 且目標檔存在。
- Modified files：`beat/features/preview/open-menu.feature`，已與 `.orig` 比對做語意驗證。
- **自動化測試（step 4）未執行**：`swift test --package-path Core`、`liquid-glass-app-check`、`liquid-glass-mockup-check` 都被權限規則拒絕。需要使用者自己跑：
  - `export PATH="/usr/bin:$PATH"; swift test --package-path Core`
  - `export PATH="$HOME/.local/share/lmux-dev/bin:/usr/bin:$PATH"; beat/changes/preview-liquid-glass/dev.sh check`
  - 有失敗時，每個失敗的測試都要補記為 CRITICAL。

## Final Assessment

2 critical issue(s) found. Fix before archiving.
