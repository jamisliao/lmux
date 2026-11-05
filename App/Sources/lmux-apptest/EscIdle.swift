import AppKit
@testable import LmuxUI

// `lmux-apptest --esc-idle`: Esc / Ctrl+C stops Claude Code mid-turn and Claude sends no hook
// (2.1.280, checked against the real CLI), only its `[Request interrupted by user]` marker in the
// transcript. A fake claude streams, then on the key writes that marker and nothing else: the row
// leaves "running" within ~1.5 s without a notification. Esc that stops nothing, Esc in an idle
// Claude pane, in a shell or in a Codex pane change nothing, and nothing runs without the key.

@MainActor
func runEscIdle() async -> Int32 {
    let r = Report()
    let c = makeController()
    c.assumeAppActive = true
    let w = c.window!
    r.section = "esc idle"
    let base = await idleCost(5)
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lmux-escidle-\(getpid())")
    let projects = dir.appendingPathComponent("claude/projects/-tmp-escidle")
    try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let mark = dir.appendingPathComponent("marker.jsonl")
    let fake = dir.appendingPathComponent("fake-claude.sh")
    // Streams under Claude's working title (`◐ Claude Code`) until Esc / Ctrl+C. interrupt: appends
    // Claude's marker to the transcript (no hook, title left as is). thinking: Esc before any reply
    // text (2.1.280: no marker, no hook, only the title goes back to `✳ Claude Code`). menu: the key
    // closes a menu, Claude keeps working.
    try? """
    #!/bin/sh
    stty raw -echo
    printf '\\033]0;◐ Claude Code\\007'
    ( i=0; while :; do i=$((i+1)); printf 'streaming %d\\r\\n' "$i"; sleep 0.2; done ) &
    S=$!
    while :; do
      k=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n')
      case "$k" in 1b|03)
        if [ "$2" = interrupt ]; then kill $S 2>/dev/null; cat "$3" >> "$1"; printf 'Interrupted\\r\\n'; fi
        if [ "$2" = thinking ]; then kill $S 2>/dev/null; printf '\\033]0;✳ Claude Code\\007'; fi ;;
      esac
    done

    """.write(to: fake, atomically: true, encoding: .utf8)
    chmod(fake.path, 0o755)

    func common(_ sid: String) -> String {
        #""isSidechain":false,"userType":"external","cwd":"/tmp","sessionId":"\#(sid)","version":"2.1.280""#
    }
    var made: [Workspace] = []
    /// A pane running the fake claude, bound to a session whose transcript holds a streaming turn.
    func claudePane(_ mode: String) async -> (Pane, String) {
        let sid = UUID().uuidString.lowercased()
        let path = projects.appendingPathComponent("\(sid).jsonl").path
        try? """
        {"parentUuid":null,\(common(sid)),"type":"user","message":{"role":"user","content":"explain the build"},"uuid":"u1","timestamp":"2026-11-02T10:00:00.000Z","promptSource":"typed"}
        {"parentUuid":"u1",\(common(sid)),"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"The build first"}]},"uuid":"a1","timestamp":"2026-11-02T10:00:01.000Z"}

        """.write(toFile: path, atomically: true, encoding: .utf8)
        try? """
        {"parentUuid":"a1",\(common(sid)),"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"x1","timestamp":"2026-11-02T10:00:02.000Z"}

        """.write(to: mark, atomically: true, encoding: .utf8)
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launcher = dir.appendingPathComponent("run-\(sid).sh")
        try? "#!/bin/sh\nexec \(q(fake.path)) \(q(path)) \(mode) \(q(mark.path))\n".write(to: launcher, atomically: true, encoding: .utf8)
        chmod(launcher.path, 0o755)
        let ws = c.newWorkspace(program: launcher.path)
        made.append(ws)
        let p = ws.panes[0]
        _ = await waitFor(5) { p.surface.readText().contains("streaming") }
        hookEvent(c, p, "SessionStart", session: sid, transcript: path, ["source": "startup"])
        hookEvent(c, p, "UserPromptSubmit", session: sid, ["prompt": "explain the build"])
        c.focus(p)
        _ = await waitFor(2) { p.agent.state == .running && w.firstResponder === p.surface }
        return (p, sid)
    }
    func isRunning(_ p: Pane) -> Bool { if case .running = p.display { return true }; return false }
    /// `korean`: the Korean 2-Set source's event shape (the key's own character is the jamo "ㅊ").
    func ctrlC(korean: Bool = false) {
        let ts = ProcessInfo.processInfo.systemUptime
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [.control], timestamp: ts, windowNumber: w.windowNumber,
                                     context: nil, characters: "\u{03}", charactersIgnoringModifiers: korean ? "ㅊ" : "c",
                                     isARepeat: false, keyCode: 8)!
            dispatchKey(e, window: w)
        }
    }
    let posted0 = c.notifier.postedCount
    let notes0 = c.model.notifications.count

    // 1. Esc stops the turn: marker, no hook -> idle, quietly.
    let (p1, _) = await claudePane("interrupt")
    r.check("(setup) fake claude streams, row running, spinner turning", isRunning(p1) && spinningViews(c) >= 1,
            "\(p1.display) spin \(spinningViews(c))")
    let t0 = Date()
    await type("\u{1b}", window: w)
    let idle = await waitFor(1.5) { p1.agent.state == .idle }
    let took = Date().timeIntervalSince(t0)
    r.check(String(format: "Esc (no hook, marker in the transcript): row idle within 1.5 s (%.2f s)", took),
            idle && !isRunning(p1) && { if case .running = p1.workspace!.display { return false }; return true }(), "\(p1.agent.state)")
    await sleepMs(200)
    r.check("…spinner stopped", spinningViews(c) == 0, "spin \(spinningViews(c))")
    r.check("…no notification, no done ✓, nothing unread", c.notifier.postedCount == posted0 && c.model.notifications.count == notes0
            && p1.unread == 0 && p1.lastAlertAt == nil, "posted \(c.notifier.postedCount - posted0) notes \(c.model.notifications.count - notes0)")
    r.check("…the check is gone (nothing pending)", c.interruptChecks.isEmpty)
    let sid1 = p1.claudeSessionID ?? ""
    hookEvent(c, p1, "UserPromptSubmit", session: sid1, ["prompt": "go on"])
    r.check("the next real hook takes over (running again)", isRunning(p1))
    hookEvent(c, p1, "Stop", session: sid1, ["last_assistant_message": "ok"])
    r.check("…and its Stop is a normal done", p1.agent.state == .done)

    // 2. Ctrl+C stops it the same way.
    let (p2, _) = await claudePane("interrupt")
    ctrlC()
    let idle2 = await waitFor(1.5) { p2.agent.state == .idle }
    r.check("Ctrl+C (no hook, marker): row idle within 1.5 s", idle2, "\(p2.agent.state)")
    let (p2k, _) = await claudePane("interrupt")
    _ = await waitFor(3) { w.firstResponder === p2k.surface }
    ctrlC(korean: true)
    // The key path is what's checked here (not the latency, which the checks above measure).
    let idle2k = await waitFor(3) { p2k.agent.state == .idle }
    r.check("Ctrl+C with the Korean input source (\"ㅊ\", key code 8): row idle", idle2k, "\(p2k.agent.state)")

    // 2b. Esc while Claude only thinks: no marker; its title back to ✳ is the sign.
    let (pT, _) = await claudePane("thinking")
    // The title OSC goes out before the first "streaming" line but reaches the surface's title
    // on a later main-queue turn: wait on the title itself, not on the output.
    let titled = await waitFor(3) { pT.surface.title.hasPrefix("◐") }
    r.check("(setup) Claude's working title", titled, pT.surface.title)
    let tT = Date()
    await type("\u{1b}", window: w)
    let idleT = await waitFor(2) { pT.agent.state == .idle }
    r.check(String(format: "Esc while thinking (no marker, title ✳): row idle at the second look (%.2f s)", Date().timeIntervalSince(tT)),
            idleT && c.notifier.postedCount == posted0, "\(pT.agent.state) title \(pT.surface.title)")

    // 3. Esc that stopped nothing (closed a menu): no marker, still running.
    let (p3, _) = await claudePane("menu")
    await type("\u{1b}", window: w)
    await sleepMs(1800)
    r.check("Esc that didn't stop Claude (no marker): stays running", isRunning(p3) && c.interruptChecks.isEmpty, "\(p3.display)")

    // 4. A new prompt right after Esc: the pending look is about the old turn, never applied.
    let (p4, sid4) = await claudePane("interrupt")
    await type("\u{1b}", window: w)
    hookEvent(c, p4, "UserPromptSubmit", session: sid4, ["prompt": "instead do this"])
    await sleepMs(1600)
    r.check("Esc then a new prompt before the look: stays running", isRunning(p4), "\(p4.display)")

    // 5. Esc where there's nothing to stop: no transcript look at all.
    hookEvent(c, p3, "Stop", session: p3.claudeSessionID ?? "", ["last_assistant_message": "ok"])
    c.focus(p3)
    _ = await waitFor(2) { w.firstResponder === p3.surface }
    let reads3 = c.transcriptReads[p3.id]?.bytes ?? 0
    await type("\u{1b}", window: w)
    r.check("Esc in a Claude pane that isn't working: no check scheduled", c.interruptChecks.isEmpty && p3.agent.state == .done)
    await sleepMs(400)
    r.check("…and its transcript isn't read", (c.transcriptReads[p3.id]?.bytes ?? 0) == reads3)
    let shell = c.newWorkspace()
    made.append(shell)
    _ = await sinks.waitReady(shell.panes[0].id)
    c.focus(shell.panes[0])
    _ = await waitFor(2) { w.firstResponder === shell.panes[0].surface }
    await type("\u{1b}", window: w)
    r.check("Esc in a shell pane: nothing", c.interruptChecks.isEmpty && shell.panes[0].agent.state == .idle)
    let (p6, _) = await claudePane("interrupt")
    p6.agentKind = .codex  // Codex sends its own Interrupt hook: no second path
    await type("\u{1b}", window: w)
    r.check("Esc in a Codex pane: no transcript look (its Interrupt hook does it)", c.interruptChecks.isEmpty && isRunning(p6))

    // Idle cost: nothing runs once the keys are handled.
    for ws in made { c.closeWorkspace(ws) }
    await sleepMs(500)
    let cost = await idleCost(5)
    print(String(format: "INFO  [esc idle] idle CPU over 5s: %.2f%% before, %.2f%% after the Esc checks; CVDisplayLink: %@",
                 base.cpu, cost.cpu, cost.links.text))
    r.check(String(format: "idle CPU < 1%% afterwards (%.2f%%)", cost.cpu), cost.cpu < 1.0)
    r.check("…no CVDisplayLink kept running (\(cost.links.text))", !cost.links.kept)
    r.check("…nothing pending", c.interruptChecks.isEmpty)
    return finish(r, c)
}
