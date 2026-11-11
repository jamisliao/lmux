import AppKit
import LmuxHooks
@testable import LmuxUI

// `lmux-apptest --attention`: a done / needs-input row left unattended breathes after the
// reminder delay (fake clock), stops when attended, never while it's on screen, a static ring
// under Reduce Motion, Off disables it, and three breathing rows cost no idle CPU.

/// The sidebar's breathing glyphs (Core Animation `pulse` animations), by row.
@MainActor
func pulsingViews(_ c: LmuxController) -> Int {
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    func walk(_ v: NSView) -> Int {
        let me = (v.layer?.animation(forKey: "pulse") != nil) ? 1 : 0
        return me + v.subviews.reduce(0) { $0 + walk($1) }
    }
    return walk(c.root.sidebarHost)
}

/// Sidebar layers (any depth, view-backed or not) running the Core Animation animation `key`.
@MainActor
func animatedLayers(_ c: LmuxController, _ key: String) -> [CAAnimation] {
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    func walk(_ l: CALayer) -> [CAAnimation] {
        (l.animation(forKey: key).map { [$0] } ?? []) + (l.sublayers ?? []).flatMap(walk)
    }
    return c.root.sidebarHost.layer.map(walk) ?? []
}

/// The sidebar's turning spinners (Core Animation `spin` animations on the arc layer).
@MainActor
func spinningViews(_ c: LmuxController) -> Int {
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    func walk(_ v: NSView) -> Int {
        let me = (v.layer?.sublayers ?? []).contains { $0.animation(forKey: "spin") != nil } ? 1 : 0
        return me + v.subviews.reduce(0) { $0 + walk($1) }
    }
    return walk(c.root.sidebarHost)
}

/// Idle CPU of this process over `seconds` (less the sampling's own), and whether a CVDisplayLink kept running meanwhile.
///
/// The link's thread is sampled every 100 ms over the whole window, not counted at its two ends:
/// libghostty's renderer starts a display link for a frame now and then (a pane redrawing) and
/// stops it again, so a count at one instant caught that blip at random (the old "0 -> 1" flake).
/// What the check is about, an animation drawn per frame in lmux, keeps a link running: present
/// in nearly every sample. A blip is one or two samples.
struct LinkUse { var share: Double; var longestMs: Int
    var kept: Bool { share >= 0.5 || longestMs >= 1000 }
    var text: String { String(format: "link up in %.0f%% of samples, longest %d ms", share * 100, longestMs) }
}

@MainActor
func idleCost(_ seconds: Double = 10) async -> (cpu: Double, links: LinkUse) {
    func now() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    let t0 = now(), w0 = Date()
    var on = 0, total = 0, run = 0, longest = 0
    // The sampling is the harness's own work, not lmux's: its CPU time (this thread's clock
    // around each sample) is left out of the idle figure. Counted in, it put ~0.1-0.2% on top
    // and "idle CPU < 1%" failed at 1.01-1.16% on runs where lmux itself was at ~0.9%.
    var samplerNs: UInt64 = 0
    while Date().timeIntervalSince(w0) < seconds {
        let s0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let up = threadNames().contains { $0.contains("CVDisplayLink") }
        samplerNs += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - s0
        total += 1
        if up { on += 1; run += 1; longest = max(longest, run) } else { run = 0 }
        await sleepMs(100)
    }
    let cpu = (now() - t0 - Double(samplerNs) / 1e9) / Date().timeIntervalSince(w0) * 100
    return (cpu, LinkUse(share: Double(on) / Double(max(total, 1)), longestMs: longest * 100))
}

@MainActor
func runAttention() async -> Int32 {
    let r = Report()
    let c = makeController()
    c.assumeAppActive = true
    var now = Date()
    c.attentionClock = { now }
    c.reduceMotionOverride = false
    c.updatePulseMotion()
    r.section = "attention"
    let home = c.model.selected!
    var ws: [Workspace] = []
    for t in ["B", "C", "D", "E", "F"] {
        let w = c.newWorkspace(select: false)
        w.customTitle = t
        ws.append(w)
        _ = await sinks.waitReady(w.panes[0].id)
    }
    func done(_ w: Workspace, _ s: String) {
        hookEvent(c, w.panes[0], "SessionStart", session: s)
        hookEvent(c, w.panes[0], "UserPromptSubmit", session: s, ["prompt": "x"])
        hookEvent(c, w.panes[0], "Stop", session: s, ["last_assistant_message": "done"])
    }
    func advance(_ minutes: Double) async {
        now = now.addingTimeInterval(minutes * 60)
        c.updateAttention()
        await sleepMs(150)
    }
    let B = ws[0], C = ws[1], D = ws[2], E = ws[3], F = ws[4]
    r.check("nothing pending: no timer", c.attentionWork == nil)
    done(B, "a-b")
    _ = await waitFor(2) { B.panes[0].attentionSince != nil }
    r.check("B finished while another workspace was on screen: the unattended clock starts", B.panes[0].attentionSince != nil
            && B.unattendedSince == nil)
    r.check("…one coarse timer while it's pending", c.attentionWork != nil)
    await advance(2.9)
    r.check("2.9 minutes: still calm", B.unattendedSince == nil && pulsingViews(c) == 0)
    await advance(0.2)
    r.check("3 minutes (default): B breathes", B.unattendedSince != nil && pulsingViews(c) == 1, "\(pulsingViews(c))")
    let halos = animatedLayers(c, "halo"), glyphs = animatedLayers(c, "pulse")
    let beats = (glyphs + halos).map(\.beginTime)
    r.check("…clearly: the check dims to 0.25 and an accent halo swells behind it, on one beat",
            halos.count == 1 && (glyphs.first as? CABasicAnimation)?.toValue as? Double == 0.25
            && Set(beats.map { ($0 / 1.6).rounded() }).count == 1 && beats.count == 2,
            "halo \(halos.count) beats \(beats)")
    r.check("…VoiceOver: “waiting 3 minutes”", c.waitingLabel(B) == "waiting 3 minutes", c.waitingLabel(B) ?? "nil")
    r.check("…no extra notification by default", !c.notifier.posted.contains { $0.kind == "reminder" })
    await advance(2)
    r.check("…“waiting 5 minutes” later", c.waitingLabel(B) == "waiting 5 minutes", c.waitingLabel(B) ?? "nil")

    // The workspace on screen never counts as unattended.
    done(home, "a-home")
    _ = await waitFor(2) { if case .done = home.panes[0].display { return true }; return false }
    await advance(20)
    r.check("finishing in the visible workspace (window key) never breathes", home.panes[0].attentionSince == nil && home.unattendedSince == nil)

    // needs input breathes too.
    hookEvent(c, C.panes[0], "SessionStart", session: "a-c")
    hookEvent(c, C.panes[0], "UserPromptSubmit", session: "a-c", ["prompt": "x"])
    hookEvent(c, C.panes[0], "Notification", session: "a-c", ["message": "Allow?", "notification_type": "permission_prompt"])
    _ = await waitFor(2) { C.panes[0].attentionSince != nil }
    await advance(3.5)
    r.check("needs input left 3 minutes breathes too (its badge)", C.unattendedSince != nil && pulsingViews(c) == 2, "\(pulsingViews(c))")

    // Attending: select (window key), typing, a new prompt.
    c.select(B)
    await sleepMs(150)
    r.check("selecting B while lmux is active resets it", B.unattendedSince == nil && B.panes[0].attentionSince == nil && pulsingViews(c) == 1)
    c.select(home)
    hookEvent(c, C.panes[0], "UserPromptSubmit", session: "a-c", ["prompt": "y"])
    await sleepMs(150)
    r.check("a new prompt in C resets it", C.unattendedSince == nil && pulsingViews(c) == 0)
    done(D, "a-d")
    _ = await waitFor(2) { D.panes[0].attentionSince != nil }
    await advance(6)
    r.check("D breathes", D.unattendedSince != nil)
    c.userTyped(D.panes[0])
    await sleepMs(150)
    r.check("typing into D's pane resets it", D.unattendedSince == nil && D.panes[0].attentionSince == nil)
    c.assumeAppActive = false
    done(E, "a-e")
    _ = await waitFor(2) { E.panes[0].attentionSince != nil }
    c.select(E)
    await advance(6)
    r.check("selected but lmux not active: still counts as unattended", E.unattendedSince != nil)
    c.assumeAppActive = true
    c.refreshPaneChrome()
    r.check("…until lmux becomes active with E on screen", E.unattendedSince == nil)
    c.select(home)

    // Hidden window: no animation (the row keeps its state).
    done(B, "a-b2")
    _ = await waitFor(2) { B.panes[0].attentionSince != nil }
    await advance(6)
    c.windowShownOverride = false
    c.syncOcclusion()
    await sleepMs(150)
    r.check("window hidden or minimized: the animation is removed", B.unattendedSince != nil && pulsingViews(c) == 0 && !c.model.pulseMotion
            && animatedLayers(c, "halo").isEmpty)
    c.windowShownOverride = nil
    c.syncOcclusion()
    await sleepMs(150)
    r.check("…and back when it's seen again", pulsingViews(c) == 1)
    // Selected while the window can't be seen: still unattended, cleared the moment it's seen.
    c.windowShownOverride = false
    c.syncOcclusion()
    c.select(B)
    await sleepMs(150)
    r.check("selected while the window is hidden: still unattended", B.unattendedSince != nil && B.panes[0].attentionSince != nil)
    c.windowShownOverride = nil
    c.syncOcclusion()
    r.check("…cleared as soon as the window is seen (occlusion -> visible)", B.unattendedSince == nil && B.panes[0].attentionSince == nil)
    c.select(home)
    done(B, "a-b3")
    _ = await waitFor(2) { B.panes[0].attentionSince != nil }
    await advance(6)

    // Reduce Motion: a static accent ring, no animation.
    c.reduceMotionOverride = true
    c.updatePulseMotion()
    await sleepMs(150)
    r.check("Reduce Motion: no animation, the row still marked (static ring)", pulsingViews(c) == 0 && B.unattendedSince != nil
            && animatedLayers(c, "halo").isEmpty
            && c.model.reduceMotion)
    c.reduceMotionOverride = false
    c.updatePulseMotion()

    // Settings: Off, and the optional notification.
    c.settings.remindAfterMinutes = 0
    c.updateAttention()
    // (C is mid-prompt: its quiet hint keeps the one coarse timer; nothing running, none at all.)
    let runningLeft = c.model.workspaces.flatMap(\.panes).contains { $0.agent.state == .running }
    r.check("Remind me after: Off stops it (and no reminder timer)",
            B.unattendedSince == nil && (c.attentionWork == nil) == !runningLeft && pulsingViews(c) == 0)
    c.settings.remindAfterMinutes = 2
    c.settings.remindNotification = true
    let posted0 = c.notifier.postedCount
    done(F, "a-f")
    _ = await waitFor(2) { F.panes[0].attentionSince != nil }
    await advance(2.1)
    r.check("2 minutes + Remind again via notification: one reminder notification", F.unattendedSince != nil
            && c.notifier.posted.filter { $0.kind == "reminder" }.count >= 1 && c.notifier.postedCount > posted0)
    let reminders = c.notifier.posted.filter { $0.kind == "reminder" }.count
    await advance(3)
    r.check("…only once per wait", c.notifier.posted.filter { $0.kind == "reminder" }.count == reminders)
    c.settings.remindNotification = false
    c.settings.remindAfterMinutes = 3

    // Three breathing rows cost nothing per frame in lmux.
    r.section = "attention idle"
    // Nothing running (a running row's spinner is a separate, existing cost): C was mid-prompt.
    c.closeWorkspace(C)
    c.closeWorkspace(F)
    for w in [B, D, E] { done(w, "idle-\(w.title)") }
    _ = await waitFor(2) { [B, D, E].allSatisfy { $0.panes[0].attentionSince != nil } }
    await advance(6)
    await sleepMs(500)
    let rows = [B, D, E].filter { $0.unattendedSince != nil }.count
    r.check("3 rows breathing, nothing running", rows == 3 && pulsingViews(c) == 3
            && !c.model.workspaces.contains { if case .running = $0.display { return true }; return false }, "rows \(rows) pulses \(pulsingViews(c))")
    c.reduceMotionOverride = true; c.updatePulseMotion(); await sleepMs(300)
    let base = await cpuPercent(seconds: 10)
    c.reduceMotionOverride = false; c.updatePulseMotion(); await sleepMs(300)
    print(String(format: "INFO  [attention idle] baseline (same rows, no animation) %.2f%%", base))
    let (cpu, links) = await idleCost()
    print(String(format: "INFO  [attention idle] %d breathing rows: lmux idle CPU %.2f%% over 10s, CVDisplayLink: %@",
                 pulsingViews(c), cpu, links.text))
    r.check(String(format: "idle CPU < 1%% with the rows breathing (%.2f%%)", cpu), cpu < 1.0)
    r.check("no CVDisplayLink kept running (\(links.text))", !links.kept)

    // Agents working: running rows turn a Core Animation spinner, nothing per frame in lmux.
    r.section = "running idle"
    var running: [Workspace] = []
    for i in 0..<3 {
        let w = c.newWorkspace(select: false)
        w.customTitle = "run \(i)"
        _ = await sinks.waitReady(w.panes[0].id)
        hookEvent(c, w.panes[0], "SessionStart", session: "run-\(i)")
        hookEvent(c, w.panes[0], "UserPromptSubmit", session: "run-\(i)", ["prompt": "x"])
        hookEvent(c, w.panes[0], "PreToolUse", session: "run-\(i)", ["tool_name": "Bash", "tool_input": ["command": "swift build"]])
        running.append(w)
    }
    _ = await waitFor(3) { running.allSatisfy { if case .running = $0.display { return true }; return false } }
    // (a) 3 running rows alone: the breathing rows go calm first.
    let savedMinutes = c.settings.remindAfterMinutes
    c.settings.remindAfterMinutes = 0
    c.updateAttention()
    await sleepMs(500)
    r.check("3 running rows turn (Core Animation), nothing else animates", spinningViews(c) == 3 && pulsingViews(c) == 0,
            "spin \(spinningViews(c)) pulse \(pulsingViews(c))")
    let a3 = await idleCost()
    print(String(format: "INFO  [running idle] 3 running rows: lmux idle CPU %.2f%% over 10s, CVDisplayLink: %@", a3.cpu, a3.links.text))
    r.check(String(format: "3 running rows: idle CPU < 1%% (%.2f%%)", a3.cpu), a3.cpu < 1.0)
    r.check("…no CVDisplayLink kept running (\(a3.links.text))", !a3.links.kept)
    // (b) 3 running + 3 breathing.
    c.settings.remindAfterMinutes = savedMinutes
    c.updateAttention()
    await sleepMs(500)
    r.check("3 running + 3 breathing", spinningViews(c) == 3 && pulsingViews(c) == 3, "spin \(spinningViews(c)) pulse \(pulsingViews(c))")
    let b6 = await idleCost()
    print(String(format: "INFO  [running idle] 3 running + 3 breathing: lmux idle CPU %.2f%% over 10s, CVDisplayLink: %@", b6.cpu, b6.links.text))
    r.check(String(format: "3 running + 3 breathing: idle CPU < 1%% (%.2f%%)", b6.cpu), b6.cpu < 1.0)
    r.check("…no CVDisplayLink kept running (\(b6.links.text))", !b6.links.kept)
    // Hidden window: nothing turns or breathes; Reduce Motion: the arc stays, still.
    c.windowShownOverride = false
    c.syncOcclusion()
    await sleepMs(200)
    r.check("window hidden: spinners and pulses removed", spinningViews(c) == 0 && pulsingViews(c) == 0)
    c.windowShownOverride = nil
    c.syncOcclusion()
    c.reduceMotionOverride = true
    c.updatePulseMotion()
    await sleepMs(200)
    r.check("Reduce Motion: the running arc is drawn but still", spinningViews(c) == 0 && running.allSatisfy { if case .running = $0.display { return true }; return false })
    c.reduceMotionOverride = false
    c.updatePulseMotion()
    await sleepMs(200)
    r.check("…and turns again", spinningViews(c) == 3)

    // A relaunch shows every resumed done row's ✓ again and keeps an unattended one's clock
    // (layout.json): overdue breathes right away. Claude and Codex alike.
    r.section = "attention relaunch"
    let xs = "5a0c7e3d-1b2f-4c6a-8d9e-0f1a2b3c4d5e", ys = "6b1d8f4e-2c3a-4d7b-9eaf-1a2b3c4d5e6f"
    let zs = "7c2e9a5f-3d4b-4e8c-8fb0-2b3c4d5e6f70", codexSID = "019a2b3c-4d5e-7f60-8a71-b2c3d4e5f6a7"
    let X = c.newWorkspace(select: false), Y = c.newWorkspace(select: false), W = c.newWorkspace(select: false)
    X.customTitle = "X"; Y.customTitle = "Y"; W.customTitle = "W"
    for w in [X, Y, W] { _ = await sinks.waitReady(w.panes[0].id) }
    func codex(_ c: LmuxController, _ p: Pane, _ name: String, _ extra: [String: Any] = [:]) {
        var e = try! HookEvent(paneID: p.id, payload: extra.merging(["hook_event_name": name, "session_id": codexSID, "cwd": "/tmp"]) { $1 })
        e.agent = .codex
        c.handleHook(e)
    }
    now = Date().addingTimeInterval(-10 * 60)
    done(X, xs)
    codex(c, W.panes[0], "SessionStart", ["source": "startup"])
    codex(c, W.panes[0], "UserPromptSubmit", ["prompt": "x"])
    codex(c, W.panes[0], "Stop", ["last_assistant_message": "codex done"])
    now = Date().addingTimeInterval(-60)
    done(Y, ys)
    c.select(home)
    done(home, zs)  // looked at: done, no wait
    _ = await waitFor(2) { [X, Y, W].allSatisfy { $0.panes[0].attentionSince != nil } }
    let xSince = X.panes[0].attentionSince, xID = X.panes[0].id, yID = Y.panes[0].id, zID = home.panes[0].id, wID = W.panes[0].id
    r.check("(setup) the home row finished on screen (no wait), W is a Codex pane",
            home.panes[0].display == .done("done") && home.panes[0].attentionSince == nil && W.panes[0].agentKind == .codex)
    c.settings.remindNotification = true  // (settings.plist: the relaunch has it on too)
    c.saveNow()
    c.shutdown()
    let c2 = makeController()
    // The rows' views come up with the first layout passes: wait for them, not a fixed time.
    _ = await waitFor(5) { pulsingViews(c2) == 2 }
    let rx = c2.pane(id: xID), ry = c2.pane(id: yID), rz = c2.pane(id: zID), rw = c2.pane(id: wID)
    func sameStart(_ d: Date?) -> Bool { d.map { abs($0.timeIntervalSince(xSince ?? .distantPast)) < 0.001 } ?? false }
    r.check("after relaunch the done row is back (✓, its reply line) with its original wait start",
            rx?.display == .done("done") && sameStart(rx?.attentionSince) && rx?.workspace?.title == "X",
            "\(String(describing: rx?.display)) \(String(describing: rx?.attentionSince)) vs \(String(describing: xSince))")
    r.check("…a row already looked at comes back ✓ too, without a wait (no pulse)",
            rz?.display == .done("done") && rz?.attentionSince == nil && rz?.workspace?.unattendedSince == nil,
            "\(String(describing: rz?.display))")
    r.check("…and the Codex row the same (✓, its reply, its wait)",
            rw?.agentKind == .codex && rw?.display == .done("codex done") && rw?.attentionSince != nil && rw?.workspace?.unattendedSince != nil,
            "\(String(describing: rw?.display))")
    r.check("…already overdue (10 min): they breathe right away, no reminder notification at launch",
            rx?.workspace?.unattendedSince != nil && pulsingViews(c2) == 2 && c2.model.pulseMotion
                && !c2.notifier.posted.contains { $0.kind == "reminder" }, "pulses \(pulsingViews(c2)) \(c2.notifier.posted.map(\.title))")
    r.check("…a 1-minute-old one waits for the rest of its 3 minutes", ry?.attentionSince != nil && ry?.workspace?.unattendedSince == nil)
    let later = Date().addingTimeInterval(2.5 * 60)
    c2.attentionClock = { later }
    c2.updateAttention()
    _ = await waitFor(3) { pulsingViews(c2) == 3 }
    r.check("…and breathes once they're up (fake clock), with its one reminder now",
            ry?.workspace?.unattendedSince != nil && pulsingViews(c2) == 3
                && c2.notifier.posted.filter { $0.kind == "reminder" }.count == 1, "\(pulsingViews(c2))")
    if let rx { hookEvent(c2, rx, "SessionStart", session: xs, ["source": "resume"]) }
    await sleepMs(150)
    _ = await waitFor(3) { pulsingViews(c2) == 3 }
    r.check("the resumed agent's SessionStart (same session) keeps the done state and its clock",
            rx?.display == .done("done") && sameStart(rx?.attentionSince) && pulsingViews(c2) == 3)
    if let rw { codex(c2, rw, "SessionStart", ["source": "resume"]) }
    await sleepMs(150)
    _ = await waitFor(3) { pulsingViews(c2) == 3 }
    r.check("…Codex's too", rw?.display == .done("codex done") && rw?.attentionSince != nil && pulsingViews(c2) == 3)
    if let ry { hookEvent(c2, ry, "SessionStart", session: ys, ["source": "clear"]) }
    _ = await waitFor(3) { pulsingViews(c2) == 2 }
    r.check("…/clear (a new conversation) resets it as before", ry?.display == .idle && ry?.attentionSince == nil && pulsingViews(c2) == 2)
    c2.assumeAppActive = true
    if let w = rx?.workspace { c2.select(w) }
    _ = await waitFor(3) { pulsingViews(c2) == 1 }
    r.check("selecting it (lmux active) clears the wait, the ✓ stays",
            rx?.attentionSince == nil && rx?.workspace?.unattendedSince == nil && rx?.display == .done("done") && pulsingViews(c2) == 1)
    if let rw { codex(c2, rw, "UserPromptSubmit", ["prompt": "more"]) }
    if let rz { hookEvent(c2, rz, "UserPromptSubmit", session: zs, ["prompt": "more"]) }
    _ = await waitFor(3) { pulsingViews(c2) == 0 }
    r.check("a new prompt drops the restored ✓ (Claude and Codex) and the wait", rz?.display == .running(nil)
            && rw?.display == .running(nil) && rw?.attentionSince == nil && pulsingViews(c2) == 0,
            "\(String(describing: rz?.display)) \(String(describing: rw?.display))")
    // The agent gone (SessionEnd; a resume that failed ends the same way, `resetAfterClaude` once the
    // shell prompts again with no agent): a plain shell, ✓ gone.
    if let rx { hookEvent(c2, rx, "SessionEnd", session: xs, ["reason": "other"]) }
    await sleepMs(150)
    r.check("the agent leaving drops the restored ✓", rx?.display == .idle && rx?.claudeSessionID == nil)
    c2.saveNow()
    let after = (try? String(contentsOf: c2.paths.layoutFile, encoding: .utf8)) ?? ""
    r.check("…and the next layout.json has no ✓ or wait left to restore",
            !after.isEmpty && !after.contains("attentionSince") && !after.contains("doneAt"))
    c2.settings.remindNotification = false
    return finish(r, c2)
}
