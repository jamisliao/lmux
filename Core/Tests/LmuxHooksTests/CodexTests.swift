import Foundation
import Testing
@testable import LmuxHooks

/// Codex CLI support: real (sanitized) 0.166.0 payloads through the parser, the state machine,
/// the hooks.json installer, its trust records, and the real lmux-hook binary.
@Suite struct CodexTests {
    func event(_ json: String, agent: AgentKind? = .codex, pane: String = "p1") throws -> HookEvent {
        let line = HookClient.envelope(pane: pane, payload: Array(json.utf8), sentNanos: 1, agent: agent)!
        return try HookEvent.parse(line: Data(line))
    }

    // MARK: Parsing

    @Test func payloadsParse() throws {
        let start = try event(CodexPayloads.sessionStart)
        #expect(start.agent == .codex && start.kind == .sessionStart && start.source == "startup")
        #expect(start.sessionID == "01a19af7-a41b-7be0-a747-28b261b34a33")
        #expect(start.transcriptPath?.hasSuffix("rollout-2026-11-02T15-34-43-01a19af7-a41b-7be0-a747-28b261b34a33.jsonl") == true)
        let pre = try event(CodexPayloads.preToolUse)
        #expect(pre.kind == .preToolUse && pre.toolName == "Bash" && pre.toolArgument == "printf 'lmux' > made.txt")
        #expect(pre.toolUseID == "exec-4ed9d00c-81b1-4372-a018-a46e09895ce5")
        let perm = try event(CodexPayloads.permissionRequest)
        #expect(perm.kind == .permissionRequest && perm.toolName == "Bash" && perm.permissionMode == "default")
        #expect(try event(CodexPayloads.preToolUse_2).permissionMode == "bypassPermissions")
        let stop = try event(CodexPayloads.stop)
        #expect(stop.kind == .stop && stop.lastAssistantMessage == "# Result\n\nhello" && stop.stopHookActive == false)
        #expect(try event(CodexPayloads.interrupt).kind == .interrupt)
        #expect(try event(CodexPayloads.sessionEnd).kind == .sessionEnd)
        #expect(try event(CodexPayloads.userPromptSubmit).prompt?.hasPrefix("Create a file named made.txt") == true)
    }

    @Test func untaggedEnvelopeIsClaude() throws {
        #expect(try event(CodexPayloads.stop, agent: nil).agent == .claude)
        #expect(try event(CodexPayloads.stop, agent: .claude).agent == .claude)
        let line = String(decoding: HookClient.envelope(pane: "p", payload: Array("{}".utf8), sentNanos: 1, agent: .codex)!,
                          as: UTF8.self)
        #expect(line.hasPrefix(#"{"lmux":1,"pane":"p","agent":"codex","sent_ns":1"#))
    }

    @Test func tokenAndAgentTogether() throws {
        let line = HookClient.envelope(pane: "p\"1", payload: Array(CodexPayloads.stop.utf8), sentNanos: 1, token: "t\"ok",
                                       agent: .codex)!
        let e = try HookEvent.parse(line: Data(line))
        #expect(e.paneID == "p\"1" && e.paneToken == "t\"ok" && e.agent == .codex && e.kind == .stop)
    }

    @Test func codexHomeIsReplayedButNotSecrets() {
        #expect(HookClient.replayable("CODEX_HOME"))
        for k in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"] { #expect(!HookClient.replayable(k)) }
    }

    // MARK: State machine

    @Test func permissionThenDone() throws {
        var a = PaneAgent()
        a.handle(try event(CodexPayloads.sessionStart), focused: false)
        #expect(a.state == .idle)
        a.handle(try event(CodexPayloads.userPromptSubmit), focused: false)
        #expect(a.state == .running)
        #expect(a.handle(try event(CodexPayloads.preToolUse), focused: false).alert == nil)
        let p = a.handle(try event(CodexPayloads.permissionRequest), focused: false)
        #expect(a.state == .needsInput(.permission))
        #expect(p.notify == .needsInput(.permission, message: "Permission: Bash"))
        // A repeat while blocked: no second alert.
        #expect(a.handle(try event(CodexPayloads.permissionRequest), focused: false).alert == nil)
        a.handle(try event(CodexPayloads.postToolUse), focused: false)
        #expect(a.state == .running)
        let done = a.handle(try event(CodexPayloads.stop), focused: false)
        #expect(a.state == .done && done.notify == .done(lastMessage: "# Result\n\nhello"))
        a.handle(try event(CodexPayloads.sessionEnd), focused: false)
        #expect(a.state == .idle)
    }

    @Test func interruptGoesIdleWithoutAlert() throws {
        var a = PaneAgent()
        a.handle(try event(CodexPayloads.userPromptSubmit), focused: false)
        a.handle(try event(CodexPayloads.permissionRequest), focused: false)
        let t = a.handle(try event(CodexPayloads.interrupt), focused: false)
        #expect(a.state == .idle && t.alert == nil && t.notify == nil)
        // Running, interrupted: idle too, and the next prompt starts a new turn.
        a.handle(try event(CodexPayloads.userPromptSubmit_1), focused: false)
        #expect(a.handle(try event(CodexPayloads.interrupt), focused: false).alert == nil)
        #expect(a.state == .idle)
    }

    /// Codex's own reports (OSC 7501), as its TUI sends them for a turn with an approval, an
    /// Esc, and an error: one alert per episode, done kept through the idle that follows.
    @Test func programStatusReports() {
        var a = PaneAgent()
        #expect(a.report(.idle, focused: false).alert == nil && a.state == .idle)
        a.report(.working, focused: false)
        #expect(a.state == .running)
        let ask = a.report(.blocked(.permission), message: "Permission: Bash", focused: false)
        #expect(a.state == .needsInput(.permission) && ask.notify == .needsInput(.permission, message: "Permission: Bash"))
        #expect(a.report(.blocked(.permission), focused: false).alert == nil)  // a repeat: absorbed
        #expect(a.report(.blocked(.question), focused: false).alert == nil && a.state == .needsInput(.question))
        a.report(.working, focused: false)
        let done = a.report(.done, lastMessage: "# Result", focused: true)
        #expect(a.state == .done && done.alert == .done(lastMessage: "# Result") && done.notify == nil)
        #expect(a.report(.idle, focused: false).alert == nil && a.state == .done)  // the TUI's idle after a turn
        a.report(.working, focused: false)
        #expect(a.report(.idle, focused: false).alert == nil && a.state == .idle)  // Esc
        a.report(.working, focused: false)
        #expect(a.report(.error, focused: false).alert == .failed(errorType: nil))
        a.report(.working, focused: false)
        #expect(a.report(.clear, focused: false).alert == nil && a.state == .idle)
    }

    // MARK: Sessions from Codex's shared app-server

    /// A session's hook of this kind (the shared server's hooks all name the same pane).
    func shared(_ kind: String, _ sid: String) throws -> HookEvent {
        try event(#"{"hook_event_name":"\#(kind)","session_id":"\#(sid)"}"#, pane: "first")
    }

    /// Two codex start at the same moment: a tie, neither bound. One goes on with tool events,
    /// the other's next prompt starts a turn: a tool event never binds (only a turn start does),
    /// that prompt binds its own session.
    @Test func sharedServerSessionsBindOneToOne() throws {
        var b = CodexSessionBinder(window: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        for sid in ["a1", "a2"] {
            #expect(b.hold(try shared("SessionStart", sid), at: at(0)))
            #expect(b.hold(try shared("UserPromptSubmit", sid), at: at(0.01)))
        }
        var turns = [CodexSessionBinder.Turn(pane: "A1", at: at(0.05)), CodexSessionBinder.Turn(pane: "A2", at: at(0.06))]
        #expect(b.resolve(turns: turns, now: at(1)).bound.isEmpty && b.pending.count == 2)  // the window is still open
        let tie = b.resolve(turns: turns, now: at(1.6))
        #expect(tie.bound.isEmpty && tie.unbound.count == 2 && tie.unbound.allSatisfy { $0.panes == 2 } && b.pending.isEmpty)

        // a1 goes on (its tools, its Stop): nothing waits on those.
        #expect(!b.hold(try shared("PreToolUse", "a1"), at: at(5)))
        // a2's next prompt starts its pane's turn at that moment; a1's tool events meanwhile.
        turns[1].at = at(5.02)
        #expect(!b.hold(try shared("PostToolUse", "a1"), at: at(5.03)))
        #expect(b.hold(try shared("UserPromptSubmit", "a2"), at: at(5.04)))
        #expect(!b.hold(try shared("PreToolUse", "a1"), at: at(5.05)))
        #expect(b.hold(try shared("PreToolUse", "a2"), at: at(5.06)))
        #expect(!b.hold(try shared("Stop", "a1"), at: at(5.2)))
        let r = b.resolve(turns: turns, now: at(6.6))
        #expect(r.bound.map(\.session) == ["a2"] && r.bound.first?.pane == "A2")
        #expect(r.bound.first?.events.map(\.kind) == [.userPromptSubmit, .preToolUse])
        // …and a1's own next prompt binds a1.
        turns[1].claimedAt = at(5.04)
        turns[0].at = at(9)
        #expect(b.hold(try shared("UserPromptSubmit", "a1"), at: at(9.01)))
        #expect(b.resolve(turns: turns, now: at(10.6)).bound.map { "\($0.session)>\($0.pane)" } == ["a1>A1"])
    }

    /// A codex outside lmux on the same shared server (its hooks carry the pane of the codex that
    /// started the server) prompts as pane z's codex starts its first turn: z's turn could be
    /// either session, so it is neither's; once z's session is bound, the outsider gets no turn.
    @Test func outsideSessionNeverTakesAPanesTurn() throws {
        var b = CodexSessionBinder(window: 1.5)
        let t0 = Date(timeIntervalSinceReferenceDate: 2000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        #expect(b.hold(try shared("UserPromptSubmit", "outside"), at: at(0)))
        #expect(b.hold(try shared("SessionStart", "zs"), at: at(0.3)))
        var z = CodexSessionBinder.Turn(pane: "Z", at: at(0.2))
        #expect(b.waits(z) && !b.waits(.init(pane: "far", at: at(10))))  // a pane whose turn is unrelated: no wait
        // The outsider's wait ends first (a window after z's turn): z could also be zs, so it isn't the outsider's.
        #expect(b.resolve(turns: [z], now: at(1.6)).unbound.isEmpty)
        let first = b.resolve(turns: [z], now: at(1.75))
        #expect(first.bound.isEmpty && first.unbound.map(\.session) == ["outside"] && b.pending.keys.sorted() == ["zs"])
        // …nor zs's: it could have been the outsider's (given up or not).
        #expect(b.resolve(turns: [z], now: at(1.8)).bound.isEmpty)

        // Later zs is bound (its own prompt, its own turn); its next turn is claimed by its prompt
        // (routed to z directly): the outsider prompting then gets nothing.
        z.at = at(20)
        #expect(b.hold(try shared("UserPromptSubmit", "zs"), at: at(20.01)))
        #expect(b.resolve(turns: [z], now: at(21.6)).bound.map(\.pane) == ["Z"])
        z = CodexSessionBinder.Turn(pane: "Z", at: at(30), claimedAt: at(30.02))
        #expect(b.hold(try shared("UserPromptSubmit", "outside"), at: at(30.01)))
        #expect(!b.waits(z))
        let late = b.resolve(turns: [z], now: at(31.6))
        #expect(late.bound.isEmpty && late.unbound.first?.panes == 0)
        // A session is never bound from a turn of two panes either, nor from a SessionEnd.
        #expect(b.hold(try shared("UserPromptSubmit", "s"), at: at(40)))
        #expect(b.resolve(turns: [.init(pane: "P", at: at(40.1)), .init(pane: "Q", at: at(39.9))], now: at(41.6))
            .unbound.first?.panes == 2)
        #expect(!b.hold(try shared("SessionEnd", "s2"), at: at(50)) && b.pending.isEmpty)

        // zs arrives after the outsider's own window: the outsider still waits out z's turn's
        // window (zs could start a turn until then), so z is never the outsider's.
        var c = CodexSessionBinder(window: 1.5)
        #expect(c.hold(try shared("UserPromptSubmit", "outside"), at: at(100)))
        let zt = CodexSessionBinder.Turn(pane: "Z", at: at(101.4))
        let early = c.resolve(turns: [zt], now: at(101.5))
        #expect(early.bound.isEmpty && early.unbound.isEmpty && early.next == at(102.9))
        #expect(c.hold(try shared("SessionStart", "zs"), at: at(101.6)))
        let out = c.resolve(turns: [zt], now: at(102.9))
        #expect(out.bound.isEmpty && out.unbound.map(\.session) == ["outside"] && out.next == at(103.1))
        #expect(c.resolve(turns: [zt], now: at(103.1)).bound.isEmpty && c.pending.isEmpty)
    }

    @Test func subagentsCoalesce() throws {
        func sub(_ name: String, _ id: String) throws -> HookEvent {
            try event(#"{"hook_event_name":"\#(name)","session_id":"s","agent_id":"\#(id)","agent_type":"worker"}"#)
        }
        var a = PaneAgent()
        a.handle(try event(CodexPayloads.userPromptSubmit), focused: false)
        a.handle(try sub("SubagentStart", "a1"), focused: false)
        a.handle(try sub("SubagentStart", "a2"), focused: false)
        #expect(a.activeSubagents == ["a1", "a2"])
        // Subagents finishing (their Stop, SubagentStop) never end the turn or alert.
        #expect(a.handle(try sub("Stop", "a1"), focused: false).alert == nil)
        #expect(a.handle(try sub("SubagentStop", "a1"), focused: false).alert == nil)
        #expect(a.state == .running)
        let done = a.handle(try event(CodexPayloads.stop), focused: false)
        #expect(done.alert != nil && a.activeSubagents.isEmpty)
        // One notification for the whole turn.
        #expect(a.handle(try event(CodexPayloads.stop), focused: false).alert == nil)
    }

    // MARK: Installer

    static let hookPath = "/Applications/lmux.app/Contents/MacOS/lmux-hook"

    /// Shaped like the user's real ~/.codex/hooks.json: another tool's hooks, 2-space JSON.
    static let foreign = """
    {
      "hooks": {
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "\\"/usr/local/bin/node\\" \\"/x/codex-hook.js\\"",
                "timeout": 30
              }
            ]
          }
        ],
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/x/notify.sh",
                "timeout": 30
              }
            ]
          }
        ]
      }
    }

    """

    @Test func installFresh() throws {
        let after = try HookInstaller.install(into: nil, hookPath: Self.hookPath, target: CodexHookInstaller.target)
        let s = try HookInstaller.status(of: after, target: CodexHookInstaller.target)
        #expect(s.isComplete && s.installedEvents == CodexHookInstaller.events)
        #expect(s.commands == ["[ -n \"$LMUX_PANE_ID\" ] && [ -x '\(Self.hookPath)' ] && exec '\(Self.hookPath)' codex; exit 0 # lmux-managed"])
        // Codex events only: nothing Claude-only (Notification, Elicitation, StopFailure…).
        for e in ["Notification", "Elicitation", "StopFailure", "PostToolUseFailure"] { #expect(!after.contains("\"\(e)\"")) }
        let removed = try HookInstaller.uninstall(from: after, target: CodexHookInstaller.target)
        #expect(try HookInstaller.status(of: removed, target: CodexHookInstaller.target).installedEvents.isEmpty)
    }

    @Test func installAppendsAfterUserHooksAndUninstallRestoresBytes() throws {
        let t = CodexHookInstaller.target
        let after = try HookInstaller.install(into: Self.foreign, hookPath: Self.hookPath, target: t)
        // The user's hooks keep their positions (Codex trusts hooks by position): group 0 is theirs.
        let pos = try CodexHookInstaller.positions(after)
        #expect(pos.contains("session_start:1:0") && pos.contains("stop:1:0") && pos.contains("pre_tool_use:0:0"))
        #expect(!pos.contains("session_start:0:0"))
        // Only added lines: every original line is still there, in order.
        let old = Self.foreign.split(separator: "\n", omittingEmptySubsequences: false)
        var it = after.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        for line in old { while let n = it.next(), n != line {} }
        #expect(try HookInstaller.install(into: after, hookPath: Self.hookPath, target: t) == after)  // idempotent
        #expect(try HookInstaller.uninstall(from: after, target: t) == Self.foreign)
    }

    @Test func applyAndPristineRestore() throws {
        let dir = TestTemp.dir("codex-install")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("hooks.json").path
        try Data(Self.foreign.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o640)
        let pristine = dir.appendingPathComponent("pristine")
        let change = try HookInstaller.planInstall(settingsPath: path, hookPath: Self.hookPath, target: CodexHookInstaller.target)
        try HookInstaller.apply(change, pristineDirectory: pristine)
        #expect(CodexHookInstaller.isComplete(hooksPath: path))
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o640)
        let un = try CodexHookInstaller.planUninstall(hooksPath: path, pristineDirectory: pristine)
        try HookInstaller.apply(un, pristineDirectory: pristine)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == Self.foreign)

        // Created by lmux: uninstall removes the file again.
        let fresh = dir.appendingPathComponent("new/hooks.json").path
        try HookInstaller.apply(try CodexHookInstaller.planInstall(hooksPath: fresh, hookPath: Self.hookPath), pristineDirectory: pristine)
        try HookInstaller.apply(try CodexHookInstaller.planUninstall(hooksPath: fresh, pristineDirectory: pristine),
                                pristineDirectory: pristine)
        #expect(!FileManager.default.fileExists(atPath: fresh))

        // Edited by the user since: only lmux's entries are cut out.
        try HookInstaller.apply(try CodexHookInstaller.planInstall(hooksPath: path, hookPath: Self.hookPath), pristineDirectory: pristine)
        var text = try String(contentsOfFile: path, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"timeout\": 30", with: "\"timeout\": 31")
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try HookInstaller.apply(try CodexHookInstaller.planUninstall(hooksPath: path, pristineDirectory: pristine),
                                pristineDirectory: pristine)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == Self.foreign.replacingOccurrences(of: "\"timeout\": 30", with: "\"timeout\": 31"))
    }

    @Test func defaultPathsFollowCodexHome() {
        #expect(CodexHookInstaller.defaultHooksPath(environment: ["CODEX_HOME": "/w/cx", "HOME": "/h"]) == "/w/cx/hooks.json")
        #expect(CodexHookInstaller.defaultHooksPath(environment: ["HOME": "/h"]) == "/h/.codex/hooks.json")
        #expect(CodexHookInstaller.configPath(environment: ["CODEX_HOME": "/w/cx"]) == "/w/cx/config.toml")
        #expect(CodexHookInstaller.snake("UserPromptSubmit") == "user_prompt_submit")
    }

    @Test func trustRecords() throws {
        let after = try HookInstaller.install(into: Self.foreign, hookPath: Self.hookPath, target: CodexHookInstaller.target)
        let pos = try CodexHookInstaller.positions(after)
        #expect(pos.count == CodexHookInstaller.events.count)
        let path = "/Users/me/.codex/hooks.json"
        func entry(_ p: String) -> String { "[hooks.state.\"\(path):\(p)\"]\ntrusted_hash = \"sha256:00\"\n" }
        let none = "[features]\nhooks = true\n"
        #expect(CodexHookInstaller.trust(positions: pos, hooksPath: path, config: none) == .needsReview(count: pos.count))
        let some = none + pos.prefix(3).map(entry).joined()
        #expect(CodexHookInstaller.trust(positions: pos, hooksPath: path, config: some) == .needsReview(count: pos.count - 3))
        #expect(CodexHookInstaller.trust(positions: pos, hooksPath: path, config: none + pos.map(entry).joined()) == .trusted)
        // Another file's records don't count.
        let other = pos.map { "[hooks.state.\"/elsewhere/hooks.json:\($0)\"]\n" }.joined()
        #expect(CodexHookInstaller.trust(positions: pos, hooksPath: path, config: other) == .needsReview(count: pos.count))
        #expect(CodexHookInstaller.trust(hooksPath: "/nonexistent/hooks.json", configPath: "/nonexistent/c.toml") == .notInstalled)
        // Codex records the path it loaded: through a symlinked home (a linked ~/.codex, /tmp vs
        // /private/tmp) it differs from lmux's, and still counts.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lmux-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("real"))
        let linked = dir.appendingPathComponent("link/hooks.json").path
        try after.write(toFile: linked, atomically: true, encoding: .utf8)
        let real = CodexHookInstaller.realPath(linked)
        #expect(real != linked)
        let records = pos.map { "[hooks.state.\"\(real):\($0)\"]\n" }.joined()
        #expect(CodexHookInstaller.trust(positions: pos, hooksPath: linked, config: records) == .trusted)
    }

    // MARK: lmux-hook end to end

    @Test func hookBinaryTagsCodexEvents() throws {
        let path = tempSocketPath()
        let inbox = Inbox()
        let server = HookSocketServer(path: path, onEvent: inbox.add, onError: inbox.addError)
        try server.start()
        defer { server.stop() }
        let bin = try hookBinary()
        let env = ["LMUX_PANE_ID": "pane-cx", "LMUX_PANE_NONCE": "tok-cx", "LMUX_SOCKET": path, "CODEX_HOME": "/w/cx",
                   "OPENAI_API_KEY": "sk-x"]
        let all = [CodexPayloads.sessionStart, CodexPayloads.userPromptSubmit, CodexPayloads.preToolUse,
                   CodexPayloads.permissionRequest, CodexPayloads.postToolUse, CodexPayloads.interrupt,
                   CodexPayloads.sessionStart_1, CodexPayloads.userPromptSubmit_1, CodexPayloads.preToolUse_2,
                   CodexPayloads.postToolUse_1, CodexPayloads.stop, CodexPayloads.sessionEnd]
        var walls: [Double] = []
        for payload in all {
            let (status, out, ms) = try runHookArgs(bin, ["codex"], stdin: payload, env: env)
            #expect(status == 0 && out.isEmpty)
            walls.append(ms)
        }
        #expect(inbox.wait(count: all.count))
        let got = inbox.received.map(\.0)
        #expect(got.map(\.name) == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                                    "Interrupt", "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop",
                                    "SessionEnd"])
        #expect(got.allSatisfy { $0.agent == .codex && $0.paneID == "pane-cx" && $0.paneToken == "tok-cx" })
        #expect(got[0].claudeEnvironment == ["CODEX_HOME": "/w/cx"])
        #expect(inbox.errorList.isEmpty)
        print(String(format: "[lmux latency] codex hook process wall: p50 %.2fms max %.2fms (n=%d)",
                     percentile(walls, 0.5), walls.max() ?? 0, walls.count))
    }

    func runHookArgs(_ bin: URL, _ args: [String], stdin: String, env: [String: String]) throws -> (Int32, Data, Double) {
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        try p.run()
        inPipe.fileHandleForWriting.write(Data(stdin.utf8))
        try inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        let t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        return (p.terminationStatus, outPipe.fileHandleForReading.readDataToEndOfFile(), Double(t1 - t0) / 1e6)
    }
}
