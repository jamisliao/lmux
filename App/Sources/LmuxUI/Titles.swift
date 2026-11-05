import AppKit
import LmuxHooks

// Session titles (R16) come from Claude Code itself: the `ai-title` it writes into the transcript
// (and rewrites as it sees fit), or the name the user gave it with `/rename` (`custom-title`).
// Codex: its `thread_name` (the rollout's `thread_name_updated`, else `session_index.jsonl`),
// adopted like Claude's `ai-title` (it never overrides a name the user typed in lmux).
// lmux reads them through the pane's incremental transcript reader, off the main thread, at
// SessionStart and after each Stop; it never asks a model. A name the user types in lmux (or
// `/rename`) locks the title. A workspace's title is its manual name, else its focused pane's
// session title.

/// The title of the Claude session in a pane, persisted with the layout.
public struct TitleState: Sendable, Equatable, Codable {
    public var title: String?
    /// The user named the session (lmux rename or Claude Code `/rename`): Claude's own title never replaces it.
    public var isManual: Bool
    /// Last Claude Code `/rename` title adopted, so an older one never overrides a later lmux
    /// rename or unlock.
    public var adoptedClaudeTitle: String?

    public init(title: String? = nil, isManual: Bool = false) {
        self.title = title
        self.isManual = isManual
    }

    /// Tolerant: layouts saved by older lmux carry more keys (the model title engine's), and may lack these.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        adoptedClaudeTitle = try c.decodeIfPresent(String.self, forKey: .adoptedClaudeTitle)
    }

    /// The user renamed the session: lock it.
    public mutating func setManualTitle(_ newTitle: String) {
        title = newTitle
        isManual = true
    }

    /// Hand the title back to Claude's own (the next read fills it in).
    public mutating func unlock() {
        isManual = false
        title = nil
    }

    /// What the transcript says: a new `/rename` locks the title; otherwise Claude's `ai-title`
    /// is the title unless the user named the session.
    public mutating func apply(customTitle: String?, aiTitle: String?) {
        if let custom = customTitle, custom != adoptedClaudeTitle {
            adoptedClaudeTitle = custom
            setManualTitle(custom)
        }
        if !isManual, let ai = aiTitle, ai != title { title = ai }
    }
}

extension LmuxController {
    nonisolated static let titleDebounce: TimeInterval = 2.0

    /// SessionStart: a new session in the pane starts with a new title; Claude's own if the
    /// transcript already has one (`--resume`).
    func titleSessionStarted(_ pane: Pane, _ e: HookEvent) {
        guard let sid = e.sessionID, !sid.isEmpty else { return }
        if sid != pane.titleSession {
            if !pane.titleState.isManual { pane.titleState = TitleState() }
            pane.titleSession = sid
            scheduleSave()
        }
        refreshTitleFromClaude(pane)
    }

    /// After a Stop (Claude writes its `ai-title` around then): read it, debounced.
    func scheduleTitleRefresh(_ pane: Pane, delay: TimeInterval = LmuxController.titleDebounce) {
        titleWork[pane.id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak pane] in
            MainActor.assumeIsolated {
                guard let self, let pane else { return }
                self.titleWork[pane.id] = nil
                self.refreshTitleFromClaude(pane)
            }
        }
        titleWork[pane.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Adopt Claude's `custom-title` / `ai-title` from the transcript (appended bytes only).
    func refreshTitleFromClaude(_ pane: Pane) {
        guard let path = pane.transcriptPath else { return }
        let sid = pane.titleSession
        let state = pane.titleState
        let codex = pane.runsCodex
        Task { [weak self, weak pane] in
            guard let self, let pane else { return }
            let snap = codex ? await self.transcripts.codexSnapshot(pane: pane.id, path: path, withTitle: true)
                             : await self.transcripts.snapshot(pane: pane.id, path: path)
            guard let snap else { return }
            var s = state
            s.apply(customTitle: snap.customTitle, aiTitle: snap.aiTitle)
            // A rename (or another session) while the file was read wins.
            guard s != state, pane.titleSession == sid, pane.titleState == state else { return }
            pane.titleState = s
            self.titlesChanged(pane)
        }
    }

    func titlesChanged(_ pane: Pane) {
        if let ws = pane.workspace { refreshHeaders(ws) }
        if pane.workspace === model.selected { root.updateHeader() }
        scheduleOverlayRefresh(pane)
        scheduleSave()
    }

    // MARK: - Manual names

    /// Rename a pane's session; empty hands the title back to Claude's own.
    public func renamePane(_ pane: Pane, to name: String?) {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty {
            pane.titleState.unlock()
            refreshTitleFromClaude(pane)
        } else {
            pane.titleState.setManualTitle(t)
        }
        titlesChanged(pane)
    }

    /// Rename a workspace (locks its title); empty follows the focused pane again.
    public func renameWorkspace(_ ws: Workspace, to name: String?) {
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ws.customTitle = t.isEmpty ? nil : t
        root.updateHeader()
        for p in ws.panes { scheduleOverlayRefresh(p) }
        scheduleSave()
    }

    public func promptRenamePane(_ pane: Pane) {
        guard !headless else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to use \(pane.runsCodex ? "Codex" : "Claude Code")’s own title for the session."
        let field = NSTextField(string: pane.titleState.isManual ? (pane.titleState.title ?? "") : "")
        field.placeholderString = pane.headerTitle
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.renamePane(pane, to: field.stringValue)
            self?.focusCurrent()
        }
    }
}
