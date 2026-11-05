import Testing
@testable import LmuxHooks

@Suite struct AgentStateTests {
    /// Feeds payloads in order; returns the transitions.
    func run(_ payloads: [String], focused: Bool = false, agent: inout PaneAgent) throws -> [AgentTransition] {
        try payloads.map { agent.handle(try event($0), focused: focused) }
    }

    @Test func basicTurn() throws {
        var a = PaneAgent()
        let t = try run([Payloads.sessionStart, Payloads.prompt, Payloads.preBash, Payloads.postBash, Payloads.stop], agent: &a)
        #expect(t.map(\.to) == [.idle, .running, .running, .running, .done])
        #expect(t.compactMap(\.notify) == [.done(lastMessage: "All tests pass.")])
        let t2 = try run([Payloads.prompt], agent: &a)
        #expect(t2[0].to == .running)
    }

    @Test func typingClearsNeedsInputAndToolEventsResume() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, Payloads.permission], agent: &a)
        #expect(a.state == .needsInput(.permission))
        #expect(a.userTyped().to == .idle)
        #expect(a.userTyped().to == .idle)  // no-op outside needsInput
        let t = try run([Payloads.postBash], agent: &a)
        #expect(t[0].to == .running)
        var b = PaneAgent()
        _ = try run([Payloads.prompt], agent: &b)
        #expect(b.userTyped().to == .running)  // typing while running changes nothing
    }

    /// Claude Code's Esc (no hook; the app saw the transcript's interrupt marker): idle, silently.
    @Test func userInterruptedGoesIdleWithoutAlert() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, Payloads.preBash], agent: &a)
        let t = a.userInterrupted()
        #expect(t.from == .running && t.to == .idle && t.alert == nil && t.notify == nil)
        #expect(a.userInterrupted().to == .idle)  // repeat: no-op
        var d = PaneAgent()
        _ = try run([Payloads.prompt, Payloads.stop], agent: &d)
        #expect(d.userInterrupted().to == .done)  // a finished turn keeps its ✓
        // The next real hook takes over.
        #expect(try run([Payloads.prompt], agent: &a)[0].to == .running)
    }

    @Test func permissionDedupesAcrossHookAndNotification() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.preBash, Payloads.permission, Payloads.notifPermission, Payloads.postBash], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .needsInput(.permission), .needsInput(.permission), .running])
        #expect(t.compactMap(\.notify).count == 1)
        #expect(t[2].notify == .needsInput(.permission, message: "Permission: Bash"))
    }

    @Test func notificationAloneAlsoEntersNeedsInput() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.notifPermission], agent: &a)
        #expect(t[1].to == .needsInput(.permission))
        #expect(t[1].notify == .needsInput(.permission, message: "Claude needs your permission to use Bash"))
    }

    @Test func idleReminderAfterStopDoesNotRealert() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.notifIdle, Payloads.notifIdle], agent: &a)
        #expect(t.map(\.to) == [.running, .done, .done, .done])
        #expect(t.compactMap(\.alert).count == 1)
    }

    @Test func idleReminderWhileBlockedDoesNotRealert() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.permission, Payloads.notifIdle], agent: &a)
        #expect(t[2].to == .needsInput(.permission) && t[2].alert == nil)
    }

    @Test func idleReminderRecoversMissedStopOnce() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.notifIdle, Payloads.notifIdle], agent: &a)
        #expect(t.map(\.to) == [.running, .done, .done])
        #expect(t.compactMap(\.alert).count == 1)
    }

    @Test func subagentActivityNeverEndsOrBlocksTurn() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.subStart, Payloads.subPreTool, Payloads.subStop], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .running, .running])
        #expect(t.allSatisfy { $0.alert == nil })
        #expect(a.activeSubagents.isEmpty)
    }

    @Test func parallelSubagentsKeepTheTurnRunningUntilTheMainStop() throws {
        var a = PaneAgent()
        let sub2Start = Payloads.json("SubagentStart", #""agent_id":"agent-8","agent_type":"Explore""#)
        let sub2Stop = Payloads.json("SubagentStop", #""agent_id":"agent-8","agent_type":"Explore","last_assistant_message":"done too""#)
        let subStopHook = Payloads.json("Stop", #""agent_id":"agent-7","last_assistant_message":"sub finished""#)
        let subIdle = Payloads.json("Notification", #""agent_id":"agent-7","notification_type":"idle_prompt","message":"waiting""#)
        let t = try run([Payloads.prompt, Payloads.preBash, Payloads.subStart, sub2Start, Payloads.subPreTool, subStopHook,
                         Payloads.subStop, subIdle, sub2Stop, Payloads.postBash], agent: &a)
        #expect(t.map(\.to).allSatisfy { $0 == .running }, "\(t.map(\.to))")
        #expect(t.allSatisfy { $0.alert == nil && $0.notify == nil })
        #expect(a.activeSubagents.isEmpty)
        let end = try run([Payloads.stop], agent: &a)
        #expect(end.map(\.to) == [.done] && end.compactMap(\.notify) == [.done(lastMessage: "All tests pass.")])
    }

    @Test func subagentToolEventsDoNotReviveFinishedTurn() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, Payloads.stop], agent: &a)
        let t = try run([Payloads.subPreTool, Payloads.subStop], agent: &a)
        #expect(t.map(\.to) == [.done, .done])
    }

    @Test func subagentToolEventDoesNotClearMainAgentPermission() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.permission, Payloads.subPreTool, Payloads.subStop], agent: &a)
        #expect(t.map(\.to).dropFirst().allSatisfy { $0 == .needsInput(.permission) })
    }

    @Test func subagentPermissionBlocksUntilSameAgentContinues() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.subStart, Payloads.subPermission, Payloads.preBash, Payloads.subPostTool], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .needsInput(.permission), .needsInput(.permission), .running])
        #expect(t.compactMap(\.alert).count == 1)
    }

    @Test func askUserQuestionNeedsInput() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.askUser, Payloads.askUserDone], agent: &a)
        #expect(t.map(\.to) == [.running, .needsInput(.question), .running])
    }

    @Test func focusSuppressesNotifyButKeepsAlert() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.permission, Payloads.postBash, Payloads.stop], focused: true, agent: &a)
        #expect(t.compactMap(\.notify).isEmpty)
        #expect(t.compactMap(\.alert).count == 2)
    }

    @Test func stopFailureAlertsFailed() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stopFailure], agent: &a)
        #expect(t[1].to == .done && t[1].notify == .failed(errorType: "rate_limit"))
    }

    @Test func compactSessionStartKeepsRunningOthersReset() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.compactStart, Payloads.sessionEnd], agent: &a)
        #expect(t.map(\.to) == [.running, .running, .idle])
    }

    @Test func unknownEventIsNoOp() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.future], agent: &a)
        #expect(t[1].to == .running && t[1].alert == nil)
    }
}
