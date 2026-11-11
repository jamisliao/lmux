import AppKit
import LmuxHooks
import LmuxTerminal
@testable import LmuxUI

// Agent-native bits (`--agents`): any program's own status (OSC 7501 `app=`), `lmux wait`, and
// what `lmux list --json` says about each pane's agent.

@MainActor
func runAgents() async -> Int32 {
    let r = Report()
    let c = makeController()
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("agents", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    func script(_ name: String, _ body: String) -> URL {
        let u = dir.appendingPathComponent(name)
        try? ("#!/bin/sh\n" + body).write(to: u, atomically: true, encoding: .utf8)
        chmod(u.path, 0o755)
        return u
    }
    // A program named my-agent, run as the pane's foreground job; once it's gone the launcher's
    // shell is the foreground (a builtin `read`), as at a prompt.
    let agent = script("my-agent", "while :; do sleep 1; done\n")
    let launch = dir.appendingPathComponent("launch.sh")
    try? "#!/bin/bash\nset -m\n'\(agent.path)'\nwhile :; do read -r x; done\n".write(to: launch, atomically: true, encoding: .utf8)
    chmod(launch.path, 0o755)
    func report(_ state: SurfaceView.ProgramStatus.State, _ kind: String? = nil, app: String = "my-agent") -> SurfaceView.ProgramStatus {
        SurfaceView.ProgramStatus(state: state, kind: kind, app: app)
    }
    func foregroundName(_ p: Pane) -> String? {
        ClaudeProcess.representative(ofGroup: p.surface.foregroundPID).flatMap(ClaudeProcess.name)
    }

    // ------------------------------------------------------------ OSC 7501 from any program
    r.section = "osc 7501: any agent"
    let other = c.newWorkspace(select: false)
    let op = other.panes[0]
    _ = await sinks.waitReady(op.id)
    let n0 = c.notifier.postedCount
    // The harness's pane runs `cat` in the foreground: what a `cat`-ed file could say.
    c.programStatus(op, report(.blocked, "question"))
    c.programStatus(op, report(.blocked, "question", app: "cat"))
    c.programStatus(op, report(.working, app: ""))
    r.check("a report naming a program that isn't the pane's foreground job (cat runs): ignored, nothing notified",
            op.programApp == nil && op.agent.state == .idle && c.notifier.postedCount == n0, "\(op.display)")

    let ws = c.newWorkspace(select: false, program: launch.path)
    let p = ws.panes[0]
    let up = await waitFor(5) { c.foregroundIs(p, app: "my-agent") }
    r.check("my-agent is the pane's foreground job", up, foregroundName(p) ?? "-")
    c.programStatus(p, report(.working))
    r.check("working: running, the agent is my-agent (its name as the label)", p.agent.state == .running
            && p.agentName == "my-agent" && ClaudeProcess.foregroundName(p) == "my-agent" && !p.runsClaude, "\(p.display)")
    c.checkClaudeStillRunning(p)  // (what a title change does; the script's own process name is `sh`)
    r.check("…a #!/bin/sh reporter (named sh) still running: a title change keeps it", p.programApp == "my-agent"
            && p.agent.state == .running)
    c.programStatus(p, report(.blocked, "question"))
    r.check("blocked: needs you, the ring, one notification with its name",
            p.needsInput && p.showsRing && c.notifier.postedCount == n0 + 1
            && c.notifier.posted.last?.body == "Needs input · my-agent has a question", c.notifier.posted.last?.body ?? "-")
    c.programStatus(p, report(.blocked, "question"))
    c.programStatus(p, report(.blocked, "permission"))
    c.userTyped(p)
    r.check("…repeats and a different ask: still one alert; typing doesn't clear it (its report says when)",
            p.needsInput && c.notifier.postedCount == n0 + 1)
    c.programStatus(p, report(.working, app: "imposter"))
    r.check("…another name meanwhile (not the foreground job): ignored", p.needsInput && p.programApp == "my-agent")
    c.programStatus(p, report(.blocked, "permission"))
    r.check("…a key that isn't Return (an arrow in its menu), then its redraw: the same ask, no new alert",
            p.needsInput && c.notifier.postedCount == n0 + 1, "\(c.notifier.postedCount - n0)")
    c.returnKey(p)
    c.programStatus(p, report(.blocked, "permission"))
    r.check("…after Return (an answer), the next blocked is a new ask: alerts again, no working needed in between",
            p.needsInput && c.notifier.postedCount == n0 + 2, "\(c.notifier.postedCount - n0)")
    c.programStatus(p, report(.blocked, "permission"))
    r.check("…and its repeat, with nothing typed, doesn't", c.notifier.postedCount == n0 + 2)
    c.programStatus(p, report(.working))
    c.programStatus(p, report(.done))
    c.programStatus(p, report(.idle))
    r.check("done: one more notification; the idle after it keeps it done",
            p.agent.state == .done && !p.failed && c.notifier.postedCount == n0 + 3 && c.notifier.posted.last?.kind == "done",
            "\(p.display) \(c.notifier.postedCount - n0)")
    c.programStatus(p, report(.working))
    r.check("a new turn: running again", p.agent.state == .running && !p.failed)
    let realGroup = p.programGroup
    p.programGroup = 999_999  // (as if the last instance died and a new one started under the same name)
    c.programStatus(p, report(.working))
    r.check("…the same report from a new instance (another job): bound to the new job, its exit watched",
            p.programGroup == realGroup && p.programExitWatch != nil, "\(p.programGroup) vs \(realGroup)")
    c.programStatus(p, report(.error))
    r.check("error: failed, notified once", p.display == .failed(nil) && c.notifier.postedCount == n0 + 4
            && c.notifier.posted.last?.kind == "failed", "\(p.display)")
    let unread0 = p.unread, entries0 = c.model.notifications.count
    for _ in 0..<5 { c.programStatus(p, report(.error)) }
    r.check("…the same error printed again (a redraw, a retry): no more notifications, unread or list entries",
            p.display == .failed(nil) && c.notifier.postedCount == n0 + 4 && p.unread == unread0
            && c.model.notifications.count == entries0, "\(c.notifier.postedCount - n0) \(p.unread) \(c.model.notifications.count)")
    c.programStatus(p, report(.working))
    c.programStatus(p, report(.clear, app: ""))
    r.check("clear (no app=, as Codex sends it): a shell again", p.programApp == nil && p.agent.state == .idle
            && ClaudeProcess.foregroundName(p) != "my-agent", "\(p.display)")

    // Hooks win: a pane whose Claude Code session hooks bound ignores its reports.
    let hws = c.newWorkspace(select: false, program: launch.path)
    let hp = hws.panes[0]
    _ = await waitFor(15) { c.foregroundIs(hp, app: "my-agent") }
    c.programStatus(hp, report(.working))
    c.handleHook(try! HookEvent(paneID: hp.id, payload: ["hook_event_name": "SessionStart", "session_id": "agents-1"]))
    r.check("a Claude Code hook in a pane a program reported in: hooks take it over", hp.runsClaude && hp.programApp == nil)
    let n1 = c.notifier.postedCount
    c.programStatus(hp, report(.blocked, "question"))
    c.programStatus(hp, report(.done, app: "claude-code"))
    r.check("…its own reports after that (Claude printing OSC 7501 too): no state, no second notification",
            !hp.needsInput && c.notifier.postedCount == n1 && hp.programApp == nil, "\(hp.display)")
    c.handleHook(try! HookEvent(paneID: hp.id, payload: ["hook_event_name": "UserPromptSubmit", "session_id": "agents-1"]))
    c.handleHook(try! HookEvent(paneID: hp.id, payload: ["hook_event_name": "Stop", "session_id": "agents-1",
                                                         "last_assistant_message": "All set."]))
    r.check("…the hooks' turn notifies once", hp.agent.state == .done && c.notifier.postedCount == n1 + 1)

    // The reporter's last words: it reported and quit before lmux looked.
    let lws = c.newWorkspace(select: false, program: launch.path)
    let lp = lws.panes[0]
    _ = await waitFor(15) { c.foregroundIs(lp, app: "my-agent") }
    c.programStatus(lp, report(.working))
    let agentGroup = lp.surface.foregroundPID
    c.reporterExitGrace = 60  // (here its exit isn't acted on: the steps below are the last words)
    kill(-agentGroup, SIGKILL)
    let back = await waitFor(5) { lp.surface.foregroundPID != agentGroup && c.runningProcess(lp) == nil }
    r.check("my-agent quit, the shell is the foreground again", back, foregroundName(lp) ?? "-")
    _ = c.foregroundArgv(lp, lp.surface.foregroundPID)
    r.check("…a shell in front is remembered with a watch for its exec (it may be one that forked the next job)",
            lp.programArgv?.group == lp.surface.foregroundPID && lp.programArgvWatch?.isCancelled == false)
    c.programStatus(lp, report(.working, app: "imposter"))
    r.check("…another name from the shell: ignored", lp.programApp == "my-agent" && lp.agent.state == .running)
    let n2 = c.notifier.postedCount
    c.programStatus(lp, report(.blocked, "question"))
    c.programStatus(lp, report(.working))
    r.check("…last words that don't end a turn (blocked, working: it quit, it can't wait or work): refused",
            !lp.needsInput && lp.agent.state == .running && lp.programGroup > 0 && c.notifier.postedCount == n2)
    c.programStatus(lp, report(.done))
    r.check("…my-agent's own done that came after it left: counted (one notification)",
            lp.agent.state == .done && c.notifier.postedCount == n2 + 1)
    c.programStatus(lp, report(.blocked, "question"))
    r.check("…last words count once: the next report with its name is refused", !lp.needsInput && c.notifier.postedCount == n2 + 1)
    c.checkClaudeStillRunning(lp)
    c.reporterExitGrace = 0.5
    r.check("gone without a clear (next prompt title): forgotten, the done stays", lp.programApp == nil && lp.agent.state == .done)
    c.programStatus(lp, report(.blocked, "question"))
    r.check("…and from then on its name from the shell counts for nothing", !lp.needsInput && c.notifier.postedCount == n2 + 1)

    // Ctrl-Z: the reporter is stopped, not gone. The shell's foreground is no reason to believe its name.
    // (An interactive bash takes the terminal back from a stopped job, as a prompt does; no rc, no history.)
    let zlaunch = dir.appendingPathComponent("launch-z.sh")
    try? "#!/bin/sh\nHISTFILE=/dev/null exec /bin/bash --norc --noprofile -i -c \"'\(agent.path)'; while :; do read -r x; done\"\n"
        .write(to: zlaunch, atomically: true, encoding: .utf8)
    chmod(zlaunch.path, 0o755)
    let zws = c.newWorkspace(select: false, program: zlaunch.path)
    let zp = zws.panes[0]
    _ = await waitFor(15) { c.foregroundIs(zp, app: "my-agent") }
    c.programStatus(zp, report(.working))
    let zGroup = zp.surface.foregroundPID
    kill(-zGroup, SIGSTOP)  // (what ⌃Z's SIGTSTP does, and can't be ignored)
    let stopped = await waitFor(5) { zp.surface.foregroundPID != zGroup && c.runningProcess(zp) == nil }
    let n4 = c.notifier.postedCount
    c.programStatus(zp, report(.blocked, "question"))
    c.programStatus(zp, report(.clear, app: ""))
    c.checkClaudeStillRunning(zp)
    r.check("stopped with Ctrl-Z, the shell in front: its name (a cat-ed file, say) can't block or clear it, and it isn't forgotten",
            stopped && zp.programApp == "my-agent" && zp.agent.state == .running && c.notifier.postedCount == n4,
            "stopped \(stopped) fg \(foregroundName(zp) ?? "-") \(zp.display) " + c.actionLog.filter { $0.contains("pane=\(zp.id.prefix(8))") }.joined(separator: " | "))
    kill(-zGroup, SIGKILL)
    kill(-zGroup, SIGCONT)
    _ = await waitFor(3) { !ClaudeProcess.groupAlive(zGroup) }
    c.checkClaudeStillRunning(zp)
    r.check("…killed: forgotten at the next title check (a running row goes idle)", zp.programApp == nil && zp.agent.state == .idle)
    c.closeWorkspace(zws)

    // A reporter killed while working, nothing printed after (no clear, no title change): its exit,
    // from the kernel, ends the row; the header (on screen here) stops naming it.
    let prevWS = c.model.selected
    let dws = c.newWorkspace(program: launch.path)
    let dp = dws.panes[0]
    _ = await waitFor(15) { c.foregroundIs(dp, app: "my-agent") }
    c.programStatus(dp, report(.working))
    c.flushPaneChrome()
    let named = dp.view.header.label.stringValue
    let dTitle = dp.title
    let dGroup = dp.surface.foregroundPID
    kill(-dGroup, SIGKILL)
    let ended = await waitFor(3) { dp.programApp == nil && dp.agent.state == .idle }
    c.flushPaneChrome()
    r.check("a reporter killed while working: idle about half a second after its exit, with no title change and no poll",
            ended && dp.title == dTitle && dp.programExitWatch == nil
            && c.actionLog.contains { $0.contains("program gone without a clear: pane=\(dp.id.prefix(8))") }, "\(dp.display)")
    r.check("…the header named it while it ran, and doesn't after", named == "my-agent"
            && dp.view.header.label.stringValue != "my-agent", "\(named) -> \(dp.view.header.label.stringValue)")
    c.programStatus(dp, report(.done))
    r.check("…its done, parsed after that (a big burst still in the pty): counts, as its last words", dp.agent.state == .done)
    c.programStatus(dp, report(.error))
    r.check("…once", dp.agent.state == .done && !dp.failed)
    c.checkClaudeStillRunning(dp)
    r.check("…and the next title change ends it", dp.lastWords == nil && dp.programApp == nil && dp.agent.state == .done)
    c.closeWorkspace(dws)
    if let prevWS { c.select(prevWS) }

    // A job's leader that execs in place (same group): its argv is looked at again, from the kernel's
    // exec event (a shell that forked the next job, then exec'd it).
    // (exec-job.sh runs as a job of its own, so it leads its group, as a shell's forked child does.)
    let execReady = dir.appendingPathComponent("exec-job.ready")
    let execJob = script("exec-job.sh", "trap \"exec '\(agent.path)'\" USR1\ntouch '\(execReady.path)'\nwhile :; do sleep 0.1; done\n")
    let execLaunch = dir.appendingPathComponent("exec.sh")
    try? "#!/bin/bash\nset -m\n'\(execJob.path)'\n".write(to: execLaunch, atomically: true, encoding: .utf8)
    chmod(execLaunch.path, 0o755)
    let ews0 = c.newWorkspace(select: false, program: execLaunch.path)
    let xe = ews0.panes[0]
    let jobUp = await waitFor(15) { fm.fileExists(atPath: execReady.path) && c.foregroundIs(xe, app: "exec-job") }
    let lookups0 = c.argvLookups
    c.programStatus(xe, report(.working))
    c.programStatus(xe, report(.blocked, "question"))
    r.check("a shell in front reporting my-agent: refused, its argv read once for both", jobUp && xe.programApp == nil
            && c.argvLookups - lookups0 == 1, "\(c.argvLookups - lookups0)")
    kill(xe.surface.foregroundPID, SIGUSR1)
    let execd = await waitFor(15) { c.foregroundIs(xe, app: "my-agent") }
    await sleepMs(100)
    c.programStatus(xe, report(.working))
    r.check("…it execs my-agent in place (same group): my-agent's report counts (the cache dropped at the exec)",
            execd && xe.programApp == "my-agent" && xe.agent.state == .running,
            "\(xe.display) execd \(execd) cache \(xe.programArgv.map { "\($0.group) \($0.argv)" } ?? "nil") fg \(xe.surface.foregroundPID) watch \(xe.programArgvWatch?.isCancelled.description ?? "nil")")
    c.closeWorkspace(ews0)

    // A codex taking over a pane a program reported in: codex's own path, the program forgotten.
    let codexDir = dir.appendingPathComponent("codexbin", isDirectory: true)
    try? fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
    let fakeCodex = codexDir.appendingPathComponent("codex")
    try? "#!/bin/sh\nwhile :; do sleep 1; done\n".write(to: fakeCodex, atomically: true, encoding: .utf8)
    chmod(fakeCodex.path, 0o755)
    let codexLaunch = codexDir.appendingPathComponent("launch.sh")
    try? "#!/bin/bash\nset -m\n'\(fakeCodex.path)'\n".write(to: codexLaunch, atomically: true, encoding: .utf8)
    chmod(codexLaunch.path, 0o755)
    let xws = c.newWorkspace(select: false, program: codexLaunch.path)
    let xp = xws.panes[0]
    _ = await waitFor(5) { c.foregroundIsCodex(xp) }
    xp.programApp = "my-agent"  // (as if my-agent had reported here before codex started)
    xp.programReport = .working
    c.programStatus(xp, report(.working, app: "codex"))
    r.check("codex's report in a pane a program reported in: codex's, the program forgotten",
            xp.codexReport == .working && xp.programApp == nil && xp.agentName == "codex", "\(xp.agentName ?? "-")")
    c.programStatus(xp, report(.clear, app: ""))
    r.check("…so codex's clear (no app=) is codex's: nothing stuck", xp.codexReport == nil && xp.agent.state == .idle)
    c.closeWorkspace(xws)

    // The real escape, through libghostty: a program printing it, and a file `cat` prints.
    r.section = "osc 7501: through the terminal"
    let e2e = script("e2e-agent", """
    printf '\\033]7501;state=working:app=e2e-agent\\033\\\\'
    sleep 0.3
    printf '\\033]7501;state=blocked:kind=permission:app=e2e-agent\\033\\\\'
    while :; do sleep 1; done

    """)
    let e2eLaunch = dir.appendingPathComponent("e2e.sh")
    try? "#!/bin/bash\nset -m\n'\(e2e.path)'\n".write(to: e2eLaunch, atomically: true, encoding: .utf8)
    chmod(e2eLaunch.path, 0o755)
    let ews = c.newWorkspace(select: false, program: e2eLaunch.path)
    let ep = ews.panes[0]
    let blocked = await waitFor(5) { ep.needsInput }
    r.check("a program printing state=blocked:app=e2e-agent: needs you, named e2e-agent",
            blocked && ep.agentName == "e2e-agent" && ep.alertDetail == "e2e-agent needs you", "\(ep.display)")
    let spoof = dir.appendingPathComponent("spoof.txt")
    try? "\u{1b}]7501;state=blocked:kind=question:app=e2e-agent\u{1b}\\\u{1b}]7501;state=blocked:app=cat\u{1b}\\\u{1b}]7501;state=done:app=my-agent\u{1b}\\"
        .write(to: spoof, atomically: true, encoding: .utf8)
    let catLaunch = dir.appendingPathComponent("cat.sh")
    try? "#!/bin/bash\nset -m\nsleep 0.5\ncat '\(spoof.path)'\nwhile :; do read -r x; done\n".write(to: catLaunch, atomically: true, encoding: .utf8)
    chmod(catLaunch.path, 0o755)
    let n3 = c.notifier.postedCount
    let ignored0 = c.ignoredProgramReports, lookupsCat = c.argvLookups
    let cws = c.newWorkspace(select: false, program: catLaunch.path)
    let cp = cws.panes[0]
    await sleepMs(1500)
    r.check("a file with OSC 7501 reports shown with cat: no state, no notification",
            cp.programApp == nil && cp.agent.state == .idle && c.notifier.postedCount == n3, "\(cp.display)")
    let joined = c.actionLog.filter { $0.contains("pane=\(cp.id.prefix(8))") }.joined(separator: " | ")
    // (One log line per foreground group: cat's, and the shell's for any looked at after cat quit.)
    // (A lookup per job and per exec: cat's group as the shell forked it, as cat, then the shell's after.)
    r.check("…all three seen and refused; a lookup per job and exec, one log line per job",
            c.ignoredProgramReports - ignored0 == 3 && c.argvLookups - lookupsCat <= 3
            && (1...2).contains(joined.components(separatedBy: "ignored").count - 1),
            "\(c.ignoredProgramReports - ignored0) refused, \(c.argvLookups - lookupsCat) lookups " + joined)
    // A file full of them: one process lookup and one log line for the job, not one per report.
    let flood = dir.appendingPathComponent("flood.txt")
    try? String(repeating: "\u{1b}]7501;state=blocked:app=e2e-agent\u{1b}\\\u{1b}]7501;state=working:app=flood-x\u{1b}\\", count: 300)
        .write(to: flood, atomically: true, encoding: .utf8)
    let floodLaunch = dir.appendingPathComponent("flood.sh")
    try? "#!/bin/bash\nset -m\nsleep 0.5\ntail -n +1 -f '\(flood.path)'\n".write(to: floodLaunch, atomically: true, encoding: .utf8)
    chmod(floodLaunch.path, 0o755)
    let ignored1 = c.ignoredProgramReports, lookups1 = c.argvLookups
    let fws = c.newWorkspace(select: false, program: floodLaunch.path)
    let fp = fws.panes[0]
    let allSeen = await waitFor(5) { c.ignoredProgramReports - ignored1 == 600 }
    let floodLog = c.actionLog.filter { $0.contains("pane=\(fp.id.prefix(8))") && $0.contains("ignored") }
    r.check("…600 reports from tail (two names, alternating): all refused, 1 log line, no state",
            allSeen && floodLog.count == 1 && c.argvLookups - lookups1 == 1 && fp.programApp == nil && c.notifier.postedCount == n3,
            "\(c.ignoredProgramReports - ignored1) refused, \(floodLog.count) lines, \(c.argvLookups - lookups1) lookups")
    c.closeWorkspace(fws)
    // A file named like the app it claims, shown by a program that takes it as an argument, and a
    // wrapper running a printer under its own name: `sort notes`, `xargs cat`.
    let notes = dir.appendingPathComponent("notes")
    try? "\u{1b}]7501;state=blocked:app=notes\u{1b}\\\u{1b}]7501;state=blocked:app=sort\u{1b}\\\u{1b}]7501;state=blocked:app=xargs\u{1b}\\\n"
        .write(to: notes, atomically: true, encoding: .utf8)
    let sortLaunch = dir.appendingPathComponent("sort.sh")
    try? "#!/bin/bash\nset -m\ncd '\(dir.path)'\nsleep 0.5\nsort notes\necho notes | xargs cat\nwhile :; do read -r x; done\n"
        .write(to: sortLaunch, atomically: true, encoding: .utf8)
    chmod(sortLaunch.path, 0o755)
    let ignoredSort = c.ignoredProgramReports
    let sws = c.newWorkspace(select: false, program: sortLaunch.path)
    let sp = sws.panes[0]
    _ = await waitFor(1.5 * ciSlow) { c.ignoredProgramReports - ignoredSort == 6 }
    await sleepMs(300)
    let sortLog = c.actionLog.filter { $0.contains("pane=\(sp.id.prefix(8))") }
    // A log line per foreground group lmux saw the reports under: one per job, or a single one when both
    // jobs' output is read in one go (a slow machine reads it once the second job has started). Never one per report.
    r.check("…`sort notes` and `echo notes | xargs cat` (app=notes, sort, xargs): refused too (one line per job)",
            sp.programApp == nil && sp.agent.state == .idle && c.notifier.postedCount == n3
            && c.ignoredProgramReports - ignoredSort == 6 && (1...4).contains(sortLog.filter { $0.contains("ignored") }.count),
            "\(c.ignoredProgramReports - ignoredSort) " + sortLog.joined(separator: " | "))

    // `quick-agent; cat notes`: the reporter quits, the next job prints its name. Never its words.
    let quick = script("quick-agent", """
    printf '\\033]7501;state=working:app=quick-agent\\033\\\\'
    sleep 0.3

    """)
    let quickSpoof = dir.appendingPathComponent("quick-spoof.txt")
    try? "\u{1b}]7501;state=blocked:kind=question:app=quick-agent\u{1b}\\".write(to: quickSpoof, atomically: true, encoding: .utf8)
    let quickLaunch = dir.appendingPathComponent("quick.sh")
    try? "#!/bin/bash\nset -m\n'\(quick.path)'\ncat '\(quickSpoof.path)'\nwhile :; do read -r x; done\n"
        .write(to: quickLaunch, atomically: true, encoding: .utf8)
    chmod(quickLaunch.path, 0o755)
    let qn = c.notifier.postedCount
    let qws = c.newWorkspace(select: false, program: quickLaunch.path)
    let qkp = qws.panes[0]
    let qGone = await waitFor(5) { qkp.programApp == nil && c.actionLog.contains { $0.contains("pane=\(qkp.id.prefix(8))") && $0.contains("gone") } }
    r.check("`quick-agent; cat file-naming-it`: the file's blocked is refused (cat isn't quick-agent, nor its last words)",
            qGone && !qkp.needsInput && qkp.agent.state == .idle && c.notifier.postedCount == qn,
            "\(qkp.display) " + c.actionLog.filter { $0.contains("pane=\(qkp.id.prefix(8))") }.joined(separator: " | "))
    c.closeWorkspace(qws)

    // `cat reports; next-agent`: cat's reports can be looked at after cat quit, while the shell has
    // forked next-agent but not exec'd it (the group is next-agent's already). next-agent still counts.
    let nextAgent = script("next-agent", """
    sleep 0.5
    printf '\\033]7501;state=blocked:kind=question:app=next-agent\\033\\\\'
    while :; do sleep 1; done

    """)
    let manyReports = dir.appendingPathComponent("many.txt")
    try? String(repeating: "\u{1b}]7501;state=working:app=next-agent\u{1b}\\", count: 200).write(to: manyReports, atomically: true, encoding: .utf8)
    let nextLaunch = dir.appendingPathComponent("next.sh")
    try? "#!/bin/bash\nset -m\ncat '\(manyReports.path)'\n'\(nextAgent.path)'\n".write(to: nextLaunch, atomically: true, encoding: .utf8)
    chmod(nextLaunch.path, 0o755)
    let lookupsNext = c.argvLookups
    let nws = c.newWorkspace(select: false, program: nextLaunch.path)
    let np = nws.panes[0]
    let nextCounted = await waitFor(15) { np.needsInput }
    r.check("`cat 200-reports-naming-next-agent; next-agent`: next-agent's own report still counts; a few lookups, not 200",
            nextCounted && np.agentName == "next-agent" && c.argvLookups - lookupsNext <= 4,
            "\(c.argvLookups - lookupsNext) lookups " + "\(np.display) " + c.actionLog.filter { $0.contains("pane=\(np.id.prefix(8))") }.joined(separator: " | "))
    c.closeWorkspace(nws)

    // A reporter's own child in its job (the same process group) speaks for it; `npm test` doesn't.
    let parent = script("parent-agent", """
    /bin/sh -c "printf '\\033]7501;state=blocked:kind=question:app=parent-agent\\033\\\\'"
    while :; do sleep 1; done

    """)
    let parentLaunch = dir.appendingPathComponent("parent.sh")
    try? "#!/bin/bash\nset -m\n'\(parent.path)'\n".write(to: parentLaunch, atomically: true, encoding: .utf8)
    chmod(parentLaunch.path, 0o755)
    let pws = c.newWorkspace(select: false, program: parentLaunch.path)
    let pp = pws.panes[0]
    let childSpoke = await waitFor(5) { pp.needsInput }
    r.check("a child process the reporter runs in its own job prints the report: it counts (the job is parent-agent)",
            childSpoke && pp.agentName == "parent-agent", "\(pp.display)")
    // (A job of its own holding the terminal, while the reporter lives, is another program: refused,
    // as the Ctrl-Z case above shows with the shell in front. Accepting it reopens `cat`.)
    c.closeWorkspace(pws)

    // ------------------------------------------------------------ lmux list --json
    r.section = "list"
    let cli = paths.binDir!.appendingPathComponent("lmux").path
    let cliEnv = ["LMUX_CONTROL_SOCKET": paths.controlSocket, "LMUX_PANE_ID": ""]
    let listed = await runProcess(cli, ["list", "--json"], env: cliEnv)
    let wss = (try? JSONSerialization.jsonObject(with: Data(listed.out.utf8))) as? [[String: Any]] ?? []
    let panes = wss.flatMap { $0["panes"] as? [[String: Any]] ?? [] }
    let keys: Set<String> = ["id", "title", "cwd", "state", "focused", "claude", "agent", "session", "workspaceTitle"]
    r.check("every pane: id, title, cwd, state, focused, claude (as before) + agent, session, workspaceTitle",
            !panes.isEmpty && panes.allSatisfy { Set($0.keys) == keys }, "\(panes.first?.keys.sorted() ?? [])")
    r.check("…workspaces keep id, title, selected, panes", wss.allSatisfy { Set($0.keys) == ["id", "title", "selected", "panes"] })
    func entry(_ p: Pane) -> [String: Any]? { panes.first { $0["id"] as? String == p.id } }
    r.check("…Claude's pane: agent claude, its session", entry(hp)?["agent"] as? String == "claude"
            && entry(hp)?["session"] as? String == "agents-1" && entry(hp)?["state"] as? String == "done", "\(entry(hp) ?? [:])")
    r.check("…a 7501 program's pane: agent e2e-agent, no session, needs input", entry(ep)?["agent"] as? String == "e2e-agent"
            && entry(ep)?["session"] as? String == "" && entry(ep)?["state"] as? String == "needs input", "\(entry(ep) ?? [:])")
    r.check("…a shell: no agent; workspaceTitle is its row's title", entry(op)?["agent"] as? String == ""
            && entry(op)?["workspaceTitle"] as? String == other.title)
    let plain = await runProcess(cli, ["list"], env: cliEnv)
    let line = plain.out.split(separator: "\n").first { $0.contains(ep.id) }.map(String.init) ?? ""
    r.check("plain list: the old columns, then the agent", line.hasPrefix("    pane \(ep.id)  ") && line.contains("  [needs input]  ")
            && line.hasSuffix("  (e2e-agent)"), line)

    // ------------------------------------------------------------ new-workspace --background
    r.section = "background"
    let selected0 = c.model.selectedID
    let focused0 = c.model.selected?.focusedPane?.id
    let bg = await runProcess(cli, ["new-workspace", "--background", "--cmd", "echo bg"], env: cliEnv)
    let bgPane = bg.out.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    let bgWS = c.pane(id: bgPane)?.workspace
    r.check("--background: the row appears, the selection and focus stay, it prints the new pane id",
            bg.status == 0 && bgWS != nil && c.model.selectedID == selected0 && c.model.selected?.focusedPane?.id == focused0
            && bg.out.hasPrefix("workspace \(bgWS?.id ?? "?") pane "), bg.out + bg.err)
    r.check("…its command runs there", await sinks.wait(bgPane, contains: "echo bg"), sinks.text(bgPane))
    let fg = await runProcess(cli, ["new-workspace"], env: cliEnv)
    r.check("…without it, unchanged: the new workspace is selected", fg.status == 0
            && fg.out.contains(c.model.selectedID ?? "?") && c.model.selectedID != selected0, fg.out)
    if let w = c.model.selected { c.closeWorkspace(w) }
    if let w = bgWS { c.closeWorkspace(w) }
    if let w = c.model.workspaces.first(where: { $0.id == selected0 }) { c.select(w) }
    let badFlag = await runProcess(cli, ["new-workspace", "--backgroud"], env: cliEnv)
    r.check("…a misspelled flag is still a usage error", badFlag.status == 2)

    // ------------------------------------------------------------ lmux wait
    r.section = "wait"
    @Sendable func wait(_ args: [String]) async -> (status: Int32, out: String, err: String) {
        await runProcess(cli, ["wait"] + args, env: cliEnv)
    }
    func waiting(_ n: Int) async -> Bool { await waitFor(3) { c.waits.count == n } }
    let ww = c.newWorkspace(select: false)
    let wp = ww.panes[0]
    _ = await sinks.waitReady(wp.id)
    let idle = await wait([wp.id])
    r.check("an idle pane, default (not running): answers at once", idle.status == 0 && idle.out == "idle\n", idle.out + idle.err)
    _ = sendHook(pane: wp.id, hook("UserPromptSubmit", session: "wait-1"))
    _ = await waitFor { wp.agent.state == .running }
    async let doneWait = wait([wp.id, "--until", "done", "--json"])
    async let settledWait = wait([wp.id])
    r.check("running: both waits block (in the app: two waits, nothing else)", await waiting(2))
    _ = sendHook(pane: wp.id, hook("Stop", session: "wait-1", #""last_assistant_message":"Reviewed.\nThree findings.""#))
    let (d, s) = await (doneWait, settledWait)
    let dj = (try? JSONSerialization.jsonObject(with: Data(d.out.utf8))) as? [String: Any] ?? [:]
    r.check("done: --json has state, pane, workspace, agent, session and the whole reply", d.status == 0
            && dj["state"] as? String == "done" && dj["pane"] as? String == wp.id && dj["workspace"] as? String == ww.id
            && dj["agent"] as? String == "claude" && dj["session"] as? String == "wait-1"
            && dj["reply"] as? String == "Reviewed.\nThree findings.", d.out + d.err)
    r.check("…the default wait too, plain: the state, then the reply", s.status == 0 && s.out == "done\nReviewed.\nThree findings.\n", s.out)
    r.check("…and the app keeps no wait after answering", c.waits.isEmpty && c.model.onAgentStateChange == nil)

    // After `lmux send`, the turn before it doesn't count.
    let sent = await runProcess(cli, ["send", "--pane", wp.id, #"next\n"#], env: cliEnv)
    async let afterSend = wait([wp.id, "--until", "done"])
    let blocks = await waiting(1)
    r.check("lmux send, then wait --until done on a pane still showing the last done: waits for the next",
            sent.status == 0 && blocks)
    _ = sendHook(pane: wp.id, hook("UserPromptSubmit", session: "wait-1"))
    _ = sendHook(pane: wp.id, hook("Stop", session: "wait-1", #""last_assistant_message":"Second.""#))
    let as1 = await afterSend
    r.check("…answered by that next turn's done", as1.status == 0 && as1.out == "done\nSecond.\n", as1.out + as1.err)

    // Text without Return can't start a turn: it doesn't make the done stale.
    let noop = await runProcess(cli, ["send", "--pane", wp.id, "partial"], env: cliEnv)
    let afterNoop = await wait([wp.id, "--until", "done", "--timeout", "0"])
    r.check("lmux send without a Return, then wait --until done (--timeout 0): the done still counts",
            noop.status == 0 && afterNoop.status == 0 && afterNoop.out.hasPrefix("done\n"), "\(afterNoop.status) " + afterNoop.out + afterNoop.err)

    // needs-you, idle, any.
    _ = sendHook(pane: wp.id, hook("UserPromptSubmit", session: "wait-1"))
    _ = await waitFor { wp.agent.state == .running }
    async let needs = wait([wp.id, "--until", "needs-you"])
    async let needsJ = wait([wp.id, "--until", "needs-you", "--json"])
    _ = await waiting(2)
    _ = sendHook(pane: wp.id, hook("PreToolUse", session: "wait-1", #""tool_name":"Bash","tool_input":{"command":"ls"}"#))
    await sleepMs(200)
    r.check("--until needs-you: a tool call doesn't end it", c.waits.count == 2)
    _ = sendHook(pane: wp.id, hook("PermissionRequest", session: "wait-1", #""tool_name":"Bash""#))
    let nr = await needs
    r.check("…the permission dialog does", nr.status == 0 && nr.out == "needs input\nPermission: Bash\n", nr.out + nr.err)
    let njr = await needsJ
    let nj = (try? JSONSerialization.jsonObject(with: Data(njr.out.utf8))) as? [String: Any] ?? [:]
    r.check("…its --json reply is this turn's: none yet (not the turn before's \"Second.\")",
            nj["state"] as? String == "needs input" && nj["reply"] as? String == "", "\(nj)")
    // A codex reporting its own state: its done can come before the Stop hook with the text.
    wp.codexReport = .done
    wp.codexTurnReply = nil
    let staleCodex = c.reply(wp)
    wp.codexTurnReply = "This turn."
    let freshCodex = c.reply(wp)
    wp.codexReport = nil
    wp.codexTurnReply = nil
    r.check("…and a codex's: its turn's reply, nil until its Stop hook (never Claude's older lastReply)",
            staleCodex == nil && freshCodex == "This turn.", "\(staleCodex ?? "nil") \(freshCodex ?? "nil")")
    async let idleWait = wait([wp.id, "--until", "idle"])
    async let anyWait = wait([wp.id, "--until", "any", "--json"])
    _ = await waiting(2)
    wp.agent.userInterrupted()
    let (iw, aw) = await (idleWait, anyWait)
    let aj = (try? JSONSerialization.jsonObject(with: Data(aw.out.utf8))) as? [String: Any] ?? [:]
    r.check("--until idle and --until any: the interrupt (needs input -> idle) ends both",
            iw.status == 0 && iw.out == "idle\n" && aw.status == 0 && aj["state"] as? String == "idle", iw.out + aw.out)

    // --until any: a change undone within one runloop turn (before the coalesced look) still counts.
    let aws = c.newWorkspace(select: false, program: launch.path)
    let ap = aws.panes[0]
    _ = await waitFor(15) { c.foregroundIs(ap, app: "my-agent") }
    c.programStatus(ap, report(.blocked, "question"))
    async let anyBack = wait([ap.id, "--until", "any", "--json"])
    _ = await waiting(1)
    c.programStatus(ap, report(.working))
    c.programStatus(ap, report(.blocked, "question"))  // (same turn: needs input -> running -> needs input)
    let ab = await anyBack
    let abj = (try? JSONSerialization.jsonObject(with: Data(ab.out.utf8))) as? [String: Any] ?? [:]
    r.check("--until any: needs input -> running -> needs input in one runloop turn ends it",
            ab.status == 0 && abj["state"] as? String == "needs input", "\(ab.status) " + ab.out + ab.err)

    // An answer sent with `lmux send` (Return), then the same ask again with nothing in between:
    // a new ask, and `wait --until needs-you` after the send sees it.
    let answer = await runProcess(cli, ["send", "--pane", ap.id, #"y\n"#], env: cliEnv)
    async let again = wait([ap.id, "--until", "needs-you", "--timeout", "10"])
    let heldAgain = await waiting(1)
    let nAgain = c.notifier.postedCount
    c.programStatus(ap, report(.blocked, "question"))
    let ag = await again
    r.check("lmux send \"y\\n\" to a waiting program, then wait --until needs-you: the same ask again ends it (a new ask, alerted)",
            answer.status == 0 && heldAgain && ag.status == 0 && ag.out.hasPrefix("needs input")
            && c.notifier.postedCount == nAgain + 1, "\(ag.status) " + ag.out + ag.err)

    // A raw client that half-closes after its request (`nc -N`): EOF is a hang-up, the wait ends unanswered.
    if let hfd = ControlServer.connect(paths.controlSocket) {
        let req = Data(#"{"cmd":"wait","target":"\#(ap.id)","until":"done"}"#.utf8 + [0x0A])
        _ = req.withUnsafeBytes { Darwin.write(hfd, $0.baseAddress, $0.count) }
        let held = await waiting(1)
        shutdown(hfd, SHUT_WR)
        let dropped = await waiting(0)
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(hfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var b = [UInt8](repeating: 0, count: 64)
        let got = b.withUnsafeMutableBytes { Darwin.read(hfd, $0.baseAddress, $0.count) }
        close(hfd)
        r.check("a raw client that half-closes after its request: the wait ends, unanswered (as documented)",
                held && dropped && got == 0, "held \(held) dropped \(dropped) read \(got)")
    } else {
        r.check("a raw client connects", false)
    }
    c.closeWorkspace(aws)

    // Exit 2 only when lmux says gone (lmux quitting too); a connection it refuses is exit 3.
    let altPath = paths.stateDir.appendingPathComponent("alt.sock").path
    let alt = ControlServer(path: altPath) { _ in ["ok": true] }
    alt.handleWait = { _, _ in {} }  // (never answers on its own)
    try? alt.start()
    let altEnv = ["LMUX_CONTROL_SOCKET": altPath, "LMUX_PANE_ID": ""]
    // 32 clients: lmux takes no more. One at a time, accepted in between (the listen backlog is 16).
    var hogs: [Int32] = []
    for _ in 0..<32 { if let h = ControlServer.connect(altPath) { hogs.append(h) }; await sleepMs(20) }
    await sleepMs(300)
    let refused = await runProcess(cli, ["wait", "x", "--timeout", "5"], env: altEnv)
    r.check("a connection lmux refuses (32 clients already): exit 3 \"no response\", not 2 \"gone\"",
            hogs.count == 32 && refused.status == 3 && refused.err.contains("no response"), "\(refused.status) " + refused.err)
    for h in hogs { close(h) }
    await sleepMs(300)
    let quitter = Task.detached { await runProcess(cli, ["wait", "x", "--timeout", "10"], env: altEnv) }
    await sleepMs(700)
    alt.stop()
    let qr = await quitter.value
    r.check("lmux quitting while a wait is open: it answers gone, exit 2", qr.status == 2 && qr.err.contains("gone"),
            "\(qr.status) " + qr.err)

    // A workspace id: its row's state.
    let gws = c.newWorkspace(select: false, program: launch.path)
    let gp = gws.panes[0]
    _ = await waitFor(15) { c.foregroundIs(gp, app: "my-agent") }
    c.programStatus(gp, report(.working))
    async let wsWait = wait([gws.id, "--json"])
    _ = await waiting(1)
    c.programStatus(gp, report(.done))
    let wsr = await wsWait
    let wj = (try? JSONSerialization.jsonObject(with: Data(wsr.out.utf8))) as? [String: Any] ?? [:]
    r.check("a workspace id: ends with its row (an OSC 7501 agent's done), names the pane and agent", wsr.status == 0
            && wj["state"] as? String == "done" && wj["pane"] as? String == gp.id && wj["agent"] as? String == "my-agent", wsr.out + wsr.err)

    // Timeout, target gone, bad input.
    c.programStatus(gp, report(.working))
    let t0 = Date()
    let timedOut = await wait([gp.id, "--timeout", "0.5"])
    r.check("--timeout: exit 1 after it", timedOut.status == 1 && Date().timeIntervalSince(t0) < 3 && timedOut.err.contains("timed out"),
            "\(timedOut.status) " + timedOut.err)
    r.check("…and the app forgot that wait when the CLI hung up", await waiting(0))
    async let goneWait = wait([gp.id])
    async let goneWsWait = wait([gws.id])
    _ = await waiting(2)
    c.closeWorkspace(gws)
    let (g1, g2) = await (goneWait, goneWsWait)
    r.check("target gone (its workspace closed): exit 2, for the pane and the workspace",
            g1.status == 2 && g2.status == 2 && g1.err.contains("gone"), "\(g1.status) \(g2.status) " + g1.err)
    let unknown = await wait(["no-such-pane"])
    r.check("an id that never was: exit 2", unknown.status == 2, "\(unknown.status) " + unknown.err)
    let bad = await wait([wp.id, "--until", "soon"])
    let none = await wait([])
    let down = await runProcess(cli, ["wait", wp.id], env: ["LMUX_CONTROL_SOCKET": paths.stateDir.path + "/nothing.sock"])
    r.check("bad --until, no id, lmux not running: exit 3 with a message", bad.status == 3 && bad.err.contains("--until")
            && none.status == 3 && down.status == 3 && down.err.contains("not running"), bad.err + none.err + down.err)

    // Waiting costs the app nothing: no timer, no poll, a socket nobody reads from.
    r.section = "wait cost"
    let quiet = c.newWorkspace(select: false)
    let qp = quiet.panes[0]
    _ = await sinks.waitReady(qp.id)
    _ = sendHook(pane: qp.id, hook("UserPromptSubmit", session: "wait-cost"))
    _ = await waitFor { qp.agent.state == .running }
    let base = await idleCost(4)
    // The 8 must all be waiting through the 4 s measured below: their timeout covers starting 8
    // processes too, which takes a few seconds on a slow CI runner (ciSlow), not on a Mac.
    let timeout = String(Int(5 * ciSlow))
    let timed = Task.detached { await runProcess("/usr/bin/time", ["-p", cli, "wait", qp.id, "--timeout", timeout], env: cliEnv) }
    var others: [Task<(status: Int32, out: String, err: String), Never>] = []
    for _ in 0..<7 { others.append(Task.detached { await runProcess(cli, ["wait", qp.id, "--timeout", timeout], env: cliEnv) }) }
    _ = await waitFor(3 * ciSlow) { c.waits.count == 8 }
    let loaded = await idleCost(4)
    r.check("8 CLIs waiting: the app's idle CPU doesn't move (\(String(format: "%.2f", base.cpu))% -> \(String(format: "%.2f", loaded.cpu))%)",
            c.waits.count == 8 && loaded.cpu - base.cpu < 0.3, "waits \(c.waits.count)")
    let tr = await timed.value
    for t in others { _ = await t.value }
    let cpu = tr.err.split(separator: "\n").filter { $0.hasPrefix("user") || $0.hasPrefix("sys") }
        .compactMap { $0.split(separator: " ").last.flatMap { Double($0) } }.reduce(0, +)
    r.check("…and a waiting CLI itself: blocked in poll, ~no CPU over its \(timeout) s (\(cpu) s)", tr.status == 1 && cpu < 0.1, tr.err)
    r.check("…all gone from the app after their timeouts", await waiting(0))

    print("agents: \(r.passed) passed, \(r.failed) failed")
    return r.failed == 0 ? 0 : 1
}
