import Foundation
import Testing
@testable import LmuxHooks

/// Real-shaped payloads per https://code.claude.com/docs/en/hooks
enum Payloads {
    static let common = #""session_id":"0d6c1a2e-7b1f-4d2a-9a51-3f0e6f4c9b10","transcript_path":"/Users/me/.claude/projects/-Users-me-proj/0d6c1a2e.jsonl","cwd":"/Users/me/proj","permission_mode":"default""#

    static func json(_ event: String, _ extra: String = "") -> String {
        "{" + common + #","hook_event_name":""# + event + "\"" + (extra.isEmpty ? "" : "," + extra) + "}"
    }

    static let sessionStart = json("SessionStart", #""source":"startup","model":"claude-opus-5""#)
    static let prompt = json("UserPromptSubmit", #""prompt":"fix the \"bug\"\nplease 한국어""#)
    static let preBash = json("PreToolUse", #""tool_name":"Bash","tool_input":{"command":"npm test","description":"Run tests","timeout":120000},"tool_use_id":"toolu_01ABC""#)
    static let postBash = json("PostToolUse", #""tool_name":"Bash","tool_input":{"command":"npm test"},"tool_response":{"stdout":"ok","stderr":"","interrupted":false},"tool_use_id":"toolu_01ABC""#)
    static let permission = json("PermissionRequest", #""tool_name":"Bash","tool_input":{"command":"rm -rf build"},"tool_use_id":"toolu_02""#)
    static let notifPermission = json("Notification", #""message":"Claude needs your permission to use Bash","notification_type":"permission_prompt""#)
    static let notifIdle = json("Notification", #""message":"Claude is waiting for your input","notification_type":"idle_prompt""#)
    static let stop = json("Stop", #""stop_hook_active":false,"last_assistant_message":"All tests pass.""#)
    static let subStart = json("SubagentStart", #""agent_id":"agent-7","agent_type":"Explore""#)
    static let subStop = json("SubagentStop", #""agent_id":"agent-7","agent_type":"Explore","last_assistant_message":"found it","stop_hook_active":false"#)
    static let subPreTool = json("PreToolUse", #""agent_id":"agent-7","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"x"},"tool_use_id":"toolu_03""#)
    static let subPermission = json("PermissionRequest", #""agent_id":"agent-7","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"make"},"tool_use_id":"toolu_04""#)
    static let subPostTool = json("PostToolUse", #""agent_id":"agent-7","agent_type":"general-purpose","tool_name":"Bash","tool_input":{"command":"make"},"tool_response":{},"tool_use_id":"toolu_04""#)
    static let stopFailure = json("StopFailure", #""error_type":"rate_limit","error_message":"429""#)
    static let sessionEnd = json("SessionEnd", #""reason":"prompt_input_exit""#)
    static let compactStart = json("SessionStart", #""source":"compact""#)
    static let stopBgSubagent = json("Stop", #""stop_hook_active":false,"last_assistant_message":"已派出","background_tasks":[{"id":"agent-7","type":"subagent","status":"running","description":"sleep","agent_type":"general-purpose"}],"session_crons":[]"#)
    static let stopBgShell = json("Stop", #""stop_hook_active":false,"last_assistant_message":"已啟動","background_tasks":[{"id":"b75w99nqn","type":"shell","status":"running","description":"dev server","command":"sleep 40"}],"session_crons":[]"#)
    static let stopBgSubagentDone = json("Stop", #""stop_hook_active":false,"last_assistant_message":"好了","background_tasks":[{"id":"agent-7","type":"subagent","status":"completed","description":"sleep","agent_type":"general-purpose"}],"session_crons":[]"#)
    static let preCompact = json("PreCompact", #""trigger":"manual","custom_instructions":"""#)
    static let preCompactAuto = json("PreCompact", #""trigger":"auto","custom_instructions":"""#)
    static let postCompact = json("PostCompact", #""trigger":"manual","compact_summary":"Summary of the conversation.""#)
    static let askUser = json("PreToolUse", #""tool_name":"AskUserQuestion","tool_input":{"questions":[]},"tool_use_id":"toolu_05""#)
    static let askUserDone = json("PostToolUse", #""tool_name":"AskUserQuestion","tool_input":{},"tool_response":{},"tool_use_id":"toolu_05""#)
    static let future = json("SomeFutureEvent", #""x":1"#)
}

func event(_ payload: String, pane: String = "pane-1") throws -> HookEvent {
    let line = HookClient.envelope(pane: pane, payload: Array(payload.utf8), sentNanos: 42)!
    return try HookEvent.parse(line: Data(line))
}

@Suite struct EventParsingTests {
    // @feature: subagent-running-state.feature
    // @scenario: 還在跑的只有背景 shell 時，主回合結束就是完成
    @Test func countsOnlyRunningBackgroundSubagents() throws {
        #expect(try event(Payloads.stopBgSubagent).runningBackgroundSubagents == 1)
        #expect(try event(Payloads.stopBgShell).runningBackgroundSubagents == 0)
        #expect(try event(Payloads.stopBgSubagentDone).runningBackgroundSubagents == 0)
        #expect(try event(Payloads.stop).runningBackgroundSubagents == 0)  // 沒有 background_tasks 欄位
    }

    @Test func parsesCommonFields() throws {
        let e = try event(Payloads.preBash)
        #expect(e.paneID == "pane-1")
        #expect(e.kind == .preToolUse)
        #expect(e.sessionID == "0d6c1a2e-7b1f-4d2a-9a51-3f0e6f4c9b10")
        #expect(e.transcriptPath == "/Users/me/.claude/projects/-Users-me-proj/0d6c1a2e.jsonl")
        #expect(e.cwd == "/Users/me/proj")
        #expect(e.toolName == "Bash")
        #expect(e.toolUseID == "toolu_01ABC")
        #expect(e.sentAtNanos == 42)
        #expect(!e.isSubagent)
    }

    @Test func parsesEventSpecificFields() throws {
        let n = try event(Payloads.notifPermission)
        #expect(n.kind == .notification && n.notificationType == "permission_prompt")
        #expect(n.message == "Claude needs your permission to use Bash")
        let p = try event(Payloads.prompt)
        #expect(p.kind == .userPromptSubmit && p.prompt == "fix the \"bug\"\nplease 한국어")
        let s = try event(Payloads.stop)
        #expect(s.stopHookActive == false && s.lastAssistantMessage == "All tests pass.")
        let sub = try event(Payloads.subStop)
        #expect(sub.kind == .subagentStop && sub.agentID == "agent-7" && sub.agentType == "Explore" && sub.isSubagent)
        #expect(try event(Payloads.sessionStart).source == "startup")
        #expect(try event(Payloads.sessionEnd).reason == "prompt_input_exit")
        #expect(try event(Payloads.stopFailure).errorType == "rate_limit")
    }

    @Test func unknownEventsAreKeptNotRejected() throws {
        let e = try event(Payloads.future)
        #expect(e.kind == .unknown && e.name == "SomeFutureEvent")
    }

    @Test func paneIDIsEscapedAndMultilinePayloadFlattened() throws {
        let pretty = "{\n  \"hook_event_name\": \"Stop\",\n  \"session_id\": \"s\"\n}\n"
        let line = HookClient.envelope(pane: "we\"ird\\pane\n", payload: Array(pretty.utf8), sentNanos: 1)!
        #expect(line.filter { $0 == 0x0A }.count == 1 && line.last == 0x0A)
        let e = try HookEvent.parse(line: Data(line))
        #expect(e.paneID == "we\"ird\\pane\n" && e.kind == .stop)
    }

    @Test func envelopeCarriesTheHookingProcess() throws {
        // lmux-hook reports which claude process ran it (its parent) and that process's
        // group, so the app can tell the pane's foreground claude from a nested `claude -p`.
        let line = HookClient.envelope(pane: "p", payload: Array(Payloads.stop.utf8), sentNanos: 1,
                                       process: .init(pid: 4242, pgid: 4240, ancestorGroups: [4240, 100],
                                                      environment: ["CLAUDE_CONFIG_DIR": "/x \"y\"\n"]))!
        let e = try HookEvent.parse(line: Data(line))
        #expect(e.claudePID == 4242 && e.claudePGID == 4240 && e.kind == .stop)
        #expect(e.claudeAncestorGroups == [4240, 100] && e.claudeEnvironment == ["CLAUDE_CONFIG_DIR": "/x \"y\"\n"])
        let old = try event(Payloads.stop)
        #expect(old.claudePID == nil && old.claudePGID == nil)
    }

    @Test func replayableEnvironmentNeverCarriesCredentials() {
        #expect(HookClient.replayable("CLAUDE_CONFIG_DIR") && HookClient.replayable("ANTHROPIC_MODEL")
                 && HookClient.replayable("BASH_DEFAULT_TIMEOUT_MS"))
        // Credential-like or unknown: never captured.
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_BASE_URL",
                     "ANTHROPIC_BEDROCK_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_MESSAGING_TOKEN",
                     "CLAUDE_CODE_CLIENT_CERT", "CLAUDE_CODE_CLIENT_KEY_PASSPHRASE", "AWS_BEARER_TOKEN_BEDROCK",
                     "CLAUDE_CODE_API_KEY_HELPER_TTL_MS", "HTTPS_PROXY", "NODE_EXTRA_CA_CERTS", "CLAUDE_CODE_ENTRYPOINT",
                     "CLAUDE_SOMETHING_NEW", "MAX_THINKING_TOKENS", "CLAUDE_CODE_MAX_OUTPUT_TOKENS", "ANTHROPIC_SOMETHING_NEW", "DISABLE_TELEMETRY", "HOME", "PATH", "LMUX_PANE_ID"] {
            #expect(!HookClient.replayable(name), "\(name)")
        }
        // Every allowed name is clear of the credential patterns, no exceptions.
        let deny = try! NSRegularExpression(pattern: "KEY|TOKEN|SECRET|PASS|AUTH|HEADER|COOKIE|CREDENTIAL|URL|CERT")
        for name in HookClient.replayableNames {
            #expect(deny.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil, "\(name)")
        }
        let o = HookClient.Origin.current(environment: ["CLAUDE_CONFIG_DIR": "/c", "ANTHROPIC_API_KEY": "sk",
                                                        "ANTHROPIC_CUSTOM_HEADERS": "Authorization: Bearer x",
                                                        "ANTHROPIC_BASE_URL": "https://u:p@h", "PATH": "/bin"])
        #expect(o.environment == ["CLAUDE_CONFIG_DIR": "/c"] && o.pid == getppid() && !o.ancestorGroups.isEmpty)
        // Even a forged envelope carrying a secret is dropped on parse.
        let line = HookClient.envelope(pane: "p", payload: Array(Payloads.stop.utf8), sentNanos: 1,
                                       process: .init(pid: 1, pgid: 1, environment: ["ANTHROPIC_CUSTOM_HEADERS": "Bearer x",
                                                                                      "ANTHROPIC_MODEL": "m"]))!
        #expect((try? HookEvent.parse(line: Data(line)))?.claudeEnvironment == ["ANTHROPIC_MODEL": "m"])
    }

    @Test func envelopeRejectsNonObjects() {
        #expect(HookClient.envelope(pane: "p", payload: Array("".utf8), sentNanos: 0) == nil)
        #expect(HookClient.envelope(pane: "p", payload: Array("[1]".utf8), sentNanos: 0) == nil)
        #expect(HookClient.envelope(pane: "p", payload: Array("garbage".utf8), sentNanos: 0) == nil)
    }

    @Test func malformedLinesThrow() {
        #expect(throws: HookEvent.ParseError.notJSONObject) { try HookEvent.parse(line: Data("nope".utf8)) }
        #expect(throws: HookEvent.ParseError.missingPane) { try HookEvent.parse(line: Data(#"{"hook":{"hook_event_name":"Stop"}}"#.utf8)) }
        #expect(throws: HookEvent.ParseError.missingHook) { try HookEvent.parse(line: Data(#"{"pane":"p"}"#.utf8)) }
        #expect(throws: HookEvent.ParseError.missingEventName) { try HookEvent.parse(line: Data(#"{"pane":"p","hook":{}}"#.utf8)) }
    }

    // The sidebar's running line: "Bash · swift test --filter IME".
    @Test func toolArgumentIsOneLine() throws {
        let bash = try HookEvent(paneID: "p", payload: ["hook_event_name": "PreToolUse", "tool_name": "Bash",
                                                        "tool_input": ["command": "swift test --filter IME\necho done"]])
        #expect(bash.toolArgument == "swift test --filter IME")
        let edit = try HookEvent(paneID: "p", payload: ["hook_event_name": "PreToolUse", "tool_name": "Edit",
                                                        "tool_input": ["file_path": "/a/b/refund.ts", "old_string": "x"]])
        #expect(edit.toolArgument == "refund.ts")
        let none = try HookEvent(paneID: "p", payload: ["hook_event_name": "PreToolUse", "tool_name": "TodoWrite"])
        #expect(none.toolArgument == nil)
    }
}
