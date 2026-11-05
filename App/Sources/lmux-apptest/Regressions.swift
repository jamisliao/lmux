import AppKit
import LmuxHooks
@testable import LmuxUI

// `lmux-apptest --regressions`: bugs a QA pass found where features meet, each checked the way a
// user hits it. Panes run the isolated zsh with `$LMUX_QA_FAKEBIN` first on its PATH (apptest.sh),
// where this writes a fake `claude` and `codex` (they log their arguments and stay in the
// foreground; no hooks), so a resumed session never starts a real agent.
//
//   restore: an agent session lmux resumes is kept while the shell prints its prompt first, with
//            no hook ever arriving (an import from cmux, Codex hooks not trusted), and saved again.
//            The same for a cmux import, whose Undo then closes every untouched workspace.
//   zoom:    ⌘⌥←/→ (goto_split left/right) while zoomed moves to that pane; a pane hidden behind
//            the zoom still gets the unattended reminder.
//   undo:    Undo send finds a prompt that carried an image.
//   clear:   Clear Status also drops what was already on its way (Codex's pending "needs input",
//            a coalesced `lmux notify`); typing into Codex during its grace second cancels it.
//   drag:    a selection change mid-drag doesn't shift where the dragged rows land.
//   hint:    a resumed Codex with untrusted hooks gets the hint; CLAUDE_CONFIG_DIR hint with no hooks anywhere doesn't claim they're set up.

@MainActor
func runRegressions() async -> Int32 {
    let r = Report()
    guard let fakebin = env["LMUX_QA_FAKEBIN"] else { print("FAIL  [regressions] LMUX_QA_FAKEBIN not set"); return 1 }
    let log = URL(fileURLWithPath: fakebin).appendingPathComponent("agents.log").path
    let failSID = "8d3fab60-4e5c-4f9d-a0c1-3c4d5e6f7081"
    for name in ["claude", "codex"] {
        let f = URL(fileURLWithPath: fakebin).appendingPathComponent(name)
        // A resume of the "failing" session exits right away (a session the agent can't open).
        try? "#!/bin/sh\necho \"\(name) $*\" >> '\(log)'\ncase \"$*\" in *\(failSID)*) exit 1;; esac\nexec sleep 600\n"
            .write(to: f, atomically: true, encoding: .utf8)
        chmod(f.path, 0o755)
    }

    // ------------------------------------------------------------- restore without hooks
    // A saved layout with a Claude and a Codex session, as an import or the last quit wrote it.
    let claudeSID = "4f6b2c1e-8a0d-4c3b-9e51-2d7a6f0b9c11", codexSID = "019a1b2c-3d4e-7f50-8a61-b2c3d4e5f607"
    let cp = "A1B2C3D4-0000-4000-8000-00000000C1A0", xp = "A1B2C3D4-0000-4000-8000-00000000C0D3"
    let fp = "A1B2C3D4-0000-4000-8000-00000000FA11"
    let layout: [String: Any] = [
        "version": 1, "selected": "W1", "sidebarVisible": true, "sidebarWidth": 240,
        "workspaces": [
            ["id": "W1", "accent": 0, "root": ["pane": ["id": cp, "cwd": "/tmp", "claudeSession": claudeSID,
                                                                "resumeCommand": "claude --resume \(claudeSID)"]]],
            ["id": "W2", "accent": 1, "root": ["pane": ["id": xp, "cwd": "/tmp", "claudeSession": codexSID, "agent": "codex",
                                                                "resumeCommand": "codex resume \(codexSID)"]]],
            // Its last turn done: comes back ✓, then its resume fails.
            ["id": "W3", "accent": 2, "root": ["pane": ["id": fp, "cwd": "/tmp", "claudeSession": failSID,
                                                                "resumeCommand": "claude --resume \(failSID)",
                                                                "doneAt": Date().timeIntervalSince1970 - 120, "alertDetail": "all set"]]],
        ],
    ]
    let layoutURL = paths.stateDir.appendingPathComponent("layout.json")
    try? JSONSerialization.data(withJSONObject: layout).write(to: layoutURL)
    // Codex's hooks installed but never trusted ("Continue without trusting").
    let codexHooks = CodexHooksSetup.hooksPath()
    try? FileManager.default.createDirectory(atPath: (codexHooks as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let plan = try? CodexHooksSetup.planInstall(hooksPath: codexHooks, hookBinary: "/usr/bin/true") { try? HooksSetup.apply(plan) }
    let untrusted = { if case .needsReview = CodexHooksSetup.trust() { return true }; return false }()
    let c = makeController()
    // Shorter than the app's 8 s, set before the restored shells' first titles reach the main queue;
    // long enough that the resumed codex is the pane's foreground process by then.
    c.codexHintDelay = 2
    c.assumeAppActive = true
    let w = c.window!
    r.section = "restore without hooks"
    let pc = c.pane(id: cp), px = c.pane(id: xp)
    r.check("(setup) both sessions restored", pc?.claudeSessionID == claudeSID && px?.claudeSessionID == codexSID)
    let pf = c.pane(id: fp)
    r.check("a pane whose last turn was done comes back ✓ (its reply line) as its resume starts",
            pf?.display == .done("all set") && pf?.claudeSessionID == failSID, "\(String(describing: pf?.display))")
    let started = await waitFor(10) {
        let s = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        return s.contains("claude --resume \(claudeSID)") && s.contains("codex resume \(codexSID)")
    }
    // The shell's prompt and then the agent's command line both retitle the pane before (and as) it runs.
    _ = await waitFor(5) { [pc, px].allSatisfy { $0.map { c.runningProcess($0) != nil } ?? false } }
    await sleepMs(300)
    r.check("(setup) the shells typed both resumes", started, (try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
    r.check("the restored Claude pane keeps its session through the shell's prompt (no hook ever came)",
            pc?.claudeSessionID == claudeSID && pc?.runsClaude == true, "\(pc?.claudeSessionID ?? "nil") title \(pc?.title ?? "")")
    r.check("…and the Codex pane too", px?.claudeSessionID == codexSID && px?.runsCodex == true, "\(px?.claudeSessionID ?? "nil")")
    let hinted = await waitFor(8) { px?.view.overlay.toast != nil }
    r.check("…and with Codex's hooks not trusted, the resumed Codex pane gets the same hint as a typed `codex`",
            untrusted && hinted && (px?.view.overlay.toast?.text.string ?? "").contains("Trust all and continue"),
            "untrusted=\(untrusted) \(px?.view.overlay.toast?.text.string ?? "no note")")
    if let px { c.hideToast(px) }
    c.saveNow()
    let saved = (try? String(contentsOf: layoutURL, encoding: .utf8)) ?? ""
    r.check("…so the next quit saves both sessions again (the relaunch after that resumes them)",
            saved.contains(claudeSID) && saved.contains(codexSID))
    // That resume fails (the fake agent exits for it): kept through the relaunch grace (the shell's
    // prompt alone doesn't drop it), then a plain shell when the grace ends.
    let failed = await waitFor(10) {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("--resume \(failSID)")
            && pf.map { $0.surface.foregroundPID > 0 && c.runningProcess($0) == nil } == true
    }
    await sleepMs(300)
    r.check("(setup) the done pane's resume ran and exited (its shell is back)", failed)
    r.check("…its ✓ and session are kept through the relaunch grace", pf?.display == .done("all set") && pf?.claudeSessionID == failSID)
    if let pf { c.relaunchGraceEnded(pf, failSID) }
    r.check("…and when it ends with no agent back: a plain shell, the restored ✓ gone",
            pf?.display == .idle && pf?.claudeSessionID == nil, "\(String(describing: pf?.display))")

    // The same through a cmux import (first launch: hooks not installed yet), then Undo Import:
    // nobody touched the imported workspaces, so all of them close.
    r.section = "cmux import + undo, no hooks"
    let cmuxHome = paths.stateDir.appendingPathComponent("cmux-home", isDirectory: true)
    let fixture = writeCmuxFixture(cmuxHome)
    c.importFromCmux(CmuxImport.plan(CmuxSources(home: cmuxHome)), sections: [.workspaces])
    let imported = c.model.workspaces.filter { $0.id.hasPrefix("cmux-") }
    let agentPane = imported.flatMap(\.panes).first { $0.claudeSessionID == fixture.sid }
    let resumed = await waitFor(10) {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("--resume \(fixture.sid)")
            && agentPane.map { c.runningProcess($0) != nil } == true
    }
    await sleepMs(300)
    r.check("(setup) 3 workspaces imported, the Claude one resumed by its shell", imported.count == 3 && resumed,
            "\(imported.count) " + ((try? String(contentsOfFile: log, encoding: .utf8)) ?? ""))
    r.check("the imported Claude pane keeps its session through the shell's prompt", agentPane?.claudeSessionID == fixture.sid,
            agentPane?.claudeSessionID ?? "nil")
    let undone = c.undoCmuxImport()
    r.check("Undo Import right away: every imported workspace closes (none counts as used)",
            !c.model.workspaces.contains { $0.id.hasPrefix("cmux-") } && !undone.contains("Kept"), undone)

    // ------------------------------------------------------------- zoom + directional focus
    r.section = "zoom + arrows"
    let zw = c.newWorkspace(select: true)
    let za = zw.panes[0]
    _ = await waitFor(5) { za.surface.foregroundPID > 0 }
    guard let zb = c.split(za, .right) else { r.check("split", false); return finish(r, c) }
    _ = await waitFor(5) { zb.surface.foregroundPID > 0 }
    c.focus(za)
    c.toggleSplitZoom()
    r.check("(setup) zoomed on the left pane", zw.zoomedPane === za && zb.surface.window == nil)
    c.moveFocus(.right)
    r.check("⌘⌥→ (goto_split:right) while zoomed: unzooms and focuses the right pane",
            !zw.isZoomed && zw.focusedPane === zb && zb.surface.window != nil && zb.surface.occlusionVisible,
            "zoomed=\(zw.isZoomed) focused right=\(zw.focusedPane === zb)")
    c.toggleSplitZoom()
    c.moveFocus(.left)
    r.check("⌘⌥← back while zoomed on the right pane: the left one", !zw.isZoomed && zw.focusedPane === za)
    c.toggleSplitZoom()
    c.moveFocus(.left)
    r.check("…with nothing further left: stays zoomed on it", zw.zoomedPane === za && zw.focusedPane === za
            && zb.surface.window == nil && !zb.surface.occlusionVisible)

    // A pane hidden behind the zoom finishing: nobody can see it, so it's unattended.
    hookEvent(c, zb, "SessionStart", session: "zoom-hidden")
    hookEvent(c, zb, "UserPromptSubmit", session: "zoom-hidden", ["prompt": "go"])
    hookEvent(c, zb, "Stop", session: "zoom-hidden", ["last_assistant_message": "done"])
    r.check("a pane hidden behind the zoom goes done: it waits for the user (unattended)",
            zb.agent.state == .done && zb.attentionSince != nil)
    hookEvent(c, za, "SessionStart", session: "zoom-shown")
    hookEvent(c, za, "UserPromptSubmit", session: "zoom-shown", ["prompt": "go"])
    hookEvent(c, za, "Stop", session: "zoom-shown", ["last_assistant_message": "done"])
    r.check("…the zoomed pane itself, on screen: attended", za.agent.state == .done && za.attentionSince == nil)
    c.toggleSplitZoom()

    // ------------------------------------------------------------- undo send with an image
    r.section = "undo send + image"
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lmux-regress-\(getpid())")
    let proj = dir.appendingPathComponent("claude/projects/-tmp")
    try? FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let isid = "6c1d2e3f-4a5b-4c6d-8e7f-a0b1c2d3e4f5"
    let tpath = proj.appendingPathComponent("\(isid).jsonl").path
    let common = #""isSidechain":false,"userType":"external","cwd":"/tmp","sessionId":"\#(isid)","version":"2.1.280""#
    let before = """
    {"parentUuid":null,\(common),"type":"user","message":{"role":"user","content":"hello"},"uuid":"img-u0","timestamp":"2026-11-02T10:00:00.000Z","promptSource":"typed"}
    {"parentUuid":"img-u0",\(common),"type":"assistant","message":{"id":"m0","role":"assistant","content":[{"type":"text","text":"hi"}]},"uuid":"img-a0","timestamp":"2026-11-02T10:00:01.000Z"}

    """
    // Claude Code's shape for a pasted image: the text block, then the image block.
    let turn = """
    {"parentUuid":"img-a0",\(common),"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Image #1] what is wrong here"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}]},"uuid":"img-u1","timestamp":"2026-11-02T10:00:02.000Z","promptSource":"typed"}

    """
    try? before.write(toFile: tpath, atomically: true, encoding: .utf8)
    let uw = c.newWorkspace(select: true, program: "/bin/sleep 600")
    let up = uw.panes[0]
    _ = await waitFor(5) { up.surface.foregroundPID > 0 }
    hookEvent(c, up, "SessionStart", session: isid, transcript: tpath, ["source": "startup"])
    hookEvent(c, up, "UserPromptSubmit", session: isid, ["prompt": "[Image #1] what is wrong here"])
    if let h = FileHandle(forWritingAtPath: tpath) { h.seekToEndOfFile(); h.write(Data(turn.utf8)); h.closeFile() }
    let since = before.utf8.count
    let task = Task { await c.undo(prompt: "[Image #1] what is wrong here", in: up, since: since) }
    let found = await waitFor(5) { c.actionLog.contains { $0.hasPrefix("rewind img-u1") } }
    r.check("Undo send finds the turn whose prompt has an image (text + image blocks)", found,
            c.actionLog.suffix(3).joined(separator: "; "))
    r.check("…not \"Couldn't find that message\"", !(up.view.overlay.toast?.text.string ?? "").contains("Couldn’t find"))
    _ = await task.value

    // ------------------------------------------------------------- Clear Status and pending work
    r.section = "clear status: pending"
    let cw = c.newWorkspace(select: true)
    let kp = cw.panes[0]
    _ = await waitFor(5) { kp.surface.foregroundPID > 0 }
    /// A Codex hook event (lmux-hook marks the agent on the envelope, not in Codex's payload).
    func codexEvent(_ p: Pane, _ name: String, _ extra: [String: Any] = [:]) {
        var o: [String: Any] = ["hook_event_name": name, "session_id": "codex-clear", "cwd": "/tmp"]
        for (k, v) in extra { o[k] = v }
        var e = try! HookEvent(paneID: p.id, payload: o)
        e.agent = .codex
        c.handleHook(e)
    }
    codexEvent(kp, "SessionStart")
    codexEvent(kp, "UserPromptSubmit", ["prompt": "go"])
    codexEvent(kp, "PermissionRequest", ["tool_name": "Bash"])
    let asks = await waitFor(c.codexPermissionGrace + 1) { kp.needsInput }
    r.check("(setup) a Codex approval nobody else answers: needs input after the grace second", asks && kp.runsCodex, "\(kp.display)")
    codexEvent(kp, "UserPromptSubmit", ["prompt": "go"])
    codexEvent(kp, "PermissionRequest", ["tool_name": "Bash"])
    c.clearStatus(for: cw)
    await sleepMs(Int(c.codexPermissionGrace * 1000) + 400)
    r.check("Clear Status during Codex's grace second: its pending \"needs input\" doesn't come back",
            !kp.needsInput && c.codexPermissionWork[kp.id] == nil, "\(kp.display)")
    codexEvent(kp, "UserPromptSubmit", ["prompt": "again"])
    codexEvent(kp, "PermissionRequest", ["tool_name": "Bash"])
    c.focus(kp)
    _ = await waitFor(2) { w.firstResponder === kp.surface }
    await type("y", window: w)
    await sleepMs(Int(c.codexPermissionGrace * 1000) + 400)
    r.check("typing into Codex within its grace second (answering it): no \"needs input\" after the fact",
            !kp.needsInput, "\(kp.display)")
    // A coalesced `lmux notify` waiting for the end of its window.
    let nw = c.newWorkspace(select: false)
    let np = nw.panes[0]
    c.notifyInterval = 1
    c.notify(text: "first", title: nil, paneID: np.id)
    c.notify(text: "second", title: nil, paneID: np.id)
    r.check("(setup) the first notify counted, the second is held", np.unread == 1)
    let posted = c.notifier.postedCount
    c.clearStatus(for: nw)
    await sleepMs(1400)
    r.check("Clear Status: the held notify doesn't bring the badge or a notification back",
            np.unread == 0 && c.notifier.postedCount == posted, "unread \(np.unread) posted +\(c.notifier.postedCount - posted)")
    c.notify(text: "third", title: nil, paneID: np.id)
    r.check("…and the next notify after the window still posts right away", np.unread == 1 && c.notifier.postedCount == posted + 1)
    c.notifyInterval = 5

    // ------------------------------------------------------------- drag: selection changes mid-drag
    r.section = "drag + selection"
    let host = c.root.sidebarHost
    func titles() -> String { c.model.workspaces.map(\.title).joined() }
    let rows = await stageWorkspaces(c, ["A", "B", "C", "D"])
    await click(host, at: rowPoint(c, 0))
    await click(host, at: rowPoint(c, 1), modifiers: .command)
    r.check("(setup) A and B selected", c.model.selection == Set([rows[0].id, rows[1].id]))
    // Between C and D: A+B travel as one block under the pointer (the others close up and make room),
    // so one row down puts the block's top on the slot after C.
    let between = rowPoint(c, 1)
    await dragBegin(host, from: rowPoint(c, 0), to: between)
    _ = await waitFor(2) { c.model.sidebarDrag != nil }
    c.select(rows[2])  // e.g. ⌘3 or `lmux new-workspace` mid-drag: the multi-selection is gone
    await mouseUp(host, at: NSPoint(x: between.x, y: between.y + 1), type: .leftMouseDragged)
    await mouseUp(host, at: between)
    _ = await waitFor(2) { titles() != "ABCD" }
    r.check("A+B dragged between C and D, selection changed mid-drag: they land between C and D", titles() == "CABD", titles())

    // ------------------------------------------------------------- CLAUDE_CONFIG_DIR hint
    r.section = "hooks hint"
    let none = c.paths.stateDir.appendingPathComponent("hint-none", isDirectory: true)
    let work = c.paths.stateDir.appendingPathComponent("hint-work", isDirectory: true)
    try? FileManager.default.createDirectory(at: work.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try? "{}".write(to: work.appendingPathComponent("sessions/5150.json"), atomically: true, encoding: .utf8)
    let h = LmuxController.hooksHint(settingsPath: none.appendingPathComponent("settings.json").path, claudePID: 5150,
                                     candidates: [work])
    r.check("no hooks anywhere, Claude on another CLAUDE_CONFIG_DIR: offers that dir, doesn't say the hooks are set up",
            h.kind == .otherConfigDir && h.action == "Install There…" && !h.detail.contains("set up for")
                && h.detail.contains("hint-work"), h.detail)

    return finish(r, c)
}
