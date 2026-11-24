# 右側 Inspector 原生問答面板與零 Token Session 上下文補充 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `lmux` 實作純原生 SwiftUI **待確認面板**、`lmux ask` 兩階段控制通道 CLI 與本機零 Token **Session 上下文補充**，並完整對齊 `ask-me` 契約與多 **workspace** 注意力通知系統。

**Architecture:** `Core/LmuxTranscript` 負責無 UI 依賴的 Claude/Codex 對話脈絡抽取（過濾 `<synthetic>`、補齊 Codex 異動檔）；`App/LmuxUI` 新增 `AskSpec`、`AskSessionStore`、`AskRefLoader`、`AskContextBuilder`、`AskMarkdownParser`、`InspectorAskCards` 與 `InspectorAskView`，透過 `ControlServer` 單行兩階段 RPC（`ask-create` 同步建立＋`ask-wait` 長連線等待）與 `lmux-cli` 通訊，並以 `Pane.hasPendingAsk` 整合 `needsInput`、`lmux wait` 與 **通知 bar**。

**Tech Stack:** Swift 5/6 (`Core/Package.swift`, `App/Package.swift`), XCTest, Swift Testing, AppKit, SwiftUI, Observation, Unix Domain Socket (`ControlServer`), `lmux-apptest`

## Global Constraints

- `App/Sources/LmuxTerminal` 與 `vendor/ghostty` 維持完全不變；`Core/Sources/LmuxHooks` 不內建 `AskUserQuestion` 攔截，維持 5 秒非阻塞旁聽原則（ADR-0005）。
- `Core/LmuxTranscript` 僅依賴 `LmuxPrivateFile`，不得 import `LmuxHooks` 或 `LmuxUI`。
- **待確認面板**全程純原生 SwiftUI，不建立 `WKWebView`、不掛載額外 `NSVisualEffectView`（ADR-0003）；`mermaid` 僅以可折疊等寬程式碼卡＋複製語法呈現，絕不覆蓋「即時預覽」原有檔案。
- `layout.json` 永遠不持久化暫時性的 `.ask` 分頁，僅保存 `lastNonAskInspectorTab`。
- 所有本機檔案與 Git 引用嚴格受限於來源 pane 的工作目錄／repo root（`O_NOFOLLOW | O_NONBLOCK`、`S_IFREG`、`512 KB` 上限、拒二進位 NUL 位元組、獨立 `nonisolated static` 硬化 git 執行器含 `filterOverrideEnv` 與 `--` 路徑分隔）。
- `control.sock` 強制執行 `LMUX_PANE_NONCE` 與 `allowCrossPaneSend` / `allowExternalSend` 權限隔離（`allowCrossPaneSend` 僅對持有效 pane token 者生效，外部呼叫者絕不可領取 pane 建立的 `ask-wait`），並拒絕 **預覽 tab**。
- 每個任務最多修改 2–3 個實作檔案、單一新檔不超過 ~300 行、採 TDD（先 RED 測試、再 GREEN 實作、驗證通過後提交）。

## Quality Principles

**Testing:** Tests verify behavior (return values, state changes, responses), not wiring.
If the main assertion is `toHaveBeenCalledWith`, rewrite to assert on the function's output.

**Code:** No single new file exceeds ~300 lines. If it grows past that, split into focused sub-modules.

---

### Task 1: Core 零 Token 對話脈絡抽取（`TranscriptContextExtractor` + `<synthetic>` 過濾 + Codex 異動檔）

**Files:**
- Create: `Core/Sources/LmuxTranscript/TranscriptContextExtractor.swift`
- Modify: `Core/Sources/LmuxTranscript/TranscriptIndex.swift:61-82,203-254,352-376`
- Modify: `Core/Sources/LmuxTranscript/CodexRollout.swift:233-260,342-380`
- Test: `Core/Tests/LmuxTranscriptTests/TranscriptContextExtractorTests.swift`

**Interfaces:**
- Produces (`LmuxTranscript`):
  - `public struct TranscriptTurnDigest: Sendable, Equatable { public var index: Int; public var promptSummary: String; public var replySummary: String? }`
  - `public struct TranscriptContextSummary: Sendable, Equatable { public var sessionTitle: String?; public var initialGoal: String?; public var recentTurns: [TranscriptTurnDigest]; public var touchedFiles: [String] }`
  - `public enum TranscriptContextExtractor { public static func extract(title: String?, turns: [TranscriptIndex.Turn], maxRecentTurns: Int = 3, maxFileTurns: Int = 5) -> TranscriptContextSummary }`
  - `TranscriptIndex.Turn`: `editedFiles` 與 `createdFiles` 於 Codex rollout 亦有值；`replyHead` 略過 `model == "<synthetic>"` 助理訊息。

- [x] **Step 1: 建立失敗單元測試（`Core/Tests/LmuxTranscriptTests/TranscriptContextExtractorTests.swift`）**

```swift
// @feature: inspector-ask-panel.feature
// @scenario: 從 Claude 與 Codex 對話紀錄本機抽取 Session 上下文補充
// @scenario: 對話紀錄缺少、含損毀行或合成佔位訊息時安全降級產生上下文補充
import XCTest
@testable import LmuxTranscript

final class TranscriptContextExtractorTests: XCTestCase {
    func testClaudeExtractionFiltersSyntheticAndCollectsGoalRecentTurnsAndFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lines = [
            #"{"type":"custom-title","customTitle":"修補驗證流程"}"#,
            #"{"type":"user","uuid":"u1","parentUuid":null,"turnOrigin":"human","message":{"role":"user","content":"請重構 AuthService 並補測試"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/repo/Auth.swift"}},{"type":"text","text":"已完成 AuthService 重構。"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","turnOrigin":"human","message":{"role":"user","content":"下一步要處理逾時重試嗎？"}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"id":"m2","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Local synthetic notice"}]}}"#,
            #"{"type":"assistant","corrupt":"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let idx = TranscriptIndex(url: tmp)
        _ = try idx.update()
        let summary = TranscriptContextExtractor.extract(title: idx.customTitle ?? idx.aiTitle, turns: idx.turns)

        XCTAssertEqual(summary.sessionTitle, "修補驗證流程")
        XCTAssertEqual(summary.initialGoal, "請重構 AuthService 並補測試")
        XCTAssertEqual(summary.touchedFiles, ["/repo/Auth.swift"])
        XCTAssertEqual(summary.recentTurns.count, 1)
        XCTAssertEqual(summary.recentTurns.first?.promptSummary, "下一步要處理逾時重試嗎？")
        XCTAssertNil(summary.recentTurns.first?.replySummary)
    }

    func testCodexRolloutExtractsPatchAndFunctionCallFilesAndEmptyFallback() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lines = [
            #"{"timestamp":"2026-11-24T01:00:00Z","type":"session_meta","payload":{"id":"c1","cwd":"/repo","model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-11-24T01:00:01Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_name":"Codex 修復"}}"#,
            #"{"timestamp":"2026-11-24T01:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"修改 Router.swift"}}"#,
            #"{"timestamp":"2026-11-24T01:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /repo/Router.swift\n@@\n-old\n+new\n*** Add File: /repo/Helper.swift\n+let x = 1\n*** End Patch"}}"#,
            #"{"timestamp":"2026-11-24T01:00:03.500Z","type":"response_item","payload":{"type":"function_call","name":"write_file","arguments":"{\"file_path\":\"/repo/Config.swift\"}"}}"#,
            #"{"timestamp":"2026-11-24T01:00:04Z","type":"event_msg","payload":{"type":"agent_message","message":"已更新 Router 與 Helper。"}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let rollout = CodexRollout(url: tmp)
        _ = try rollout.update()
        let summary = TranscriptContextExtractor.extract(title: rollout.threadName, turns: rollout.turns)

        XCTAssertEqual(summary.sessionTitle, "Codex 修復")
        XCTAssertEqual(summary.initialGoal, "修改 Router.swift")
        XCTAssertEqual(summary.touchedFiles, ["/repo/Router.swift", "/repo/Helper.swift", "/repo/Config.swift"])
        XCTAssertEqual(TranscriptContextExtractor.extract(title: nil, turns: []).recentTurns, [])
    }
}
```

- [x] **Step 2: 執行測試確認 RED**

Run: `swift test --package-path Core --filter TranscriptContextExtractorTests`
Expected: FAIL（`TranscriptContextExtractor` 尚未定義）

- [x] **Step 3: 實作 `TranscriptContextExtractor.swift`，並更新 `TranscriptIndex.swift` 與 `CodexRollout.swift`**

1. `TranscriptIndex.swift`：`Node` 新增 `var isSynthetic = false`（`message?["model"] as? String == "<synthetic>"`）；在 `computeTurns()` 產生 `replyHead` 時排除 `isSynthetic` 節點（保留 `hasText`/`replyLines` 維持 `TurnLocator` 不變）。
2. `CodexRollout.swift`：`Accumulator.Rec` 新增 `editedFiles`/`createdFiles`；解析 `response_item` 的 `apply_patch`（`*** Update File: ` / `*** Add File: `）與 `function_call` JSON 參數內的 `file_path`，填入 `indexTurns()`。
3. `TranscriptContextExtractor.swift`：對所有輸出字串欄位（`sessionTitle`、`initialGoal`、`recentTurns` 的 `promptSummary`/`replySummary`、`touchedFiles`）套用控制與雙向字元清理；`initialGoal` 限 200 字、`recentTurns` 取最新 `maxRecentTurns` 輪（排除重複首輪）、`touchedFiles` 取最近 `maxFileTurns` 輪去重上限 12 筆。

- [x] **Step 4: 執行測試確認 GREEN**

Run: `swift test --package-path Core --filter "TranscriptContextExtractorTests|AgentTelemetryTests|TranscriptIndexTests|CodexRolloutTests"`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 1**

```bash
git add Core/Sources/LmuxTranscript/TranscriptContextExtractor.swift Core/Sources/LmuxTranscript/TranscriptIndex.swift Core/Sources/LmuxTranscript/CodexRollout.swift Core/Tests/LmuxTranscriptTests/TranscriptContextExtractorTests.swift
git commit -m "feat(core): add zero-token TranscriptContextExtractor with synthetic filter and Codex file tracking"
```

---

### Task 2: `AskSpec` 正規化、防偷懶檢核與 `--inspector-ask` 測試入口註冊

**Files:**
- Create: `App/Sources/LmuxUI/AskSpec.swift`
- Create: `App/Sources/lmux-apptest/InspectorAskTests.swift`
- Modify: `App/Sources/lmux-apptest/main.swift:85-100`
- Modify: `App/scripts/apptest.sh`（立即註冊 `--inspector-ask` 獨立分組，讓後續所有 Task 可直接以 `App/scripts/apptest.sh --inspector-ask` 驗證）

**Interfaces:**
- Produces (`LmuxUI`):
  - `public struct AskOption: Sendable, Equatable { public var label: String; public var description: String; public var recommended: Bool }`
  - `public struct AskQuestion: Sendable, Equatable, Identifiable { public var id: String; public var header: String; public var question: String; public var detail: String; public var mermaid: String?; public var multiSelect: Bool; public var allowFreeText: Bool; public var options: [AskOption]; public var refs: [String]; public var gitDiff: [String] }`
  - `public struct AskSpec: Sendable, Equatable { public var title: String; public var eyebrow: String; public var intro: String; public var questions: [AskQuestion]; public var lenient: Bool; public static func parse(jsonObject: [String: Any], lenient: Bool = false) throws -> AskSpec }`
  - `public struct AskAnswer: Sendable, Equatable { public var id: String; public var header: String; public var question: String; public var selected: [String]; public var freeText: String; public func toJSONObject() -> [String: Any] }`
  - `public enum AskSpecError: Error, Equatable, CustomStringConvertible`

- [x] **Step 1: 建立 `InspectorAskTests.swift`（含 `// @feature: inspector-ask-panel.feature` 標頭）並註冊 `--inspector-ask`**

測試涵蓋：
- 字串簡寫選項 `["方案 A (Recommended)", "方案 B（推薦）"]` 自動剝除後綴且設 `recommended == true`；
- 嚴格模式拒絕 `intro < 25` 字、含選項題目 `detail < 20` 字、重複 `question.id`、單題重複正規化 `option.label`、0 題或 >12 題、以及 `refs` 或 `gitDiff` 單題超過 8 筆（明確拒絕不靜默裁切）；
- `lenient: true` 允許短 `intro` 與空 `detail`（仍要求 `intro` 與 `question` 非空）；
- 針對 `title`/`eyebrow`/`intro`/`detail`/`option.label` 清理不安全控制／BiDi 字元（`PreviewTarget.replacingUnsafeScalars`）；
- `AskAnswer.toJSONObject()` 固定輸出 `header: ""` 與 `freeText: ""`。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL（`AskSpec` 尚未定義）

- [x] **Step 3: 實作 `App/Sources/LmuxUI/AskSpec.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 2**

```bash
git add App/Sources/LmuxUI/AskSpec.swift App/Sources/lmux-apptest/InspectorAskTests.swift App/Sources/lmux-apptest/main.swift App/scripts/apptest.sh
git commit -m "feat(ui): add AskSpec parser with ask-me parity and register --inspector-ask harness"
```

---

### Task 3: `AskSessionStore` 狀態機、Per-Pane FIFO 佇列、上限保護與 10 分鐘答案快取

**Files:**
- Create: `App/Sources/LmuxUI/AskSessionStore.swift`
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `AskSpec`, `AskAnswer`, `TranscriptContextSummary` (`LmuxTranscript`), `ToolCallEntry` (`LmuxHooks`), `GitDiffLine` (`LmuxUI`)
- Produces (`LmuxUI`):
  - `public struct AskFileRefResult: Sendable, Equatable, Identifiable`、`public struct AskGitDiffRefResult: Sendable, Equatable, Identifiable`、`public struct AskSessionContext: Sendable, Equatable`（統一定義於此或 `AskSessionModels.swift`，供 Task 4/5/11/12 直接共用，不回頭改未列檔案）
  - `@MainActor @Observable public final class AskSession: Identifiable`（含 `id`, `paneID`, `createdInsidePane`, `spec`, `context: AskSessionContext?`, `isLoadingContext: Bool`, `loadedFileRefs: [String: [AskFileRefResult]]`, `loadedGitDiffs: [String: [AskGitDiffRefResult]]`, `draftSelected: [String: [String]]`, `draftFreeText: [String: String]`, `isAllAnswered: Bool`, `answeredCount: Int`, `firstUnansweredQuestionID: String?`）
  - `@MainActor @Observable public final class AskSessionStore`：
    - `static let maxPendingPerPane = 16`, `static let maxPendingGlobal = 64`, `static let cacheTTL: TimeInterval = 600`, `static let maxCachedOutcomes = 32`
    - `create(spec:paneID:createdInsidePane:sessionID:) throws -> AskSession`（超過上限時 fail-closed 拋錯）
    - `attachWaiter(sessionID:reply:) -> (() -> Void)?`（檢查快取、supersede 舊 waiter 回傳 error 關閉、斷線僅 detach 不刪表單）
    - `submit(sessionID:) -> Bool`、`cancel(sessionID:)`、`markPaneClosed(_ paneID:)`、`markAllLost()`
    - `activeSession(for paneID:) -> AskSession?`、`pendingCount(for paneID:) -> Int`、`session(id:) -> AskSession?`

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上 `AskSessionStore` 狀態機與容量上限測試**

涵蓋：同 pane FIFO 不覆蓋草稿；未全題作答 `submit` 回 `false` 與 `firstUnansweredQuestionID`；無 waiter 先 `submit` 後由 `attachWaiter` 自快取領回並清除；重複 `attachWaiter` 乾淨 supersede 舊 waiter；`cancel`（含 `note`）、`markPaneClosed` 與 `markAllLost()`（回 `lost` 含 `note`）；快取 10 分鐘過期（注入 `now`）與 32 筆淘汰；超過單 pane 16 筆／全域 64 筆上限 fail-closed 拒絕。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `App/Sources/LmuxUI/AskSessionStore.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 3**

```bash
git add App/Sources/LmuxUI/AskSessionStore.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): add AskSessionStore state machine, FIFO queue, capacity caps, and outcome cache"
```

---

### Task 4: `AskRefLoader` 安全本機讀檔／獨立硬化 Git 執行器與 `PreviewTarget` 純文字白名單

**Files:**
- Create: `App/Sources/LmuxUI/AskRefLoader.swift`
- Modify: `App/Sources/LmuxUI/GitDiffService.swift:95-260,390-465`（抽出 `nonisolated static` 無狀態硬化執行器 `runGitHardened`、`filterOverrideEnv`、`emptyTreeHash`，不依賴 `@MainActor` `currentGeneration`；於 `readUntrackedLines` 補上 `!data.contains(0)` NUL 位元組檢查）
- Modify: `App/Sources/LmuxUI/PreviewTarget.swift:11-23`（新增常見無副檔名／純文字檔名白名單如 `Makefile`、`Dockerfile`、`.toml`、`.feature`、`.mjs`）
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `AskFileRefResult`, `AskGitDiffRefResult`, `GitDiffParser`, `PreviewTarget`
- Produces (`LmuxUI`):
  - `GitDiffService.runGitHardened(...)`、`GitDiffService.buildFilterOverrideEnv(in:)`、`GitDiffService.emptyTreeHash(in:)`（皆為 `nonisolated static`，可安全與 UI `GitDiffService.refresh` 併發執行）
  - `public enum AskRefLoader { public static func loadFileRef(_ raw: String, baseDir: String?, repoRoot: String?) -> AskFileRefResult; public static func loadGitDiff(_ relPath: String, cwd: String?) async -> AskGitDiffRefResult }`

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上帶 `// @feature: inspector-ask-panel.feature` 與 `// @scenario: 本機檔案與 Git 引用越界、指向危險／二進位檔案或新倉庫未追蹤檔時安全處理` 測試**

涵蓋：
- `loadFileRef`：合法相對路徑＋行號 `src/App.swift:2-4`（含超過 120 行自動截斷與含冒號檔名處理）；拒絕 `../outside.txt`、symlink 逃逸、目錄（`S_IFDIR`）、FIFO（`mkfifo`）、超過 `512 KB` 大檔、含 NUL 位元組（有效 UTF-8 內嵌 `\0`）二進位檔、`file://` 與 `baseDir == nil`；
- `loadGitDiff`：拒絕 `-` 開頭旗標注入（如 `--output=/tmp/pwned`）、`../` 遍歷、絕對路徑、不安全控制字元；必定使用 `--` 分隔符；含惡意 `filter.evil.clean` 之 repo 不執行 filter；無初始 commit（unborn `HEAD`）倉庫中的未追蹤純文字新檔正確產出新增行；
- `PreviewTarget.kind` 接受 `Makefile`、`Dockerfile`、`spec.feature`、`Cargo.toml`。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `AskRefLoader.swift`（明確落實 `O_NOFOLLOW | O_NONBLOCK`、`fstat` `S_IFREG`、`512 KB` 上限、`!data.contains(0)`、120 行上限）並抽出 `GitDiffService` `nonisolated static` 硬化方法與更新 `PreviewTarget.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask && App/scripts/apptest.sh --liquid-glass`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 4**

```bash
git add App/Sources/LmuxUI/AskRefLoader.swift App/Sources/LmuxUI/GitDiffService.swift App/Sources/LmuxUI/PreviewTarget.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): add hardened AskRefLoader with static Git filter isolation and O_NOFOLLOW containment"
```

---

### Task 5: `AskContextBuilder` 組裝零 Token Session 上下文補充（per-cwd Git 隔離）

**Files:**
- Create: `App/Sources/LmuxUI/AskContextBuilder.swift`
- Modify: `App/Sources/LmuxUI/MessageActions.swift:91-122`（提供 `snapshot(pane:path:withCodexTitle:)` 參數）
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `TranscriptContextExtractor`, `TranscriptCache`, `ToolCallStream`, `GitDiffService.runGitHardened`, `AskSessionContext`
- Produces (`LmuxUI`):
  - `enum AskContextBuilder { @MainActor static func build(for pane: Pane, transcripts: TranscriptCache, activeGitSnapshot: GitDiffSnapshot?) async -> AskSessionContext }`

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上帶 `// @scenario: 從 Claude 與 Codex 對話紀錄本機抽取 Session 上下文補充` 與降級場景測試**

涵蓋：
- 從臨時 Claude JSONL 與 Codex Rollout（含 `session_index.jsonl`）經 `TranscriptCache` 組出 `AskSessionContext`（含最近 5 筆工具）；
- 背景 **workspace** B 位於 Repo B 而全域 `activeGitSnapshot` 指向 Repo A 時，驗證回傳 Repo B 分支與變更數，絕不混入 Repo A；
- 非 Git 目錄與無 `transcriptPath` 之純 shell tab 安全降級不報錯。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `App/Sources/LmuxUI/AskContextBuilder.swift` 與 `MessageActions.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 5**

```bash
git add App/Sources/LmuxUI/AskContextBuilder.swift App/Sources/LmuxUI/MessageActions.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): add AskContextBuilder with TranscriptCache, ToolCallStream, and per-cwd Git isolation"
```

---

### Task 6: 伺服器端兩階段 Socket RPC（`ask-create` / `ask-wait`）與嚴格租戶驗權

**Files:**
- Create: `App/Sources/LmuxUI/AskControl.swift`
- Modify: `App/Sources/LmuxUI/ControlServer.swift:22-35,235-260,275-372`
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `AskSpec`, `AskSessionStore`, `AskContextBuilder`, `AskRefLoader`, `LmuxController.randomToken()`
- Produces (`LmuxUI`):
  - `ControlServer.handleAskWait: (([String: Any], @escaping ([String: Any]) -> Void) -> () -> Void)?`
  - `LmuxController.handleAskCreate(_ req: [String: Any]) -> [String: Any]`、`LmuxController.startAskWait(_ req: [String: Any], reply: @escaping ([String: Any]) -> Void) -> () -> Void`

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上伺服器端 RPC 與完整安全驗權測試**

涵蓋：
- 合法 `LMUX_PANE_NONCE` 呼叫 `ask-create` 回傳 32 字元 hex（128-bit）`sessionId`，隨後 `ask-wait` 收到送出結果；
- 偽造 token（`ask-create` 與 `ask-wait`）、跨 pane 無 `allowCrossPaneSend`、外部無 `allowExternalSend`、於 pane A 內剝除 token 靠 `peerPID` 跨區偽造目標 pane B（即使 `allowExternalSend == true`）、指定 **預覽 tab** 皆拒絕；
- `allowCrossPaneSend == true` 但無有效 pane token 的外部呼叫端仍**不可**領取 `createdInsidePane == true` 的 `ask-wait`；外部呼叫端（即使 `allowExternalSend == true`）亦不可偷領 `createdInsidePane == true` 的 `ask-wait`；
- 正向授權測試（`allowCrossPaneSend == true` 持有效他 pane token、`allowExternalSend == true` 外部建外部等）；
- 未知 `sessionId` 回傳一致不洩漏存在性的錯誤訊息；
- `ControlServer.stop()` 觸發等待連線收到 `gone: true`。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `AskControl.swift` 與 `ControlServer.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 6**

```bash
git add App/Sources/LmuxUI/AskControl.swift App/Sources/LmuxUI/ControlServer.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): add ask-create/ask-wait ControlServer RPCs with strict pane-nonce tenant isolation"
```

---

### Task 7: `lmux ask` CLI 子命令與 `connectAndSend` 大型請求迴圈寫入修復

**Files:**
- Modify: `App/Sources/lmux-cli/main.swift:19-30,96-148,205-248`
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `ask-create` / `ask-wait` Socket RPC
- Produces (`lmux-cli`):
  - `lmux ask --spec <path|-> [--timeout <secs>] [--pane <id>] [--lenient]`
  - `lmux ask --wait <sessionId> [--timeout <secs>]`
  - `connectAndSend` 迴圈寫入完整位元組（防 8KB `AF_UNIX` 截斷）；`--spec` 檔案以 `O_NONBLOCK` + `S_IFREG` 與 `1 MB` 上限安全讀取；`ask(_:)` 明確對 `ask-create` 與 `ask-wait` 皆附上 `LMUX_PANE_NONCE`/`LMUX_PANE_TOKEN`；`--timeout` 檢核 `> 0 && <= 3600`（拒絕 `NaN`/`Inf`/`<= 0` 回 exit `2`）。

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上真實 `lmux` binary CLI 測試（對應 Scenarios 3, 4, 5）**

涵蓋：
- `--spec <file>`（含 >16KB 大型 spec 驗證迴圈寫入）與 `--spec -`（stdin 輸入）；
- `--timeout 0.2` 逾時印出 `status: "pending"`、`sessionId`、`resume: "lmux ask --wait <id>"`（exit `0`），送出後以 `--wait <id>` 領回 `submitted` JSON 且不重複開表單（`pendingCount == 0`）；
- CLI 端收到 `gone: true` 轉印 `status: "lost"` 含 `note`（exit `0`）；
- 非法規格（`intro < 25`、重複 `id`、損毀 JSON）回 stderr + exit `1`；無效旗標／負 timeout／`NaN` 回 exit `2`。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `App/Sources/lmux-cli/main.swift` 的迴圈寫入與 `ask(_:)`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 7**

```bash
git add App/Sources/lmux-cli/main.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(cli): implement lmux ask --spec/--wait and fix looped socket writes in lmux-cli"
```

---

### Task 8: 多工作區注意力連動（`Pane.hasPendingAsk`、`lmux wait` 與 **通知 bar**）

**Files:**
- Modify: `App/Sources/LmuxUI/Model.swift:98-120,255-315`
- Modify: `App/Sources/LmuxUI/Controller.swift:190-215,705-720,1295-1315`
- Modify: `App/Sources/LmuxUI/Notifications.swift:85-115`
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `AskSessionStore`
- Produces (`LmuxUI`):
  - `Pane.hasPendingAsk: Bool`（`didSet` 觸發 `agentStateChanged()`）、`Pane.pendingAskTitle: String?`
  - `Pane.display`：`hasPendingAsk` 優先序高於 `.running`，回傳 `.needsInput(pendingAskTitle ?? "待確認")`
  - `Pane.needsInput`：`hasPendingAsk || (agent.state is .needsInput)`（`Controller.userTyped` 絕不清除 `hasPendingAsk`）
  - 背景 tab 建立提問時發送 **通知卡片**（不打斷前景 workspace A），關閉 tab 時呼叫 `askStore.markPaneClosed(pane.id)`。

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上注意力、通知與 `lmux wait` 測試**

涵蓋：背景執行中的 workspace B 發起提問時，前景 workspace A 維持選取不被打斷、workspace B 與該 tab 轉為需確認（覆蓋 `.running`）、`lmux wait <pane> --until needs-you` 被喚醒、**通知 bar** 新增對應 **通知卡片**、在終端機打字（`userTyped`）不清除 `hasPendingAsk`、關閉來源 tab 觸發 `markPaneClosed`。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `Model.swift`、`Controller.swift` 與 `Notifications.swift` 注意力整合**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 8**

```bash
git add App/Sources/LmuxUI/Model.swift App/Sources/LmuxUI/Controller.swift App/Sources/LmuxUI/Notifications.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): integrate pending ask sessions with Pane.needsInput, lmux wait, and notifications"
```

---

### Task 9: `AskMarkdownParser` 分塊原生 Markdown 與紅綠 Diff 解析器

**Files:**
- Create: `App/Sources/LmuxUI/AskMarkdownParser.swift`
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `GitDiffParser` (`GitDiffLine`)
- Produces (`LmuxUI`):
  - `public enum AskMarkdownBlock: Sendable, Equatable { case heading(level: Int, text: String), paragraph(String), bulletItem(String), numberedItem(prefix: String, text: String), blockquote(String), codeBlock(language: String?, code: String), diffBlock([GitDiffLine]) }`
  - `public enum AskMarkdownParser { public static func parse(_ text: String) -> [AskMarkdownBlock] }`

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上 `AskMarkdownParser` 測試**

涵蓋：多段落與 `- ` / `1. ` 清單保留為獨立區塊、標題／引用區塊、` ```diff ` 轉 `diffBlock` 含 `.added`/`.removed`/`.hunkHeader`、一般 ` ```swift ` 轉 `codeBlock`、未閉合 fence 與空字串安全降級。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `App/Sources/LmuxUI/AskMarkdownParser.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 9**

```bash
git add App/Sources/LmuxUI/AskMarkdownParser.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): add block-level AskMarkdownParser with inline Markdown and unified diff support"
```

---

### Task 10: `InspectorTab.ask`、Persistence 保護、動態 4 頁籤與焦點同步（`syncInspectorForFocusedPane`）

**Files:**
- Modify: `App/Sources/LmuxUI/Model.swift:750-805`（新增 `InspectorTab.ask`、`lastNonAskInspectorTab`、`inspectorAutoOpenedByAsk`）
- Modify: `App/Sources/LmuxUI/Persistence.swift:14-40,180-190,260-275`（絕不持久化 `.ask`，解碼 `"ask"` 降級為 `.preview`）
- Modify: `App/Sources/LmuxUI/RightInspectorView.swift:91-225`（動態顯示第 4 頁籤含未答徽章、`< 340pt` 或 4 頁籤緊湊標籤 `待確認`/`預覽`/`Diff`/`記錄` 並收斂非選中圖示）
- Modify: `App/Sources/LmuxUI/Controller.swift:765-795,865-890,1125-1145`（新增 `syncInspectorForFocusedPane()` 涵蓋 `select`、`focus`、`activePaneDidChange`、`openNotification` 與 `onActivate`）
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `AskSessionStore`, `Pane.hasPendingAsk`
- Produces (`LmuxUI`):
  - `InspectorTab.ask`、`AppModel.lastNonAskInspectorTab`、`AppModel.inspectorAutoOpenedByAsk`
  - `Controller.syncInspectorForFocusedPane()`（自動切換 `.ask`／退回 `lastNonAskInspectorTab`／若為自動展開則還原收合、切換 tab 時清掉殘留 `NSText` 焦點）

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上動態頁籤、自動展開／收合還原與 Persistence 測試**

涵蓋：
- 無 pending ask 時維持 3 頁籤相容；有 pending ask 時動態出現 `.ask` 並顯示未答徽章與緊湊標籤；
- 原先收合時因 ask 自動展開（`inspectorAutoOpenedByAsk == true`），送出／取消或切至無 ask 的 Tab C 時自動還原原分頁並收合；
- `snapshotLayout()` 停在 `.ask` 時寫出 `lastNonAskInspectorTab`；舊檔含 `"inspectorTab": "ask"` 解碼降級為 `.preview`。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `Model.swift`、`Persistence.swift`、`RightInspectorView.swift` 與 `Controller.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask && App/scripts/apptest.sh --liquid-glass`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 10**

```bash
git add App/Sources/LmuxUI/Model.swift App/Sources/LmuxUI/Persistence.swift App/Sources/LmuxUI/RightInspectorView.swift App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): add dynamic InspectorTab.ask, persistence guard, compact 4-tab layout, and focus sync"
```

---

### Task 11: 原生內容子元件（`InspectorAskCards.swift`：上下文卡、分段 Markdown、Refs/Diff 與 Mermaid 複製卡）

**Files:**
- Create: `App/Sources/LmuxUI/InspectorAskCards.swift`（維持單檔 <= 300 行）
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `AskSessionContext`, `AskMarkdownParser`, `AskFileRefResult`, `AskGitDiffRefResult`, `GhosttyRuntime.openTerminalURL`, `LmuxTokens`
- Produces (`LmuxUI`):
  - `struct AskContextCardView: View`（`lenient == true || intro.count < 80` 預設展開，否則單行摘要可展開；無任何資料時乾淨略過空區塊）
  - `struct AskMarkdownBlocksView: View`（行內 `.inlineOnlyPreservingWhitespace`＋`.environment(\.openURL)` 必傳 `kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8` 並回傳 `.handled`）
  - `struct AskRefCardView: View`（顯示程式碼／紅綠 Diff 或安全降級錯誤訊息，點擊檔名呼叫 `onOpenPreview` 並對不支援預覽的檔案顯示友善提示）
  - `struct AskMermaidCardView: View`（可折疊等寬碼塊＋「複製語法」按鈕寫入 `NSPasteboard`，不觸發 WebView 或改動即時預覽）

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上卡片呈現與安全連結測試**

涵蓋：
- `AskContextCardView` 展開策略（`lenient` 或 `intro < 80` 預設展開；詳盡 `intro` 預設收合；空上下文安全隱藏）；
- `AskMarkdownBlocksView` 連結處理器阻擋 `javascript:`、`.app` 與無 scheme 連結且回傳 `.handled`；
- `AskRefCardView` 呈現越界錯誤訊息、點擊可預覽檔切入預覽、不支援檔顯示提示；
- `AskMermaidCardView` 複製語法至剪貼簿且不更動 `WorkspacePreviewCoordinator` 目前預覽檔。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `App/Sources/LmuxUI/InspectorAskCards.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 11**

```bash
git add App/Sources/LmuxUI/InspectorAskCards.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): add native InspectorAskCards for context, Markdown/Diff, refs, and Mermaid copy card"
```

---

### Task 12: 純原生 SwiftUI `InspectorAskView` 問答表單與 `RightInspectorView` 接線

**Files:**
- Create: `App/Sources/LmuxUI/InspectorAskView.swift`（維持單檔 <= 300 行）
- Modify: `App/Sources/LmuxUI/RightInspectorView.swift:180-225`（將 `.ask` 接至 `InspectorAskView`）
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `AskSession`, `AskSessionStore`, `InspectorAskCards`, `LmuxTokens`
- Produces (`LmuxUI`):
  - `public struct InspectorAskView: View`（含 `Presentation` 靜態模型、`1 / N` 多工作階段佇列頁首、題目快速跳轉 chip、`ScrollViewReader` 支援 `scrollToQuestionID`、單選／多選卡片含 `推薦` 徽章、多行 `freeText`、全題皆作答才啟用的送出鈕與取消鈕）

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上 `InspectorAskView` 表單狀態與渲染測試**

涵蓋：零 `WKWebView` 建立；`1 / N` 多工作階段顯示；未全題作答時送出停用與未答題數提示；勾選單／多選與填寫 `freeText` 後啟用送出；取消鈕與送出鈕正確更新 `AskSessionStore`。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `App/Sources/LmuxUI/InspectorAskView.swift` 並接入 `RightInspectorView.swift`**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 12**

```bash
git add App/Sources/LmuxUI/InspectorAskView.swift App/Sources/LmuxUI/RightInspectorView.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): build InspectorAskView form with FIFO header, option cards, and all-answered submit bar"
```

---

### Task 13: AppKit 焦點、選單快捷鍵（`⌘Z`/`⇧⌘Z`/`⌘X`/`⌘↩`）與窄視窗夾緊防護

**Files:**
- Modify: `App/Sources/LmuxUI/Menu.swift:67-82`（補齊 responder-chain `Undo` / `Redo` / `Cut` 並於 `NSText` 聚焦時停用 `Undo Send`）
- Modify: `App/Sources/LmuxUI/SidebarSelection.swift:160-185`（`validateMenuItem` 判斷 `window.firstResponder is NSText`）
- Modify: `App/Sources/LmuxUI/Controller.swift:865-890,1165-1190,1585-1620`（`LmuxWindow.performKeyEquivalent` 攔截 `⌘↩`＋數字鍵盤 Enter、`ensureFocus()` 限縮 `rightInspectorHost` 內 `NSText`、送出／取消／切分頁排程歸還 `focusCurrent()`）
- Modify: `App/Sources/LmuxUI/RootView.swift:295-330`（窄視窗優先夾緊寬度至 `240pt` 再隱藏，且隱藏 `rightInspectorHost` 時通知 `controller?.ensureFocus()`）
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`

**Interfaces:**
- Consumes: `AskSessionStore`, `InspectorAskView` (`scrollToQuestionID`)
- Produces:
  - `NSText` 編輯時實際執行 `⌘Z`/`⇧⌘Z`/`⌘X` 作用於草稿文字且不觸發 Claude Rewind；
  - `.ask` 可見且活躍時 `⌘↩`（含 keypad Enter）全題作答即送出、未答滿則提示音＋捲動至第一道未答題且絕不漏進 PTY；
  - 送出／取消／切分頁／`⌥⌘B` 收合／視窗縮窄自動隱藏時，鍵盤焦點一律歸還 `pane.surface`。

- [x] **Step 1: 在 `InspectorAskTests.swift` 補上完整 AppKit 焦點與快捷鍵測試**

涵蓋：
- 聚焦自由輸入框輸入文字後實際派發 `⌘Z`／`⇧⌘Z`／`⌘X`，驗證草稿文字復原／重做／剪下生效且 `validateMenuItem(Undo Send) == false`；
- 在 `SurfaceView` 與 `NSText` 兩種焦點狀態下分別按下 `⌘↩`：有未答題目時設定 `scrollToQuestionID` 為第一道未答題且終端機 sink 收不到位元組；全題作答後按 `⌘↩` 完成送出且終端機 sink 仍不收位元組；
- 聚焦輸入框時執行：送出、取消、切至 `.diff`、切至無 ask 的 Tab C、按 `⌥⌘B` 收合、以及視窗縮窄至隱藏右側欄，驗證每一條路徑皆將 `window.firstResponder` 歸還給 `pane.surface`。

- [x] **Step 2: 執行測試確認 RED**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: FAIL

- [x] **Step 3: 實作 `Menu.swift`、`SidebarSelection.swift`、`Controller.swift` 與 `RootView.swift` 防護**

- [x] **Step 4: 執行測試確認 GREEN**

Run: `App/scripts/apptest.sh --inspector-ask`
Expected: PASS

- [x] **Step 5: 提交 Task 13**

```bash
git add App/Sources/LmuxUI/Menu.swift App/Sources/LmuxUI/SidebarSelection.swift App/Sources/LmuxUI/Controller.swift App/Sources/LmuxUI/RootView.swift App/Sources/lmux-apptest/InspectorAskTests.swift
git commit -m "feat(ui): guard NSText Undo/Redo/Cut, Cmd+Return PTY leak, narrow-window clamp, and focus return"
```

---

### Task 14: 端到端整合驗收、`skills/lmux/SKILL.md` 文件與全套回歸驗證

**Files:**
- Modify: `App/Sources/lmux-apptest/InspectorAskTests.swift`（補齊全鏈路 `@e2e` 整合驗收測試，串聯真實 `lmux ask --spec` -> 掛載 `InspectorAskView` -> UI 作答與 `⌘↩` -> stdout JSON -> `.ask` 隱藏與焦點歸還 -> 背景通知點擊切換）
- Modify: `skills/lmux/SKILL.md`（補充 `lmux ask --spec` / `--wait` / `refs` / `gitDiff` 用法說明）
- Modify: `App/scripts/apptest.sh`（將 `--inspector-ask` 納入 `--quick` 與完整主流程）

**Interfaces:**
- Consumes: Task 1–13 全部模組與 `lmux-cli` binary

- [ ] **Step 1: 在 `InspectorAskTests.swift` 補齊跨元件 `@e2e` 整合驗收（確保 Scenarios 3, 6, 8, 9 完整走過真實 CLI + 視窗 + 渲染 + 焦點）**

- [ ] **Step 2: 更新 `skills/lmux/SKILL.md` 與 `App/scripts/apptest.sh` 主流程註冊**

- [ ] **Step 3: 執行完整回歸測試套件**

Run: `swift test --package-path Core && App/scripts/apptest.sh --inspector-ask && App/scripts/apptest.sh --quick && beat/changes/preview-liquid-glass/dev.sh check`
Expected: ALL PASS（0 failures）

- [ ] **Step 4: 提交 Task 14**

```bash
git add App/Sources/lmux-apptest/InspectorAskTests.swift skills/lmux/SKILL.md App/scripts/apptest.sh
git commit -m "test(ask): add full E2E inspector-ask integration checks, update SKILL.md, and wire apptest"
```
