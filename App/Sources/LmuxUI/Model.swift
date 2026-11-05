import AppKit
import LmuxHooks
import LmuxTerminal
import LmuxTokens
import Observation

public enum SplitAxis: String, Codable {
    /// Children side by side (divider is vertical). Ghostty `new_split:right`.
    case horizontal
    /// Children stacked (divider is horizontal). Ghostty `new_split:down`.
    case vertical
}

public enum FocusDirection { case left, right, up, down, previous, next }

/// What a sidebar row (or a pane) shows on line 2.
public enum AgentDisplay: Equatable {
    case idle
    case running(String?)
    case needsInput(String?)
    case done(String?)
    case failed(String?)

    /// The state as a word, for rows without a detail ("Needs input", "Working…"). Idle has none:
    /// a row never says "Idle".
    public var label: String {
        switch self {
        case .idle: return ""
        case .running: return "Working…"
        case .needsInput: return "Needs input"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    /// Machine name of the state (`lmux list`).
    public var stateName: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .needsInput: return "needs input"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    public var detail: String? {
        switch self {
        case .idle: return nil
        case .running(let d), .needsInput(let d), .done(let d), .failed(let d): return d
        }
    }

    var priority: Int {
        switch self {
        case .needsInput: return 4
        case .running: return 3
        case .failed: return 2
        case .done: return 1
        case .idle: return 0
        }
    }
}

/// One terminal pane: a libghostty surface plus what lmux knows about it.
@MainActor @Observable
public final class Pane: Identifiable {
    /// Also `LMUX_PANE_ID` in the pane's environment.
    public let id: String
    @ObservationIgnored public let surface: SurfaceView
    @ObservationIgnored public private(set) lazy var view = PaneView(pane: self)
    @ObservationIgnored public weak var workspace: Workspace?

    /// Terminal title (OSC 0/2).
    public var title: String = ""
    /// Working directory (OSC 7 via Ghostty's pwd action).
    public var cwd: String?
    public var branch: String?

    // Agent awareness
    public var agent = PaneAgent() {
        didSet { if agent.state != oldValue.state { agentStateChanged() } }
    }
    /// Last main-agent tool name while running.
    public var lastTool: String?
    /// Detail text of the last alert (permission message, last reply, error).
    public var alertDetail: String?
    /// The last alert was a failure (StopFailure); shown until the next turn.
    public var failed = false {
        didSet { if failed != oldValue { agentStateChanged() } }
    }
    /// When the state `lmux list` shows last changed, and when lmux last typed into the pane on
    /// request (`lmux send`, `new-workspace --cmd`): `lmux wait` only ends on a state that came after.
    @ObservationIgnored var stateChangedAt = Date.distantPast
    @ObservationIgnored var lastSentAt: Date?
    /// Alerts that arrived while the pane was not focused.
    public var unread = 0 {
        didSet { if unread == 0, oldValue > 0 { workspace?.model?.markNotificationsRead(pane: id) } }
    }
    public var lastAlertAt: Date?
    /// A pinned tab sits at the front of its pane's strip and doesn't close (×, ⌘W, Close Others).
    public var pinned = false
    /// Done / needs input and nobody has looked yet: when that started (nil once attended).
    @ObservationIgnored public var attentionSince: Date?
    /// Restored done (layout.json): the resumed agent's own SessionStart for this session keeps
    /// that state instead of resetting it.
    @ObservationIgnored var restoredDoneSession: String?
    /// Claude Code (or Codex) session running here (from hook events), for resume on restore.
    public var claudeSessionID: String?
    /// Which agent that session belongs to (the hook events say; persisted).
    public var agentKind: AgentKind = .claude
    /// pid of the claude process running that session (from lmux-hook), if known.
    @ObservationIgnored var claudePID: Int32?
    /// Its replayable environment (`CLAUDE_CONFIG_DIR`, …) as lmux-hook reported it.
    @ObservationIgnored var claudeEnvironment: [String: String] = [:]
    /// The command that resumes that session with the flags it was started with
    /// (`claude --model x … --resume <id>`), captured at SessionStart, persisted.
    public var resumeCommand: String?
    /// Replayable env of that claude (allowlisted names only), handed to a restored pane's shell.
    public var resumeEnvironment: [String: String] = [:]
    /// That session's transcript (hook `transcript_path`; Codex: its rollout file).
    public var transcriptPath: String?
    /// The last reply as the agent reported it (Stop `last_assistant_message`), for Copy original.
    @ObservationIgnored var lastReply: String?
    /// When that reply came, and when the pane's last prompt was submitted: a reply from before
    /// the prompt is the turn before (`lmux wait` doesn't print it).
    /// (Monotonic: `ProcessInfo.systemUptime`, a clock step can't reorder them.)
    @ObservationIgnored var lastReplyAt: TimeInterval?
    @ObservationIgnored var promptAt: TimeInterval?
    /// The codex here reports its own state (OSC 7501): its last report, nil when it doesn't
    /// (or left). Then that drives the pane's state and alerts, not hooks.
    @ObservationIgnored var codexReport: SurfaceView.ProgramStatus.State?
    /// When that codex last started a turn (working after idle / done): how a session whose
    /// hooks come from Codex's shared app-server is matched to this pane.
    @ObservationIgnored var codexTurnStartedAt: Date?
    /// That turn start, once a session's prompt in this pane accounted for it.
    @ObservationIgnored var codexTurnClaimed: Date?
    /// The current turn's reply and permission request as hooks told them (the alerts' text).
    @ObservationIgnored var codexTurnReply: String?
    @ObservationIgnored var codexAsk: String?
    /// A codex ran here (reported or hooked): its token may live on in Codex's shared app-server.
    @ObservationIgnored var ranCodex = false
    /// Reports held back while a session's hooks wait for their pane (see `programStatus`).
    @ObservationIgnored var codexHeld: [SurfaceView.ProgramStatus] = []
    /// Another program reports its own state here (OSC 7501 `app=<name>`, `otherProgramStatus`):
    /// its name, its last report and the foreground job it came from. nil when none does.
    @ObservationIgnored var programApp: String?
    @ObservationIgnored var programReport: SurfaceView.ProgramStatus.State?
    @ObservationIgnored var programKind: String?
    @ObservationIgnored var programGroup: pid_t = 0
    /// The user typed while it waited for them: its next `blocked` is a new ask, not a repeat.
    @ObservationIgnored var programAnswered = false
    /// Fires when the reporter's process exits (kqueue, no polling): a reporter that dies without
    /// `clear` doesn't leave the row running until the next title change.
    @ObservationIgnored var programExitWatch: DispatchSourceProcess?
    /// The reporter that exited (forgotten): its last words, still on their way through the pty,
    /// count once until the next title change.
    @ObservationIgnored var lastWords: (app: String, group: pid_t)?
    /// The foreground job's argv, looked up once per job (`fromReporter`): a file full of reports
    /// costs one process lookup, and one "ignored" log line (the job it was logged for).
    @ObservationIgnored var programArgv: (group: pid_t, argv: [String])?
    /// Drops `programArgv` when that job's leader execs (kqueue): a shell that forked the next job
    /// becomes it in place, same group.
    @ObservationIgnored var programArgvWatch: DispatchSourceProcess?
    @ObservationIgnored var programIgnoredLogged: pid_t = 0
    /// Title of the Claude session in this pane (R16: Claude's own, or a manual name), persisted.
    public var titleState = TitleState()
    /// Session the title state belongs to (a new session starts a new auto title).
    public var titleSession: String?
    /// A rewind (edit / remove / undo) is in progress: message actions are disabled.
    public var busy = false
    /// Claude Code was rewound to just before this turn (uuid): it and the turns after it are gone
    /// from the conversation, though still in the transcript until Claude writes its next prompt
    /// on a new branch. Hidden from hover meanwhile; cleared by the next SessionStart.
    @ObservationIgnored var rewoundFrom: String?
    /// When the user last pressed Esc here (not Ctrl+C): a rewind's Esc waits out Claude's
    /// double-press window after it.
    @ObservationIgnored var lastEscKey: Date?
    /// The rewind running here (its delayed "Rewinding…" note checks it's still this one).
    @ObservationIgnored var rewindToken: UUID?
    /// What a rewind that ended while this pane was hidden has to say (and whether it failed),
    /// shown when it shows again.
    @ObservationIgnored var pendingRewindNote: (String, Bool)?
    /// The running rewind found this pane hidden and stopped without a key.
    @ObservationIgnored var rewindStoppedHidden = false
    /// …leaving Claude's rewind menu open: closed when the pane shows again.
    @ObservationIgnored var rewindMenuLeftOpen = false
    /// A restore is relaunching Claude on this session: it counts as open (not in History) until
    /// the pane's next SessionStart.
    public var relaunchingSessionID: String?
    /// Where the cursor was at the pane's last frame (the input label follows Claude's input box).
    @ObservationIgnored var lastFrameCursorY = -1.0
    /// Last plain Return the user sent here (to tell typed prompts from automation).
    @ObservationIgnored var lastReturnAt: Date?
    /// A new empty shell lmux opened (⌘N or nothing to restore), not a restored one.
    @ObservationIgnored var startedPlain = false
    /// Transcript size at that Return (Undo only considers turns written after it).
    @ObservationIgnored var lastReturnOffset = 0
    /// Hooks hint (HooksHint.swift): a hook event came from this pane, the one deferred check
    /// pending, and whether the hint was shown (once per pane).
    @ObservationIgnored var hooksHeard = false
    @ObservationIgnored var hooksHintCheck: DispatchWorkItem?
    @ObservationIgnored var hooksHinted = false
    /// The foreground process name per foreground group (`ClaudeProcess.foregroundName`).
    @ObservationIgnored var foregroundCache: (group: pid_t, name: String?)?
    /// Screen -> turn mapping cache for hover actions.
    @ObservationIgnored var hover = HoverCache()
    /// Whether this pane is the visible + focused one (drives the ring).
    public var isFocused = false
    /// The last sign of life from the agent here: a hook event, a new terminal title (Claude's
    /// working spinner), an accepted OSC 7501 report (`noteAgentActivity`), or its screen changed
    /// since the last look (`updateAttention`).
    @ObservationIgnored var lastActivityAt = Date()
    /// That last look at the screen: its `activeTextHash` and when.
    @ObservationIgnored var screenHash: Int?
    @ObservationIgnored var screenSampledAt = Date.distantPast
    /// When a usage-limit wait ends by itself (reset time + grace) if Claude says nothing, and
    /// whether that reset time was read (else a 5 h fallback).
    @ObservationIgnored var usageLimitDeadline: Date?
    @ObservationIgnored var usageLimitKnownReset = true
    /// Running, yet nothing came for `LmuxController.quietAfter`: minutes since (a hint on the row, not a state).
    public internal(set) var quietMinutes: Int?
    /// The session's `permission_mode` (main agent's hook events), for the header's badge.
    @ObservationIgnored var permissionMode: String?

    init(id: String, surface: SurfaceView) {
        self.id = id
        self.surface = surface
    }

    public var display: AgentDisplay {
        switch agent.state {
        case .idle: return .idle
        case .running: return .running(runningDetail)
        case .needsInput: return .needsInput(alertDetail)
        case .done: return failed ? .failed(alertDetail) : .done(alertDetail)
        }
    }

    /// Line 2 while running: waiting for a usage limit, else the quiet hint, else the last tool.
    var runningDetail: String? {
        if let r = agent.usageLimitResets { return "waiting for usage limit · resets \(r)" }
        if let m = quietMinutes { return "no output for \(m)m" }
        return lastTool
    }

    /// Subagents of the running turn (0 otherwise).
    public var subagentCount: Int { agent.state == .running ? agent.activeSubagents.count : 0 }

    /// The header's badge for a mode in which the agent acts without asking: nil otherwise.
    public var modeBadge: String? {
        switch permissionMode {
        case "bypassPermissions": return "bypass"
        case "auto": return "auto"
        default: return nil
        }
    }

    private func agentStateChanged() {
        stateChangedAt = Date()
        workspace?.model?.onAgentStateChange?(self)
    }

    /// Which agent runs here, as `lmux list` names it: claude, codex, or the `app=` of a program
    /// that reports its own state (OSC 7501). nil: none.
    public var agentName: String? {
        if runsClaude { return agentKind.rawValue }
        if codexReport != nil { return "codex" }
        return programApp
    }

    public var needsInput: Bool {
        if case .needsInput = agent.state { return true }
        return false
    }

    /// The pane's own title (POLISH.md 4): the Claude session title, else a meaningful terminal
    /// title, else the cwd's folder ("Home" for ~). Empty means "nothing meaningful yet".
    public var headerTitle: String {
        if let t = sessionTitle { return t }
        return shellTitle
    }

    /// The Claude session title (auto, `/rename` or manual), cleaned; nil when there is none.
    var sessionTitle: String? {
        guard let raw = titleState.title else { return nil }
        let t = Pane.displayTitle(raw)
        return t.isEmpty ? nil : t
    }

    /// The terminal title when it names something (a running command), else the cwd's folder.
    var shellTitle: String { terminalTitle ?? cwdTitle ?? "" }

    /// A terminal title worth showing: not a path (zsh's `user@host:~/x`, Ghostty's `…/x/y`), not
    /// a generic "Claude Code" / "claude". Cleaned like every title.
    var terminalTitle: String? {
        let t = Pane.displayTitle(title)
        if t.isEmpty || Pane.isPathTitle(t) { return nil }
        if ["claude code", "claude", "codex"].contains(t.lowercased()) { return nil }
        return t
    }

    /// The cwd's last component: `~` is "Home", `/` is "/". Without a cwd, the folder of a path title.
    var cwdTitle: String? {
        if let c = cwd, !c.isEmpty { return Pane.folderTitle(c) }
        let t = Pane.displayTitle(title)
        if Pane.isPathTitle(t) {
            if let colon = t.firstIndex(of: ":"), t.contains("@") { return Pane.folderTitle(String(t[t.index(after: colon)...])) }
            return Pane.folderTitle(t)
        }
        return nil
    }

    static func folderTitle(_ path: String) -> String {
        if path == "/" { return "/" }
        if path == "~" || path == NSHomeDirectory() || path == NSHomeDirectory() + "/" { return "Home" }
        return (path as NSString).lastPathComponent
    }

    /// The title cap (characters) everywhere a title is shown.
    static let titleCap = 48

    /// Cleaning every title source goes through: leading status glyphs, a leaked
    /// `" - Session start"` (hook text), capped at 48 characters.
    static func displayTitle(_ raw: String) -> String {
        var t = stripLeakedSuffix(cleanTitle(raw))
        if t.count > titleCap { t = String(t.prefix(titleCap - 1)).trimmingCharacters(in: .whitespaces) + "…" }
        return t
    }

    /// Hook text that leaks into a session title (`Fix login - Session start`).
    static let leakedSuffixes = [" - session start", " — session start", " – session start", " - session"]

    static func stripLeakedSuffix(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let s = leakedSuffixes.first(where: { t.lowercased().hasSuffix($0) }) {
            t = String(t.dropLast(s.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// A terminal title as lmux shows it: without the spinner / status glyphs programs put in
    /// front (Claude Code: `✳ Claude Code`, `⠋ Working`), trimmed.
    static func cleanTitle(_ raw: String) -> String {
        let glyphs = Set("·•*◐◓◑◒●○◔◕⏺◉⚡︎")
        var s = Substring(raw)
        while let ch = s.first, ch.isWhitespace || glyphs.contains(ch)
                || ch.unicodeScalars.allSatisfy({ (0x2700...0x27BF).contains($0.value) || (0x2800...0x28FF).contains($0.value)
                    || $0.value == 0xFE0F }) {
            s = s.dropFirst()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// `/x/y`, `~`, `~/x`, `…/x/y` (Ghostty's shell integration abbreviates long cwds), and
    /// zsh's default `user@host:path`.
    static func isPathTitle(_ t: String) -> Bool {
        if t.hasPrefix("/") || t == "~" || t.hasPrefix("~/") || t.hasPrefix("…/") || t.hasPrefix(".../") { return true }
        return t.range(of: #"^[^\s@]+@[^\s:]+:\S*$"#, options: .regularExpression) != nil
    }

    /// Claude Code (or Codex) is running in this pane (between SessionStart and SessionEnd).
    public var runsClaude: Bool { claudeSessionID != nil }
    /// Codex runs here: Claude-only actions (edit, remove, undo send) are not offered.
    public var runsCodex: Bool { runsClaude && agentKind == .codex }

    /// The ring shows on a pane that wants attention and is not the focused one.
    /// Rings mean "needs you": only an unfocused pane waiting for input (unread alone is a badge).
    public var showsRing: Bool { !isFocused && needsInput }
}

/// A node of a workspace's split tree.
@MainActor
public final class SplitNode {
    public enum Content {
        case pane(Pane)
        case split(SplitAxis, SplitNode, SplitNode)
    }
    /// A leaf shows `.pane(tab)`, the selected one of its `tabs`.
    public var content: Content
    /// A leaf's terminals (tabs) in strip order, the shown one among them; empty for a split.
    /// One tab is a plain pane (no strip).
    public var tabs: [Pane] = []
    /// Fraction of the space given to the first child.
    public var ratio: CGFloat = 0.5
    public weak var parent: SplitNode?

    init(_ content: Content) {
        self.content = content
        switch content {
        case .pane(let p): tabs = [p]
        case .split(_, let a, let b): a.parent = self; b.parent = self
        }
    }

    convenience init(pane: Pane) { self.init(.pane(pane)) }

    /// A leaf of several tabs, `selected` shown.
    convenience init(tabs: [Pane], selected: Int) {
        self.init(.pane(tabs[min(max(selected, 0), tabs.count - 1)]))
        self.tabs = tabs
    }

    /// Every pane in reading order (left-to-right, top-to-bottom), each leaf's tabs in strip order.
    public var panes: [Pane] {
        switch content {
        case .pane: return tabs
        case .split(_, let a, let b): return a.panes + b.panes
        }
    }

    /// The panes on screen: each leaf's shown tab.
    public var visiblePanes: [Pane] {
        switch content {
        case .pane(let p): return [p]
        case .split(_, let a, let b): return a.visiblePanes + b.visiblePanes
        }
    }

    /// The leaf showing `pane` or holding it as a tab.
    func find(_ pane: Pane) -> SplitNode? {
        switch content {
        case .pane: return tabs.contains { $0 === pane } ? self : nil
        case .split(_, let a, let b): return a.find(pane) ?? b.find(pane)
        }
    }

    /// The leaf's shown tab (nil for a split).
    var shownTab: Pane? {
        if case .pane(let p) = content { return p }
        return nil
    }

    /// The leaf's tab strip (made the first time it shows).
    private(set) lazy var strip = TabStripView(node: self)
    /// More than one tab (saved as tabs, ⌘W closes a tab).
    var hasTabs: Bool { tabs.count > 1 }
    /// The strip shows on every leaf (cmux's default), or only on one with tabs (the setting off).
    static var stripWithOneTab = true
    var hasStrip: Bool { !tabs.isEmpty && (hasTabs || Self.stripWithOneTab) }
    /// Pinned tabs come first: a tab may go no further left than this, an unpinned one no further right.
    var pinnedCount: Int { tabs.prefix { $0.pinned }.count }

    var leafCount: Int {
        switch content {
        case .pane: return 1
        case .split(_, let a, let b): return a.leafCount + b.leafCount
        }
    }
}

/// A workspace (a sidebar row): a split tree of panes.
@MainActor @Observable
public final class Workspace: Identifiable {
    public let id: String
    /// Manual name; locks the title (auto titles come in a later phase).
    public var customTitle: String?
    /// Index into `LmuxTokens.Colors.workspaceAccents`.
    public var accent: Int
    @ObservationIgnored public var root: SplitNode
    /// Mirrors `root.panes`; observed so the sidebar updates on structure changes.
    public private(set) var panes: [Pane] = []
    /// Left unattended past the reminder delay (the row's glyph breathes): since when.
    public internal(set) var unattendedSince: Date?
    public var focusedPane: Pane?
    /// Latest `lmux notify` text, shown on line 2 when no agent state is more relevant.
    public var notification: String?
    /// Split zoom (Ghostty's `toggle_split_zoom`): the one pane shown full-size, the rest hidden
    /// until toggled back. Saved in layout.json, so a relaunch comes back zoomed.
    public var zoomedPane: Pane?

    init(id: String, accent: Int, root: SplitNode) {
        self.id = id
        self.accent = accent
        self.root = root
        structureChanged()
    }

    func structureChanged() {
        panes = root.panes
        for p in panes { p.workspace = self }
        // Focus and zoom are on shown tabs only.
        let shown = root.visiblePanes
        if let f = focusedPane, !shown.contains(where: { $0 === f }) { focusedPane = root.find(f)?.shownTab ?? shown.first }
        if focusedPane == nil { focusedPane = shown.first }
        if let z = zoomedPane, !shown.contains(where: { $0 === z }) { zoomedPane = root.find(z)?.shownTab }
    }

    /// Zoomed on a pane that's still here (closing / splitting unzooms first; this is a safety net).
    public var isZoomed: Bool { zoomedPane != nil }

    /// More than one pane on screen (tabs of one leaf don't count).
    var isSplit: Bool { root.leafCount > 1 }

    /// The panes on screen (each split leaf's shown tab).
    var visiblePanes: [Pane] { root.visiblePanes }

    /// Pane header texts: each pane's own title (auto > shell > cwd); panes whose titles
    /// collide get a distinguishing suffix (the last path component where their cwds differ,
    /// else their position).
    /// A pane whose title is the workspace title (already in the content header) shows what runs
    /// in it instead (`running`: "Claude Code", "zsh", the command), so no string repeats.
    func headerTitles(running: (Pane) -> String? = { _ in nil }) -> [ObjectIdentifier: String] {
        var out: [ObjectIdentifier: String] = [:]
        let shown = title
        func own(_ p: Pane) -> String {
            let t = p.headerTitle
            return t == shown ? (running(p) ?? t) : t
        }
        let groups = Dictionary(grouping: panes.enumerated(), by: { own($0.element) })
        for (title, members) in groups {
            if members.count == 1 || title.isEmpty {
                for m in members { out[ObjectIdentifier(m.element)] = title }
                continue
            }
            let cwds = members.map { $0.element.cwd ?? "" }
            let distinct = Set(cwds).count == cwds.count && !cwds.contains("")
            for (i, m) in members {
                var suffix = "\(i + 1)"
                if distinct, let c = m.cwd {
                    // The deepest component that differs from every other pane's cwd.
                    let mine = c.split(separator: "/")
                    let others = cwds.filter { $0 != c }.map { $0.split(separator: "/") }
                    if let k = mine.indices.reversed().first(where: { k in others.allSatisfy { $0.count <= k || $0[k] != mine[k] } }) {
                        suffix = String(mine[k])
                    }
                }
                out[ObjectIdentifier(m)] = "\(title) · \(suffix)"
            }
        }
        return out
    }

    /// Pane whose cwd/branch the row shows: the focused one.
    var primary: Pane? { focusedPane ?? panes.first }

    /// Set by `AppModel` (title disambiguation looks at the other workspaces).
    @ObservationIgnored weak var model: AppModel?

    /// The row title (POLISH.md 4): a manual name, else the focused pane's session title,
    /// terminal title or folder, else "Terminal". Rows that share a title keep it; line 2
    /// tells them apart (`disambiguator`).
    public var title: String {
        if let t = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return Pane.displayTitle(t) }
        return baseTitle
    }

    var baseTitle: String {
        if let t = primary?.headerTitle, !t.isEmpty { return t }
        return "Terminal"
    }

    /// Where the title came from the cwd (the folder name), so the header doesn't repeat the path.
    var titleIsFolder: Bool {
        guard (customTitle ?? "").isEmpty, let p = primary else { return false }
        return p.sessionTitle == nil && p.terminalTitle == nil
    }

    /// Line 2 of an idle row whose title another row also shows (`AppModel.disambiguators`).
    public var disambiguator: String? { model?.disambiguators()[id] }

    /// The row has a line 2 (46pt instead of 30pt).
    public var showsStateLine: Bool { rowDetail(now: Date()) != nil }

    /// The state the row shows (one indicator). Without hooks, Claude Code's own notifications
    /// (OSC 9) still say what it is doing; they get the same glyph as the hook path: "needs your
    /// permission" is needs input (dot), "waiting for your input" (its idle prompt) is done (check).
    public var rowState: AgentDisplay {
        let d = display
        guard case .idle = d, let n = notification else { return d }
        let t = n.lowercased()
        if ["needs your permission", "needs your attention", "has a question"].contains(where: t.contains) { return .needsInput(n) }
        if ["waiting for your input", "waiting for input"].contains(where: t.contains) { return .done(n) }
        return d
    }

    /// Line 2 of the row (POLISH.md 4), nil when there's nothing to say (a 1-line row).
    public struct RowDetail: Equatable {
        public enum Tone: Equatable { case needsInput, secondary, tertiary }
        public let text: String
        public let tone: Tone
        /// "4m" on a Done / Failed row, "3 subagents" on a running one (right-aligned).
        public let age: String?
        /// The text is a branch name (drawn after a branch glyph).
        public let isBranch: Bool

        public init(text: String, tone: Tone, age: String? = nil, isBranch: Bool = false) {
            self.text = text
            self.tone = tone
            self.age = age
            self.isBranch = isBranch
        }
    }

    public func rowDetail(now: Date) -> RowDetail? { rowDetail(now: now, disambiguator: disambiguator) }

    /// `disambiguator`: this row's entry of `AppModel.disambiguators()` (the sidebar computes them
    /// once for all rows), read only for an idle row.
    public func rowDetail(now: Date, disambiguator: @autoclosure () -> String?) -> RowDetail? {
        func first(_ s: String?) -> String? {
            guard let s else { return nil }
            var line = s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            // The indicator already says the state: no "Needs input · …" label words.
            for w in ["Needs input", "Running", "Done", "Failed"] where line.hasPrefix(w + " · ") || line.hasPrefix(w + ": ") {
                line = String(line.dropFirst(w.count + 3))
            }
            return line.isEmpty ? nil : line
        }
        switch rowState {
        case .needsInput(let d): return RowDetail(text: first(d) ?? "Needs input", tone: .needsInput, age: nil, isBranch: false)
        case .running(let tool):
            // The running pane's subagents, on the right where a finished row shows its age.
            let n = statePane?.subagentCount ?? 0
            return RowDetail(text: first(tool) ?? "Working…", tone: .secondary,
                             age: n > 0 ? "\(n) subagent\(n == 1 ? "" : "s")" : nil, isBranch: false)
        case .done(let d): return RowDetail(text: first(d) ?? "Done", tone: .secondary, age: elapsed(now: now), isBranch: false)
        case .failed(let d): return RowDetail(text: first(d) ?? "Failed", tone: .secondary, age: elapsed(now: now), isBranch: false)
        case .idle:
            if let n = first(notification) { return RowDetail(text: n, tone: .secondary, age: nil, isBranch: false) }
            if let d = disambiguator() {
                let isBranch = primary?.branch.map { !$0.isEmpty && d.hasPrefix($0) } ?? false
                return RowDetail(text: d, tone: .tertiary, age: nil, isBranch: isBranch)
            }
            return nil
        }
    }

    /// The most relevant agent state across panes (needs input > running > failed > done).
    public var display: AgentDisplay { statePane?.display ?? .idle }

    /// The pane `display` comes from (nil when every pane is idle).
    var statePane: Pane? {
        var best: Pane?
        var bestPriority = 0
        var bestAt = Date.distantPast
        for p in panes {
            let pr = p.display.priority
            let at = p.lastAlertAt ?? .distantPast
            if pr > bestPriority || (pr > 0 && pr == bestPriority && at > bestAt) {
                best = p
                bestPriority = pr
                bestAt = at
            }
        }
        return best
    }

    /// The row's agent is running but waiting for a usage limit: a still clock, not the spinner.
    public var waitsForUsageLimit: Bool {
        guard case .running = rowState else { return false }
        return statePane?.agent.usageLimitResets != nil
    }

    public var unread: Int { panes.reduce(0) { $0 + $1.unread } }

    /// When the row's Done / Failed state came in (nil for any other state).
    var finishedAt: Date? {
        let d = display
        switch d {
        case .done, .failed: return panes.filter { $0.display == d }.compactMap(\.lastAlertAt).max()
        default: return nil
        }
    }

    /// "4m" since a Done / Failed row's alert (nil otherwise, and in its first minute).
    public func elapsed(now: Date) -> String? {
        guard let at = finishedAt else { return nil }
        let m = Int(now.timeIntervalSince(at) / 60)
        if m < 1 { return nil }
        if m < 60 { return "\(m)m" }
        if m < 24 * 60 { return "\(m / 60)h" }
        return "\(m / (24 * 60))d"
    }

    /// The content header's meta (POLISH.md 5): the branch and `~/path`, each left out when it
    /// would only repeat the title or say nothing (`~`, the folder the title came from).
    public var headerMeta: (branch: String?, path: String?) {
        guard let p = primary else { return (nil, nil) }
        let branch = p.branch.flatMap { $0.isEmpty ? nil : $0 }
        var path = p.cwd.map(abbreviateHome)
        if let x = path, x == "~" || x == title || x.isEmpty || (titleIsFolder && branch == nil) { path = nil }
        return (branch, path)
    }

    /// Row tooltip: full `~/path` and branch.
    public var rowHelp: String {
        let (b, _) = headerMeta
        let path = primary?.cwd.map(abbreviateHome) ?? ""
        return [path, b.map { "branch " + $0 } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One entry of the bell's list: an agent alert (needs input, done, failed) or a CLI notify.
public struct NotificationEntry: Identifiable, Equatable {
    public let id: UUID
    public let paneID: String?
    public let workspaceID: String?
    /// The workspace's title when it was posted (the row shows the current one while it exists).
    public let title: String
    public let message: String
    public let kind: String
    public let date: Date
    public var read: Bool

    public init(paneID: String?, workspaceID: String?, title: String, message: String, kind: String,
                date: Date = Date(), read: Bool) {
        id = UUID()
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.title = title
        self.message = message
        self.kind = kind
        self.date = date
        self.read = read
    }
}

@MainActor @Observable
public final class AppModel {
    public var workspaces: [Workspace] = [] { didSet { for w in workspaces { w.model = self } } }
    public var selectedID: String?
    public var sidebarVisible = true
    public var sidebarWidth: CGFloat = LmuxTokens.Layout.sidebarWidthDefault
    /// What the sidebar's elapsed times are measured against: moved by a minute tick that
    /// only runs while a visible sidebar shows a Done / Failed row.
    public var clock = Date()
    /// A pane's agent state changed (`lmux wait` looks then; nil while nothing waits).
    @ObservationIgnored var onAgentStateChange: ((Pane) -> Void)?

    /// Sidebar multi-selection (⌘-click / ⇧-click, Finder conventions): the selected rows' IDs, the
    /// active workspace (`selectedID`, the one on screen) among them. Empty = just the active one.
    public var selection: Set<String> = []
    /// Where a ⇧-click range starts: the last plain or ⌘-clicked row.
    public var selectionAnchorID: String?
    /// The sidebar row under the pointer (shows the ×).
    public var hoveredRowID: String?
    /// A sidebar row drag-to-reorder in progress (press-and-drag past a small threshold).
    public struct SidebarDrag: Equatable {
        /// Workspace ids moving (the dragged row, or the selection it's part of), in sidebar order.
        public let ids: [String]
        /// The row the press started on (the one under the pointer).
        public let grabbedID: String
        /// Where they'd land if dropped now: how many of the other rows sit above the pointer.
        public var dropIndex: Int
    }
    /// Changes only when the drop slot does (a few times per drag), so the rows re-lay out their
    /// offsets then, not on every mouse move.
    public var sidebarDrag: SidebarDrag?
    /// The live pointer of that drag, set on every mouse move: read only by the lifted rows (they
    /// follow it) and the auto-scroller, so a move re-renders nothing else.
    public struct SidebarDragPointer: Equatable {
        /// The sidebar's "sidebarRows" coordinate space, for auto-scroll.
        public var y: CGFloat
        /// How far the pointer has moved vertically since the press.
        public var translation: CGFloat
    }
    public var sidebarDragPointer: SidebarDragPointer?
    /// Unattended rows may animate: the window and sidebar can be seen and motion isn't reduced.
    public var pulseMotion = true
    /// Reduce Motion is on: unattended rows get a static ring instead of the breathing glyph.
    public var reduceMotion = false

    /// The bell's list, newest first, capped (not persisted).
    public private(set) var notifications: [NotificationEntry] = []
    public static let notificationCap = 50
    public var unreadNotifications: Int { notifications.filter { !$0.read }.count }

    func recordNotification(_ e: NotificationEntry) {
        notifications.insert(e, at: 0)
        if notifications.count > Self.notificationCap { notifications.removeLast(notifications.count - Self.notificationCap) }
    }

    /// The pane was seen (its unread count went to 0): its entries are read.
    func markNotificationsRead(pane: String) {
        for i in notifications.indices where notifications[i].paneID == pane && !notifications[i].read { notifications[i].read = true }
    }

    func markNotificationsRead(id: UUID) {
        if let i = notifications.firstIndex(where: { $0.id == id }) { notifications[i].read = true }
    }

    func markAllNotificationsRead() {
        for i in notifications.indices where !notifications[i].read { notifications[i].read = true }
    }

    public var selected: Workspace? { workspaces.first { $0.id == selectedID } }
    public var isMultiSelection: Bool { selection.count > 1 }
    /// The row draws a selection pill: the active row, or any row of a multi-selection.
    public func isInSelection(_ ws: Workspace) -> Bool {
        isMultiSelection ? selection.contains(ws.id) : ws.id == selectedID
    }
    /// The selected workspaces in sidebar order (the active one alone without a multi-selection).
    public var selectedWorkspaces: [Workspace] {
        isMultiSelection ? workspaces.filter { selection.contains($0.id) } : (selected.map { [$0] } ?? [])
    }
    public var totalUnread: Int { workspaces.reduce(0) { $0 + $1.unread } }

    /// Line 2 of idle rows whose title another row also shows, by workspace id: the branch, else
    /// the deepest path component where the cwds differ (compared from the folder up: `~/a/lmux`
    /// vs `~/b/lmux` -> "a" / "b"), else the path; rows that still collide get " · 2", " · 3".
    /// One pass over all rows (a row never looks at the others itself).
    public func disambiguators() -> [String: String] {
        var out: [String: String] = [:]
        for (_, same) in Dictionary(grouping: workspaces, by: \.title) where same.count > 1 {
            let paths = same.map { Array(($0.primary?.cwd ?? "").split(separator: "/").reversed()) }
            var count: [String: Int] = [:]
            for (i, w) in same.enumerated() {
                let base: String
                if let b = w.primary?.branch, !b.isEmpty {
                    base = b
                } else if let k = paths[i].indices.first(where: { k in
                    paths.indices.allSatisfy { j in j == i || paths[j].count <= k || paths[j][k] != paths[i][k] }
                }) {
                    base = String(paths[i][k])
                } else {
                    base = w.primary?.cwd.map { compactPath(abbreviateHome($0)) } ?? ""
                }
                let n = (count[base] ?? 0) + 1
                count[base] = n
                if base.isEmpty { if n > 1 { out[w.id] = "\(n)" } } else { out[w.id] = n == 1 ? base : "\(base) · \(n)" }
            }
        }
        return out
    }

    /// `disambiguators()` for the sidebar, kept current off the view: recomputed after any title,
    /// cwd, branch or row change it read (one observation, no polling) and only stored (so only
    /// observed) when it differs. A busy shell retitling itself no longer re-evaluates the list.
    public private(set) var rowDisambiguators: [String: String] = [:]

    func trackDisambiguators() {
        let names = withObservationTracking { disambiguators() } onChange: { [weak self] in
            // Called before the change lands: look again once it has.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.trackDisambiguators() } }
        }
        if names != rowDisambiguators { rowDisambiguators = names }
    }

    public init() { trackDisambiguators() }
}
