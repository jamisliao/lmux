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

    // MARK: 壓縮

    // @feature: compaction-running-state.feature
    // @scenario: 已完成的 tab 開始壓縮時顯示進行中
    // @scenario: 壓縮結束後回到完成，不發通知
    /// 實測順序（Claude Code 2.1.318）：PreCompact → SessionStart(compact) → PostCompact。
    @Test func manualCompactionAfterDoneRunsThenRestoresDoneSilently() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.compactStart, Payloads.postCompact],
                        agent: &a)
        #expect(t.map(\.to) == [.running, .done, .running, .done, .done])
        #expect(t[2].alert == nil && t[3].alert == nil && t[4].alert == nil)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮結束後回到完成，不發通知
    /// 只有 PostCompact（沒有 SessionStart(compact)）也算壓縮結束。
    @Test func postCompactAloneEndsCompaction() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.postCompact], agent: &a)
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
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.compactStart,
                         Payloads.notifPermission, Payloads.postCompact], agent: &a)
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
        let t = try run([Payloads.prompt, Payloads.preCompactAuto, Payloads.compactStart, Payloads.postCompact], agent: &a)
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

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮期間 tab 轉為等待回應時，壓縮結束不蓋掉它
    @Test func compactionEndDoesNotOverwriteNeedsInput() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.permission, Payloads.postCompact],
                        agent: &a)
        #expect(t.map(\.to) == [.running, .done, .running, .needsInput(.permission), .needsInput(.permission)])
        #expect(t[3].alert != nil && t[4].alert == nil)
        #expect(!a.isCompacting)
        // 使用者回應後，照一般規則繼續。
        let after = try run([Payloads.postBash, Payloads.stop], agent: &a)
        #expect(after.map(\.to) == [.running, .done])
    }

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮期間使用者開始輸入時，壓縮結束不把它改回完成
    @Test func compactionEndDoesNotOverwriteIdleAfterTyping() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact, Payloads.permission], agent: &a)
        #expect(a.state == .needsInput(.permission))
        #expect(a.userTyped().to == .idle)  // 使用者開始輸入：等待回應結束，變閒置
        let t = try run([Payloads.postCompact], agent: &a)
        #expect(t[0].to == .idle && t[0].alert == nil)
    }

    // @feature: compaction-running-state.feature
    // @scenario: 壓縮結束後，tab 不再被視為壓縮中
    /// App 的 Esc 偵測靠 `isCompacting`：只有 lmux 標成 running 的壓縮才算；結束後、回合中的自動壓縮都不算。
    @Test func isCompactingOnlyWhileLmuxMarkedCompactionRuns() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, Payloads.stop, Payloads.preCompact], agent: &a)
        #expect(a.isCompacting)
        _ = try run([Payloads.compactStart], agent: &a)
        #expect(!a.isCompacting)

        var b = PaneAgent()
        _ = try run([Payloads.prompt, Payloads.preCompactAuto], agent: &b)  // 回合中：本來就是 running
        #expect(!b.isCompacting)
        _ = try run([Payloads.compactStart], agent: &b)
        #expect(!b.isCompacting)

        var c = PaneAgent()
        _ = try run([Payloads.sessionStart, Payloads.preCompact], agent: &c)
        #expect(c.isCompacting)
        c.userInterrupted()
        #expect(!c.isCompacting)
    }

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
}
