import AppKit
import LmuxHooks
@testable import LmuxUI

// `lmux-apptest --status-extras`: the running row's subagent count, the header's bypass / auto
// badge, the usage-limit wait and the quiet hint (fake clock). Hook payloads are shaped like
// Claude Code 2.1's (SubagentStart `agent_id`, `permission_mode`, StopFailure `error`,
// Notification `quota_auto_resume_*`); Codex's like 0.166's.

@MainActor
func runStatusExtras() async -> Int32 {
    let r = Report()
    let c = makeController()
    c.assumeAppActive = true
    var now = Date()
    c.attentionClock = { now }
    func pane(_ title: String) async -> (Workspace, Pane) {
        let w = c.newWorkspace(select: false)
        w.customTitle = title
        _ = await sinks.waitReady(w.panes[0].id)
        return (w, w.panes[0])
    }
    func settle() async { await sleepMs(60) }
    func line2(_ w: Workspace) -> Workspace.RowDetail? { w.rowDetail(now: c.model.clock) }
    func advance(_ minutes: Double) async {
        now = now.addingTimeInterval(minutes * 60)
        c.updateAttention()
        await settle()
    }

    // MARK: Subagents
    r.section = "subagents"
    let (S, s) = await pane("S")
    func sub(_ name: String, _ id: String) { hookEvent(c, s, name, session: "sx-1", ["agent_id": id, "agent_type": "Explore"]) }
    hookEvent(c, s, "SessionStart", session: "sx-1", ["source": "startup"])
    hookEvent(c, s, "UserPromptSubmit", session: "sx-1", ["prompt": "look around"])
    await settle()
    r.check("running, no subagents: nothing on the right", line2(S)?.age == nil && line2(S)?.text == "Working…", "\(String(describing: line2(S)))")
    sub("SubagentStart", "a"); sub("SubagentStart", "b"); sub("SubagentStart", "c")
    await settle()
    r.check("three SubagentStarts: “3 subagents” on line 2", line2(S)?.age == "3 subagents", line2(S)?.age ?? "nil")
    sub("SubagentStart", "b"); sub("SubagentStop", "a"); sub("SubagentStop", "zzz")
    await settle()
    r.check("a repeated start counts once, an unknown stop is ignored: 2", line2(S)?.age == "2 subagents", line2(S)?.age ?? "nil")
    sub("SubagentStop", "b")
    hookEvent(c, s, "PreToolUse", session: "sx-1", ["tool_name": "Bash", "tool_input": ["command": "make"]])
    await settle()
    r.check("one left: singular, after the tool", line2(S)?.age == "1 subagent" && line2(S)?.text == "Bash · make",
            "\(String(describing: line2(S)))")
    hookEvent(c, s, "Stop", session: "sx-1", ["agent_id": "c", "last_assistant_message": "sub done"])
    await settle()
    r.check("a subagent's own Stop neither ends the turn nor the count", s.agent.state == .running && s.subagentCount == 1)
    hookEvent(c, s, "Stop", session: "sx-1", ["last_assistant_message": "all done"])
    await settle()
    r.check("the main Stop (SubagentStop for c missed): count cleared, row says done",
            s.subagentCount == 0 && s.agent.activeSubagents.isEmpty && !(line2(S)?.age ?? "").contains("subagent"))
    hookEvent(c, s, "UserPromptSubmit", session: "sx-1", ["prompt": "again"])
    sub("SubagentStart", "x"); sub("SubagentStart", "y")
    hookEvent(c, s, "UserPromptSubmit", session: "sx-1", ["prompt": "and again"])
    await settle()
    r.check("a new prompt starts the count over (missed stops of the last one)", s.subagentCount == 0 && line2(S)?.age == nil)
    for i in 0..<50 { sub("SubagentStart", "many-\(i)") }
    await settle()
    r.check("missed stops can't grow it without bound: capped at \(PaneAgent.subagentCap)",
            s.subagentCount == PaneAgent.subagentCap, "\(s.subagentCount)")
    hookEvent(c, s, "SessionEnd", session: "sx-1", ["reason": "prompt_input_exit"])
    await settle()
    r.check("SessionEnd clears it", s.subagentCount == 0 && line2(S) == nil)
    // Two running panes, same line 2: the count is the pane the row speaks for (the newer alert),
    // not the first pane that happens to show the same.
    let (T2, t1) = await pane("T")
    let t2 = c.split(t1, .right)!
    _ = await sinks.waitReady(t2.id)
    for (p, sid) in [(t1, "tw-1"), (t2, "tw-2")] {
        hookEvent(c, p, "UserPromptSubmit", session: sid, ["prompt": "a"])
        hookEvent(c, p, "Stop", session: sid, ["last_assistant_message": "ok"])
        await sleepMs(20)  // t2's alert is the newer one
    }
    hookEvent(c, t1, "UserPromptSubmit", session: "tw-1", ["prompt": "b"])
    hookEvent(c, t2, "UserPromptSubmit", session: "tw-2", ["prompt": "b"])
    for id in ["p", "q"] { hookEvent(c, t2, "SubagentStart", session: "tw-2", ["agent_id": id, "agent_type": "Explore"]) }
    await settle()
    r.check("two panes both “Working…”: the row counts the subagents of the pane it speaks for",
            T2.statePane === t2 && line2(T2)?.age == "2 subagents", "\(line2(T2)?.age ?? "nil") \(T2.statePane === t2)")
    c.closeWorkspace(T2)

    // MARK: Mode badge
    r.section = "mode badge"
    let (M, m) = await pane("M")
    c.select(M)
    await settle()
    func ev(_ name: String, _ mode: String, _ extra: [String: Any] = [:]) {
        var x = extra
        x["permission_mode"] = mode
        hookEvent(c, m, name, session: "mb-1", x)
    }
    ev("SessionStart", "default", ["source": "startup"])
    ev("UserPromptSubmit", "default", ["prompt": "x"])
    await settle()
    // Where a pane's badge shows: its tab strip when it has one (by default every pane does), else
    // its header (split) or the content header (one pane).
    func strip(_ p: Pane) -> TabStripView? { p.workspace?.root.find(p).flatMap { $0.hasStrip ? $0.strip : nil } }
    func refresh() async { c.refreshPaneChrome(); await settle() }
    // Tab bar only on panes with tabs (the setting off): one pane, the content header.
    c.setTabBarWithOneTab(false)
    await refresh()
    r.check("default mode: no badge", m.modeBadge == nil && c.root.header.modeBadge == nil && strip(m) == nil)
    ev("PreToolUse", "bypassPermissions", ["tool_name": "Bash", "tool_input": ["command": "ls"]])
    await settle()
    r.check("bypassPermissions: “bypass” in the header (one pane, no tab bar: the content header)",
            m.modeBadge == "bypass" && c.root.header.modeBadge == "bypass", c.root.header.modeBadge ?? "nil")
    r.check("…never on the sidebar row", !(line2(M)?.text ?? "").contains("bypass") && !(line2(M)?.age ?? "").contains("bypass"))
    ev("PreToolUse", "default", ["agent_id": "sub-1", "tool_name": "Grep", "tool_input": ["pattern": "x"]])
    ev("PostToolUse", "unavailable", ["tool_name": "Bash"])
    await settle()
    r.check("a subagent's mode or an unknown value doesn't change it", m.modeBadge == "bypass")
    ev("PostToolUse", "auto", ["tool_name": "Bash"])
    await settle()
    r.check("auto mode: “auto”", m.modeBadge == "auto" && c.root.header.modeBadge == "auto")
    ev("PostToolUse", "acceptEdits", ["tool_name": "Bash"])
    await settle()
    r.check("accept edits (asks before commands): no badge", m.modeBadge == nil && c.root.header.modeBadge == nil)
    ev("PostToolUse", "bypassPermissions", ["tool_name": "Bash"])
    // The tab bar on every pane (the default): the strip is the pane's header, once.
    c.setTabBarWithOneTab(true)
    await refresh()
    r.check("with a tab bar: the badge is in the pane's strip, not also the content header",
            strip(m)?.modeBadge == "bypass" && c.root.header.modeBadge == nil,
            "\(strip(m)?.modeBadge ?? "nil") \(c.root.header.modeBadge ?? "nil")")
    let m2 = c.split(m, .right)!
    await refresh()
    r.check("split with tab bars: on its own pane's strip only",
            strip(m)?.modeBadge == "bypass" && strip(m2)?.modeBadge == nil && c.root.header.modeBadge == nil)
    c.setTabBarWithOneTab(false)
    await refresh()
    r.check("split without tab bars: the pane's own header carries it, the content header doesn't",
            m.view.header.modeBadge == "bypass" && m2.view.header.modeBadge == nil && c.root.header.modeBadge == nil,
            "\(m.view.header.modeBadge ?? "nil") \(c.root.header.modeBadge ?? "nil")")
    c.setTabBarWithOneTab(true)
    await refresh()
    ev("Stop", "default", ["last_assistant_message": "ok"])
    await settle()
    r.check("the mode changing back clears it", m.modeBadge == nil && m.view.header.modeBadge == nil && strip(m)?.modeBadge == nil)
    // Shift+Tab sends no hook. Claude can act in the new mode only through a tool, and PreToolUse
    // (sent before the tool runs) carries the mode, as does the next prompt.
    ev("UserPromptSubmit", "bypassPermissions", ["prompt": "y"])
    await settle()
    r.check("Shift+Tab into bypass at the prompt: the badge with the next prompt", m.modeBadge == "bypass")
    ev("PreToolUse", "default", ["tool_name": "Bash", "tool_input": ["command": "ls"]])
    ev("PreToolUse", "bypassPermissions", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])
    await settle()
    r.check("…and mid-turn, before the next tool runs (its PreToolUse)",
            m.modeBadge == "bypass" && strip(m)?.modeBadge == "bypass")
    // Tabs: the strip shows the shown tab's badge; the row counts a hidden tab's subagents.
    for id in ["ta", "tb"] { ev("SubagentStart", "bypassPermissions", ["agent_id": id, "agent_type": "Explore"]) }
    let tab = c.newTab(m, select: true)!
    _ = await sinks.waitReady(tab.id)
    await refresh()
    r.check("a new tab in front (default mode): the strip has no badge; the hidden bypass tab keeps its own",
            strip(m)?.node?.shownTab === tab && strip(m)?.modeBadge == nil && m.modeBadge == "bypass")
    r.check("…the row still counts the hidden tab's subagents", line2(M)?.age == "2 subagents", line2(M)?.age ?? "nil")
    c.selectTab(m)
    await refresh()
    r.check("…back to that tab: the strip shows “bypass”", strip(m)?.node?.shownTab === m && strip(m)?.modeBadge == "bypass")
    hookEvent(c, m, "SessionEnd", session: "mb-1", ["reason": "prompt_input_exit"])
    await settle()
    r.check("SessionEnd clears it", m.modeBadge == nil && m.view.header.modeBadge == nil && strip(m)?.modeBadge == nil)
    // Codex sends `permission_mode` too (0.166: default / bypassPermissions).
    let (_, x) = await pane("X")
    for (name, extra) in [("SessionStart", ["source": "startup"]), ("UserPromptSubmit", ["prompt": "z"])] as [(String, [String: Any])] {
        var o: [String: Any] = ["hook_event_name": name, "session_id": "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", "cwd": "/tmp",
                                "permission_mode": "bypassPermissions"]
        for (k, v) in extra { o[k] = v }
        var e = try! HookEvent(paneID: x.id, payload: o)
        e.agent = .codex
        c.handleHook(e)
    }
    await settle()
    r.check("Codex in bypass: the same badge", x.modeBadge == "bypass", x.modeBadge ?? "nil")

    // MARK: Usage limit
    r.section = "usage limit"
    let (U, u) = await pane("U")
    // Resets 3 hours from now (Claude's "9:15pm" form): the waits below never run into it by chance.
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "Asia/Seoul")
    fmt.dateFormat = "h:mma"
    let resets = fmt.string(from: now.addingTimeInterval(3 * 3600)).lowercased()
    let limitMsg = "You've hit your session limit · resets \(resets) (Asia/Seoul) · progress saved"
    let ul = UUID().uuidString.lowercased()
    let ulTranscript = NSTemporaryDirectory() + "lmux-extras-\(getpid())/projects/-tmp/\(ul).jsonl"
    hookEvent(c, u, "SessionStart", session: ul, transcript: ulTranscript, ["source": "startup"])
    hookEvent(c, u, "UserPromptSubmit", session: ul, ["prompt": "long task"])
    await settle()
    let posted = c.notifier.postedCount, entries = c.model.notifications.count
    hookEvent(c, u, "StopFailure", session: ul, ["error": "rate_limit", "last_assistant_message": limitMsg])
    await settle()
    r.check("usage limit hit: still running, line 2 “waiting for usage limit · resets \(resets)”",
            u.agent.state == .running && line2(U)?.text == "waiting for usage limit · resets \(resets)", line2(U)?.text ?? "nil")
    r.check("…the row shows a still clock, not the working spinner", U.waitsForUsageLimit)
    r.check("…and ends by itself 15 min after \(resets) (Asia/Seoul) if Claude says nothing",
            u.usageLimitDeadline == PaneAgent.usageLimitResetDate(resets, zone: "Asia/Seoul", after: now)!
                .addingTimeInterval(LmuxController.usageLimitGrace), "\(String(describing: u.usageLimitDeadline))")
    // Esc / Ctrl+C at Claude's idle prompt (its title ✳) while it waits: not an interrupted turn.
    u.surface.printOutput("\u{1b}]0;✳ Claude Code\u{07}")
    _ = await waitFor(15) { u.surface.title.hasPrefix("✳") }
    c.interruptKeyPressed(u)
    let looked = c.interruptChecks[u.id] != nil
    await sleepMs(1500)
    r.check("Esc during the wait: no transcript look, still waiting (not dropped to idle)",
            !looked && u.agent.state == .running && U.waitsForUsageLimit, "\(looked) \(u.agent.state)")
    r.check("…no notification, no unread, no bell entry, not failed",
            c.notifier.postedCount == posted && u.unread == 0 && c.model.notifications.count == entries && !u.failed)
    hookEvent(c, u, "Notification", session: ul, ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
    await advance(45)
    r.check("45 quiet minutes and Claude's idle reminder later: still waiting, no quiet hint",
            u.agent.state == .running && u.quietMinutes == nil && line2(U)?.text == "waiting for usage limit · resets \(resets)",
            line2(U)?.text ?? "nil")
    hookEvent(c, u, "Notification", session: ul, ["notification_type": "quota_auto_resume_fired",
                                                     "message": "Usage limit available — Claude is continuing your task"])
    await settle()
    r.check("Claude continues by itself (quota_auto_resume_fired): running, the wait text gone, no notification",
            u.agent.state == .running && line2(U)?.text == "Working…" && c.notifier.postedCount == posted, line2(U)?.text ?? "nil")
    r.check("…the spinner is back", !U.waitsForUsageLimit)
    hookEvent(c, u, "StopFailure", session: ul, ["error": "rate_limit", "last_assistant_message": limitMsg])
    hookEvent(c, u, "Notification", session: ul, ["notification_type": "quota_auto_resume_stale",
                                                     "message": "Usage limit reset — press enter to continue"])
    await settle()
    r.check("it won't continue by itself (stale): done, the user's turn, one notification",
            u.agent.state == .done && c.notifier.postedCount == posted + 1
            && c.notifier.posted.last?.body == "Done · Usage limit reset — press enter to continue",
            c.notifier.posted.last?.body ?? "nil")
    hookEvent(c, u, "UserPromptSubmit", session: ul, ["prompt": "go"])
    hookEvent(c, u, "StopFailure", session: ul, ["error": "rate_limit",
                                                    "last_assistant_message": "API Error: Request rejected (429) · this may be a temporary capacity issue"])
    await settle()
    r.check("a transient 429 (no reset time) still fails as before, with its error",
            u.failed && u.agent.state == .done && line2(U)?.text == "rate_limit", line2(U)?.text ?? "nil")
    // Claude never says whether it continues: the wait ends after the reset time + 15 min.
    hookEvent(c, u, "UserPromptSubmit", session: ul, ["prompt": "again"])
    hookEvent(c, u, "StopFailure", session: ul, ["error": "rate_limit", "last_assistant_message": limitMsg])
    await settle()
    c.updateAttention()
    let deadline = u.usageLimitDeadline
    r.check("(setup) waiting again, its deadline set", U.waitsForUsageLimit && deadline != nil)
    r.check("…the timer is armed for that deadline exactly, not every 30 s",
            (c.attentionDelay ?? 0) > 30 || (deadline.map { $0.timeIntervalSince(now) <= 30 } ?? false),
            "\(c.attentionDelay ?? -1)")
    let posted2 = c.notifier.postedCount
    if let d = deadline { now = d.addingTimeInterval(-60) }
    c.updateAttention()
    await settle()
    r.check("a minute before the deadline: still waiting", U.waitsForUsageLimit && u.agent.state == .running)
    await advance(2)
    r.check("past it: done, the user's turn, one notification (`lmux wait` returns)",
            u.agent.state == .done && !U.waitsForUsageLimit && c.notifier.postedCount == posted2 + 1
            && c.notifier.posted.last?.body == "Done · Usage limit reset", c.notifier.posted.last?.body ?? "nil")
    await advance(30)
    r.check("…once", c.notifier.postedCount == posted2 + 1)
    // A reset time that can't be read ("in 3 days"): 5 h + 15 min, and no claim that it reset.
    hookEvent(c, u, "UserPromptSubmit", session: ul, ["prompt": "weekly"])
    hookEvent(c, u, "StopFailure", session: ul, ["error": "rate_limit",
              "last_assistant_message": "You've hit your weekly limit · resets in 3 days"])
    await settle()
    r.check("unreadable reset time: waiting, deadline 5 h 15 min out",
            U.waitsForUsageLimit && u.usageLimitDeadline == now.addingTimeInterval(5 * 3600 + 15 * 60) && !u.usageLimitKnownReset,
            "\(String(describing: u.usageLimitDeadline.map { $0.timeIntervalSince(now) }))")
    let posted3 = c.notifier.postedCount
    await advance(5 * 60 + 16)
    r.check("…then done, saying the wait ended (not that the limit reset)",
            u.agent.state == .done && c.notifier.postedCount == posted3 + 1
            && c.notifier.posted.last?.body == "Done · Usage limit wait ended", c.notifier.posted.last?.body ?? "nil")
    // A wait that ends and a new one in the same burst of events: the new one's deadline, not the old's.
    let later = fmt.string(from: now.addingTimeInterval(5 * 3600)).lowercased()
    hookEvent(c, u, "UserPromptSubmit", session: ul, ["prompt": "x"])
    hookEvent(c, u, "StopFailure", session: ul, ["error": "rate_limit", "last_assistant_message": limitMsg])
    await settle()
    let first = u.usageLimitDeadline
    hookEvent(c, u, "UserPromptSubmit", session: ul, ["prompt": "y"])
    hookEvent(c, u, "StopFailure", session: ul, ["error": "rate_limit",
              "last_assistant_message": "You've hit your session limit · resets \(later) (Asia/Seoul)"])
    await settle()
    r.check("a new wait in the same burst gets its own deadline (\(later) + 15 min)",
            first != nil && u.usageLimitDeadline == PaneAgent.usageLimitResetDate(later, zone: "Asia/Seoul", after: now)!
                .addingTimeInterval(LmuxController.usageLimitGrace),
            "\(String(describing: first)) -> \(String(describing: u.usageLimitDeadline))")

    // MARK: Quiet hint
    r.section = "quiet hint"
    let (Q, q) = await pane("Q")
    hookEvent(c, q, "SessionStart", session: "qh-1", ["source": "startup"])
    hookEvent(c, q, "UserPromptSubmit", session: "qh-1", ["prompt": "build"])
    hookEvent(c, q, "PreToolUse", session: "qh-1", ["tool_name": "Bash", "tool_input": ["command": "make test"]])
    await settle()
    r.check("running: the coarse attention timer is armed (no timer of its own)", c.attentionWork != nil)
    await advance(9)
    r.check("9 quiet minutes: nothing yet", q.quietMinutes == nil && line2(Q)?.text == "Bash · make test")
    await advance(3)
    r.check("12 quiet minutes: “no output for 12m”, a hint only (still running, no alert)",
            line2(Q)?.text == "no output for 12m" && q.agent.state == .running && !q.failed && q.unread == 0,
            line2(Q)?.text ?? "nil")
    await advance(1)
    r.check("…its minutes move with the same timer", line2(Q)?.text == "no output for 13m", line2(Q)?.text ?? "nil")
    hookEvent(c, q, "PostToolUse", session: "qh-1", ["tool_name": "Bash"])
    await settle()
    r.check("a hook event clears it at once", q.quietMinutes == nil && line2(Q)?.text == "Bash · make test", line2(Q)?.text ?? "nil")
    await advance(11)
    r.check("quiet again (a long quiet tool): the hint again, the state unchanged", q.quietMinutes == 11 && q.agent.state == .running)
    q.surface.printOutput("\u{1b}]0;⠂ Claude Code\u{07}")
    let cleared = await waitFor(15) { q.quietMinutes == nil }
    r.check("output (Claude's spinner retitling the pane) clears it", cleared && line2(Q)?.text == "Bash · make test")
    // Drawn frames aren't output: a cursor blink, focus or scrolling never hide the hint.
    r.check("(setup) Q is hidden (not the selected workspace)", c.model.selected !== Q)
    await advance(11)
    r.check("quiet 11 minutes again: the hint", q.quietMinutes == 11, "\(q.quietMinutes ?? -1)")
    for _ in 0..<5 { q.surface.onFrame?() }
    c.updateAttention()
    r.check("…frames alone (cursor blink, focus) leave it", q.quietMinutes == 11)
    // An OSC 7501 report lmux rejects (codex isn't the foreground program: a file shown with cat).
    q.surface.printOutput("\u{1b}]7501;state=working:app=codex\u{1b}\\")
    _ = await waitFor(15) { c.actionLog.contains { $0.contains("codex report ignored: pane=\(q.id.prefix(8))") } }
    r.check("…a rejected OSC 7501 report leaves it too", q.quietMinutes == 11 && q.codexReport == nil
            && c.actionLog.contains { $0.contains("codex report ignored: pane=\(q.id.prefix(8))") })
    // Output in a hidden pane draws no frame, sets no title: the screen look sees it.
    q.surface.printOutput("compiling 1/200\r\n")
    _ = await waitFor(15) { q.surface.readText().contains("compiling 1/200") }
    await advance(1)
    r.check("output in the hidden pane (no title, no frame): the hint goes at the next look",
            q.quietMinutes == nil && line2(Q)?.text == "Bash · make test", line2(Q)?.text ?? "nil")
    for i in 2...12 {
        q.surface.printOutput("compiling \(i)/200\r\n")
        _ = await waitFor(15) { q.surface.readText().contains("compiling \(i)/200") }
        await advance(1)
    }
    r.check("a build printing a line a minute for 11 minutes: never the hint", q.quietMinutes == nil)
    await advance(12)
    r.check("…then 12 silent minutes: the hint (counted from the last output seen, within a minute)",
            (q.quietMinutes ?? 0) >= 11, "\(q.quietMinutes ?? -1)")
    // The look's baseline starts over with each activity: output before a hook doesn't later
    // count as new (that would restart the quiet clock at the look and delay the hint).
    hookEvent(c, q, "PostToolUse", session: "qh-1", ["tool_name": "Bash"])
    await advance(2)
    let baseline = q.screenHash
    q.surface.printOutput("tests done\r\n")
    _ = await waitFor(15) { q.surface.readText().contains("tests done") }
    hookEvent(c, q, "PreToolUse", session: "qh-1", ["tool_name": "Bash", "tool_input": ["command": "make lint"]])
    await settle()
    r.check("(setup) a look stored a baseline, then the hook cleared it", baseline != nil && q.screenHash == nil)
    await advance(10.5)
    r.check("output then a hook, then 10 quiet minutes: the hint, counted from the hook",
            q.quietMinutes == 10, "\(q.quietMinutes ?? -1)")
    let t0 = c.attentionWork
    c.updateAttention(); c.updateAttention()
    r.check("one timer, rescheduled in place (not stacked)", t0 != nil && c.attentionWork === t0)
    // (X, the Codex pane, still runs: its hint's minute ticks would set the time. Only Q here.)
    c.clearStatus(x)
    c.updateAttention()
    // Q's next deadline: its next look or its hint's next minute, whichever is first (U's wait is hours out).
    let qNext = min(max(q.lastActivityAt, q.screenSampledAt).addingTimeInterval(LmuxController.screenLookEvery),
                    q.lastActivityAt.addingTimeInterval(TimeInterval(((q.quietMinutes ?? 9) + 1) * 60)))
    r.check("…armed for Q's next deadline exactly (not the 30 s reminder cap)",
            abs((c.attentionDelay ?? 0) - max(qNext.timeIntervalSince(now), 1)) < 0.5,
            "\(c.attentionDelay ?? -1) vs \(qNext.timeIntervalSince(now))")
    // Usage-limit waits and other states never get it.
    await advance(30)
    hookEvent(c, q, "Notification", session: "qh-1", ["notification_type": "permission_prompt", "message": "Allow make?"])
    await advance(30)
    r.check("needs input: no quiet hint", q.quietMinutes == nil && q.needsInput)
    hookEvent(c, q, "Stop", session: "qh-1", ["last_assistant_message": "built"])
    hookEvent(c, s, "SessionEnd", session: "sx-1", ["reason": "other"])
    for p in c.model.workspaces.flatMap(\.panes) where p.agent.state == .running { c.clearStatus(p) }
    c.clearStatus(for: U)
    await advance(30)
    r.check("nothing running or pending: no timer", c.attentionWork == nil
            && c.model.workspaces.flatMap(\.panes).allSatisfy { $0.quietMinutes == nil })
    _ = Q

    print("status extras: \(r.passed) passed, \(r.failed) failed")
    return r.failed == 0 ? 0 : 1
}

/// `lmux-apptest --status-extras-shots DIR`: extras-single-{dark,light}.png (one pane in bypass with
/// 3 subagents; rows waiting for a usage limit and quiet) and extras-split-* (the badge on a pane header).
@MainActor
func runStatusExtrasShots(_ dir: URL) async -> Int32 {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let c = makeController()
    var now = Date()
    c.attentionClock = { now }
    let main = c.model.selected!
    main.customTitle = "payments refactor"
    let p = main.panes[0]
    hookEvent(c, p, "SessionStart", session: "shot-1", ["source": "startup", "permission_mode": "bypassPermissions"])
    hookEvent(c, p, "UserPromptSubmit", session: "shot-1", ["prompt": "x", "permission_mode": "bypassPermissions"])
    hookEvent(c, p, "PreToolUse", session: "shot-1", ["tool_name": "Read", "permission_mode": "bypassPermissions",
                                                      "tool_input": ["file_path": "/tmp/Payments.swift"]])
    for id in ["a", "b", "c"] { hookEvent(c, p, "SubagentStart", session: "shot-1", ["agent_id": id, "agent_type": "Explore"]) }
    let u = c.newWorkspace(select: false)
    u.customTitle = "release notes"
    hookEvent(c, u.panes[0], "UserPromptSubmit", session: "shot-2", ["prompt": "x"])
    hookEvent(c, u.panes[0], "StopFailure", session: "shot-2", ["error": "rate_limit",
              "last_assistant_message": "You've hit your session limit · resets 3pm (Asia/Seoul)"])
    let q = c.newWorkspace(select: false)
    q.customTitle = "flaky IME test"
    hookEvent(c, q.panes[0], "UserPromptSubmit", session: "shot-3", ["prompt": "x"])
    hookEvent(c, q.panes[0], "PreToolUse", session: "shot-3", ["tool_name": "Bash", "tool_input": ["command": "swift test"]])
    let d = c.newWorkspace(select: false)
    d.customTitle = "docs typo"
    hookEvent(c, d.panes[0], "UserPromptSubmit", session: "shot-4", ["prompt": "x"])
    hookEvent(c, d.panes[0], "Stop", session: "shot-4", ["last_assistant_message": "Fixed."])
    await sleepMs(300)
    now = now.addingTimeInterval(12 * 60)
    // Only the quiet row stays quiet: the others had a sign of life just now.
    for w in [main, u, d] { c.noteAgentActivity(w.panes[0]) }
    c.updateAttention()
    await shoot(c, dir, "extras-single")
    _ = c.split(p, .right)
    c.focus(p)
    c.refreshPaneChrome()
    await shoot(c, dir, "extras-split") { c.refreshPaneChrome() }
    return 0
}
