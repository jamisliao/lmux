import AppKit
import LmuxHooks
import LmuxTerminal
import LmuxTranscript
@testable import LmuxUI

// End-to-end on the real Claude Code binary, offline (App/scripts/e2etest.sh): a temp HOME and
// config dir, and a local stand-in for the API that logs what Claude sends. Four prompts, then
// through the buttons' code paths: ✎ on the last (rewound in place, text back in the input), ×
// refused while the input holds a draft, × on an older turn whose later turn wrote a file
// (everything after it goes, the file stays), a new prompt (what Claude sends no longer has the
// removed turns), Copy original, and ⌘Z both while Claude works and after it replied. The same
// claude process runs throughout.
//
// Env: LMUX_E2E_CWD (scratch dir), LMUX_E2E_CLAUDE_CMD (claude with the temp config and the mock
// API), LMUX_E2E_API_LOG (the mock's request log), LMUX_PANE_COMMAND (plain zsh), plus the usual
// headless state dirs.

@MainActor
func rows(_ p: Pane) -> [String] { p.surface.viewportRows().rows.map(\.text) }

@MainActor
func dump(_ p: Pane, _ label: String) {
    guard env["LMUX_E2E_DUMP"] == "1" else { return }
    print("---- screen: \(label)")
    for (i, r) in rows(p).enumerated() where !r.trimmingCharacters(in: .whitespaces).isEmpty {
        print(String(format: "%3d|", i) + r.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
    }
}

/// Re-evaluates `cond` whenever `path` is written (kqueue), plus once a second for what changes
/// without a write (hook-driven state, an atomic rewrite that replaced the watched inode), until
/// it holds or `timeout` passes.
@MainActor
func waitOnFile(_ path: String, timeout: Double, _ cond: @MainActor () async -> Bool) async -> Bool {
    if await cond() { return true }
    let (wake, cont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let fd = open(path, O_EVTONLY)
    let src = fd >= 0 ? DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                                    eventMask: [.write, .extend, .delete, .rename], queue: .main) : nil
    src?.setEventHandler { cont.yield() }
    src?.setCancelHandler { close(fd) }
    src?.resume()
    let tick = Timer(timeInterval: 1, repeats: true) { _ in cont.yield() }
    RunLoop.main.add(tick, forMode: .common)
    defer { tick.invalidate(); src?.cancel(); cont.finish() }
    let end = Date().addingTimeInterval(timeout)
    for await _ in wake {
        if await cond() { return true }
        if Date() >= end { return false }
    }
    return false
}

/// What the run looked like when a wait gave up.
@MainActor
func diagnose(_ c: LmuxController, _ p: Pane, _ turns: [TranscriptIndex.Turn], since: Date) -> String {
    let t = turns.map { "\($0.index):\($0.prompt.prefix(24))\($0.hasReply ? "+reply" : "")" }.joined(separator: " / ")
    let screen = rows(p).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8)
        .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: " | ")
    return String(format: "after %.0fs: state=%@ session=%@ turns=[%@] log=[%@] screen=[%@]",
                  Date().timeIntervalSince(since), "\(p.agent.state)", p.claudeSessionID ?? "nil", t,
                  c.actionLog.suffix(4).joined(separator: "; "), screen)
}

/// Turn `n` (1-based) is in the transcript with Claude's reply, read through the pane's
/// TranscriptIndex (what hover and forget use), and then Claude's Stop has arrived. Waits on
/// the transcript file, generous but bounded; the check says what was seen if it gives up.
@MainActor
@discardableResult
func waitReply(_ r: Report, _ c: LmuxController, _ p: Pane, turn n: Int, _ label: String,
               timeout: Double = 240) async -> Bool {
    let start = Date()
    var turns: [TranscriptIndex.Turn] = []
    guard let path = p.transcriptPath else { r.check(label, false, "no transcript path"); return false }
    let written = await waitOnFile(path, timeout: timeout) {
        turns = await c.loadTurns(p)
        return turns.count >= n && turns[n - 1].hasReply
    }
    let stopped = written ? await waitFor(30) { p.agent.state != .running } : false
    r.check(label, written && stopped, written && stopped
            ? String(format: "%.1fs", Date().timeIntervalSince(start))
            : (written ? "reply written, no Stop: " : "reply not in the transcript: ") + diagnose(c, p, turns, since: start))
    return written && stopped
}

/// Type text into Claude, then press a real Return through the window (the Undo path).
/// Done once the prompt is in the transcript as a new turn (or Claude reported it).
@MainActor
func submit(_ c: LmuxController, _ p: Pane, _ text: String) async {
    let before = await c.loadTurns(p).count
    p.surface.sendText(text)
    // Claude treats a burst of input as a paste for a moment; a Return inside that window
    // can be taken as part of it. Wait, and press again if the prompt didn't go out.
    await sleepMs(900)
    for _ in 0..<3 {
        await type("\r", window: c.window)
        let sent = await waitOnFile(p.transcriptPath ?? "", timeout: 6) {
            if p.agent.state == .running { return true }
            return await c.loadTurns(p).count > before
        }
        if sent { return }
    }
}

@MainActor
func hoverRow(_ c: LmuxController, _ p: Pane, turn: Int) async -> Bool {
    _ = await c.loadTurns(p)
    p.hover.readAt = .distantPast
    let m = c.screenMap(p, maxAge: 0)
    guard let head = m.map?.promptHeads().first(where: { $0.turn == turn }) else { return false }
    let y = p.surface.bounds.height - (m.rows[head.row].top + m.rowHeight / 2)
    c.paneMouseMoved(p, NSPoint(x: 200, y: y))
    return await waitFor(3) { c.hoveredTurn(p) == turn }
}


// MARK: - The mock API's request log

/// The user texts of every request Claude sent to the mock API, oldest first.
func apiRequests() -> [[String]] {
    guard let path = env["LMUX_E2E_API_LOG"], let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { line in
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["texts"] as? [String]
    }
}

/// The last request that carried `prompt` (the conversation Claude sent with it).
func apiRequest(with prompt: String) -> [String]? { apiRequests().last { $0.contains { $0.contains(prompt) } } }

@MainActor
func inputText(_ p: Pane) -> String? { LmuxController.idleInput(rows(p)) }

/// Esc Esc as a user would (clears a filled input).
@MainActor
func escEsc(_ c: LmuxController, _ p: Pane) async {
    var d = LmuxController.RewindDrive()
    await c.pressEscTwice(p, &d)
}

/// A rewind a button started (in a Task): it began, and it's over.
@MainActor
func rewindFinished(_ p: Pane, _ timeout: Double = 25) async -> Bool {
    _ = await waitFor(2) { p.busy }
    return await waitFor(timeout) { !p.busy }
}

@MainActor
func runE2E() async -> Int32 {
    let r = Report()
    r.section = "e2e"
    guard let cwd = env["LMUX_E2E_CWD"], let claude = env["LMUX_E2E_CLAUDE_CMD"], env["LMUX_E2E_API_LOG"] != nil else {
        print("FAIL  [e2e] LMUX_E2E_CWD / LMUX_E2E_CLAUDE_CMD / LMUX_E2E_API_LOG not set"); return 1
    }
    let c = makeController()
    c.pasteboard = NSPasteboard(name: NSPasteboard.Name("lmux-e2e-\(getpid())"))
    let ws = c.newWorkspace(cwd: cwd)
    ws.customTitle = "e2e"
    let p = ws.panes[0]
    for w in c.model.workspaces where w !== ws { c.closeWorkspace(w) }
    // A second workspace: the "sending to" label over Claude's input shows only with two or more.
    _ = c.newWorkspace()
    c.select(ws)
    r.check("shell prompt", await waitFor(10) { rows(p).contains { $0.contains("%") } }, rows(p).joined(separator: "|"))

    p.surface.sendText("\(claude) --model claude-e2e-mock --permission-mode acceptEdits\n")
    var ready = false
    let end = Date().addingTimeInterval(40)
    while Date() < end {
        if p.claudeSessionID != nil, inputText(p) != nil { ready = true; break }
        await sleepMs(250)
    }
    dump(p, "started")
    r.check("claude started, SessionStart hook seen, input box found", ready,
            "sid=\(p.claudeSessionID ?? "nil") rows=\(rows(p).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " | "))")
    guard ready, p.claudeSessionID != nil else { return finish(r, c) }
    let pid = p.claudePID ?? ClaudeProcess.representative(ofGroup: p.surface.foregroundPID) ?? 0
    func sameClaude() -> Bool { pid > 0 && ClaudeProcess.alive(pid) && p.claudePID.map { $0 == pid } ?? true }
    r.check("input label shows the workspace title above Claude's input",
            await waitFor(3) { !p.view.overlay.inputLabel.isHidden && p.view.overlay.inputLabel.text == "e2e" })

    // 1) four prompts; the third writes a file (Claude's Write tool, accepted)
    let note = (cwd as NSString).appendingPathComponent("note.txt")
    let prompts = ["remember PINEAPPLE", "remember the number 42", "WRITEFILE \(note) please", "third MANGO"]
    for (i, text) in prompts.enumerated() {
        await submit(c, p, text)
        guard await waitReply(r, c, p, turn: i + 1, "prompt \(i + 1) answered: its turn + reply in the transcript, then Stop", timeout: 60) else {
            return finish(r, c)
        }
    }
    dump(p, "after four prompts")
    r.check("the Write tool wrote note.txt", FileManager.default.fileExists(atPath: note))
    let requestsBefore = apiRequests().count

    // 2) ✎ on the last turn: rewound in place, its text back in the input, nothing sent
    if await hoverRow(c, p, turn: 4) {
        p.view.overlay.turnBar?.edit.performClick()
        let detail = p.view.overlay.card?.detail.stringValue ?? ""
        r.check("✎ asks first; the last turn: nothing after it to remove",
                c.cardShown(p) && detail.contains("Claude keeps running") && !detail.contains("everything after it"), detail)
        p.view.overlay.card?.confirm.performClick()
        r.check("✎: done", await rewindFinished(p))
        dump(p, "after ✎")
        r.check("✎: the prompt is back in Claude's input", await waitFor(3) { inputText(p) == "third MANGO" }, inputText(p) ?? "nil")
        let turns = await c.loadTurns(p)
        r.check("✎: lmux shows 3 turns (the rewound one hidden; no SessionStart from the rewind cleared that)",
                turns.count == 3 && p.rewoundFrom != nil, turns.map(\.prompt).joined(separator: " / "))
        r.check("✎: the same claude process, nothing sent", sameClaude() && apiRequests().count == requestsBefore
                && p.agent.state != .running, "pid \(pid) now \(p.claudePID ?? 0)")
        r.check("✎: the rewound prompt is no longer above the input",
                !c.screenMap(p, maxAge: 0).map!.promptHeads().contains { $0.turn == 4 }
                && !rows(p).dropLast(4).contains { $0.hasPrefix("❯ third MANGO") })
    } else {
        r.check("hover over the MANGO prompt", false)
    }

    // 3) the first turn's pill has no ×; × on turn 2 while the input holds a draft: refused, nothing changes
    if await hoverRow(c, p, turn: 1) {
        r.check("turn 1 (the conversation's first): ✎ but no ×",
                p.view.overlay.turnBar.map { !$0.edit.isHidden && $0.remove.isHidden } ?? false)
    } else {
        r.check("hover over the PINEAPPLE prompt", false)
    }
    if await hoverRow(c, p, turn: 2) {
        p.view.overlay.turnBar?.remove.performClick()
        p.view.overlay.card?.confirm.performClick()
        r.check("× with a draft in the input: done", await rewindFinished(p))
        r.check("…refused: “Couldn’t rewind” note, the draft kept, no menu left open",
                (p.view.overlay.toast?.text.string ?? "").contains("Couldn’t rewind") && inputText(p) == "third MANGO",
                "toast=\(p.view.overlay.toast?.text.string ?? "none") input=\(inputText(p) ?? "nil")")
        r.check("…3 turns still", await c.loadTurns(p).count == 3)
    } else {
        r.check("hover over the 42 prompt", false)
    }
    await escEsc(c, p)
    r.check("Esc Esc clears the draft (as a user would)", await waitFor(3) { inputText(p) == "" }, inputText(p) ?? "nil")

    // 4) × on turn 2: removes it and the WRITEFILE turn after it; the file stays (conversation only)
    if await hoverRow(c, p, turn: 2) {
        p.view.overlay.turnBar?.remove.performClick()
        let detail = p.view.overlay.card?.detail.stringValue ?? ""
        r.check("× on an older turn says it removes everything after it, and that files stay",
                detail.contains("Removes this message and everything after it") && detail.contains("note.txt"), detail)
        p.view.overlay.card?.confirm.performClick()
        r.check("×: done", await rewindFinished(p))
        dump(p, "after ×")
        let turns = await c.loadTurns(p)
        r.check("×: only turn 1 left", turns.map(\.prompt) == ["remember PINEAPPLE"], turns.map(\.prompt).joined(separator: " / "))
        r.check("×: the input is empty, no menu open", inputText(p) == "", inputText(p) ?? "nil")
        r.check("×: “Restore conversation” only: note.txt is still there",
                (try? String(contentsOfFile: note, encoding: .utf8)) == "written by the mock\n")
        r.check("×: the same claude process", sameClaude())
        r.check("×: no failure note", !(p.view.overlay.toast?.text.string ?? "").contains("Couldn’t"),
                c.actionLog.suffix(6).joined(separator: "; "))
    } else {
        r.check("hover over the 42 prompt", false)
    }

    // 5) the next prompt: what Claude sends has turn 1 and not the removed ones; lmux follows the branch
    await submit(c, p, "what do you remember")
    await waitReply(r, c, p, turn: 2, "the next prompt answered as turn 2", timeout: 60)
    let sent = apiRequest(with: "what do you remember") ?? []
    r.check("Claude sent turn 1 but none of the removed turns",
            sent.contains { $0.contains("PINEAPPLE") } && !sent.contains { $0.contains("42") || $0.contains("MANGO") || $0.contains("WRITEFILE") },
            sent.joined(separator: " | "))
    let turns5 = await c.loadTurns(p)
    r.check("lmux's turns follow Claude's new branch", turns5.map(\.prompt) == ["remember PINEAPPLE", "what do you remember"],
            turns5.map(\.prompt).joined(separator: " / "))

    // 6) Copy original = the transcript's markdown
    let answer = await c.replyText(p, turns5.last) ?? ""
    let copied = await c.copyOriginal(p)
    r.check("Copy original (⌥⌘C path) equals the transcript's markdown",
            !answer.isEmpty && copied == answer && c.pasteboard.string(forType: .string) == answer, answer)

    // 7) ⌘Z while Claude works on the prompt (the mock holds its reply 4s)
    await submit(c, p, "SLOW undo me")
    r.check("undo: toast up after Enter", await waitFor(5) { c.pendingUndo != nil })
    await cmd("z", window: c.window)
    r.check("undo (working): done", await waitFor(20) { c.pendingUndo == nil && !p.busy })
    dump(p, "after ⌘Z while working")
    r.check("undo (working): the prompt is back in the input", await waitFor(3) { inputText(p) == "SLOW undo me" }, inputText(p) ?? "nil")
    let turns7 = await c.loadTurns(p)
    r.check("undo (working): 2 turns, same claude", turns7.count == 2 && sameClaude(), turns7.map(\.prompt).joined(separator: " / "))
    await escEsc(c, p)
    _ = await waitFor(3) { inputText(p) == "" }

    // 8) ⌘Z after Claude replied (still inside the 3s): through the rewind menu
    await submit(c, p, "quick one to undo")
    _ = await waitOnFile(p.transcriptPath ?? "", timeout: 5) { (await c.loadTurns(p)).last?.hasReply == true && p.agent.state != .running }
    r.check("undo (replied): toast still up", c.pendingUndo != nil)
    await cmd("z", window: c.window)
    r.check("undo (replied): done", await waitFor(20) { c.pendingUndo == nil && !p.busy })
    dump(p, "after ⌘Z after the reply")
    r.check("undo (replied): the prompt is back in the input", await waitFor(3) { inputText(p) == "quick one to undo" },
            inputText(p) ?? "nil")
    r.check("undo (replied): 2 turns, same claude", await c.loadTurns(p).count == 2 && sameClaude())
    await escEsc(c, p)
    _ = await waitFor(3) { inputText(p) == "" }

    // 9) and Claude never sees the undone prompts again
    await submit(c, p, "final check")
    await waitReply(r, c, p, turn: 3, "a last prompt answered as turn 3", timeout: 60)
    let last = apiRequest(with: "final check") ?? []
    r.check("Claude's last request has neither undone prompt",
            !last.isEmpty && !last.contains { $0.contains("SLOW undo me") || $0.contains("quick one to undo") }, last.joined(separator: " | "))
    // 10) A pasted prompt (Claude shows "[Pasted text #N +M lines]"): ✎ puts its whole text back, ×
    //     leaves a clean input, and Claude never sends the pasted text again.
    let pasted = (1...6).map { "PASTED LINE \($0) of the e2e" }.joined(separator: "\n")
    func sendPasted() async -> Bool {
        let before = await c.loadTurns(p).count
        GhosttyRuntime.standardPasteboard.clearContents()
        GhosttyRuntime.standardPasteboard.setString(pasted, forType: .string)
        p.surface.paste(nil)
        _ = await waitFor(3) { (inputText(p) ?? "").hasPrefix("[Pasted text") }
        await sleepMs(900)
        await type("\r", window: c.window)
        return await waitOnFile(p.transcriptPath ?? "", timeout: 30) {
            let t = await c.loadTurns(p)
            return t.count > before && t.last?.hasReply == true && p.agent.state != .running
        }
    }
    r.check("a pasted prompt answered", await sendPasted())
    let p10 = await c.loadTurns(p)
    let o10e = await c.rewind(p, turnUuid: p10.last!.uuid, mode: .edit)
    r.check("✎ on a pasted prompt: its whole text back in the input (not the placeholder)",
            o10e == .done && LmuxController.idleBox(rows(p))?.first == "PASTED LINE 1 of the e2e"
            && LmuxController.idleBox(rows(p))?.contains("PASTED LINE 6 of the e2e") == true,
            "\(o10e) \(LmuxController.idleBox(rows(p)) ?? ["nil"])")
    await escEsc(c, p)
    r.check("…Esc Esc leaves a clean input", await waitFor(3) { LmuxController.idleBox(rows(p)) == [""] }, "\(LmuxController.idleBox(rows(p)) ?? ["nil"])")
    await sleepMs(900)
    r.check("a pasted prompt again", await sendPasted())
    let p10b = await c.loadTurns(p)
    let o10r = await c.rewind(p, turnUuid: p10b.last!.uuid, mode: .remove)
    r.check("× on a pasted prompt: done, a clean input", o10r == .done && LmuxController.idleBox(rows(p)) == [""],
            "\(o10r) \(LmuxController.idleBox(rows(p)) ?? ["nil"])")
    await sleepMs(900)
    await submit(c, p, "after the pasted ones")
    _ = await waitOnFile(p.transcriptPath ?? "", timeout: 30) { (await c.loadTurns(p)).last?.hasReply == true }
    let req10 = apiRequest(with: "after the pasted ones") ?? []
    r.check("…Claude's next request has neither pasted prompt", !req10.isEmpty && !req10.contains { $0.contains("PASTED LINE") },
            req10.joined(separator: " | "))

    // 11) A `!` shell command: rewinding to it is refused (Claude would leave its input in shell
    //     mode); an older turn past it rewinds as usual, back in the normal input.
    await sleepMs(900)
    p.surface.sendText("!")
    await sleepMs(400)
    p.surface.sendText("echo SHELLPROBE")
    await sleepMs(400)
    await type("\r", window: c.window)
    let shellRan = await waitOnFile(p.transcriptPath ?? "", timeout: 30) {
        (await c.loadTurns(p)).last.map { RewindMenu.isShellCommand($0.prompt) } == true && p.agent.state != .running
    }
    _ = await waitFor(10) { inputText(p) == "" }
    let t11 = await c.loadTurns(p)
    r.check("a ! shell command ran, a turn of its own", shellRan, t11.map(\.prompt).joined(separator: " / "))
    let o11 = await c.rewind(p, turnUuid: t11.last!.uuid, mode: .remove)
    r.check("× on it: refused, no menu, the input as it was", o11 != .done && RewindMenu.read(rows(p)) == .closed && inputText(p) == ""
            && p.view.overlay.toast?.text.string.contains("shell command") == true, "\(o11) input=\(inputText(p) ?? "nil")")
    let before11 = t11[t11.count - 2]
    let o11b = await c.rewind(p, turnUuid: before11.uuid, mode: .edit)
    r.check("✎ on the turn before it: done past the shell command, its prompt back in the normal input",
            o11b == .done && inputText(p) == before11.prompt, "\(o11b) input=\(inputText(p) ?? "nil")")
    await escEsc(c, p)
    _ = await waitFor(3) { inputText(p) == "" }
    p.surface.sendText("x")
    r.check("…not in shell mode (a typed x is a prompt)", await waitFor(3) { inputText(p) == "x" }, rows(p).suffix(4).joined(separator: "|"))
    await escEsc(c, p)
    _ = await waitFor(3) { inputText(p) == "" }

    r.check("one claude process for the whole run", sameClaude())
    if env["LMUX_E2E_DUMP"] == "1" { for l in c.actionLog { print("      log: \(l)") } }

    // Leave nothing running.
    for _ in 0..<3 { p.surface.sendKey(keyCode: 0x08, codepoint: 0x63, control: true); await sleepMs(400) }
    _ = await waitFor(5) { p.claudeSessionID == nil }
    return finish(r, c)
}
