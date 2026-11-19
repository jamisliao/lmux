# Formal App 1:1 Apple Liquid Glass & Core Telemetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 將 `lmux` 正式 macOS App（`Core/` + `App/`）1:1 升級為對齊 `preview-mockup.html` 的雙主題 Apple Liquid Glass 三欄工作台（Unified 44pt Glass Titlebar、左側玻璃卡片清單＋搜尋＋通知 bar、中央圓角分割終端＋Pane Tab Strip、右側 320pt Inspector＋雙軌預覽、32pt 全寬底部狀態列），並補齊真實的 Agent 遙測與背景 Git Diff 管線。

**Architecture:** 在 `Core/LmuxTranscript` 與 `Core/LmuxHooks` 增量解析模型／Token／Cache／費用並維持 Hook 即時 Tool Call 環形串流（`docs/adr/0004`）；在 `App/LmuxUI` 新增具進程安全防護的背景 `GitDiffService` 與 `AgentTelemetryStore` 驅動右側 Inspector 與底部狀態列；原生 UI 僅於大面板底層使用單層 `NSVisualEffectView` 搭配半透明高光覆層模擬卡片（`docs/adr/0003`），拖曳時全面切換 `isResizing` 不透明實底，並以雙軌模型保留分割 `預覽 tab` 與右側即時預覽（`docs/adr/0002`）。

**Tech Stack:** Swift 5/6 (`Core/Package.swift`, `App/Package.swift`), XCTest, AppKit, SwiftUI, Observation, WebKit (`WKWebView`), `libghostty`

## Global Constraints

- `App/Sources/LmuxTerminal` 與 `vendor/ghostty` 維持完全不變；終端機繪圖路徑絕不引入 SwiftUI。
- 向後相容既有的 `layout.json`（舊設定缺少 `inspectorVisible`/`inspectorWidth`/`inspectorTab` 時預設展開、`320pt`、`.preview`）、`MarkdownHTML` CSP／textCSP 安全隔離、以及全部現有快捷鍵（含 `⌃⌘S`、`⇧⌘H`、`⌘N`、`⌘T`、`⌘D`、`⇧⌘D`）。
- 全域僅 Titlebar、左側欄、右側 Inspector 與底部狀態列底層掛載 `NSVisualEffectView`；任何拖曳調整（左側欄、右側欄、通知 bar、窗格分割線、視窗縮放）期間皆觸發 `RootView.setAllBackdropsResizing(_:)` 切換不透明實底，失焦／手勢取消／移除視圖即自動復原。
- 所有新 Chrome SwiftUI host 必須使用 `SidebarHostingView`（`acceptsFirstResponder == false`），確保點擊邊欄或狀態列不搶奪終端機焦點。
- 每個任務最多修改 2–3 個實作檔案、單一新檔不超過 ~300 行、先寫失敗測試（RED）再實作（GREEN）並執行真實測試命令驗證。

## Quality Principles

**Testing:** Tests verify behavior (return values, state changes, responses), not wiring.
If the main assertion is `toHaveBeenCalledWith`, rewrite to assert on the function's output.

**Code:** No single new file exceeds ~300 lines. If it grows past that, split into focused sub-modules.

---

### Task 1: Core Agent Telemetry 模型與 Claude JSONL 增量 Token/Model 解析

**Files:**
- Create: `Core/Sources/LmuxTranscript/AgentTelemetry.swift`
- Modify: `Core/Sources/LmuxTranscript/TranscriptIndex.swift:44-220`
- Test: `Core/Tests/LmuxTranscriptTests/AgentTelemetryTests.swift`

**Interfaces:**
- Produces (`LmuxTranscript`):
  - `public struct AgentTelemetrySnapshot: Sendable, Equatable`（`model: String?`, `turnCount: Int`, `contextUsedTokens: Int`, `contextLimitTokens: Int`, `inputTokens: Int`, `outputTokens: Int`, `cacheCreationTokens: Int`, `cacheReadTokens: Int`, `estimatedCostUSD: Double?`, `contextPercent: Double`, `updatedAt: Date?`）
  - `public enum ModelPricing { public static func contextLimit(for model: String?) -> Int; public static func estimateCostUSD(model: String?, input: Int, cacheCreation: Int, cacheRead: Int, output: Int) -> Double? }`
  - `TranscriptIndex`: `public private(set) var telemetry = AgentTelemetrySnapshot()`

- [x] **Step 1: 建立失敗單元測試（`AgentTelemetryTests.swift`，含 `// @feature:` 標註、增量追加驗證與異常降級檢查）**

```swift
// @feature: liquid-glass-app.feature
// @scenario: 增量解析 Claude 與 Codex 對話紀錄取得模型、Turn 與 Token 用量
// @scenario: 對話紀錄缺少用量欄位或格式損毀行時安全降級不拋錯
import XCTest
@testable import LmuxTranscript

final class AgentTelemetryTests: XCTestCase {
    func testClaudeIncrementalTelemetryExtractsAppendOnlyAndClampsInvalidUsage() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let u1 = #"{"type":"user","uuid":"u1","parentUuid":null,"turnOrigin":"human","message":{"role":"user","content":"hi"}}"#
        let aNoUsage = #"{"type":"assistant","uuid":"a0","parentUuid":"u1","message":{"id":"m0","role":"assistant","model":"claude-sonnet-4-20250514","content":[{"type":"text","text":"..."}]}}"#
        let a1 = #"{"type":"assistant","uuid":"a1","parentUuid":"a0","message":{"id":"m1","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":2000,"output_tokens":300},"content":[{"type":"text","text":"hello"}]}}"#
        let badLine = #"{"type":"assistant","corrupt": "#
        try (u1 + "\n" + aNoUsage + "\n" + a1 + "\n" + badLine + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let idx = TranscriptIndex(url: tmp)
        _ = try idx.update()
        XCTAssertEqual(idx.fullReads, 1)
        XCTAssertEqual(idx.telemetry.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(idx.telemetry.turnCount, 1)
        XCTAssertEqual(idx.telemetry.contextUsedTokens, 3500)
        XCTAssertEqual(idx.telemetry.cacheReadTokens, 2000)
        XCTAssertEqual(idx.telemetry.outputTokens, 300)
        XCTAssertEqual(idx.telemetry.contextLimitTokens, 200_000)
        XCTAssertNotNil(idx.telemetry.estimatedCostUSD)

        let firstParsed = idx.bytesParsed
        let u2 = #"{"type":"user","uuid":"u2","parentUuid":"a1","turnOrigin":"human","message":{"role":"user","content":"next"}}"#
        let a2 = #"{"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"id":"m2","role":"assistant","model":"claude-opus-4-1","usage":{"input_tokens":-50,"cache_creation_input_tokens":100,"cache_read_input_tokens":4000,"output_tokens":200},"content":[{"type":"text","text":"done"}]}}"#
        let h = try FileHandle(forUpdating: tmp)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data((u2 + "\n" + a2 + "\n").utf8))

        _ = try idx.update()
        XCTAssertEqual(idx.fullReads, 1)
        XCTAssertGreaterThan(idx.bytesParsed, firstParsed)
        XCTAssertEqual(idx.telemetry.model, "claude-opus-4-1")
        XCTAssertEqual(idx.telemetry.turnCount, 2)
        XCTAssertEqual(idx.telemetry.contextUsedTokens, 4100)
        XCTAssertEqual(idx.telemetry.inputTokens, 0)
        XCTAssertEqual(idx.telemetry.outputTokens, 500)
    }
}
```

- [x] **Step 2: 執行測試確認失敗**

Run: `swift test --package-path Core --filter AgentTelemetryTests`
Expected: FAIL（`AgentTelemetrySnapshot` 與 `idx.telemetry` 尚未定義）

- [x] **Step 3: 實作 `AgentTelemetry.swift` 並擴充 `TranscriptIndex.swift` 增量解析**

在 `AgentTelemetry.swift` 定義 `AgentTelemetrySnapshot` 與 `ModelPricing`；在 `TranscriptIndex.swift` 的單行讀取處解析完整 `assistant` 行的 `message["model"]` 與 `message["usage"]`（所有 token 欄位 `max(0, val)` 防負值；每出現新 `usage` 更新最新 `contextUsedTokens = input + cacheCreation + cacheRead`，並累加總 `outputTokens` 與成本），不更動既有 `Transcript.outlineObject`。

- [x] **Step 4: 重跑測試驗證通過**

Run: `swift test --package-path Core --filter AgentTelemetryTests`
Expected: PASS

- [x] **Step 5: 提交 Task 1**

```bash
git add Core/Sources/LmuxTranscript/AgentTelemetry.swift Core/Sources/LmuxTranscript/TranscriptIndex.swift Core/Tests/LmuxTranscriptTests/AgentTelemetryTests.swift
git commit -m "feat(core): extract incremental model and token telemetry from Claude transcripts"
```

---

### Task 2: Codex Rollout Token Telemetry 增量解析

**Files:**
- Modify: `Core/Sources/LmuxTranscript/CodexRollout.swift:32-390`
- Modify: `Core/Tests/LmuxTranscriptTests/AgentTelemetryTests.swift`

**Interfaces:**
- Consumes (`LmuxTranscript`): `AgentTelemetrySnapshot`, `ModelPricing`
- Produces (`CodexRollout`):
  - `CodexRollout`: `public private(set) var telemetry: AgentTelemetrySnapshot`
  - `CodexRollout.Parsed`: `public var telemetry: AgentTelemetrySnapshot`（供 `CodexRollout.parse(_:)` 回傳完整遙測）

- [x] **Step 1: 在 `AgentTelemetryTests.swift` 新增 Codex rollout 增量追加、`turn_context`、`parse(_:)` 與損毀行測試**

```swift
func testCodexRolloutParsesTokenCountIncrementallyAndViaStaticParse() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-test-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let meta = #"{"timestamp":"2026-11-18T00:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp","model":"gpt-5.3-codex"}}"#
    let u1 = #"{"timestamp":"2026-11-18T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"fix bug"}}"#
    let tok1 = #"{"timestamp":"2026-11-18T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":272000,"last_token_usage":{"input_tokens":12000,"cached_input_tokens":8000,"output_tokens":450}}}}"#
    let bad = #"{"type":"event_msg","broken": "#
    try (meta + "\n" + u1 + "\n" + tok1 + "\n" + bad + "\n").write(to: tmp, atomically: true, encoding: .utf8)

    let rollout = CodexRollout(url: tmp)
    _ = try rollout.update()
    XCTAssertEqual(rollout.fullReads, 1)
    XCTAssertEqual(rollout.telemetry.model, "gpt-5.3-codex")
    XCTAssertEqual(rollout.telemetry.turnCount, 1)
    XCTAssertEqual(rollout.telemetry.contextUsedTokens, 12000)
    XCTAssertEqual(rollout.telemetry.cacheReadTokens, 8000)
    XCTAssertEqual(rollout.telemetry.contextLimitTokens, 272_000)

    let firstBytes = rollout.bytesParsed
    let ctx = #"{"timestamp":"2026-11-18T00:00:03Z","type":"turn_context","payload":{"model":"o3"}}"#
    let u2 = #"{"timestamp":"2026-11-18T00:00:04Z","type":"event_msg","payload":{"type":"user_message","message":"again"}}"#
    let tok2 = #"{"timestamp":"2026-11-18T00:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":200000,"last_token_usage":{"input_tokens":-10,"cached_input_tokens":5000,"output_tokens":100}}}}"#
    let h = try FileHandle(forUpdating: tmp)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data((ctx + "\n" + u2 + "\n" + tok2 + "\n").utf8))

    _ = try rollout.update()
    XCTAssertEqual(rollout.fullReads, 1)
    XCTAssertGreaterThan(rollout.bytesParsed, firstBytes)
    XCTAssertEqual(rollout.telemetry.model, "o3")
    XCTAssertEqual(rollout.telemetry.turnCount, 2)
    XCTAssertEqual(rollout.telemetry.contextUsedTokens, 0)
    XCTAssertEqual(rollout.telemetry.outputTokens, 550)

    let whole = try CodexRollout.parse(tmp)
    XCTAssertEqual(whole.telemetry.model, "o3")
    XCTAssertEqual(whole.telemetry.turnCount, 2)
}
```

- [x] **Step 2: 執行測試確認失敗**

Run: `swift test --package-path Core --filter testCodexRolloutParsesTokenCountIncrementallyAndViaStaticParse`
Expected: FAIL

- [x] **Step 3: 實作 `CodexRollout` 增量與整檔遙測抽取**

在 `Accumulator.consume(_:at:)` 執行 `guard let c = CodexRollout.classify(o)` **之前** 先抽取 `session_meta` / `turn_context`（`model`）與 `event_msg` `token_count`（`info.model_context_window`、`info.last_token_usage`；`max(0, ...)` 防負值），並在 `Parsed` 加上 `public var telemetry: AgentTelemetrySnapshot`。

- [x] **Step 4: 執行全套 `LmuxTranscriptTests`**

Run: `swift test --package-path Core --filter LmuxTranscriptTests`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 2**

```bash
git add Core/Sources/LmuxTranscript/CodexRollout.swift Core/Tests/LmuxTranscriptTests/AgentTelemetryTests.swift
git commit -m "feat(core): extract token_count telemetry from Codex rollout files"
```

---

### Task 3: Hook 即時 Tool Call 串流與 `PaneAgent` 記錄環形緩衝區

**Files:**
- Create: `Core/Sources/LmuxHooks/ToolCallStream.swift`
- Modify: `Core/Sources/LmuxHooks/AgentState.swift:68-150`
- Test: `Core/Tests/LmuxHooksTests/ToolCallStreamTests.swift`

**Interfaces:**
- Produces (`LmuxHooks`):
  - `public enum ToolCategory: String, Sendable, Equatable`（`read`, `edit`, `bash`, `search`, `other`）
  - `public enum ToolStatus: String, Sendable, Equatable`（`running`, `succeeded`, `failed`, `interrupted`）
  - `public struct ToolCallEntry: Sendable, Equatable, Identifiable`（`id: String`, `name: String`, `category: ToolCategory`, `argument: String?`, `status: ToolStatus`, `startedAtNanos: UInt64`, `durationMs: Int?`）
  - `public struct ToolCallStream: Sendable, Equatable`（`entries: [ToolCallEntry]`, `cap = 50`, `turnCount: Int`, `mutating func record(_ event: HookEvent)`）
  - `PaneAgent` 新增 `public private(set) var toolStream = ToolCallStream()` 及 `public mutating func recordToolEvent(_ event: HookEvent)`（給不走 `PaneAgent.handle` 的 Codex report 模式呼叫），並在 `handle(_:focused:)` 同步呼叫 `toolStream.record(e)`。

- [x] **Step 1: 撰寫 `ToolCallStreamTests.swift` 失敗測試**

```swift
// @feature: liquid-glass-app.feature
// @scenario: Hook 即時工具事件與終止事件更新即時 Tool Call 串流與狀態
import XCTest
@testable import LmuxHooks

final class ToolCallStreamTests: XCTestCase {
    func testToolCallStreamTracksCategoriesDurationsFallbackIDFailureInterruptAndCap() {
        var agent = PaneAgent()
        var prompt = HookEvent(paneID: "p1", name: HookEvent.Kind.userPromptSubmit.rawValue)
        agent.handle(prompt, focused: true)
        XCTAssertEqual(agent.toolStream.turnCount, 1)

        var preRead = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        preRead.toolName = "Read"; preRead.toolArgument = "Tokens.swift"; preRead.toolUseID = "tu-1"; preRead.sentAtNanos = 1_000_000_000
        agent.handle(preRead, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.category, .read)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .running)

        var postRead = HookEvent(paneID: "p1", name: HookEvent.Kind.postToolUse.rawValue)
        postRead.toolName = "Read"; postRead.toolUseID = "tu-1"; postRead.sentAtNanos = 1_042_000_000
        agent.handle(postRead, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .succeeded)
        XCTAssertEqual(agent.toolStream.entries.last?.durationMs, 42)

        // toolUseID == nil fallback match by latest running matching toolName + Failure
        var preBash = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        preBash.toolName = "Bash"; preBash.toolArgument = "swift test"; preBash.receivedAtNanos = 2_000_000_000
        agent.handle(preBash, focused: true)
        var failBash = HookEvent(paneID: "p1", name: HookEvent.Kind.postToolUseFailure.rawValue)
        failBash.toolName = "Bash"; failBash.receivedAtNanos = 2_120_000_000
        agent.handle(failBash, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.category, .bash)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .failed)
        XCTAssertEqual(agent.toolStream.entries.last?.durationMs, 120)

        // Running tool marked interrupted on Interrupt
        var preEdit = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        preEdit.toolName = "Edit"; preEdit.toolUseID = "tu-3"
        agent.handle(preEdit, focused: true)
        agent.handle(HookEvent(paneID: "p1", name: HookEvent.Kind.interrupt.rawValue), focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .interrupted)

        // Bounded ring cap = 50 evicts oldest
        for i in 1...55 {
            var ev = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
            ev.toolName = "Grep"; ev.toolUseID = "cap-\(i)"
            agent.handle(ev, focused: true)
        }
        XCTAssertEqual(agent.toolStream.entries.count, ToolCallStream.cap)
        XCTAssertEqual(agent.toolStream.entries.first?.id, "cap-6")
    }
}
```

- [x] **Step 2: 執行測試確認失敗**

Run: `swift test --package-path Core --filter ToolCallStreamTests`
Expected: FAIL

- [x] **Step 3: 實作 `ToolCallStream.swift` 並整合進 `AgentState.swift`**

實作工具分類（`Read`/`View`→`.read`、`Edit`/`Write`/`MultiEdit`/`NotebookEdit`→`.edit`、`Bash`/`Run`→`.bash`、`Grep`/`Glob`/`Search`→`.search`、其餘 `.other`）、時間戳取用 `event.sentAtNanos ?? event.receivedAtNanos ?? DispatchTime.now().uptimeNanoseconds`、`toolUseID` 或 `toolName` 末尾 `.running` 條目比對、`cap = 50` 淘汰最舊紀錄；並暴露 `recordToolEvent(_:)` 供 Codex report 模式共用。

- [x] **Step 4: 執行全套 `Core` 單元測試**

Run: `swift test --package-path Core`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 3**

```bash
git add Core/Sources/LmuxHooks/ToolCallStream.swift Core/Sources/LmuxHooks/AgentState.swift Core/Tests/LmuxHooksTests/ToolCallStreamTests.swift
git commit -m "feat(core): add bounded live ToolCallStream tracking to PaneAgent"
```

---

### Task 4: 安全背景 `GitDiffService` 與 `--liquid-glass-telemetry` 測試通道接線

**Files:**
- Create: `App/Sources/LmuxUI/GitDiffService.swift`
- Create: `App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift`
- Modify: `App/Sources/lmux-apptest/main.swift:70-185`
- Modify: `App/scripts/apptest.sh:150-170`

**Interfaces:**
- Consumes (`LmuxUI`): `PreviewTarget.resolve(_:cwd:)`, `PreviewTarget.hasUnsafeScalar(_:)`, `PreviewTarget.replacingUnsafeScalars(_:)`
- Produces (`LmuxUI`):
  - `public struct GitDiffLine: Equatable, Identifiable`（`id: Int`, `kind: Kind` [`.context`, `.added`, `.removed`, `.hunkHeader`], `text: String`）
  - `public struct GitDiffFile: Equatable, Identifiable`（`id: String`, `path: String`, `status: String`, `added: Int`, `deleted: Int`, `lines: [GitDiffLine]`, `truncated: Bool`）
  - `public struct GitDiffSnapshot: Equatable`（`cwd: String?`, `isGitRepo: Bool`, `branch: String?`, `totalAdded: Int`, `totalDeleted: Int`, `files: [GitDiffFile]`, `previewCandidates: [URL]`）
  - `@MainActor @Observable public final class GitDiffService`（`public private(set) var snapshot: GitDiffSnapshot`, `public private(set) var isLoading: Bool`, `public func refresh(cwd: String?, immediate: Bool = false)`, `static func parseNumstat(_:)`, `static func parseUnifiedDiff(_:maxLines:)`）

- [x] **Step 1: 建立 `LiquidGlassTelemetryTests.swift` 並註冊 `--liquid-glass-telemetry` 至 `main.swift` 與 `App/scripts/apptest.sh` 的 `run_liquid_glass_suite`**

涵蓋斷言（標註 `// @feature: liquid-glass-app.feature` / `// @scenario: Git Diff 服務讀取工作區變更統計與檔案 hunks，非 Git 目錄呈現空狀態`）：
1. `parseNumstat` 與 `parseUnifiedDiff` 解析單檔／多檔、`binary - -` 安全略過、`maxLines` 截斷設 `truncated == true`。
2. 建置暫存 Git 倉庫並設定惡意 `.git/config` `diff.external = touch /tmp/pwned`：執行 `refresh(cwd:immediate:)` 後確認傳回正確分支、`totalAdded`、`totalDeleted`、`files`，且 `/tmp/pwned` **絕未被建立**。
3. 未曾 commit 的新建 `git init` 倉庫（unborn HEAD）與 detached HEAD 皆可正確回報 status/diff，不因 `diff HEAD` exit 128 壞掉。
4. 目錄包含 unsafe scalars / symlink 指向外層 `/etc/passwd` 時，`previewCandidates` 只收錄通過 `PreviewTarget.resolve` 驗證的一般檔案（上限 5 筆，`README.md` 優先），且路徑經過 `PreviewTarget.replacingUnsafeScalars`。
5. 切換至非 Git 暫存目錄後 `snapshot.isGitRepo == false`、`files.isEmpty`；快速連續切換兩個目錄（cancel generation）後只保留最後一次目錄結果。

- [x] **Step 2: 編譯並執行確認 RED**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass-telemetry`
Expected: FAIL（`GitDiffService` 未定義）

- [x] **Step 3: 實作安全強化版 `GitDiffService.swift`**

實作重點：
- `200ms` debounce（測試可用 `immediate: true`），切換時遞增 generation ID 並對進行中 `Process` 呼叫 `terminate()`。
- 僅在 `cwd` 為存在的一般目錄時執行，直接呼叫 `/usr/bin/git`（禁 shell），所有 git 子命令帶 `GIT_OPTIONAL_LOCKS=0` 環境變數，diff 指令加上 `--no-ext-diff --no-textconv -c core.fsmonitor=false --`。
- Stdout / stderr 使用 async readabilityHandler 並於達到硬性 byte 上限（例如 `256 KB`）前停止累積再等待結束，搭配 3 秒 timeout 保護絕不 deadlock。
- Unborn HEAD fallback（`diff HEAD` 失敗改讀 `diff --cached` + `status --porcelain=v1 -z` untracked），以 `PreviewTarget.replacingUnsafeScalars` 清洗所有 `branch` 與檔案路徑。

- [x] **Step 4: 執行 `--liquid-glass-telemetry` 驗證 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass-telemetry`
Expected: PASS

- [x] **Step 5: 提交 Task 4**

```bash
git add App/Sources/LmuxUI/GitDiffService.swift App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift App/Sources/lmux-apptest/main.swift App/scripts/apptest.sh
git commit -m "feat(ui): add hardened background GitDiffService and wire --liquid-glass-telemetry"
```

---

### Task 5: `LmuxTokens` 1:1 雙主題 Apple Liquid Glass 設計系統與 WCAG AA 對比檢核

**Files:**
- Modify: `App/Sources/LmuxTokens/Tokens.swift:109-397`
- Modify: `App/scripts/liquid-glass-app-check.swift`

**Interfaces:**
- Produces (`LmuxTokens`):
  - `Colors`：新增 `windowBackgroundTint`、`titlebarBackground`、`rightSidebarTint`、`footerBackground`、`glassHighlightBorder`（Shallow White Crystal `0xFFFFFF @ 0.78` / Dark `0xFFFFFF @ 0.14`，同時保留既有 `glassBorder` hairline `lightAlpha: 0.09` 相容不破）、`glassCard`、`glassCardHover`、`glassCardSelected`、`glassSurfaceRecessed`、`activePaneRing`（`0x0A84FF`）、`statusRunningPill`/`Text`、`statusNeedsInputPill`/`Text`、`statusDonePill`/`Text`、`statusIdlePill`/`Text`、`diffAddedBg`/`Fg`、`diffRemovedBg`/`Fg`；調整 `sidebarTint`、`specularHighlight`。
  - `Layout`：`titlebarHeight = 44`、`footerHeight = 32`、`sidebarWidthDefault = 260`（`180...400`）、`rightInspectorWidthDefault = 320`（`240...500`）、`paneCornerRadius = 10`、`paneGap = 8`、`paneTabStripHeight = 30`、`workspaceFilterHeaderHeight = 30`。

- [x] **Step 1: 更新 `App/scripts/liquid-glass-app-check.swift`（同步清除過時 `// @scenario:` 標頭並改用正確場景名）**

新增驗證：
1. Light（High-Key Crystal）與 Dark（Obsidian Midnight）主題下 `titlebarBackground`、`rightSidebarTint`、`footerBackground`、`glassCard`、`glassHighlightBorder`、`activePaneRing` 與尺寸常數（`44/32/260/320/10/30`）皆解析無誤。
2. 選取卡片、`statusRunningText` / `statusNeedsInputText` / `statusDoneText` 疊合於實際 pill 與玻璃底色後的 WCAG AA 對比度（>= `4.5:1`），以及 `diffAddedFg`/`Bg`、`diffRemovedFg`/`Bg` 與 **底部狀態列** 文字對比皆 >= `4.5:1`。

- [x] **Step 2: 執行 `swift App/scripts/liquid-glass-app-check.swift` 確認 RED**

Run: `swift App/scripts/liquid-glass-app-check.swift`
Expected: FAIL（新 Token 與常數尚未新增）

- [x] **Step 3: 實作 `App/Sources/LmuxTokens/Tokens.swift`（精準對調淺／深雙主題玻璃色彩並維持現有 Nord WCAG AA 相容檢查）**

- [x] **Step 4: 驗證 Token 腳本與現有 WCAG / Contrast 測試皆通過 GREEN**

Run: `swift App/scripts/liquid-glass-app-check.swift && PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --contrast --liquid-glass`
Expected: `APP TOKEN CHECK: ok`，`--contrast` 與 `--liquid-glass` PASS

- [x] **Step 5: 提交 Task 5**

```bash
git add App/Sources/LmuxTokens/Tokens.swift App/scripts/liquid-glass-app-check.swift
git commit -m "feat(tokens): add 1:1 High-Key Crystal & Obsidian Midnight Liquid Glass tokens with WCAG AA verification"
```

---

### Task 6a: `AppModel` Inspector / Filter / Preview 狀態與 `LayoutFile` 持久化擴充

**Files:**
- Modify: `App/Sources/LmuxUI/Model.swift:66-140, 747-810`
- Modify: `App/Sources/LmuxUI/Persistence.swift:8-60, 160-260`
- Modify: `App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift`

**Interfaces:**
- Consumes (`LmuxTokens`): `LmuxTokens.Layout.rightInspectorWidthDefault`, `rightInspectorWidthMin`, `rightInspectorWidthMax`
- Produces (`LmuxUI`):
  - `public enum InspectorTab: String, Codable, CaseIterable { case preview, diff, trace }`
  - `public enum WorkspaceFilter: String, CaseIterable { case all, active, needsInput }`
  - `AppModel` 新增：`inspectorVisible: Bool = true`、`inspectorWidth: CGFloat = LmuxTokens.Layout.rightInspectorWidthDefault`、`inspectorTab: InspectorTab = .preview`、`workspaceFilter: WorkspaceFilter = .all`、`inspectorPreviewURLByWorkspace: [String: URL] = [:]`、`reduceMotionOverride: Bool?`（搭配測試無副作用控制動態）、`@ObservationIgnored var telemetryStore: AgentTelemetryStore?`、`@ObservationIgnored public let gitDiffService = GitDiffService()`。
  - `Pane`: `didSet` 於 `agent != oldValue` 時同時更新 `workspace?.model?.telemetryStore?.noteHookUpdate(for: self)`（即使同為 `.running -> .running`）。
  - `LayoutFile`：以 `decodeIfPresent` 在 `init(from:)` 解碼 `inspectorVisible`、`inspectorWidth`（鉗製於 `240...500`）、`inspectorTab`，並在 `Controller.snapshotLayout()` / `restoreLayout()` 完整讀寫。

- [x] **Step 1: 在 `LiquidGlassTelemetryTests.swift` 加入舊版 `layout.json` 相容解碼、超界寬度鉗製（如 `999` → `500`）與 `snapshotLayout()` → `restoreLayout()` 往返測試**

- [x] **Step 2: 執行 `--liquid-glass-telemetry` 確認 RED**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass-telemetry`
Expected: FAIL

- [x] **Step 3: 實作 `Model.swift` 與 `Persistence.swift` 狀態及解碼／序列化更新**

- [x] **Step 4: 執行 `--liquid-glass-telemetry` 與 `--compat` 驗證 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass-telemetry --compat`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 6a**

```bash
git add App/Sources/LmuxUI/Model.swift App/Sources/LmuxUI/Persistence.swift App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift
git commit -m "feat(ui): extend AppModel & backward-compatible LayoutFile with Inspector and Filter state"
```

---

### Task 6b: `AgentTelemetryStore`、`TranscriptCache.Snapshot` 遙測橋接與 Codex Hook 工具轉發

**Files:**
- Create: `App/Sources/LmuxUI/AgentTelemetryStore.swift`
- Modify: `App/Sources/LmuxUI/MessageActions.swift:55-120`
- Modify: `App/Sources/LmuxUI/Agent.swift:165-210, 285-370`
- Modify: `App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift`

**Interfaces:**
- Consumes: `TranscriptIndex.telemetry`, `CodexRollout.telemetry`, `Pane.agent.toolStream`
- Produces (`LmuxUI`):
  - `public struct PaneTelemetryDisplay: Equatable`（`model: String?`, `turnCount: Int`, `contextUsedTokens: Int`, `contextLimitTokens: Int`, `inputTokens: Int`, `outputTokens: Int`, `cacheReadTokens: Int`, `estimatedCostUSD: Double?`, `contextPercent: Double`, `toolCalls: [ToolCallEntry]`, `isActiveAgent: Bool`）
  - `@MainActor @Observable public final class AgentTelemetryStore`（`public func display(for pane: Pane?) -> PaneTelemetryDisplay`、`public func noteHookUpdate(for pane: Pane)`、`public func refreshTranscriptTelemetry(for pane: Pane)`、`public func clear(paneID: String)`；`turnCount` 取 `max(jsonl.turnCount, toolStream.turnCount)`）
  - `TranscriptCache.Snapshot` 新增 `let telemetry: AgentTelemetrySnapshot`。

- [x] **Step 1: 在 `LiquidGlassTelemetryTests.swift` 新增 `AgentTelemetryStore` 與 Codex `codexReport` 模式下仍能記錄 `ToolCallStream` 及切分頁／`SessionEnd` 清除測試**

- [x] **Step 2: 執行 `--liquid-glass-telemetry` 確認 RED**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass-telemetry`
Expected: FAIL

- [x] **Step 3: 實作 `AgentTelemetryStore.swift`，更新 `TranscriptCache.Snapshot` 暴露 `telemetry`，並修正 `Agent.swift` 在 Codex early-return 與 Hook 完成處同步更新 `recordToolEvent` 與 `telemetryStore`**

注意：檢視 `Agent.swift` 中 `resetAfterClaude` 與 `sessionEnd` 處，僅在對話結束/重開時明確 reset 遙測而非在無關事件抹除進行中統計。

- [x] **Step 4: 執行 `--liquid-glass-telemetry` 與 `--agent-state` 相關測試驗證 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass-telemetry`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 6b**

```bash
git add App/Sources/LmuxUI/AgentTelemetryStore.swift App/Sources/LmuxUI/MessageActions.swift App/Sources/LmuxUI/Agent.swift App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift
git commit -m "feat(ui): connect TranscriptCache and Hook events (Claude + Codex) to AgentTelemetryStore"
```

---

### Task 7a: 快捷鍵雙綁相容（`⌘B` / `⌃⌘S` / `⌥⌘B`）與 `toggleInspector()` 控制流程

**Files:**
- Modify: `App/Sources/LmuxUI/Menu.swift:83-105`
- Modify: `App/Sources/LmuxUI/Controller.swift:790-810, 1475-1505`
- Modify: `App/Sources/lmux-apptest/LiquidGlass.swift`

**Interfaces:**
- Produces (`LmuxUI`):
  - `Menu.swift` View 選單新增 `"Toggle Inspector"`（`keyEquivalent: "b"`, modifiers `[.command, .option]`, id: `"toggleInspector"`, selector: `#selector(menuToggleInspector(_:))`），保留 `"Toggle Sidebar"`（`⌃⌘S`, id: `"toggleSidebar"`）。
  - `LmuxWindow.performKeyEquivalent`: 在 `super.performKeyEquivalent(with: event)` 與 `asciiEquivalent` 未被 menu / Ghostty `SurfaceView` / `NSText` / `WKWebView` 消耗時，若為 unmodified `⌘B`（且未自訂覆寫 `toggleSidebar`），觸發 `controller?.toggleSidebar()` 並回傳 `true`（支援非拉丁鍵盤配置 `asciiEquivalent`）。
  - `Controller`: `public func toggleInspector()`（切換 `model.inspectorVisible`；若隱藏或離開目前 `.preview` firstResponder，呼叫 `focusCurrent()`）。

- [x] **Step 1: 在 `LiquidGlass.swift` 加入 `⌥⌘B`、`⌘B`、`⌃⌘S` 經 `window.performKeyEquivalent` 切換左右欄及 `NSText` 不被搶鍵測試**

- [x] **Step 2: 執行 `--liquid-glass` 確認 RED**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass`
Expected: FAIL

- [x] **Step 3: 實作 `Menu.swift` 與 `Controller.swift` 雙綁與 `toggleInspector()`**

- [x] **Step 4: 執行 `--liquid-glass` 與 `--newuser` 驗證 `⌘B`、`⌃⌘S`、`⌥⌘B`、`⇧⌘H` 全部通過**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass --newuser`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 7a**

```bash
git add App/Sources/LmuxUI/Menu.swift App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/LiquidGlass.swift
git commit -m "feat(ui): wire Cmd+B, Ctrl+Cmd+S, and Opt+Cmd+B inspector/sidebar shortcuts"
```

---

### Task 7b: 統一 44pt 玻璃標題列、`TitlebarCenterChip` 與右側操作群組

**Files:**
- Create: `App/Sources/LmuxUI/TitlebarView.swift`
- Modify: `App/Sources/LmuxUI/Sidebar.swift:534-588`（確保 `IconButton`/`TitlebarCluster` 可重用）

**Interfaces:**
- Produces (`LmuxUI`):
  - `@MainActor final class TitlebarBackdrop: NSView`（`NSVisualEffectView(.titlebar, .behindWindow)` + `tint` + 1pt `specular` + `isResizing` opaque fallback）
  - `struct TitlebarCenterChip: View`（狀態圓點 [支援 `reduceMotion`]、工作區標題、`zoomIcon`、`modeBadge`、Git 分支 + 精簡路徑；支援傳入可用最大寬度避免與左右控制群組重疊）
  - `struct TitlebarRightCluster: View`（向右分割 `⌘D`、向下分割 `⇧⌘D`、分隔線、`⌥⌘B` 切換 **右側 Inspector** 高亮狀態鈕）
  - 全部按鈕均由 `SidebarHostingView` 承載並供 `RootView` 直接掛載於 AppKit `titlebarHost`（與拖曳空區互不干擾）。

- [x] **Step 1: 在 `LiquidGlass.swift` 補入 `TitlebarCenterChip.computeChipLayout` 窄窗不重疊驗證與 `TitlebarRightCluster` 動作測試（RED）**

- [x] **Step 2: 編譯並執行 `--liquid-glass` 確認 RED**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass`
Expected: FAIL

- [x] **Step 3: 建立 `TitlebarView.swift`（<= 220 行）與共用的 `TitlebarCluster` 樣式**

- [x] **Step 4: 執行 `--liquid-glass` 與 `--titlebar` 確認通過 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass --titlebar`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 7b**

```bash
git add App/Sources/LmuxUI/TitlebarView.swift App/Sources/LmuxUI/Sidebar.swift App/Sources/lmux-apptest/LiquidGlass.swift
git commit -m "feat(ui): build 44pt Liquid Glass Titlebar components (backdrop, center chip, right cluster)"
```

---

### Task 8a: 左側欄 `WorkspaceFilterHeader` 與 1:1 玻璃 `WorkspaceRowContent` 卡片

**Files:**
- Create: `App/Sources/LmuxUI/WorkspaceFilterHeader.swift`
- Modify: `App/Sources/LmuxUI/Sidebar.swift:145-410`
- Modify: `App/Sources/LmuxUI/HooksSetup.swift:355-365`（確認 `WorkspaceRowContent` 預設參數不破既有預覽卡片）

**Interfaces:**
- Consumes (`LmuxTokens`): `glassCard`, `glassCardHover`, `glassCardSelected`, `glassHighlightBorder`, `statusRunningPill`/`Text`, `statusNeedsInputPill`/`Text`, `statusDonePill`/`Text`, `statusIdlePill`/`Text`, `workspaceFilterHeaderHeight`
- Produces (`LmuxUI`):
  - `WorkspaceFilterHeader`（左側「工作區」標題 + 右側篩選 Popover/按鈕；掛於 `RootView` 中 `sidebarHost` 上方，讓 `sidebarHost` 內 `rowPoint(c, i)` 起始 y 座標不偏移）
  - `WorkspaceRowContent`（左側 `3pt` 垂直 Accent 條位於安全內距、保留 `TabDisclosureButton` 既有 `x: 1..<15` 熱區不衝突；第 1 行標題 + 右側狀態藥丸 [hover 時保留 `×` 並維持 `closeButtonRect` 相容]；第 2 行摘要 + 相對時間；保有預設參數確保 `HooksSetup.swift` 與 `Sidebar.swift` 測試建構相容）
  - 篩選為 `.active` / `.needsInput` 且無符合項目時顯示清晰空狀態（`"沒有符合篩選條件的工作區"` + 重置為全部按鈕），且篩選開啟時安全停用拖曳排序避免索引錯位。

- [x] **Step 1: 在 `LiquidGlass.swift` 加入篩選狀態（`all` / `active` / `needsInput`）、無結果空狀態、狀態藥丸視覺呈現與 `TabDisclosureButton` 不重疊測試**

- [x] **Step 2: 執行 `--liquid-glass` 確認 RED**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass`
Expected: FAIL

- [x] **Step 3: 實作 `WorkspaceFilterHeader.swift` 與新版 `WorkspaceRowContent`（同時保護多選、右鍵選單與拖曳重排）**

- [x] **Step 4: 執行 `--sidebar`、`--sidebar-tabs`、`--zoom-clear-reorder` 與 `--liquid-glass` 驗證完全相容且 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --sidebar --sidebar-tabs --liquid-glass`
Expected: ALL PASS

- [x] **Step 5: 提交 Task 8a**

```bash
git add App/Sources/LmuxUI/WorkspaceFilterHeader.swift App/Sources/LmuxUI/Sidebar.swift App/Sources/LmuxUI/HooksSetup.swift App/Sources/lmux-apptest/LiquidGlass.swift
git commit -m "feat(ui): upgrade workspace rows to glass cards with accent stripe, status pills, and filter header"
```

---

### Task 8b: History 搜尋膠囊視覺對齊（置於通知 bar 上方）

**Files:**
- Modify: `App/Sources/LmuxUI/History.swift:407-595`
- Modify: `App/Sources/lmux-apptest/LiquidGlass.swift`

**Interfaces:**
- Produces (`LmuxUI`): 更新 `HistorySection` 與 `HistoryRow` 採用 `preview-mockup.html` 膠囊玻璃搜尋欄（`glassSurfaceRecessed`、`glassBorder`、`focusRing`）與玻璃搜尋結果列（確保位於 `Workspace` 清單底端與 `NotificationBar` 上方且結果清單向上展開不遮蔽下方配件）。

- [x] **Step 1: 更新 `History.swift` 搜尋膠囊與玻璃結果列樣式，並於 `LiquidGlass.swift` 檢查選取／未選取玻璃邊框與聚焦樣式**

- [x] **Step 2: 執行 `--liquid-glass` 與 `--history` / `--newuser` 驗證通過**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass --newuser`
Expected: ALL PASS

- [x] **Step 3: 提交 Task 8b**

```bash
git add App/Sources/LmuxUI/History.swift App/Sources/lmux-apptest/LiquidGlass.swift
git commit -m "feat(ui): restyle History search capsule and result rows for Liquid Glass"
```

---

### Task 9a: 中央分塊 `10pt` 圓角卡片與區分焦點/通知光環（`PaneViews.swift`、`Snapshot.swift`）

**Files:**
- Modify: `App/Sources/LmuxUI/PaneViews.swift:27-305`
- Modify: `App/Sources/LmuxUI/Snapshot.swift:40-90`
- Modify: `App/Sources/LmuxUI/Controller.swift:950-1065`（更新 `refreshPaneChrome` / `focused` 同步與動態 appearance）

**Interfaces:**
- Produces (`LmuxUI`):
  - `PaneView`: 啟用 `wantsLayer = true`、圓角 `T.Layout.paneCornerRadius`（`10pt`），依 `isFocused` 與 `effectiveAppearance` 套用 `activePaneRing` 藍色聚焦邊光 vs 非聚焦 `glassBorder` 細框；`RingView`（未讀通知 / `needsInput`）改以醒目琥珀色 `stateNeedsInput` 光環繪製，確保與藍色 `active-ring` 視覺不衝突。
  - `SplitContainerView`: 保留 `isDragging`、`viewWillMove(toWindow: nil)` 保護與 `SplitDivider` `±3pt` 拖曳命中區，並支援分塊間 `paneGap` 玻璃間距且於 `Snapshot.swift` 正確裁切終端 `IOSurface` 圓角。

- [x] **Step 1: 在 `LiquidGlass.swift` 補入聚焦與非聚焦 `PaneView` 邊框/光環顏色區隔測試（焦點藍光 `activePaneRing` vs 非焦點 `needsInput` `RingView` 琥珀色）並確認 RED**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass`
Expected: FAIL

- [x] **Step 2: 實作 `PaneViews.swift`、`Snapshot.swift` 與 `Controller.swift` `PaneView.isFocused` 同步**

- [x] **Step 3: 執行 `--liquid-glass`、`--zoom-clear-reorder` 與 `--snapshot` 驗證 PASS**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass --zoom-clear-reorder`
Expected: ALL PASS

- [x] **Step 4: 提交 Task 9a**

```bash
git add App/Sources/LmuxUI/PaneViews.swift App/Sources/LmuxUI/Snapshot.swift App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/LiquidGlass.swift
git commit -m "feat(ui): style terminal panes as rounded glass cards with distinct active-ring and unread ring"
```

---

### Task 9b: 整合式 `Pane Tab Strip`（`30pt` 膠囊分頁 + 右側分割／關閉按鈕）與相容測試對齊

**Files:**
- Modify: `App/Sources/LmuxUI/Tabs.swift:465-835`
- Modify: `App/Sources/lmux-apptest/PaneTabs.swift:95-275`
- Modify: `App/Sources/lmux-apptest/StatusExtras.swift:100-145`

**Interfaces:**
- Produces (`LmuxUI`):
  - `TabStripView`：預設於每個分塊頂部顯示 `30pt` 玻璃 `Pane Tab Strip`（帶狀態色點之圓角分頁膠囊、`×` 關閉、分頁列末尾 `+` 開分頁鈕；右側操作道顯示 `[向右分割, 向下分割, 關閉分塊 ✕]`，其中關閉分塊呼叫 `controller?.requestClosePane(shown)` 受執行中程式確認框保護），完整保留拖曳排序、跨格分割、雙擊縮放／重新命名、右鍵選單與 `hitTest` 點擊隔離（不穿透至 `PreviewView`）。

- [x] **Step 1: 檢查並更新 `PaneTabs.swift` 與 `StatusExtras.swift` 中關於單頁 `tabStrip` 預設顯示、`background` token 與 `buttonRect` 按鈕配置的新期待（RED）**

- [x] **Step 2: 實作 `Tabs.swift` 新版 `TabStripView` 膠囊繪製與 `[向右分割, 向下分割, 關閉分塊]` 按鈕道**

- [x] **Step 3: 執行 `--pane-tabs`、`--preview`（特別檢查 `preview-click-hit`）與 `--status-extras` 驗證全數 PASS**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --pane-tabs --preview`
Expected: ALL PASS

- [x] **Step 4: 提交 Task 9b**

```bash
git add App/Sources/LmuxUI/Tabs.swift App/Sources/lmux-apptest/PaneTabs.swift App/Sources/lmux-apptest/StatusExtras.swift
git commit -m "feat(ui): upgrade Pane Tab Strip with pill tabs, status dots, and split/close action lane"
```

---

### Task 10a-1: `RightInspectorView` 玻璃框架、可拖曳手把與三分頁外殼

**Files:**
- Create: `App/Sources/LmuxUI/RightInspectorView.swift`
- Modify: `App/Sources/lmux-apptest/LiquidGlass.swift`

**Interfaces:**
- Consumes (`LmuxTokens`, `AppModel`): `rightSidebarTint`, `specularHighlight`, `glassCardSelected`, `InspectorTab`
- Produces (`LmuxUI`):
  - `@MainActor final class RightInspectorBackdrop: NSView`（`NSVisualEffectView(.sidebar, .behindWindow)`、`tint`、`1pt` `specular`、`isResizing` / `accessibilityDisplayShouldReduceTransparency` opaque fallback）
  - `@MainActor final class RightInspectorResizeHandle: NSView`（追蹤 `isDragging`、`viewWillMove(toWindow: nil)` 重置並回呼 `onDrag`/`onDragStateChange`）
  - `struct RightInspectorView<PreviewContent: View, DiffContent: View, TraceContent: View>: View`（頂部 3 段式 Segmented Control：`即時預覽` / `變更 (Diff)` / `執行記錄`；切換離開 `.preview` 時觸發 `onLeavePreview()` 歸還鍵盤焦點，<= 200 行）

- [x] **Step 1: 在 `LiquidGlass.swift` 新增 `RightInspectorBackdrop`（正常毛玻璃＋亮邊 vs `forceOpaque`/Reduce Transparency 實底）與 `RightInspectorResizeHandle` 移除自動清除 `isDragging` 測試（RED）**

- [x] **Step 2: 實作 `RightInspectorView.swift`**

- [x] **Step 3: 執行 `--liquid-glass` 驗證 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass`
Expected: ALL PASS

- [x] **Step 4: 提交 Task 10a-1**

```bash
git add App/Sources/LmuxUI/RightInspectorView.swift App/Sources/lmux-apptest/LiquidGlass.swift
git commit -m "feat(ui): implement RightInspectorView shell, backdrop material, and safe resize handle"
```

---

### Task 10a-2: `InspectorDiffView`（Git 變更清單、Diff Hunks 與非 Git 空狀態）

**Files:**
- Create: `App/Sources/LmuxUI/InspectorDiffView.swift`
- Modify: `App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift`

**Interfaces:**
- Consumes: `GitDiffSnapshot`, `PreviewTarget.resolve(_:cwd:)`
- Produces (`LmuxUI`):
  - `struct InspectorDiffView: View`（頂部 Working Tree 卡片含分支、檔案數、`+added -deleted`；逐檔 Diff 卡片與紅/綠等寬列；非 Git 目錄顯示清楚提示 `"非 Git 版本控制目錄"`；乾淨無變更顯示 `"工作樹乾淨無變更"`；點擊可預覽檔名時須經 `PreviewTarget.resolve` 檢查後才呼叫 `onOpenPreview(url)`，<= 200 行）

- [x] **Step 1: 在 `LiquidGlassTelemetryTests.swift` 加入 `InspectorDiffView.displayState(for:)` 狀態判斷測試（非 Git、乾淨、含多檔與 symlink 阻擋路徑判斷，RED）**

- [x] **Step 2: 實作 `InspectorDiffView.swift`**

- [x] **Step 3: 執行 `--liquid-glass-telemetry` 驗證 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass-telemetry`
Expected: ALL PASS

- [x] **Step 4: 提交 Task 10a-2**

```bash
git add App/Sources/LmuxUI/InspectorDiffView.swift App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift
git commit -m "feat(ui): build InspectorDiffView working tree card, hunk view, and non-Git empty state"
```

---

### Task 10a-3: `InspectorTraceView`（Context Window 負載卡片與 Tool Calls 串流）

**Files:**
- Create: `App/Sources/LmuxUI/InspectorTraceView.swift`
- Modify: `App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift`

**Interfaces:**
- Consumes: `PaneTelemetryDisplay`, `ToolCallEntry`
- Produces (`LmuxUI`):
  - `struct InspectorTraceView: View`（Card 1「Context Window (Token 負載)」含 `%` 徽章、藍紫進度條、已用／上限與 2×2 真實 API 明細：`輸入 Input`、`輸出 Output`、`快取命中 Cache`、`估計費用`；Card 2「最近執行的工具 (Tool Calls)」含分類圖示色塊、工具名、參數摘要、耗時／執行中標記；無作用中 Agent 時呈現 `"— / 尚無作用中的 Agent"` 空狀態，<= 200 行）

- [x] **Step 1: 在 `LiquidGlassTelemetryTests.swift` 新增 `InspectorTraceView.presentation(for:)` 空狀態／使用率格式／Tool 分類測試（RED）**

- [x] **Step 2: 實作 `InspectorTraceView.swift`**

- [x] **Step 3: 執行 `--liquid-glass-telemetry` 驗證 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass-telemetry`
Expected: ALL PASS

- [x] **Step 4: 提交 Task 10a-3**

```bash
git add App/Sources/LmuxUI/InspectorTraceView.swift App/Sources/lmux-apptest/LiquidGlassTelemetryTests.swift
git commit -m "feat(ui): build InspectorTraceView context gauge and live Tool Calls stream"
```

---

### Task 10b-1: 雙軌 `OpenMenu`（新增「在右側欄即時預覽」與 `⌃⌘`-click）及選單測試更新

**Files:**
- Modify: `App/Sources/LmuxUI/OpenMenu.swift:6-115`
- Modify: `App/Sources/LmuxUI/Controller.swift:1538-1557`（新增 test-only `clickModifiersOverride`）
- Modify: `App/Sources/lmux-apptest/PreviewInteractions.swift:15-130`

**Interfaces:**
- Produces (`LmuxUI`):
  - `LmuxController.OpenChoice` 新增 `.inspectorPreview`；`openMenuItems` 為 `[("在右側欄即時預覽", .inspectorPreview), ("在新 tab 預覽", .preview), ("用預設 app 開", .defaultApp), ("在 Finder 顯示", .finder), ("複製路徑", .copyPath)]`。
  - `openTerminalLink`: 當驗證為可預覽本機檔案後，先檢查 `guard isLivePane(pane)`，若同時按住 `.control` + `.command`（或 `clickModifiersOverride` 包含 `.control`），略過選單直接 `newPreviewTab(file, after: pane)`；否則顯示 5 項 **開啟選單**。
  - `LmuxController.openInInspectorPreview(_ file: URL, workspace: Workspace? = nil)`：將目標記錄於該 workspace 的 `inspectorPreviewURLByWorkspace`，設定 `model.inspectorTab = .preview` 與 `model.inspectorVisible = true`。

- [ ] **Step 1: 更新 `PreviewInteractions.swift`（驗證 5 項選單順序、「在右側欄即時預覽」選後設定 `inspectorTab == .preview`／`inspectorVisible == true` 不更動分割數、`⌃⌘`-click 直開預覽 tab 且 stale pane 不觸發，RED）**

- [ ] **Step 2: 實作 `OpenMenu.swift` 與 `Controller.swift` `openInInspectorPreview` / `clickModifiersOverride`**

- [ ] **Step 3: 執行 `--preview` 驗證既有與新版 `open-menu` 檢查全數 PASS**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --preview`
Expected: PASS

- [ ] **Step 4: 提交 Task 10b-1**

```bash
git add App/Sources/LmuxUI/OpenMenu.swift App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/PreviewInteractions.swift
git commit -m "feat(ui): add Right Inspector Live Preview as primary OpenMenu choice plus Ctrl+Cmd tab shortcut"
```

---

### Task 10b-2: `InspectorPreviewPane` + `WorkspacePreviewCoordinator`（隔離生命週期與安全 `↗` 外開）

**Files:**
- Create: `App/Sources/LmuxUI/InspectorPreviewPane.swift`
- Modify: `App/Sources/LmuxUI/Controller.swift:1067-1079`（`ensureFocus()` 允許右側預覽 `WKWebView` 保留鍵盤焦點）
- Modify: `App/Sources/lmux-apptest/PreviewInteractions.swift`

**Interfaces:**
- Consumes: `PreviewView`, `PreviewTarget`, `GhosttyRuntime.openTerminalURL`
- Produces (`LmuxUI`):
  - `@MainActor final class WorkspacePreviewCoordinator`：依目前 `workspaceID` 與載入檔案管理受控 `PreviewView`；**每次切換 `workspaceID` 或載入不同來源檔案時明確呼叫舊 `PreviewView.close()` 並建立新實例**（防止 `WKWebView.backForwardList`、`visitedHTMLRoots` 與 `PreviewWatcher` 跨工作區殘留！）；設定 `previewView.openExternal` 一律轉交 `GhosttyRuntime.openTerminalURL(..., kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: controller?.window)`。
  - `struct InspectorPreviewPane: View`：Browser 位址列（`‹` `›` `↻` 按鈕含 `canGoBack`/`canGoForward`/`fileURL != nil` 停用控制、目前檔名、`LIVE` 徽章、`↗` 經 `GhosttyRuntime.openTerminalURL` 安全觸發外開）+ 快速檔案 chips（來自 `GitDiffSnapshot.previewCandidates`）+ 無開啟檔案時顯示快速檔案／空狀態提示 + 嵌入式 `PreviewView` 與 `WKWebView Pipeline (Metal)` 底列。

- [ ] **Step 1: 在 `PreviewInteractions.swift` 新增 `WorkspacePreviewCoordinator` 測試（驗證 `↗` 與 `openExternal` 透過 `UntrustedURLAlert.testHook` 阻擋 `.sh`/unsafe symlink、拒絕 `/dev/zero` 與 unsafe scalars、切換 workspace 後 `backForwardList` 清空且舊 `PreviewWatcher` 停止，RED）**

- [ ] **Step 2: 實作 `InspectorPreviewPane.swift`（<= 220 行）與 `Controller.ensureFocus()` 允許 Inspector `.preview` `WKWebView` 保留焦點**

- [ ] **Step 3: 執行 `--preview` 驗證 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --preview`
Expected: PASS

- [ ] **Step 4: 提交 Task 10b-2**

```bash
git add App/Sources/LmuxUI/InspectorPreviewPane.swift App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/PreviewInteractions.swift
git commit -m "feat(ui): build InspectorPreviewPane with isolated WorkspacePreviewCoordinator and safe external link handling"
```

---

### Task 11a-1: 全寬 `32pt` 玻璃 `WindowFooterView`

**Files:**
- Create: `App/Sources/LmuxUI/WindowFooterView.swift`
- Modify: `App/Sources/lmux-apptest/LiquidGlass.swift`

**Interfaces:**
- Consumes: `PaneTelemetryDisplay`, `GitDiffSnapshot`, `InspectorTab`
- Produces (`LmuxUI`):
  - `@MainActor final class FooterBackdrop: NSView`（`NSVisualEffectView` + `tint` + 1pt 頂部邊線 + `isResizing` opaque fallback）
  - `struct WindowFooterView: View`（`32pt` 全寬列：左側 Agent 模型／最近 Tool Call／Turn 數／誠實渲染器標記 `"Metal"`（`reduceMotion` 下停止狀態點動畫）；中央 Context Window 進度條＋`%`；右側 Git 分支 `+adds -dels`、`"即時預覽"` 鈕、`⌥⌘B` 鈕；無作用中 agent / 非 Git 目錄顯示 `—`；於 `600pt` 窄窗自動優雅緊縮；全部可點擊徽章與按鈕均設無障礙 `accessibilityLabel` 並呼叫 `onInspectTab(tab)` 展開且切分頁）

- [ ] **Step 1: 在 `LiquidGlass.swift` 補入 `WindowFooterView.presentation(telemetry:git:)` 空狀態、點擊切換對應 `InspectorTab` 與 `FooterBackdrop` opaque fallback 測試（RED）**

- [ ] **Step 2: 實作 `WindowFooterView.swift`（<= 220 行）**

- [ ] **Step 3: 執行 `--liquid-glass` 驗證 GREEN**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass`
Expected: ALL PASS

- [ ] **Step 4: 提交 Task 11a-1**

```bash
git add App/Sources/LmuxUI/WindowFooterView.swift App/Sources/lmux-apptest/LiquidGlass.swift
git commit -m "feat(ui): build full-width 32pt Glass WindowFooterView with clickable telemetry & git badges"
```

---

### Task 11a-2: `RootView` 三欄＋Titlebar/Footer 總裝（含 `titlebarHost` 與窄視窗保護）與全域 `isResizing` 接線

**Files:**
- Modify: `App/Sources/LmuxUI/RootView.swift:12-345`
- Modify: `App/Sources/LmuxUI/SidebarAccessory.swift:6-34`
- Modify: `App/Sources/LmuxUI/Controller.swift:260-310, 500-590, 965-1000, 1135-1160, 1380-1410`

**Interfaces:**
- Produces (`LmuxUI`):
  - `RootView` 完整三欄佈局：
    1. 頂部 `44pt`：`TitlebarBackdrop` 在最底 + 將 `TitlebarCluster`、`TitlebarCenterChip` 與 `TitlebarRightCluster` 全部掛入 AppKit `titlebarHost` 層級確保可點擊且不搶拖曳，並維持與 güncelled `header` / `Titlebar.swift` / `RealWindow.swift` / `Contrast.swift` 相容介面。
    2. 底部 `32pt`：`FooterBackdrop` + `WindowFooterView`（以 `SidebarHostingView` 承載）。
    3. 中間三欄：左側 `WorkspaceFilterHeader`（位於 `sidebarHost` 上方）+ `SidebarView` + `NotificationBar`；中央帶有 `paneGap` 玻璃畫布與分割樹；右側 `RightInspectorResizeHandle` + `RightInspectorBackdrop` + `RightInspectorView`。
    4. **窄視窗保護**：`RootView.layout()` 若視窗寬度扣除左側欄後不足以同時容納 `RightInspector`（>=240）與中央終端（`>=120`），暫時隱藏右側 Inspector 排版並將左側欄寬度上限鉗製，絕不改變使用者保存的 `model.inspectorVisible` 設定，維持 `NewUser.swift` (`420×260`) 終端機寬度 `>= 120` 成立。
  - `RootView.setAllBackdropsResizing(_ active: Bool)`：統一同步 `sidebarBackdrop`、`titlebarBackdrop`、`rightInspectorBackdrop`、`footerBackdrop` 的 `isResizing`；`SidebarAccessory.setSidebarResizing(_:)` 轉發至此；`sidebarAccessoryMaxHeight` 正確扣除 `footerHeight` + `workspaceFilterHeaderHeight`。
  - `Controller`：在 `select(_:)`、`focus(_:)`、`paneDidChangeDirectory`、`setTitle`、Hook `postToolUse`/`stop` 觸發 debounced `model.gitDiffService.refresh(cwd:)`，在 `applyAppearance()` 同步所有 Backdrop 外觀，並於切換 workspace 時通知 `WorkspacePreviewCoordinator` 乾淨重建預覽。

- [ ] **Step 1: 實作 `RootView.swift`、`SidebarAccessory.swift` 與 `Controller.swift` 完整三欄整合、接線 `GitDiffService` 與 `setAllBackdropsResizing(_:)`**

- [ ] **Step 2: 執行 `--titlebar`、`--contrast`、`--sidebar`、`--sidebar-tabs`、`--pane-tabs`、`--preview` 與 `--newuser` 確認現有與新 UI 整合後無回歸**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --titlebar --contrast --sidebar --sidebar-tabs --pane-tabs --preview --newuser`
Expected: ALL PASS

- [ ] **Step 3: 提交 Task 11a-2**

```bash
git add App/Sources/LmuxUI/RootView.swift App/Sources/LmuxUI/SidebarAccessory.swift App/Sources/LmuxUI/Controller.swift
git commit -m "feat(ui): assemble 3-column RootView, titlebarHost chrome, narrow-window clamp, and global drag guard"
```

---

### Task 11b: `NotificationBar` 收合狀態與 1:1 玻璃卡片對齊

**Files:**
- Modify: `App/Sources/LmuxNotificationBar/NotificationBar.swift:12-198`
- Modify: `App/Sources/LmuxNotificationBar/NotificationCard.swift:1-120`
- Modify: `App/Sources/lmux-apptest/LiquidGlass.swift`

**Interfaces:**
- Produces (`LmuxNotificationBar`):
  - `BarLayout`: 新增 `var isCollapsed: Bool = false` 與 `static let collapseDragThreshold: CGFloat = 42`；向下拖曳至總高度 `<= 42` 時收合並記錄原本展開 `extra`，從收合狀態向上拖曳立即展開；點擊摘要列切換 `isCollapsed`（收合後僅顯示把手＋摘要列高度，並透過 `controller.setSidebarResizing(_:)` 驅動全域 backdrop 降級）。
  - 摘要列顯示鈴鐺圖示（有未讀時右上方顯示紅點）、`Inbox` 標題與藍色未讀膠囊；`NotificationCard` 改為圓角玻璃卡片 + 未讀左側 `6pt` 藍點 + 由 `sourcePane(entry, in: controller.model)?.branch` 顯示分支資訊，同時完整遵守 `notification-cards.feature`（無任務名稱／第一二行重複不重複顯示等規則）。

- [ ] **Step 1: 在 `LiquidGlass.swift` 加入 `BarLayout` 點擊摘要列收合/展開與拖曳過低閾值自動收合測試（RED）**

- [ ] **Step 2: 實作 `NotificationBar.swift` 與 `NotificationCard.swift`**

- [ ] **Step 3: 執行 `--liquid-glass` 與 `--bell` 驗證所有通知 bar 互動與既有 `notification-cards` 場景全數 PASS**

Run: `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh --liquid-glass --bell`
Expected: ALL PASS

- [ ] **Step 4: 提交 Task 11b**

```bash
git add App/Sources/LmuxNotificationBar/NotificationBar.swift App/Sources/LmuxNotificationBar/NotificationCard.swift App/Sources/lmux-apptest/LiquidGlass.swift
git commit -m "feat(notification-bar): add collapse toggle, drag-threshold collapse, bell red dot, and glass cards"
```

---

### Task 12: E2E 完整整合測試（`LiquidGlassWorkbenchTests`）、`@covered-by` 對齊、全套回歸與實機雙主題對照

**Files:**
- Create: `App/Sources/lmux-apptest/LiquidGlassWorkbenchTests.swift`（維持 <= 300 行）
- Modify: `App/Sources/lmux-apptest/LiquidGlass.swift`
- Modify: `App/Sources/lmux-apptest/main.swift`
- Modify: `App/scripts/apptest.sh`（於 `run_liquid_glass_suite` 加入 `--liquid-glass-workbench` 與 `--liquid-glass-restore`）
- Modify: `beat/changes/preview-liquid-glass/features/liquid-glass-app.feature`
- Modify: `beat/changes/preview-liquid-glass/features/open-menu.feature`
- Create: `beat/changes/preview-liquid-glass/manual-verification.md`

**Interfaces:**
- Produces (`lmux-apptest`): `runLiquidGlassWorkbench()` 與重啟驗證 `--liquid-glass-restore`（驗證 `inspectorVisible`、`inspectorWidth`、`inspectorTab` 與 `BarLayout.isCollapsed` / `extra` 持久化還原）。

- [ ] **Step 1: 建立 `LiquidGlassWorkbenchTests.swift` 完整覆蓋剩餘 `@e2e` 與 `@error-handling` 場景**

包含真實環境端到端測試（標註對應 `// @feature:` 與 `// @scenario:`）：
1. **全域毛玻璃 & Reduce Transparency（4 個面板 × Light/Dark）**：檢查 `SidebarBackdrop`、`TitlebarBackdrop`、`RightInspectorBackdrop`、`FooterBackdrop` 在一般模式開啟模糊＋亮邊，在 `accessibilityDisplayShouldReduceTransparency` / `forceOpaque` 時全數切換為主題不透明實底。
2. **Reduce Motion**：設 `c.model.reduceMotionOverride = true` / `reduceMotion`，確認側欄展開收合與 `TitlebarCenterChip`／`WindowFooterView` 呼吸點／卡片光環停止動畫（`animatedLayers == 0`、`pulsingViews == 0`）。
3. **5 種調整目標拖曳大小 + 邊界鉗製 + 失焦復原 + 重啟拖曳**：左側欄（`180...400`）、右側 Inspector（`240...500`）、通知 bar、窗格分割線、`NSWindow.willStartLiveResize`，於每次拖曳確認 4 個 Backdrop 同時 `isResizing == true`，並在放開／`didResignKey`／`didResignActive`／`viewWillMove(toWindow: nil)` 清除全域 `isResizing` 與把手高亮，且可再次拖曳。
4. **即時 Socket Hook → Footer & Inspector 執行記錄串流 + 切換 Workspace 上下文同步**：送入 `sendHook`（`UserPromptSubmit` → `PreToolUse` → `PostToolUse` → `PostToolUseFailure`）確認 Footer 與 Inspector 同步更新，切換至另一目錄／Git 分支 Workspace 時 Titlebar、Diff、Preview 列表、Footer 同步刷新（或正確進入空狀態），並在重開（`--liquid-glass-restore`）還原 `inspectorVisible`、`inspectorWidth`、`inspectorTab`。
5. **Inspector 即時預覽完整瀏覽**：驗證快速切換 chips → `‹`（Back）→ `›`（Forward）→ `↻`（Reload）、`LIVE` 狀態與 `WindowFooterView` 各區點擊跳轉。

- [ ] **Step 2: 補齊 `liquid-glass-app.feature` 與 `open-menu.feature` 所有場景的 `@covered-by:` 標註（同時檢查所有 `@behavior` 與 `@e2e` 測試檔皆有 `// @feature:` 與 `// @scenario:`）**

- [ ] **Step 3: 執行完整自動化測試矩陣（含 `--restore` 等非 `--quick` 檢查）**

Run:
1. `swift test --package-path Core`
2. `PATH="/tmp/swift-native-shim:$PATH" ./beat/changes/preview-liquid-glass/dev.sh check`
3. `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/apptest.sh`
4. `PATH="/tmp/swift-native-shim:$PATH" ./App/scripts/bundle.sh`
Expected: 100% PASS（zero skipped/failed cases），產出 clean release `App/build/lmux.app`（`sdk 27.2`）。

- [ ] **Step 4: 雙主題實機啟動／截圖 1:1 對照驗收並紀錄於 `manual-verification.md`**

分別以淺色（`LMUX_APPEARANCE=light`）與深色（`LMUX_APPEARANCE=dark`）啟動 `App/build/lmux.app`（使用隔離 `LMUX_STATE_DIR`），逐項比對 `preview-mockup.html`（44pt Titlebar 置中膠囊、左側玻璃卡片＋藥丸＋搜尋＋通知 bar、中央圓角終端＋Pane Tab Strip＋active-ring、右側 Inspector 三分頁、32pt Footer、所有拖曳降級）並於 `beat/changes/preview-liquid-glass/manual-verification.md` 紀錄檢核結果，同時於背景保持最新版前景 app 供使用者立即實測。

- [ ] **Step 5: 提交 Task 12**

```bash
git add App/Sources/lmux-apptest/ App/scripts/apptest.sh beat/changes/preview-liquid-glass/features/ beat/changes/preview-liquid-glass/manual-verification.md
git commit -m "test(liquid-glass): complete E2E workbench, restore, and manual visual parity verification"
```
