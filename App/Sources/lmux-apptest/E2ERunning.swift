import AppKit
import LmuxHooks
import LmuxTerminal
import LmuxTranscript
@testable import LmuxUI

// ✎ / × on the turn Claude is still on, on the real Claude Code binary (App/scripts/e2etest.sh
// --running): the turn that asks for a permission (its dialog hides the input box; the hover pill
// shows there since the pane waits on the user), the turn mid-reply, and a turn with a message
// queued behind it (refused, and the note says why). The mock API (scripts/claude-api-mock.py)
// holds ASKTOOL's turn at a Bash permission dialog and STREAM's reply half written.
@MainActor
func runE2ERunning() async -> Int32 {
    let r = Report()
    r.section = "e2e-running"
    guard let cwd = env["LMUX_E2E_CWD"], let claude = env["LMUX_E2E_CLAUDE_CMD"], env["LMUX_E2E_API_LOG"] != nil else {
        print("FAIL  [e2e-running] LMUX_E2E_CWD / LMUX_E2E_CLAUDE_CMD / LMUX_E2E_API_LOG not set"); return 1
    }
    let c = makeController()
    c.pasteboard = NSPasteboard(name: NSPasteboard.Name("lmux-e2e-\(getpid())"))
    let ws = c.newWorkspace(cwd: cwd)
    let p = ws.panes[0]
    for w in c.model.workspaces where w !== ws { c.closeWorkspace(w) }
    c.select(ws)
    _ = await waitFor(10) { rows(p).contains { $0.contains("%") } }
    p.surface.sendText("\(claude) --model claude-e2e-mock --permission-mode acceptEdits\n")
    r.check("claude started", await waitFor(40) { p.claudeSessionID != nil && inputText(p) != nil })
    guard p.claudeSessionID != nil else { return finish(r, c) }
    await submit(c, p, "remember PINEAPPLE")
    guard await waitReply(r, c, p, turn: 1, "turn 1 answered", timeout: 60) else { return finish(r, c) }
    func toast() -> String { p.view.overlay.toast?.text.string ?? "" }

    // 1) × through the pill while Claude asks to run a command for the turn just sent.
    await sleepMs(900)
    await submit(c, p, "ASKTOOL now")
    let asking = await waitFor(20) { if case .needsInput = p.agent.state { return LmuxController.inputText(rows(p)) == nil }; return false }
    r.check("Claude asks for a permission, its input box hidden", asking, "\(p.agent.state)")
    // (Claude writes the prompt to its transcript a moment after the dialog is up.)
    _ = await waitOnFile(p.transcriptPath ?? "", timeout: 10) { await c.loadTurns(p).count == 2 }
    if await hoverRow(c, p, turn: 2) {
        p.view.overlay.turnBar?.remove.performClick()
        let detail = p.view.overlay.card?.detail.stringValue ?? ""
        r.check("× on it asks first and says the dialog is declined first", c.cardShown(p) && detail.contains("declined first"), detail)
        p.view.overlay.card?.confirm.performClick()
        r.check("×: done", await rewindFinished(p))
        let turns = await c.loadTurns(p)
        r.check("×: the turn is gone, the input empty, no failure note", turns.map(\.prompt) == ["remember PINEAPPLE"] && inputText(p) == ""
                && !toast().contains("Couldn’t"), "\(turns.map(\.prompt)) input=\(inputText(p) ?? "nil") toast=\(toast()) \(c.actionLog.suffix(4))")
        r.check("…and the pane no longer waits for an answer", p.agent.state == .idle, "\(p.agent.state)")
    } else {
        let m = c.screenMap(p, maxAge: 0)
        r.check("hover over the ASKTOOL prompt (pill while Claude asks)", false,
                "\(p.agent.state) heads=\(m.map?.promptHeads() ?? []) turns=\(p.hover.turns.map(\.prompt)) hovered=\(c.hoveredTurn(p).map(String.init) ?? "nil") rows=\(rows(p).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(14).joined(separator: " | "))")
        return finish(r, c)
    }

    // 2) ✎ while Claude is writing its reply (part of it on screen already).
    await sleepMs(900)
    await submit(c, p, "STREAM tell me")
    _ = await waitFor(10) { rows(p).contains { $0.contains("Thinking it over") } }
    let o2 = await c.rewind(p, turnUuid: (await c.loadTurns(p)).last!.uuid, mode: .edit)
    let left2 = await c.loadTurns(p).count
    r.check("✎ mid-reply: Esc first, rewound, the prompt back in the input, the pane not left running",
            o2 == .done && inputText(p) == "STREAM tell me" && p.agent.state != .running && left2 == 1,
            "\(o2) input=\(inputText(p) ?? "nil") \(p.agent.state) \(c.actionLog.suffix(4))")
    await escEsc(c, p)
    _ = await waitFor(3) { inputText(p) == "" }

    // 3) A message queued behind the running turn: refused before any key, and the note says why.
    await sleepMs(900)
    await submit(c, p, "SLOW queue behind me")
    p.surface.sendText("queued one")
    await sleepMs(900)
    await type("\r", window: c.window)
    _ = await waitFor(5) { LmuxController.queuedPrompts(rows(p)) }
    let o3 = await c.rewind(p, turnUuid: (await c.loadTurns(p)).last!.uuid, mode: .remove)
    r.check("× with a queued message: refused, the note names it", o3 != .done && toast().contains("queued messages"),
            "\(o3) toast=\(toast())")
    _ = await waitOnFile(p.transcriptPath ?? "", timeout: 30) {
        (await c.loadTurns(p)).last.map { $0.prompt == "queued one" && $0.hasReply } == true && p.agent.state != .running
    }

    // 4) What Claude sends next has neither taken-back turn.
    await sleepMs(900)
    await submit(c, p, "next one")
    _ = await waitOnFile(p.transcriptPath ?? "", timeout: 30) { (await c.loadTurns(p)).last?.hasReply == true && p.agent.state != .running }
    let sent = apiRequest(with: "next one") ?? []
    r.check("Claude's next request has neither the ASKTOOL nor the STREAM turn",
            !sent.isEmpty && sent.contains { $0.contains("PINEAPPLE") } && !sent.contains { $0.contains("ASKTOOL") || $0.contains("STREAM") },
            sent.joined(separator: " | "))

    for _ in 0..<3 { p.surface.sendKey(keyCode: 0x08, codepoint: 0x63, control: true); await sleepMs(400) }
    _ = await waitFor(5) { p.claudeSessionID == nil }
    return finish(r, c)
}
