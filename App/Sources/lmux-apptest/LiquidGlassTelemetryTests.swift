// @feature: liquid-glass-app.feature
// @scenario: Git Diff 服務讀取工作區變更統計與檔案 hunks，非 Git 目錄呈現空狀態
// @scenario: Hook 即時工具事件與終止事件更新即時 Tool Call 串流與狀態

import Foundation
import AppKit
import LmuxHooks
import LmuxTokens
import LmuxTranscript
@testable import LmuxUI

@MainActor
func runLiquidGlassTelemetry() async -> Int32 {
    let r = Report()
    r.section = "liquid-glass-telemetry"

    // 1. parseNumstat & parseUnifiedDiff
    let sampleNumstat = """
    10\t2\tSources/App.swift
    -\t-\tAssets/logo.png
    5\t0\tREADME.md
    """
    let numstatParsed = GitDiffService.parseNumstat(sampleNumstat)
    r.check("parseNumstat parses added/deleted and marks binary",
            numstatParsed.count == 3
            && numstatParsed[0].path == "Sources/App.swift" && numstatParsed[0].added == 10 && numstatParsed[0].deleted == 2 && !numstatParsed[0].isBinary
            && numstatParsed[1].path == "Assets/logo.png" && numstatParsed[1].isBinary
            && numstatParsed[2].path == "README.md" && numstatParsed[2].added == 5 && numstatParsed[2].deleted == 0)

    let sampleDiff = """
    diff --git a/README.md b/README.md
    index 1234567..89abcde 100644
    --- a/README.md
    +++ b/README.md
    @@ -1,3 +1,4 @@
     # Title
    +New Line 1
    +New Line 2
     End
    diff --git a/my notes.md b/my notes.md
    index 1111111..2222222 100644
    --- a/my notes.md
    +++ b/my notes.md
    @@ -10,3 +10,2 @@
     old line
    -    old()
    +    new()
     end
    """
    let filesDiff = GitDiffService.parseUnifiedDiff(sampleDiff, maxLines: 2)
    r.check("parseUnifiedDiff parses multiple files including spaces with maxLines truncation",
            filesDiff.count == 2
            && filesDiff[0].path == "README.md"
            && filesDiff[0].lines.count <= 2
            && filesDiff[0].truncated == true
            && filesDiff[1].path == "my notes.md")

    // 2. Malicious git config diff.external + core.fsmonitor test
    let fm = FileManager.default
    let pwnedPath = "/tmp/pwned_\(UUID().uuidString)"
    let pwnedFsMonitorPath = "/tmp/pwned_fsmonitor_\(UUID().uuidString)"
    let repoA = fm.temporaryDirectory.appendingPathComponent("repo-a-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: repoA)
        try? fm.removeItem(atPath: pwnedPath)
        try? fm.removeItem(atPath: pwnedFsMonitorPath)
    }
    try? fm.createDirectory(at: repoA, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "main"], env: ["GIT_DIR": repoA.appendingPathComponent(".git").path])
    let testFile = repoA.appendingPathComponent("test.txt")
    try? "line1\nline2\n".write(to: testFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "add", "test.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    // Configure malicious diff.external and core.fsmonitor after commit setup so only GitDiffService is tested.
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "config", "diff.external", "touch \(pwnedPath)"])
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "config", "core.fsmonitor", "touch \(pwnedFsMonitorPath)"])
    try? "line1\nline2-edited\nline3\n".write(to: testFile, atomically: true, encoding: .utf8)

    let svc = GitDiffService()
    svc.refresh(cwd: repoA.path, immediate: true)
    let refreshed = await waitFor(3) { !svc.isLoading && svc.snapshot.isGitRepo }
    let testDiff = svc.snapshot.files.first(where: { $0.path == "test.txt" })
    r.check("refresh on git repo finishes without loading", refreshed)
    r.check("malicious diff.external and core.fsmonitor are never executed",
            !fm.fileExists(atPath: pwnedPath) && !fm.fileExists(atPath: pwnedFsMonitorPath))
    r.check("snapshot has real unified diff hunks, exact added/deleted counts, and branch",
            svc.snapshot.isGitRepo
            && svc.snapshot.branch == "main"
            && svc.snapshot.totalAdded == 2
            && svc.snapshot.totalDeleted == 1
            && (testDiff?.lines.contains(where: { $0.kind == .hunkHeader && $0.text.hasPrefix("@@") }) == true),
            "added=\(svc.snapshot.totalAdded) deleted=\(svc.snapshot.totalDeleted) lines=\(testDiff?.lines.count ?? 0)")

    // 3. Unborn HEAD repository
    let unbornRepo = fm.temporaryDirectory.appendingPathComponent("unborn-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: unbornRepo) }
    try? fm.createDirectory(at: unbornRepo, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "feat/unborn"], env: ["GIT_DIR": unbornRepo.appendingPathComponent(".git").path])
    let unbornFile = unbornRepo.appendingPathComponent("README.md")
    try? "# Unborn\n".write(to: unbornFile, atomically: true, encoding: .utf8)

    svc.refresh(cwd: unbornRepo.path, immediate: true)
    _ = await waitFor(3) { !svc.isLoading && svc.snapshot.isGitRepo }
    r.check("unborn HEAD reports isGitRepo without crash and finds untracked/staged files",
            svc.snapshot.isGitRepo
            && svc.snapshot.branch == "feat/unborn"
            && !svc.snapshot.files.isEmpty)

    // 4. previewCandidates with README.md prioritization and unsafe scalar / symlink filtering
    let safeFile = unbornRepo.appendingPathComponent("sample.html")
    try? "<h1>hi</h1>".write(to: safeFile, atomically: true, encoding: .utf8)
    let symlinkToPasswd = unbornRepo.appendingPathComponent("passwd_link.txt")
    try? fm.createSymbolicLink(at: symlinkToPasswd, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))

    svc.refresh(cwd: unbornRepo.path, immediate: true)
    _ = await waitFor(3) { !svc.isLoading && !svc.snapshot.previewCandidates.isEmpty }
    let candidates = svc.snapshot.previewCandidates
    r.check("previewCandidates prioritizes README.md and excludes unsafe symlink outside repo",
            candidates.first?.lastPathComponent == "README.md"
            && !candidates.contains(where: { $0.lastPathComponent == "passwd_link.txt" }))

    // 5. Non-git directory and generation cancellation
    let nonGitDir = fm.temporaryDirectory.appendingPathComponent("nongit-\(UUID().uuidString)")
    let targetDir = fm.temporaryDirectory.appendingPathComponent("target-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: nonGitDir)
        try? fm.removeItem(at: targetDir)
    }
    try? fm.createDirectory(at: nonGitDir, withIntermediateDirectories: true)
    try? "# Non-Git Preview\n".write(to: nonGitDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "target-branch"], env: ["GIT_DIR": targetDir.appendingPathComponent(".git").path])

    svc.refresh(cwd: nonGitDir.path, immediate: true)
    _ = await waitFor(3) { !svc.isLoading && svc.snapshot.cwd == nonGitDir.path }
    r.check("non-git directory sets isGitRepo = false, empty files, and scans previewCandidates",
            !svc.snapshot.isGitRepo && svc.snapshot.files.isEmpty && svc.snapshot.previewCandidates.first?.lastPathComponent == "README.md")

    // Rapid switch (cancellation)
    svc.refresh(cwd: nonGitDir.path)
    svc.refresh(cwd: targetDir.path, immediate: true)
    _ = await waitFor(3) { !svc.isLoading && svc.snapshot.cwd == targetDir.path }
    r.check("rapid directory switch keeps the final directory result",
            svc.snapshot.cwd == targetDir.path && svc.snapshot.isGitRepo && svc.snapshot.branch == "target-branch")

    // 6. LayoutFile backwards-compatible decoding & out-of-bounds clamping
    let legacyJSON = """
    {
      "version": 1,
      "workspaces": [],
      "sidebarVisible": true,
      "sidebarWidth": 260.0
    }
    """
    if let legacyLayout = try? JSONDecoder().decode(LayoutFile.self, from: Data(legacyJSON.utf8)) {
        r.check("legacy layout.json decodes with default inspectorVisible == true", legacyLayout.inspectorVisible == true)
        r.check("legacy layout.json decodes with default inspectorWidth == 320", legacyLayout.inspectorWidth == Double(LmuxTokens.Layout.rightInspectorWidthDefault))
        r.check("legacy layout.json decodes with default inspectorTab == .preview", legacyLayout.inspectorTab == .preview)
    } else {
        r.check("legacy layout.json decodes with default inspectorVisible == true", false)
        r.check("legacy layout.json decodes with default inspectorWidth == 320", false)
        r.check("legacy layout.json decodes with default inspectorTab == .preview", false)
    }

    let outOfBoundsJSON = """
    {
      "version": 1,
      "workspaces": [],
      "sidebarVisible": true,
      "sidebarWidth": 260.0,
      "inspectorVisible": false,
      "inspectorWidth": 999.0,
      "inspectorTab": "diff"
    }
    """
    if let clampedLayout = try? JSONDecoder().decode(LayoutFile.self, from: Data(outOfBoundsJSON.utf8)) {
        r.check("out-of-bounds inspectorWidth 999 is clamped to 500", clampedLayout.inspectorWidth == Double(LmuxTokens.Layout.rightInspectorWidthMax))
        r.check("inspectorVisible is restored as false", clampedLayout.inspectorVisible == false)
        r.check("inspectorTab is restored as diff", clampedLayout.inspectorTab == .diff)
    } else {
        r.check("out-of-bounds inspectorWidth 999 is clamped to 500", false)
        r.check("inspectorVisible is restored as false", false)
        r.check("inspectorTab is restored as diff", false)
    }

    // 7. AppModel inspector & workspaceFilter defaults and roundtrip
    let model = AppModel()
    r.check("AppModel default inspectorVisible is true", model.inspectorVisible == true)
    r.check("AppModel default inspectorWidth is 320", model.inspectorWidth == LmuxTokens.Layout.rightInspectorWidthDefault)
    r.check("AppModel default inspectorTab is .preview", model.inspectorTab == .preview)
    r.check("AppModel default workspaceFilter is .all", model.workspaceFilter == .all)
    r.check("AppModel reduceMotionOverride initially nil", model.reduceMotionOverride == nil)

    let testWorkspaceURL = URL(fileURLWithPath: "/tmp/sample-preview.html")
    model.inspectorPreviewURLByWorkspace["ws-1"] = testWorkspaceURL
    r.check("inspectorPreviewURLByWorkspace remembers preview url",
            model.inspectorPreviewURLByWorkspace["ws-1"] == testWorkspaceURL)

    // Snapshot layout roundtrip
    let c = makeController()
    c.model.inspectorVisible = false
    c.model.inspectorWidth = 360
    c.model.inspectorTab = .trace
    let snap = c.snapshotLayout()
    r.check("snapshotLayout includes inspectorVisible false", snap.inspectorVisible == false)
    r.check("snapshotLayout includes inspectorWidth 360", snap.inspectorWidth == 360)
    r.check("snapshotLayout includes inspectorTab .trace", snap.inspectorTab == .trace)

    // 8. AgentTelemetryStore, Codex codexReport tool streaming, and sessionEnd cleanup
    let ws = c.model.workspaces.first!
    let pane = ws.panes.first!
    let store = c.model.telemetryStore ?? AgentTelemetryStore()
    c.model.telemetryStore = store

    let initialDisplay = store.display(for: pane)
    r.check("initial telemetry has 0 turns and inactive",
            initialDisplay.turnCount == 0 && !initialDisplay.isActiveAgent)

    let fakeTelemetry = AgentTelemetrySnapshot(
        model: "claude-sonnet-4.5",
        turnCount: 2,
        contextUsedTokens: 15_000,
        contextLimitTokens: 200_000,
        inputTokens: 10_000,
        outputTokens: 500,
        cacheReadTokens: 4_500,
        estimatedCostUSD: 0.05
    )
    store.recordSnapshot(fakeTelemetry, for: pane.id)
    var d = store.display(for: pane)
    r.check("recordSnapshot updates display model and tokens",
            d.model == "claude-sonnet-4.5" && d.turnCount == 2 && d.contextUsedTokens == 15_000)

    // Verify turnCount takes max(jsonl.turnCount, toolStream.turnCount)
    var promptEvent = HookEvent(paneID: pane.id, name: "UserPromptSubmit")
    promptEvent.agent = .claude
    pane.agent.recordToolEvent(promptEvent)
    pane.agent.recordToolEvent(promptEvent)
    pane.agent.recordToolEvent(promptEvent) // toolStream.turnCount = 3 > 2
    d = store.display(for: pane)
    r.check("display turnCount uses max of jsonl and toolStream", d.turnCount == 3)

    // Verify Codex in codexReport mode still captures tool events via HookEvent
    pane.codexReport = .working
    pane.agentKind = .codex
    var toolEvent = try! HookEvent(paneID: pane.id, payload: [
        "hook_event_name": "PreToolUse",
        "session_id": "codex-1",
        "tool_name": "Bash",
        "tool_input": ["command": "make test"],
        "tool_use_id": "call_cdx_1"
    ])
    toolEvent.agent = .codex
    c.handleHook(toolEvent)
    d = store.display(for: pane)
    r.check("codexReport mode records tool events into ToolCallStream",
            d.toolCalls.contains(where: { $0.id == "call_cdx_1" && $0.name == "Bash" && $0.category == .bash }))

    // Verify sessionEnd clears telemetry snapshot
    var endEvent = try! HookEvent(paneID: pane.id, payload: [
        "hook_event_name": "SessionEnd",
        "session_id": "codex-1"
    ])
    endEvent.agent = .codex
    c.handleHook(endEvent)
    d = store.display(for: pane)
    r.check("sessionEnd clears telemetry snapshot in AgentTelemetryStore",
            d.contextUsedTokens == 0)

    // Real JSONL transcript -> Controller.scheduleTelemetryRefresh -> TranscriptCache -> AgentTelemetryStore end-to-end
    let liveTranscript = fm.temporaryDirectory.appendingPathComponent("live-telemetry-\(UUID().uuidString).jsonl")
    defer { try? fm.removeItem(at: liveTranscript) }
    let jsonlLine = #"{"type":"assistant","uuid":"u-e2e-1","parentUuid":null,"timestamp":"2026-11-19T10:00:00Z","message":{"id":"msg_e2e_1","role":"assistant","model":"claude-sonnet-4-5-20250929","content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":1200,"cache_read_input_tokens":800,"output_tokens":300}}}"# + "\n"
    try? jsonlLine.write(to: liveTranscript, atomically: true, encoding: .utf8)
    pane.claudeSessionID = "sess-live-e2e"
    pane.transcriptPath = liveTranscript.path
    c.scheduleTelemetryRefresh(pane, delay: 0.01)
    let liveReady = await waitFor(3) { store.display(for: pane).model == "claude-sonnet-4-5-20250929" }
    let liveDisplay = store.display(for: pane)
    r.check("Controller.scheduleTelemetryRefresh parses real JSONL file into AgentTelemetryStore",
            liveReady
            && liveDisplay.inputTokens == 1200
            && liveDisplay.outputTokens == 300
            && liveDisplay.cacheReadTokens == 800
            && liveDisplay.contextUsedTokens == 2000)

    // 7. InspectorDiffView.displayState(for:)
    let nonGitSnap = GitDiffSnapshot(cwd: "/tmp", isGitRepo: false)
    r.check("InspectorDiffView.displayState for non-git repo",
            InspectorDiffView.displayState(for: nonGitSnap) == .notGitRepo)

    let cleanSnap = GitDiffSnapshot(cwd: "/tmp", isGitRepo: true, branch: "main", files: [])
    r.check("InspectorDiffView.displayState for clean git repo",
            InspectorDiffView.displayState(for: cleanSnap) == .clean(branch: "main"))

    let diffFile = GitDiffFile(path: "Sources/Main.swift", status: "M", added: 5, deleted: 2, lines: [
        GitDiffLine(id: 0, kind: .added, text: "+let x = 1"),
        GitDiffLine(id: 1, kind: .removed, text: "-let x = 0")
    ])
    let dirtySnap = GitDiffSnapshot(cwd: "/tmp", isGitRepo: true, branch: "feat", totalAdded: 5, totalDeleted: 2, files: [diffFile])
    r.check("InspectorDiffView.displayState for dirty git repo",
            InspectorDiffView.displayState(for: dirtySnap) == .diff(branch: "feat", fileCount: 1, added: 5, deleted: 2))

    // symlink / unsafe preview check
    r.check("InspectorDiffView.resolvePreviewURL rejects unsafe control characters",
            InspectorDiffView.resolvePreviewURL(file: "test\u{202E}file.txt", cwd: "/tmp") == nil)

    // 8. InspectorTraceView.presentation(for:)
    let emptyDisplay = PaneTelemetryDisplay()
    let emptyPres = InspectorTraceView.presentation(for: emptyDisplay)
    r.check("InspectorTraceView empty display state",
            !emptyPres.hasActiveAgent && emptyPres.modelName == "—" && emptyPres.costText == "—")

    let activeDisplay = PaneTelemetryDisplay(
        model: "claude-3-7-sonnet",
        turnCount: 5,
        contextUsedTokens: 45_000,
        contextLimitTokens: 200_000,
        inputTokens: 30_000,
        outputTokens: 5_000,
        cacheReadTokens: 10_000,
        estimatedCostUSD: 0.1234,
        contextPercent: 0.225,
        toolCalls: [
            ToolCallEntry(id: "1", name: "Bash", category: .bash, argument: "ls -la", status: .succeeded, startedAtNanos: 0, durationMs: 42),
            ToolCallEntry(id: "2", name: "Read", category: .read, argument: "file.txt", status: .running, startedAtNanos: 0)
        ],
        isActiveAgent: true
    )
    let activePres = InspectorTraceView.presentation(for: activeDisplay)
    r.check("InspectorTraceView active presentation formatting",
            activePres.hasActiveAgent && activePres.modelName == "claude-3-7-sonnet"
            && activePres.contextPercentText == "22.5%"
            && activePres.contextTokensText == "45.0k / 200.0k"
            && activePres.costText == "$0.1234"
            && activePres.toolCalls.count == 2
            && activePres.toolCalls[0].category == .bash
            && activePres.toolCalls[1].category == .read)

    print("\nRESULT: \(r.failed == 0 ? "PASS" : "FAIL") (\(r.passed)/\(r.passed + r.failed) checks passed)\n")
    return r.failed == 0 ? 0 : 1
}
