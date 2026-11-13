import Foundation
import Testing
@testable import LmuxHooks

/// Background subagents: a main-agent Stop whose `background_tasks` lists subagents pauses the turn.
/// Entry fields per https://code.claude.com/docs/en/hooks (Stop input): id, type, status, description.
@Suite struct BackgroundSubagentTests {
    /// A main-agent Stop with `background_tasks`: `subagents` as type "subagent", `shells` as type "shell".
    func mainStop(subagents: [String] = [], shells: [String] = []) -> String {
        let entries: [String] = subagents.map { #"{"id":"\#($0)","type":"subagent","status":"running","description":"research"}"# }
            + shells.map { #"{"id":"\#($0)","type":"shell","status":"running","description":"npm run dev"}"# }
        return Payloads.json("Stop", #""stop_hook_active":false,"last_assistant_message":"Turn over.","background_tasks":["#
            + entries.joined(separator: ",") + "]")
    }

    func run(_ payloads: [String], agent: inout PaneAgent) throws -> [AgentTransition] {
        try payloads.map { agent.handle(try event($0), focused: false) }
    }
    func start(_ id: String) -> String { Payloads.json("SubagentStart", #""agent_id":"\#(id)","agent_type":"general-purpose""#) }
    func stop(_ id: String) -> String {
        Payloads.json("SubagentStop", #""agent_id":"\#(id)","agent_type":"general-purpose","stop_hook_active":false"#)
    }
    /// Subagent `id` asks for permission (its dialog shows in the main session).
    func ask(_ id: String) -> String {
        Payloads.json("PermissionRequest", #""agent_id":"\#(id)","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"make"},"tool_use_id":"toolu_\#(id)""#)
    }
    /// Subagent `id`'s tool ran (after its dialog was answered).
    func toolDone(_ id: String) -> String {
        Payloads.json("PostToolUse", #""agent_id":"\#(id)","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"make"},"tool_response":{},"tool_use_id":"toolu_\#(id)""#)
    }

    @Test func parsesBackgroundSubagentIDs() throws {
        // No field (older Claude Code, Codex): nil, so the old behavior stays.
        #expect(try event(Payloads.stop).backgroundSubagentIDs == nil)
        #expect(try event(Payloads.json("Stop", #""background_tasks":"oops""#)).backgroundSubagentIDs == nil)
        #expect(try event(mainStop()).backgroundSubagentIDs == [String]())
        // Only type "subagent" with a non-empty id counts; shells, monitors and malformed entries don't.
        let mixed = Payloads.json("Stop", #""background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"x"},{"id":"b1","type":"shell","status":"running","description":"npm run dev"},{"id":"m1","type":"monitor","status":"running","description":"m"},{"type":"subagent","status":"running"},{"id":"","type":"subagent"},"junk",{"id":"a2","type":"subagent","status":"running","description":"y"}]"#)
        #expect(try event(mixed).backgroundSubagentIDs == ["a1", "a2"])
        #expect(try event(mainStop(subagents: ["a"], shells: ["s"])).backgroundSubagentIDs == ["a"])
    }

    // @feature: background-subagent-count.feature
    // @scenario: 主 agent 結束一輪時還有背景 subagent，row 維持執行中
    @Test func stopWithBackgroundSubagentsKeepsRunning() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, start("a"), start("b"), mainStop(subagents: ["a", "b"])], agent: &a)
        #expect(t[3].to == .running && t[3].alert == nil && t[3].notify == nil)
        #expect(a.activeSubagents == ["a", "b"] && a.awaitingBackgroundSubagents)
        // A subagent's own Stop carries the parent's list too: it changes nothing.
        var b = PaneAgent()
        _ = try run([Payloads.prompt, start("a"),
                     Payloads.json("Stop", #""agent_id":"a","background_tasks":[{"id":"z","type":"subagent","status":"running"}]"#)],
                    agent: &b)
        #expect(b.state == .running && b.activeSubagents == ["a"] && !b.awaitingBackgroundSubagents)
    }

    // @feature: background-subagent-count.feature
    // @scenario: 只有前景 subagent 時，主 agent 結束一輪就變成 Done
    @Test func foregroundSubagentOnlyEndsAsDone() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, start("f"), stop("f"), mainStop()], agent: &a)
        #expect(t[3].to == .done && t[3].notify == .done(lastMessage: "Turn over."))
        #expect(a.activeSubagents.isEmpty && !a.awaitingBackgroundSubagents)
    }

    // @feature: background-subagent-count.feature
    // @scenario: 只有背景 shell 指令在執行時，主 agent 結束一輪就變成 Done
    @Test func backgroundShellAloneEndsAsDone() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, mainStop(shells: ["dev-server"])], agent: &a)
        #expect(t[1].to == .done && t[1].notify == .done(lastMessage: "Turn over."))
        #expect(!a.awaitingBackgroundSubagents)
    }

    // @feature: background-subagent-count.feature
    // @scenario: Claude Code 沒有回報背景工作清單時，維持原本的行為
    @Test func stopWithoutTheListKeepsTheOldBehavior() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, start("a"), Payloads.stop], agent: &a)
        #expect(t[2].to == .done && t[2].notify == .done(lastMessage: "All tests pass."))
        #expect(a.activeSubagents.isEmpty && !a.awaitingBackgroundSubagents)
    }

    // @feature: background-subagent-count.feature
    // @scenario: 最後一個背景 subagent 做完後，主 agent 結束一輪才發 Done 通知
    @Test func doneOnlyAfterTheLastBackgroundSubagent() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, start("a"), mainStop(subagents: ["a"]),
                         stop("a"), Payloads.prompt, mainStop()], agent: &a)
        #expect(t.compactMap(\.notify) == [.done(lastMessage: "Turn over.")])
        #expect(t[5].to == .done && a.activeSubagents.isEmpty && !a.awaitingBackgroundSubagents)
    }

    /// The pause makes the pane run whatever it showed before (here: idle after a dialog was answered).
    @Test func stopWithBackgroundSubagentsRunsEvenFromIdle() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), ask("a")], agent: &a)
        #expect(a.userTyped().to == .idle)
        let t = try run([mainStop(subagents: ["a"])], agent: &a)
        #expect(t[0].to == .running && t[0].alert == nil)
    }

    /// The pause ends with the turn however else it ends: a failure (a usage limit too), Codex's
    /// Interrupt, a new or ended session.
    @Test func otherEndingsClearThePause() throws {
        for end in [Payloads.json("StopFailure", #""error":"server_error""#), StatusExtrasTests.limit,
                    Payloads.json("Interrupt"), Payloads.sessionEnd, Payloads.sessionStart] {
            var a = PaneAgent()
            _ = try run([Payloads.prompt, start("a"), mainStop(subagents: ["a"]), end], agent: &a)
            #expect(!a.awaitingBackgroundSubagents && a.activeSubagents.isEmpty, "\(end)")
        }
    }

    /// Auto-compact mid-pause keeps it.
    @Test func compactKeepsThePause() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), mainStop(subagents: ["a"]), Payloads.compactStart], agent: &a)
        #expect(a.state == .running && a.activeSubagents == ["a"] && a.awaitingBackgroundSubagents)
    }

    @Test func backgroundListIsCapped() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, mainStop(subagents: (0..<100).map { "s\($0)" })], agent: &a)
        #expect(a.activeSubagents.count == PaneAgent.subagentCap)
    }

    /// 場景: 一個背景 subagent 回報後，其他還在執行的仍計入
    @Test func oneReportingBackKeepsTheOthersCounted() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, start("a"), start("b"), mainStop(subagents: ["a", "b"]),
                         stop("a"), Payloads.prompt], agent: &a)  // a finishes and reports back
        #expect(t[5].to == .running && t[5].alert == nil)
        #expect(a.activeSubagents == ["b"])
        #expect(!a.awaitingBackgroundSubagents)  // the main agent works again: the pause is over
    }

    /// 場景: 背景 subagent 執行期間送出新 prompt，計數保留
    @Test func aNewPromptWhilePausedKeepsTheCount() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), mainStop(subagents: ["a"]), Payloads.prompt], agent: &a)
        #expect(a.state == .running && a.activeSubagents == ["a"])
    }

    /// 場景: 漏收背景 subagent 做完的事件，下一次結束一輪時校正
    @Test func theNextStopCorrectsAMissedSubagentStop() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), start("b"), mainStop(subagents: ["a", "b"]),
                     Payloads.prompt], agent: &a)  // a reports back, but its SubagentStop never arrived
        #expect(a.activeSubagents == ["a", "b"])
        let t = try run([mainStop(subagents: ["b"])], agent: &a)
        #expect(t[0].to == .running && t[0].notify == nil && a.activeSubagents == ["b"])
    }

    /// 場景: 暫停中收到閒置提醒，row 變成 Done
    @Test func idlePromptWhilePausedEndsAsDone() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, start("a"), mainStop(subagents: ["a"]), Payloads.notifIdle], agent: &a)
        #expect(t[3].to == .done && t[3].notify == .done(lastMessage: nil))
        #expect(!a.awaitingBackgroundSubagents)
        // The next prompt starts afresh: no count left over from the pause.
        _ = try run([Payloads.prompt], agent: &a)
        #expect(a.activeSubagents.isEmpty)
    }

    /// 場景: 從 Done 開始新的一輪時，清掉上一輪殘留的計數
    @Test func aNewTurnAfterDoneDropsLeftovers() throws {
        var a = PaneAgent()
        // idle_prompt recovers a missed Stop as done but leaves x counted.
        _ = try run([Payloads.prompt, start("x"), Payloads.notifIdle], agent: &a)
        #expect(a.state == .done && a.activeSubagents == ["x"])
        _ = try run([Payloads.prompt], agent: &a)
        #expect(a.state == .running && a.activeSubagents.isEmpty)
    }

    /// 場景: 主 agent 結束一輪時，背景 subagent 的權限對話框還沒回答，row 維持需要輸入
    @Test func aDialogStillUpWhenTheTurnPausesStays() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, start("a"), ask("a"), mainStop(subagents: ["a"])], agent: &a)
        #expect(t[3].to == .needsInput(.permission) && t[3].alert == nil)
        #expect(a.activeSubagents == ["a"] && a.awaitingBackgroundSubagents)
        // Answered: the subagent's next tool event and the pane runs on.
        #expect(try run([toolDone("a")], agent: &a)[0].to == .running)
    }

    /// 場景: 暫停中回答背景 subagent 的權限對話框，row 回到執行中
    @Test func answeringASubagentDialogWhilePausedRuns() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), mainStop(subagents: ["a"]), ask("a")], agent: &a)
        #expect(a.state == .needsInput(.permission))
        #expect(a.userTyped().to == .running)
        #expect(a.activeSubagents == ["a"])
        // Not paused: answering is idle until the main agent acts again, as before.
        var b = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), ask("a")], agent: &b)
        #expect(b.userTyped().to == .idle)
    }

    /// 場景: 暫停中按 Esc 或 Ctrl+C，row 維持執行中
    @Test func escWhilePausedKeepsRunning() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), mainStop(subagents: ["a"])], agent: &a)
        let t = a.userInterrupted()
        #expect(t.to == .running && t.alert == nil)
        #expect(a.activeSubagents == ["a"] && a.awaitingBackgroundSubagents)
    }

    /// 場景: 主 agent 處理背景 subagent 的回報時，按 Esc 仍能中斷
    @Test func escInTheWokenTurnStillInterrupts() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), start("b"), mainStop(subagents: ["a", "b"]),
                     stop("a"), Payloads.prompt], agent: &a)  // a reports back: the main agent works again
        let t = a.userInterrupted()
        #expect(t.to == .idle && t.alert == nil && a.activeSubagents.isEmpty)
    }
}
