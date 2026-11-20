// @feature: liquid-glass-app.feature
// @scenario: Hook 即時工具事件與終止事件更新即時 Tool Call 串流與狀態
import XCTest
@testable import LmuxHooks

final class ToolCallStreamTests: XCTestCase {
    func testToolCallStreamTracksCategoriesDurationsFallbackIDFailureInterruptAndCap() {
        var agent = PaneAgent()
        let prompt = HookEvent(paneID: "p1", name: HookEvent.Kind.userPromptSubmit.rawValue)
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

        // Main stop finalizes lingering .running entries so dropped PostToolUse never stays stuck
        agent.handle(HookEvent(paneID: "p1", name: HookEvent.Kind.stop.rawValue), focused: true)
        XCTAssertFalse(agent.toolStream.entries.contains { $0.status == .running })
        XCTAssertLessThan(agent.toolStream.entries.last?.durationMs ?? Int.max, 60_000)

        // Non-compact SessionStart (/clear) resets toolStream
        agent.handle(HookEvent(paneID: "p1", name: HookEvent.Kind.sessionStart.rawValue), focused: true)
        XCTAssertTrue(agent.toolStream.entries.isEmpty)
        XCTAssertEqual(agent.toolStream.turnCount, 0)

        // Subagent stop does not finalize main-agent running tools; main stopFailure -> .failed
        var mainPre = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        mainPre.toolName = "  gLoB  "; mainPre.toolUseID = "tu-main"; mainPre.sentAtNanos = 5_000_000_000
        agent.handle(mainPre, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.category, .search)
        var subStop = HookEvent(paneID: "p1", name: HookEvent.Kind.stop.rawValue)
        subStop.agentID = "sub-1"; subStop.sentAtNanos = 5_100_000_000
        agent.handle(subStop, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .running)

        // Backward clock timestamp clamps duration to 0ms on stopFailure -> .failed
        var mainStopFail = HookEvent(paneID: "p1", name: HookEvent.Kind.stopFailure.rawValue)
        mainStopFail.sentAtNanos = 4_000_000_000
        agent.handle(mainStopFail, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .failed)
        XCTAssertEqual(agent.toolStream.entries.last?.durationMs, 0)

        // Duplicate toolUseID creates distinct entry instead of colliding; nil-ID/nil-name completion fallback; .other category
        var dup1 = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        dup1.toolName = "CustomMcpTool"; dup1.toolUseID = "dup-1"
        agent.handle(dup1, focused: true)
        var dup2 = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        dup2.toolName = "CustomMcpTool"; dup2.toolUseID = "dup-1"
        agent.handle(dup2, focused: true)
        XCTAssertEqual(agent.toolStream.entries.suffix(2).count, 2)
        XCTAssertNotEqual(agent.toolStream.entries[agent.toolStream.entries.count - 2].id,
                          agent.toolStream.entries[agent.toolStream.entries.count - 1].id)
        XCTAssertEqual(agent.toolStream.entries.last?.category, .other)
        agent.handle(HookEvent(paneID: "p1", name: HookEvent.Kind.postToolUse.rawValue), focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .succeeded)

        // Direct resetToolStream() helper (used on codexReport OSC 7501 early-return path)
        agent.resetToolStream()
        XCTAssertTrue(agent.toolStream.entries.isEmpty)
        XCTAssertEqual(agent.toolStream.turnCount, 0)
    }
}
