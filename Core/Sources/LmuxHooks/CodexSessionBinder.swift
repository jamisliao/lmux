import Foundation

/// Codex 0.166 runs every session's hooks on one shared app-server, with the environment of the
/// codex that started it: a hook doesn't say which pane it came from. A session no pane has yet
/// is matched to the pane whose codex started a turn (its own OSC 7501 report) when the session
/// started one (SessionStart / UserPromptSubmit: never a tool event or a Stop), and only one to
/// one: a pane two sessions could be, or a session two panes could be, is bound to nothing.
public struct CodexSessionBinder: Sendable {
    /// How far apart a session's turn start and its pane's may be.
    public let window: TimeInterval

    /// A pane's codex started a turn at `at`; `claimedAt`: when a session already bound to the
    /// pane started its own turn (a turn it accounts for is no other session's).
    public struct Turn: Sendable, Equatable {
        public var pane: String
        public var at: Date
        public var claimedAt: Date?
        public init(pane: String, at: Date, claimedAt: Date? = nil) {
            self.pane = pane
            self.at = at
            self.claimedAt = claimedAt
        }
    }

    public struct Binding: Sendable {
        public var session: String
        public var pane: String
        /// When the session's turn started (the turn it claims in that pane).
        public var since: Date
        public var events: [HookEvent]
    }

    /// Sessions waiting for their pane: when their turn started, and their events since.
    public private(set) var pending: [String: (since: Date, events: [HookEvent])] = [:]
    /// Every unbound session's turn starts lately, bound later or not: a pane that two of them
    /// could be is neither's, also after one of them was given up.
    private var starts: [(session: String, at: Date)] = []

    public init(window: TimeInterval) { self.window = window }

    /// An event of a session no pane has. Only a turn start opens a wait; the session's other
    /// events join one that is open. false: dropped (nothing to bind it by).
    @discardableResult
    public mutating func hold(_ e: HookEvent, at now: Date) -> Bool {
        guard let sid = e.sessionID, !sid.isEmpty, e.kind != .sessionEnd else { return false }
        if e.kind == .sessionStart || e.kind == .userPromptSubmit {
            starts.removeAll { now.timeIntervalSince($0.at) > 4 * window }
            starts.append((sid, now))
            if pending[sid] == nil { pending[sid] = (now, []) }
        }
        guard pending[sid] != nil else { return false }
        pending[sid]?.events.append(e)
        return true
    }

    /// Whether a report of this turn could still get its text from a waiting session's hooks.
    public func waits(_ turn: Turn) -> Bool {
        open(turn) && pending.values.contains { abs($0.since.timeIntervalSince(turn.at)) <= window }
    }

    /// The waits that are over: each bound to its one pane, or given up (`unbound`, with how
    /// many panes it could have been). A wait is over once its own window and that of every turn
    /// it could be have passed (another session may still start a turn up to a window after a
    /// pane's); `next`: when the next one left is, for the caller's timer.
    public mutating func resolve(turns: [Turn], now: Date)
        -> (bound: [Binding], unbound: [(session: String, panes: Int)], next: Date?) {
        let turns = turns.filter(open)
        var bound: [Binding] = [], unbound: [(session: String, panes: Int)] = [], next: Date?
        for (sid, p) in pending {
            let panes = turns.filter { abs($0.at.timeIntervalSince(p.since)) <= window }
            let over = panes.map(\.at).reduce(p.since, max).addingTimeInterval(window)
            // (A timer set for `over` may fire a hair early.)
            guard now.addingTimeInterval(0.01) >= over else {
                next = min(next ?? over, over)
                continue
            }
            pending[sid] = nil
            guard panes.count == 1, let t = panes.first,
                  Set(starts.filter { abs($0.at.timeIntervalSince(t.at)) <= window }.map(\.session)) == [sid] else {
                unbound.append((sid, panes.count))
                continue
            }
            bound.append(Binding(session: sid, pane: t.pane, since: p.since, events: p.events))
        }
        return (bound, unbound, next)
    }

    private func open(_ t: Turn) -> Bool {
        t.claimedAt.map { abs($0.timeIntervalSince(t.at)) > window } ?? true
    }
}
