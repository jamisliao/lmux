import AppKit
import Carbon
import Darwin
import LmuxHooks
import LmuxTerminal
import LmuxTokens
import LmuxTranscript

private typealias T = LmuxTokens

// Message actions on Claude Code panes (R7-R10):
// - hover a turn: ✎ edit & resend, × remove (not on the first turn); Copy original (⌥⌘C = last reply)
// - undo-send toast (⌘Z), the "sending to" label
// - ⌘W asks before killing a running process
//
// ✎, × and Undo use Claude Code's own rewind, in the running Claude (Rewind.swift).

/// Screen/transcript cache behind the hover actions of one pane.
struct HoverCache {
    var rows: [SurfaceView.Row] = []
    var rowHeight: CGFloat = 0
    var map: TurnLocator.Map?
    var readAt: Date = .distantPast
    /// Turn list from the pane's `TranscriptIndex` (prompts capped, replies read on demand).
    var turns: [TranscriptIndex.Turn] = []
    var stamp: FileStamp?
    var loadedPath: String?
    var loading = false
    var point: NSPoint?
    /// Times the viewport was read and mapped to turns (hover reuses the map for 0.4s).
    var locates = 0
    /// A text-selection drag started in this pane: no hover actions until the next move.
    var selecting = false
}

struct FileStamp: Equatable, Sendable {
    let size: Int
    let mtime: Date
    static func of(_ path: String) -> FileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileStamp(size: (a[.size] as? NSNumber)?.intValue ?? 0, mtime: a[.modificationDate] as? Date ?? .distantPast)
    }
}

struct PendingUndo {
    let paneID: String
    let prompt: String
    let deadline: Date
    /// Transcript size when Return was pressed: the turn to undo starts at or after it, so
    /// an older turn with the same text ("yes", "continue") is never the one removed.
    let sinceOffset: Int
    var timer: Timer?
}

/// One incremental `TranscriptIndex` per pane, used on one background queue only: hover
/// and titles never parse on the main thread, and a repeated read only parses what
/// Claude appended since (a 50MB transcript is read once, then in kilobytes).
final class TranscriptCache: @unchecked Sendable {
    struct Snapshot: Sendable {
        let turns: [TranscriptIndex.Turn]
        let stamp: FileStamp?
        let customTitle: String?
        let aiTitle: String?
        let bytesParsed: Int
        let fullReads: Int
    }

    let queue = DispatchQueue(label: "lmux.transcripts", qos: .userInitiated)
    private var byPane: [String: TranscriptIndex] = [:]  // queue only
    /// Codex panes: their rollout reader (`CodexRollout`, same turn shape).
    private var codexByPane: [String: CodexRollout] = [:]  // queue only

    private func index(_ pane: String, _ path: String) -> TranscriptIndex {
        if let i = byPane[pane], i.url.path == path { return i }
        let i = TranscriptIndex(url: URL(fileURLWithPath: path))
        byPane[pane] = i
        return i
    }

    private func rollout(_ pane: String, _ path: String) -> CodexRollout {
        if let r = codexByPane[pane], r.url.path == path { return r }
        let r = CodexRollout(url: URL(fileURLWithPath: path))
        codexByPane[pane] = r
        return r
    }

    /// Bring the pane's index up to date with the file and return its turns.
    func snapshot(pane: String, path: String) async -> Snapshot? {
        if CodexRollout.isRollout(path) { return await codexSnapshot(pane: pane, path: path) }
        return await withCheckedContinuation { c in
            queue.async {
                let idx = self.index(pane, path)
                let stamp = FileStamp.of(path)
                guard (try? autoreleasepool { try idx.update() }) != nil else { c.resume(returning: nil); return }
                c.resume(returning: Snapshot(turns: idx.turns, stamp: stamp, customTitle: idx.customTitle,
                                             aiTitle: idx.aiTitle, bytesParsed: idx.bytesParsed, fullReads: idx.fullReads))
            }
        }
    }

    /// Codex: the rollout's turns, and Codex's own title for the session (the rollout's
    /// `thread_name_updated`, else `$CODEX_HOME/session_index.jsonl`, read from its end).
    func codexSnapshot(pane: String, path: String, withTitle: Bool = false) async -> Snapshot? {
        await withCheckedContinuation { c in
            queue.async {
                let r = self.rollout(pane, path)
                let stamp = FileStamp.of(path)
                guard (try? autoreleasepool { try r.update() }) != nil else { c.resume(returning: nil); return }
                var title = r.threadName
                if title == nil, withTitle, let id = r.meta.id, let home = CodexRollout.codexHome(ofRollout: path) {
                    title = CodexThreadNames.name(of: id, in: CodexThreadNames.file(codexHome: home))
                }
                c.resume(returning: Snapshot(turns: r.turns, stamp: stamp, customTitle: nil, aiTitle: title,
                                             bytesParsed: r.bytesParsed, fullReads: r.fullReads))
            }
        }
    }

    /// Original markdown of a turn's reply, read from the file.
    func reply(pane: String, path: String, turn: TranscriptIndex.Turn) async -> String? {
        await withCheckedContinuation { c in
            queue.async {
                c.resume(returning: CodexRollout.isRollout(path) ? try? self.rollout(pane, path).reply(turn)
                                                                   : try? self.index(pane, path).reply(turn))
            }
        }
    }

    func fullPrompt(pane: String, path: String, turn: TranscriptIndex.Turn) async -> String {
        await withCheckedContinuation { c in
            queue.async {
                let p = CodexRollout.isRollout(path) ? try? self.rollout(pane, path).fullPrompt(turn)
                                                     : try? self.index(pane, path).fullPrompt(turn)
                c.resume(returning: p ?? turn.prompt)
            }
        }
    }

    func drop(pane: String) {
        queue.async {
            self.byPane[pane] = nil
            self.codexByPane[pane] = nil
        }
    }
}

/// Claude's process, as seen through the pane's pty.
enum ClaudeProcess {
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "xonsh", "elvish", "login"]

    /// What runs in the pane's foreground ("Claude Code", "zsh", "vim"), for pane headers. Looked
    /// up once per foreground group (a new job is a new group) and again after a title change
    /// (`exec vim` keeps the group), never per redraw.
    @MainActor static func foregroundName(_ pane: Pane) -> String? {
        if pane.runsClaude { return pane.agentKind == .codex ? "Codex" : "Claude Code" }
        if let app = pane.programApp { return app }
        let fg = pane.surface.foregroundPID
        guard fg > 0 else { return nil }
        if let c = pane.foregroundCache, c.group == fg { return c.name }
        let n = representative(ofGroup: fg).flatMap(name)
        // A new pane's child that hasn't exec'd yet still carries lmux's own name: nothing runs
        // there yet (never a header saying "lmux"), look again later.
        guard n != ProcessInfo.processInfo.processName else { return nil }
        pane.foregroundCache = (fg, n)
        return n
    }

    static func name(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// The pty's foreground process group still has members.
    static func groupAlive(_ pgid: pid_t) -> Bool { pgid > 0 && (kill(-pgid, 0) == 0 || errno == EPERM) }

    /// The process exists (a zombie counts until it is reaped).
    static func alive(_ pid: pid_t) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// The process that stands for a foreground process group: the newest member that is
    /// not `login` (the group leader may have exec'd or exited).
    static func representative(ofGroup pgid: pid_t) -> pid_t? {
        guard pgid > 0 else { return nil }
        // The leader is the job itself (claude, vim, …) unless it was a login wrapper that is gone.
        if let leader = name(pgid), leader != "login" { return pgid }
        var pids = [pid_t](repeating: 0, count: 256)
        let n = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let members = pids.prefix(max(0, Int(n) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
        let named = members.filter { name($0) != "login" }
        return (named.isEmpty ? members : named).max()
    }

    /// argv of a running process (KERN_PROCARGS2). macOS only shows another process's
    /// environment to root, so `env` is usually empty: lmux-hook reports it instead.
    static func commandLine(_ pid: pid_t) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard pid > 0, sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }   // exec path
        while i < size, buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        func next() -> String? {
            guard i < size, buf[i] != 0 else { return nil }
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        while args.count < argc, let a = next() { args.append(a) }
        var env: [String: String] = [:]
        while let kv = next() {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        return (args, env)
    }

    static func arguments(_ pid: pid_t) -> [String]? { commandLine(pid)?.argv }

    /// argv says Claude Code (`claude`, its native binary, or node running its cli.js).
    static func isClaude(_ pid: pid_t) -> Bool {
        (arguments(pid) ?? []).prefix(2).contains {
            ["claude", "claude.exe"].contains(($0 as NSString).lastPathComponent) || $0.hasSuffix("/cli.js") || $0.hasSuffix("/cli.mjs")
        }
    }
}

extension LmuxController {
    // MARK: - Wiring

    func installMessageActions(_ pane: Pane) {
        let s = pane.surface
        s.onMouseMove = { [weak self, weak pane] p in
            guard let self, let pane, pane.runsClaude else { return }
            self.paneMouseMoved(pane, p)
        }
        s.onMouseExit = { [weak self, weak pane] in
            guard let self, let pane else { return }
            pane.hover.point = nil
            self.hideHoverActions(pane)
        }
        s.onReturnKey = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.returnKey(pane)
        }
    }

    // MARK: - Screen and transcript

    /// Rows of the viewport and their turn roles, re-read at most every `maxAge` seconds.
    func screenMap(_ pane: Pane, maxAge: TimeInterval = 0.4) -> HoverCache {
        if Date().timeIntervalSince(pane.hover.readAt) > maxAge || pane.hover.map == nil {
            let (rows, h) = pane.surface.viewportRows()
            pane.hover.rows = rows
            pane.hover.rowHeight = h
            pane.hover.readAt = Date()
            pane.hover.locates += 1
            pane.hover.map = TurnLocator.locate(
                rows: rows.map(\.text),
                turns: pane.hover.turns.map { .init(index: $0.index, prompt: $0.prompt, hasReply: $0.hasReply) })
        }
        return pane.hover
    }

    /// Make sure the turn list matches the transcript on disk; update off-main if not
    /// (only the bytes Claude appended are parsed). Calls `then` (on main) once fresh.
    func refreshTurns(_ pane: Pane, then: (@MainActor () -> Void)? = nil) {
        guard let path = pane.transcriptPath else { return }
        let stamp = FileStamp.of(path)
        if pane.hover.loadedPath == path, pane.hover.stamp == stamp { then?(); return }
        guard !pane.hover.loading else { return }
        pane.hover.loading = true
        Task { [weak self, weak pane] in
            guard let self, let pane else { return }
            let snap = await self.transcripts.snapshot(pane: pane.id, path: path)
            pane.hover.loading = false
            if let snap { self.apply(snap, path: path, to: pane) }
            then?()
        }
    }

    private func apply(_ snap: TranscriptCache.Snapshot, path: String, to pane: Pane) {
        guard pane.transcriptPath == path else { return }
        var turns = snap.turns
        // After a rewind: the turns Claude dropped, until its next prompt starts the new branch.
        if let gone = pane.rewoundFrom {
            if let i = turns.firstIndex(where: { $0.uuid == gone }) { turns.removeSubrange(i...) } else { pane.rewoundFrom = nil }
        }
        if turns != pane.hover.turns { pane.hover.map = nil }
        pane.hover.turns = turns
        pane.hover.stamp = snap.stamp
        pane.hover.loadedPath = path
        transcriptReads[pane.id] = (snap.bytesParsed, snap.fullReads)
    }

    /// Fresh turns, awaited (used by actions, not by hover).
    func loadTurns(_ pane: Pane) async -> [TranscriptIndex.Turn] {
        guard let path = pane.transcriptPath else { return [] }
        if let snap = await transcripts.snapshot(pane: pane.id, path: path) { apply(snap, path: path, to: pane) }
        return pane.hover.turns
    }

    /// The original markdown of a turn's reply.
    func replyText(_ pane: Pane, _ turn: TranscriptIndex.Turn?) async -> String? {
        guard let turn, let path = pane.transcriptPath else { return nil }
        return await transcripts.reply(pane: pane.id, path: path, turn: turn)
    }

    // MARK: - Hover

    func paneMouseMoved(_ pane: Pane, _ p: NSPoint) {
        pane.hover.point = p
        guard !pane.busy, !pane.hover.selecting, pane.view.overlay.card == nil, pane.transcriptPath != nil else {
            hideHoverActions(pane); return
        }
        refreshTurns(pane) { [weak self, weak pane] in
            guard let self, let pane, pane.hover.point != nil else { return }
            self.updateHover(pane)
        }
    }

    /// The turn under the pointer: a faint band over its visible rows and one pill (⧉ ✎ ×) at the
    /// block's top right. Any row of the turn counts (prompt, tool calls, output, reply). The turn
    /// Claude is still writing gets nothing (Undo send covers a prompt just sent).
    func updateHover(_ pane: Pane) {
        guard let p = pane.hover.point else { hideHoverActions(pane); return }
        let c = screenMap(pane)
        let y = pane.surface.bounds.height - p.y
        guard let map = c.map, c.rowHeight > 0,
              let row = c.rows.firstIndex(where: { y >= $0.top && y < $0.top + c.rowHeight }),
              row < map.turnOfRow.count, let turn = map.turnOfRow[row],
              !isRunningTurn(pane, turn),
              let block = map.block(of: turn, rows: c.rows.map(\.text)) else {
            hideHoverActions(pane); return
        }
        let ov = pane.view.overlay
        let t = pane.hover.turns.first { $0.index == turn }
        let hasReply = t?.hasReply ?? false
        // Edit / remove drive Claude Code's rewind: Codex turns, ! shell commands (rewinding to one
        // is refused) and turns from before a compaction (not in Claude's menu) get Copy only (no
        // broken buttons), so nothing to show before they have a reply.
        let editable = !pane.runsCodex && !(t.map { RewindMenu.isShellCommand($0.prompt) || $0.beforeCompaction } ?? false)
        if !editable, !hasReply { hideHoverActions(pane); return }
        // The conversation's first turn (the transcript's, not the first on screen) has no ×: it would
        // remove the whole conversation. ✎ stays.
        let first = pane.hover.turns.first?.index == turn
        showTurnBar(pane, turn: turn, hasReply: hasReply, editable: editable, removable: !first)
        ov.turnRow = (c.rows[block.first].top, c.rowHeight)
        ov.turnBand = NSRect(x: 0, y: c.rows[block.first].top, width: ov.bounds.width,
                             height: c.rows[block.last].top + c.rowHeight - c.rows[block.first].top)
        ov.needsLayout = true
    }

    /// The last turn while Claude works on it (a prompt was just submitted, no Stop yet).
    func isRunningTurn(_ pane: Pane, _ turn: Int) -> Bool {
        claudeWorking(pane) && turn == pane.hover.turns.last?.index
    }

    /// Claude is working in `pane`: running since the last prompt, and that turn wasn't stopped
    /// with Esc (Claude Code sends no Stop hook then; the transcript ends with its interrupt marker).
    /// Not while the turn is paused for background subagents: Claude is at its prompt then.
    func claudeWorking(_ pane: Pane) -> Bool {
        guard case .running = pane.agent.state, !pane.agent.awaitingBackgroundSubagents else { return false }
        return pane.hover.turns.last?.interrupted != true
    }

    /// Right edge (overlay x) of the text on a row: terminal padding + its display columns.
    func textRight(_ pane: Pane, _ text: String) -> CGFloat {
        let trimmed = text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let cols = trimmed.unicodeScalars.reduce(0) { $0 + (TurnLocator.isWide($1) ? 2 : 1) }
        return pane.surface.terminalPadding.width + CGFloat(cols) * max(1, pane.surface.cellSize.width)
    }

    /// A text-selection drag in the pane hides the pill until the pointer moves again.
    func paneSelectionDrag(_ pane: Pane, active: Bool) {
        pane.hover.selecting = active
        if active { hideHoverActions(pane) }
    }

    /// Blank row runs of the viewport (overlay coordinates), for placing cards.
    func freeRuns(_ pane: Pane) -> [(top: CGFloat, bottom: CGFloat)] {
        let (rows, h) = pane.surface.viewportRows()
        var out: [(CGFloat, CGFloat)] = []
        var start: CGFloat?
        for r in rows {
            if r.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if start == nil { start = r.top }
            } else if let s = start {
                out.append((s, r.top)); start = nil
            }
        }
        if let s = start, let last = rows.last { out.append((s, max(last.top + h, pane.view.overlay.bounds.height))) }
        return out
    }

    /// Turn the hover pill currently acts on (tests and the buttons).
    func hoveredTurn(_ pane: Pane) -> Int? {
        guard let bar = pane.view.overlay.turnBar, bar.shown else { return nil }
        return bar.turn
    }

    private func showTurnBar(_ pane: Pane, turn: Int, hasReply: Bool, editable: Bool, removable: Bool) {
        let ov = pane.view.overlay
        if ov.turnBar == nil {
            let bar = TurnActionBar(
                onCopy: { [weak self, weak pane, weak ov] in
                    guard let self, let pane, let t = ov?.turnBar?.turn else { return }
                    Task { await self.copyOriginal(pane, turnIndex: t) }
                },
                onEdit: { [weak self, weak pane, weak ov] in
                    guard let self, let pane, let t = ov?.turnBar?.turn else { return }
                    self.requestRewind(pane, turnIndex: t, edit: true)
                },
                onRemove: { [weak self, weak pane, weak ov] in
                    guard let self, let pane, let bar = ov?.turnBar, bar.removable else { return }
                    let t = bar.turn
                    self.requestRewind(pane, turnIndex: t, edit: false)
                })
            bar.remove.onHover = { [weak ov, weak bar] on in
                guard on else { ov?.showTip(nil); return }
                // Explains the action once the pointer rests on × (600ms), below the pill.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    MainActor.assumeIsolated {
                        guard let bar, bar.remove.isHovering, bar.shown else { return }
                        ov?.showTip("Remove this message and everything after it")
                    }
                }
            }
            ov.addSubview(bar)
            ov.turnBar = bar
        }
        let bar = ov.turnBar!
        if bar.turn != turn { ov.showTip(nil) }
        bar.turn = turn
        if bar.hasCopy != hasReply { bar.hasCopy = hasReply }
        if bar.editable != editable { bar.editable = editable }
        if bar.removable != removable { bar.removable = removable }
        if bar.codex != pane.runsCodex { bar.codex = pane.runsCodex }
        bar.setShown(true)
    }

    func hideHoverActions(_ pane: Pane) {
        pane.view.overlay.turnBar?.setShown(false)
        pane.view.overlay.turnBand = nil
        pane.view.overlay.showTip(nil)
    }

    // MARK: - Input label (R7)

    func scheduleOverlayRefresh(_ pane: Pane, delay: TimeInterval = 0.15) {
        overlayWork[pane.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak pane] in
            MainActor.assumeIsolated {
                guard let self, let pane else { return }
                self.overlayWork[pane.id] = nil
                self.refreshInputLabel(pane)
            }
        }
        overlayWork[pane.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Workspace accent + title over the rule above Claude's input box.
    func refreshInputLabel(_ pane: Pane) {
        let ov = pane.view.overlay
        // Only with 2+ workspaces: with one there is no wrong session to guard against.
        guard pane.runsClaude, let ws = pane.workspace, ws === model.selected, !pane.busy, model.workspaces.count >= 2 else {
            ov.inputLabel.isHidden = true
            ov.inputRuleRow = nil
            ov.needsLayout = true
            return
        }
        let c = screenMap(pane, maxAge: 0)
        guard let rule = c.map?.inputRule, c.rowHeight > 0 else {
            ov.inputLabel.isHidden = true
            ov.inputRuleRow = nil
            ov.needsLayout = true
            return
        }
        // Same place and text as last time: no layout pass.
        let placed = !ov.inputLabel.isHidden && ov.inputRuleRow?.top == c.rows[rule].top && ov.inputRuleRow?.height == c.rowHeight
        let before = (ov.inputLabel.text, ov.inputRuleStart)
        ov.inputRuleRow = (c.rows[rule].top, c.rowHeight)
        ov.inputLabel.text = ws.title
        ov.inputLabel.accent = T.Colors.workspaceAccents[ws.accent % T.Colors.workspaceAccents.count].nsColor
        ov.inputLabel.background = pane.surface.terminalBackground ?? T.Colors.windowBackground.nsColor
        ov.inputLabel.adoptAppearance(on: pane.surface.terminalBackground)
        ov.inputRuleStart = pane.surface.terminalPadding.width
        if !placed || before != (ov.inputLabel.text, ov.inputRuleStart) { ov.needsLayout = true }
        ov.inputLabel.isHidden = false
    }

    /// Claude redraws its input box as it works (spinner line, streamed reply) without a hook
    /// event for each redraw. On each frame the pane draws (nothing on screen changed: no frame),
    /// the cursor is looked at: Claude keeps it in or below its input box, so only when it moved
    /// is the screen mapped again and the label re-placed. No timer, no polling.
    func paneDrewFrame(_ pane: Pane) {
        guard pane.runsClaude, pane.workspace === model.selected, model.workspaces.count >= 2 else { return }
        let y = pane.surface.cursorY
        guard y != pane.lastFrameCursorY else { return }
        pane.lastFrameCursorY = y
        if overlayWork[pane.id] == nil { scheduleOverlayRefresh(pane, delay: 0.1) }
    }

    // MARK: - Cards and notes

    func showCard(_ pane: Pane, message: NSAttributedString, detail: String,
                  confirmTitle: String, passive: Bool = false, onConfirm: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        dismissCard(pane)
        hideHoverActions(pane)
        let ws = pane.workspace
        let accent = ws.map { T.Colors.workspaceAccents[$0.accent % T.Colors.workspaceAccents.count].nsColor }
        let card = ConfirmCard(
            message: message, detail: detail, confirmTitle: confirmTitle, accent: accent,
            onCancel: { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.dismissCard(pane)
                onCancel?()
            },
            onConfirm: { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.dismissCard(pane)
                onConfirm()
            })
        pane.view.overlay.freeRuns = freeRuns(pane)
        pane.view.overlay.addSubview(card)
        pane.view.overlay.card = card
        pane.view.overlay.needsLayout = true
        // A card nobody asked for (the hooks hint): typing goes on to the terminal as usual, and
        // ⏎ / esc stay Claude's; only its buttons answer it.
        if passive {
            card.cancel.title = "Dismiss"
            card.cancel.shortcut = nil
            card.confirm.shortcut = nil
            return
        }
        pane.surface.keyInterceptor = { [weak card] event in
            guard let card else { return false }
            // A held key's auto-repeat (the Enter that raised the guard) never answers the card.
            if event.isARepeat { return true }
            switch event.keyCode {
            case 0x24, 0x4C: card.confirm.performClick(); return true
            case 0x35: card.cancel.performClick(); return true
            default:
                if event.modifierFlags.contains(.command) { return false }
                card.cancel.performClick()
                return false
            }
        }
    }

    func dismissCard(_ pane: Pane) {
        pane.view.overlay.card?.removeFromSuperview()
        pane.view.overlay.card = nil
        pane.surface.keyInterceptor = nil
    }

    static func bold(_ prefix: String, _ strong: String, _ suffix: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: T.Colors.textSecondary.nsColor]
        s.append(NSAttributedString(string: prefix, attributes: base))
        s.append(NSAttributedString(string: strong, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                                                                 .foregroundColor: T.Colors.textPrimary.nsColor]))
        s.append(NSAttributedString(string: suffix, attributes: base))
        return s
    }

    /// A short inline note at the pane's bottom right (refusals, errors, progress).
    func showNote(_ pane: Pane, _ text: String, symbol: String = "info.circle", color: NSColor = T.Colors.textTertiary.nsColor,
                  duration: TimeInterval? = 4, action: (title: String, run: () -> Void)? = nil) {
        hideToast(pane)
        let t = ToastView(button: action.map { a in OverlayButton(title: a.title, style: .secondary, action: a.run) })
        t.symbol = symbol
        t.symbolColor = color
        t.text = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                               .foregroundColor: T.Colors.textPrimary.nsColor])
        pane.view.overlay.addSubview(t)
        pane.view.overlay.toast = t
        pane.view.overlay.needsLayout = true
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak pane, weak t] in
                guard let pane, let t, pane.view.overlay.toast === t else { return }
                t.removeFromSuperview()
                pane.view.overlay.toast = nil
            }
        }
    }

    func hideToast(_ pane: Pane) {
        pane.view.overlay.toast?.removeFromSuperview()
        pane.view.overlay.toast = nil
    }

    // MARK: - Copy original (R10)

    /// Copy a turn's reply (nil = the last reply) as its original markdown.
    @discardableResult
    public func copyOriginal(_ pane: Pane, turnIndex: Int? = nil) async -> String? {
        let name = pane.runsCodex ? "Codex" : "Claude"
        var md: String?
        // Codex's last reply as its Stop reported it (the rollout is the fallback).
        if turnIndex == nil, pane.runsCodex, let last = pane.lastReply, !last.isEmpty { md = last }
        if md == nil {
            let turns = await loadTurns(pane)
            let turn = turnIndex.map { i in turns.first { $0.index == i } } ?? turns.last { $0.hasReply }
            md = await replyText(pane, turn)
        }
        guard let md else {
            showNote(pane, "No reply from \(name) to copy yet.")
            return nil
        }
        pasteboard.clearContents()
        pasteboard.setString(md, forType: .string)
        showNote(pane, "Copied \(name)’s reply as markdown", symbol: "doc.on.doc", duration: 1.6)
        return md
    }

    @objc func menuCopyOriginal(_ sender: Any?) {
        guard let p = model.selected?.focusedPane, p.transcriptPath != nil || p.lastReply != nil else { NSSound.beep(); return }
        Task { await copyOriginal(p) }
    }

    /// While a restored or History-resumed agent starts, its session counts as open (History doesn't
    /// list it as closed in between): until the pane's next SessionStart, or 30s if it never comes back.
    func markRelaunching(_ pane: Pane, _ sid: String) {
        pane.relaunchingSessionID = sid
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak pane] in
            guard let pane else { return }
            self?.relaunchGraceEnded(pane, sid)
        }
    }

    func relaunchGraceEnded(_ pane: Pane, _ sid: String) {
        guard pane.relaunchingSessionID == sid, !pane.busy else { return }
        pane.relaunchingSessionID = nil
        history.scheduleRefresh()
        // The agent never came back (a resume that failed): a shell again, its restored ✓ gone.
        checkClaudeStillRunning(pane)
    }

    /// Backups the old forget (before Claude Code's rewind did the job) left in the state dir: they
    /// hold the forgotten text and were promised 7 days, so launch still deletes them after that.
    var forgottenDirectory: URL { paths.stateDir.appendingPathComponent("forgotten", isDirectory: true) }

    nonisolated static let forgottenRetention: TimeInterval = 7 * 86400

    func pruneForgottenBackups(now: Date = Date()) async {
        let dir = forgottenDirectory
        await Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for f in files {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(m) > Self.forgottenRetention { try? fm.removeItem(at: f) }
            }
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
        }.value
    }

    // MARK: - Return (R7)

    /// Plain Return in `pane`.
    func returnKey(_ pane: Pane) {
        // A program's question answered with Return (arrows in its menu aren't): its next `blocked` is a new ask.
        if pane.needsInput, pane.programApp != nil { pane.programAnswered = true }
        guard pane.runsClaude else { return }
        // Enter while an IME composes (Japanese, Chinese) confirms the conversion: it sends nothing.
        // Korean is different: Enter commits the syllable AND sends the line, so it counts for
        // Undo like any other Enter.
        if pane.surface.hasMarkedText(), !inputSourceLanguages().contains(where: { $0.hasPrefix("ko") }) { return }
        noteReturn(pane)
        // The prompt leaves the input box and Claude redraws below it: the label goes with
        // the old box and comes back over the new one.
        pane.view.overlay.inputLabel.isHidden = true
        scheduleOverlayRefresh(pane, delay: 0.3)
    }

    /// Languages of the current keyboard input source ("ko" for the Korean IMEs).
    nonisolated static func currentInputSourceLanguages() -> [String] {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
    }

    /// A Return the user typed here: remember when, and how long the transcript was (one
    /// stat), so Undo only ever looks at turns written after it.
    func noteReturn(_ pane: Pane) {
        pane.lastReturnAt = Date()
        pane.lastReturnOffset = pane.transcriptPath.flatMap { FileStamp.of($0)?.size } ?? 0
        considerHooksHint(pane)
    }

    /// Whether a confirm card is up in `pane` (tests).
    func cardShown(_ pane: Pane) -> Bool { pane.view.overlay.card != nil }

    // MARK: - Undo send (R7)

    /// A prompt reached Claude (UserPromptSubmit). If the user just pressed Return here,
    /// offer to take it back for 3s.
    func promptSubmitted(_ pane: Pane, prompt: String?) {
        // Undo rewinds the turn (Claude Code's rewind menu): not offered for Codex.
        guard !pane.runsCodex, !pane.busy, let prompt, !prompt.isEmpty, let r = pane.lastReturnAt, Date().timeIntervalSince(r) < 3 else { return }
        pane.lastReturnAt = nil
        showUndoToast(pane, prompt: prompt, sinceOffset: pane.lastReturnOffset)
    }

    func showUndoToast(_ pane: Pane, prompt: String, sinceOffset: Int = 0) {
        clearPendingUndo()
        hideToast(pane)
        let window = T.Motion.undoSendWindow
        let button = OverlayButton(title: "Undo", shortcut: "⌘Z", style: .secondary)
        button.action = { [weak self] in _ = self?.undoSend() }
        let t = ToastView(button: button)
        let ws = pane.workspace
        let accent = ws.map { T.Colors.workspaceAccents[$0.accent % T.Colors.workspaceAccents.count].nsColor } ?? .clear
        let s = NSMutableAttributedString(string: "Sent to ", attributes: [.font: NSFont.systemFont(ofSize: 12.5),
                                                                          .foregroundColor: T.Colors.textSecondary.nsColor])
        s.append(NSAttributedString(string: "● ", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: accent,
                                                               .baselineOffset: 1]))
        s.append(NSAttributedString(string: ws?.title ?? "Claude", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                                                                                .foregroundColor: T.Colors.textPrimary.nsColor]))
        t.text = s
        t.startDrain(duration: window)
        t.countdown = "\(Int(window))s"
        pane.view.overlay.addSubview(t)
        pane.view.overlay.toast = t
        pane.view.overlay.needsLayout = true
        let start = Date()
        var u = PendingUndo(paneID: pane.id, prompt: prompt, deadline: start.addingTimeInterval(window),
                            sinceOffset: sinceOffset)
        // The line drains by itself (Core Animation); once a second the countdown moves, and at the
        // end the toast goes. Nothing runs when idle.
        u.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak pane, weak t] timer in
            MainActor.assumeIsolated {
                let left = window - Date().timeIntervalSince(start)
                guard self != nil, let pane, let t, pane.view.overlay.toast === t, left > 0.05 else {
                    timer.invalidate()
                    if let self, let pane, let t, pane.view.overlay.toast === t { self.hideToast(pane) }
                    if let self, self.pendingUndo?.paneID == pane?.id { self.pendingUndo = nil }
                    return
                }
                t.countdown = "\(Int(left.rounded(.up)))s"
            }
        }
        pendingUndo = u
    }

    func clearPendingUndo() {
        pendingUndo?.timer?.invalidate()
        pendingUndo = nil
    }

    /// ⌘Z while the toast is up: interrupt Claude if it's working, then rewind the turn.
    @discardableResult
    public func undoSend() -> Bool {
        guard let u = pendingUndo, Date() < u.deadline, let pane = pane(id: u.paneID) else {
            log("undoSend: nothing to undo")
            return false
        }
        // A rewind already drives this pane: two drivers would mix their keys.
        guard !pane.busy else {
            log("undoSend: pane busy")
            return false
        }
        // Not from another tab or workspace: its keys would go to a pane nobody sees.
        guard onScreen(pane) else {
            log("undoSend: pane hidden")
            return false
        }
        log("undoSend: \(u.prompt.prefix(40))")
        clearPendingUndo()
        hideToast(pane)
        // Busy from now on, so no other action slips in while the prompt is looked up.
        pane.busy = true
        Task { await self.undo(prompt: u.prompt, in: pane, since: u.sinceOffset) }
        return true
    }

    @objc func menuUndoSend(_ sender: Any?) {
        if !undoSend() { NSSound.beep() }
    }

    // MARK: - ⌘W safety

    /// Close a pane, asking first if that would kill something other than an idle shell. A pinned
    /// tab doesn't close (a beep, as in cmux) while its strip shows (where it can be unpinned).
    public func requestClosePane(_ pane: Pane) {
        if pane.pinned, pane.workspace?.root.find(pane)?.hasStrip == true { NSSound.beep(); return }
        guard let running = runningProcess(pane) else { closePane(pane); return }
        showCard(pane, message: Self.bold("Close this pane? ", running, " is still running."),
                 detail: "Closing it terminates the process.", confirmTitle: "Close",
                 onConfirm: { [weak self, weak pane] in
                     guard let self, let pane else { return }
                     self.closePane(pane)
                 })
    }

    /// Name of the foreground process if it's not an idle shell (nil = safe to close).
    func runningProcess(_ pane: Pane) -> String? {
        let fg = pane.surface.foregroundPID
        if fg > 0, let pid = ClaudeProcess.representative(ofGroup: fg) {
            let name = ClaudeProcess.name(pid) ?? "a process"
            if ClaudeProcess.shells.contains(name) { return nil }
            return pane.runsClaude ? (pane.agentKind == .codex ? "Codex" : "Claude Code") : name
        }
        return pane.surface.needsConfirmQuit ? "a process" : nil
    }
}

@MainActor
func sleepMs(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
