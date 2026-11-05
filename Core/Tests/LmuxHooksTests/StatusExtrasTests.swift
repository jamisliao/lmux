import Foundation
import Testing
@testable import LmuxHooks

/// Subagent counting and the usage-limit wait (payload shapes from Claude Code 2.1's own schemas:
/// SubagentStart `agent_id`/`agent_type`, StopFailure `error`/`last_assistant_message`,
/// Notification `quota_auto_resume_*`).
@Suite struct StatusExtrasTests {
    func run(_ payloads: [String], agent: inout PaneAgent) throws -> [AgentTransition] {
        try payloads.map { agent.handle(try event($0), focused: false) }
    }
    func start(_ id: String) -> String { Payloads.json("SubagentStart", #""agent_id":"\#(id)","agent_type":"Explore""#) }
    func stop(_ id: String) -> String { Payloads.json("SubagentStop", #""agent_id":"\#(id)","agent_type":"Explore","stop_hook_active":false"#) }

    @Test func countsDistinctSubagents() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), start("b"), start("c")], agent: &a)
        #expect(a.activeSubagents.count == 3)
        _ = try run([start("b"), stop("a")], agent: &a)  // a repeated start counts once
        #expect(a.activeSubagents == ["b", "c"])
        _ = try run([stop("zzz"), stop("a")], agent: &a)  // unknown / repeated stops are no-ops
        #expect(a.activeSubagents == ["b", "c"] && a.state == .running)
    }

    @Test func missedStopsAreClearedWhenTheTurnEnds() throws {
        for end in [Payloads.stop, Payloads.prompt, Payloads.sessionEnd, Payloads.sessionStart,
                    Payloads.json("StopFailure", #""error":"server_error""#)] {
            var a = PaneAgent()
            _ = try run([Payloads.prompt, start("a"), start("b")], agent: &a)
            _ = try run([end], agent: &a)
            #expect(a.activeSubagents.isEmpty, "\(end)")
        }
        var e = PaneAgent()
        _ = try run([Payloads.prompt, start("a")], agent: &e)
        e.userInterrupted()
        #expect(e.activeSubagents.isEmpty)
    }

    @Test func aSubagentsOwnStopDoesNotClearTheCount() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, start("a"), start("b"), Payloads.json("Stop", #""agent_id":"a""#)], agent: &a)
        #expect(a.activeSubagents.count == 2 && a.state == .running)
    }

    @Test func countIsCapped() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt] + (0..<100).map { start("s\($0)") }, agent: &a)
        #expect(a.activeSubagents.count == PaneAgent.subagentCap)
    }

    @Test func stopFailureReadsTheErrorField() throws {
        #expect(try event(Payloads.json("StopFailure", #""error":"server_error""#)).errorType == "server_error")
        #expect(try event(Payloads.stopFailure).errorType == "rate_limit")  // older `error_type`
    }

    static let limit = Payloads.json("StopFailure", #""error":"rate_limit","last_assistant_message":"You've hit your session limit · resets 3pm (Asia/Seoul) · progress saved""#)
    static func notif(_ type: String, _ msg: String = "x") -> String {
        Payloads.json("Notification", #""message":"\#(msg)","notification_type":"\#(type)""#)
    }

    @Test func usageLimitWaitsRunningWithoutAlert() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, start("a"), Self.limit], agent: &a)
        #expect(t[2].to == .running && t[2].alert == nil && t[2].notify == nil)
        #expect(a.usageLimitResets == "3pm" && a.activeSubagents.isEmpty)
        // Claude's idle reminder while it waits is not a missed Stop.
        #expect(try run([Self.notif("idle_prompt")], agent: &a)[0].to == .running)
        #expect(a.usageLimitResets == "3pm")
        // It continues by itself.
        let f = try run([Self.notif("quota_auto_resume_fired")], agent: &a)
        #expect(f[0].to == .running && f[0].alert == nil && a.usageLimitResets == nil)
    }

    @Test func usageLimitThatWontResumeIsTheUsersTurn() throws {
        for type in ["quota_auto_resume_stale", "quota_auto_resume_disabled"] {
            var a = PaneAgent()
            _ = try run([Payloads.prompt, Self.limit], agent: &a)
            let t = try run([Self.notif(type, "Usage limit reset — press enter to continue")], agent: &a)
            #expect(t[0].to == .done && t[0].notify == .done(lastMessage: "Usage limit reset — press enter to continue"))
            #expect(a.usageLimitResets == nil)
        }
    }

    @Test func usageLimitWaitEndsWithTheNextTurnOrSession() throws {
        for next in [Payloads.prompt, Payloads.preBash, Payloads.stop, Payloads.sessionEnd] {
            var a = PaneAgent()
            _ = try run([Payloads.prompt, Self.limit, next], agent: &a)
            #expect(a.usageLimitResets == nil, "\(next)")
        }
        var b = PaneAgent()
        _ = try run([Payloads.prompt, Self.limit], agent: &b)
        _ = try run([Payloads.subPreTool], agent: &b)  // a subagent's leftovers don't end the wait
        #expect(b.usageLimitResets == "3pm")
        b.userInterrupted()
        #expect(b.usageLimitResets == nil && b.state == .idle)
    }

    @Test func otherRateLimitsStillFail() throws {
        var a = PaneAgent()
        let t = try run([Payloads.prompt, Payloads.json("StopFailure",
            #""error":"rate_limit","last_assistant_message":"API Error: Request rejected (429) · this may be a temporary capacity issue""#)], agent: &a)
        #expect(t[1].to == .done && t[1].notify == .failed(errorType: "rate_limit") && a.usageLimitResets == nil)
    }

    @Test func staleAfterAHandStartedTurnLeavesItRunning() throws {
        // The wait ended (the user typed a prompt), then Claude's late stale / disabled notice.
        for type in ["quota_auto_resume_stale", "quota_auto_resume_disabled", "quota_auto_resume_fired"] {
            var a = PaneAgent()
            _ = try run([Payloads.prompt, Self.limit, Payloads.prompt], agent: &a)
            let t = try run([Self.notif(type)], agent: &a)
            #expect(t[0].to == .running && t[0].alert == nil, "\(type)")
        }
        // Never waiting at all: a stale notice doesn't end a running turn.
        var b = PaneAgent()
        #expect(try run([Payloads.prompt, Self.notif("quota_auto_resume_stale")], agent: &b)[1].to == .running)
    }

    @Test func usageLimitPassedEndsTheWaitOnce() throws {
        var a = PaneAgent()
        _ = try run([Payloads.prompt, Self.limit], agent: &a)
        #expect(a.usageLimitZone == "Asia/Seoul")
        let t = a.usageLimitPassed(focused: false)
        #expect(t.to == .done && t.notify == .done(lastMessage: "Usage limit reset") && a.usageLimitResets == nil)
        #expect(a.usageLimitPassed(focused: false).alert == nil)  // not waiting: a no-op
        var u = PaneAgent()
        _ = try run([Payloads.prompt, Self.limit], agent: &u)
        #expect(u.usageLimitPassed(focused: false, knownReset: false).notify == .done(lastMessage: "Usage limit wait ended"))
        var b = PaneAgent()
        _ = try run([Payloads.prompt], agent: &b)
        #expect(b.usageLimitPassed(focused: false).to == .running)  // a normal turn is untouched
    }

    @Test func codexNewTurnClearsLeftoverSubagents() throws {
        var a = PaneAgent()
        a.report(.done, focused: false)
        _ = try run([start("late")], agent: &a)  // a SubagentStart that came after the turn ended
        a.report(.working, focused: false)
        #expect(a.activeSubagents.isEmpty)
        _ = try run([start("x")], agent: &a)
        a.report(.blocked(.permission), focused: false)
        a.report(.working, focused: false)  // an answered dialog: the same turn
        #expect(a.activeSubagents == ["x"])
    }

    @Test func resetDates() throws {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seoul
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 13, minute: 10))!
        func at(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, year: Int = 2026) -> Date {
            cal.date(from: DateComponents(year: year, month: m, day: d, hour: h, minute: min))!
        }
        let f = { (t: String) in PaneAgent.usageLimitResetDate(t, zone: "Asia/Seoul", after: now) }
        #expect(f("3pm") == at(11, 4, 15))
        #expect(f("3:30pm") == at(11, 4, 15, 30))
        #expect(f("3 PM") == at(11, 4, 15))
        #expect(f("11am") == now)  // a time of day over 12 h away has just passed (never "tomorrow")
        #expect(f("1:00pm") == now)  // rounded: Claude said 1pm, the hook came at 1:10
        #expect(f("11pm") == at(11, 4, 23))  // later today
        #expect(f("1am") == at(11, 5, 1))  // past midnight, under 12 h away
        #expect(f("1:10pm") == at(11, 4, 13, 10))  // this very minute
        #expect(f("Nov 5, 3:30pm") == at(11, 5, 15, 30))
        #expect(f("Nov 5 at 3pm") == at(11, 5, 15))
        #expect(f("Jan 2, 9am") == at(1, 2, 9, year: 2027))
        #expect(f("soon") == nil && f("") == nil)
        // Another zone: 3am in New York (it's 11:10pm there).
        let ny = PaneAgent.usageLimitResetDate("3am", zone: "America/New_York", after: now)!
        var nyc = Calendar(identifier: .gregorian)
        nyc.timeZone = TimeZone(identifier: "America/New_York")!
        #expect(nyc.component(.hour, from: ny) == 3 && ny.timeIntervalSince(now) == 3 * 3600 + 50 * 60)
        #expect(PaneAgent.usageLimitZoneName(message: "limit · resets 3pm (Asia/Seoul)") == "Asia/Seoul")
        #expect(PaneAgent.usageLimitZoneName(message: "limit · resets 3pm (progress saved)") == nil)
    }

    @Test func resetTimeFormats() {
        let f = PaneAgent.usageLimitResetTime
        #expect(f("rate_limit", "You've hit your weekly limit · resets Nov 5, 3:30pm (Asia/Seoul)") == "Nov 5, 3:30pm")
        #expect(f("rate_limit", "You've hit your usage limit · resets 11am") == "11am")
        #expect(f("rate_limit", "You've hit your limit · contact your admin to increase it") == nil)
        #expect(f("server_error", "· resets 3pm") == nil)
        #expect(f("rate_limit", nil) == nil)
        #expect(f("rate_limit", "You've hit your session limit \u{2219} resets 3pm \u{2219} upgrade") == "3pm")
        #expect(f("rate_limit", "You've hit your session limit - resets 3pm - try later") == "3pm")
        #expect(f("rate_limit", "You've hit your session limit · resets 3pm.") == "3pm")
        // " resets " in prose that isn't about a limit: not a wait.
        #expect(f("rate_limit", "API Error (429): the pool resets 3pm") == nil)
    }
}
