import AppKit
import Darwin
import LmuxSessions
import LmuxTokens
import Observation
import SwiftUI

private typealias T = LmuxTokens

// History (R12): closed Claude Code sessions at the bottom of the sidebar, full-text
// search (Korean too), click / Enter = resume in a new workspace at the session's cwd.
// The index (SQLite FTS) lives in lmux's state dir and is only ever touched on one
// background queue; ~/.claude/projects is read, never written (except an explicit
// restore of an archived transcript, or Move to Trash). Only sessions at risk are
// archived: older than Claude's cleanupPeriodDays - 5, hidden, or being trashed. Refreshes happen at launch and
// after Stop / SessionEnd hooks (debounced) — no polling.

/// `SessionIndex` is not thread-safe; it lives in this box and is used on `queue` only.
private final class IndexBox: @unchecked Sendable {
    var index: SessionIndex?
    var archiving = false
}

@MainActor @Observable
public final class HistoryModel {
    public struct Item: Identifiable, Equatable {
        public var id: String { record.id }
        public let record: SessionRecord
        public let snippet: String?
        public let highlights: [Range<String.Index>]
        public static func == (a: Item, b: Item) -> Bool { a.record == b.record && a.snippet == b.snippet }
    }

    public private(set) var sessions: [SessionRecord] = []
    public private(set) var hits: [SearchHit] = []
    public private(set) var searchedQuery = ""
    public var query = "" {
        didSet { if query != oldValue { selection = 0; scheduleSearch() } }
    }
    public var selection = 0
    /// Bumped by ⇧⌘H (Search History): the field takes the keyboard.
    public var focusRequest = 0
    /// The search field has the keyboard (the panel is open).
    public var fieldFocused = false
    public private(set) var indexing = false
    public private(set) var lastError: String?
    /// Completed refreshes (tests).
    public private(set) var refreshCount = 0

    @ObservationIgnored let queue = DispatchQueue(label: "lmux.history", qos: .utility)
    @ObservationIgnored private let box = IndexBox()
    @ObservationIgnored weak var controller: LmuxController?
    @ObservationIgnored let databaseURL: URL
    @ObservationIgnored public let projectsRoot: URL
    /// Codex CLI's home: its sessions are in History too.
    @ObservationIgnored public let codexHome: URL
    @ObservationIgnored let archiveDirectory: URL
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    @ObservationIgnored private var searchWork: DispatchWorkItem?
    /// The index is in use: a History search was opened once (or the database already existed at
    /// launch). Until then nothing is indexed and Stop events don't refresh it.
    public private(set) var started = false
    /// Not started yet, but Claude Code has sessions to index: the search field shows anyway.
    public private(set) var available = false
    /// Binary that understands `--lmux-index` (the app itself); nil = index in-process.
    @ObservationIgnored public var helper: URL? = {
        guard Bundle.main.bundleIdentifier != nil, let exe = Bundle.main.executableURL,
              exe.lastPathComponent == "lmux" else { return nil }
        return exe
    }()

    static let refreshDebounce: TimeInterval = 2.0

    init(paths: LmuxPaths, controller: LmuxController) {
        self.controller = controller
        databaseURL = paths.stateDir.appendingPathComponent("sessions.db")
        archiveDirectory = paths.stateDir.appendingPathComponent("archive", isDirectory: true)
        projectsRoot = paths.claudeProjects
        codexHome = paths.codexHome
    }

    /// Sessions not open in any pane: what the list shows (search hits: one per session).
    public var items: [Item] {
        let open = controller?.openClaudeSessions() ?? []
        if searchedQuery.isEmpty || query.isEmpty {
            return sessions.lazy.filter { !open.contains($0.id) }.prefix(200)
                .map { Item(record: $0, snippet: nil, highlights: []) }
        }
        var seen = Set<String>()
        var out: [Item] = []
        for h in hits where !open.contains(h.session.id) && seen.insert(h.session.id).inserted {
            out.append(Item(record: h.session, snippet: h.snippet, highlights: h.highlights))
        }
        return out
    }

    public var totalCount: Int { sessions.count }

    // MARK: - Indexing

    /// At launch: a database from an earlier run is kept up to date right away (incremental, cheap,
    /// and archiving runs); without one, the first index waits until History is opened, so someone
    /// who never uses it never pays for it (a first index of a big projects folder takes seconds).
    func launch() {
        if FileManager.default.fileExists(atPath: databaseURL.path) { start(); return }
        let root = projectsRoot, codex = codexHome
        queue.async { [weak self] in
            let found = Self.hasTranscripts(root) || Self.hasCodexSessions(codex)
            DispatchQueue.main.async { MainActor.assumeIsolated { if found { self?.available = true } } }
        }
    }

    /// History was opened (the search field took the keyboard): index now if not yet.
    func start() {
        guard !started else { return }
        refreshNow()
    }

    /// Any `<project>/<session>.jsonl` under the projects folder (stops at the first).
    nonisolated static func hasTranscripts(_ root: URL) -> Bool {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let names = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []
            if names.contains(where: { $0.hasSuffix(".jsonl") }) { return true }
        }
        return false
    }

    /// Any rollout under `<codex home>/sessions/YYYY/MM/DD/` (stops at the first).
    nonisolated static func hasCodexSessions(_ home: URL) -> Bool {
        let fm = FileManager.default
        let root = home.appendingPathComponent("sessions")
        func dirs(_ u: URL) -> [URL] { ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).map { u.appendingPathComponent($0) } }
        for y in dirs(root) { for m in dirs(y) { for d in dirs(m) {
            if ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).contains(where: { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }) {
                return true
            }
        } } }
        return false
    }

    /// Hooks reported a session stopping or ending: refresh a bit later (debounced).
    func scheduleRefresh() {
        guard started else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshNow() } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDebounce, execute: work)
    }

    func refreshNow(completion: (@MainActor () -> Void)? = nil) {
        started = true
        indexing = true
        let box = box, db = databaseURL, root = projectsRoot, archive = archiveDirectory, helper = helper, codex = codexHome
        queue.async { [weak self] in
            var all: [SessionRecord]?
            var err: String?
            do {
                if box.index == nil {
                    box.index = try SessionIndex(databaseURL: db, projectsRoot: root, archiveDirectory: archive, codexHome: codex)
                }
                if let helper, HistoryIndexer.run(helper, "refresh", db: db, root: root, archive: archive, codex: codex,
                                                  qos: .utility) {
                    // Indexed by the helper; nothing left to do here.
                } else {
                    let stats = try box.index?.refresh()
                    // A big (first) index frees a lot; hand it back to the system right away.
                    if (stats?.reindexed ?? 0) > 20 { malloc_zone_pressure_relief(nil, 0) }
                }
                all = try box.index?.sessions()
            } catch {
                err = "\(error)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let all { self.sessions = all }
                    self.lastError = err
                    self.indexing = false
                    self.refreshCount += 1
                    if !self.query.isEmpty { self.scheduleSearch(delay: 0) }
                    completion?()
                }
            }
            // Archive the transcripts Claude's cleanup is about to delete (older than its
            // cleanupPeriodDays - 5, read from settings.json), at background priority so the
            // first run never competes with the UI. Fresh sessions are not copied.
            guard !box.archiving else { return }
            box.archiving = true
            let cutoff = SessionIndex.archiveCutoff(settings: SessionIndex.claudeSettingsURL())
            self?.queue.async(qos: .background) {
                if let helper, HistoryIndexer.run(helper, "archive", db: db, root: root, archive: archive, cutoff: cutoff,
                                                  qos: .background) {
                } else {
                    let n = (try? box.index?.archiveAll(olderThan: cutoff)) ?? 0
                    if n > 20 { malloc_zone_pressure_relief(nil, 0) }
                }
                box.archiving = false
            }
        }
    }

    /// Tests: the open index's Codex home (nil: none open, or opened without Codex); `drop` closes it first.
    func indexCodexHome(drop: Bool = false) async -> URL? {
        let box = box
        return await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            queue.async {
                if drop { box.index = nil }
                c.resume(returning: box.index?.codexHome)
            }
        }
    }

    /// Await a refresh (tests).
    public func refresh() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in refreshNow { c.resume() } }
    }

    /// Wait until queued background work (e.g. archiving) finished (tests).
    public func drain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async(qos: .background) { c.resume() }
        }
    }

    // MARK: - Search

    private func scheduleSearch(delay: TimeInterval = 0.12) {
        searchWork?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { hits = []; searchedQuery = ""; return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.runSearch(q) } }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runSearch(_ q: String, completion: (@MainActor () -> Void)? = nil) {
        let box = box
        queue.async { [weak self] in
            let found = (try? box.index?.search(q, limit: 300)) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q {
                        self.hits = found
                        self.searchedQuery = q
                    }
                    completion?()
                }
            }
        }
    }

    /// Set the query and await its results (tests).
    public func search(_ q: String) async {
        query = q
        searchWork?.cancel()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            runSearch(q.trimmingCharacters(in: .whitespacesAndNewlines)) { c.resume() }
        }
    }

    // MARK: - Actions

    /// Resume in a new workspace at the session's cwd (restoring an archived transcript first).
    public func resume(_ id: String, completion: (@MainActor (Workspace?) -> Void)? = nil) {
        let box = box
        queue.async { [weak self] in
            var info: ResumeInfo?
            var err: String?
            do {
                guard let index = box.index else { throw SessionIndexError.notFound(id) }
                var i = try index.resumeInfo(id)
                if i.needsRestore {
                    try index.restore(id)
                    i = try index.resumeInfo(id)
                }
                info = i
            } catch {
                err = "\(error)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastError = err
                    let ws = info.flatMap { self.controller?.openResumedSession(id, info: $0) }
                    completion?(ws)
                }
            }
        }
    }

    public func resumeSelected() {
        let list = items
        guard !list.isEmpty else { return }
        resume(list[min(max(0, selection), list.count - 1)].record.id)
    }

    public func hide(_ id: String) {
        sessions.removeAll { $0.id == id }
        hits.removeAll { $0.session.id == id }
        let box = box
        queue.async { try? box.index?.setHidden(id) }
    }

    /// Explicit hard delete via the macOS Trash. Returns the trashed items' URLs.
    public func moveToTrash(_ id: String, completion: (@MainActor ([URL]) -> Void)? = nil) {
        sessions.removeAll { $0.id == id }
        hits.removeAll { $0.session.id == id }
        let box = box
        queue.async {
            let urls = (try? box.index?.moveToTrash(id)) ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { completion?(urls) } }
        }
    }

    func confirmMoveToTrash(_ item: Item) {
        guard let c = controller, !c.headless else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(Self.title(item.record))” to the Trash?"
        alert.informativeText = "The transcript and lmux’s archived copy go to the Trash, where you can still put them back."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: c.window) { [weak self] resp in
            if resp == .alertFirstButtonReturn { self?.moveToTrash(item.record.id) }
        }
    }

    // MARK: - Display

    static func title(_ r: SessionRecord) -> String {
        if let t = r.title, !t.isEmpty { return t }
        if let p = r.firstPrompt?.split(whereSeparator: \.isNewline).first { return String(p) }
        return String(r.id.prefix(8))
    }

    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<3600: return "\(max(1, Int(s / 60)))m"
        case ..<86400: return "\(Int(s / 3600))h"
        case ..<(7 * 86400): return "\(Int(s / 86400))d"
        case ..<(35 * 86400): return "\(Int(s / (7 * 86400)))w"
        default: return "\(Int(s / (30 * 86400)))mo"
        }
    }
}

extension LmuxPaths {
    /// Codex CLI's home: LMUX_CODEX_HOME, else $CODEX_HOME, else ~/.codex (only read, except a
    /// rollout moved to the Trash from History).
    public var codexHome: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["LMUX_CODEX_HOME"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return SessionIndex.defaultCodexHome(environment: env)
    }

    /// Claude Code's projects dir: LMUX_CLAUDE_PROJECTS, else $CLAUDE_CONFIG_DIR/projects,
    /// else ~/.claude/projects.
    public var claudeProjects: URL {
        let env = ProcessInfo.processInfo.environment
        if let p = env["LMUX_CLAUDE_PROJECTS"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        if let c = env["CLAUDE_CONFIG_DIR"], !c.isEmpty {
            return URL(fileURLWithPath: c, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        }
        return SessionIndex.defaultProjectsRoot
    }
}

extension LmuxController {
    /// Claude sessions currently running in a pane (shown as workspaces, not History).
    func openClaudeSessions() -> Set<String> {
        Set(model.workspaces.flatMap(\.panes).flatMap { [$0.claudeSessionID, $0.relaunchingSessionID].compactMap { $0 } })
    }

    /// Focus the pane already running `id`, or open a workspace that resumes it.
    @discardableResult
    func openResumedSession(_ id: String, info: ResumeInfo) -> Workspace? {
        if let p = model.workspaces.flatMap(\.panes).first(where: { $0.claudeSessionID == id }) {
            focus(p)
            return p.workspace
        }
        guard ClaudeCommand.isSessionID(id) else { return nil }
        // ` claude --resume <id>` or ` codex resume <id>`: the CLI the session belongs to (leading
        // space: kept out of shell history).
        let cmd = " " + info.arguments.map(ClaudeCommand.shellQuote).joined(separator: " ")
        let ws = newWorkspace(cwd: info.cwdExists ? info.cwd : nil, command: cmd)
        // A Codex pane is that session from the start, as a restored one is: Codex sends its first
        // hook (SessionStart) only with the first prompt, so a quit before that would drop it.
        // (Claude's SessionStart comes at once, and captures its flags and env.)
        if info.arguments.first == "codex", let p = ws.panes.first {
            p.claudeSessionID = id
            markRelaunching(p, id)
            p.agentKind = .codex
            p.resumeCommand = String(cmd.dropFirst())
        }
        return ws
    }
}

// MARK: - View

/// History (POLISH.md 10): a 28pt search field at the sidebar's bottom (⇧⌘H); focused or typed
/// into, a panel grows up from it with the 6 most recent sessions or the search results.
/// Hidden while there is no history at all. The first index runs when the field is first focused.
struct HistorySection: View {
    @Bindable var history: HistoryModel
    @FocusState private var searchFocused: Bool
    @State private var hoverField = false

    private var expanded: Bool { searchFocused || !history.query.isEmpty }
    private var searching: Bool { !history.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        if history.started ? history.totalCount == 0 && !history.indexing : !history.available {
            EmptyView()
        } else {
            let items = Array(history.items.prefix(T.Layout.historyMaxResults))
            VStack(alignment: .leading, spacing: 0) {
                if expanded {
                    panel(items)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                field
                    .padding(.horizontal, T.Layout.rowInsetX)
                    .padding(.top, expanded ? 4 : 0)
                    .padding(.bottom, T.Spacing.s)
            }
            .animation(T.Motion.reduceMotion ? nil : .easeOut(duration: T.Motion.historyExpand), value: expanded)
            .onChange(of: history.focusRequest) { searchFocused = true }
            .onChange(of: searchFocused) {
                history.fieldFocused = searchFocused
                if searchFocused { history.start() }
            }
        }
    }

    private func panel(_ items: [HistoryModel.Item]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(T.Colors.separator.color).frame(height: 1)
            HStack {
                Text("History").font(T.Typography.sectionHeader.font)
                Spacer()
                Text("\(searching ? history.items.count : min(items.count, history.totalCount)) of \(history.totalCount)")
                    .font(T.Typography.rowMeta.font.monospacedDigit())
            }
            .foregroundStyle(T.Colors.textTertiary.color)
            .padding(.horizontal, T.Layout.rowInsetX + T.Layout.rowPaddingX)
            .padding(.top, 10)
            .padding(.bottom, 4)
            if items.isEmpty {
                Text(searching ? "No sessions match “\(history.query)”" : "No closed sessions")
                    .font(T.Typography.rowMeta.font)
                    .foregroundStyle(T.Colors.textTertiary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, T.Layout.rowInsetX + T.Layout.rowPaddingX)
                    .padding(.vertical, 6)
            } else {
                // Six rows tall; the rest scroll. Lazy, so only the rows on screen are built.
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                HistoryRow(item: item, compact: !searching, selected: i == history.selection && expanded,
                                           history: history)
                                    .id(i)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: CGFloat(min(items.count, T.Layout.historyVisibleRows)) * HistoryRow.height(compact: !searching))
                    .onChange(of: history.selection) { proxy.scrollTo(history.selection) }
                    .onChange(of: history.query) { proxy.scrollTo(0, anchor: .top) }
                }
            }
        }
    }

    private var field: some View {
        // Styled as focused while open (focused, or a query is still in it).
        let focused = expanded
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(T.Colors.textTertiary.color)
            TextField("", text: $history.query,
                      prompt: Text(history.indexing && history.totalCount == 0 ? "Indexing history…" : "Search history")
                          .foregroundStyle(T.Colors.textTertiary.color))
                .textFieldStyle(.plain)
                .font(T.Typography.field.font)
                .foregroundStyle(T.Colors.textPrimary.color)
                .focused($searchFocused)
                .onSubmit { history.resumeSelected() }
                .onExitCommand {
                    // Esc clears the query; a second Esc collapses and hands the keyboard back to the pane.
                    if history.query.isEmpty {
                        searchFocused = false
                        // After SwiftUI has let go of the field (it resigns it on its next update,
                        // which would otherwise leave the window with no first responder).
                        DispatchQueue.main.async { history.controller?.focusCurrent() }
                    } else {
                        history.query = ""
                    }
                }
                .onKeyPress(.downArrow) {
                    history.selection = min(history.selection + 1, max(0, min(history.items.count, T.Layout.historyMaxResults) - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) { history.selection = max(0, history.selection - 1); return .handled }
                .accessibilityLabel("History search, \(history.totalCount) sessions")
            if history.indexing && history.totalCount == 0 {
                Spinner(color: T.Colors.textTertiary).frame(width: 10, height: 10)
            } else if focused || !history.query.isEmpty {
                Text("esc").font(.system(size: 11)).foregroundStyle(T.Colors.textTertiary.color)
            } else {
                Text("⇧⌘H").font(.system(size: 11)).foregroundStyle(T.Colors.textTertiary.color)
            }
        }
        .padding(.horizontal, T.Layout.rowPaddingX)
        .frame(height: T.Layout.historySearchHeight)
        .background(RoundedRectangle(cornerRadius: T.Radius.field, style: .continuous)
            .fill(focused ? T.Colors.elevatedBackground.color : (hoverField ? T.Colors.rowSelected.color : T.Colors.rowHover.color)))
        .overlay(RoundedRectangle(cornerRadius: T.Radius.field, style: .continuous)
            .stroke(T.Colors.border.color, lineWidth: 1).opacity(focused ? 1 : 0))
        .overlay(RoundedRectangle(cornerRadius: T.Radius.field + 2.5, style: .continuous)
            .stroke(T.Colors.focusRing.color, lineWidth: 2.5).padding(-2.5).opacity(focused ? 1 : 0))
        .contentShape(Rectangle())
        .onHover { hoverField = $0 }
        .onTapGesture { searchFocused = true }
    }
}

struct HistoryRow: View {
    let item: HistoryModel.Item
    /// Focused with an empty query: one line, title + age (28pt).
    let compact: Bool
    let selected: Bool
    let history: HistoryModel
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(HistoryModel.title(item.record))
                    .font(T.Typography.historyTitle.font)
                    .foregroundStyle(T.Colors.textPrimary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.record.agent == .codex {
                    // Which CLI resumes it: Claude Code rows are unmarked, Codex rows say so, quietly.
                    Text("Codex")
                        .font(.system(size: 10))
                        .foregroundStyle(T.Colors.textTertiary.color)
                        .accessibilityLabel("Codex session")
                }
                if selected || hover {
                    (Text("Resume ") + Text(Image(systemName: "return")))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(T.Colors.accent.color)
                } else {
                    Text(HistoryModel.age(item.record.updatedAt))
                        .font(T.Typography.rowMeta.font.monospacedDigit())
                        .foregroundStyle(T.Colors.textTertiary.color)
                }
            }
            if !compact {
                Text(snippet)
                    .font(T.Typography.historySnippet.font)
                    .foregroundStyle(T.Colors.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, T.Layout.rowPaddingX)
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
            .fill(selected ? T.Colors.rowSelected.color : (hover ? T.Colors.rowHover.color : .clear)))
        .padding(.horizontal, T.Layout.rowInsetX)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { history.resume(item.record.id) }
        .contextMenu {
            Button("Resume") { history.resume(item.record.id) }
            Divider()
            Button("Hide") { history.hide(item.record.id) }
            Button("Move to Trash…") { history.confirmMoveToTrash(item) }
        }
        .help(item.record.cwd.map(abbreviateHome) ?? "")
    }

    private var rowHeight: CGFloat { Self.height(compact: compact) }
    static func height(compact: Bool) -> CGFloat { compact ? 28 : T.Layout.historyRowHeight }

    private var snippet: AttributedString {
        guard let s = item.snippet else {
            let first = item.record.firstPrompt?.split(whereSeparator: \.isNewline).first.map(String.init)
            return AttributedString(first ?? item.record.cwd.map(abbreviateHome) ?? "")
        }
        // Centered on the first match with a leading "…" (the row is one line).
        var text = s
        var ranges = item.highlights
        if let r = ranges.first {
            let lead = s.distance(from: s.startIndex, to: r.lowerBound)
            if lead > 12 {
                let cut = s.index(r.lowerBound, offsetBy: -10)
                text = "…" + s[cut...]
                ranges = item.highlights.compactMap { h in
                    guard h.lowerBound >= cut else { return nil }
                    let lo = text.index(text.startIndex, offsetBy: 1 + s.distance(from: cut, to: h.lowerBound))
                    let hi = text.index(lo, offsetBy: s.distance(from: h.lowerBound, to: h.upperBound))
                    return lo..<hi
                }
            }
        }
        var a = AttributedString(text)
        for r in ranges {
            guard let ar = Range(r, in: a) else { continue }
            a[ar].backgroundColor = T.Colors.accent.color.opacity(0.24)
            a[ar].foregroundColor = T.Colors.textPrimary.color
        }
        return a
    }
}
