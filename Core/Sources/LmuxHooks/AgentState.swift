import Foundation

/// Per-pane agent state, driven only by hook events (PLAN principle 2).
public enum AgentState: Sendable, Equatable {
    case idle
    case running
    case needsInput(NeedsInputReason)
    case done
}

public enum NeedsInputReason: String, Sendable, Equatable {
    /// Tool permission dialog (PermissionRequest / Notification permission_prompt).
    case permission
    /// MCP elicitation dialog.
    case elicitation
    /// AskUserQuestion tool.
    case question
    /// ExitPlanMode plan approval.
    case planApproval
}

/// What the app should surface. `PaneAgent.handle` emits at most one per episode.
public enum AgentAlert: Sendable, Equatable {
    case needsInput(NeedsInputReason, message: String?)
    case done(lastMessage: String?)
    case failed(errorType: String?)
}

public struct AgentTransition: Sendable, Equatable {
    public var from: AgentState
    public var to: AgentState
    /// Deduped alert for this transition (use for badges / "jump to next").
    public var alert: AgentAlert?
    /// Same alert, but only when the pane is not focused. This is the single
    /// notification path: post a system notification iff this is non-nil.
    public var notify: AgentAlert?
}

/// State machine for the agent session (Claude Code or Codex) running in one pane.
///
/// Rules:
/// - UserPromptSubmit -> running (new episode).
/// - Stop (main agent) -> done + alert. SubagentStop never ends the turn.
/// - StopFailure -> done + failed alert.
/// - Events from a subagent (agent_id set) never mark the turn done, and their tool
///   events never change state. The one exception is a permission/elicitation dialog,
///   which blocks the user regardless of who asked; it is cleared only by the
///   same agent's next tool event.
/// - Interrupt (Codex: the user pressed Esc / Ctrl-C mid-turn) -> idle, no alert: the user
///   stopped it and is looking at it. Codex has no failure event, so a Codex turn never
///   ends in `failed`. Claude Code sends nothing on Esc: see `userInterrupted()`.
/// - Only a *transition into* needsInput/done produces an alert. Repeats (e.g.
///   PermissionRequest followed by Notification permission_prompt, or idle_prompt
///   reminders) are absorbed.
/// - 壓縮：PreCompact 時是閒置或完成（`/compact`，或 Claude 在閒置時自己壓縮）-> running，並記住原本的狀態。
///   壓縮結束（PostCompact、SessionStart `compact`，或兩者都沒來時的 idle_prompt）-> 回到原本的狀態，不發 alert。
///   回合中的自動壓縮本來就是 running，不記住任何東西。新 prompt、Stop、StopFailure、Esc、新的 session 讓記住的狀態作廢。
/// - Subagents (SubagentStart/Stop by agent_id) are counted while the turn runs, at most
///   `subagentCap`; the main turn ending (Stop, StopFailure, Esc), a new prompt or a new
///   session clears them, so a missed SubagentStop never outlives its turn.
/// - A usage limit (StopFailure `rate_limit` whose message says when it resets) doesn't end the
///   turn: Claude Code can continue on its own once the limit resets. The pane stays running,
///   `usageLimitResets` says when, and no alert is raised. Claude's Notification
///   `quota_auto_resume_fired` (it continues) keeps it running; `…_stale` / `…_disabled` (press
///   Enter, or it won't continue) end it as done, with the alert, and so does the app once the
///   reset time has passed with neither (`usageLimitPassed`).
public struct PaneAgent: Sendable, Equatable {
    public private(set) var state: AgentState = .idle
    public private(set) var activeSubagents: Set<String> = []
    /// Waiting for a usage limit: when it resets as Claude Code wrote it ("3pm", "Nov 5, 3pm"), else nil.
    public private(set) var usageLimitResets: String?
    /// The time zone Claude Code named with it ("Asia/Seoul"), if any.
    public private(set) var usageLimitZone: String?
    /// More SubagentStarts than this in one turn are not counted (missed Stops can't grow it).
    public static let subagentCap = 32
    /// agent_id ("" for main) whose dialog put us in needsInput.
    private var blockingAgent: String?
    /// PreCompact 時記住的狀態（只在閒置或完成時記）；nil 表示目前沒有 lmux 標成 running 的壓縮。
    private var stateBeforeCompaction: AgentState?

    public init() {}

    /// The session's last turn had ended (done) when lmux quit, as the relaunch shows it.
    public static var restoredDone: PaneAgent {
        var a = PaneAgent()
        a.state = .done
        return a
    }

    @discardableResult
    public mutating func handle(_ e: HookEvent, focused: Bool) -> AgentTransition {
        let from = state
        var alert: AgentAlert?
        let agent = e.agentID ?? ""
        // Anything the main agent does again means it isn't waiting for the limit any more.
        if usageLimitResets != nil, !e.isSubagent, ![.notification, .stopFailure, .unknown].contains(e.kind) {
            clearUsageLimit()
        }

        func needInput(_ r: NeedsInputReason, _ msg: String?) {
            if case .needsInput = state { return }  // already blocked: dedupe
            state = .needsInput(r)
            blockingAgent = agent
            alert = .needsInput(r, message: msg)
        }
        func resumeIfBlockedBy(_ a: String) {
            if case .needsInput = state, blockingAgent == a {
                state = .running
                blockingAgent = nil
            }
        }

        // lmux 標成 running 的壓縮結束了：回到原本的狀態，不發 alert。
        if let before = stateBeforeCompaction, !e.isSubagent,
           e.kind == .postCompact
            || (e.kind == .sessionStart && e.source == "compact")
            || (e.kind == .notification && e.notificationType == "idle_prompt") {
            stateBeforeCompaction = nil
            state = before
            return AgentTransition(from: from, to: state, alert: nil, notify: nil)
        }
        // 回合或 session 換了：記住的狀態作廢（之後才到的結束回報不再改變狀態）。
        if !e.isSubagent, [.userPromptSubmit, .stop, .stopFailure, .interrupt, .sessionStart, .sessionEnd].contains(e.kind) {
            stateBeforeCompaction = nil
        }

        switch e.kind {
        case .sessionStart:
            // Auto-compact fires SessionStart(source: compact) mid-turn; keep state.
            if e.source != "compact" { reset() }
        case .sessionEnd:
            reset()
        case .userPromptSubmit:
            state = .running
            blockingAgent = nil
            activeSubagents.removeAll()
        case .preToolUse:
            if !e.isSubagent, e.toolName == "AskUserQuestion" {
                needInput(.question, nil)
            } else if !e.isSubagent, e.toolName == "ExitPlanMode" {
                needInput(.planApproval, nil)
            } else if case .needsInput = state {
                resumeIfBlockedBy(agent)
            } else if !e.isSubagent {
                state = .running
            }
        case .postToolUse, .postToolUseFailure:
            if case .needsInput = state {
                resumeIfBlockedBy(agent)
            } else if !e.isSubagent {
                state = .running
            }
        case .permissionRequest:
            needInput(.permission, e.toolName.map { "Permission: \($0)" })
        case .elicitation:
            needInput(.elicitation, nil)
        case .elicitationResult:
            if state == .needsInput(.elicitation) { resumeIfBlockedBy(agent) }
        case .notification:
            switch e.notificationType {
            case "permission_prompt":
                needInput(.permission, e.message)
            case "elicitation_dialog", "elicitation_url_dialog":
                needInput(.elicitation, e.message)
            case "elicitation_complete", "elicitation_response":
                if state == .needsInput(.elicitation) { resumeIfBlockedBy(agent) }
            case "idle_prompt":
                // Reminder only. If we somehow missed Stop, recover to done once (not while the
                // turn waits for a usage limit: Claude sits at its prompt then on purpose).
                if state == .running, !e.isSubagent, usageLimitResets == nil {
                    state = .done
                    alert = .done(lastMessage: nil)
                }
            case "quota_auto_resume_fired":
                // The limit reset and Claude continues the task by itself.
                guard usageLimitResets != nil, !e.isSubagent else { break }
                clearUsageLimit()
                state = .running
            case "quota_auto_resume_stale", "quota_auto_resume_disabled":
                // It won't continue by itself: the user's turn. Only while waiting: a turn the user
                // started by hand since then is theirs, not this notification's.
                guard usageLimitResets != nil, !e.isSubagent else { break }
                clearUsageLimit()
                blockingAgent = nil
                state = .done
                alert = .done(lastMessage: e.message)
            default:
                break  // auth_success, agent_needs_input, agent_completed, ... : not this pane's turn
            }
        case .subagentStart:
            if let id = e.agentID, activeSubagents.count < Self.subagentCap { activeSubagents.insert(id) }
        case .subagentStop:
            if let id = e.agentID { activeSubagents.remove(id) }
        case .stop:
            guard !e.isSubagent else { break }
            activeSubagents.removeAll()
            blockingAgent = nil
            if state != .done {
                state = .done
                alert = .done(lastMessage: e.lastAssistantMessage)
            }
        case .stopFailure:
            guard !e.isSubagent else { break }
            activeSubagents.removeAll()
            blockingAgent = nil
            if let resets = Self.usageLimitResetTime(error: e.errorType, message: e.lastAssistantMessage) {
                usageLimitResets = resets
                usageLimitZone = Self.usageLimitZoneName(message: e.lastAssistantMessage)
                state = .running
                break
            }
            clearUsageLimit()
            state = .done
            alert = .failed(errorType: e.errorType)
        case .interrupt:
            guard !e.isSubagent else { break }
            state = .idle
            blockingAgent = nil
            activeSubagents.removeAll()
        case .preCompact:
            // `/compact`（或閒置時的自動壓縮）：壓縮完之前是 running。回合中的自動壓縮本來就是 running。
            if !e.isSubagent, state == .idle || state == .done {
                stateBeforeCompaction = state
                state = .running
            }
        case .postCompact, .unknown:
            break
        }

        return AgentTransition(from: from, to: state, alert: alert, notify: focused ? nil : alert)
    }

    /// What Codex's TUI says about itself in its own terminal (OSC 7501).
    public enum ProgramState: Sendable, Equatable {
        case idle, working, blocked(NeedsInputReason), done, error, clear
    }

    /// A Codex TUI's own report (OSC 7501): once it reports, it is the pane's state (hooks can
    /// come from a shared app-server, for any pane). One alert per episode, as with hooks.
    /// - working -> running (an answered dialog too).
    /// - blocked -> needs input + alert (once; a different ask meanwhile only changes its kind).
    /// - done -> done + alert; the idle that follows a finished turn keeps it done.
    /// - idle while running / waiting: the user stopped it (Esc): idle, no alert.
    /// - error -> failed. clear (codex left) -> idle.
    @discardableResult
    public mutating func report(_ s: ProgramState, message: String? = nil, lastMessage: String? = nil,
                                focused: Bool) -> AgentTransition {
        let from = state
        var alert: AgentAlert?
        clearUsageLimit()
        switch s {
        case .working:
            // A new turn (not an answered dialog): the last turn's subagents are gone.
            if state == .idle || state == .done { activeSubagents.removeAll() }
            state = .running
            blockingAgent = nil
        case .blocked(let r):
            if case .needsInput = state {
                state = .needsInput(r)
                break
            }
            state = .needsInput(r)
            blockingAgent = ""
            alert = .needsInput(r, message: message)
        case .done:
            blockingAgent = nil
            activeSubagents.removeAll()
            if state != .done {
                state = .done
                alert = .done(lastMessage: lastMessage)
            }
        case .idle:
            if state != .done { reset() }
        case .error:
            reset()
            state = .done
            alert = .failed(errorType: nil)
        case .clear:
            reset()
        }
        return AgentTransition(from: from, to: state, alert: alert, notify: focused ? nil : alert)
    }

    /// The user typed into the pane while it was waiting for them. Clears needsInput
    /// (the user answered the dialog, or pressed Esc, which sends no hook event).
    /// A later tool event from the main agent moves the pane back to running.
    @discardableResult
    public mutating func userTyped() -> AgentTransition {
        let from = state
        if case .needsInput = state {
            state = .idle
            blockingAgent = nil
        }
        return AgentTransition(from: from, to: state, alert: nil, notify: nil)
    }

    /// Claude Code's turn was stopped with Esc / Ctrl+C: it sends no hook then, the app sees the
    /// interrupt marker in the transcript instead. Same as Codex's Interrupt: idle, no alert.
    @discardableResult
    public mutating func userInterrupted() -> AgentTransition {
        let from = state
        stateBeforeCompaction = nil
        switch state {
        case .running, .needsInput:
            state = .idle
            blockingAgent = nil
            activeSubagents.removeAll()
            clearUsageLimit()
        case .idle, .done:
            break
        }
        return AgentTransition(from: from, to: state, alert: nil, notify: nil)
    }

    /// The usage limit's reset time (plus a grace period) passed and Claude neither continued nor
    /// said it won't: the user's turn, as with `quota_auto_resume_stale`. A no-op unless waiting.
    /// `knownReset` false: the reset time couldn't be read, so the alert claims no reset.
    @discardableResult
    public mutating func usageLimitPassed(focused: Bool, knownReset: Bool = true) -> AgentTransition {
        let from = state
        guard usageLimitResets != nil else { return AgentTransition(from: from, to: state, alert: nil, notify: nil) }
        clearUsageLimit()
        blockingAgent = nil
        state = .done
        let alert = AgentAlert.done(lastMessage: knownReset ? "Usage limit reset" : "Usage limit wait ended")
        return AgentTransition(from: from, to: state, alert: alert, notify: focused ? nil : alert)
    }

    private mutating func clearUsageLimit() {
        usageLimitResets = nil
        usageLimitZone = nil
    }

    private mutating func reset() {
        state = .idle
        blockingAgent = nil
        stateBeforeCompaction = nil
        activeSubagents.removeAll()
        clearUsageLimit()
    }

    /// When a usage limit resets, from a StopFailure: `rate_limit` with Claude Code's message
    /// "You've hit your session limit · resets 3pm (Asia/Seoul)". nil for anything else (a
    /// transient 429 says no reset time: a failure as before).
    static func usageLimitResetTime(error: String?, message: String?) -> String? {
        guard error == "rate_limit", let m = message, let r = m.range(of: " resets "),
              m[..<r.lowerBound].range(of: "limit", options: .caseInsensitive) != nil else { return nil }
        var t = m[r.upperBound...]
        for end in [" (", " \u{00B7}", " \u{2219}", " \u{2022}", " - ", " \u{2013} ", " \u{2014} ", "\n"] {
            if let e = t.range(of: end) { t = t[..<e.lowerBound] }
        }
        let out = t.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".,;:!")))
        return out.isEmpty || out.count > 40 ? nil : out
    }

    /// "Asia/Seoul" from "… resets 3pm (Asia/Seoul) …", when it is a real time zone.
    static func usageLimitZoneName(message: String?) -> String? {
        guard let m = message, let r = m.range(of: " resets "), let o = m[r.upperBound...].range(of: "("),
              let c = m[o.upperBound...].range(of: ")") else { return nil }
        let z = String(m[o.upperBound..<c.lowerBound])
        return TimeZone(identifier: z) != nil ? z : nil
    }

    /// The first moment matching Claude Code's reset text ("3pm", "3:30pm", "Nov 5, 3:30pm",
    /// "Nov 5 at 3pm") at or after `now` (a minute of slack), in `zone` (else the local one).
    /// A time of day whose next match is over 12 hours away has just passed (Claude rounds it, or
    /// the hook came late): `now`. nil when the text isn't one of those.
    public static func usageLimitResetDate(_ text: String, zone: String?, after now: Date) -> Date? {
        let tz = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        var s = text.uppercased().replacingOccurrences(of: " AT ", with: ", ")
        for m in ["AM", "PM"] { s = s.replacingOccurrences(of: " " + m, with: m) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        for (format, hasDay) in [("MMM d, h:mma", true), ("MMM d, ha", true), ("h:mma", false), ("ha", false)] {
            f.dateFormat = format
            guard let d = f.date(from: s) else { continue }
            let c = cal.dateComponents([.month, .day, .hour, .minute], from: d)
            var want = DateComponents()
            want.hour = c.hour
            want.minute = c.minute
            want.second = 0
            if hasDay { want.month = c.month; want.day = c.day }
            guard let next = cal.nextDate(after: now.addingTimeInterval(-60), matching: want, matchingPolicy: .nextTime)
            else { return nil }
            return !hasDay && next.timeIntervalSince(now) > 12 * 3600 ? now : next
        }
        return nil
    }
}
