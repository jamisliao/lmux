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
    }
}
