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

        // Running tool marked interrupted on Interrupt with exact durationMs
        var preEdit = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        preEdit.toolName = "Edit"; preEdit.toolUseID = "tu-3"; preEdit.sentAtNanos = 3_000_000_000
        agent.handle(preEdit, focused: true)
        var interruptEv = HookEvent(paneID: "p1", name: HookEvent.Kind.interrupt.rawValue)
        interruptEv.sentAtNanos = 3_075_000_000
        agent.handle(interruptEv, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .interrupted)
        XCTAssertEqual(agent.toolStream.entries.last?.durationMs, 75)

        // toolName-only fallback must match running entry with matching name rather than a newer unrelated running entry
        var fallbackBash = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        fallbackBash.toolName = "Bash"; fallbackBash.toolUseID = "tu-fb-bash"; fallbackBash.sentAtNanos = 3_500_000_000
        agent.handle(fallbackBash, focused: true)
        var fallbackOther = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        fallbackOther.toolName = "Edit"; fallbackOther.toolUseID = "tu-fb-edit"; fallbackOther.sentAtNanos = 3_550_000_000
        agent.handle(fallbackOther, focused: true)
        var postFallbackBash = HookEvent(paneID: "p1", name: HookEvent.Kind.postToolUse.rawValue)
        postFallbackBash.toolName = "Bash"; postFallbackBash.sentAtNanos = 3_800_000_000
        agent.handle(postFallbackBash, focused: true)
        let fbBashEntry = agent.toolStream.entries.first(where: { $0.id == "tu-fb-bash" })
        let fbOtherEntry = agent.toolStream.entries.first(where: { $0.id == "tu-fb-edit" })
        XCTAssertEqual(fbBashEntry?.status, .succeeded)
        XCTAssertEqual(fbBashEntry?.durationMs, 300)
        XCTAssertEqual(fbOtherEntry?.status, .running)

        // Bounded ring cap = 50 evicts oldest
        for i in 1...55 {
            var ev = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
            ev.toolName = "Grep"; ev.toolUseID = "cap-\(i)"; ev.sentAtNanos = 4_000_000_000
            agent.handle(ev, focused: true)
        }
        XCTAssertEqual(agent.toolStream.entries.count, ToolCallStream.cap)
        XCTAssertEqual(agent.toolStream.entries.first?.id, "cap-6")

        // Main stop finalizes lingering .running entries with exact durationMs
        var mainStopEv = HookEvent(paneID: "p1", name: HookEvent.Kind.stop.rawValue)
        mainStopEv.sentAtNanos = 4_250_000_000
        agent.handle(mainStopEv, focused: true)
        XCTAssertFalse(agent.toolStream.entries.contains { $0.status == .running })
        XCTAssertEqual(agent.toolStream.entries.last?.durationMs, 250)

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

        // Duplicate toolUseID creates distinct entry instead of colliding, and postToolUse with that ID completes both in LIFO order
        var dup1 = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        dup1.toolName = "CustomMcpTool"; dup1.toolUseID = "dup-1"; dup1.sentAtNanos = 6_000_000_000
        agent.handle(dup1, focused: true)
        var dup2 = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        dup2.toolName = "CustomMcpTool"; dup2.toolUseID = "dup-1"; dup2.sentAtNanos = 6_050_000_000
        agent.handle(dup2, focused: true)
        XCTAssertEqual(agent.toolStream.entries.suffix(2).count, 2)
        XCTAssertNotEqual(agent.toolStream.entries[agent.toolStream.entries.count - 2].id,
                          agent.toolStream.entries[agent.toolStream.entries.count - 1].id)
        XCTAssertEqual(agent.toolStream.entries.last?.category, .other)
        var postDup = HookEvent(paneID: "p1", name: HookEvent.Kind.postToolUse.rawValue)
        postDup.toolName = "CustomMcpTool"; postDup.toolUseID = "dup-1"; postDup.sentAtNanos = 6_100_000_000
        agent.handle(postDup, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .succeeded)
        XCTAssertEqual(agent.toolStream.entries[agent.toolStream.entries.count - 2].status, .running)
        postDup.sentAtNanos = 6_200_000_000
        agent.handle(postDup, focused: true)
        XCTAssertEqual(agent.toolStream.entries[agent.toolStream.entries.count - 2].status, .succeeded)

        // nil-ID/nil-name completion fallback still finalizes latest running tool
        var unnamedPre = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        unnamedPre.toolName = "Edit"
        agent.handle(unnamedPre, focused: true)
        agent.handle(HookEvent(paneID: "p1", name: HookEvent.Kind.postToolUse.rawValue), focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .succeeded)

        // userInterrupted() finalizes running tools as .interrupted without wiping history
        var interruptedPre = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        interruptedPre.toolName = "Bash"; interruptedPre.toolUseID = "tu-int"
        agent.handle(interruptedPre, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .running)
        agent.userInterrupted()
        XCTAssertEqual(agent.state, .idle)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .interrupted)
        XCTAssertNotNil(agent.toolStream.entries.last?.durationMs)

        // report(.idle) finalizes running tools as .interrupted without wiping prior entries
        var idlePre = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        idlePre.toolName = "Read"; idlePre.toolUseID = "tu-idle"
        agent.handle(idlePre, focused: true)
        let countBeforeIdle = agent.toolStream.entries.count
        agent.report(.idle, focused: true)
        XCTAssertEqual(agent.state, .idle)
        XCTAssertEqual(agent.toolStream.entries.count, countBeforeIdle)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .interrupted)

        // report(.error) finalizes running tools as .failed without wiping prior entries
        var errPre = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        errPre.toolName = "Bash"; errPre.toolUseID = "tu-err"
        agent.handle(errPre, focused: true)
        let countBeforeError = agent.toolStream.entries.count
        agent.report(.error, focused: true)
        XCTAssertEqual(agent.state, .done)
        XCTAssertEqual(agent.toolStream.entries.count, countBeforeError)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .failed)

        // report(.done) finalizes running tools as .succeeded without wiping prior entries
        var donePre = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        donePre.toolName = "Bash"; donePre.toolUseID = "tu-done"
        agent.handle(donePre, focused: true)
        let countBeforeDone = agent.toolStream.entries.count
        agent.report(.done, focused: true)
        XCTAssertEqual(agent.state, .done)
        XCTAssertEqual(agent.toolStream.entries.count, countBeforeDone)
        XCTAssertEqual(agent.toolStream.entries.last?.status, .succeeded)

        // report(.clear) clears toolStream
        agent.report(.clear, focused: true)
        XCTAssertEqual(agent.state, .idle)
        XCTAssertTrue(agent.toolStream.entries.isEmpty)

        // Direct resetToolStream() helper (used on codexReport OSC 7501 early-return path)
        agent.handle(errPre, focused: true)
        agent.resetToolStream()
        XCTAssertTrue(agent.toolStream.entries.isEmpty)
        XCTAssertEqual(agent.toolStream.turnCount, 0)

        // PostToolUse backfills missing argument and search tools map to .search
        var preSearch = HookEvent(paneID: "p1", name: HookEvent.Kind.preToolUse.rawValue)
        preSearch.toolName = "WebSearch"; preSearch.toolUseID = "tu-ws"
        agent.handle(preSearch, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.category, .search)
        XCTAssertNil(agent.toolStream.entries.last?.argument)
        var postSearch = HookEvent(paneID: "p1", name: HookEvent.Kind.postToolUse.rawValue)
        postSearch.toolName = "WebSearch"; postSearch.toolUseID = "tu-ws"; postSearch.toolArgument = "swift 6"
        agent.handle(postSearch, focused: true)
        XCTAssertEqual(agent.toolStream.entries.last?.argument, "swift 6")
    }
}
