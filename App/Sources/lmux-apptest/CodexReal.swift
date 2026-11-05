import AppKit
import LmuxHooks
@testable import LmuxUI

// The REAL Codex CLI in lmux panes (`--codex-real`, then `--codex-real-restore` on the same state
// dir), against a local mock of the Responses API (App/scripts/codexreal.sh): no login, no
// credential, a temp CODEX_HOME. Codex's own TUI, approvals, hooks trust, rollout, thread titles
// and `codex resume`; lmux's hooks installer, sidebar states, notifications, History and restore.
// The mock asks for one command when the prompt says RUNTOOL (ESCALATE: outside the sandbox, so
// Codex asks first) and streams a slow reply for SLOWTURN.
//
// LMUX_QA_CODEX_MODE (codexreal.sh runs all three):
//   daemon    Codex as installed: one shared app-server for every codex, with the environment of
//             the first (its hooks name that pane): status from each pane's OSC 7501, sessions
//             bound by the pane whose codex started a turn at that moment.
//   nodaemon  `features.daemon_auto_start = false` (the user's choice): each codex its own server.
//   outside   a shared server started outside lmux was already running: no hook reaches lmux,
//             status still comes from each pane's OSC 7501.

@MainActor
private func screen(_ p: Pane) -> String { p.surface.readText(viewportOnly: true) }

/// The command line of the pane's foreground program.
@MainActor
private func argv(_ p: Pane) -> String {
    ClaudeProcess.representative(ofGroup: p.surface.foregroundPID).flatMap(ClaudeProcess.commandLine)?.argv.joined(separator: " ") ?? ""
}

/// Everything the pane printed (scrollback too).
@MainActor
private func everything(_ p: Pane) -> String { p.surface.readText(viewportOnly: false) }

@MainActor
private func lastLines(_ p: Pane, _ n: Int = 8) -> String {
    screen(p).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        .suffix(n).joined(separator: " | ")
}

/// Type a prompt into Codex's composer and submit it (a burst of text is a paste for a moment).
@MainActor
private func submitCodex(_ p: Pane, _ text: String) async {
    p.surface.sendText(text)
    await sleepMs(600)
    p.surface.sendText("\r")
}

/// Answer Codex's "trust these hooks" screen with "Trust all and continue" when it shows up
/// (once `ready`, or after a few seconds).
@MainActor
private func passTrustScreen(_ p: Pane, ready: () -> Bool, until done: () -> Bool, timeout: Double = 40) async -> Bool {
    var trusted = false
    let start = Date(), end = start.addingTimeInterval(timeout)
    while Date() < end, !done() {
        if !trusted, ready() || Date().timeIntervalSince(start) > 8, screen(p).contains("Trust all and continue") {
            trusted = true
            await sleepMs(400)
            p.surface.sendText("2")
            await sleepMs(300)
            p.surface.sendText("\r")
        }
        await sleepMs(200)
    }
    return trusted
}


/// The session's rollout has this prompt (a pane bound to a session is bound to its own).
@MainActor
private func ownSession(_ p: Pane, _ prompt: String) -> Bool {
    guard let t = p.transcriptPath, let text = try? String(contentsOfFile: t, encoding: .utf8) else { return false }
    return text.contains(prompt)
}

@MainActor
private func quitCodex(_ c: LmuxController, _ p: Pane) async {
    p.surface.sendKey(keyCode: 8, codepoint: 0x63, control: true)
    await sleepMs(400)
    p.surface.sendKey(keyCode: 8, codepoint: 0x63, control: true)
    _ = await waitFor(10) { c.runningProcess(p) == nil }
}

@MainActor
func runCodexReal() async -> Int32 {
    let r = Report()
    guard let work = env["LMUX_QA_CODEX_WORK"] else { print("FAIL  [codex real] LMUX_QA_CODEX_WORK not set"); return 1 }
    let mode = env["LMUX_QA_CODEX_MODE"] ?? "daemon"
    let hooks = mode != "outside"       // hooks reach lmux at all
    let ownEnv = mode == "nodaemon"     // each codex's hooks carry its own pane
    let fm = FileManager.default
    let state = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!)
    let hooksPath = CodexHooksSetup.hooksPath()
    r.section = "codex real (\(mode)): setup"
    r.check("CODEX_HOME is the run's temp dir", env["CODEX_HOME"].map { hooksPath.hasPrefix($0) } == true
            && !hooksPath.hasPrefix(NSHomeDirectory() + "/.codex"), hooksPath)
    let theirs = (try? Data(contentsOf: URL(fileURLWithPath: hooksPath))) ?? Data()
    let config0 = (try? Data(contentsOf: URL(fileURLWithPath: CodexHookInstaller.configPath()))) ?? Data()
    let c = makeController()
    c.codexHintDelay = 1.5
    guard let hookBin = paths.hookBinary else { r.check("lmux-hook found", false); return finish(r, c) }

    // ------------------------------------------------------------ install (what the sheet's Install does)
    r.section = "codex real (\(mode)): install"
    do {
        let plan = try CodexHooksSetup.planInstall(hooksPath: hooksPath, hookBinary: hookBin)
        r.check("the sheet's diff only adds lines", !HooksSetup.diff(plan).split(separator: "\n").contains {
            $0.hasPrefix("-") && !$0.hasPrefix("---") })
        r.check("Install applies", c.applyHooksChange(plan, install: true, agent: .codex) == nil)
    } catch { r.check("plan install", false, "\(error)") }
    r.check("installed into $CODEX_HOME/hooks.json, not trusted yet; config.toml untouched", CodexHooksSetup.isInstalled()
            && { if case .needsReview = CodexHooksSetup.trust() { return true }; return false }()
            && (try? Data(contentsOf: URL(fileURLWithPath: CodexHookInstaller.configPath()))) ?? Data() == config0,
            "\(CodexHooksSetup.trust())")

    // ------------------------------------------------------------ a real codex asks for approval
    r.section = "codex real (\(mode)): approval"
    let ws = c.newWorkspace(cwd: work, select: false)
    ws.customTitle = "codex real"
    let p = ws.panes[0]
    r.check("(setup) shell prompt", await waitFor(15) { screen(p).contains("%") }, lastLines(p))
    let n0 = c.notifier.postedCount
    let promptP = "RUNTOOL ESCALATE create the marker"
    p.surface.sendText("codex -a on-request -s read-only '\(promptP)'\n")
    var hintSeen = false
    let trusted = await passTrustScreen(p, ready: {
        if p.view.overlay.toast?.text.string.contains("Trust all and continue") == true { hintSeen = true }
        return hintSeen
    }, until: { p.needsInput })
    r.check("Codex shows its hooks trust screen; “Trust all and continue”, lmux's hint meanwhile", trusted && hintSeen, lastLines(p))
    r.check("the approval prompt makes the row “needs you” (Codex's own report, OSC 7501)",
            await waitFor(20) { p.needsInput } && p.codexReport == .blocked && screen(p).contains("Would you like to run"),
            "\(p.display) | \(lastLines(p))")
    let askText = hooks ? "Needs input · Permission: Bash" : "Needs input · Permission"
    await sleepMs(1500)
    r.check("…one notification for it: “\(askText)”", c.notifier.postedCount == n0 + 1
            && c.notifier.posted.last?.body == askText, "\(c.notifier.posted.suffix(2).map(\.body))")
    if hooks {
        r.check("the session is this pane's (bound \(ownEnv ? "by its own hooks" : "by its turn starting then"))",
                await waitFor(5) { p.claudeSessionID != nil && p.agentKind == .codex } && ownSession(p, promptP),
                "\(p.claudeSessionID ?? "nil") log=\(c.actionLog.suffix(3))")
        r.check("…and lmux reads the hooks as trusted", CodexHooksSetup.trust() == .trusted, "\(CodexHooksSetup.trust())")
    } else {
        r.check("no hook reaches lmux (the server started outside it has no pane): no session", p.claudeSessionID == nil)
    }
    p.surface.sendText("y")
    let doneText = hooks ? "Done · # Result" : "Done"
    r.check("approved: running, then done", await waitFor(20) { p.display == .done(hooks ? "# Result" : nil) }, "\(p.display) | \(lastLines(p))")
    r.check("…the command really ran", fm.fileExists(atPath: work + "/made-by-codex.txt"))
    await sleepMs(800)
    r.check("…exactly one more notification: “\(doneText)”", c.notifier.postedCount == n0 + 2
            && c.notifier.posted.last?.body == doneText, "\(c.notifier.posted.suffix(3).map(\.body))")
    let sid = p.claudeSessionID ?? ""
    if hooks {
        r.check("resume captured from the codex argv", p.resumeCommand == "codex resume -a on-request -s read-only \(sid)",
                p.resumeCommand ?? "nil")
        r.check("the title is Codex's thread_name (session_index.jsonl)",
                await waitFor(15) { p.titleState.title == "Create the marker file" }, p.titleState.title ?? "nil")
    }

    // ------------------------------------------------------------ Esc mid-turn
    r.section = "codex real (\(mode)): interrupt"
    let n1 = c.notifier.postedCount
    await submitCodex(p, "SLOWTURN keep talking")
    r.check("(setup) a new prompt runs", await waitFor(10) { p.agent.state == .running }, "\(p.agent.state)")
    await sleepMs(1500)
    p.surface.sendKey(keyCode: 53, codepoint: 0x1b)
    r.check("Esc mid-turn → idle", await waitFor(10) { p.agent.state == .idle }, "\(p.agent.state) | \(lastLines(p))")
    await sleepMs(1500)
    r.check("…no notification, no ring", c.notifier.postedCount == n1 && !p.needsInput, "\(c.notifier.posted.suffix(2).map(\.body))")

    // ------------------------------------------------------------ a second codex while the first runs
    r.section = "codex real (\(mode)): second pane"
    let qws = c.newWorkspace(cwd: work, select: false)
    let q = qws.panes[0]
    _ = await waitFor(15) { screen(q).contains("%") }
    let n2 = c.notifier.postedCount
    let promptQ = "RUNTOOL in the sandbox"
    q.surface.sendText("codex -a on-request -s workspace-write '\(promptQ)'\n")
    r.check("its own row: done, one notification; the first pane doesn't move",
            await waitFor(25) { q.agent.state == .done } && c.notifier.postedCount == n2 + 1
            && p.agent.state == .idle && p.claudeSessionID == (hooks ? sid : nil),
            "\(q.display) \(c.notifier.posted.suffix(2).map(\.body)) first: \(p.agent.state) \(p.claudeSessionID ?? "nil")")
    if hooks {
        r.check("…its session is its own", await waitFor(5) { q.claudeSessionID != nil } && ownSession(q, promptQ),
                q.claudeSessionID ?? "nil")
    }

    // ------------------------------------------------------------ two prompts at the same moment
    r.section = "codex real (\(mode)): at once"
    let w1 = c.newWorkspace(cwd: work, select: false), w2 = c.newWorkspace(cwd: work, select: false)
    let a1 = w1.panes[0], a2 = w2.panes[0]
    _ = await waitFor(15) { screen(a1).contains("%") && screen(a2).contains("%") }
    let n3 = c.notifier.postedCount
    a1.surface.sendText("codex 'say one'\n")
    a2.surface.sendText("codex 'say two'\n")
    r.check("both rows done, one notification each", await waitFor(25) { a1.agent.state == .done && a2.agent.state == .done }
            && c.notifier.postedCount == n3 + 2, "\(a1.display) \(a2.display) posted \(c.notifier.postedCount - n3)")
    await sleepMs(Int(LmuxController.codexBindWindow * 1000) + 500)
    let bound = [(a1, "say one"), (a2, "say two")].filter { $0.0.claudeSessionID != nil }
    r.check(ownEnv ? "each bound to its own session (its own hooks)"
                   : "a session is bound only where it's certain: never to the other pane (\(bound.count) of 2 bound)",
            bound.allSatisfy { ownSession($0.0, $0.1) } && (!ownEnv || bound.count == 2) && (hooks || bound.isEmpty),
            bound.map { "\($0.0.claudeSessionID ?? "-") own=\(ownSession($0.0, $0.1))" }.joined(separator: ", "))
    for a in [a1, a2] { await quitCodex(c, a) }
    c.closeWorkspace(w1); c.closeWorkspace(w2)

    // ------------------------------------------------------------ the first codex leaves, the others go on
    r.section = "codex real (\(mode)): first leaves"
    await quitCodex(c, p)
    r.check("the first codex quits: its row is a shell again, by Codex's own `clear` (sent without app=)",
            await waitFor(5) { p.agent.state == .idle && p.codexReport == nil && !p.runsCodex }
            && c.actionLog.contains { $0.hasPrefix("codex report: pane=\(p.id.prefix(8)) clear") }
            && !c.actionLog.contains("codex gone without a clear: pane=\(p.id.prefix(8))"),
            "\(p.agent.state) \(String(describing: p.codexReport)) log=\(c.actionLog.suffix(6))")
    c.closeWorkspace(ws)
    let n4 = c.notifier.postedCount
    await submitCodex(q, "say more")
    r.check("the second goes on reporting (done, one notification) after the first's pane closed",
            await waitFor(20) { q.display == .done(hooks ? "# Result" : nil) && c.notifier.postedCount == n4 + 1 },
            "\(q.display) posted \(c.notifier.postedCount - n4)")
    let zws = c.newWorkspace(cwd: work, select: false)
    let z = zws.panes[0]
    _ = await waitFor(15) { screen(z).contains("%") }
    z.surface.sendText("codex 'say late'\n")
    let zDone = await waitFor(25) { z.agent.state == .done }
    let zBound = await waitFor(5) { z.claudeSessionID != nil } && ownSession(z, "say late")
    r.check("a new codex after that: its row works\(hooks ? ", its session bound to it" : "")", zDone && (!hooks || zBound),
            "\(z.display) \(z.claudeSessionID ?? "nil") log=\(c.actionLog.suffix(14))")
    await quitCodex(c, z)
    c.closeWorkspace(zws)

    // ------------------------------------------------------------ History (⇧⌘H)
    r.section = "codex real (\(mode)): history"
    let qsid = q.claudeSessionID
    await quitCodex(c, q)
    c.closeWorkspace(qws)
    await c.history.refresh()
    let rows = c.history.sessions.filter { $0.agent == .codex }
    r.check("History indexes the real sessions as Codex, titled from thread_name (from the rollouts: any mode)",
            rows.count >= 5 && rows.contains { $0.title == "Create the marker file" }, "\(rows.map { ($0.id, $0.title ?? "-") })")
    let pick = qsid ?? rows.first { $0.title != nil }?.id ?? ""
    var resumed: Workspace?
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        c.history.resume(pick) { w in resumed = w; k.resume() }
    }
    guard let rws = resumed, let rp = rws.panes.first else { r.check("Resume opens a workspace", false); return finish(r, c) }
    r.check("Resume: codex resume <id>, the real codex reopens it, the pane is that session before any hook",
            await waitFor(25) { everything(rp).contains("You ran") || (c.runningProcess(rp) != nil && everything(rp).contains("›")) }
            && rp.claudeSessionID == pick && rp.agentKind == .codex, lastLines(rp))
    let n5 = c.notifier.postedCount
    await submitCodex(rp, "say it once more")
    r.check("…a prompt there: its row goes done (one notification), still that session",
            await waitFor(25) { rp.agent.state == .done } && c.notifier.postedCount == n5 + 1 && rp.claudeSessionID == pick,
            "\(rp.display) \(rp.claudeSessionID ?? "nil") log=\(c.actionLog.suffix(14))")

    // ------------------------------------------------------------ for the restore run
    c.saveNow()
    let exp: [String: Any] = ["pane": rp.id, "sid": pick, "resume": rp.resumeCommand ?? "", "theirs": theirs.base64EncodedString()]
    try? JSONSerialization.data(withJSONObject: exp).write(to: state.appendingPathComponent("codex-real-expect.json"))
    return finish(r, c)
}

@MainActor
func runCodexRealRestore() async -> Int32 {
    let r = Report()
    let mode = env["LMUX_QA_CODEX_MODE"] ?? "daemon"
    r.section = "codex real (\(mode)): restore"
    let state = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!)
    guard let d = try? Data(contentsOf: state.appendingPathComponent("codex-real-expect.json")),
          let exp = try? JSONSerialization.jsonObject(with: d) as? [String: String],
          let id = exp["pane"], let sid = exp["sid"], let resume = exp["resume"], !resume.isEmpty,
          let theirs = exp["theirs"].flatMap({ Data(base64Encoded: $0) }) else {
        print("FAIL  [codex real: restore] no expectations from the --codex-real run")
        return 1
    }
    let c = makeController()
    guard let p = c.pane(id: id) else { r.check("the Codex pane comes back", false); return finish(r, c) }
    r.check("the Codex pane comes back as that session", p.agentKind == .codex && p.claudeSessionID == sid)
    r.check("…its shell types `\(resume)` and the real codex resumes it",
            await waitFor(30) { argv(p).hasSuffix(" " + resume.split(separator: " ").dropFirst().joined(separator: " ")) },
            "argv [\(argv(p))] | \(lastLines(p, 12))")
    let n0 = c.notifier.postedCount
    await sleepMs(1500)
    await submitCodex(p, "say hi after the relaunch")
    // (It comes back done, as it was left: the new turn's done is the notification.)
    r.check("…a prompt after the relaunch: done (one notification), same session",
            await waitFor(25) { p.agent.state == .done && c.notifier.postedCount > n0 } && p.claudeSessionID == sid
            && c.notifier.postedCount == n0 + 1,
            "\(p.display) \(p.claudeSessionID ?? "nil") | \(lastLines(p))")
    // Uninstall (what the sheet's Uninstall does): hooks.json is the user's again, byte for byte.
    r.section = "codex real (\(mode)): uninstall"
    do {
        let plan = try CodexHooksSetup.planUninstall(hooksPath: CodexHooksSetup.hooksPath())
        r.check("Uninstall applies", c.applyHooksChange(plan, install: false, agent: .codex) == nil)
    } catch { r.check("plan uninstall", false, "\(error)") }
    let now = (try? Data(contentsOf: URL(fileURLWithPath: CodexHooksSetup.hooksPath()))) ?? Data()
    r.check("hooks.json restored byte for byte (after a real Codex trusted and ran them)", now == theirs,
            String(decoding: now, as: UTF8.self))
    return finish(r, c)
}
