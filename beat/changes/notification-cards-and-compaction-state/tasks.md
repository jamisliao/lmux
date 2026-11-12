# 通知卡片與壓縮中的進行中狀態 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **例外：Task 1 與 Task 8 由主 session（controller）執行，不派給 subagent**：兩者都要使用者動手或回答問題。Task 1 完成後，controller 重讀本檔並更新待辦清單（Task 1 可能改寫 Task 3、新增 Task 3a…）。

**Goal:** 壓縮時 tab 顯示進行中；通知 bar 的通知改成卡片（任務名稱、workspace 名稱、兩行訊息），並反白來自 focused tab 的卡片。

**Architecture:** A 部分改 lmux 核心的 hook 清單（`HookInstaller.events`）、狀態機（`PaneAgent`）與 App 端的第 2 行文字（`Agent.swift`），用 swift-testing 驗證。B 部分只改 plugin（`App/Sources/LmuxNotificationBar/`），新增 `NotificationCard.swift`，由使用者在 build 出來的 `lmux.app` 手動確認。實作 A 之前，先記錄 `/compact` 真正送出的事件順序並審查其他狀態（Task 1）。

**Tech Stack:** Swift 6.4.2、SwiftPM、swift-testing、SwiftUI、AppKit。

## Global Constraints

- worktree：`/Users/jamis.liao/opensource/lmux-sidebar-notification-bar`，branch `feat/sidebar-notification-bar`。不 push。
- 所有 commit message、程式碼註解、文件用繁體中文（台灣用詞）；程式碼識別字保留英文。commit message 結尾加 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- 從 lmux pane 裡跑任何 build／測試指令前，先 `unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET`，否則會打到使用者正在用的 lmux。
- 所有 `swift` 指令前先 `export PATH="/usr/bin:$PATH"`（避開 Homebrew 的 GNU libtool）。
- 不用 `env -u X ...`、`PATH=... cmd`、`sed -i` 的寫法（會被 hook 擋）；改成先 `unset`／`export` 再執行；改檔用編輯工具。
- 不改 `App/scripts/bundle.sh`；build `lmux.app` 一律用 repo 外的 swift 包裝腳本（Task 8 Step 1）。
- plugin 以外的 lmux 原始檔，只准改：`Core/Sources/LmuxHooks/HookInstaller.swift`、`Core/Sources/LmuxHooks/AgentState.swift`、`Core/Sources/LmuxHooks/HookEvent.swift`（Task 3a，使用者 2026-11-12 同意）、`App/Sources/LmuxUI/Agent.swift`，以及 `Core/Tests/LmuxHooksTests/` 的測試。例外：Task 0 的 `Core/Tests/LmuxTranscriptTests/TranscriptIndexTests.swift`。其他檔案（例如新事件要改的 `HookEvent.swift`）先問使用者。
- 不改 `NotificationEntry`（`App/Sources/LmuxUI/Model.swift:694`）。
- 相依：Task 2-3 依 Task 1 的結果；Task 4 依 Task 3；Task 5-6（B 部分）不依賴 Task 1-4，Task 1 等使用者時可以先做。

## Quality Principles

**Testing:** Tests verify behavior (return values, state changes, responses), not wiring.
If the main assertion is `toHaveBeenCalledWith`, rewrite to assert on the function's output.

**Code:** No single new file exceeds ~300 lines. If it grows past that, split into focused sub-modules.

## File Structure

| 檔案 | 責任 | Task |
|---|---|---|
| `Core/Tests/LmuxTranscriptTests/TranscriptIndexTests.swift` | （只在編不過時）Swift 6.4.2 type-check 修正 | 0 |
| `beat/changes/notification-cards-and-compaction-state/design.md`、`features/compaction-running-state.feature` | 審查結果、補的場景 | 1 |
| `Core/Sources/LmuxHooks/HookInstaller.swift` | lmux 寫進 `~/.claude/settings.json` 的事件清單 | 2 |
| `Core/Tests/LmuxHooksTests/InstallerTests.swift` | 安裝／更新 hook 的測試 | 2 |
| `Core/Sources/LmuxHooks/AgentState.swift` | 每個 tab 的狀態機 | 3 |
| `Core/Tests/LmuxHooksTests/EventParsingTests.swift` | 測試用 payload（`Payloads`） | 3 |
| `Core/Tests/LmuxHooksTests/AgentStateTests.swift` | 狀態機測試 | 3 |
| `App/Sources/LmuxUI/Agent.swift` | 壓縮時第 2 行顯示 `Compacting` | 4 |
| `App/Sources/LmuxNotificationBar/NotificationCard.swift`（新） | 一張通知卡片：內容、名稱取法、反白 | 5、6 |
| `App/Sources/LmuxNotificationBar/NotificationBar.swift` | 摘要列、清單、bar 最小高度 | 5 |
| `beat/changes/notification-cards-and-compaction-state/manual-verification.md`（新） | `@e2e` 場景的手動驗證紀錄 | 8 |

---

### Task 0: 前置：確認 Core 測試能編譯

**Files:**
- 只在編不過時 Modify: `Core/Tests/LmuxTranscriptTests/TranscriptIndexTests.swift:38-42`

**Interfaces:**
- Consumes: 無。
- Produces: `swift test` 在 `Core/` 能跑。Task 2、3、7 依賴它。

- [x] **Step 1: 跑 Core 測試**（結果：編不過，type-check 已知問題）

Run:
```bash
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/usr/bin:$PATH"
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar/Core
swift test 2>&1 | tail -20
```
Expected: 全部 PASS → 跳到 Task 1，不改任何檔案。

- [x] **Step 2: 只在 Step 1 失敗於 `Tests/LmuxTranscriptTests/TranscriptIndexTests.swift:38-42` 的 type-check 時修正**

這是 Swift 6.4.2 的已知問題，與本功能無關。在 `@Test(arguments: [...])` 陣列的結尾 `]` 後面加 ` as [String]`，也就是最後一行改成：

```swift
                          + #"{"parentUuid":"int","isSidechain":false,"type":"user","message":{"role":"user","content":"again"},"uuid":"u9","timestamp":"T11","turnOrigin":"human"}"# + "\n"] as [String])
```

重跑 Step 1 的指令。Expected: 全部 PASS。

- [x] **Step 3: 單獨 commit（只在 Step 2 有改時）**（`1eb7298`）

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add Core/Tests/LmuxTranscriptTests/TranscriptIndexTests.swift
git commit -m "$(cat <<'EOF'
test: 修正 Swift 6.4.2 編不過 TranscriptIndexTests 的 type-check

@Test(arguments:) 的陣列沒標型別又有多個字串相加，Swift 6.4.2 type-check 逾時，
連帶整個 Core 的 swift test 都跑不了。加上 as [String]，與本功能無關。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 1: 記錄 `/compact` 的真實事件順序，審查其他狀態（controller 執行）

**Files:**
- Create（repo 外）: `/private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/.claude/settings.local.json`
- Modify: `beat/changes/notification-cards-and-compaction-state/design.md`（C 節後面加「審查結果」；A.3 與「風險」依結果修改）
- Modify: `beat/changes/notification-cards-and-compaction-state/features/compaction-running-state.feature`（確認的問題補場景）
- Modify: 本檔（Task 3 的測試與實作；需要時新增 Task 3a、3b…；同步 Task 8）

**Interfaces:**
- Consumes: 無。
- Produces: 真實事件順序；審查結果表。若結果改到 A.3 的既有規則（`preCompact`、`postCompact`、`SessionStart(compact)`、`idle_prompt`、Esc），直接改 Task 3 的測試與實作，不另開 3a。

- [x] **Step 1: 確認本機 Claude Code 版本**（2.1.318；binary 內有 `PreCompact`、`PostCompact`）

Run: `claude --version`
到 https://code.claude.com/docs/en/hooks 確認這個版本支援 `PostCompact`。不支援時停下來問使用者（寫進共用的 settings.json 會是舊版不認得的 key）。

- [x] **Step 2: 建立記錄用的暫時專案**

建立 `/private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/.claude/settings.local.json`，內容如下（hook 只寫檔、不寫 stdout：PreCompact 的 stdout 會變成壓縮指示）：

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "cat >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl; echo >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "cat >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl; echo >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl" }] }],
    "PreCompact": [{ "hooks": [{ "type": "command", "command": "cat >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl; echo >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl" }] }],
    "PostCompact": [{ "hooks": [{ "type": "command", "command": "cat >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl; echo >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "cat >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl; echo >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "cat >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl; echo >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "cat >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl; echo >> /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe/events.jsonl" }] }]
  }
}
```

不動 `~/.claude/settings.json`。

- [x] **Step 3: 請使用者跑三種情況**（只跑了情況 A；改記錄 `/compact`、背景子 agent、`AskUserQuestion`）

給使用者的步驟（一步一個動作）：
1. 在任一個終端機執行：`cd /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe && claude`。出現信任資料夾的提示時選信任。
2. 輸入 `case A: 說 hi`，等回答完。
3. 輸入 `/compact`，等壓縮完成。（情況 A：完成時壓縮）
4. 輸入 `/exit`。
5. 執行 `claude --continue`，直接輸入 `/compact`，等壓縮完成。（情況 B：閒置時壓縮）
6. 輸入 `case C: 說 hi`，等回答完。
7. 輸入 `/compact`，馬上按 Esc。（情況 C：壓縮中按 Esc）
8. 等 1 分鐘（讓閒置提醒有機會送出），輸入 `/exit`。

- [x] **Step 4: 讀出事件順序**

Run:
```bash
cd /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/compact-probe
grep -v '^$' events.jsonl | while IFS= read -r line; do
  printf '%s\n' "$line" | grep -o '"hook_event_name":"[A-Za-z]*"\|"source":"[a-z]*"\|"trigger":"[a-z]*"\|"notification_type":"[a-z_]*"\|"prompt":"case [A-C]' | tr '\n' ' '
  echo
done
```
Expected: 每行一個事件。記下三種情況各自的順序，特別是：`/compact` 有沒有送 `UserPromptSubmit`；壓縮後有沒有 `Stop`；`PostCompact` 與 `SessionStart(compact)` 誰先到；情況 C 送了什麼。

- [x] **Step 5: 依事件順序檢查 Task 3 的規則**（規則不用改，見 design.md「風險」）

把三種順序逐一套進 design.md A.3 的規則表，寫出每一步的狀態：
- 結果符合 `compaction-running-state.feature` → 不改。
- 不符合（例如壓縮後有 `Stop`、`/compact` 會送 `UserPromptSubmit`）→ 修改 A.3 規則、Task 3 的測試與實作，並在 decisions TSV 記一列。
- 把三種順序寫進 design.md「風險」，取代兩條「未查證」。

- [x] **Step 6: 審查其他狀態**（使用者回報：子 agent 執行中、等我回答問題；前者已查證，後者待 Task 3b）

1. 讀 https://code.claude.com/docs/en/hooks，列出全部 hook 事件與 `notification_type`。
2. 對照 lmux：
   ```bash
   cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
   sed -n 26,33p Core/Sources/LmuxHooks/HookInstaller.swift
   grep -n "case \." Core/Sources/LmuxHooks/AgentState.swift | sed -n 1,60p
   sed -n 225,250p App/Sources/LmuxUI/Model.swift
   ```
3. 在 design.md 的 C 節後面加：
   ```markdown
   #### 審查結果

   | Claude Code 事件／通知類型 | 觸發時機 | lmux 有訂閱？ | 狀態機處理 | sidebar 顯示 | 問題 |
   |---|---|---|---|---|---|
   ```
   每個事件一列；「問題」欄寫「無」或具體描述。
4. 用 AskUserQuestion 問使用者：「看過哪些狀態顯示不對？請說：當時 Claude 在做什麼、tab 顯示什麼、應該顯示什麼。」每個情境對到表上的一列；對不到的寫「無對應 hook，無法修正」，記進「風險」。

- [x] **Step 7: 確認的問題補場景與任務**（Task 3a、3b；HookEvent.swift 已獲同意）

每個確認的問題：
1. 在 `compaction-running-state.feature` 加 `@behavior` 場景（業務語言，不寫方法名稱）。
2. 在 design.md A.3 加一列。
3. 在本檔 Task 3 後面加 Task 3a、3b…（格式比照 Task 3：先寫失敗的測試、跑測試確認失敗、實作、跑測試確認通過、commit；測試加 `// @feature:`、`// @scenario:`，feature 加 `# @covered-by:`）。
4. 同步 Task 8：Step 5 加手動確認項；`manual-verification.md` 加列。
5. 要訂閱新事件時：`HookEvent.Kind` 要加 case（`Core/Sources/LmuxHooks/HookEvent.swift`，不在允許清單）→ 先問使用者；Task 2 的測試一起更新。

- [x] **Step 8: Commit**

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add beat/changes/notification-cards-and-compaction-state/
git commit -m "$(cat <<'EOF'
design(notification-cards-and-compaction-state): 記錄 /compact 的事件順序與其他狀態的審查結果

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

完成後，controller 重讀本檔，更新待辦清單。

---

### Task 2: lmux 訂閱 PreCompact 與 PostCompact

**Files:**
- Modify: `Core/Sources/LmuxHooks/HookInstaller.swift:26-32`
- Test: `Core/Tests/LmuxHooksTests/InstallerTests.swift`（新增 2 個測試；刪除第 99-100 行）
- Modify: `beat/changes/notification-cards-and-compaction-state/features/compaction-running-state.feature`（`# @covered-by:`）

**Interfaces:**
- Consumes: `HookInstaller.install(into:hookPath:target:)`、`HookInstaller.status(of:target:)`、`HookInstaller.Target(events:argument:appends:)`（internal memberwise init，測試用 `@testable import` 取得）、`JSONValue.parse(_:)`、`foreignSettings`（`InstallerTests.swift` 頂端的 fixture）。
- Produces: `HookInstaller.events` 包含 `"PreCompact"`、`"PostCompact"`（共 16 個）。
- 整合前提：`lmux-hook` 在 hook 模式不寫 stdout（`Core/Sources/lmux-hook/main.swift`）。PreCompact 的 stdout 會被 Claude 當成壓縮指示，這個前提不能破壞。

- [x] **Step 1: 寫失敗的測試**

在 `Core/Tests/LmuxHooksTests/InstallerTests.swift` 的 `installPreservesForeignHooksAndIsIdempotent()` 後面加：

```swift
    // @feature: compaction-running-state.feature
    // @scenario: 更新 hook 時加入壓縮事件，保留使用者自己的壓縮 hook
    /// 舊版 lmux 裝的 hook 沒有壓縮事件：再裝一次會加上 PreCompact 與 PostCompact，
    /// 使用者自己的 PreCompact 項目保留原樣。
    @Test func reinstallAddsCompactionEventsKeepingForeignPreCompact() throws {
        let compaction = ["PreCompact", "PostCompact"]
        let old = HookInstaller.Target(events: HookInstaller.events.filter { !compaction.contains($0) },
                                       argument: nil, appends: false)
        let older = try HookInstaller.install(into: foreignSettings, hookPath: hookPath, target: old)
        let olderStatus = try HookInstaller.status(of: older)
        #expect(!olderStatus.isComplete)

        let now = try HookInstaller.install(into: older, hookPath: hookPath)
        let nowStatus = try HookInstaller.status(of: now)
        #expect(nowStatus.isComplete)
        let before = try JSONValue.parse(foreignSettings)
        let after = try JSONValue.parse(now)
        for ev in compaction {
            guard case .array(let a)? = after["hooks"]?[ev] else { Issue.record("missing \(ev)"); continue }
            #expect(a.filter { "\($0)".contains(HookInstaller.marker) }.count == 1)
        }
        guard case .array(let b)? = before["hooks"]?["PreCompact"],
              case .array(let a)? = after["hooks"]?["PreCompact"] else { Issue.record(); return }
        #expect(a.filter { !"\($0)".contains(HookInstaller.marker) } == b)
    }

    /// 官方版 lmux（舊的事件清單）再裝一次：lmux 的壓縮項目被移除，使用者自己的 PreCompact 保留。
    @Test func olderLmuxReinstallDropsCompactionEventsKeepingForeignPreCompact() throws {
        let compaction = ["PreCompact", "PostCompact"]
        let old = HookInstaller.Target(events: HookInstaller.events.filter { !compaction.contains($0) },
                                       argument: nil, appends: false)
        let newer = try HookInstaller.install(into: foreignSettings, hookPath: hookPath)
        let downgraded = try HookInstaller.install(into: newer, hookPath: hookPath, target: old)
        let before = try JSONValue.parse(foreignSettings)
        let after = try JSONValue.parse(downgraded)
        for ev in compaction {
            if case .array(let a)? = after["hooks"]?[ev] {
                #expect(!a.contains { "\($0)".contains(HookInstaller.marker) })
            }
        }
        #expect(after["hooks"]?["PreCompact"] == before["hooks"]?["PreCompact"])
    }
```

- [x] **Step 2: 跑測試，確認失敗**

Run（在 `Core/`，沿用 Task 0 Step 1 的 `unset`／`export`）：`swift test --filter LmuxHooksTests.InstallerTests 2>&1 | tail -20`
Expected: FAIL：`reinstallAddsCompactionEventsKeepingForeignPreCompact` 的 `#expect(!olderStatus.isComplete)`（舊清單等於目前清單）。`olderLmuxReinstallDropsCompactionEventsKeepingForeignPreCompact` 此時會通過（目前沒有 lmux 的壓縮項目），實作後仍須通過。

- [x] **Step 3: 實作**

`Core/Sources/LmuxHooks/HookInstaller.swift:26-32` 改成：

```swift
    /// Events the state machine consumes (plus SubagentStart/Stop for the subagent counter).
    /// PreCompact／PostCompact：壓縮期間 tab 顯示進行中（beat: compaction-running-state.feature）。
    public static let events: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "PostToolUseFailure", "Notification", "SubagentStart",
        "SubagentStop", "Stop", "StopFailure", "Elicitation", "ElicitationResult",
        "PreCompact", "PostCompact", "SessionEnd",
    ]
```

`Core/Tests/LmuxHooksTests/InstallerTests.swift` 刪掉這 2 行（PreCompact 現在也是 lmux 的事件；使用者的 PreCompact 項目保留，已由第 87-90 行的迴圈驗證）：

```swift
        // Foreign-only event untouched.
        #expect(after["hooks"]?["PreCompact"] == before["hooks"]?["PreCompact"])
```

- [x] **Step 4: 跑測試，確認通過**

Run: `swift test --filter LmuxHooksTests 2>&1 | tail -20`
Expected: 全部 PASS（包含 `installPreservesForeignHooksAndIsIdempotent` 與 2 個新測試）。

- [x] **Step 5: 標註場景**

`compaction-running-state.feature` 的場景「更新 hook 時加入壓縮事件，保留使用者自己的壓縮 hook」：在 tag 行與 `場景:` 之間加：

```gherkin
  # @covered-by: Core/Tests/LmuxHooksTests/InstallerTests.swift
```

- [x] **Step 6: Commit**（`f41c5d9`）

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add Core/Sources/LmuxHooks/HookInstaller.swift Core/Tests/LmuxHooksTests/InstallerTests.swift beat/changes/notification-cards-and-compaction-state/features/compaction-running-state.feature
git commit -m "$(cat <<'EOF'
lmux 訂閱 Claude Code 的 PreCompact 與 PostCompact hook

狀態機要靠這 2 個事件知道壓縮的開始與結束。已安裝 hook 的使用者要在
Settings → Hooks 按 Install 才會加入（舊安裝少了 2 個事件，顯示為未安裝；
lmux 只在 hook 路徑改變時自動提示）。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: 狀態機在壓縮期間顯示進行中

**Files:**
- Modify: `Core/Sources/LmuxHooks/AgentState.swift`（`PaneAgent` 的說明註解、欄位、`handle`、`userInterrupted`）
- Modify: `Core/Tests/LmuxHooksTests/EventParsingTests.swift`（`Payloads` 加 3 個 payload）
- Test: `Core/Tests/LmuxHooksTests/AgentStateTests.swift`（新增 11 個測試）
- Modify: `beat/changes/notification-cards-and-compaction-state/features/compaction-running-state.feature`（`# @covered-by:`）

**Interfaces:**
- Consumes: `HookEvent.Kind.preCompact`／`.postCompact`（`Core/Sources/LmuxHooks/HookEvent.swift:37,42`）、`e.source`、`e.notificationType`、`e.isSubagent`；Task 1 確認過的事件順序。
- Produces: `PaneAgent` 新的 private 欄位 `stateBeforeCompaction: AgentState?`。外部 API 不變；`AgentTransition` 不變。

- [x] **Step 1: 加測試用 payload**

在 `Core/Tests/LmuxHooksTests/EventParsingTests.swift` 的 `enum Payloads` 裡，`compactStart` 那行後面加：

```swift
    static let preCompact = json("PreCompact", #""trigger":"manual","custom_instructions":"""#)
    static let preCompactAuto = json("PreCompact", #""trigger":"auto","custom_instructions":"""#)
    static let postCompact = json("PostCompact", #""trigger":"manual","compact_summary":"Summary of the conversation.""#)
```

- [x] **Step 2: 寫失敗的測試**

在 `Core/Tests/LmuxHooksTests/AgentStateTests.swift` 的 `compactSessionStartKeepsRunningOthersReset()` 後面加：

```swift
    // MARK: 壓縮

    // @feature: compaction-running-state.feature
    // @scenario: 已完成的 tab 開始壓縮時顯示進行中
    // @scenario: 壓縮結束後回到完成，不發通知
    @Test func manualCompactionAfterDoneRunsThenRestoresDoneSilently() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.postCompact], agent: &a)
        #expect(t.map(\.to) == [.running, .done, .running, .done])
        #expect(t[2].alert == nil && t[3].alert == nil)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮結束後回到完成，不發通知
    /// 只有 SessionStart(compact)、沒有 PostCompact，也算壓縮結束。
    @Test func compactSessionStartAloneEndsCompaction() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.compactStart], agent: &a)
        #expect(t.map(\.to) == [.running, .done, .running, .done])
        #expect(t[3].alert == nil)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 閒置的 tab 壓縮結束後回到閒置
    @Test func compactionFromIdleRestoresIdle() throws {
        var a = PaneAgent()
        let t = try run([Payloads.sessionStart, Payloads.preCompact, Payloads.postCompact], agent: &a)
        #expect(t.map(\.to) == [.idle, .running, .idle])
        #expect(t.compactMap(\.alert).isEmpty)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 兩種結束回報都送來時只處理第一個
    /// 兩個結束回報之間狀態變了（等待回應）：第二個回報不把它改回完成。
    @Test func secondCompactionEndIsNoOp() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.postCompact,
                         Payloads.notifPermission, Payloads.compactStart], agent: &a)
        #expect(t.map(\.to) == [.running, .done, .running, .done, .needsInput(.permission), .needsInput(.permission)])
        #expect(t[3].alert == nil && t[5].alert == nil)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 沒收到結束回報時，閒置提醒讓 tab 回到原本的狀態
    @Test func idleReminderEndsCompactionWithoutAlert() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.notifIdle], agent: &a)
        #expect(t.map(\.to) == [.running, .done, .running, .done])
        #expect(t[3].alert == nil)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮期間使用者按 Esc 中斷
    @Test func escDuringCompactionGoesIdleAndLateEndIsIgnored() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact], agent: &a)
        let esc = a.userInterrupted()
        #expect(esc.to == .idle && esc.alert == nil)
        let t = try run([Payloads.postCompact], agent: &a)
        #expect(t[0].to == .idle && t[0].alert == nil)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮期間使用者送出新的 prompt
    @Test func promptDuringCompactionKeepsRunningAndLateEndIsIgnored() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.prompt, Payloads.postCompact],
                        agent: &a)
        #expect(t.map(\.to) == [.running, .done, .running, .running, .running])
    }

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮期間使用者送出新的 prompt
    /// 新的 session 或 session 結束也讓記住的狀態作廢（design A.3）。
    @Test func sessionChangeDuringCompactionForgetsTheOldState() throws {
        for change in [Payloads.sessionEnd, Payloads.sessionStart] {
            var a = PaneAgent()
            let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, change, Payloads.postCompact], agent: &a)
            #expect(t.map(\.to) == [.running, .done, .running, .idle, .idle])
        }
    }

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮期間使用者送出新的 prompt
    /// StopFailure 也讓記住的狀態作廢：之後的結束回報不把失敗改回閒置（design A.3）。
    @Test func failureDuringCompactionForgetsTheOldState() throws {
        var a = PaneAgent()
        let t = try run([Payloads.sessionStart, Payloads.preCompact, Payloads.stopFailure, Payloads.postCompact], agent: &a)
        #expect(t.map(\.to) == [.idle, .running, .done, .done])
    }

    // @feature: compaction-running-state.feature
    // @scenario: 回合中的自動壓縮不改變狀態
    @Test func autoCompactionMidTurnChangesNothing() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.preCompactAuto, Payloads.postCompact, Payloads.compactStart], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .running, .running])
        #expect(t.compactMap(\.alert).isEmpty)
        let end = try run([Payloads.stop], agent: &a)
        #expect(end[0].to == .done && end[0].alert == .done(lastMessage: "All tests pass."))
    }

    // @feature: compaction-running-state.feature
    // @scenario: 回合中的自動壓縮不改變狀態
    /// 回合中的自動壓縮不記住任何東西：漏掉 Stop 時，閒置提醒照原本規則補成完成並發 alert。
    @Test func autoCompactionMidTurnRemembersNothing() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.preCompactAuto, Payloads.notifIdle], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .done])
        #expect(t[2].alert == .done(lastMessage: nil))
    }
```

- [x] **Step 3: 跑測試，確認失敗**

Run（在 `Core/`，沿用 Task 0 Step 1 的 `unset`／`export`）：`swift test --filter LmuxHooksTests.AgentStateTests 2>&1 | tail -30`
Expected: FAIL：`manualCompaction…`、`compactSessionStartAlone…`、`compactionFromIdle…`、`secondCompactionEnd…`、`idleReminderEnds…`、`escDuringCompaction…`、`promptDuringCompaction…`、`sessionChangeDuring…`、`failureDuring…` 失敗（`preCompact` 目前不改變狀態）；`autoCompactionMidTurnChangesNothing`、`autoCompactionMidTurnRemembersNothing` 通過。

- [x] **Step 4: 實作**

(a) `PaneAgent` 上方的 `/// Rules:` 清單，在 `- Subagents (SubagentStart/Stop ...` 那一條前面加：

```swift
/// - 壓縮：PreCompact 時是閒置或完成（`/compact`，或 Claude 在閒置時自己壓縮）-> running，並記住原本的狀態。
///   壓縮結束（PostCompact、SessionStart `compact`，或兩者都沒來時的 idle_prompt）-> 回到原本的狀態，不發 alert。
///   回合中的自動壓縮本來就是 running，不記住任何東西。新 prompt、Stop、StopFailure、Esc、新的 session 讓記住的狀態作廢。
```

(b) `private var blockingAgent: String?` 後面加：

```swift
    /// PreCompact 時記住的狀態（只在閒置或完成時記）；nil 表示目前沒有 lmux 標成 running 的壓縮。
    private var stateBeforeCompaction: AgentState?
```

(c) `handle(_:focused:)` 裡，`func resumeIfBlockedBy` 的定義後面、`switch e.kind {` 前面加：

```swift
        // lmux 標成 running 的壓縮結束了：回到原本的狀態，不發 alert。
        if let before = stateBeforeCompaction, !e.isSubagent,
           e.kind == .postCompact
            || (e.kind == .sessionStart && e.source == "compact")
            || (e.kind == .notification && e.notificationType == "idle_prompt") {
            stateBeforeCompaction = nil
            state = before
            return AgentTransition(from: from, to: state, alert: nil, notify: nil)
        }
        // 回合或 session 換了：記住的狀態作廢（之後才到的結束回報不再改變狀態）。
        if !e.isSubagent, [.userPromptSubmit, .stop, .stopFailure, .interrupt, .sessionStart, .sessionEnd].contains(e.kind) {
            stateBeforeCompaction = nil
        }
```

(d) `switch` 裡把

```swift
        case .preCompact, .postCompact, .unknown:
            break
```

改成：

```swift
        case .preCompact:
            // `/compact`（或閒置時的自動壓縮）：壓縮完之前是 running。回合中的自動壓縮本來就是 running。
            if !e.isSubagent, state == .idle || state == .done {
                stateBeforeCompaction = state
                state = .running
            }
        case .postCompact, .unknown:
            break
```

(e) `userInterrupted()` 的第一行（`let from = state` 前面）加：

```swift
        stateBeforeCompaction = nil
```

- [x] **Step 5: 跑測試，確認通過**

Run: `swift test --filter LmuxHooksTests 2>&1 | tail -20`
Expected: 全部 PASS，包含既有的 `idleReminderRecoversMissedStopOnce`、`compactSessionStartKeepsRunningOthersReset`、`userInterruptedGoesIdleWithoutAlert`。

- [x] **Step 6: 標註場景**

`compaction-running-state.feature` 每個 `@behavior` 場景（除了 Task 2 已標的那個），在 tag 行與 `場景:` 之間加：

```gherkin
  # @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift
```

- [x] **Step 7: Commit**（`1b785ff`）

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add Core/Sources/LmuxHooks/AgentState.swift Core/Tests/LmuxHooksTests/EventParsingTests.swift Core/Tests/LmuxHooksTests/AgentStateTests.swift beat/changes/notification-cards-and-compaction-state/features/compaction-running-state.feature
git commit -m "$(cat <<'EOF'
壓縮期間 tab 顯示進行中，結束後回到原本的狀態

使用者打 /compact 後，tab 原本仍顯示完成或閒置。PreCompact 時若 tab 閒置或完成，
改成 running 並記住原本的狀態；PostCompact、SessionStart(compact) 或閒置提醒
讓它回到原本的狀態，不發通知。回合中的自動壓縮不受影響。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

### Task 3a: 背景子 agent 還在跑時，tab 維持進行中（Task 1 審查新增）

**Files:**
- Modify: `Core/Sources/LmuxHooks/HookEvent.swift`（新欄位與解析）
- Modify: `Core/Sources/LmuxHooks/AgentState.swift`（`handle` 的 `.stop` 分支；說明註解）
- Modify: `Core/Tests/LmuxHooksTests/EventParsingTests.swift`（`Payloads` 加 3 個 payload；解析測試）
- Test: `Core/Tests/LmuxHooksTests/AgentStateTests.swift`（新增 5 個測試）
- Modify: `beat/changes/notification-cards-and-compaction-state/features/subagent-running-state.feature`（`# @covered-by:`）

**Interfaces:**
- Consumes: 實測的 `Stop` payload（`compact-probe/events2.log`）：`"background_tasks":[{"id":"…","type":"subagent","status":"running",…}]`。
- Produces: `HookEvent.runningBackgroundSubagents: Int`。

- [x] **Step 1: 加測試用 payload**

在 `enum Payloads` 的 `compactStart` 那行後面加：

```swift
    static let stopBgSubagent = json("Stop", #""stop_hook_active":false,"last_assistant_message":"已派出","background_tasks":[{"id":"agent-7","type":"subagent","status":"running","description":"sleep","agent_type":"general-purpose"}],"session_crons":[]"#)
    static let stopBgShell = json("Stop", #""stop_hook_active":false,"last_assistant_message":"已啟動","background_tasks":[{"id":"b75w99nqn","type":"shell","status":"running","description":"dev server","command":"sleep 40"}],"session_crons":[]"#)
    static let stopBgSubagentDone = json("Stop", #""stop_hook_active":false,"last_assistant_message":"好了","background_tasks":[{"id":"agent-7","type":"subagent","status":"completed","description":"sleep","agent_type":"general-purpose"}],"session_crons":[]"#)
```

- [x] **Step 2: 寫失敗的測試**

在 `EventParsingTests` 加解析測試：

```swift
    @Test func countsOnlyRunningBackgroundSubagents() throws {
        #expect(try event(Payloads.stopBgSubagent).runningBackgroundSubagents == 1)
        #expect(try event(Payloads.stopBgShell).runningBackgroundSubagents == 0)
        #expect(try event(Payloads.stopBgSubagentDone).runningBackgroundSubagents == 0)
        #expect(try event(Payloads.stop).runningBackgroundSubagents == 0)  // 沒有 background_tasks 欄位
    }
```

在 `AgentStateTests.swift` 的最後一個測試後面加：

```swift
    // MARK: 背景子 agent

    // @feature: subagent-running-state.feature
    // @scenario: 主回合結束時還有背景子 agent 在跑，tab 維持進行中
    @Test func stopWithRunningBackgroundSubagentStaysRunningSilently() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.subStart, Payloads.stopBgSubagent], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .running])
        #expect(t.allSatisfy { $0.alert == nil && $0.notify == nil })
        #expect(a.activeSubagents == ["agent-7"])
    }

    // @feature: subagent-running-state.feature
    // @scenario: 背景子 agent 做完、Claude 回應完後，tab 顯示完成並只通知一次
    @Test func doneOnlyAfterTheLastStopWithNoBackgroundSubagent() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.subStart, Payloads.stopBgSubagent, Payloads.subStop,
                         Payloads.prompt, Payloads.stop], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .running, .running, .running, .done])
        #expect(t.compactMap(\.notify) == [.done(lastMessage: "All tests pass.")])
    }

    // @feature: subagent-running-state.feature
    // @scenario: 還在跑的只有背景 shell 時，主回合結束就是完成
    @Test func backgroundShellDoesNotKeepTheTurnRunning() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stopBgShell], agent: &a)
        #expect(t.map(\.to) == [.running, .done])
        #expect(t[1].notify == .done(lastMessage: "已啟動"))
    }

    // @feature: subagent-running-state.feature
    // @scenario: 背景子 agent 已經結束時，主回合結束就是完成
    @Test func finishedBackgroundSubagentDoesNotKeepTheTurnRunning() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stopBgSubagentDone], agent: &a)
        #expect(t.map(\.to) == [.running, .done])
        #expect(t[1].notify == .done(lastMessage: "好了"))
    }

    // @feature: subagent-running-state.feature
    // @scenario: 沒收到背景子 agent 的後續事件時，閒置提醒讓 tab 顯示完成
    @Test func idleReminderEndsADeferredStop() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.subStart, Payloads.stopBgSubagent, Payloads.notifIdle], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .running, .done])
        #expect(t[3].notify == .done(lastMessage: nil))
    }
```

- [x] **Step 3: 跑測試，確認失敗**

Run（在 `Core/`，沿用 Task 0 的 `unset`／`export`）：`swift test --filter LmuxHooksTests 2>&1 | grep -E "error:|✘" | head -20`
Expected: 編譯錯誤 `runningBackgroundSubagents` 不存在（RED）。先加欄位但不處理（`public var runningBackgroundSubagents = 0`）後重跑，Expected: `stopWithRunningBackgroundSubagentStaysRunningSilently`、`doneOnlyAfter…`、`idleReminderEndsADeferredStop` 與解析測試失敗。

- [x] **Step 4: 實作**

(a) `HookEvent.swift`，`stopHookActive` 那行後面加欄位：

```swift
    /// Stop 的 `background_tasks` 裡，還在跑（`status == "running"`）的背景子 agent 數量（背景 shell 不算）。
    public var runningBackgroundSubagents = 0
```

`init(paneID:payload:)` 裡 `stopHookActive = …` 後面加：

```swift
        runningBackgroundSubagents = (payload["background_tasks"] as? [[String: Any]] ?? []).filter {
            $0["type"] as? String == "subagent" && $0["status"] as? String == "running"
        }.count
```

(b) `AgentState.swift` 的 `case .stop:` 改成：

```swift
        case .stop:
            guard !e.isSubagent else { break }
            blockingAgent = nil
            // 背景子 agent 還在跑：主回合雖然結束，工作還沒完。維持進行中，不發 alert，也不清掉子 agent 計數；
            // 它們結束後 Claude 會再起一個回合（UserPromptSubmit），最後一個 Stop 才是完成。
            if e.runningBackgroundSubagents > 0 {
                state = .running
                break
            }
            activeSubagents.removeAll()
            if state != .done {
                state = .done
                alert = .done(lastMessage: e.lastAssistantMessage)
            }
```

類別說明註解 `- Stop (main agent) -> done + alert.` 那條後面加：`Unless background subagents are still running (Stop's background_tasks): stay running, no alert.`

- [x] **Step 5: 跑測試，確認通過**

Run: `swift test --filter LmuxHooksTests 2>&1 | grep -E "error:|✘|Test run" | head`
Expected: 全部 PASS（含既有的 `parallelSubagentsKeepTheTurnRunningUntilTheMainStop`、`subagentToolEventsDoNotReviveFinishedTurn`）。

- [x] **Step 6: 標註場景並 Commit**

`subagent-running-state.feature` 每個場景在 tag 行與 `場景:` 之間加 `# @covered-by: Core/Tests/LmuxHooksTests/AgentStateTests.swift`。

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add Core/Sources/LmuxHooks/HookEvent.swift Core/Sources/LmuxHooks/AgentState.swift Core/Tests/LmuxHooksTests/ beat/changes/notification-cards-and-compaction-state/features/subagent-running-state.feature
git commit -m "$(cat <<'EOF'
背景子 agent 還在跑時，tab 維持進行中

主 agent 派出背景子 agent 後會先 Stop，tab 原本就顯示完成並發通知，子 agent 做完後
又發第二次。Stop 的 background_tasks 有還在跑的子 agent 時，維持進行中、不發通知；
最後一個 Stop 才完成。背景 shell 不算（避免 dev server 讓 tab 永遠轉圈）。

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
)"
```

### Task 3b:「等我回答問題」（Task 1 審查新增；待查）

- [ ] **Step 1: 在 `default` 權限模式下記錄事件**：請使用者在 `compact-probe` 執行 `claude --permission-mode default`，做「權限提示（選允許、選拒絕各一次）」與 `AskUserQuestion`，讀 `events2.log`。
- [ ] **Step 2: 對照 lmux 的處理（`AgentState.swift`）**，找出沒有顯示需要輸入的情況；補場景、測試、實作（格式比照 Task 3a）。找不到問題時，向使用者回報並請他描述當時的操作。

---

### Task 4: 壓縮期間 workspace 列第 2 行顯示 Compacting

**Files:**
- Modify: `App/Sources/LmuxUI/Agent.swift`（`processHook` 裡 `preToolUse` 設定 `lastTool` 的區塊後面，約第 150-152 行）

**Interfaces:**
- Consumes: Task 3（`preCompact` 讓狀態變成 running）；`Pane.lastTool`（`App/Sources/LmuxUI/Model.swift:85`），進行中時是 workspace 列第 2 行（`Model.swift:240-245` 的 `runningDetail`）。
- Produces: 無新介面。

- [x] **Step 1: 實作**

在 `App/Sources/LmuxUI/Agent.swift` 這段之後：

```swift
        if e.kind == .preToolUse, !e.isSubagent, let tool = e.toolName {
            let t = e.toolArgument.map { "\(tool) · \($0)" } ?? tool
            if pane.lastTool != t { pane.lastTool = t }
        }
```

加：

```swift
        // 壓縮中：workspace 列第 2 行顯示 Compacting，不顯示上一個回合的工具（beat: compaction-running-state.feature）。
        // 下一個 PreToolUse 會覆蓋它，UserPromptSubmit 會清掉它。
        if e.kind == .preCompact, !e.isSubagent, pane.lastTool != "Compacting" { pane.lastTool = "Compacting" }
```

- [x] **Step 2: 編譯**

Run:
```bash
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/usr/bin:$PATH"
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar/App
swift build 2>&1 | grep -E "error|Build complete" | head -10
```
Expected: `Build complete!`。畫面上的確認在 Task 8 Step 5。

- [x] **Step 3: Commit**（`a917d5d`）

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add App/Sources/LmuxUI/Agent.swift
git commit -m "$(cat <<'EOF'
壓縮期間 sidebar 第 2 行顯示 Compacting

原本會顯示上一個回合用的工具（例如 Bash · swift test），看起來像在跑測試。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: 通知卡片

**Files:**
- Create: `App/Sources/LmuxNotificationBar/NotificationCard.swift`
- Modify: `App/Sources/LmuxNotificationBar/NotificationBar.swift`（檔頭說明、`minHeight`、`notificationLine` 刪除、`NotificationList`、`NotificationSummaryRow`；刪除 `NotificationListRow`）

**Interfaces:**
- Consumes: `AppModel.notifications`、`AppModel.workspaces`、`AppModel.clock`、`Workspace.panes`（`App/Sources/LmuxUI/Model.swift:466`）、`Workspace.customTitle`（`Model.swift:457`）、`Workspace.title`、`Pane.titleState.title`（`Model.swift:167`）、`Pane.headerTitle`（`Model.swift:278`）、`Pane.cwd`（`Model.swift:77`）、`LmuxController.openNotification(_:)`、`NotificationList.age(_:now:)`。
- Produces（Task 6 會用）:
  - `struct NotificationCard: View`，`init(entry: NotificationEntry, model: AppModel, age: String, open: @escaping () -> Void)`
  - `@MainActor static let NotificationCard.maxHeight: CGFloat`
  - `func sourcePane(_ e: NotificationEntry, in model: AppModel) -> Pane?`
  - `func taskTitle(_ e: NotificationEntry, in model: AppModel) -> String?`
  - `func workspaceName(_ e: NotificationEntry, in model: AppModel) -> String`
  - `func plainMessage(_ s: String) -> String`

- [x] **Step 1: 建立 `NotificationCard.swift`**

```swift
import AppKit
import LmuxTokens
import LmuxUI
import SwiftUI

private typealias T = LmuxTokens

/// 通知 bar 清單裡的一則通知，最多 4 行：任務名稱與經過時間、workspace 名稱、訊息（最多 2 行）。
/// 沒有任務名稱時，第 1 行改成 workspace 名稱，不顯示第 2 行；第 2 行與第 1 行相同時也不顯示。
struct NotificationCard: View {
    let entry: NotificationEntry
    let model: AppModel
    let age: String
    let open: () -> Void
    @State private var hover = false

    /// 圓角底色的位置比照 sidebar 的 workspace 列（外距 rowInsetX）；文字與摘要列、plugin 列對齊（x = 32）。
    static let outerPaddingX: CGFloat = T.Layout.rowInsetX
    static let innerPaddingX: CGFloat = 4
    static let innerPaddingY: CGFloat = 6
    static let outerPaddingY: CGFloat = 2

    /// 一行文字實際佔的高度：中文會改用 PingFang 顯示，行高比 SF 高，取兩者較大的值。
    @MainActor static func lineHeight(_ size: CGFloat) -> CGFloat {
        let lm = NSLayoutManager()
        let sf = lm.defaultLineHeight(for: .systemFont(ofSize: size))
        let cjk = NSFont(name: "PingFangTC-Regular", size: size).map { lm.defaultLineHeight(for: $0) } ?? sf
        return ceil(max(sf, cjk))
    }

    /// 4 行都有時的高度：通知 bar 的最小高度要放得下一張完整的卡片。
    @MainActor static let maxHeight: CGFloat = outerPaddingY * 2 + innerPaddingY * 2
        + lineHeight(T.Typography.rowTitle.size) + lineHeight(T.Typography.rowMeta.size)
        + lineHeight(T.Typography.rowSubtitle.size) * 2 + T.Layout.rowLineGap * 3

    var body: some View {
        let workspace = workspaceName(entry, in: model)
        let task = taskTitle(entry, in: model)
        let first = task ?? workspace
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(entry.read ? Color.clear : T.Colors.accent.color)
                .frame(width: 6, height: 6)
                .frame(width: 14, height: Self.lineHeight(T.Typography.rowTitle.size))
            VStack(alignment: .leading, spacing: T.Layout.rowLineGap) {
                HStack(spacing: 4) {
                    Text(first)
                        .font(.system(size: T.Typography.rowTitle.size, weight: entry.read ? .regular : .medium))
                        .foregroundStyle((entry.read ? T.Colors.textSecondary : T.Colors.textPrimary).color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(age)
                        .font(T.Typography.rowMeta.font.monospacedDigit())
                        .foregroundStyle(T.Colors.textTertiary.color)
                }
                if task != nil, workspace != first {
                    Text(workspace)
                        .font(T.Typography.rowMeta.font)
                        .foregroundStyle(T.Colors.textTertiary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(plainMessage(entry.message))
                    .font(T.Typography.rowSubtitle.font)
                    .foregroundStyle((entry.read ? T.Colors.textTertiary : T.Colors.textSecondary).color)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Self.innerPaddingX)
        .padding(.vertical, Self.innerPaddingY)
        .background(
            RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                .fill(background)
        )
        .padding(.horizontal, Self.outerPaddingX)
        .padding(.vertical, Self.outerPaddingY)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(entry.read ? "" : "unread")
    }

    private var background: Color {
        hover ? T.Colors.rowHover.color : .clear
    }
}

/// 通知來自的 tab；tab 已關閉時是 nil。在所有 workspace 裡找，tab 被移到別的 workspace 也找得到。
@MainActor
func sourcePane(_ e: NotificationEntry, in model: AppModel) -> Pane? {
    guard let id = e.paneID else { return nil }
    for ws in model.workspaces {
        if let pane = ws.panes.first(where: { $0.id == id }) { return pane }
    }
    return nil
}

/// 通知來自的 tab 目前的任務名稱（Claude 的 session 標題，清理規則與 tab 列、sidebar 相同）。
/// tab 已關閉、或沒有 session 標題時是 nil。讀的是現在的值：tab 換了 session，舊通知也顯示新的任務名稱。
@MainActor
func taskTitle(_ e: NotificationEntry, in model: AppModel) -> String? {
    guard let pane = sourcePane(e, in: model), let raw = pane.titleState.title, !raw.isEmpty else { return nil }
    let t = pane.headerTitle
    return t.isEmpty ? nil : t
}

/// 卡片上代表通知來源的名稱：workspace 的手動名稱；否則 tab 工作目錄的資料夾名稱；否則通知當時的名稱。
/// 不用 lmux 的自動名稱：沒有手動名稱時，它是 focused tab 的任務名稱，會顯示成另一個 tab 的任務。
@MainActor
func workspaceName(_ e: NotificationEntry, in model: AppModel) -> String {
    let pane = sourcePane(e, in: model)
    let ws = pane?.workspace ?? model.workspaces.first { $0.id == e.workspaceID }
    if let ws, let custom = ws.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
        return ws.title
    }
    if let cwd = pane?.cwd, !cwd.isEmpty {
        let folder = (cwd as NSString).lastPathComponent
        if !folder.isEmpty { return folder }
    }
    return e.title
}

/// 去掉訊息開頭的 Markdown 標記（`#`、`*`、`-`、`>`）與空白，以及成對的 `**`。
// ponytail: 只處理開頭與 `**`；訊息若真的以 "-" 開頭（例如 "-1 failed"）也會被拿掉，需要時再改成只拿掉 "- "。
func plainMessage(_ s: String) -> String {
    let t = s.replacingOccurrences(of: "**", with: "")
    return String(t.drop { "#*-> \t".contains($0) })
}
```

- [x] **Step 2: 改 `NotificationBar.swift`**

(a) 檔頭說明（第 9-11 行）改成：

```swift
/// sidebar 最底部的 bar，由上而下：可上下拖曳調整高度的拖曳帶、各個 plugin 的行（PluginHost）、
/// 摘要列（鈴鐺與未讀數，固定不捲動）、通知卡片清單（未讀在前、已讀在後，各自由新到舊）。
/// 點卡片會跳到該通知的 tab 並標成已讀。通知資料與鈴鐺清單相同（`AppModel.notifications`，最多 50 則，不保存）。
```

(b) `minHeight`（第 18-21 行）改成：

```swift
    /// 最小高度，也是沒拖過時的自動高度：拖曳帶 + 每個 plugin 一行（有 plugin 時再加一條分隔線）
    /// + 摘要列 + 一張完整的通知卡片（不拖拉也看得到第一張卡片）。
    static func minHeight(pluginRows: Int) -> CGFloat {
        handleHeight + rowHeight * CGFloat(pluginRows) + (pluginRows > 0 ? 1 : 0) + rowHeight + NotificationCard.maxHeight
    }
```

(c) 刪除整個 `notificationLine(_:in:)`（含上方註解）；`workspaceName` 已在 `NotificationCard.swift`。

(d) `NotificationList` 的 `body` 改成（摘要列固定在上面，卡片可捲動；第一張卡片換人時捲回最上面）：

```swift
    var body: some View {
        // 未讀在前、已讀在後，各自由新到舊。
        let ordered = model.notifications.filter { !$0.read } + model.notifications.filter(\.read)
        // ponytail: 「3m」這類時間只在通知變動或 sidebar 每分鐘的 tick（model.clock）時更新，閒置時不另外開計時器。
        let now = max(model.clock, Date())
        VStack(spacing: 0) {
            NotificationSummaryRow(model: model, host: host)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if ordered.isEmpty {
                            Text("No notifications")
                                .font(.system(size: 12))
                                .foregroundStyle(T.Colors.textTertiary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 32)
                                .frame(height: NotificationBarPlugin.rowHeight)
                        }
                        ForEach(ordered) { e in
                            NotificationCard(entry: e, model: model, age: Self.age(e.date, now: now)) {
                                controller.openNotification(e)
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                // 捲動過後來了新的未讀通知：捲回最上面，不必動滑鼠。
                .onChange(of: ordered.first?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }
```

(e) `NotificationSummaryRow` 整個換成：

```swift
/// 清單最上面一列：鈴鐺與未讀數。第一則通知在下方用卡片顯示。
struct NotificationSummaryRow: View {
    let model: AppModel
    let host: PluginHost?

    var body: some View {
        let unread = model.unreadNotifications
        HStack(spacing: 6) {
            Image(systemName: unread > 0 ? "bell.badge" : "bell")
                .font(.system(size: 11))
                .foregroundStyle((unread > 0 ? T.Colors.accent : T.Colors.textTertiary).color)
                .frame(width: 14)
            Spacer(minLength: 4)
            if unread > 0 {
                Text("\(unread)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(T.Colors.accent.color)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NotificationBarPlugin.rowHeight)
        .contentShape(Rectangle())
        .contextMenu { if let host { PluginMenuItems(host: host) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
    }
}
```

(f) 刪除整個 `struct NotificationListRow`（含上方註解）。

- [x] **Step 3: 編譯**

Run（沿用 Task 4 Step 2 的 `unset`／`export`，在 `App/`）：`swift build 2>&1 | grep -E "error|Build complete" | head -20`
Expected: `Build complete!`，沒有 `error`。

- [x] **Step 4: 確認沒有留下孤兒**

Run: `grep -n "NotificationListRow\|notificationLine\|shown: ordered" /Users/jamis.liao/opensource/lmux-sidebar-notification-bar/App/Sources/LmuxNotificationBar/*.swift`
Expected: 沒有輸出。

Run: `wc -l /Users/jamis.liao/opensource/lmux-sidebar-notification-bar/App/Sources/LmuxNotificationBar/NotificationCard.swift`
Expected: 小於 300。

- [x] **Step 5: Commit**（`bdb24cb`）

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add App/Sources/LmuxNotificationBar/NotificationCard.swift App/Sources/LmuxNotificationBar/NotificationBar.swift
git commit -m "$(cat <<'EOF'
通知 bar 的通知改成卡片：任務名稱、workspace、兩行訊息

一行顯示時訊息被截斷，看不出原本的任務。卡片第 1 行是 tab 的任務名稱與經過時間，
第 2 行是 workspace 名稱（手動名稱，否則工作目錄的資料夾名稱），其餘是訊息（最多 2 行）。
摘要列只留鈴鐺與未讀數並固定在上方；bar 最小高度放得下一張完整的卡片。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: 反白來自 focused tab 的通知卡片

**Files:**
- Modify: `App/Sources/LmuxNotificationBar/NotificationCard.swift`

**Interfaces:**
- Consumes: Task 5 的 `NotificationCard`；`AppModel.selected`（`App/Sources/LmuxUI/Model.swift:786`）、`Workspace.focusedPane`（`Model.swift:467`）。
- Produces: 無新介面。

- [x] **Step 1: 加上反白**

(a) `@State private var hover = false` 後面加：

```swift
    @Environment(\.controlActiveState) private var activeState
```

(b) `background` 換成（比照 `App/Sources/LmuxUI/Sidebar.swift:333-337` 的 `pillColor`）：

```swift
    /// 來自 focused tab：與 sidebar 選取列同色（視窗不在前景時用淡的那個）。反白時 hover 不改變底色。
    private var focused: Bool {
        entry.paneID != nil && entry.paneID == model.selected?.focusedPane?.id
    }

    private var background: Color {
        if focused { return (activeState == .inactive ? T.Colors.rowSelectedInactive : T.Colors.rowSelected).color }
        return hover ? T.Colors.rowHover.color : .clear
    }
```

(c) `.accessibilityAddTraits(.isButton)` 改成：

```swift
        .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
```

- [x] **Step 2: 編譯**

Run（在 `App/`）：`swift build 2>&1 | grep -E "error|Build complete" | head -10`
Expected: `Build complete!`

- [x] **Step 3: Commit**（`4da043e`）

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add App/Sources/LmuxNotificationBar/NotificationCard.swift
git commit -m "$(cat <<'EOF'
通知卡片反白來自 focused tab 的通知

底色與 sidebar 選取列相同，視窗不在前景時變淡。同一個 workspace 的其他 tab 不反白。

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: 跑全部自動測試

**Files:**
- Create（repo 外）: `/private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/apptest-feature.sh`
- 不改程式碼（發現問題就回到對應的 Task 修）

**Interfaces:**
- Consumes: Task 0-6 的成果。
- Produces: Core 全部測試與 apptest `--quick` 的結果，和已知失敗的比對。

- [ ] **Step 1: Core 全部測試**

Run:
```bash
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/usr/bin:$PATH"
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar/Core
swift test 2>&1 | tail -10
```
Expected: 全部 PASS（不加 `--filter`）。

- [ ] **Step 2: 建立 apptest 腳本（含看門狗）**

建立 `/private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/apptest-feature.sh`：

```bash
#!/bin/bash
# 在目前的 branch 跑 apptest --quick。看門狗：任何一個 lmux-apptest 程序跑超過 8 分鐘就停掉（主要測試階段曾卡住 2.5 小時）。
set -uo pipefail
WT=/Users/jamis.liao/opensource/lmux-sidebar-notification-bar
S=/private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad
LOG="$S/apptest-feature.log"
cd "$WT" || exit 1
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="$S/swift-native:/usr/bin:$PATH"
bash App/scripts/apptest.sh --quick > "$LOG" 2>&1 &
RUN=$!
declare -a SEEN_PID SEEN_AT
while kill -0 "$RUN" 2>/dev/null; do
  for pid in $(pgrep -x lmux-apptest); do
    found=-1
    for i in "${!SEEN_PID[@]}"; do [ "${SEEN_PID[$i]}" = "$pid" ] && found=$i; done
    if [ "$found" -lt 0 ]; then
      SEEN_PID+=("$pid"); SEEN_AT+=("$(date +%s)")
    elif [ $(( $(date +%s) - SEEN_AT[found] )) -gt 480 ]; then
      echo "watchdog: lmux-apptest pid $pid 超過 8 分鐘，停掉" >> "$LOG"
      kill "$pid"
    fi
  done
  sleep 15
done
wait "$RUN"; echo "apptest exit=$?" >> "$LOG"
```

- [ ] **Step 3: 跑 apptest（背景執行）**

Run（背景）：`bash /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/apptest-feature.sh`

跑完後 Run：`grep "^FAIL\|RESULT\|watchdog\|apptest exit" /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/apptest-feature.log`

Expected: 只有已知的失敗（在原始程式碼 264eaaa 上也會出現，見 decisions TSV 2026-11-12T14:45 的檢查點）：
- `[tabs] the strip's background follows a switch to light`
- `[settings window] first open: the current theme is selected`
- idle CPU 類（例如 `[esc idle] idle CPU < 1%`，數值每次不同）
- `[hygiene]`（`~/.zsh_history` 變動、測試視窗出現）
- 主要測試階段在 `Tests.swift:741` 之後卡住、被看門狗停掉

其他 `FAIL`（特別是 hooks、agents、notifications、status 相關）→ 停下來，回到對應的 Task 修。

---

### Task 8: build lmux.app，手動確認（controller 執行）

**Files:**
- Create: `beat/changes/notification-cards-and-compaction-state/manual-verification.md`
- Modify: `beat/changes/notification-cards-and-compaction-state/features/*.feature`（`@e2e` 場景加 `# @covered-by: manual`）

**Interfaces:**
- Consumes: Task 2-7 的成果。
- Produces: `App/build/lmux.app`；手動驗證紀錄。

- [ ] **Step 1: 確認 swift 包裝腳本存在**

Run: `ls -l /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/swift-native/swift`

不存在時，在同一個路徑建立（`chmod 755`）：

```sh
#!/bin/sh
if [ "$1" = "build" ]; then
  shift
  exec /usr/bin/swift build --build-system native "$@"
fi
exec /usr/bin/swift "$@"
```

- [ ] **Step 2: 請使用者關掉測試版 lmux**

告訴使用者：
1. 在測試版 lmux 視窗按 ⌘Q。
2. 接下來 build 的期間，正在用的 lmux 收不到 Claude 狀態（hook 指向 `App/build/lmux.app`）。
3. 在 Step 9 之前，正式版 lmux 若跳出「更新 hook」，按 Not Now（按下去會在測試中途移除壓縮事件）。

確認已結束：
Run: `ps -axo pid=,comm= | grep "lmux-sidebar-notification-bar/App/build/lmux.app" | grep -v grep`
Expected: 沒有輸出。

- [ ] **Step 3: build lmux.app**

Run:
```bash
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/swift-native:/usr/bin:$PATH"
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
bash App/scripts/bundle.sh 2>&1 | tail -5
codesign --verify --deep App/build/lmux.app && echo codesign-ok
```
Expected: bundle.sh 成功（SDK 檢查通過）；`codesign-ok`。

- [ ] **Step 4: 開測試版，安裝 hook**

Run: `bash /private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/open-app-real.sh`
記下輸出的 state 目錄（Step 6 第 11 項要用）。

腳本不存在時，用下面的內容在同一個路徑重建（複製正在用的 lmux 的設定到新的 state 目錄；Claude 用真的 `~/.claude`；不取代 `/Applications/lmux.app`）：

```bash
#!/bin/bash
set -uo pipefail
WT=/Users/jamis.liao/opensource/lmux-sidebar-notification-bar
EXE="$WT/App/build/lmux.app/Contents/MacOS/lmux"
REAL="$HOME/Library/Application Support/lmux"
T=/private/tmp/claude-502/-Users-jamis-liao-opensource-lmux/b98536bc-aa23-4a4d-ab6c-87cbf62abe9a/scratchpad/manual
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
RUNNING=$(pgrep -f "$EXE")
if [ -n "$RUNNING" ]; then
  echo "已經有測試版 lmux 在跑（pid ${RUNNING}），請先在那個視窗按 ⌘Q。"
  exit 0
fi
NEW="$T/state-real-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$NEW" && chmod 700 "$NEW"
cp -p "$REAL/settings.plist" "$REAL/layout.json" "$NEW/" || exit 1
sqlite3 "$REAL/sessions.db" ".backup '$NEW/sessions.db'" || exit 1
cp -R "$REAL/archive" "$NEW/archive" || exit 1
mkdir -p "$T/plugins/example" "$T/codex" "$T/cmux"
cp "$WT/App/scripts/example-plugin/run" "$T/plugins/example/run"
chmod 700 "$T/plugins/example/run"
[ -f "$HOME/.config/lmux/config" ] && cp "$HOME/.config/lmux/config" "$T/config"
export LMUX_STATE_DIR="$NEW" LMUX_PLUGIN_DIR="$T/plugins" LMUX_CONFIG_FILE="$T/config" \
       LMUX_CMUX_HOME="$T/cmux" CODEX_HOME="$T/codex" LMUX_CODEX_HOME="$T/codex"
nohup "$EXE" >"$T/lmux-app.log" 2>&1 &
echo "測試版 lmux.app 已啟動（pid $!），state 目錄：${NEW}"
```

請使用者在測試版：Settings → Hooks。畫面會顯示 "Not installed" 與 **Install** 按鈕（舊安裝少了 2 個事件）。按 Install，看 diff 有 `PreCompact` 與 `PostCompact`，再按確認。然後確認：

Run: `/Users/jamis.liao/opensource/lmux-sidebar-notification-bar/App/build/lmux.app/Contents/Resources/bin/lmux-hook status; echo "exit=$?"`
Expected: `missing:   -`，`command:` 指向 `App/build/lmux.app` 的 lmux-hook，`exit=0`（不完整時 exit 是 3）。

- [ ] **Step 5: 使用者手動確認壓縮（在測試版開新的 tab，執行全新的 `claude`；不要用從版面還原的 session，它們也在正式版裡跑）**

1. 送一個會用到 Bash 的 prompt（例如 `執行 ls`），等回合完成（✓）。
2. 打 `/compact`。確認：workspace 列在壓縮期間顯示轉圈；第 2 行是 `Compacting`，不是 `Bash · ls`。
3. 壓縮完成後確認：回到 ✓；鈴鐺清單、通知 bar、macOS 通知中心都沒有新的通知。
4. 打 `/exit`，執行 `claude --continue`，直接打 `/compact`。確認壓縮期間轉圈、結束後回到閒置（沒有 ✓）。
5. 再打 `/compact`，馬上按 Esc。確認 tab 回到閒置；如果一直轉圈，記下多久之後才停。
6. 確認正式版 lmux 裡其他 tab 的狀態沒有異常。

- [ ] **Step 6: 使用者手動確認通知卡片**

前置：通知 bar 拉高到看得到 3 張以上卡片（第 6、7 項除外）；準備一個沒有手動名稱、有 2 個 Claude tab 的 workspace，以及一個手動命名的 workspace。依序確認：

1. 剛開測試版、還沒有任何通知：摘要列只有鈴鐺，下方顯示 "No notifications"（文字與卡片文字左緣對齊）。
2. 卡片：第 1 行任務名稱＋時間；第 2 行是工作目錄的資料夾名稱；訊息最多 2 行，超過有 `…`；未讀的字比較粗、有圓點。
3. 手動命名的 workspace 送的通知：第 2 行是手動名稱。
4. 同一個 workspace 的 tab A（focus 中）與 tab B：tab B 的卡片第 1 行是 tab B 的任務名稱，卡片上沒有 tab A 的任務名稱。
5. 任務名稱與資料夾名稱相同時：卡片只顯示一次。
6. 讓 Claude 回覆以 `## 結論` 開頭（例如 prompt：`第一行只寫 ## 結論，然後說 hi`）：卡片訊息是 `結論`。
7. 沒有任務名稱的 tab：開一個一般 shell tab，執行 `lmux notify hi`：第 1 行是 workspace 名稱，沒有第 2 行。
8. 關掉送過通知的 tab：卡片仍在，第 1 行是 workspace 名稱。
9. 關掉整個 workspace：卡片第 1 行是通知當時的 workspace 名稱。
10. tab 裡打 `/clear`，再送一個 prompt 讓 Claude 取新標題：舊卡片第 1 行變成新的任務名稱。
11. 雙擊 bar 上緣恢復最小高度。讓一個**不是 focus 中**的 tab 送出中文、長到要兩行的通知：摘要列顯示未讀數；下方完整顯示這張卡片，最後一行沒被切掉。（測完再把 bar 拖回原本的高度。）
12. bar 拉高、清單往下捲之後，讓一個不是 focus 中的 tab 送出通知：清單自動捲回最上面；摘要列一直固定在上方。
13. 同一個 workspace 的 tab A、tab B 都有通知：focus tab A 時只有 A 的卡片反白；滑鼠移到反白的卡片上，底色不變。
14. 改 focus 另一個 workspace 的 tab C：反白移到 C 的卡片。
15. 切到其他 App：反白的顏色與 sidebar 選取列「不在前景」時的顏色相同。
16. 在 Terminal.app（不是 lmux）執行：
    ```bash
    export LMUX_STATE_DIR=<Step 4 記下的 state 目錄>
    /Users/jamis.liao/opensource/lmux-sidebar-notification-bar/App/build/lmux.app/Contents/Resources/bin/lmux notify hi
    ```
    這張卡片不反白。
17. 點擊一張卡片：跳到它的 tab，卡片反白。
18. 回歸：⇧⌘U 跳到最新未讀、鈴鐺彈出清單照常。

- [ ] **Step 7: 寫手動驗證紀錄並標註場景**

建立 `beat/changes/notification-cards-and-compaction-state/manual-verification.md`：

```markdown
# 手動驗證紀錄

- 日期：（填入）
- lmux.app commit：（`git rev-parse --short HEAD`）
- Claude Code 版本：（`claude --version`）

| feature | 場景 | Task 8 項目 | 結果 | 備註 |
|---|---|---|---|---|
| compaction-running-state | 壓縮期間 workspace 列第 2 行顯示 Compacting | Step 5-2 | | |
| compaction-running-state | 已完成的 tab 開始壓縮時顯示進行中（實機） | Step 5-2 | | |
| compaction-running-state | 壓縮結束後回到完成，不發通知（實機） | Step 5-3 | | |
| compaction-running-state | 閒置的 tab 壓縮結束後回到閒置（實機） | Step 5-4 | | |
| compaction-running-state | 壓縮期間使用者按 Esc 中斷（實機） | Step 5-5 | | |
| notification-cards | 通知卡片顯示任務名稱、workspace 名稱與訊息 | Step 6-2 | | |
| notification-cards | workspace 有手動名稱時，第 2 行用手動名稱 | Step 6-3 | | |
| notification-cards | 卡片不顯示同一個 workspace 裡另一個 tab 的任務名稱 | Step 6-4 | | |
| notification-cards | 第 2 行與第 1 行相同時不顯示 | Step 6-5 | | |
| notification-cards | 訊息開頭的 Markdown 符號不顯示 | Step 6-6 | | |
| notification-cards | 沒有任務名稱時，第 1 行改用 workspace 名稱 | Step 6-7 | | |
| notification-cards | tab 關閉後，卡片仍然顯示 | Step 6-8 | | |
| notification-cards | workspace 也關閉後，卡片用通知當時的 workspace 名稱 | Step 6-9 | | |
| notification-cards | tab 換了 session 後，卡片顯示新的任務名稱 | Step 6-10 | | |
| notification-cards | 通知 bar 在最小高度時也看得到最新一則未讀通知 | Step 6-11 | | |
| notification-cards | 清單捲動過後收到新的未讀通知，清單回到最上面 | Step 6-12 | | |
| notification-cards | 沒有通知 | Step 6-1 | | |
| notification-cards | 只反白來自 focused tab 的通知卡片 | Step 6-13 | | |
| notification-cards | 換 focus 時，反白跟著移動 | Step 6-14 | | |
| notification-cards | lmux 視窗不在前景時，反白變淡 | Step 6-15 | | |
| notification-cards | 不是來自 tab 的通知不反白 | Step 6-16 | | |
| notification-cards | 點擊通知卡片跳到它的 tab | Step 6-17 | | |
```

依使用者回報填「結果」（通過／失敗）與備註。失敗的項目：回到對應的 Task 修，修完重做 Step 3-6 的相關項目。

每個 `@e2e` 場景在 tag 行與 `場景:` 之間加：

```gherkin
  # @covered-by: manual — beat/changes/notification-cards-and-compaction-state/manual-verification.md
```

把 Step 5-4、5-5 觀察到的結果（特別是 Esc）寫進 design.md「風險」。

- [ ] **Step 8: Commit**

```bash
cd /Users/jamis.liao/opensource/lmux-sidebar-notification-bar
git add beat/changes/notification-cards-and-compaction-state/
git commit -m "$(cat <<'EOF'
test(notification-cards-and-compaction-state): 手動驗證紀錄與場景標註

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 9: 提醒使用者把 hook 指回正式版**

測試結束後，請使用者依序做：
1. 在測試版按 ⌘Q。
2. 打開 `/Applications` 的 lmux。
3. Settings → Hooks → 按 Update。

提醒：
- 正式版按 Update 會移除 `PreCompact`／`PostCompact`（正式版不認得這 2 個事件）。
- 通知 bar 的最小高度變高了，bar 會比之前高約一張卡片；需要的話往下拖回來。
