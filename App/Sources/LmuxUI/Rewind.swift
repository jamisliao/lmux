import AppKit
import LmuxTokens
import LmuxTranscript

private typealias T = LmuxTokens

// ✎, × and ⌘Z on a Claude Code turn drive Claude Code's own rewind (Esc Esc), inside the running
// process: subagents, background shells and MCP connections live on. lmux sends one key at a time,
// waits until the menu's parsed selection has changed (any other redraw doesn't count), and only
// presses Return once the selection has held still on exactly the entry or option it expects.
// Only "Restore conversation" is ever chosen, never an option that restores code. Anything
// unexpected backs out with Esc and changes nothing. The user's own input to the pane is held
// meanwhile (`SurfaceView.inputHeld`), and the pane shows its last frame until Claude has redrawn
// the result: the menu is never seen moving.

/// Claude Code's rewind menu as it is drawn (2.1.322; up to 2.1.280 the counts read "↑ 2 more above"
/// and "↓ 1 more below", and ⇧↑ rather than Home went to the first message):
///
///     ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
///        Rewind
///
///        Restore the code and/or conversation to the point before…
///
///         ↑ 2 more
///          what is 6 times 7
///          No code changes
///
///        ❯ (current)
///
///         ↓ 1 more
///        Enter to continue · Esc to cancel
///
/// An entry is the prompt's first line, cut to the pane's width with "…" (a multi-line prompt
/// always ends in "…"). Return on one asks to confirm:
///
///        Confirm you want to restore to the point before you sent this message:
///        │ what is 6 times 7                (up to 4 lines of the prompt, wrapped)
///        │ (6s ago)
///        …
///        ❯ 1. Restore code and conversation    (only when files changed since: the default)
///          2. Restore conversation
///          3. Restore code
///          4. Summarize from here
///        ↓ 5. Summarize up to here             (a list taller than the pane scrolls)
///
/// Without file checkpoints there are no code options, and Return on an entry may restore the
/// conversation right away.
enum RewindMenu {
    enum Screen: Equatable {
        /// No rewind menu on screen.
        case closed
        /// A rewind menu is on screen but can't be read (its title scrolled away, a new layout).
        case open
        /// "Nothing to rewind to yet."
        case nothing
        /// The message list: the highlighted entry, the row it's on, the "↑ / ↓ N more" counts.
        case list(selected: String, row: Int, above: Int, below: Int)
        /// The confirmation: the quoted message (its rows joined), the option labels shown, the
        /// highlighted one.
        case confirm(quote: String, options: [String], selected: Int?)
    }

    static let current = "(current)"
    /// The only option lmux picks: conversation only, files untouched.
    static let restoreConversation = "Restore conversation"
    static let footer = "Enter to continue · Esc to cancel"

    static func read(_ rows: [String]) -> Screen {
        let trimmed = rows.map { $0.trimmingCharacters(in: .whitespaces) }
        // The menu's title row, under its ▔ top edge (the last one: older ones scrolled away).
        guard let title = trimmed.indices.last(where: { i in
            trimmed[i] == "Rewind" && trimmed[max(0, i - 2)..<i].contains { $0.hasPrefix("▔") }
        }) else {
            // The input box is hidden while the menu is up.
            if TurnLocator.locate(rows: rows, turns: []).inputRow != nil { return .closed }
            let open = trimmed.contains { $0.hasPrefix(footer) || $0.hasPrefix("Confirm you want to restore")
                || $0.contains("conversation to the point before") }
            return open ? .open : .closed
        }
        let body = Array(trimmed[(title + 1)...])
        if body.contains(where: { $0.hasPrefix("Nothing to rewind to yet") }) { return .nothing }
        if let c = body.firstIndex(where: { $0.hasPrefix("Confirm you want to restore") }) {
            var quote: [String] = []
            var i = c + 1
            while i < body.count, body[i].isEmpty { i += 1 }
            while i < body.count, body[i].hasPrefix("│") {
                quote.append(String(body[i].dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1
            }
            // The last quoted row is when it was sent, in parentheses: "(6s ago)", "(just now)".
            if let last = quote.last, last.hasPrefix("("), last.hasSuffix(")") { quote.removeLast() }
            var options: [String] = []
            var selected: Int?
            for row in body[i...] {
                var s = Substring(row).drop { "↑↓ ".contains($0) }
                let pointed = s.hasPrefix("❯")
                if pointed { s = s.dropFirst().drop { $0 == " " } }
                guard let dot = s.firstIndex(of: "."), dot > s.startIndex, s[..<dot].allSatisfy(\.isNumber) else { continue }
                if pointed { selected = options.count }
                options.append(s[s.index(after: dot)...].trimmingCharacters(in: .whitespaces))
            }
            return .confirm(quote: quote.joined(separator: "\n"), options: options, selected: selected)
        }
        guard body.contains(where: { $0.contains("to the point before") }) else { return .open }
        let pointed = body.indices.filter { body[$0].hasPrefix("❯ ") }
        guard pointed.count == 1, let row = pointed.first else { return .open }
        // "↑ 2 more" (2.1.3xx), "↑ 2 more above" (2.1.280).
        func more(_ arrow: String) -> Int {
            body.lazy.compactMap { row -> Int? in
                let words = row.split(separator: " ")
                guard words.count >= 3, words[0] == arrow, words[2] == "more",
                      words.count == 3 || words[3] == (arrow == "↑" ? "above" : "below") else { return nil }
                return Int(words[1])
            }.first ?? 0
        }
        return .list(selected: String(body[row].dropFirst(2)).trimmingCharacters(in: .whitespaces),
                     row: title + 1 + row, above: more("↑"), below: more("↓"))
    }

    /// Where the highlighted entry is in the whole list (0 = the oldest message): the "↑ N more above"
    /// count plus the entries drawn above it (each the same height: its text, a file-changes line
    /// with checkpoints, a blank). nil if the rows don't add up.
    static func selectedIndex(_ rows: [String]) -> Int? {
        guard case .list(_, let row, let above, _) = read(rows) else { return nil }
        let trimmed = rows.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let header = trimmed[..<row].lastIndex(where: { $0.contains("to the point before") }),
              let first = (header + 1...row).first(where: { !trimmed[$0].isEmpty && !trimmed[$0].hasPrefix("↑") }),
              row + 1 < rows.count else { return nil }
        let height = trimmed[row + 1].isEmpty ? 2 : 3
        guard (row - first) % height == 0 else { return nil }
        return above + (row - first) / height
    }

    /// A list entry (the prompt's first line, cut with "…") is this prompt.
    static func matches(_ entry: String, prompt: String) -> Bool {
        var e = TurnLocator.norm(entry)
        let cut = e.hasSuffix("…")
        if cut { e = TurnLocator.norm(String(e.dropLast())) }
        let lines = promptLines(prompt)
        let first = TurnLocator.norm(lines.first ?? "")
        guard !e.isEmpty, !first.isEmpty else { return false }
        if cut { return first.hasPrefix(e) }
        // Not cut: the whole first line, and the only line (a longer prompt shows "…").
        return e == first && lines.count == 1
    }

    /// The confirmation's quote (up to 4 lines of the prompt, wrapped at any character) is this
    /// prompt: compared without whitespace, it starts the prompt and is as long as the menu shows.
    static func quoteMatches(_ quote: String, prompt: String) -> Bool {
        let q = quote.filter { !$0.isWhitespace }
        let p = promptLines(prompt).prefix(4).joined().filter { !$0.isWhitespace }
        guard !q.isEmpty, p.hasPrefix(q) else { return false }
        return q.count >= min(p.count, 120)
    }

    /// The prompt as Claude's menu shows it: a `!` shell command (`<bash-input>cmd</bash-input>` in the
    /// transcript) as "! cmd".
    static func shown(_ prompt: String) -> String {
        let t = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<bash-input>"), t.hasSuffix("</bash-input>") else { return prompt }
        return "! " + t.dropFirst("<bash-input>".count).dropLast("</bash-input>".count)
    }

    /// A `!` shell command. Claude Code rewinds to one with its input in shell mode, which clearing the
    /// input doesn't leave (2.1.280): the next thing typed would run as a command. lmux won't.
    static func isShellCommand(_ prompt: String) -> Bool { shown(prompt) != prompt }

    static let shellCommandNote = "Can’t rewind to a ! shell command: Claude Code would leave its input in shell mode."

    static func promptLines(_ prompt: String) -> [String] {
        shown(prompt).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !["[image]", "[document]"].contains($0) }
    }
}

public enum RewindOutcome: Equatable, Sendable {
    case done
    case failed(String)
}

extension LmuxController {
    enum RewindMode {
        /// ✎: the prompt goes back into Claude's input for editing (never sent).
        case edit
        /// ×: the input is left empty.
        case remove
    }

    /// How long Claude Code counts two Esc presses as one double press (Esc Esc).
    static let doubleEscWindow: TimeInterval = 0.8

    // MARK: - Confirm card

    func requestRewind(_ pane: Pane, turnIndex: Int, edit: Bool) {
        guard !pane.runsCodex, !pane.busy, let turn = pane.hover.turns.first(where: { $0.index == turnIndex }) else { return }
        if turn.beforeCompaction {
            showNote(pane, Self.compactedNote,
                     symbol: "exclamationmark.triangle", color: T.Colors.stateFailed.nsColor)
            return
        }
        if RewindMenu.isShellCommand(turn.prompt) {
            showNote(pane, RewindMenu.shellCommandNote, symbol: "exclamationmark.triangle", color: T.Colors.stateFailed.nsColor)
            return
        }
        let later = pane.hover.turns.filter { $0.index > turn.index }.count
        var detail: String
        if edit {
            detail = "Claude rewinds to just before it and puts the text back in the input."
            if later > 0 { detail += " Removes this message and everything after it." }
        } else {
            detail = later > 0 ? "Removes this message and everything after it from the conversation."
                               : "Removes this message from the conversation."
        }
        detail += " Claude keeps running."
        if claudeWorking(pane) { detail += " Claude is working and will be stopped first." }
        else if claudeAsking(pane) { detail += " Claude is waiting for your answer; that’s declined first." }
        let files = Set(pane.hover.turns.filter { $0.index >= turn.index }.flatMap(\.editedFiles)).sorted()
        if !files.isEmpty {
            let names = files.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            detail += " Files changed (\(names)\(files.count > 3 ? " and \(files.count - 3) more" : "")) stay as they are."
        }
        let first = turn.firstLine.count > 60 ? String(turn.firstLine.prefix(60)) + "…" : turn.firstLine
        showCard(pane, message: Self.bold(edit ? "Edit " : "Remove ", "“\(first)”", "?"), detail: detail,
                 confirmTitle: edit ? "Edit" : "Remove",
                 onConfirm: { [weak self, weak pane] in
                     guard let self, let pane else { return }
                     Task { await self.rewind(pane, turnUuid: turn.uuid, mode: edit ? .edit : .remove) }
                 })
    }

    // MARK: - Driving Claude Code's rewind

    /// Rewind the Claude session in `pane` to just before turn `turnUuid`, in place.
    @discardableResult
    func rewind(_ pane: Pane, turnUuid: String, mode: RewindMode) async -> RewindOutcome {
        guard !pane.busy else { return .failed("busy") }
        guard !pane.runsCodex else { return .failed("rewind is Claude Code only") }
        guard pane.claudeSessionID != nil else { return .failed("no Claude session in this pane") }
        // Not busy again until `finishRewind`.
        pane.busy = true
        hideHoverActions(pane)
        dismissCard(pane)
        if pendingUndo?.paneID == pane.id { clearPendingUndo(); hideToast(pane) }
        holdInput(pane)
        var drive = RewindDrive(lastEsc: pane.lastEscKey)
        let outcome = await driveRewind(pane, turnUuid: turnUuid, mode: mode, &drive)
        await finishRewind(pane, outcome, note: drive.note, mayHaveRemoved: drive.mayHaveRemoved)
        return outcome
    }

    /// The user's input stays out of the pane, its frame held (a calm "Rewinding…" past a second:
    /// the last turn is done before then, with nothing to flash), and its viewport at the bottom
    /// (where lmux reads).
    private func holdInput(_ pane: Pane) {
        pane.rewindStoppedHidden = false
        pane.pendingRewindNote = nil
        pane.surface.inputHeld = true
        freezeFrame(pane)
        _ = pane.surface.performBindingAction("scroll_to_bottom")
        // This rewind's, not a later one's.
        let token = UUID()
        pane.rewindToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak pane] in
            guard let self, let pane, pane.busy, pane.rewindToken == token, pane.view.overlay.toast == nil else { return }
            self.showNote(pane, "Rewinding…", symbol: "arrow.uturn.backward", duration: nil)
        }
    }

    /// `note`: what to say instead of the usual ("Couldn’t rewind…" on a failure, nothing on success).
    /// The pane shows itself again once Claude's redraw is over; then the turns, the hover pill and
    /// the input label are read again right away.
    private func finishRewind(_ pane: Pane, _ outcome: RewindOutcome, note: String? = nil, mayHaveRemoved: Bool = false) async {
        pane.rewindToken = nil
        await unfreezeFrame(pane)
        // (Also when no frame was held: the terminal is never left hidden.)
        pane.surface.alphaValue = 1
        pane.surface.inputHeld = false
        pane.busy = false
        // Hidden meanwhile (its tab or workspace switched, another pane zoomed): lmux stopped without
        // a key. The note waits until the pane shows again, and so does closing a menu left open.
        let stopped = pane.rewindStoppedHidden
        if stopped, RewindMenu.read(screenRows(pane)) != .closed { pane.rewindMenuLeftOpen = true }
        if case .failed(let why) = outcome {
            log("rewind failed: \(why)")
            let text = stopped
                ? (mayHaveRemoved ? "Rewind stopped while this pane was hidden; check Claude’s conversation."
                                  : "Rewind stopped while this pane was hidden; nothing was removed.")
                : note ?? Self.failureNote(why)
            pane.pendingRewindNote = (text, true)
        } else if let note {
            pane.pendingRewindNote = (note, false)
        } else {
            pane.pendingRewindNote = nil
        }
        hideToast(pane)
        if onScreen(pane) { showPendingRewindNote(pane) }
        scheduleOverlayRefresh(pane, delay: 0)
        if let point = pane.surface.lastMousePoint { paneMouseMoved(pane, point) }
    }

    /// What a failed rewind tells the user: the reason when lmux knows one the user can act on,
    /// else Claude Code's own Esc Esc as the way out.
    static func failureNote(_ why: String) -> String {
        switch why {
        case "compacted": return compactedNote
        case "turn not found": return "Couldn’t rewind: that message is no longer in Claude’s session."
        case "Claude has queued messages": return "Couldn’t rewind: Claude has queued messages. Clear them first."
        case "Claude’s input has unsent text": return "Couldn’t rewind: Claude’s input has unsent text. Clear it first."
        case "Claude’s input has unsent text or queued messages":
            return "Couldn’t rewind: Claude’s input has unsent text or queued messages. Clear them first."
        case "Claude’s input box isn’t on screen": return "Couldn’t rewind: Claude’s input box isn’t on screen."
        default: return "Couldn’t rewind; use Esc Esc in Claude Code."
        }
    }

    static let compactedNote = "Can’t rewind this message: it’s from before Claude compacted the conversation."

    /// Claude is waiting on a dialog of its own (a permission, a question, a plan to approve): its
    /// input box is hidden under it, and Esc declines it, as the user's own Esc would.
    func claudeAsking(_ pane: Pane) -> Bool {
        if case .needsInput = pane.agent.state { return true }
        return false
    }

    /// The pane shows again after a rewind stopped while it was hidden: Claude's menu left open is
    /// closed now (Esc, input held meanwhile: a Return there could restore code), then the note.
    func showPendingRewindNote(_ pane: Pane) {
        if pane.rewindMenuLeftOpen, !pane.busy {
            pane.rewindMenuLeftOpen = false
            pane.busy = true
            pane.surface.inputHeld = true
            Task {
                _ = await self.backOut(pane, "shown again with its menu open", waitLate: false)
                pane.surface.inputHeld = false
                pane.busy = false
                self.showPendingRewindNote(pane)
            }
            return
        }
        guard let (text, failed) = pane.pendingRewindNote else { return }
        pane.pendingRewindNote = nil
        if failed {
            showNote(pane, text, symbol: "exclamationmark.triangle", color: T.Colors.stateFailed.nsColor, duration: 6)
        } else {
            showNote(pane, text, duration: 6)
        }
    }

    // MARK: - The held frame

    /// Cover the pane with its current frame (nothing if it has none yet).
    private func freezeFrame(_ pane: Pane) {
        let ov = pane.view.overlay
        guard ov.freeze == nil else { return }
        guard let v = FrozenFrameView(surface: pane.surface) else { log("rewind: no frame to hold"); return }
        ov.addSubview(v, positioned: .below, relativeTo: ov.subviews.first)
        ov.freeze = v
        v.frame = ov.bounds
        // The live terminal hidden under it (a translucent background would show it through).
        pane.surface.alphaValue = 0
    }

    /// Claude's redraw is over (its rows unchanged for 100ms, 600ms at most: a ticking footer never
    /// settles), then one more frame for the renderer: the held frame fades out over the new one.
    private func unfreezeFrame(_ pane: Pane) async {
        guard let v = pane.view.overlay.freeze else { return }
        var last = screenRows(pane), since = Date()
        let end = Date().addingTimeInterval(0.6)
        while Date() < end, Date().timeIntervalSince(since) < 0.1, onScreen(pane) {
            await sleepMs(15)
            let now = screenRows(pane)
            if now != last { last = now; since = Date() }
        }
        await sleepMs(20)
        pane.view.overlay.freeze = nil
        pane.surface.alphaValue = 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            v.animator().alphaValue = 0
        }, completionHandler: { v.removeFromSuperview() })
    }

    /// What one rewind has done to the pane so far.
    struct RewindDrive {
        /// When lmux (or the user, before) last pressed a lone Esc: the next Esc Esc waits out
        /// Claude's double-press window.
        var lastEsc: Date?
        /// lmux pressed Esc to stop Claude.
        var interrupted = false
        /// A note to show instead of the usual one when it's over.
        var note: String?
        /// Claude may have removed turns already (it took the last one back, or a Return went to the menu).
        var mayHaveRemoved = false
    }

    /// How long Claude's input box must hold still before lmux reads Claude as idle at its prompt,
    /// when no Esc is in play (with one, the double-press window).
    static let idleQuiet: TimeInterval = 0.15

    /// The steps, on a busy pane whose input is held.
    private func driveRewind(_ pane: Pane, turnUuid: String, mode: RewindMode, _ d: inout RewindDrive) async -> RewindOutcome {
        var turns = await loadTurns(pane)
        guard let pos = turns.firstIndex(where: { $0.uuid == turnUuid }) else { return .failed("turn not found") }
        // Compacted into Claude's summary: not in its menu.
        guard !turns[pos].beforeCompaction else { return .failed("compacted") }
        guard !RewindMenu.isShellCommand(turns[pos].prompt) else { d.note = RewindMenu.shellCommandNote; return .failed("a shell command") }
        let prompt = turns[pos].prompt
        log("rewind \(turnUuid.prefix(8)) mode=\(mode) working=\(claudeWorking(pane))")

        // 1) A draft in Claude's input is the user's: refused before any key (Esc Esc would clear it).
        //    Under a dialog of Claude's the box is hidden: a draft there shows (and is refused) in step 3.
        func dialogUp(_ rows: [String]) -> Bool { claudeAsking(pane) && Self.inputText(rows) == nil }
        if !d.interrupted {
            let rows = screenRows(pane)
            // Esc with queued prompts sends them: nothing is pressed then.
            if Self.queuedPrompts(rows) { return .failed("Claude has queued messages") }
            let draft = Self.inputText(rows)
            if draft == nil, !dialogUp(rows) { return .failed("Claude’s input box isn’t on screen") }
            if let draft, !draft.isEmpty { return .failed("Claude’s input has unsent text") }
        }
        // 2) Claude idle at its prompt. Working: Esc, as Claude's own first Esc would, then a still screen.
        //    Waiting on a dialog for this turn: Esc declines it and the turn stops the same way.
        //    (Past the user's own Esc's double-press window first: lmux's would make it Esc Esc.)
        func stoppable(_ rows: [String]) -> Bool { claudeWorking(pane) || Self.screenWorking(rows) || dialogUp(rows) }
        if !d.interrupted, stoppable(screenRows(pane)) {
            await waitEscWindow(&d)
            if stoppable(screenRows(pane)) { pressEsc(pane, &d) }
            d.interrupted = true
            // A dialog just shown may not take a key yet: Esc again while it's still up, each one
            // past the double-press window (never an Esc Esc at the prompt it leaves).
            for _ in 0..<3 where dialogUp(screenRows(pane)) {
                guard await waitScreen(pane, Self.doubleEscWindow + 0.1, { !dialogUp($0) }) == nil, dialogUp(screenRows(pane)) else { break }
                log("rewind: Claude's dialog still up, Esc again")
                pressEsc(pane, &d)
            }
        }
        guard await waitIdle(pane, 8, afterEsc: d.lastEsc.map { Date().timeIntervalSince($0) < Self.doubleEscWindow + 0.1 } ?? false) != nil else {
            // At most a lone Esc was pressed here: no late menu to wait for.
            return await backOut(pane, "Claude is not at its prompt", waitLate: false)
        }
        // Stopped (by an Esc) and idle at its prompt: the turn is over. Claude sends no hook for that,
        // so the pane would go on saying it works or waits for an answer.
        if d.interrupted, pane.agent.usageLimitResets == nil, pane.agent.state == .running || claudeAsking(pane) {
            pane.agent.userInterrupted()
            schedulePaneChrome(pane)
        }

        // 3) Esc right after an answerless turn makes Claude take that turn back by itself, its text in
        //    the input: the last turn is gone already. The target: done. An older one: clear it, go on.
        if let text = Self.idleInput(screenRows(pane)), !text.isEmpty {
            let last = turns[turns.count - 1].prompt
            guard d.interrupted, RewindMenu.matches(text, prompt: last) || TurnLocator.matches(row: text, prompt: last) else {
                return .failed("Claude’s input has unsent text")
            }
            log("rewind: Claude took the last turn back itself")
            if pos == turns.count - 1 { return await rewound(pane, turnUuid: turnUuid, prompt: prompt, mode: mode, &d) }
            // Gone from the conversation already, whatever happens next.
            pane.rewoundFrom = turns.removeLast().uuid
            d.mayHaveRemoved = true
            pane.hover = HoverCache()
            await waitEscWindow(&d)
            await pressEscTwice(pane, &d)
            guard await waitScreen(pane, 3, { Self.idleInput($0) == "" }) != nil else { return await backOut(pane, "input not cleared") }
        }

        // 4) Open the menu: "(current)" highlighted.
        await waitEscWindow(&d)
        await pressEscTwice(pane, &d)
        var state = await waitMenu(pane, 4)
        guard case .list(let first, _, _, _) = state, first == RewindMenu.current else {
            return await backOut(pane, "the rewind menu didn't open as expected: \(state)")
        }

        // 5) One entry at a time, each the turn expected there, to the target: up from "(current)"
        //    (the newest first), or, when the target is nearer the top, Home (⇧↑ before 2.1.3xx) to the
        //    oldest entry and down from there. Identical prompts are told apart by where they are, not by their text.
        let listed = turns.filter { !$0.beforeCompaction }
        let want = pos - turns[..<pos].filter(\.beforeCompaction).count
        guard want < listed.count else { return await backOut(pane, "the turn isn't in the list") }
        if want + 1 < turns.count - pos {
            var top = await press(pane, .top, from: state)
            if top == nil, onScreen(pane) { top = await press(pane, .topBefore3xx, from: state) }
            guard let top else { return await backOut(pane, "the list didn't go to the top") }
            state = top
            guard case .list(let selected, _, _, _) = state, RewindMenu.matches(selected, prompt: listed[0].prompt),
                  RewindMenu.selectedIndex(screenRows(pane)) == 0 else {
                return await backOut(pane, "the top entry isn't turn 1: \(state)")
            }
            for k in stride(from: 1, through: want, by: 1) {
                guard let next = await press(pane, .down, from: state) else { return await backOut(pane, "the list didn't move") }
                state = next
                guard case .list(let selected, _, _, _) = state, RewindMenu.matches(selected, prompt: listed[k].prompt) else {
                    return await backOut(pane, "entry \(k + 1) from the top isn't its turn: \(state)")
                }
            }
        } else {
            for depth in 1...(turns.count - pos) {
                guard let next = await press(pane, .up, from: state) else { return await backOut(pane, "the list didn't move") }
                state = next
                guard case .list(let selected, _, _, _) = state,
                      RewindMenu.matches(selected, prompt: turns[turns.count - depth].prompt) else {
                    return await backOut(pane, "entry \(depth) isn't turn \(turns.count - depth + 1): \(state)")
                }
            }
        }
        // …and where it is in the whole list agrees with the transcript (no turn one side has and the other hasn't).
        // One read: the settled selection, still the target's text, at the target's place in the whole list.
        let last = screenRows(pane)
        guard Self.selection(RewindMenu.read(last)) == Self.selection(state),
              case .list(let shown, _, _, _) = RewindMenu.read(last), RewindMenu.matches(shown, prompt: prompt),
              let at = RewindMenu.selectedIndex(last), at == want else {
            return await backOut(pane, "the entry is message \(RewindMenu.selectedIndex(last).map(String.init) ?? "?") of the list, not \(want)")
        }

        // 6) Return on it: the confirmation, whose quote must be this prompt.
        guard pressReturn(pane) else { return await backOut(pane, "hidden") }
        // (Without file checkpoints Claude may restore right away.)
        d.mayHaveRemoved = true
        guard let after = await waitScreen(pane, 4, { r in
            if case .confirm = RewindMenu.read(r) { return true }
            return RewindMenu.read(r) == .closed && Self.idleInput(r) != nil
        }) else { return await backOut(pane, "no confirmation") }
        state = RewindMenu.read(after)
        guard case .confirm(let quote, _, _) = state else {
            // Restored without asking (no file checkpoints): it only counts with the prompt back in the input.
            let back = await waitIdle(pane, 2).flatMap(Self.idleInput) ?? ""
            guard RewindMenu.matches(back, prompt: prompt) || TurnLocator.matches(row: back, prompt: prompt) else {
                return await backOut(pane, "the menu closed without a confirmation")
            }
            return await rewound(pane, turnUuid: turnUuid, prompt: prompt, mode: mode, &d)
        }
        guard RewindMenu.quoteMatches(quote, prompt: prompt) else {
            return await backOut(pane, "the confirmation quotes another message: \(quote)")
        }

        // 7) Down / up to "Restore conversation" (with file checkpoints the default is "Restore code and
        //    conversation"), one key at a time, each waited out; Return only once it has held still.
        for _ in 0..<8 {
            guard case .confirm(_, let opts, let sel?) = state, let want = opts.firstIndex(of: RewindMenu.restoreConversation) else {
                return await backOut(pane, "no \(RewindMenu.restoreConversation) option: \(state)")
            }
            if sel == want { break }
            guard let next = await press(pane, sel > want ? .up : .down, from: state) else { return await backOut(pane, "the option didn't move") }
            state = next
        }
        // Held still a little longer here: Return on it is the one step that can't be backed out of.
        guard case .confirm(_, let opts, let sel?) = state, opts[sel] == RewindMenu.restoreConversation,
              await settled(pane, state, for: 0.15) else {
            return await backOut(pane, "\(RewindMenu.restoreConversation) not highlighted")
        }
        // One read right before Return: still exactly "Restore conversation", still the same selection.
        guard case .confirm(_, let now, let nowSel?) = RewindMenu.read(screenRows(pane)),
              now[nowSel] == RewindMenu.restoreConversation, Self.selection(.confirm(quote: "", options: now, selected: nowSel))
                == Self.selection(.confirm(quote: "", options: opts, selected: sel)) else {
            return await backOut(pane, "\(RewindMenu.restoreConversation) not highlighted at Return")
        }
        guard pressReturn(pane) else { return await backOut(pane, "hidden") }
        // "Restore conversation" is chosen: from here on no key is pressed (an Esc could cut the restore
        // short). Claude has rewound once the menu is gone, however long that takes.
        pane.rewoundFrom = turnUuid
        guard await waitScreen(pane, 30, { RewindMenu.read($0) == .closed && Self.idleInput($0) != nil }) != nil else {
            if !onScreen(pane) {
                log("rewind: restore chosen, pane hidden")
                if mode == .remove { d.note = "Rewound. Clear the message from Claude’s input yourself." }
                return .done
            }
            log("rewind: restore chosen, Claude not back at its prompt yet")
            d.note = "Rewound. Claude is still catching up."
            return .done
        }
        return await rewound(pane, turnUuid: turnUuid, prompt: prompt, mode: mode, &d)
    }

    /// Claude rewound: lmux hides the turn and the ones after it (Claude only writes its new
    /// branch with the next prompt), then puts the input the way the action wants it. Claude
    /// puts the prompt back in the same step as the rewind; lmux never types it.
    private func rewound(_ pane: Pane, turnUuid: String, prompt: String, mode: RewindMode, _ d: inout RewindDrive) async -> RewindOutcome {
        pane.rewoundFrom = turnUuid
        pane.hover = HoverCache()
        _ = await loadTurns(pane)
        titleAfterRewind(pane)
        if mode == .remove {
            let leftOver = "Rewound. Clear the message from Claude’s input yourself."
            // Claude puts the prompt back as its menu closes.
            guard let back = await waitScreen(pane, 1.5, { !(Self.idleInput($0) ?? "").isEmpty }) else {
                if !onScreen(pane) { d.note = leftOver; log("rewind: rewound, pane hidden before the input was cleared") }
                else { log("rewind: the prompt didn't come back to the input in 1.5s") }
                log("rewind done \(turnUuid.prefix(8))")
                return .done
            }
            // Ctrl+U clears a plain one-row prompt at once. Not one with pasted text or an image
            // (Claude keeps those apart from the text) and not one on several rows: Esc Esc there.
            let box = Self.idleBox(back) ?? []
            if box.filter({ !$0.isEmpty }).count == 1, RewindMenu.promptLines(prompt).count == prompt.split(separator: "\n").count,
               !box.contains(where: { $0.contains("[Pasted text") || $0.contains("[Image") }) {
                // However late it's drawn: the box changes.
                if send(pane, 0x20, 0x75, control: true), let after = await waitScreen(pane, 1.5, { Self.idleBox($0).map { $0 != box } ?? false }), Self.idleInput(after) == "" {
                    log("rewind done \(turnUuid.prefix(8))")
                    return .done
                }
            }
            // Esc Esc (Claude Code's own shortcut) past the double-press window of the pair that opened
            // the menu, and only on a box that's still filled: on an empty one it opens the menu.
            await waitEscWindow(&d)
            let now = screenRows(pane)
            guard onScreen(pane), let left = Self.idleInput(now), !left.isEmpty else {
                if !onScreen(pane) || Self.idleInput(now) != "" { d.note = leftOver; log("rewind: rewound, input not cleared") }
                log("rewind done \(turnUuid.prefix(8))")
                return .done
            }
            await pressEscTwice(pane, &d)
            guard await waitScreen(pane, 3, { Self.idleInput($0) == "" }) != nil else {
                if onScreen(pane) { _ = await backOut(pane, "input not cleared") }
                d.note = leftOver
                log("rewind: rewound, input not cleared")
                return .done
            }
        }
        log("rewind done \(turnUuid.prefix(8))")
        return .done
    }

    /// Something didn't look as expected: Esc until no menu is left. Nothing was changed.
    private func backOut(_ pane: Pane, _ why: String, waitLate: Bool = true) async -> RewindOutcome {
        log("rewind: backing out (\(why))")
        // A menu that opens late (a slow Claude) is closed too: input stays held until then.
        if waitLate, RewindMenu.read(screenRows(pane)) == .closed { _ = await waitScreen(pane, 3, { RewindMenu.read($0) != .closed }) }
        // Never into a hidden pane (its waits end at once: the Escs would come in a burst, a pair of
        // them opening the menu again).
        for _ in 0..<4 where RewindMenu.read(screenRows(pane)) != .closed {
            guard send(pane, 0x35, 0x1B) else { break }
            _ = await waitScreen(pane, 1, { RewindMenu.read($0) == .closed })
        }
        return .failed(why)
    }

    /// Claude's own title may carry the removed turns' words: read it again once Claude writes.
    func titleAfterRewind(_ pane: Pane) {
        guard !pane.titleState.isManual, pane.titleState.title != nil else { return }
        scheduleTitleRefresh(pane, delay: 0.5)
    }

    // MARK: - Screen and keys

    func screenRows(_ pane: Pane) -> [String] { pane.surface.viewportRows().rows.map(\.text) }

    /// Poll the pane's rows (every 15ms, only while lmux drives it) until `cond` holds; nil after `timeout` seconds.
    func waitScreen(_ pane: Pane, _ timeout: TimeInterval, _ cond: ([String]) -> Bool) async -> [String]? {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            // Its tab hidden or closed (or its workspace closed) meanwhile: stop, the caller backs out.
            guard onScreen(pane) else { return nil }
            let rows = screenRows(pane)
            if cond(rows) { return rows }
            await sleepMs(15)
        } while Date() < end
        return nil
    }

    /// Claude idle at its prompt, its input box (where it is, what it holds) unchanged for `quiet`, or
    /// after an Esc for longer than the double-press window: an Esc that stopped it has been handled
    /// and its redraw is over. Only the box counts: a footer that ticks (background tasks) never settles.
    func waitIdle(_ pane: Pane, _ timeout: TimeInterval, afterEsc: Bool = true, quiet: TimeInterval? = nil) async -> [String]? {
        let hold = quiet ?? (afterEsc ? Self.doubleEscWindow + 0.1 : Self.idleQuiet)
        let end = Date().addingTimeInterval(timeout)
        var since: (box: String, at: Date)?
        repeat {
            guard onScreen(pane) else { return nil }
            let rows = screenRows(pane)
            let box = Self.idleInput(rows).map { "\(TurnLocator.locate(rows: rows, turns: []).inputRow ?? -1) \($0)" }
            if box == nil {
                since = nil
            } else if let s = since, s.box == box {
                if Date().timeIntervalSince(s.at) >= hold { return rows }
            } else {
                since = (box!, Date())
            }
            await sleepMs(15)
        } while Date() < end
        return nil
    }

    /// The menu once it can be read (or nil = closed / unreadable after `timeout`).
    func waitMenu(_ pane: Pane, _ timeout: TimeInterval) async -> RewindMenu.Screen {
        let rows = await waitScreen(pane, timeout) {
            switch RewindMenu.read($0) { case .list, .confirm, .nothing: return true; default: return false }
        }
        return rows.map(RewindMenu.read) ?? RewindMenu.read(screenRows(pane))
    }

    enum MenuKey { case up, down, top, topBefore3xx }

    /// One ↑ / ↓ / Home (Claude's "first message"; ⇧↑ up to 2.1.280), then the menu as soon as its parsed selection
    /// differs from `from` (a clock or status redraw doesn't count, nor a frame read half drawn) and
    /// has held still. nil if it never moves.
    func press(_ pane: Pane, _ key: MenuKey, from: RewindMenu.Screen) async -> RewindMenu.Screen? {
        let keyCode: UInt32 = switch key { case .down: 0x7D; case .top: 0x73; case .up, .topBefore3xx: 0x7E }  // ↓, Home, ↑
        guard send(pane, keyCode, 0, shift: key == .topBefore3xx) else { return nil }
        guard let rows = await waitScreen(pane, 2, { r in
            let s = RewindMenu.read(r)
            switch s {
            case .list, .confirm: return Self.selection(s) != Self.selection(from)
            case .open: return false
            default: return true
            }
        }) else { return nil }
        let s = RewindMenu.read(rows)
        guard await settled(pane, s) else { return nil }
        return s
    }

    /// What a key moves: the highlighted entry (text, row, scroll) or option.
    static func selection(_ s: RewindMenu.Screen) -> String {
        switch s {
        case .list(let t, let row, let above, let below): return "list \(row) \(above) \(below) \(t)"
        case .confirm(_, let opts, let sel): return "confirm \(sel.map { "\($0) \(opts[$0])" } ?? "-")"
        default: return "\(s)"
        }
    }

    /// How long a selection must hold still before lmux trusts it (Claude draws a key's effect in
    /// one frame; this outlasts a frame read half drawn several times over).
    static let settleWindow: TimeInterval = 0.08

    /// The selection stays as it is for `settleWindow` (no key still on its way). A frame read half
    /// drawn (no menu readable) is read again; any other selection is a move lmux didn't ask for.
    func settled(_ pane: Pane, _ s: RewindMenu.Screen, for window: TimeInterval? = nil) async -> Bool {
        let window = window ?? Self.settleWindow
        let want = Self.selection(s)
        let start = Date()
        while Date().timeIntervalSince(start) < window {
            await sleepMs(15)
            guard onScreen(pane) else { return false }
            let now = RewindMenu.read(screenRows(pane))
            if now == .open { continue }
            guard Self.selection(now) == want else { return false }
        }
        for _ in 0..<3 {
            let now = RewindMenu.read(screenRows(pane))
            if now != .open { return Self.selection(now) == want }
            await sleepMs(15)
        }
        return false
    }

    /// The pane is on screen: its leaf's shown tab, in the selected workspace, not behind another
    /// pane's zoom. Anything else is hidden: no rewind key goes to it.
    func onScreen(_ pane: Pane) -> Bool {
        guard let ws = pane.workspace, ws === model.selected, ws.visiblePanes.contains(where: { $0 === pane }) else { return false }
        return ws.zoomedPane == nil || ws.zoomedPane === pane
    }

    /// The text in Claude's input box (no menu open), working or not; nil without an input box.
    static func inputText(_ rows: [String]) -> String? {
        // Its first non-empty line (what lmux compares); "" only when the whole box is empty.
        inputLines(rows).map { $0.first { !$0.isEmpty } ?? "" }
    }

    /// Every row of Claude's input box, idle (no menu open, not working); nil otherwise.
    static func idleBox(_ rows: [String]) -> [String]? { screenWorking(rows) ? nil : inputLines(rows) }

    /// Every row of Claude's input box (no menu open), trimmed; nil without an input box.
    static func inputLines(_ rows: [String]) -> [String]? {
        guard RewindMenu.read(rows) == .closed, let i = TurnLocator.locate(rows: rows, turns: []).inputRow else { return nil }
        var lines = [rows[i].trimmingCharacters(in: .whitespaces) == "❯" ? ""
                     : TurnLocator.marked(rows[i], TurnLocator.promptMarkers)?.trimmingCharacters(in: .whitespaces) ?? ""]
        // A multi-line draft goes on below, up to the box's bottom rule.
        for r in rows[(i + 1)...] {
            if TurnLocator.isRule(r) { break }
            lines.append(r.trimmingCharacters(in: .whitespaces))
        }
        return lines
    }

    /// Prompts queued while Claude works ("Press up to edit queued messages", "… to send now"): an Esc
    /// would send them.
    static func queuedPrompts(_ rows: [String]) -> Bool {
        rows.contains { $0.contains("to edit queued messages") || $0.contains("to send now") }
    }

    /// Claude shows it's working: "esc to interrupt" in its footer or on the spinner line above the input.
    static func screenWorking(_ rows: [String]) -> Bool {
        let rule = TurnLocator.locate(rows: rows, turns: []).inputRule ?? rows.count
        return rows[max(0, rule - 8)...].contains { $0.contains("esc to interrupt") }
    }

    /// The text in Claude's input box when Claude is idle there (no menu open, not working), else nil.
    static func idleInput(_ rows: [String]) -> String? {
        guard !screenWorking(rows) else { return nil }
        return inputText(rows)
    }

    /// Every key of a rewind: none into a pane that's no longer shown (false then).
    @discardableResult
    func send(_ pane: Pane, _ keyCode: UInt32, _ codepoint: UInt32, control: Bool = false, shift: Bool = false) -> Bool {
        guard onScreen(pane) else {
            log("rewind: pane hidden, no key sent")
            pane.rewindStoppedHidden = true
            return false
        }
        pane.surface.sendKey(keyCode: keyCode, codepoint: codepoint, control: control, shift: shift)
        return true
    }

    @discardableResult
    func pressEsc(_ pane: Pane, _ d: inout RewindDrive) -> Bool {
        guard send(pane, 0x35, 0x1B) else { return false }
        d.lastEsc = Date()
        return true
    }

    /// Past Claude Code's double-press window since lmux's last lone Esc, so the next Esc Esc is its own.
    func waitEscWindow(_ d: inout RewindDrive) async {
        guard let last = d.lastEsc else { return }
        let left = Self.doubleEscWindow + 0.1 - Date().timeIntervalSince(last)
        if left > 0 { await sleepMs(Int(left * 1000)) }
    }

    /// Claude Code's double press: the second Esc well inside its window, but not in the same read.
    func pressEscTwice(_ pane: Pane, _ d: inout RewindDrive) async {
        guard send(pane, 0x35, 0x1B) else { return }
        d.lastEsc = Date()
        await sleepMs(150)
        guard send(pane, 0x35, 0x1B) else { return }
        // A pair, not a lone Esc: the window starts over only after it.
        d.lastEsc = Date()
    }

    @discardableResult
    func pressReturn(_ pane: Pane) -> Bool { send(pane, 0x24, 0x0D) }

    // MARK: - Undo send

    /// Undo send: Esc right away if Claude works on it, then rewind that turn (prompt back in the
    /// input). The turn is the first with that text written at or after `since` (the transcript's
    /// size when Return was pressed), so an older identical prompt is never the one taken back.
    @discardableResult
    func undo(prompt: String, in pane: Pane, since: Int = 0) async -> RewindOutcome {
        // Busy since ⌘Z; the user's input is held from here on.
        holdInput(pane)
        var d = RewindDrive(lastEsc: pane.lastEscKey)
        let rows0 = screenRows(pane)
        if Self.queuedPrompts(rows0) || !(Self.inputText(rows0) ?? "").isEmpty {
            await finishRewind(pane, .failed("Claude’s input has unsent text or queued messages"))
            return .failed("Claude’s input has unsent text or queued messages")
        }
        let want = TurnLocator.normText(prompt)
        if pane.agent.state == .running {
            await waitEscWindow(&d)
            // Stopped: by lmux's Esc, or by the user's own just before.
            if pane.agent.state != .running || pressEsc(pane, &d) { d.interrupted = true }
        }
        var found: TranscriptIndex.Turn?
        for _ in 0..<20 {
            let turns = await loadTurns(pane)
            log("undo: since=\(since) turns=\(turns.map { "\($0.promptOffset):" + TurnLocator.norm($0.prompt).prefix(30) })")
            found = turns.first { t in
                let have = TurnLocator.normText(t.prompt)
                return t.promptOffset >= since && (have == want || (t.promptIsTruncated && want.hasPrefix(have)))
            }
            if found != nil { break }
            await sleepMs(150)
        }
        guard let t = found else {
            let note = d.interrupted ? "Stopped Claude, but couldn’t find that message to undo it."
                                     : "Couldn’t find that message in the session to undo it."
            await finishRewind(pane, .failed("prompt not found"), note: note)
            return .failed("prompt not found")
        }
        hideHoverActions(pane)
        dismissCard(pane)
        let outcome = await driveRewind(pane, turnUuid: t.uuid, mode: .edit, &d)
        await finishRewind(pane, outcome, note: d.note, mayHaveRemoved: d.mayHaveRemoved)
        return outcome
    }
}
