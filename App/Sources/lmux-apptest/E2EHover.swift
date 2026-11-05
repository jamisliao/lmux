import AppKit
import LmuxHooks
import LmuxTerminal
import LmuxTranscript
@testable import LmuxUI

// Hover on the real Claude Code binary (App/scripts/e2etest.sh --hover; LMUX_E2E_THEME=light for
// the light theme's prompt bars): short Korean prompts, the session resumed a day later (Claude then
// draws "✻ … · done Wednesday 11:42 PM" under each reply), a third turn, then the pointer on every
// row of every turn: the band covers that turn alone, the pill sits on its prompt row, the first
// turn has no ×, and × on turn 2 removes turn 2 and what came after it, never turn 1.
@MainActor
func runE2EHover() async -> Int32 {
    let r = Report()
    r.section = "e2e-hover"
    guard let cwd = env["LMUX_E2E_CWD"], let claude = env["LMUX_E2E_CLAUDE_CMD"], env["LMUX_E2E_API_LOG"] != nil else {
        print("FAIL  [e2e-hover] LMUX_E2E_CWD / LMUX_E2E_CLAUDE_CMD / LMUX_E2E_API_LOG not set"); return 1
    }
    let c = makeController()
    c.pasteboard = NSPasteboard(name: NSPasteboard.Name("lmux-e2e-\(getpid())"))
    let ws = c.newWorkspace(cwd: cwd)
    let p = ws.panes[0]
    for w in c.model.workspaces where w !== ws { c.closeWorkspace(w) }
    c.select(ws)
    _ = await waitFor(10) { rows(p).contains { $0.contains("%") } }
    let start = "\(claude) --model claude-e2e-mock --permission-mode acceptEdits"
    p.surface.sendText(start + "\n")
    r.check("claude started", await waitFor(40) { p.claudeSessionID != nil && inputText(p) != nil })
    guard p.claudeSessionID != nil else { return finish(r, c) }
    // The user's loop: one turn, then send a message and × it, again and again (the last one "흠"),
    // then "흠" for good.
    await submit(c, p, "하이")
    guard await waitReply(r, c, p, turn: 1, "“하이” answered as turn 1", timeout: 60) else { return finish(r, c) }
    let cycles = Int(env["LMUX_E2E_CYCLES"] ?? "") ?? 6
    var bad: [String] = []
    for k in 1...cycles {
        let text = k == cycles ? "흠" : "반복 \(k)"
        await sleepMs(900)
        await submit(c, p, text)
        guard await waitReply(r, c, p, turn: 2, "cycle \(k): “\(text)” answered as turn 2", timeout: 60) else { return finish(r, c) }
        await sleepMs(300)
        let heads = c.screenMap(p, maxAge: 0).map?.promptHeads().map(\.turn) ?? []
        guard await hoverRow(c, p, turn: 2) else { bad.append("cycle \(k): no pill on turn 2, heads \(heads)"); dump(p, "cycle \(k)"); break }
        p.view.overlay.turnBar?.remove.performClick()
        p.view.overlay.card?.confirm.performClick()
        _ = await rewindFinished(p)
        let left = await c.loadTurns(p)
        if left.map(\.prompt) != ["하이"] || inputText(p) != "" {
            bad.append("cycle \(k): turns \(left.map(\.prompt)) input \(inputText(p) ?? "nil") log \(c.actionLog.suffix(3))")
        }
    }
    r.check("\(cycles) cycles of send + × on turn 2: each time only “하이” is left, the input empty", bad.isEmpty, bad.joined(separator: "; "))
    await sleepMs(900)
    await submit(c, p, "흠")
    guard await waitReply(r, c, p, turn: 2, "“흠” answered as turn 2", timeout: 60) else { return finish(r, c) }
    await sleepMs(500)
    let afterLoop = await c.loadTurns(p)
    p.hover.readAt = .distantPast
    r.check("after the loop: lmux's turns are “하이”, “흠” and both prompts head their turns",
            afterLoop.map(\.prompt) == ["하이", "흠"] && c.screenMap(p, maxAge: 0).map?.promptHeads().map(\.turn) == [1, 2],
            "turns \(afterLoop.map(\.prompt)) rewoundFrom \(p.rewoundFrom ?? "nil")")

    // Resumed a day later: the same transcript, its times a day back.
    let sid = p.claudeSessionID!, path = p.transcriptPath!
    for _ in 0..<3 { p.surface.sendKey(keyCode: 0x08, codepoint: 0x63, control: true); await sleepMs(400) }
    _ = await waitFor(10) { p.claudeSessionID == nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let stamp = try! NSRegularExpression(pattern: #""timestamp":"([^"]+)""#)
    for m in stamp.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard let range = Range(m.range(at: 1), in: text), let d = iso.date(from: String(text[range])) else { continue }
        text.replaceSubrange(range, with: iso.string(from: d.addingTimeInterval(-86400)))
    }
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
    p.surface.sendText("clear; \(start) --resume \(sid)\n")
    r.check("resumed", await waitFor(40) { p.claudeSessionID == sid && inputText(p) != nil })
    await submit(c, p, "그럼 이건")
    guard await waitReply(r, c, p, turn: 3, "“그럼 이건” answered as turn 3", timeout: 60) else { return finish(r, c) }
    await sleepMs(800)
    dump(p, "resumed, three turns")
    r.check("a day old: Claude draws “done <weekday> <time>” under the old replies",
            rows(p).contains { row in row.contains("· done ") && ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"].contains { row.contains($0) } },
            rows(p).filter { $0.contains("· done") }.joined(separator: " | "))

    // The pointer on every non-blank row of each turn.
    _ = await c.loadTurns(p)
    p.hover.readAt = .distantPast
    let m = c.screenMap(p, maxAge: 0)
    let text3 = m.rows.map(\.text)
    let heads = m.map?.promptHeads() ?? []
    r.check("three prompt bars, three turns", heads.map(\.turn) == [1, 2, 3], "\(heads)")
    func rowOf(_ y: CGFloat) -> Int { Int(((y - m.rows[0].top) / m.rowHeight).rounded()) }
    let ov = p.view.overlay
    for (k, h) in heads.enumerated() {
        // From the screen, not the locator: the turn's non-blank rows up to the next prompt bar (the
        // last turn: up to the input box), without Claude's right-aligned "● … /effort" note.
        let end = k + 1 < heads.count ? heads[k + 1].row : (m.map?.inputRule ?? text3.count)
        // A turn ends at its "✻ … · done …" line: after a resume Claude also draws the replies of the
        // removed turns under it, which are no turn's.
        let done = (h.row..<end).first { text3[$0].hasPrefix("✻ ") && text3[$0].contains("· done ") } ?? (end - 1)
        let own = (h.row...done).filter { !text3[$0].trimmingCharacters(in: .whitespaces).isEmpty && !text3[$0].contains("/effort") }
        let orphans = ((done + 1)..<max(done + 1, end)).filter { !text3[$0].trimmingCharacters(in: .whitespaces).isEmpty && !text3[$0].contains("/effort") }
        if !orphans.isEmpty {
            var owned: [Int] = []
            for row in orphans {
                c.paneMouseMoved(p, NSPoint(x: 200, y: p.surface.bounds.height - (m.rows[row].top + m.rowHeight / 2)))
                await sleepMs(150)
                if m.map?.turnOfRow[row] != nil || c.hoveredTurn(p) != nil { owned.append(row) }
            }
            r.check("turn \(h.turn): the removed turns' replies Claude draws under it after the resume (\(orphans.count) rows) are no turn's",
                    owned.isEmpty, "owned \(owned): " + owned.map { text3[$0] }.joined(separator: " | "))
        }
        let last = own.last ?? h.row
        var wrong: [String] = []
        for row in own {
            c.paneMouseMoved(p, NSPoint(x: 200, y: p.surface.bounds.height - (m.rows[row].top + m.rowHeight / 2)))
            _ = await waitFor(1) { c.hoveredTurn(p) == h.turn }
            let pill = ov.turnRow.map { rowOf($0.top) }, band = ov.turnBand.map { (rowOf($0.minY), rowOf($0.maxY) - 1) }
            if c.hoveredTurn(p) != h.turn || pill != h.row || band?.0 != h.row || band?.1 != last {
                wrong.append("row \(row): turn \(c.hoveredTurn(p).map(String.init) ?? "-") pill \(pill.map(String.init) ?? "-") band \(band.map { "\($0.0)..\($0.1)" } ?? "-")")
            }
        }
        let footer = own.contains { text3[$0].hasPrefix("✻ ") && text3[$0].contains("· done ") }
        let bar = ov.turnBar
        r.check("turn \(h.turn): pointer on its prompt, reply and done line (\(own.count) rows): that turn, the pill on row \(h.row), the band \(h.row)…\(last)"
                + (k == 0 ? "; the first turn: ✎, no ×" : "; ✎ ×"),
                footer && own.count >= 3 && wrong.isEmpty && bar.map { !$0.edit.isHidden && $0.remove.isHidden == (k == 0) } ?? false,
                wrong.joined(separator: "; ") + " rows \(own)")
    }

    if let note = text3.firstIndex(where: { $0.contains("/effort") }) {
        c.paneMouseMoved(p, NSPoint(x: 200, y: p.surface.bounds.height - (m.rows[note].top + m.rowHeight / 2)))
        await sleepMs(300)
        r.check("Claude's “/effort” note above the input is no turn's", m.map?.turnOfRow[note] == nil && c.hoveredTurn(p) == nil, text3[note])
    }

    // × on turn 2: turn 2 and turn 3 go, turn 1 stays, in the same claude.
    let pid = p.claudePID ?? 0
    if let h2 = heads.first(where: { $0.turn == 2 }) {
        c.paneMouseMoved(p, NSPoint(x: 200, y: p.surface.bounds.height - (m.rows[h2.row + 2].top + m.rowHeight / 2)))
        _ = await waitFor(2) { c.hoveredTurn(p) == 2 }
        ov.turnBar?.remove.performClick()
        let msg = ov.card?.message.stringValue ?? ""
        r.check("× from turn 2's reply asks about “흠”", c.cardShown(p) && msg.contains("흠"), msg)
        ov.card?.confirm.performClick()
        r.check("×: done", await rewindFinished(p))
        dump(p, "after × on turn 2")
        let left = await c.loadTurns(p)
        r.check("×: only turn 1 left", left.map(\.prompt) == ["하이"], left.map(\.prompt).joined(separator: " / "))
        r.check("×: the input is empty, the same claude", inputText(p) == "" && (pid == 0 || p.claudePID == pid), inputText(p) ?? "nil")
        await sleepMs(900)
        await submit(c, p, "다음")
        await waitReply(r, c, p, turn: 2, "the next prompt answered as turn 2", timeout: 60)
        let sent = apiRequest(with: "다음") ?? []
        r.check("Claude sent turn 1 and none of the removed turns", sent.contains { $0.contains("하이") }
                && !sent.contains { $0.contains("흠") || $0.contains("그럼 이건") }, sent.joined(separator: " | "))
    }
    for _ in 0..<3 { p.surface.sendKey(keyCode: 0x08, codepoint: 0x63, control: true); await sleepMs(400) }
    _ = await waitFor(5) { p.claudeSessionID == nil }
    return finish(r, c)
}
