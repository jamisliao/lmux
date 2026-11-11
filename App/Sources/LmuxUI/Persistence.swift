import AppKit
import LmuxHooks
import LmuxTokens

// Layout autosave / restore (R11). File: <state dir>/layout.json.
// Saved debounced on every change and synchronously on quit.

public struct LayoutFile: Codable, Equatable {
    public var version = 1
    public var workspaces: [WorkspaceState] = []
    public var selected: String?
    public var sidebarVisible = true
    public var sidebarWidth: Double = Double(LmuxTokens.Layout.sidebarWidthDefault)

    public init() {}

    // Every key but `workspaces` may be missing (an older or newer lmux wrote the file): its
    // default is used. Keys added later must be optional or defaulted here too, so a layout
    // never fails to load over a field it doesn't have.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        workspaces = try c.decodeIfPresent([WorkspaceState].self, forKey: .workspaces) ?? []
        selected = try c.decodeIfPresent(String.self, forKey: .selected)
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? Double(LmuxTokens.Layout.sidebarWidthDefault)
    }

    public struct WorkspaceState: Codable, Equatable {
        public var id: String
        public var customTitle: String?
        public var accent: Int
        public var focusedPane: String?
        /// The split-zoomed pane (⇧⌘↩), if any; absent in layouts older lmux wrote.
        public var zoomedPane: String?
        public var root: NodeState

        public init(id: String, customTitle: String?, accent: Int, focusedPane: String?, zoomedPane: String? = nil, root: NodeState) {
            self.id = id; self.customTitle = customTitle; self.accent = accent; self.focusedPane = focusedPane
            self.zoomedPane = zoomedPane; self.root = root
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
            accent = try c.decodeIfPresent(Int.self, forKey: .accent) ?? 0
            focusedPane = try c.decodeIfPresent(String.self, forKey: .focusedPane)
            zoomedPane = try c.decodeIfPresent(String.self, forKey: .zoomedPane)
            root = try c.decode(NodeState.self, forKey: .root)
        }
    }

    /// Either a pane (`pane` set) or a split (`axis`, `ratio`, two `children`). A pane with tabs
    /// also has `tabs` (all of them, in strip order) and `selectedTab`; `pane` is the shown one, so
    /// an lmux without tabs opens that. Absent in layouts older lmux wrote: one tab.
    public struct NodeState: Codable, Equatable {
        public var pane: PaneState?
        public var axis: SplitAxis?
        public var ratio: Double?
        public var children: [NodeState]?
        public var tabs: [PaneState]?
        public var selectedTab: Int?

        public init(pane: PaneState? = nil, axis: SplitAxis? = nil, ratio: Double? = nil, children: [NodeState]? = nil,
                    tabs: [PaneState]? = nil, selectedTab: Int? = nil) {
            self.pane = pane; self.axis = axis; self.ratio = ratio; self.children = children
            self.tabs = tabs; self.selectedTab = selectedTab
        }

        /// The leaf's panes (its tabs, else its one pane).
        public var leafPanes: [PaneState] {
            if let t = tabs, t.count > 1 { return t }
            return pane.map { [$0] } ?? []
        }
    }

    public struct PaneState: Codable, Equatable {
        public var id: String
        public var cwd: String?
        public var title: String?
        /// Claude Code (or Codex) session running in the pane at save time (from hooks).
        public var claudeSession: String?
        /// "codex" for a Codex session; absent for Claude Code (and in layouts older lmux wrote).
        public var agent: String?
        /// How that session was started (`[VAR=x] claude <flags> --resume <id>`), replayed on restore.
        public var resumeCommand: String?
        /// Its replayable env (allowlisted names), given to the restored pane's shell, never typed.
        public var resumeEnvironment: [String: String]?
        public var transcriptPath: String?
        /// Auto / manual session title (R16) and the session it belongs to.
        public var titleState: TitleState?
        public var titleSession: String?
        /// The session's last turn ended (done): when (Unix seconds) and its last-reply line, so the
        /// resumed pane shows ✓ again. Absent otherwise.
        public var doneAt: Double?
        public var alertDetail: String?
        /// Nobody had looked at that done turn yet: since when (Unix seconds; the reminder's clock
        /// keeps running across the relaunch).
        public var attentionSince: Double?
        /// A pinned tab (absent: not pinned).
        public var pinned: Bool?
    }
}

extension LmuxController {
    static let saveDelay: TimeInterval = 1.0

    func scheduleSave() {
        guard persistenceEnabled else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    public func snapshotLayout() -> LayoutFile {
        // A done turn of a session restore resumes comes back (a needs-input dialog goes away with
        // the agent's process).
        func done(_ p: Pane) -> Bool {
            p.agent.state == .done && !p.failed
                && Self.resumeCommand(p.claudeSessionID, saved: p.resumeCommand, agent: p.agentKind) != nil
        }
        func node(_ n: SplitNode) -> LayoutFile.NodeState {
            switch n.content {
            case .pane(let shown):
                guard n.hasTabs else { return .init(pane: state(shown)) }
                return .init(pane: state(shown), tabs: n.tabs.map(state), selectedTab: n.tabs.firstIndex { $0 === shown } ?? 0)
            case .split(let axis, let a, let b):
                return .init(axis: axis, ratio: Double(n.ratio), children: [node(a), node(b)])
            }
        }
        func state(_ p: Pane) -> LayoutFile.PaneState {
            .init(id: p.id, cwd: p.cwd, title: p.title.isEmpty ? nil : p.title,
                  claudeSession: p.claudeSessionID,
                  agent: p.claudeSessionID != nil && p.agentKind != .claude ? p.agentKind.rawValue : nil,
                  resumeCommand: p.resumeCommand,
                  resumeEnvironment: p.resumeEnvironment.isEmpty ? nil : p.resumeEnvironment,
                  transcriptPath: p.transcriptPath,
                  titleState: p.titleState == TitleState() ? nil : p.titleState,
                  titleSession: p.titleSession,
                  doneAt: done(p) ? (p.lastAlertAt ?? Date()).timeIntervalSince1970 : nil,
                  alertDetail: done(p) ? p.alertDetail : nil,
                  attentionSince: done(p) ? p.attentionSince?.timeIntervalSince1970 : nil,
                  pinned: p.pinned ? true : nil)
        }
        var f = LayoutFile()
        f.workspaces = model.workspaces.map {
            .init(id: $0.id, customTitle: $0.customTitle, accent: $0.accent,
                  focusedPane: $0.focusedPane?.id, zoomedPane: $0.zoomedPane?.id, root: node($0.root))
        }
        f.selected = model.selectedID
        f.sidebarVisible = model.sidebarVisible
        f.sidebarWidth = Double(model.sidebarWidth)
        return f
    }

    public func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard persistenceEnabled else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(snapshotLayout()) else { return }
        do {
            try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Private from the first byte: a 0600 temp file, on disk (fsync) before it is renamed
            // over the layout, so a crash or power loss leaves the old layout or the new one.
            let tmp = paths.stateDir.appendingPathComponent(".layout.json.\(getpid())")
            try? FileManager.default.removeItem(at: tmp)
            let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let written = data.withUnsafeBytes { buf -> Bool in
                var off = 0
                while off < buf.count {
                    let n = write(fd, buf.baseAddress! + off, buf.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
                }
                return true
            }
            let synced = written && fsync(fd) == 0
            close(fd)
            guard synced, rename(tmp.path, paths.layoutFile.path) == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                throw POSIXError(.EIO)
            }
        } catch {
            NSLog("lmux: saving layout failed: %@", "\(error)")
        }
    }

    /// The command a restored pane types into its shell: the one captured when the session
    /// started (its flags; env goes to the shell's environment), else plain `claude --resume <id>`.
    /// Nothing for a pane whose claude lmux never saw start (no SessionStart, no command), or whose
    /// session id is not a UUID. The leading space keeps the line out of shell history.
    /// Codex: the captured `codex resume … <id>`, else plain `codex resume <id>`.
    /// The saved string is never typed as it is: its words are parsed back (lmux's own quoting only)
    /// and the command rebuilt from them (the flags lmux keeps, then the id). Anything else (an env
    /// assignment from an older layout, a control character, a shell operator) gets the plain resume.
    static func resumeCommand(_ session: String?, saved: String? = nil, agent: AgentKind = .claude) -> String? {
        guard let s = session, ClaudeCommand.isSessionID(s), let saved else { return nil }
        let argv = ClaudeCommand.hasControlCharacter(saved) ? nil : ClaudeCommand.shellWords(saved)
        if agent == .codex {
            let ok = argv.map { CodexCommand.isResume($0, session: s) } ?? false
            return " " + CodexCommand.resume(argv: ok ? argv : nil, sessionID: s, inherited: [:]) + "\n"
        }
        if let argv, argv.suffix(2) == ["--resume", s], let exe = argv.first, !exe.contains("=") {
            return " " + ClaudeCommand.resume(argv: argv, sessionID: s, inherited: [:]) + "\n"
        }
        return " claude --resume \(s)\n"
    }

    /// Returns false when there was nothing (valid) to restore.
    func restoreLayout() -> Bool {
        guard let data = try? Data(contentsOf: paths.layoutFile) else { return false }
        // Unreadable (corrupt, or a format this lmux doesn't know), whole or in part: kept aside
        // before the fresh layout is saved over it, so nothing the user had is lost silently.
        func keepAside() {
            let bad = paths.stateDir.appendingPathComponent("layout.json.bad-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.removeItem(at: bad)
            if (try? FileManager.default.copyItem(at: paths.layoutFile, to: bad)) != nil {
                chmod(bad.path, 0o600)
                NSLog("lmux: layout.json could not be read; kept as %@", bad.lastPathComponent)
            }
        }
        guard let file = try? JSONDecoder().decode(LayoutFile.self, from: data) else {
            keepAside()
            return false
        }
        guard !file.workspaces.isEmpty else { return false }
        model.sidebarVisible = file.sidebarVisible
        model.sidebarWidth = min(max(CGFloat(file.sidebarWidth), LmuxTokens.Layout.sidebarWidthMin),
                                 LmuxTokens.Layout.sidebarWidthMax)

        var dropped = false
        defer { if dropped { keepAside() } }
        for w in file.workspaces {
            // Checked whole first: a split that fails half way would leave its first pane's shell
            // running unseen.
            guard Self.isWellFormed(w.root), let root = buildNode(w.root) else { dropped = true; continue }
            let ws = Workspace(id: w.id, accent: w.accent, root: root)
            ws.customTitle = w.customTitle
            if let f = w.focusedPane, let p = ws.panes.first(where: { $0.id == f }) { ws.focusedPane = p }
            // Zoomed as the user left it, on the zoomed pane (focused, as zooming it needed); a pane
            // that is gone, or a split that no longer is one, restores unzoomed.
            if let z = w.zoomedPane, ws.isSplit, let p = ws.panes.first(where: { $0.id == z }) {
                ws.zoomedPane = p
                ws.focusedPane = p
            }
            model.workspaces.append(ws)
        }
        guard !model.workspaces.isEmpty else { return false }
        select(model.workspaces.first { $0.id == file.selected } ?? model.workspaces[0])
        // Restored unattended rows breathe right away when overdue.
        updatePulseMotion()
        updateAttention()
        return true
    }

    /// A pane, or a split with an axis and exactly two well-formed children.
    static func isWellFormed(_ s: LayoutFile.NodeState) -> Bool {
        if s.pane != nil { return true }
        guard s.axis != nil, let kids = s.children, kids.count == 2 else { return false }
        return kids.allSatisfy(isWellFormed)
    }

    /// A saved split tree as panes (a Claude pane resumes its session), hidden until selected.
    func buildNode(_ s: LayoutFile.NodeState) -> SplitNode? {
        if s.pane != nil {
            let built = s.leafPanes.map(buildPane)
            guard built.count > 1 else { return SplitNode(pane: built[0]) }
            // Pinned tabs first (an imported or hand-edited layout may have them anywhere).
            let shown = built[min(max(s.selectedTab ?? 0, 0), built.count - 1)]
            let tabs = built.filter(\.pinned) + built.filter { !$0.pinned }
            return SplitNode(tabs: tabs, selected: tabs.firstIndex { $0 === shown } ?? 0)
        }
        guard let axis = s.axis, let kids = s.children, kids.count == 2,
              let a = buildNode(kids[0]), let b = buildNode(kids[1]) else { return nil }
        let n = SplitNode(.split(axis, a, b))
        n.ratio = CGFloat(min(max(s.ratio ?? 0.5, 0.05), 0.95))
        return n
    }

    /// One saved pane (a tab) as a pane, hidden until shown.
    func buildPane(_ p: LayoutFile.PaneState) -> Pane {
        let id = self.pane(id: p.id) == nil ? p.id : UUID().uuidString
        let agent = p.agent.flatMap(AgentKind.init(rawValue:)) ?? .claude
        let input = Self.resumeCommand(p.claudeSession, saved: p.resumeCommand, agent: agent)
        let session = input == nil ? nil : p.claudeSession
        let env = (session == nil ? nil : p.resumeEnvironment)?.filter { HookClient.replayable($0.key) } ?? [:]
        let restored = makePane(id: id, cwd: p.cwd, initialInput: input, extraEnvironment: env)
        if input == nil { restoreScrollback(savedID: p.id, into: restored) }
        restored.title = p.title ?? ""
        restored.claudeSessionID = session
        // The shell prints its prompt (a title change) before the typed resume starts the agent:
        // without this, that prompt reads as "the agent is gone" and drops the session, which
        // only a hook (SessionStart) would bring back (none without hooks: an import, untrusted Codex).
        if let session { markRelaunching(restored, session) }
        restored.agentKind = agent
        restored.resumeCommand = session == nil ? nil : p.resumeCommand
        restored.resumeEnvironment = env
        restored.transcriptPath = session == nil ? nil : p.transcriptPath.flatMap { TranscriptPath.isValid($0) ? $0 : nil }
        if let ts = p.titleState { restored.titleState = ts }
        restored.titleSession = p.titleSession
        restored.pinned = p.pinned == true
        if let session, let t = p.doneAt {
            restored.agent = .restoredDone
            restored.alertDetail = p.alertDetail
            restored.lastAlertAt = Date(timeIntervalSince1970: t)
            restored.attentionSince = p.attentionSince.map(Date.init(timeIntervalSince1970:))
            restored.restoredDoneSession = session
        }
        restored.surface.setOcclusion(visible: false)
        return restored
    }
}
