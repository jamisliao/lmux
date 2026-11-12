import Foundation

/// The coding agent a hook event came from. Claude Code and Codex CLI share the hook
/// payload shape (`hook_event_name`, `session_id`, `transcript_path`, `tool_name`…); the
/// hook command lmux installs for Codex runs `lmux-hook codex`, which tags the envelope.
public enum AgentKind: String, Sendable, Equatable, Codable, CaseIterable {
    case claude
    case codex

    /// The agent's name as the UI says it.
    public var displayName: String { self == .codex ? "Codex" : "Claude" }
}

/// One Claude Code (or Codex CLI) hook invocation, as delivered over the lmux socket.
///
/// Wire format (one line, sent by `lmux-hook`):
/// `{"lmux":1,"pane":"<LMUX_PANE_ID>","token":"<LMUX_PANE_NONCE>","agent":"codex"?,"sent_ns":<unix ns>,"ppid":<pid>,"ppgid":<pgid>,"pgroups":[…],"penv":{…},"hook":<raw hook stdin JSON>}\n`
///
/// Field names follow https://code.claude.com/docs/en/hooks. Codex CLI uses the same names
/// (checked against 0.166.0's payloads); it has no Notification / Elicitation / failure
/// events, and adds `Interrupt` and `PostCompact`.
public struct HookEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case notification = "Notification"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case elicitation = "Elicitation"
        case elicitationResult = "ElicitationResult"
        case preCompact = "PreCompact"
        case sessionEnd = "SessionEnd"
        /// Codex: the user interrupted the turn (Esc / Ctrl-C).
        case interrupt = "Interrupt"
        /// Codex: after a compaction.
        case postCompact = "PostCompact"
        case unknown
    }

    public var paneID: String
    /// Which agent ran the hook (`agent` in the envelope; Claude Code when absent).
    public var agent: AgentKind = .claude
    /// The sender's `LMUX_PANE_NONCE`: the app accepts an event for `paneID` only when this is
    /// that pane's token (pane ids are not secret; the token is only in the pane's environment).
    public var paneToken: String?
    /// Raw `hook_event_name` (kept even when `kind == .unknown`).
    public var name: String
    public var kind: Kind
    public var sessionID: String?
    public var transcriptPath: String?
    public var cwd: String?
    /// Present when the hook fired inside a subagent (common field) and on SubagentStart/Stop.
    public var agentID: String?
    public var agentType: String?
    public var notificationType: String?
    public var message: String?
    public var toolName: String?
    /// What the tool acts on, one line (PreToolUse `tool_input`: command, file, pattern, URL…).
    public var toolArgument: String?
    public var toolUseID: String?
    /// SessionStart `source`: startup|resume|clear|compact|fork
    public var source: String?
    /// SessionEnd `reason`
    public var reason: String?
    public var stopHookActive: Bool?
    /// Stop 的 `background_tasks` 裡，還在跑（`status == "running"`）的背景子 agent 數量（背景 shell 不算）。
    public var runningBackgroundSubagents = 0
    public var lastAssistantMessage: String?
    /// UserPromptSubmit `prompt`
    public var prompt: String?
    /// StopFailure `error` ("rate_limit", "server_error", …; `error_type` from older senders)
    public var errorType: String?
    /// `permission_mode` ("default", "bypassPermissions", …).
    public var permissionMode: String?
    /// Wall clock (unix ns) when lmux-hook started, if sent.
    public var sentAtNanos: UInt64?
    /// Wall clock (unix ns) when the server parsed the line.
    public var receivedAtNanos: UInt64?
    /// The Claude Code process that ran the hook and its process group (sent by lmux-hook;
    /// nil from older clients). The pane's own claude is the pty's foreground group, a
    /// nested `claude -p` (e.g. from Claude's Bash tool) is not.
    public var claudePID: Int32?
    public var claudePGID: Int32?
    /// Process groups of that claude's ancestors (nearest first).
    public var claudeAncestorGroups: [Int32] = []
    /// Its replayable environment (`HookClient.replayable`), e.g. `CLAUDE_CONFIG_DIR`.
    public var claudeEnvironment: [String: String] = [:]

    public var isSubagent: Bool { !(agentID ?? "").isEmpty }

    public enum ParseError: Error, Equatable {
        case notJSONObject
        case missingPane
        case missingHook
        case missingEventName
    }

    public init(paneID: String, name: String) {
        self.paneID = paneID
        self.name = name
        self.kind = Kind(rawValue: name) ?? .unknown
    }

    /// Builds an event from an already-decoded hook payload (the JSON Claude Code writes to stdin).
    public init(paneID: String, payload: [String: Any]) throws {
        guard let name = payload["hook_event_name"] as? String, !name.isEmpty else {
            throw ParseError.missingEventName
        }
        self.init(paneID: paneID, name: name)
        func s(_ k: String) -> String? { payload[k] as? String }
        sessionID = s("session_id")
        transcriptPath = s("transcript_path")
        cwd = s("cwd")
        agentID = s("agent_id")
        agentType = s("agent_type")
        notificationType = s("notification_type")
        message = s("message")
        toolName = s("tool_name")
        toolArgument = Self.argument(payload["tool_input"] as? [String: Any])
        toolUseID = s("tool_use_id")
        source = s("source")
        reason = s("reason")
        stopHookActive = payload["stop_hook_active"] as? Bool
        runningBackgroundSubagents = (payload["background_tasks"] as? [[String: Any]] ?? []).filter {
            $0["type"] as? String == "subagent" && $0["status"] as? String == "running"
        }.count
        lastAssistantMessage = s("last_assistant_message")
        prompt = s("prompt")
        errorType = s("error") ?? s("error_type")
        permissionMode = s("permission_mode")
    }

    /// The one-line gist of a tool call: Bash's command, a file's name, a search pattern.
    static func argument(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for k in ["command", "file_path", "notebook_path", "pattern", "url", "query", "description", "prompt"] {
            guard var v = input[k] as? String else { continue }
            v = v.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            v = v.trimmingCharacters(in: .whitespaces)
            if k.hasSuffix("_path") { v = (v as NSString).lastPathComponent }
            if v.isEmpty { continue }
            return v.count > 80 ? String(v.prefix(79)) + "…" : v
        }
        return nil
    }

    /// Parses one wire line (without or with trailing newline).
    public static func parse(line: Data) throws -> HookEvent {
        guard let obj = try? JSONSerialization.jsonObject(with: line),
              let dict = obj as? [String: Any] else { throw ParseError.notJSONObject }
        guard let pane = dict["pane"] as? String, !pane.isEmpty else { throw ParseError.missingPane }
        guard let hook = dict["hook"] as? [String: Any] else { throw ParseError.missingHook }
        var event = try HookEvent(paneID: pane, payload: hook)
        event.paneToken = dict["token"] as? String
        if let a = dict["agent"] as? String, let k = AgentKind(rawValue: a) { event.agent = k }
        if let n = dict["sent_ns"] as? NSNumber { event.sentAtNanos = n.uint64Value }
        if let n = dict["ppid"] as? NSNumber, n.int32Value > 0 { event.claudePID = n.int32Value }
        if let n = dict["ppgid"] as? NSNumber, n.int32Value > 0 { event.claudePGID = n.int32Value }
        if let g = dict["pgroups"] as? [NSNumber] { event.claudeAncestorGroups = g.map(\.int32Value) }
        if let e = dict["penv"] as? [String: String] { event.claudeEnvironment = e.filter { HookClient.replayable($0.key) } }
        return event
    }
}

func unixNanosNow() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_REALTIME, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}
