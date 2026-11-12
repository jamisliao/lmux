import AppKit
import IOSurface
import LmuxHooks
import LmuxSessions
import LmuxTerminal
import LmuxTokens
import LmuxTranscript
@testable import LmuxUI

// P2/P3 checks on the headless app: screen -> turn mapping (pure + on a rendered
// Claude-like screen), hover actions, Copy original, undo-send toast,
// auto titles (fake model), History (fixture corpus with Korean text).

// MARK: - Fixtures

struct FixtureTurn {
    var prompt: String
    var reply: String?
    /// Tool calls before the reply: (tool name, file path).
    var tools: [(String, String)] = []
}

/// A Claude Code 2.1.x-shaped transcript (one entry per content block, chained by parentUuid).
/// `uuidPrefix`: turn uuids are `<prefix>-u<n>` (default: the session id).
func fixtureJSONL(session: String, uuidPrefix: String? = nil, cwd: String, turns: [FixtureTurn],
                  start: Date = Date().addingTimeInterval(-3600), aiTitle: String? = nil, compactAfter: Int? = nil) -> String {
    var lines: [String] = []
    var parent: String?
    var t = start
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func add(_ o: [String: Any]) {
        let d = try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])
        lines.append(String(decoding: d, as: UTF8.self))
    }
    func chain(_ type: String, _ uuid: String, _ extra: [String: Any]) {
        var o: [String: Any] = ["parentUuid": parent ?? NSNull(), "isSidechain": false, "userType": "external", "cwd": cwd,
                                "sessionId": session, "version": "2.1.280", "gitBranch": "main", "type": type,
                                "uuid": uuid, "timestamp": iso.string(from: t)]
        for (k, v) in extra { o[k] = v }
        add(o)
        parent = uuid
        t = t.addingTimeInterval(5)
    }
    for (i, turn) in turns.enumerated() {
        let n = i + 1
        chain("user", "\(uuidPrefix ?? session)-u\(n)", ["message": ["role": "user", "content": turn.prompt], "turnOrigin": "human",
                                           "promptSource": "typed"])
        for (k, tool) in turn.tools.enumerated() {
            let id = "toolu_\(n)_\(k)"
            chain("assistant", "\(session)-t\(n)-\(k)", ["message": ["id": "msg_\(n)_t\(k)", "role": "assistant",
                "content": [["type": "tool_use", "id": id, "name": tool.0, "input": ["file_path": tool.1]]]]])
            let result: [String: Any] = tool.0 == "Write" ? ["type": "create", "filePath": tool.1] : ["ok": true]
            chain("user", "\(session)-r\(n)-\(k)", ["message": ["role": "user", "content": [["type": "tool_result",
                "tool_use_id": id, "content": "ok"]]],
                "toolUseResult": result,
                "sourceToolAssistantUUID": "\(session)-t\(n)-\(k)"])
        }
        if let reply = turn.reply {
            chain("assistant", "\(session)-a\(n)", ["message": ["id": "msg_\(n)", "role": "assistant",
                                                                "content": [["type": "text", "text": reply]]]])
        }
        add(["type": "last-prompt", "lastPrompt": turn.prompt, "leafUuid": parent!, "sessionId": session])
        if let k = compactAfter, k == n {
            let leaf = parent
            parent = nil
            chain("system", "\(session)-cb", ["subtype": "compact_boundary", "content": "Conversation compacted",
                                              "logicalParentUuid": leaf!])
            chain("user", "\(session)-cs", ["message": ["role": "user", "content": "This session is being continued…"],
                                            "isCompactSummary": true, "isVisibleInTranscriptOnly": true])
        }
    }
    if let aiTitle { add(["type": "ai-title", "aiTitle": aiTitle, "sessionId": session]) }
    return lines.joined(separator: "\n") + "\n"
}

/// The Claude-like screen and its transcript (same turns as the mockup's left pane).
enum ScreenFixture {
    static let prompt1 = "부분환불할 때 금액 검증이 빠져 있어. refund.ts 보고 고쳐줘"
    static let prompt2 = "also add a test for the 0-won case, then run it"
    static let reply1 = """
    원인 찾았어요. `createPartialRefund()`가 `amount`를 남은 금액과 비교하지 않아서, 이미 환불된 주문도 또 환불돼요.

    **고칠 방향**
    1. `remaining = captured - refunded` 계산
    2. `amount > remaining`이면 `RefundExceedsCapture`
    3. 0원 이하 요청은 `RefundInvalidAmount`로 거절
    """
    static let reply2 = "테스트 추가했고 **14개 모두 통과**해요.\n\n```\npnpm vitest run refund\n```"

    static var turns: [FixtureTurn] {
        [FixtureTurn(prompt: prompt1, reply: reply1, tools: [("Read", "/work/payments/src/payments/refund.ts"),
                                                              ("Edit", "/work/payments/src/payments/refund.ts")]),
         FixtureTurn(prompt: prompt2, reply: reply2, tools: [("Write", "/work/payments/src/payments/refund.test.ts")])]
    }

    /// What Claude Code 2.1.280 draws for those turns (format observed in the e2e run).
    static let screen = """
    ❯ \(prompt1)

    ⏺ Read(src/payments/refund.ts)
      ⎿  Read 142 lines

    ⏺ 원인 찾았어요. createPartialRefund()가 amount를
      남은 금액과 비교하지 않아서, 이미 환불된 주문도 또 환불돼요.

      고칠 방향:
      1. remaining = captured - refunded 계산
      2. amount > remaining이면 RefundExceedsCapture
      3. 0원 이하 요청은 RefundInvalidAmount로 거절

    ⏺ Update(src/payments/refund.ts)
      ⎿  Updated src/payments/refund.ts with 5 additions

    ✻ Worked for 12s

    ❯ \(prompt2)

    ⏺ Bash(pnpm vitest run refund)
      ⎿  ✓ refund.test.ts (14 tests) 212ms

    ⏺ 테스트 추가했고 14개 모두 통과해요.

    """

    /// Right pane of the mockup: a permission dialog (its `❯ 1. Yes` must never count as a prompt).
    static let prompt3 = "refunds 테이블에 partial_amount 컬럼 추가하는 마이그레이션 만들어줘"
    static let screen2 = """
    ❯ \(prompt3)

    ⏺ Write(db/migrations/0042_refund_partial.sql)
      ⎿  Wrote 7 lines to db/migrations/0042_refund_partial.sql

    ⏺ 마이그레이션 파일 만들었어요. 로컬 DB에 적용해볼게요.

     Bash command

       pnpm db:migrate --to 0042
       Apply the refunds.partial_amount migration

     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for pnpm db:migrate
       3. No, and tell Claude what to do differently (esc)

    """

    /// A program for a pane: prints `text`, then Claude's input box sized to the
    /// terminal, then waits (keys are not echoed).
    static func script(_ text: String, input: String?, dir: URL, name: String) -> String {
        let txt = dir.appendingPathComponent("\(name).txt")
        try? text.write(to: txt, atomically: true, encoding: .utf8)
        let sh = dir.appendingPathComponent("\(name).sh")
        // -icanon too: no echo in canonical mode looks like a password prompt, and Ghostty
        // then draws its lock cursor (the stray 🔒 in earlier screenshots).
        var body = "#!/bin/sh\nstty -echo -icanon\nprintf '\\033[2J\\033[H'\ncat '\(txt.path)'\n"
        if let input {
            body += """
            COLS=$(stty size | cut -d' ' -f2); [ -z "$COLS" ] && COLS=100
            RULE=$(printf '%*s' "$COLS" '' | sed 's/ /─/g')
            printf '%s\\n' "$RULE"
            printf '❯ %s\\n' '\(input)'
            printf '%s\\n' "$RULE"
            printf '  \\033[2m⏵⏵ accept edits on (shift+tab to cycle)\\033[0m'

            """
        }
        body += "exec sleep 100000\n"
        try? body.write(to: sh, atomically: true, encoding: .utf8)
        chmod(sh.path, 0o755)
        return sh.path
    }
}

@MainActor
func hookEvent(_ c: LmuxController, _ p: Pane, _ name: String, session: String, transcript: String? = nil, _ extra: [String: Any] = [:]) {
    var o: [String: Any] = ["hook_event_name": name, "session_id": session, "cwd": "/tmp"]
    if let transcript { o["transcript_path"] = transcript }
    for (k, v) in extra { o[k] = v }
    c.handleHook(try! HookEvent(paneID: p.id, payload: o))
}

@MainActor
func hover(_ c: LmuxController, _ p: Pane, row: Int) async {
    let m = c.screenMap(p, maxAge: 0)
    guard row < m.rows.count else { return }
    c.paneMouseMoved(p, NSPoint(x: 120, y: p.surface.bounds.height - (m.rows[row].top + m.rowHeight / 2)))
    await sleepMs(60)
}

// MARK: - Locator (pure)

@MainActor
func locatorChecks(_ r: Report) {
    r.section = "locator"
    typealias L = TurnLocator
    let turns = [L.PromptTurn(index: 1, prompt: "fix the login bug\nmore details", hasReply: true),
                 L.PromptTurn(index: 2, prompt: "continue", hasReply: true),
                 L.PromptTurn(index: 3, prompt: "continue", hasReply: false),
                 L.PromptTurn(index: 4, prompt: "부분환불할 때 금액 검증이 빠져 있어. refund.ts 보고 고쳐줘", hasReply: true)]
    let rule = String(repeating: "─", count: 40)
    let rows = [
        "  the end of an earlier reply",               // 0: belongs to the turn before the first prompt
        "❯ fix the login bug",                         // 1 prompt 1
        "  more details",                              // 2 continuation
        "",
        "⏺ Read(src/login.ts)",                        // 4 tool call: not a reply
        "  ⎿  Read 10 lines",
        "⏺ Fixed it.",                                 // 6 reply 1
        "  The redirect loop is gone.",                // 7 reply 1 continuation
        "❯ continue",                                  // 8 prompt 2 (duplicate text, resolved by order)
        "⏺ Done.",                                     // 9 reply 2
        "❯ continue",                                  // 10 prompt 3
        " ❯ 1. Yes",                                   // 11 permission menu: not a prompt
        "❯ 부분환불할 때 금액 검증이 빠져 있어. refund.ts 보", // 12 prompt 4, wrapped
        "  고 고쳐줘",                                  // 13 continuation
        "⏺ 원인 찾았어요.",                              // 14 reply 4
        rule,                                           // 15 input rule
        "❯ continue",                                  // 16 the input box (same text as a prompt!)
        rule,
    ]
    let m = L.locate(rows: rows, turns: turns)
    r.check("prompt heads in order, duplicates resolved by position",
            m.promptHeads().map(\.turn) == [1, 2, 3, 4] && m.promptHeads().map(\.row) == [1, 8, 10, 12],
            "\(m.promptHeads())")
    r.check("multi-line / wrapped prompt rows map to their prompt", m.roles[2] == .prompt(turn: 1, head: 1)
            && m.roles[13] == .prompt(turn: 4, head: 12))
    r.check("tool call rows are not replies", m.roles[4] == .none && m.roles[5] == .none)
    r.check("reply bullet + continuation map to the turn", m.roles[6] == .reply(turn: 1) && m.roles[7] == .reply(turn: 1)
            && m.roles[14] == .reply(turn: 4))
    r.check("rows above the first visible prompt belong to the turn before it (none here: turn 0)", m.roles[0] == .none)
    r.check("permission menu `❯ 1. Yes` is not a prompt", m.roles[11] == .none)
    r.check("input box is never a prompt, even with a prompt's text", m.inputRow == 16 && m.inputRule == 15
            && m.roles[16] == .input)
    let noRule = L.locate(rows: ["❯ continue", "⏺ ok"], turns: turns)
    r.check("without transcript order hints, the latest matching turn wins", noRule.promptHeads().map(\.turn) == [3])
    let unknown = L.locate(rows: ["❯ something never sent", "⏺ hm"], turns: turns)
    r.check("a marker row that matches no prompt is ignored", unknown.promptHeads().isEmpty)
    let short = L.locate(rows: ["❯ fix"], turns: turns)
    r.check("a short prefix never matches (needs >= 8 chars or the full line)", short.promptHeads().isEmpty)
    let mid = L.locate(rows: ["  …rest of reply 3", "❯ 부분환불할 때 금액 검증이 빠져 있어. refund.ts 보고 고쳐줘"],
                       turns: turns.map { L.PromptTurn(index: $0.index, prompt: $0.prompt, hasReply: true) })
    r.check("screen starting mid-reply: those rows belong to the previous turn", mid.roles[0] == .reply(turn: 3)
            || mid.roles[0] == .none)
    // A `!` shell command is drawn as "! cmd": it heads its own turn, and only a shell turn.
    let shellTurns = [L.PromptTurn(index: 1, prompt: "list the files", hasReply: true),
                      L.PromptTurn(index: 2, prompt: "<bash-input>ls -la</bash-input>", hasReply: false),
                      L.PromptTurn(index: 3, prompt: "list the files again", hasReply: true)]
    let sh = L.locate(rows: ["❯ list the files", "⏺ OK", "! ls -la", "  ⎿  total 0", "❯ list the files again", "⏺ OK"],
                      turns: shellTurns)
    r.check("a ! shell command heads its own turn; its output is that turn's", sh.promptHeads().map(\.turn) == [1, 2, 3]
            && sh.promptHeads().map(\.row) == [0, 2, 4] && sh.turnOfRow[3] == 2, "\(sh.promptHeads()) \(sh.turnOfRow)")
    // A prompt row that matches no turn's text: that turn only when the order leaves no doubt.
    let pasted = [L.PromptTurn(index: 1, prompt: "list the files", hasReply: true),
                  L.PromptTurn(index: 2, prompt: "PASTED LINE 1\nPASTED LINE 2", hasReply: true),
                  L.PromptTurn(index: 3, prompt: "list the files again", hasReply: true)]
    let pRows = ["❯ list the files", "⏺ OK", "❯ [Pasted text #1 +2 lines]", "⏺ OK 2", "❯ list the files again", "⏺ OK 3"]
    let pm = L.locate(rows: pRows, turns: pasted)
    r.check("an unmatched prompt row between turns 1 and 3, turn 2 not on screen: it is turn 2",
            pm.promptHeads().map(\.turn) == [1, 2, 3] && pm.turnOfRow == [1, 1, 2, 2, 3, 3], "\(pm.promptHeads()) \(pm.turnOfRow)")
    let pTop = L.locate(rows: Array(pRows.dropFirst(2)), turns: pasted)
    r.check("…above the first matched prompt too (the turn right before it)", pTop.turnOfRow == [2, 2, 3, 3], "\(pTop.turnOfRow)")
    let pLost = L.locate(rows: pRows, turns: [pasted[0], L.PromptTurn(index: 2, prompt: "list the files again", hasReply: true)])
    r.check("…with no turn left for it: it ends the turn above, its rows are no turn's",
            pLost.promptHeads().map(\.turn) == [1, 2] && pLost.turnOfRow == [1, 1, nil, nil, 2, 2], "\(pLost.turnOfRow)")
    let pTwo = L.locate(rows: ["❯ list the files", "⏺ OK", "❯ one", "⏺ x", "❯ two", "⏺ y", "❯ list the files again"], turns: pasted)
    r.check("…two unmatched rows for one missing turn: neither is a turn's", pTwo.turnOfRow[2...5].allSatisfy { $0 == nil }
            && pTwo.turnOfRow[1] == 1, "\(pTwo.turnOfRow)")
    let rule80 = String(repeating: "─", count: 80)
    let note = L.locate(rows: ["❯ list the files", "⏺ Here:", "          deeply indented code", String(repeating: " ", count: 62) + "● high · /effort",
                               rule80, "❯ ", rule80], turns: [pasted[0]])
    r.check("the right-aligned note above the input is no turn's; indented reply text above it still is",
            note.turnOfRow[3] == nil && note.turnOfRow[2] == 1, "\(note.turnOfRow)")
    r.check("the “done” line: “✻ Crunched for 3s · done 11:42 PM” only, not a reply that says so or a spinner",
            L.isDoneLine("✻ Crunched for 3s · done Wednesday 11:42 PM") && !L.isDoneLine("⏺ Waiting for CI · done in 3m")
            && !L.isDoneLine("✻ Worked for 12s") && !L.isDoneLine("✳ Crunching… (12s · esc to interrupt)"))
    let notShell = L.locate(rows: ["❯ ls -la", "! list the files"], turns: shellTurns)
    r.check("…“❯ cmd” is not the shell turn, “! text” not a prompt", notShell.promptHeads().isEmpty, "\(notShell.promptHeads())")
    let cmd = ClaudeCommand.resume(
        argv: ["node", "/opt/claude/cli.js", "--model", "opus", "fix it now", "--dangerously-skip-permissions",
               "-r", "old", "--settings=/x y.json", "--continue"], sessionID: "abc-1")
    r.check("relaunch keeps session flags, drops prompt/other selectors", cmd ==
            "claude --model opus --dangerously-skip-permissions '--settings=/x y.json' --resume abc-1", cmd)
    let fresh = ClaudeCommand.resume(argv: ["/usr/local/bin/claude", "--model", "haiku"], sessionID: nil)
    r.check("nothing left to resume -> fresh start with the same flags", fresh == "/usr/local/bin/claude --model haiku", fresh)
    // Multi-value flags (`<dirs...>`) take every argument up to the next flag, like claude's own parser.
    let multi = ClaudeCommand.resume(
        argv: ["claude", "--add-dir", "/a", "/b c", "--allowedTools", "Bash(git:*)", "Read", "--mcp-config", "m1.json",
               "m2.json", "--betas", "x-1", "--allow-dangerously-skip-permissions", "-d", "api,hooks", "--debug-file",
               "/tmp/d.log", "--tools", "Bash", "Edit", "-p", "--print", "--session-id", "S", "--fork-session",
               "--output-format", "json", "-n", "my name", "--", "a prompt"],
        sessionID: "s-2")
    r.check("multi-value and optional-value flags survive, print/session flags don't", multi ==
            "claude --add-dir /a '/b c' --allowedTools 'Bash(git:*)' Read --mcp-config m1.json m2.json --betas x-1 "
            + "--allow-dangerously-skip-permissions -d api,hooks --debug-file /tmp/d.log --tools Bash Edit -n 'my name' --resume s-2",
            multi)
    let dbg = ClaudeCommand.resume(argv: ["claude", "--debug", "--model", "x", "hello"], sessionID: "s")
    r.check("an optional value is not taken from the next flag", dbg == "claude --debug --model x --resume s", dbg)
    let envd = ClaudeCommand.resume(argv: ["claude", "--model", "x"], sessionID: "s",
                                    environment: ["CLAUDE_CONFIG_DIR": "/work/.claude two",
                                                  "HOME": "/Users/x", "BASH_DEFAULT_TIMEOUT_MS": "8000",
                                                  "ANTHROPIC_MODEL": "inherited-same"],
                                    inherited: ["HOME": "/Users/x", "ANTHROPIC_MODEL": "inherited-same"])
    r.check("leading env assignments kept (what the shell didn't already have)",
            envd == "BASH_DEFAULT_TIMEOUT_MS=8000 CLAUDE_CONFIG_DIR='/work/.claude two' claude --model x --resume s", envd)
}

// MARK: - App checks

@MainActor
func runP2(_ r: Report, _ c: LmuxController, _ w: NSWindow) async {
    locatorChecks(r)
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("fixtures", isDirectory: true)
    try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
    let existing = Set(c.model.workspaces.map(\.id))
    var created: [Workspace] = []

    // ------------------------------------------------------------ Return
    r.section = "return"
    let wsA = c.newWorkspace(); created.append(wsA)
    let pA = wsA.panes[0]
    _ = await sinks.waitReady(pA.id)
    let wsB = c.newWorkspace(); created.append(wsB)
    let pB = wsB.panes[0]
    _ = await sinks.waitReady(pB.id)
    hookEvent(c, pA, "SessionStart", session: "8e1f0c2a-0000-4000-8000-0000000009a1", ["source": "startup"])
    c.select(wsB); c.select(wsA)
    pA.lastReturnAt = nil
    await type("\r", window: w)
    let sentRight = await sinks.wait(pA.id, contains: "\r")
    r.check("Enter right after switching to a Claude pane goes straight through (no card)",
            !c.cardShown(pA) && sentRight && pA.lastReturnAt != nil, sinks.text(pA.id))
    c.select(wsB)
    await type("\r", window: w)
    let plainSent = await sinks.wait(pB.id, contains: "\r")
    r.check("plain shell panes: Enter goes straight through", !c.cardShown(pB) && plainSent)
    c.select(wsA)
    // Korean IME: Enter while a syllable is composing commits it AND sends the line, so it counts
    // for Undo. Japanese / Chinese Enter only converts.
    c.inputSourceLanguages = { ["ko"] }
    pA.lastReturnAt = nil
    pA.surface.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    await type("\r", window: w)
    r.check("Korean IME composing: Enter (commit + send) counts for Undo", !c.cardShown(pA) && pA.lastReturnAt != nil)
    pA.surface.unmarkText()
    c.inputSourceLanguages = { ["ja"] }
    pA.lastReturnAt = nil
    pA.surface.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    await type("\r", window: w)
    r.check("Japanese IME composing: Enter only converts (no Undo)", !c.cardShown(pA) && pA.lastReturnAt == nil)
    pA.surface.unmarkText()
    c.inputSourceLanguages = LmuxController.currentInputSourceLanguages

    // ------------------------------------------------------------ undo send
    r.section = "undo"
    // Session ids are UUIDs and transcripts sit in <config>/projects/<dir>/<id>.jsonl.
    let gDir = fx.appendingPathComponent("projects/-tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: gDir, withIntermediateDirectories: true)
    let gPath = gDir.appendingPathComponent("8e1f0c2a-0000-4000-8000-0000000009a1.jsonl").path
    // The same short prompt twice ("yes"): Undo must take back the one just sent, never the older one.
    let gStart = Date().addingTimeInterval(-600)
    let yes1 = [FixtureTurn(prompt: "yes", reply: "On it.")]
    let yes2 = yes1 + [FixtureTurn(prompt: "yes", reply: "Again.")]
    let gText1 = fixtureJSONL(session: "8e1f0c2a-0000-4000-8000-0000000009a1", uuidPrefix: "g-1", cwd: "/tmp", turns: yes1, start: gStart)
    let gText2 = fixtureJSONL(session: "8e1f0c2a-0000-4000-8000-0000000009a1", uuidPrefix: "g-1", cwd: "/tmp", turns: yes2, start: gStart)
    try? gText1.write(toFile: gPath, atomically: true, encoding: .utf8)
    hookEvent(c, pA, "SessionStart", session: "8e1f0c2a-0000-4000-8000-0000000009a1", transcript: gPath, ["source": "resume"])
    pA.lastReturnAt = nil  // the Return checks above pressed Return here
    hookEvent(c, pA, "UserPromptSubmit", session: "8e1f0c2a-0000-4000-8000-0000000009a1", ["prompt": "automation, no Enter typed"])
    r.check("no undo toast for prompts not typed here (no Return)", c.pendingUndo == nil && pA.view.overlay.toast == nil)
    await type("\r", window: w)
    hookEvent(c, pA, "UserPromptSubmit", session: "8e1f0c2a-0000-4000-8000-0000000009a1", ["prompt": "yes"])
    let toast = pA.view.overlay.toast
    r.check("typed prompt -> 'Sent to <workspace>' toast with Undo ⌘Z", c.pendingUndo != nil && toast?.button?.title == "Undo"
            && (toast?.text.string ?? "").contains("Sent to") && (toast?.text.string ?? "").contains(wsA.title))
    r.check("…remembering where the transcript ended at Return", c.pendingUndo?.sinceOffset == gText1.utf8.count,
            "\(c.pendingUndo?.sinceOffset ?? -1) vs \(gText1.utf8.count)")
    await sleepMs(700)
    r.check("…its line drains", (toast?.progress ?? 1) < 0.85 && (toast?.progress ?? 0) > 0.5, "\(toast?.progress ?? -1)")
    let escBefore = sinks.bytes(pA.id).filter { $0 == 0x1B }.count
    await cmd("z", window: w)
    r.check("⌘Z interrupts Claude first (Esc right away), before looking for the turn",
            await waitFor(0.3) { sinks.bytes(pA.id).filter { $0 == 0x1B }.count == escBefore + 1 })
    r.check("⌘Z undoes: toast gone, pane busy", c.pendingUndo == nil && pA.view.overlay.toast?.button == nil
            && (pA.busy || c.actionLog.contains { $0.hasPrefix("rewind") }), c.actionLog.suffix(3).joined(separator: "; "))
    // Claude writes the prompt line a moment after the hook: only the older "yes" is there yet.
    await sleepMs(500)
    r.check("…and waits for it instead of taking the older identical turn", !c.actionLog.contains { $0.hasPrefix("rewind") },
            c.actionLog.suffix(2).joined(separator: "; "))
    if let h = FileHandle(forWritingAtPath: gPath) {
        h.seekToEndOfFile()
        h.write(Data(gText2.utf8.dropFirst(gText1.utf8.count)))
        h.closeFile()
    }
    let gBefore = try? Data(contentsOf: URL(fileURLWithPath: gPath))
    // The sink stands in for Claude but never shows its prompt: the rewind gives up, nothing changed.
    _ = await waitFor(30) { !pA.busy }
    r.check("undo picked the new turn (u2), not the older identical one (u1)",
            c.actionLog.contains { $0.hasPrefix("rewind g-1-u2") } && !c.actionLog.contains { $0.hasPrefix("rewind g-1-u1") },
            c.actionLog.suffix(4).joined(separator: "; "))
    r.check("…and only once (the rewind doesn't send a second Esc)", sinks.bytes(pA.id).filter { $0 == 0x1B }.count == escBefore + 1)
    r.check("Claude not back at its prompt -> nothing else sent, transcript untouched, note shown",
            (try? Data(contentsOf: URL(fileURLWithPath: gPath))) == gBefore
            && (pA.view.overlay.toast?.text.string ?? "").contains("Couldn’t rewind; use Esc Esc in Claude Code"),
            "busy=\(pA.busy) toast=\(pA.view.overlay.toast?.text.string ?? "none")")
    await type("\r", window: w)
    hookEvent(c, pA, "UserPromptSubmit", session: "8e1f0c2a-0000-4000-8000-0000000009a1", ["prompt": "something else"])
    r.check("toast up again", c.pendingUndo != nil)
    await sleepMs(Int(LmuxTokens.Motion.undoSendWindow * 1000) + 300)
    r.check("toast disappears after 3s and ⌘Z does nothing", c.pendingUndo == nil && pA.view.overlay.toast == nil
            && !c.undoSend())

    // ---------------------------------------------- hover actions on a Claude-like screen
    r.section = "hover"
    let sPath = fx.appendingPathComponent("screen-1.jsonl").path
    try? fixtureJSONL(session: "screen-1", cwd: "/work/payments", turns: ScreenFixture.turns)
        .write(toFile: sPath, atomically: true, encoding: .utf8)
    let prog = ScreenFixture.script(ScreenFixture.screen, input: "머지 전에 CHANGELOG에도 한 줄 남겨줘", dir: fx, name: "screen1")
    let wsC = c.newWorkspace(program: prog); created.append(wsC)
    wsC.customTitle = "payments refactor"
    let pC = wsC.panes[0]
    _ = await waitFor(5) { rows(pC).contains { $0.contains("accept edits") } }
    hookEvent(c, pC, "SessionStart", session: "screen-1", transcript: sPath, ["source": "startup"])
    _ = await c.loadTurns(pC)
    let map = c.screenMap(pC, maxAge: 0)
    let heads = map.map?.promptHeads() ?? []
    r.check("rendered screen: both prompts located (Hangul, wide cells)", heads.map(\.turn) == [1, 2], "\(heads)")
    r.check("rendered screen: input box located", map.map?.inputRow != nil)
    r.check("input label: workspace accent + title over the input rule",
            await waitFor(2) { !pC.view.overlay.inputLabel.isHidden && pC.view.overlay.inputLabel.text == "payments refactor" })
    if let h1 = heads.first {
        await hover(c, pC, row: h1.row)
        // One pill per TURN (prompt, tool calls, output, reply): hovering any row of it.
        let rowTexts = map.rows.map(\.text)
        let ov0 = pC.view.overlay
        r.check("hover on prompt 1 shows the turn pill for turn 1", c.hoveredTurn(pC) == 1)
        ov0.layoutSubtreeIfNeeded()
        let block1 = map.map!.block(of: 1, rows: rowTexts)!
        let workedRow = map.rows.firstIndex { $0.text.contains("Worked for 12s") }
        r.check("turn 1's block runs from its prompt to its last line (tool calls and output included)",
                block1.first == h1.row && block1.last == workedRow, "\(block1) worked=\(String(describing: workedRow))")
        let bar = ov0.turnBar
        let firstRow = NSRect(x: 0, y: map.rows[block1.first].top, width: 10, height: map.rowHeight)
        r.check("…the pill sits at the turn block's top right: 10pt from the pane's edge, on its first row",
                bar.map { abs($0.frame.maxX - (ov0.bounds.width - 10)) < 0.5 && abs($0.frame.midY - firstRow.midY) < 2 } ?? false,
                "\(bar?.frame ?? .zero) row=\(firstRow) pane \(ov0.bounds.width)")
        r.check("…⧉ ✎ left to right (turn 1 has a reply), no × (the conversation's first turn), tooltips kept",
                bar.map { !$0.copy.isHidden && !$0.edit.isHidden && $0.remove.isHidden && $0.copy.frame.maxX <= $0.edit.frame.minX
                    && $0.frame.width == 2 * TurnActionBar.buttonSize.width + 6 } ?? false
                && bar?.copy.toolTip?.contains("Copy original") == true && bar?.edit.toolTip?.contains("Edit & resend") == true)
        let band = ov0.turnBand
        let bandWant = NSRect(x: 0, y: map.rows[block1.first].top, width: ov0.bounds.width,
                              height: map.rows[block1.last].top + map.rowHeight - map.rows[block1.first].top)
        r.check("a faint band covers the whole turn block (first..last visible row), no border",
                band.map { abs($0.minY - bandWant.minY) < 0.5 && abs($0.height - bandWant.height) < 0.5 && $0.width >= ov0.bounds.width - 1 } ?? false
                && abs(LmuxTokens.Colors.promptRowHover.lightAlpha - 0.04) < 0.011,
                "\(band.map { "\($0)" } ?? "nil") want \(bandWant)")
        // Turn 2: ⧉ ✎ ×.
        await hover(c, pC, row: heads.last!.row)
        ov0.layoutSubtreeIfNeeded()
        r.check("turn 2: ⧉ ✎ × left to right, tooltips kept", c.hoveredTurn(pC) == 2
                && bar.map { !$0.copy.isHidden && !$0.remove.isHidden && $0.copy.frame.maxX <= $0.edit.frame.minX
                    && $0.edit.frame.maxX <= $0.remove.frame.minX && $0.frame.width == 3 * TurnActionBar.buttonSize.width + 8 } ?? false
                && bar?.remove.toolTip?.contains("rewind Claude") == true)
        r.check("…× is the strongest of the three", bar?.remove.prominent == true && bar?.copy.prominent == false && bar?.edit.prominent == false)
        bar?.remove.mouseEntered(with: NSEvent())
        ov0.layoutSubtreeIfNeeded()
        r.check("hovering × doesn't explain it right away (600ms delay)", ov0.tip.isHidden)
        await sleepMs(750)
        ov0.layoutSubtreeIfNeeded()
        r.check("…then “Remove this message and everything after it” below the pill, right-aligned to it",
                ov0.tip.isHidden == false && ov0.tip.text == "Remove this message and everything after it"
                && abs(ov0.tip.frame.maxX - (bar?.frame.maxX ?? 0)) < 0.5 && abs(ov0.tip.frame.minY - (bar?.frame.maxY ?? 0) - 6) < 0.5,
                "\(ov0.tip.frame) bar \(bar?.frame ?? .zero) \(ov0.tip.text)")
        bar?.remove.mouseExited(with: NSEvent())
        r.check("…and hides it again", ov0.tip.isHidden)
        await hover(c, pC, row: h1.row)
        ov0.layoutSubtreeIfNeeded()
        // Moving between rows of the same turn: the same pill, same place, never hidden in between.
        let replyRow = map.map!.roles.firstIndex(of: .reply(turn: 1))!
        let toolRow = map.rows.firstIndex { $0.text.contains("Read(src") }!
        let frame1 = bar?.frame ?? .zero
        var flickered = false
        for row in [toolRow, replyRow, replyRow + 1, workedRow ?? replyRow, h1.row, replyRow] {
            await hover(c, pC, row: row)
            ov0.layoutSubtreeIfNeeded()
            if c.hoveredTurn(pC) != 1 || ov0.turnBar !== bar || ov0.turnBar?.isHidden != false || ov0.turnBar?.frame != frame1 { flickered = true }
        }
        r.check("moving over the turn's tool call, reply and status rows keeps one pill, in place", !flickered
                && ov0.subviews.filter { $0 is TurnActionBar }.count == 1)
        r.check("…hovering a reply row shows it (the per-reply Copy chip is gone)", c.hoveredTurn(pC) == 1)
        // A different turn moves it to that turn's block.
        let reply2Row = map.rows.firstIndex { $0.text.contains("테스트 추가했고") }!
        await hover(c, pC, row: reply2Row)
        ov0.layoutSubtreeIfNeeded()
        let head2 = heads.last!.row
        r.check("hovering turn 2's reply moves the pill to turn 2's first row", c.hoveredTurn(pC) == 2 && ov0.turnBar === bar
                && abs((bar?.frame.midY ?? 0) - (map.rows[head2].top + map.rowHeight / 2)) < 2, "\(bar?.frame ?? .zero)")
        await hover(c, pC, row: map.map!.inputRow!)
        r.check("hover on the input box shows nothing", c.hoveredTurn(pC) == nil && ov0.turnBand == nil)
        await hover(c, pC, row: replyRow)
        pC.surface.onMouseExit?()
        r.check("leaving the pane hides the actions", c.hoveredTurn(pC) == nil && ov0.turnBand == nil)
        _ = await waitFor(1) { bar?.isHidden == true }
        r.check("…faded out, then hidden", bar?.isHidden == true && (bar?.alphaValue ?? 1) < 0.01)

        // Hover is cheap: no transcript parse and at most one viewport read per 0.4s of mouse moves.
        let reads0 = c.transcriptReads[pC.id].map { "\($0)" } ?? "nil"
        await hover(c, pC, row: replyRow)
        let locates0 = pC.hover.locates
        let t0 = Date()
        for i in 0..<60 {
            let row = [h1.row, toolRow, replyRow, reply2Row][i % 4]
            c.paneMouseMoved(pC, NSPoint(x: 120 + CGFloat(i), y: pC.surface.bounds.height - (map.rows[row].top + map.rowHeight / 2)))
        }
        await sleepMs(50)
        let elapsed = Date().timeIntervalSince(t0)
        r.check("60 mouse moves: no transcript parse, ≤ 1 viewport read per 0.4s", (c.transcriptReads[pC.id].map { "\($0)" } ?? "nil") == reads0
                && pC.hover.locates - locates0 <= Int(elapsed / 0.4) + 1, "reads \(reads0) locates +\(pC.hover.locates - locates0) in \(elapsed)s")

        // Copy original from the pill, then ⌥⌘C for the last reply.
        c.pasteboard = NSPasteboard(name: NSPasteboard.Name("lmux-apptest-\(getpid())"))
        c.pasteboard.clearContents()
        await hover(c, pC, row: replyRow)
        pC.view.overlay.turnBar?.copy.performClick()
        r.check("⧉ Copy original copies the transcript markdown, not the screen",
                await waitFor(2) { c.pasteboard.string(forType: .string) == ScreenFixture.reply1 })
        c.pasteboard.clearContents()
        c.focus(pC)
        await cmd("c", option: true, window: w)
        r.check("⌥⌘C copies the last reply's original markdown",
                await waitFor(2) { c.pasteboard.string(forType: .string) == ScreenFixture.reply2 },
                c.pasteboard.string(forType: .string) ?? "nil")

        // Turn 1 is the conversation's first: its pill has no × (✎ stays). Remove on it still asks
        // first, says the later turns go and the files stay.
        let sBefore = try? Data(contentsOf: URL(fileURLWithPath: sPath))
        await hover(c, pC, row: replyRow)
        r.check("the first turn's pill: ✎ but no ×", c.hoveredTurn(pC) == 1
                && pC.view.overlay.turnBar.map { !$0.edit.isHidden && $0.remove.isHidden } ?? false)
        c.requestRewind(pC, turnIndex: 1, edit: false)
        let detail = pC.view.overlay.card?.detail.stringValue ?? ""
        r.check("Remove on turn 1 opens a confirm card", c.cardShown(pC))
        r.check("…for turn 1: removes everything after it; the files it and turn 2 changed stay",
                detail.contains("everything after it") && detail.contains("refund.ts") && detail.contains("refund.test.ts")
                && detail.contains("stay as they are"), detail)
        await type("\u{1b}", window: w)
        r.check("Esc cancels; transcript untouched", !c.cardShown(pC) && (try? Data(contentsOf: URL(fileURLWithPath: sPath))) == sBefore)
        await hover(c, pC, row: reply2Row)
        pC.view.overlay.turnBar?.remove.performClick()
        let detail2 = pC.view.overlay.card?.detail.stringValue ?? ""
        r.check("…× on turn 2's reply is about turn 2 (the last: refund.test.ts only)", c.cardShown(pC) && detail2.contains("refund.test.ts")
                && !detail2.contains("refund.ts,") && !detail2.contains("refund.ts)") && !detail2.contains("everything after it"), detail2)
        pC.view.overlay.card?.cancel.performClick()
        await hover(c, pC, row: toolRow)
        pC.view.overlay.turnBar?.edit.performClick()
        r.check("✎ asks too (Edit)", c.cardShown(pC) && pC.view.overlay.card?.confirm.title == "Edit")
        pC.view.overlay.card?.cancel.performClick()

        // A text-selection drag inside the turn hides the pill (and still selects).
        await hover(c, pC, row: replyRow)
        r.check("pill up before the drag", c.hoveredTurn(pC) == 1)
        let sy = map.rows[replyRow].top + map.rowHeight / 2
        await click(pC.surface, at: NSPoint(x: 40, y: pC.surface.bounds.height - sy),
                    dragTo: NSPoint(x: 260, y: pC.surface.bounds.height - sy))
        r.check("a selection drag hides the pill", c.hoveredTurn(pC) == nil && ov0.turnBand == nil)
        r.check("…and the drag selected text", pC.surface.hasSelection, "")
        await hover(c, pC, row: replyRow)
        r.check("…the next move shows it again", c.hoveredTurn(pC) == 1)

        // The turn Claude is still writing: no pill (Undo send covers a prompt just sent); others keep theirs.
        hookEvent(c, pC, "UserPromptSubmit", session: "screen-1", ["prompt": ScreenFixture.prompt2])
        _ = await waitFor(2) { if case .running = pC.display { return true }; return false }
        await hover(c, pC, row: reply2Row)
        r.check("while Claude works, its current turn shows no pill", c.hoveredTurn(pC) == nil)
        await hover(c, pC, row: replyRow)
        r.check("…earlier turns still do", c.hoveredTurn(pC) == 1)
        hookEvent(c, pC, "Stop", session: "screen-1", ["last_assistant_message": "done"])
        _ = await waitFor(2) { if case .running = pC.display { return false }; return true }
        await hover(c, pC, row: reply2Row)
        r.check("…and it gets one again once Claude stops", c.hoveredTurn(pC) == 2)
        c.hideHoverActions(pC)

        // Esc right after sending (with an image): Claude Code 2.1.280 writes its interrupt marker and
        // sends no Stop hook, so the pane stays "running". The turn is over all the same: × must show.
        // Shapes from real captures (Core Fixtures/interrupted-*.jsonl); the image block comes first here.
        do {
            let iPath = fx.appendingPathComponent("int-1.jsonl").path
            let common = #""isSidechain":false,"userType":"external","cwd":"/tmp","sessionId":"int-1","version":"2.1.280""#
            let head = """
            {"parentUuid":null,\(common),"type":"user","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}},{"type":"text","text":"[Image #1] 이 화면에서 뭐가 잘못됐어?"}]},"imagePasteIds":[1],"uuid":"int-u1","timestamp":"2026-11-02T10:00:00.000Z","promptSource":"typed"}
            {"parentUuid":"int-u1",\(common),"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Image: source: /tmp/shot.png]"}]},"isMeta":true,"uuid":"int-m1","timestamp":"2026-11-02T10:00:00.010Z"}
            {"parentUuid":"int-m1",\(common),"type":"assistant","message":{"id":"msg_i1","role":"assistant","content":[{"type":"text","text":"화면을 보면"}]},"uuid":"int-a1","timestamp":"2026-11-02T10:00:01.000Z"}

            """
            let marker = """
            {"parentUuid":"int-a1",\(common),"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"int-x1","timestamp":"2026-11-02T10:00:02.000Z"}

            """
            try? head.write(toFile: iPath, atomically: true, encoding: .utf8)
            let iScreen = """
            ❯ [Image #1] 이 화면에서 뭐가 잘못됐어?
              ⎿  [Image #1]

            ⏺ 화면을 보면
              ⎿  Interrupted · What should Claude do instead?

            """
            let wsI = c.newWorkspace(program: ScreenFixture.script(iScreen, input: "", dir: fx, name: "int1")); created.append(wsI)
            let pI = wsI.panes[0]
            _ = await waitFor(5) { rows(pI).contains { $0.contains("Interrupted ·") } }
            hookEvent(c, pI, "SessionStart", session: "int-1", transcript: iPath, ["source": "startup"])
            hookEvent(c, pI, "UserPromptSubmit", session: "int-1", ["prompt": "[Image #1] 이 화면에서 뭐가 잘못됐어?"])
            _ = await c.loadTurns(pI)
            let iMap = c.screenMap(pI, maxAge: 0)
            let iHead = iMap.map?.promptHeads().first
            r.check("image-first prompt located on screen ([image] placeholder skipped)", iHead?.turn == 1, "\(iMap.map?.promptHeads() ?? [])")
            let intRow = iMap.rows.firstIndex { $0.text.contains("Interrupted ·") } ?? 0
            await hover(c, pI, row: intRow)
            r.check("while Claude streams the reply, the turn shows no pill", c.hoveredTurn(pI) == nil)
            if let h = FileHandle(forWritingAtPath: iPath) { h.seekToEndOfFile(); h.write(Data(marker.utf8)); h.closeFile() }
            var shown = false
            for _ in 0..<20 where !shown {
                await hover(c, pI, row: iHead?.row ?? 0)
                shown = c.hoveredTurn(pI) == 1
                if !shown { await sleepMs(100) }
            }
            r.check("Esc-interrupted turn (no Stop hook, pane still running) gets its pill",
                    shown && pI.agent.state == .running, "turn=\(c.hoveredTurn(pI).map(String.init) ?? "nil") \(pI.agent.state)")
            await hover(c, pI, row: intRow)
            r.check("…also over its \"Interrupted\" line", c.hoveredTurn(pI) == 1)
            c.requestRewind(pI, turnIndex: 1, edit: false)
            let iDetail = pI.view.overlay.card?.detail.stringValue ?? ""
            r.check("…and Remove doesn't claim Claude is still working", !iDetail.isEmpty && !iDetail.contains("will be stopped"), iDetail)
            c.dismissCard(pI)
            c.hideHoverActions(pI)
            c.select(wsC)
            await sleepMs(200)
        }
        let ov = pC.view.overlay
        // Like the mockup: right above Claude's input box, the "● workspace" label between them.
        c.refreshInputLabel(pC)
        c.showCard(pC, message: LmuxController.bold("Close this pane? ", "claude", " is still running."), detail: "",
                   confirmTitle: "Close", onConfirm: {})
        ov.layoutSubtreeIfNeeded()
        let card = ov.card?.frame ?? .zero
        let ruleTop = ov.inputRuleRow?.top ?? 0
        r.check("a confirm card sits right above the input box (like the mockup)",
                !card.isEmpty && card.maxY <= ruleTop + 1 && card.maxY >= ruleTop - 16, "\(card) rule=\(ruleTop)")
        ov.card?.cancel.performClick()
        c.showUndoToast(pC, prompt: "x")
        ov.layoutSubtreeIfNeeded()
        let toastF = ov.toast?.frame ?? .zero
        let ringEdge = LmuxTokens.Layout.ringInset + LmuxTokens.Layout.ringWidth
        r.check("Undo toast is inset well inside the ring", ov.bounds.maxX - toastF.maxX >= ringEdge + 12
                && ov.bounds.maxY - toastF.maxY >= ringEdge + 12, "\(toastF) in \(ov.bounds)")
        c.clearPendingUndo()
        c.hideToast(pC)
    }
    // Compacted turns are refused inline.
    let kPath = fx.appendingPathComponent("compacted.jsonl").path
    try? fixtureJSONL(session: "screen-1", cwd: "/tmp", turns: [FixtureTurn(prompt: "old topic before compaction", reply: "old"),
                                                                 FixtureTurn(prompt: "new topic", reply: "new")], compactAfter: 1)
        .write(toFile: kPath, atomically: true, encoding: .utf8)
    pC.transcriptPath = kPath
    let kTurns = await c.loadTurns(pC)
    c.requestRewind(pC, turnIndex: 1, edit: false)
    r.check("rewind to a compacted turn: refused inline, no card",
            kTurns.first?.beforeCompaction == true && !c.cardShown(pC)
            && (pC.view.overlay.toast?.text.string ?? "").contains("compacted"))
    pC.transcriptPath = sPath

    // The label follows Claude's input box while it works: Claude redraws (spinner line,
    // streamed reply) without a hook event per redraw, so the box moves under a still label.
    let movingTxt = fx.appendingPathComponent("moving.sh")
    try? """
    #!/bin/sh
    stty -echo -icanon
    COLS=$(stty size | cut -d' ' -f2); [ -z "$COLS" ] && COLS=100
    RULE=$(printf '%*s' "$COLS" '' | sed 's/ /─/g')
    draw() {
      printf '\\033[2J\\033[H❯ build it\\n\\n'
      [ -n "$1" ] && printf '⏺ Read(build.sh)\\n  ⎿  Read 12 lines\\n\\n✻ Working… (esc to interrupt)\\n\\n'
      printf '%s\\n❯ \\n%s\\n' "$RULE" "$RULE"
    }
    draw; sleep 1.5; draw more; exec sleep 100000

    """.write(to: movingTxt, atomically: true, encoding: .utf8)
    chmod(movingTxt.path, 0o755)
    let wsM = c.newWorkspace(program: movingTxt.path); created.append(wsM)
    let pM = wsM.panes[0]
    hookEvent(c, pM, "SessionStart", session: "lf-1", ["source": "startup"])
    hookEvent(c, pM, "UserPromptSubmit", session: "lf-1", ["prompt": "build it"])
    func ruleTop(_ p: Pane) -> CGFloat? {
        let m = c.screenMap(p, maxAge: 0)
        return m.map?.inputRule.map { m.rows[$0].top }
    }
    let firstRule = await waitFor(3) { ruleTop(pM) != nil && pM.view.overlay.inputRuleRow?.top == ruleTop(pM) } ? ruleTop(pM) : nil
    let moved = await waitFor(4) { (ruleTop(pM) ?? 0) > (firstRule ?? .infinity) }
    let followed = await waitFor(1.5) { !pM.view.overlay.inputLabel.isHidden && pM.view.overlay.inputRuleRow?.top == ruleTop(pM) }
    r.check("while Claude works, the label follows its input box down (no hook event, no key press)",
            firstRule != nil && moved && followed,
            "first=\(firstRule.map { "\($0)" } ?? "nil") now=\(ruleTop(pM).map { "\($0)" } ?? "nil") label=\(pM.view.overlay.inputRuleRow.map { "\($0.top)" } ?? "nil")")
    hookEvent(c, pM, "Stop", session: "lf-1")
    await sleepMs(900)
    r.check("…and stops re-reading the screen once Claude is idle (no polling)", c.overlayWork[pM.id] == nil)

    // ------------------------------------------------------------ chrome text
    r.section = "chrome"
    let wsH = c.newWorkspace(cwd: "/tmp"); created.append(wsH)
    let h1 = wsH.panes[0]
    let h2 = c.split(h1, .right)!
    // Both panes' programs started (under load the split's child can still be lmux-apptest, not yet
    // exec'd) and running the same thing: the headers below then differ only by what's checked.
    _ = await sinks.waitReady(h1.id)
    _ = await sinks.waitReady(h2.id)
    _ = await waitFor(3) {
        h1.foregroundCache = nil; h2.foregroundCache = nil
        return ClaudeProcess.foregroundName(h1) == ClaudeProcess.foregroundName(h2)
    }
    h1.title = ".../workspace/lmux/App"; h2.title = ".../workspace/lmux/App"
    c.refreshHeaders(wsH)
    // The shared name is the folder (tmp) or, as it's the workspace's own title, what runs there (cat).
    let hHeads = [h1, h2].map { $0.view.header.label.stringValue.components(separatedBy: " · ").first ?? "" }
    r.check("split panes with the same title get told apart", h1.view.header.label.stringValue != h2.view.header.label.stringValue
            && hHeads[0] == hHeads[1] && h1.view.header.label.stringValue.hasPrefix(hHeads[0] + " · "),
            h1.view.header.label.stringValue + " | " + h2.view.header.label.stringValue)
    h1.cwd = "/work/a/App"; h2.cwd = "/work/b/App"
    c.refreshHeaders(wsH)
    r.check("…by the path component where their cwds differ", h1.view.header.label.stringValue.hasSuffix(" · a")
            && h2.view.header.label.stringValue.hasSuffix(" · b"),
            h1.view.header.label.stringValue + " | " + h2.view.header.label.stringValue)
    let tabTitles = [h1, h2].map { wsH.root.find($0)?.strip.items.first?.title ?? "-" }
    r.check("…and their tabs say the same", tabTitles == [h1, h2].map { $0.view.header.label.stringValue }, tabTitles.joined(separator: " | "))
    // Elapsed time on Done / Failed rows, like the mockup ("4m", "12m"), ticking at most once a minute.
    let wsAge = c.newWorkspace(select: false); created.append(wsAge)
    let pAge = wsAge.panes[0]
    hookEvent(c, pAge, "UserPromptSubmit", session: "age-1", ["prompt": "x"])
    r.check("no elapsed time while running", wsAge.elapsed(now: Date()) == nil)
    hookEvent(c, pAge, "Stop", session: "age-1")
    pAge.lastAlertAt = Date().addingTimeInterval(-4 * 60 - 5)
    r.check("Done row shows how long ago (4m)", wsAge.elapsed(now: Date()) == "4m", wsAge.elapsed(now: Date()) ?? "nil")
    hookEvent(c, pAge, "UserPromptSubmit", session: "age-1", ["prompt": "x"])
    hookEvent(c, pAge, "StopFailure", session: "age-1", ["error_type": "x"])
    pAge.lastAlertAt = Date().addingTimeInterval(-12 * 60 - 5)
    r.check("Failed row too (12m)", wsAge.elapsed(now: Date()) == "12m")
    c.refreshPaneChrome()
    r.check("a minute tick is scheduled while a visible sidebar shows elapsed times", c.ageTickScheduled)
    c.toggleSidebar()
    r.check("…none while the sidebar is hidden", !c.ageTickScheduled)
    c.toggleSidebar()
    r.check("…back when it's shown", c.ageTickScheduled)
    hookEvent(c, pAge, "SessionEnd", session: "age-1")
    for w in c.model.workspaces { for p in w.panes where p.display != .idle { p.agent = PaneAgent(); p.failed = false } }
    c.refreshPaneChrome()
    r.check("…and none when no row shows one (idle)", !c.ageTickScheduled)

    h1.cwd = NSHomeDirectory(); h1.branch = nil; h1.title = ""
    wsH.focusedPane = h1
    wsH.customTitle = nil; h1.titleState = TitleState()
    r.check("header meta leaves out ~ (the title says Home)", wsH.title == "Home" && wsH.headerMeta.path == nil && wsH.headerMeta.branch == nil,
            "\(wsH.title) \(wsH.headerMeta)")
    h1.cwd = "/tmp/proj"
    r.check("…and the path the title came from, without a branch", wsH.title == "proj" && wsH.headerMeta.path == nil,
            "\(wsH.headerMeta)")
    h1.branch = "main"
    r.check("…shown with a branch: ⎇ main · /tmp/proj", wsH.headerMeta.branch == "main" && wsH.headerMeta.path == "/tmp/proj",
            "\(wsH.headerMeta)")
    // Titles and row lines as a person reads them (real-Mac report: ".../Desktop/workspace/lmux",
    // "Idle" on every row, "readme-bench-lic…p/workspace/lmux"). POLISH.md 4.
    r.section = "titles"
    h1.cwd = "/Users/x/Desktop/workspace/lmux"; h1.title = ".../Desktop/workspace/lmux"; h1.branch = "readme-bench-license"
    r.check("a shell titled with its cwd shows the folder name", wsH.title == "lmux" && h1.headerTitle == "lmux", wsH.title)
    h1.title = "user@host:~/Desktop/workspace/lmux"
    r.check("…also zsh's user@host:path title", wsH.title == "lmux", wsH.title)
    h1.title = "~"
    r.check("…and ~ while in another folder: the folder, never \"~\"", wsH.title == "lmux", wsH.title)
    let cwdSaved = h1.cwd
    h1.cwd = NSHomeDirectory(); h1.title = "~"
    r.check("the home dir is titled Home", wsH.title == "Home", wsH.title)
    h1.cwd = "/"; h1.title = "/"
    r.check("…and / is /", wsH.title == "/", wsH.title)
    h1.cwd = cwdSaved; h1.title = ".../Desktop/workspace/lmux"
    h1.title = "vim notes.md"
    r.check("a running command's title is kept", wsH.title == "vim notes.md")
    h1.title = Pane.cleanTitle("✻ Remember APPLE word - Session start")
    r.check("leaked hook text is cut from a title (\" - Session start\")", wsH.title == "Remember APPLE word", wsH.title)
    h1.title = String(repeating: "x", count: 80)
    r.check("titles are capped at 48 characters", wsH.title.count == 48, "\(wsH.title.count)")
    h1.title = "/Users/x/Desktop/workspace/lmux"
    let wsDup = c.newWorkspace(cwd: "/tmp", select: false); created.append(wsDup)
    wsDup.panes[0].cwd = "/Users/y/other/lmux"; wsDup.panes[0].title = "…/other/lmux"
    r.check("workspaces in the same folder name keep their title (lmux, lmux)", wsH.title == "lmux" && wsDup.title == "lmux",
            "\(wsH.title) / \(wsDup.title)")
    r.check("…and line 2 tells them apart (branch / differing folder)",
            wsH.rowDetail(now: Date())?.text == "readme-bench-license" && wsH.rowDetail(now: Date())?.isBranch == true
                && wsDup.rowDetail(now: Date())?.text == "other",
            "\(String(describing: wsH.rowDetail(now: Date()))) / \(String(describing: wsDup.rowDetail(now: Date())))")
    wsDup.panes[0].cwd = h1.cwd; wsDup.panes[0].branch = "readme-bench-license"
    r.check("…same branch: \"main\", \"main · 2\"", wsDup.rowDetail(now: Date())?.text == "readme-bench-license · 2",
            wsDup.rowDetail(now: Date())?.text ?? "nil")
    wsDup.customTitle = "mine"
    r.check("…only while they collide: a renamed one has no line 2", wsH.title == "lmux" && wsDup.title == "mine"
            && wsH.rowDetail(now: Date()) == nil && wsDup.rowDetail(now: Date()) == nil)
    h1.cwd = NSHomeDirectory() + "/Desktop/workspace/lmux"
    r.check("header meta: branch and ~/path", wsH.headerMeta.branch == "readme-bench-license"
            && wsH.headerMeta.path == "~/Desktop/workspace/lmux", "\(wsH.headerMeta)")
    r.check("a plain shell row is one line (no \"Idle\")", !wsH.showsStateLine && AgentDisplay.idle.label.isEmpty)
    h1.claudeSessionID = "s"
    h1.title = "✳ Claude Code"
    h1.title = Pane.cleanTitle(h1.title)
    r.check("…nor a Claude pane that hasn't done anything yet", !wsH.showsStateLine)
    r.check("a generic \"Claude Code\" title falls back to the folder", wsH.title == "lmux", wsH.title)
    hookEvent(c, h1, "UserPromptSubmit", session: "s", ["prompt": "x"])
    r.check("…line 2 shows once the agent works (\"Working…\" without a tool)", wsH.rowDetail(now: Date())?.text == "Working…",
            wsH.rowDetail(now: Date())?.text ?? "nil")
    hookEvent(c, h1, "PreToolUse", session: "s", ["tool_name": "Bash", "tool_input": ["command": "swift test --filter IME"]])
    r.check("…\"Bash · swift test --filter IME\" while a tool runs", wsH.rowDetail(now: Date())?.text == "Bash · swift test --filter IME",
            wsH.rowDetail(now: Date())?.text ?? "nil")
    hookEvent(c, h1, "Notification", session: "s", ["message": "Allow pnpm db:migrate?", "notification_type": "permission_prompt"])
    r.check("needs input: the question, in the loud color, with the dot", wsH.rowState == .needsInput("Allow pnpm db:migrate?")
            && wsH.rowDetail(now: Date()) == .init(text: "Allow pnpm db:migrate?", tone: .needsInput), "\(wsH.rowState)")
    hookEvent(c, h1, "SessionEnd", session: "s")
    h1.agent = PaneAgent(); h1.claudeSessionID = nil; h1.title = "/Users/x/Desktop/workspace/lmux"
    wsH.notification = "built"
    r.check("…a row with a notification has line 2", wsH.rowDetail(now: Date())?.text == "built" && wsH.rowState == .idle)
    wsH.notification = "Claude needs your permission to use Bash"
    r.check("…Claude's own OSC notification asking permission gets the needs-input glyph (as from the hook)",
            wsH.rowState == .needsInput("Claude needs your permission to use Bash") && wsH.rowDetail(now: Date())?.tone == .needsInput)
    wsH.notification = "Claude is waiting for your input"
    r.check("…and \"waiting for your input\" (its idle prompt) the done glyph, like the idle_prompt hook",
            wsH.rowState == .done("Claude is waiting for your input") && wsH.rowDetail(now: Date())?.tone == .secondary)
    wsH.notification = nil

    // Terminal color queries (programs pick light / dark palettes from them: Claude Code's
    // `theme: auto`, vim's background, …): answered with the theme's real colors.
    r.section = "color queries"
    let probe = paths.stateDir.appendingPathComponent("oscprobe.sh")
    try? """
    #!/bin/sh
    stty raw -echo
    /bin/cat < /dev/tty > "$LMUX_SINK_DIR/$LMUX_PANE_ID.bin" &
    touch "$LMUX_SINK_DIR/$LMUX_PANE_ID.ready"; sleep 0.3
    printf '\\033]11;?\\033\\\\\\033]10;?\\033\\\\\\033]4;0;?\\033\\\\\\033[?996n\\033[c' > /dev/tty
    wait
    """.write(to: probe, atomically: true, encoding: .utf8)
    chmod(probe.path, 0o755)
    let appearance0 = NSApp.appearance
    for (name, dark) in [("light", false), ("dark", true)] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let wsQ = c.newWorkspace(cwd: "/tmp", select: false, program: probe.path); created.append(wsQ)
        let q = wsQ.panes[0]
        let got = await sinks.wait(q.id, contains: "\u{1b}[?62;", timeout: 5)
        let reply = String(decoding: sinks.bytes(q.id), as: UTF8.self)
        let bg = dark ? "rgb:2e2e/3434/4040" : "rgb:e5e5/e9e9/f0f0"  // Nord / Nord Light
        r.check("\(name): OSC 11 answers the theme background, OSC 10 / OSC 4 / ?996 answered before DA1",
                got && reply.contains("\u{1b}]11;\(bg)") && reply.contains("\u{1b}]10;rgb:") && reply.contains("\u{1b}]4;0;rgb:")
                    && reply.contains("\u{1b}[?997;\(dark ? 1 : 2)n"),
                reply.replacingOccurrences(of: "\u{1b}", with: "ESC"))
    }
    NSApp.appearance = appearance0

    // Claude leaves the pane: the row, header and label go back to the shell's.
    r.section = "claude exit"
    let wsX = c.newWorkspace(cwd: "/tmp", select: false); created.append(wsX)
    let pX = wsX.panes[0]
    pX.cwd = "/tmp/xproj"
    hookEvent(c, pX, "SessionStart", session: "x-1")
    hookEvent(c, pX, "UserPromptSubmit", session: "x-1", ["prompt": "remember apple"])
    hookEvent(c, pX, "Notification", session: "x-1", ["message": "Claude is waiting for your input", "notification_type": "idle_prompt"])
    pX.titleState.title = "Remember APPLE word"
    r.check("(setup) a Claude pane with an auto title and a state", wsX.title == "Remember APPLE word" && wsX.showsStateLine)
    hookEvent(c, pX, "SessionEnd", session: "x-1")
    r.check("SessionEnd: no state line, title back to the folder", !wsX.showsStateLine && wsX.title == "xproj"
            && pX.headerTitle == "xproj" && !pX.runsClaude, "\(wsX.title) \(wsX.display)")
    hookEvent(c, pX, "SessionStart", session: "x-2")
    hookEvent(c, pX, "UserPromptSubmit", session: "x-2", ["prompt": "hi"])
    pX.titleState.title = "Greeting"
    // Claude killed without SessionEnd: its pid is gone, the shell prints its prompt (title).
    let dead = Process()
    dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? dead.run(); dead.waitUntilExit()
    pX.claudePID = dead.processIdentifier
    pX.surface.onTitleChange?("…/tmp/xproj")
    r.check("Claude gone without SessionEnd (Ctrl-C twice): reset on the next shell title", !pX.runsClaude && !wsX.showsStateLine
            && wsX.title == "xproj", "\(wsX.title) runsClaude=\(pX.runsClaude)")
    pX.titleState = TitleState(); pX.titleState.title = "Mine"; pX.titleState.isManual = true
    hookEvent(c, pX, "SessionStart", session: "x-3")
    hookEvent(c, pX, "SessionEnd", session: "x-3")
    r.check("…a title the user set stays", wsX.title == "Mine")

    r.section = "ghostty actions"
    c.openConfigFile()
    r.check("Open config file resolves lmux's config (LMUX_CONFIG_FILE in tests)", c.lastOpenedConfig == LmuxConfig.configFile,
            c.lastOpenedConfig?.path ?? "nil")
    let menuTitles = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items.map(\.title) ?? [] }
    for t in ["Settings…", "Hide lmux", "Hide Others", "Quit lmux", "Copy", "Paste", "Select All", "Find…", "Increase Font Size",
              "Decrease Font Size", "Reset Font Size", "Clear Screen", "Enter Full Screen", "Minimize", "Zoom", "Bring All to Front"] {
        r.check("menu has \(t)", menuTitles.contains(t))
    }

    r.section = "paths"
    let longDir = "/tmp/" + String(repeating: "deep-state-dir/", count: 8)
    let lp = LmuxPaths(environment: ["LMUX_STATE_DIR": longDir])
    r.check("a long state dir gets short sockets (no silent pathTooLong)",
            lp.controlSocket.utf8.count < 104 && lp.hookSocket.utf8.count < 104 && lp.controlSocket.hasPrefix("/tmp/lmux-\(getuid())/"),
            lp.controlSocket)
    var st = stat()
    r.check("…in a 0700 dir we own", stat(lp.socketDir.path, &st) == 0 && st.st_uid == getuid() && st.st_mode & 0o777 == 0o700)
    r.check("…the same one every launch", LmuxPaths(environment: ["LMUX_STATE_DIR": longDir]).controlSocket == lp.controlSocket)
    r.check("a short state dir keeps its sockets", paths.controlSocket.hasPrefix(paths.stateDir.path))
    try? FileManager.default.removeItem(at: lp.socketDir)
    rmdir(lp.socketDir.deletingLastPathComponent().path)  // only if empty (another lmux may use it)

    r.section = "titlebar double-click"
    typealias TD = TitlebarDragView
    r.check("double-click default is zoom", TD.titlebarDoubleClickAction(setting: nil, legacyMinimize: nil) == "Maximize")
    r.check("…follows AppleActionOnDoubleClick", TD.titlebarDoubleClickAction(setting: "Minimize", legacyMinimize: false) == "Minimize"
            && TD.titlebarDoubleClickAction(setting: "None", legacyMinimize: nil) == "None")
    r.check("…and the old AppleMiniaturizeOnDoubleClick", TD.titlebarDoubleClickAction(setting: nil, legacyMinimize: true) == "Minimize")
    r.section = "chrome"

    // WCAG AA (4.5:1) in light mode on a selected History row: Resume and the search highlight.
    func lum(_ c: UInt32) -> Double {
        func ch(_ v: UInt32) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c >> 16 & 0xFF) + 0.7152 * ch(c >> 8 & 0xFF) + 0.0722 * ch(c & 0xFF)
    }
    func blend(_ a: UInt32, over b: UInt32, _ t: Double) -> UInt32 {
        func m(_ s: UInt32) -> UInt32 { UInt32((Double(a >> s & 0xFF) * t + Double(b >> s & 0xFF) * (1 - t)).rounded()) }
        return m(16) << 16 | m(8) << 8 | m(0)
    }
    func ratio(_ a: UInt32, _ b: UInt32) -> Double { let (x, y) = (lum(a), lum(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
    typealias C = LmuxTokens.Colors
    // Polish: selection is a neutral pill (nord0 7.5% light / nord6 8.5% dark) over the sidebar; text keeps its color.
    for (name, dark) in [("light", false), ("dark", true)] {
        func v(_ d: LmuxTokens.DynamicColor) -> UInt32 { dark ? d.dark : d.light }
        let sidebar = v(C.sidebarBackground)
        let pill = blend(v(C.rowSelected), over: sidebar, Double(dark ? C.rowSelected.darkAlpha : C.rowSelected.lightAlpha))
        r.check("\(name): tertiary text on the selected pill is AA", ratio(v(C.textTertiary), pill) >= 4.5,
                String(format: "%.1f:1", ratio(v(C.textTertiary), pill)))
        r.check("\(name): needs-input text on the selected pill is AA", ratio(v(C.stateNeedsInput), pill) >= 4.5,
                String(format: "%.1f:1", ratio(v(C.stateNeedsInput), pill)))
        r.check("\(name): primary text on the selected pill is >= 9:1", ratio(v(C.textPrimary), pill) >= 9,
                String(format: "%.1f:1", ratio(v(C.textPrimary), pill)))
        let hl = blend(v(C.accent), over: pill, 0.24)
        r.check("\(name): search highlight on the selected History row is AA", ratio(v(C.textPrimary), hl) >= 4.5,
                String(format: "%.1f:1", ratio(v(C.textPrimary), hl)))
        r.check("\(name): input legend text on the terminal background is AA", ratio(v(C.textTertiary), v(C.windowBackground)) >= 4.5,
                String(format: "%.1f:1", ratio(v(C.textTertiary), v(C.windowBackground))))
    }

    created += await rewindChecks(r, c, w, fx: fx)


    // ------------------------------------------------------------ titles
    r.section = "titles"
    let wsT = c.newWorkspace(); created.append(wsT)
    let pT = wsT.panes[0]
    let tPath = fx.appendingPathComponent("t-1.jsonl").path
    try? fixtureJSONL(session: "t-1", cwd: "/tmp", turns: [
        FixtureTurn(prompt: "부분환불할 때 금액 검증이 빠져 있어. refund.ts 보고 고쳐줘", reply: "고쳤어요."),
        FixtureTurn(prompt: "also add a test for the 0-won case, then run it", reply: "통과해요."),
    ]).write(toFile: tPath, atomically: true, encoding: .utf8)
    func appendMeta(_ path: String, _ line: String) {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); h.closeFile() }
    }
    let refreshes = c.history.refreshCount
    hookEvent(c, pT, "SessionStart", session: "t-1", transcript: tPath, ["source": "startup"])
    await sleepMs(400)  // SessionStart's own read: no title yet
    // Claude Code writes its own title into the transcript (`ai-title`); lmux never asks a model.
    appendMeta(tPath, #"{"type":"ai-title","aiTitle":"Fix refund validation","sessionId":"t-1"}"#)
    hookEvent(c, pT, "Stop", session: "t-1", transcript: tPath)
    await sleepMs(300)
    r.check("Claude's title is read after the Stop debounce, not before", pT.titleState.title == nil, "\(pT.titleState)")
    r.check("after Stop: the session title is Claude's ai-title (off-main, debounced)",
            await waitFor(5) { pT.titleState.title == "Fix refund validation" }, "\(pT.titleState)")
    r.check("workspace and sidebar follow the pane's title", wsT.title == "Fix refund validation")
    r.check("History never opened yet: a Stop doesn't index it (the first index waits for History)",
            !c.history.started && c.history.refreshCount == refreshes)
    c.history.start()  // what focusing the History field does
    _ = await waitFor(5) { c.history.refreshCount > refreshes }
    let indexed = c.history.refreshCount
    appendMeta(tPath, #"{"type":"ai-title","aiTitle":"Refund validation and tests","sessionId":"t-1"}"#)
    hookEvent(c, pT, "Stop", session: "t-1", transcript: tPath)
    r.check("Claude writes a new title: the pane follows it",
            await waitFor(5) { pT.titleState.title == "Refund validation and tests" }, "\(pT.titleState)")
    r.check("…and once History is in use, Stop refreshes it (debounced)", await waitFor(4) { c.history.refreshCount > indexed })
    c.saveNow()
    let layoutText = (try? String(contentsOf: paths.layoutFile, encoding: .utf8)) ?? ""
    r.check("title state persisted with the layout", layoutText.contains("Refund validation and tests"))
    let legacy = #"{"title":"Old topic","isManual":true,"history":[],"lastEvaluatedTurn":3,"cooldown":1}"#
    let decoded = try? JSONDecoder().decode(TitleState.self, from: Data(legacy.utf8))
    r.check("a title saved by an older lmux (model engine keys) still loads", decoded?.title == "Old topic" && decoded?.isManual == true)
    c.renamePane(pT, to: "내가 정한 이름")
    appendMeta(tPath, #"{"type":"ai-title","aiTitle":"Something else","sessionId":"t-1"}"#)
    hookEvent(c, pT, "Stop", session: "t-1", transcript: tPath)
    await sleepMs(Int(LmuxController.titleDebounce * 1000) + 600)
    r.check("manual rename locks it: Claude's new title doesn't replace it", pT.titleState.title == "내가 정한 이름"
            && pT.titleState.isManual)
    c.renamePane(pT, to: "")
    r.check("clearing the name goes back to Claude's title",
            await waitFor(3) { pT.titleState.title == "Something else" && !pT.titleState.isManual }, "\(pT.titleState)")
    appendMeta(tPath, #"{"type":"custom-title","customTitle":"내 세션","sessionId":"t-1"}"#)
    hookEvent(c, pT, "Stop", session: "t-1", transcript: tPath)
    r.check("Claude Code /rename (custom-title) locks the title",
            await waitFor(5) { pT.titleState.title == "내 세션" && pT.titleState.isManual }, "\(pT.titleState)")
    c.renameWorkspace(wsT, to: "WS name")
    r.check("workspace rename wins over pane titles", wsT.title == "WS name")
    c.renameWorkspace(wsT, to: "")
    r.check("clearing it follows the pane again", wsT.title == "내 세션")
    let wsS = c.newWorkspace(); created.append(wsS)
    let pS = wsS.panes[0]
    let aPath = fx.appendingPathComponent("a-1.jsonl").path
    try? fixtureJSONL(session: "a-1", cwd: "/tmp", turns: [FixtureTurn(prompt: "웹훅 재시도 로직 정리해줘", reply: "네")],
                      aiTitle: "웹훅 재시도 정리").write(toFile: aPath, atomically: true, encoding: .utf8)
    hookEvent(c, pS, "SessionStart", session: "a-1", transcript: aPath, ["source": "resume"])
    r.check("a resumed session shows Claude's title right away",
            await waitFor(3) { pS.titleState.title == "웹훅 재시도 정리" } && wsS.title == "웹훅 재시도 정리")
    hookEvent(c, pS, "SessionStart", session: "a-2", ["source": "startup"])
    r.check("a new session in the pane starts a new title", pS.titleState.title == nil && pS.titleSession == "a-2")

    // ------------------------------------------------------------ History
    r.section = "history"
    await historyChecks(r, c, fx: fx)

    for ws in created where c.model.workspaces.contains(where: { $0 === ws }) {
        for p in ws.panes where p.runsClaude { hookEvent(c, p, "SessionEnd", session: p.claudeSessionID!) }
        c.closeWorkspace(ws)
    }
    for ws in c.model.workspaces where !existing.contains(ws.id) {
        for p in ws.panes where p.runsClaude { hookEvent(c, p, "SessionEnd", session: p.claudeSessionID!) }
        c.closeWorkspace(ws)
    }
}

/// Four past sessions (three about 환불) under the temp projects root.
@discardableResult
func writeHistoryCorpus(root: URL, cwd: String) -> [String: URL] {
    let dir = root.appendingPathComponent(SessionIndex.projectDirectoryName(forCwd: cwd), isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let day: TimeInterval = 86400
    let sessions: [(String, String?, [FixtureTurn], TimeInterval)] = [
        ("8e1f0c2a-0000-4000-8000-000000000001", "웹훅 재시도 정리",
         [FixtureTurn(prompt: "웹훅 재시도 로직 정리해줘. 중복 환불 이벤트가 두 번 들어오면 멱등키로 막아야 해", reply: "멱등키 테이블을 추가했어요.")], 0.02),
        ("8e1f0c2a-0000-4000-8000-000000000002", "refund CSV export",
         [FixtureTurn(prompt: "부분환불 내역을 CSV로 내보내는 스크립트 만들어줘", reply: "scripts/export_refunds.ts를 만들었어요.")], 5),
        ("8e1f0c2a-0000-4000-8000-000000000003", "PG 정산 대사",
         [FixtureTurn(prompt: "PG 정산 대사 결과 좀 봐줘", reply: "환불 수수료가 3건 안 맞아요. settle.ts의 반올림 때문이에요.")], 14),
        ("8e1f0c2a-0000-4000-8000-000000000004", "README 다듬기",
         [FixtureTurn(prompt: "README 문장 다듬어줘", reply: "톤을 맞췄어요.")], 30),
    ]
    var out: [String: URL] = [:]
    for (id, title, turns, ago) in sessions {
        let url = dir.appendingPathComponent("\(id).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? fixtureJSONL(session: id, cwd: cwd, turns: turns, start: Date().addingTimeInterval(-ago * day), aiTitle: title)
                .write(to: url, atomically: true, encoding: .utf8)
            // Last written when the session ended (what Claude's cleanup looks at).
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago * day + 60)],
                                                   ofItemAtPath: url.path)
        }
        out[id] = url
    }
    return out
}

@MainActor
func historyChecks(_ r: Report, _ c: LmuxController, fx: URL) async {
    let work = fx.appendingPathComponent("payments", isDirectory: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let root = c.history.projectsRoot
    r.check("History reads a temp projects root in tests (never ~/.claude)", !root.path.hasPrefix(NSHomeDirectory() + "/.claude"),
            root.path)
    let files = writeHistoryCorpus(root: root, cwd: work.path)
    let t0 = Date()
    c.history.refreshNow()
    let blocked = Date().timeIntervalSince(t0)
    r.check("refresh never blocks the main thread", blocked < 0.02, "\(Int(blocked * 1000))ms")
    await c.history.refresh()
    r.check("closed sessions listed, newest first", c.history.totalCount >= 4
            && c.history.items.first?.record.id == "8e1f0c2a-0000-4000-8000-000000000001", "\(c.history.totalCount)")
    await c.history.search("환불")
    let items = c.history.items
    r.check("Korean 2-syllable search finds the three 환불 sessions", items.count == 3, items.map(\.record.id).joined(separator: ","))
    r.check("…with a snippet and the match highlighted", items.allSatisfy { i in
        guard let s = i.snippet else { return false }
        return !i.highlights.isEmpty && i.highlights.allSatisfy { s[$0] == "환불" }
    })
    await c.history.search("부분환불 CSV")
    r.check("terms are ANDed (부분환불 CSV -> 1)", c.history.items.map(\.record.id) == ["8e1f0c2a-0000-4000-8000-000000000002"])
    await c.history.search("SETTLE.TS")
    r.check("case-insensitive, matches replies too", c.history.items.first?.record.id == "8e1f0c2a-0000-4000-8000-000000000003")

    // Resume = new workspace at the session's cwd running claude --resume <id>.
    var resumed: Workspace?
    c.history.resume("8e1f0c2a-0000-4000-8000-000000000002") { resumed = $0 }
    _ = await waitFor(3) { resumed != nil }
    let rp = resumed?.panes.first
    r.check("Resume opens a workspace in the session's cwd", rp?.cwd == work.path, rp?.cwd ?? "nil")
    r.check("…running claude --resume <id>",
            await sinks.wait(rp?.id ?? "", contains: "claude --resume 8e1f0c2a-0000-4000-8000-000000000002"),
            sinks.text(rp?.id ?? ""))
    await c.history.search("")
    c.history.query = ""

    // Archive in the background only what Claude's cleanup will delete soon (default
    // cleanupPeriodDays 30: older than 25 days), restore if the source vanished.
    await c.history.drain()
    let archive = paths.stateDir.appendingPathComponent("archive")
    func archivedIDs() -> Set<String> {
        Set((FileManager.default.enumerator(atPath: archive.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".lzfse") }.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            .map { ($0 as NSString).deletingPathExtension })
    }
    r.check("only the session at risk is archived (30 days old), fresh ones aren't copied",
            archivedIDs() == ["8e1f0c2a-0000-4000-8000-000000000004"], archivedIDs().sorted().joined(separator: ","))
    let gone = files["8e1f0c2a-0000-4000-8000-000000000004"]!
    try? FileManager.default.removeItem(at: gone)
    await c.history.refresh()
    r.check("a vanished session stays listed (missing, archived)",
            c.history.sessions.first { $0.id == "8e1f0c2a-0000-4000-8000-000000000004" }.map { $0.isMissing && $0.isArchived } == true)
    var restoredWS: Workspace?
    c.history.resume("8e1f0c2a-0000-4000-8000-000000000004") { restoredWS = $0 }
    _ = await waitFor(3) { restoredWS != nil }
    let restoredTyped = await sinks.wait(restoredWS?.panes.first?.id ?? "", contains: "--resume 8e1f0c2a-0000-4000-8000-000000000004")
    r.check("Resume restores it from the archive first", FileManager.default.fileExists(atPath: gone.path) && restoredTyped)

    // Hide (archives it: nothing lists it any more) and Move to Trash.
    c.history.hide("8e1f0c2a-0000-4000-8000-000000000003")
    await c.history.refresh()
    r.check("Hide removes it from the list (and it stays hidden)",
            !c.history.items.contains { $0.record.id == "8e1f0c2a-0000-4000-8000-000000000003" })
    await c.history.drain()
    r.check("…and archives it", archivedIDs().contains("8e1f0c2a-0000-4000-8000-000000000003"))
    let archiveMode = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue
    r.check("archive dir is private (0700)", archiveMode == 0o700, String(archiveMode ?? -1, radix: 8))
    var trashed: [URL] = []
    var trashDone = false
    c.history.moveToTrash("8e1f0c2a-0000-4000-8000-000000000001") { trashed = $0; trashDone = true }
    _ = await waitFor(3) { trashDone }
    let src1 = files["8e1f0c2a-0000-4000-8000-000000000001"]!
    r.check("Move to Trash moves transcript + archive to the Trash", !trashed.isEmpty
            && !FileManager.default.fileExists(atPath: src1.path) && trashed.allSatisfy { $0.path.contains(".Trash") },
            trashed.map(\.path).joined(separator: ", "))
    for u in trashed { try? FileManager.default.removeItem(at: u) }  // leave the user's Trash as it was
    r.check("…and the test leaves the Trash as it was", trashed.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    await c.history.refresh()
    r.check("…and it's gone from History", !c.history.sessions.contains { $0.id == "8e1f0c2a-0000-4000-8000-000000000001" })
    if let rp {
        hookEvent(c, rp, "SessionStart", session: "8e1f0c2a-0000-4000-8000-000000000002", ["source": "resume"])
        r.check("a session open in a pane is not listed as closed",
                !c.history.items.contains { $0.record.id == "8e1f0c2a-0000-4000-8000-000000000002" })
        hookEvent(c, rp, "SessionEnd", session: "8e1f0c2a-0000-4000-8000-000000000002")
        r.check("…and is listed again once it ends",
                c.history.items.contains { $0.record.id == "8e1f0c2a-0000-4000-8000-000000000002" })
    }
}


/// Physical footprint of this process (what Activity Monitor calls Memory), in bytes.
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Samples the footprint every few ms on a background queue and keeps the peak.
final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var _peak: UInt64 = 0
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lmux.apptest.peak"))
    init() {
        timer.schedule(deadline: .now(), repeating: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            let f = footprint()
            self?.lock.withLock { if f > self!._peak { self!._peak = f } }
        }
        timer.resume()
    }
    var peak: UInt64 { lock.withLock { _peak } }
    func stop() { timer.cancel() }
}

/// A Claude Code-shaped transcript of at least `bytes`, mostly large tool results (like a
/// real long session). Returns the prompts of its turns.
func writeBigTranscript(_ url: URL, session: String, bytes: Int) -> [String] {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    guard let h = try? FileHandle(forWritingTo: url) else { return [] }
    defer { try? h.close() }
    let blob = String(repeating: "lorem ipsum 환불 로그 0123456789 ", count: 6000)  // ~250KB per tool result
    var parent = "null"
    var written = 0
    var prompts: [String] = []
    var n = 0
    func line(_ s: String) { let d = Data((s + "\n").utf8); h.write(d); written += d.count }
    while written < bytes {
        n += 1
        let p = "big prompt number \(n): look at the refund logs"
        prompts.append(p)
        let u = "\(session)-u\(n)", t = "\(session)-t\(n)", r = "\(session)-r\(n)", a = "\(session)-a\(n)"
        let common = #""isSidechain":false,"userType":"external","cwd":"/tmp/big","sessionId":"\#(session)","version":"2.1.280""#
        line(#"{"parentUuid":\#(parent),\#(common),"type":"user","message":{"role":"user","content":"\#(p)"},"uuid":"\#(u)","turnOrigin":"human"}"#)
        line(#"{"parentUuid":"\#(u)",\#(common),"type":"assistant","message":{"id":"m\#(n)t","role":"assistant","content":[{"type":"tool_use","id":"tu\#(n)","name":"Bash","input":{"command":"cat refunds.log"}}]},"uuid":"\#(t)"}"#)
        line(#"{"parentUuid":"\#(t)",\#(common),"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu\#(n)","content":"\#(blob)"}]},"uuid":"\#(r)","toolUseResult":{"stdout":"\#(blob)"},"sourceToolAssistantUUID":"\#(t)"}"#)
        line(#"{"parentUuid":"\#(r)",\#(common),"type":"assistant","message":{"id":"m\#(n)","role":"assistant","content":[{"type":"text","text":"Reply \#(n): **all good**"}]},"uuid":"\#(a)"}"#)
        parent = "\"\(a)\""
    }
    return prompts
}

@MainActor
func runBigTranscript() async -> Int32 {
    let r = Report()
    r.section = "big-transcript"
    let c = makeController()
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("fixtures", isDirectory: true)
    try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
    var created: [Workspace] = []
    await sleepMs(500)
    await bigTranscriptChecks(r, c, fx: fx, created: &created)
    return finish(r, c)
}

@MainActor
func bigTranscriptChecks(_ r: Report, _ c: LmuxController, fx: URL, created: inout [Workspace]) async {
    let url = fx.appendingPathComponent("big-1.jsonl")
    let prompts = writeBigTranscript(url, session: "big-1", bytes: 52 << 20)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    r.check("synthetic transcript is >= 50MB", size >= 50 << 20, "\(size >> 20)MB, \(prompts.count) turns")
    let screen = prompts.suffix(3).map { "❯ \($0)\n\n⏺ ok\n" }.joined()
    let prog = ScreenFixture.script(screen, input: "next", dir: fx, name: "big")
    let ws = c.newWorkspace(program: prog); created.append(ws)
    let p = ws.panes[0]
    _ = await waitFor(5) { rows(p).contains { $0.contains("accept edits") } }
    let base = footprint()
    let sampler = PeakSampler()
    hookEvent(c, p, "SessionStart", session: "big-1", transcript: url.path, ["source": "resume"])
    let first = await c.loadTurns(p)
    let afterFirst = c.transcriptReads[p.id]
    r.check("first read: every turn, the whole file parsed once", first.count == prompts.count
            && afterFirst?.bytes == size && afterFirst?.fullReads == 1, "\(first.count) turns, \(afterFirst.map { "\($0)" } ?? "nil")")
    // Hover over and over, and read Claude's title a few times.
    var moves: [Double] = []
    for i in 0..<40 {
        let y = p.surface.bounds.height - CGFloat(10 + (i % 12) * 16)
        let t0 = Date()
        c.paneMouseMoved(p, NSPoint(x: 200, y: y))
        moves.append(Date().timeIntervalSince(t0) * 1000)
        await sleepMs(15)
        if i % 8 == 0 { c.refreshTitleFromClaude(p); p.titleState = TitleState() }
    }
    moves.sort()
    let slowest = moves.last ?? 0, median = moves[moves.count / 2]
    _ = await c.loadTurns(p)
    r.check("repeated hover / titles parse nothing more (no new bytes)", c.transcriptReads[p.id]?.bytes == size
            && c.transcriptReads[p.id]?.fullReads == 1, "\(c.transcriptReads[p.id].map { "\($0)" } ?? "nil")")
    // (A parse of the 50MB file takes hundreds of ms: the CI allowance for a preempted main thread can't hide one.)
    r.check("hover stays off the parse path on the main thread (every move < one 60Hz frame)", slowest < 16 * ciSlow,
            String(format: "median %.2fms, max %.2fms", median, slowest))
    // Claude appends a turn: only those bytes are parsed.
    let extra = #"{"parentUuid":"big-1-a\#(prompts.count)","isSidechain":false,"type":"user","message":{"role":"user","content":"one more prompt"},"uuid":"big-1-uX","turnOrigin":"human"}"# + "\n"
    if let h = FileHandle(forWritingAtPath: url.path) { h.seekToEndOfFile(); h.write(Data(extra.utf8)); h.closeFile() }
    let grown = await c.loadTurns(p)
    r.check("an appended turn: only the appended bytes are parsed", grown.count == prompts.count + 1
            && c.transcriptReads[p.id]?.bytes == size + extra.utf8.count && c.transcriptReads[p.id]?.fullReads == 1,
            "\(c.transcriptReads[p.id].map { "\($0)" } ?? "nil")")
    c.pasteboard.clearContents()
    let md = await c.copyOriginal(p, turnIndex: prompts.count)
    r.check("Copy original still reads the full reply from the file", md == "Reply \(prompts.count): **all good**", md ?? "nil")
    sampler.stop()
    let peakMB = Double(Int64(sampler.peak) - Int64(base)) / 1_048_576
    let nowMB = Double(footprint()) / 1_048_576
    print("      big transcript: \(size >> 20)MB file, peak +\(String(format: "%.1f", peakMB))MB over \(Int(Double(base) / 1_048_576))MB, now \(Int(nowMB))MB")
    r.check("memory stays under budget while hovering / titling a 50MB transcript (peak +60MB, process < 300MB)",
            peakMB < 60 && Double(sampler.peak) / 1_048_576 < 300,
            String(format: "peak +%.1fMB (%.0fMB), now %.0fMB", peakMB, Double(sampler.peak) / 1_048_576, nowMB))
    hookEvent(c, p, "SessionEnd", session: "big-1")
    try? FileManager.default.removeItem(at: url)
}

/// ✎ × ⌘Z through Claude Code's rewind menu, on a faithful fake of it (also `lmux-apptest --rewind`).
@MainActor
func rewindChecks(_ r: Report, _ c: LmuxController, _ w: NSWindow, fx: URL) async -> [Workspace] {
    var made: [Workspace] = []
    // ------------------------------------------------------------ rewind (Claude Code's menu, faithful fake)
    r.section = "rewind"
    // App/scripts/claude-rewind-fake.py draws the rewind menu row for row like Claude Code 2.1.280 and
    // logs every key it reads and what was chosen; the transcript fixture holds the same prompts.
    let fakeScript = URL(fileURLWithPath: env["LMUX_SCRIPTS_DIR"] ?? "scripts").appendingPathComponent("claude-rewind-fake.py").path
    func rewindPane(_ name: String, prompts: [String], menu: [String]? = nil, _ extra: [String: Any] = [:]) async
        -> (pane: Pane, log: String, path: String) {
        let path = fx.appendingPathComponent("rw-\(name).jsonl").path
        try? fixtureJSONL(session: "rw-\(name)", cwd: "/tmp", turns: prompts.map { FixtureTurn(prompt: $0, reply: "OK") })
            .write(toFile: path, atomically: true, encoding: .utf8)
        let spec = fx.appendingPathComponent("rw-\(name).json")
        var o: [String: Any] = ["prompts": menu ?? prompts]
        for (k, v) in extra { o[k] = v }
        try? JSONSerialization.data(withJSONObject: o).write(to: spec)
        let log = fx.appendingPathComponent("rw-\(name).log").path
        FileManager.default.createFile(atPath: log, contents: nil)
        let sh = fx.appendingPathComponent("rw-\(name).sh")
        try? "#!/bin/sh\nexec /usr/bin/python3 '\(fakeScript)' '\(spec.path)' '\(log)'\n".write(to: sh, atomically: true, encoding: .utf8)
        chmod(sh.path, 0o755)
        let ws = c.newWorkspace(program: sh.path); made.append(ws)
        let p = ws.panes[0]
        _ = await waitFor(8) { rows(p).contains { $0.contains("manual mode on") } }
        hookEvent(c, p, "SessionStart", session: "rw-\(name)", transcript: path, ["source": "startup"])
        _ = await c.loadTurns(p)
        return (p, log, path)
    }
    func fakeLog(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    /// What the fake did (picked, chose, restored…), without the keys.
    func acts(_ path: String) -> [String] { fakeLog(path).filter { !$0.hasPrefix("key ") } }
    /// The keys it read, in order.
    func keys(_ path: String) -> [String] { fakeLog(path).filter { $0.hasPrefix("key ") }.map { String($0.dropFirst(4)) } }
    func input(_ p: Pane) -> String? { LmuxController.idleInput(rows(p)) }
    func confirmAndWait(_ p: Pane) async -> Bool {
        p.view.overlay.card?.confirm.performClick()
        _ = await waitFor(2) { p.busy }
        return await waitFor(20) { !p.busy }
    }

    // Pure: the menu as Claude Code draws it (rows from a 2.1.280 capture).
    let listRows = ["❯ remember PINEAPPLE", "", "⏺ OK remember PINEAPPLE", String(repeating: "▔", count: 40), "   Rewind", "",
                    "   Restore the code and/or conversation to the point before…", "    ↑ 1 more above", "",
                    "     what is 6 times 7", "     No code changes", "", "   ❯ third message here", "     No code changes", "",
                    "    ↓ 1 more below", "   Enter to continue · Esc to cancel"]
    r.check("menu read: the highlighted entry, its row and the scroll counts",
            RewindMenu.read(listRows) == .list(selected: "third message here", row: 12, above: 1, below: 1), "\(RewindMenu.read(listRows))")
    // 2.1.322: "↑ 4 more" / "↓ 1 more", the count right above the first entry shown.
    let listRows322 = [String(repeating: "▔", count: 40), "   Rewind", "", "   Restore the code and/or conversation to the point before…", "",
                       "     ↑ 3 more", "     fourth one", "     No code changes", "", "     fifth one", "     No code changes", "",
                       "   ❯ sixth one", "     No code changes", "", "     ↓ 1 more", "", "   Enter to continue · Esc to cancel"]
    r.check("…and as 2.1.322 draws it: “↑ 3 more”, “↓ 1 more”; the entry is message 5 of the list",
            RewindMenu.read(listRows322) == .list(selected: "sixth one", row: 12, above: 3, below: 1)
                && RewindMenu.selectedIndex(listRows322) == 5, "\(RewindMenu.read(listRows322)) \(String(describing: RewindMenu.selectedIndex(listRows322)))")
    let confirmRows = [String(repeating: "▔", count: 40), "   Rewind", "",
                       "   Confirm you want to restore to the point before you sent this message:", "",
                       "   │ please WRITEFILE /private/tmp/x", "   │ y/note.txt", "   │ (4s ago)", "",
                       "   The conversation will be forked.", "   The code will be restored -1 in note.txt.", "",
                       "   ❯ 1. Restore code and conversation", "     2. Restore conversation", "     3. Restore code",
                       "     4. Summarize from here", "   ↓ 5. Summarize up to here"]
    r.check("menu read: the confirmation's quote (rows joined, the time left out), its options (scroll arrow too), the highlighted one",
            RewindMenu.read(confirmRows) == .confirm(quote: "please WRITEFILE /private/tmp/x\ny/note.txt",
                                                     options: ["Restore code and conversation", "Restore conversation", "Restore code",
                                                               "Summarize from here", "Summarize up to here"], selected: 0))
    r.check("…a time shown another way (“(just now)”) is left out of the quote too",
            RewindMenu.read([String(repeating: "▔", count: 40), "   Rewind", "", "   Confirm you want to restore to the point before you sent this message:",
                             "", "   │ hello there", "   │ (just now)", "", "   ❯ 1. Restore conversation"])
            == .confirm(quote: "hello there", options: ["Restore conversation"], selected: 0))
    r.check("…the quote is told from another prompt with the same start",
            RewindMenu.quoteMatches("please WRITEFILE /private/tmp/x\ny/note.txt", prompt: "please WRITEFILE /private/tmp/xy/note.txt")
            && !RewindMenu.quoteMatches("fix bug\nA", prompt: "fix bug\nB") && RewindMenu.quoteMatches("fix bug\nB", prompt: "fix bug\nB"))
    r.check("menu read: the conversation alone (a prompt row, an input box) is no menu",
            RewindMenu.read(["❯ Rewind", "", "⏺ ok", "────────", "❯ ", "────────"]) == .closed)
    r.check("menu read: its footer with the title scrolled away is a menu lmux can't read (so it backs out)",
            RewindMenu.read(["     No code changes", "   ❯ (current)", "", "   Enter to continue · Esc to cancel"]) == .open)
    r.check("entries match their prompt: cut with …, a multi-line prompt's first line + …, never a shorter prompt",
            RewindMenu.matches("a very long prompt a ve…", prompt: "a very long prompt a very long prompt")
            && RewindMenu.matches("line one of a multi…", prompt: "line one of a multi\nline two")
            && !RewindMenu.matches("line one of a multi", prompt: "line one of a multi\nline two")
            && !RewindMenu.matches("yes", prompt: "yes please") && RewindMenu.matches("yes", prompt: "yes"))
    r.check("working shows on the spinner line above the input, not only in the footer",
            LmuxController.screenWorking(["❯ hi", "", "✻ Working… (esc to interrupt)", "", "────────", "❯ ", "────────", "  ⏵⏵ accept edits on"])
            && LmuxController.idleInput(["❯ hi", "", "✻ Working… (esc to interrupt)", "", "────────", "❯ ", "────────"]) == nil)

    // ✎ on an older turn, with file checkpoints (the default option is "Restore code and conversation").
    let r1 = await rewindPane("1", prompts: ["remember PINEAPPLE", "the number 42", "third MANGO"], ["files": true])
    c.requestRewind(r1.pane, turnIndex: 2, edit: true)
    let d1 = r1.pane.view.overlay.card?.detail.stringValue ?? ""
    r.check("✎ asks first: rewinds, removes everything after it, Claude keeps running",
            r1.pane.view.overlay.card?.confirm.title == "Edit" && d1.contains("Removes this message and everything after it")
            && d1.contains("Claude keeps running"), d1)
    r.check("✎: done", await confirmAndWait(r1.pane))
    r.check("✎: exactly Esc Esc, ↑ ↑, Return, one ↓ past the code option, Return",
            keys(r1.log) == ["esc", "esc", "up", "up", "enter", "down", "enter"], keys(r1.log).joined(separator: " "))
    r.check("…“Restore conversation” on message 2, never code",
            acts(r1.log) == ["open", "pick 2", "choose Restore conversation 2", "restore conversation 2"],
            acts(r1.log).joined(separator: "; ") + " | " + c.actionLog.suffix(4).joined(separator: "; "))
    r.check("✎: its text is back in the input, nothing sent", await waitFor(2) { input(r1.pane) == "the number 42" },
            input(r1.pane) ?? "nil")
    let t1 = await c.loadTurns(r1.pane)
    r.check("✎: lmux hides it and the turn after it (Claude writes its new branch with the next prompt)",
            t1.map(\.prompt) == ["remember PINEAPPLE"] && r1.pane.rewoundFrom == "rw-1-u2", t1.map(\.prompt).joined(separator: " / "))
    r.check("…and the user's input to the pane is back", !r1.pane.surface.inputHeld)
    // Claude's next prompt starts a new branch from turn 1: lmux follows it and drops the marker.
    let branch = """
    {"parentUuid":"rw-1-a1","isSidechain":false,"type":"user","message":{"role":"user","content":"the number 43"},"uuid":"rw-1-n1","timestamp":"2026-11-04T10:00:00.000Z","sessionId":"rw-1","promptSource":"typed"}
    {"type":"last-prompt","lastPrompt":"the number 43","leafUuid":"rw-1-n1","sessionId":"rw-1"}

    """
    if let h = FileHandle(forWritingAtPath: r1.path) { h.seekToEndOfFile(); h.write(Data(branch.utf8)); h.closeFile() }
    let t1b = await c.loadTurns(r1.pane)
    r.check("…the next prompt's branch replaces the rewound turns", t1b.map(\.prompt) == ["remember PINEAPPLE", "the number 43"]
            && r1.pane.rewoundFrom == nil, t1b.map(\.prompt).joined(separator: " / "))
    r1.pane.rewoundFrom = "x"
    hookEvent(c, r1.pane, "SessionStart", session: "rw-1", transcript: r1.path, ["source": "resume"])
    r.check("SessionStart clears the rewind marker", r1.pane.rewoundFrom == nil)

    // The screen lags 300ms behind every key and a clock redraws it all the time: still one key per
    // move, Return only on "Restore conversation".
    let r2 = await rewindPane("2", prompts: ["first", "second one", "third"], ["files": true, "lag_ms": 300, "tick": true])
    let o2 = await c.rewind(r2.pane, turnUuid: "rw-2-u1", mode: .remove)
    r.check("a lagging, ticking screen: no extra key (Esc Esc, Home to the first message, Return, ↓, Return, then Ctrl+U to clear)",
            o2 == .done && keys(r2.log) == ["esc", "esc", "top", "enter", "down", "enter", "ctrl-u"],
            "\(o2) " + keys(r2.log).joined(separator: " "))
    r.check("…“Restore conversation” on message 1, never code, then the input cleared",
            acts(r2.log) == ["open", "pick 1", "choose Restore conversation 1", "restore conversation 1", "clear input"]
            && input(r2.pane) == "", acts(r2.log).joined(separator: "; "))

    // × on the last turn: rewound, the input left empty (Esc Esc on the restored text).
    let r3 = await rewindPane("3", prompts: ["first", "second one"])
    c.requestRewind(r3.pane, turnIndex: 2, edit: false)
    let d3 = r3.pane.view.overlay.card?.detail.stringValue ?? ""
    r.check("× on the last turn: “Removes this message”, nothing about later ones",
            r3.pane.view.overlay.card?.confirm.title == "Remove" && d3.contains("Removes this message from the conversation"), d3)
    _ = await confirmAndWait(r3.pane)
    r.check("×: rewound, then the input cleared", acts(r3.log) == ["open", "pick 2", "choose Restore conversation 2",
                                                                  "restore conversation 2", "clear input"]
            && input(r3.pane) == "", acts(r3.log).joined(separator: "; "))

    // The same prompt twice: × on the first "yes" goes past the later one, by position.
    let r4 = await rewindPane("4", prompts: ["yes", "fix it", "yes"])
    let o4 = await c.rewind(r4.pane, turnUuid: "rw-4-u1", mode: .remove)
    r.check("× on the first of two identical prompts rewinds to that one", o4 == .done && acts(r4.log).contains("restore conversation 1"),
            acts(r4.log).joined(separator: "; "))

    // Multi-line prompts with the same first line (the menu shows both as "fix bug…").
    let r5 = await rewindPane("5", prompts: ["fix bug\nin login", "other", "fix bug\nin logout"])
    let o5 = await c.rewind(r5.pane, turnUuid: "rw-5-u1", mode: .edit)
    r.check("✎ on the first of two multi-line prompts with the same first line: that one, by position and its quote",
            o5 == .done && acts(r5.log).contains("restore conversation 1") && input(r5.pane)?.hasPrefix("fix bug") == true,
            acts(r5.log).joined(separator: "; "))

    // A long and a multi-line prompt, as the menu cuts them.
    let long = String(repeating: "a very long prompt ", count: 12).trimmingCharacters(in: .whitespaces)
    let r6 = await rewindPane("6", prompts: ["line one of a multi\nline two here", long, "short"])
    let o6 = await c.rewind(r6.pane, turnUuid: "rw-6-u1", mode: .edit)
    r.check("✎ on a multi-line prompt (shown cut with …) past a long one", o6 == .done && acts(r6.log).contains("restore conversation 1"),
            acts(r6.log).joined(separator: "; "))

    // The menu doesn't list what the transcript says: back out, nothing chosen.
    let r7 = await rewindPane("7", prompts: ["alpha", "beta", "gamma"], menu: ["other", "things", "here"])
    let o7 = await c.rewind(r7.pane, turnUuid: "rw-7-u2", mode: .remove)
    r.check("menu entries don't match: backs out with Esc at the first wrong one, nothing picked, a note says so",
            o7 != .done && keys(r7.log) == ["esc", "esc", "up", "esc"] && acts(r7.log) == ["open", "close"]
            && (r7.pane.view.overlay.toast?.text.string ?? "").contains("Couldn’t rewind; use Esc Esc in Claude Code")
            && RewindMenu.read(rows(r7.pane)) == .closed, keys(r7.log).joined(separator: " ") + " \(o7)")

    // A draft in Claude's input: refused before any key (Esc Esc would clear it), also while Claude works.
    let r8 = await rewindPane("8", prompts: ["alpha", "beta"], ["input": "half typed"])
    let o8 = await c.rewind(r8.pane, turnUuid: "rw-8-u1", mode: .remove)
    r.check("a draft in the input: refused, no key sent, the draft kept",
            o8 != .done && fakeLog(r8.log).isEmpty && input(r8.pane) == "half typed", fakeLog(r8.log).joined(separator: "; "))
    let r9 = await rewindPane("9", prompts: ["alpha", "beta"], ["input": "half typed", "working": "footer"])
    let o9 = await c.rewind(r9.pane, turnUuid: "rw-9-u1", mode: .remove)
    r.check("…a draft while Claude works: refused before the Esc that would stop it", o9 != .done && fakeLog(r9.log).isEmpty,
            fakeLog(r9.log).joined(separator: "; "))

    // Claude working (the spinner line says so, no hook said so): Esc first, then the menu once it's idle.
    let r10 = await rewindPane("10", prompts: ["alpha", "beta"], ["working": "spinner"])
    let o10 = await c.rewind(r10.pane, turnUuid: "rw-10-u1", mode: .remove)
    r.check("working (spinner above the input): Esc stops it first, then Esc Esc opens the menu",
            o10 == .done && keys(r10.log).prefix(3) == ["esc", "esc", "esc"] && acts(r10.log).first == "interrupt"
            && acts(r10.log).contains("restore conversation 1"), keys(r10.log).joined(separator: " ") + " | " + acts(r10.log).joined(separator: "; "))
    // …and that Esc makes Claude take an answerless last turn back: for the last turn that's the rewind.
    let r11 = await rewindPane("11", prompts: ["alpha", "beta"], ["working": "footer", "takeback": true])
    let o11 = await c.rewind(r11.pane, turnUuid: "rw-11-u2", mode: .edit)
    r.check("…Claude takes the last turn back itself: one Esc, nothing more, its text in the input",
            o11 == .done && keys(r11.log) == ["esc"] && input(r11.pane) == "beta", keys(r11.log).joined(separator: " "))
    // …for an older turn: the taken-back text is cleared, and the list is one shorter.
    let r12 = await rewindPane("12", prompts: ["alpha", "beta", "gamma"], ["working": "footer", "takeback": true])
    let o12 = await c.rewind(r12.pane, turnUuid: "rw-12-u1", mode: .remove)
    r.check("…for an older turn: the taken-back text cleared, then rewound past the shorter list",
            o12 == .done && acts(r12.log).prefix(3) == ["take back 3", "clear input", "open"] && acts(r12.log).contains("restore conversation 1"),
            acts(r12.log).joined(separator: "; "))

    // Without a confirmation (no file checkpoints): Return restores, and that counts only with the prompt back.
    let r13 = await rewindPane("13", prompts: ["alpha", "beta"], ["direct": true])
    let o13 = await c.rewind(r13.pane, turnUuid: "rw-13-u2", mode: .edit)
    r.check("no confirmation step: rewound, the prompt back in the input", o13 == .done && input(r13.pane) == "beta"
            && r13.pane.rewoundFrom == "rw-13-u2", "\(o13) " + acts(r13.log).joined(separator: "; "))
    let r14 = await rewindPane("14", prompts: ["alpha", "beta"], ["close_on_pick": true])
    let o14 = await c.rewind(r14.pane, turnUuid: "rw-14-u2", mode: .edit)
    let t14 = await c.loadTurns(r14.pane)
    r.check("…the menu closing without a confirmation or the prompt: failed, nothing hidden",
            o14 != .done && r14.pane.rewoundFrom == nil && t14.count == 2, "\(o14)")

    // A menu that opens only after lmux gave up waiting: closed again, nothing picked.
    let r16 = await rewindPane("16", prompts: ["alpha", "beta"], ["open_delay_ms": 4500])
    let o16 = await c.rewind(r16.pane, turnUuid: "rw-16-u1", mode: .remove)
    r.check("a menu that opens late: closed again with Esc, nothing picked, no menu left",
            o16 != .done && acts(r16.log) == ["open", "close"] && keys(r16.log) == ["esc", "esc", "esc"]
            && RewindMenu.read(rows(r16.pane)) == .closed, keys(r16.log).joined(separator: " ") + " | " + acts(r16.log).joined(separator: "; "))

    // A multi-line draft whose first line is empty is a draft too.
    let r17 = await rewindPane("17", prompts: ["alpha", "beta"], ["input": "\nsecond line"])
    let o17 = await c.rewind(r17.pane, turnUuid: "rw-17-u1", mode: .remove)
    r.check("a multi-line draft with an empty first line: refused, no key sent", o17 != .done && fakeLog(r17.log).isEmpty,
            fakeLog(r17.log).joined(separator: "; "))

    // The list doesn't agree with the transcript on where the entry is (a turn only lmux has): back out.
    let r18 = await rewindPane("18", prompts: ["yes", "yes", "fix"], menu: ["yes", "fix"])
    let o18 = await c.rewind(r18.pane, turnUuid: "rw-18-u2", mode: .remove)
    r.check("an entry whose place in the list isn't the turn's: backs out before Return, nothing picked",
            o18 != .done && !acts(r18.log).contains { $0.hasPrefix("pick") } && acts(r18.log).last == "close",
            "\(o18) " + acts(r18.log).joined(separator: "; "))

    // Scrolled up into the scrollback: lmux brings the viewport down, then reads.
    let many = (1...40).map { "prompt number \($0)" }
    let r19 = await rewindPane("19", prompts: many)
    _ = r19.pane.surface.performBindingAction("scroll_page_up")
    _ = r19.pane.surface.performBindingAction("scroll_page_up")
    let o19 = await c.rewind(r19.pane, turnUuid: "rw-19-u39", mode: .remove)
    r.check("scrolled up: back to the bottom first, then rewound", o19 == .done && acts(r19.log).contains("restore conversation 39"),
            "\(o19) " + acts(r19.log).joined(separator: "; "))
    // Far from "(current)": Home to the first message, then down one entry at a time, each checked.
    let r19b = await rewindPane("19b", prompts: many)
    let t0 = Date()
    let o19b = await c.rewind(r19b.pane, turnUuid: "rw-19b-u4", mode: .edit)
    let dt19b = Date().timeIntervalSince(t0)
    r.check("a turn near the top of a long list: Home, then ↓ ×3, Return, Return (not 37 ↑)",
            o19b == .done && keys(r19b.log) == ["esc", "esc", "top", "down", "down", "down", "enter", "enter"]
            && acts(r19b.log).contains("restore conversation 4") && input(r19b.pane) == "prompt number 4",
            String(format: "%.2fs ", dt19b) + keys(r19b.log).joined(separator: " "))
    r.check("…under 1.5s on the fake", dt19b < 1.5 * ciSlow, String(format: "%.2fs", dt19b))
    // × on a multi-line prompt: no Ctrl+U (it clears one row), Esc Esc.
    let r19d = await rewindPane("19d", prompts: ["alpha", "line one\nline two"])
    let o19d = await c.rewind(r19d.pane, turnUuid: "rw-19d-u2", mode: .remove)
    r.check("× on a multi-line prompt: Esc Esc clears it, no Ctrl+U; the input empty",
            o19d == .done && Array(keys(r19d.log).suffix(3)) == ["enter", "esc", "esc"] && input(r19d.pane) == ""
            && acts(r19d.log).last == "clear input",
            "\(o19d) " + keys(r19d.log).joined(separator: " ") + " | " + acts(r19d.log).joined(separator: "; "))
    // × on a Claude slow to draw (400ms a key, no ticks): Ctrl+U's cleared box is waited for, no Esc Esc
    // (on the empty input it would open the menu).
    let r19e = await rewindPane("19e", prompts: ["alpha", "beta"], ["lag_ms": 400])
    let o19e = await c.rewind(r19e.pane, turnUuid: "rw-19e-u2", mode: .remove)
    r.check("× on a slow screen: Ctrl+U once, waited out, nothing after it, the input empty",
            o19e == .done && keys(r19e.log).last == "ctrl-u" && acts(r19e.log).filter { $0 == "open" }.count == 1
            && input(r19e.pane) == "",
            "\(o19e) " + keys(r19e.log).joined(separator: " ") + " | " + acts(r19e.log).joined(separator: "; "))
    // ✎ on the last turn: quick, and no menu ever visible (the held frame covers it).
    let r19c = await rewindPane("19c", prompts: ["alpha", "beta"])
    var seenMenu = 0
    let watch = Timer(timeInterval: 0.01, repeats: true) { _ in
        MainActor.assumeIsolated {
            if !r19c.pane.view.overlay.freezeShown, RewindMenu.read(rows(r19c.pane)) != .closed { seenMenu += 1 }
        }
    }
    RunLoop.main.add(watch, forMode: .common)
    let start19c = Date()
    let o19c = await c.rewind(r19c.pane, turnUuid: "rw-19c-u2", mode: .edit)
    let dt19c = Date().timeIntervalSince(start19c)
    watch.invalidate()
    r.check("✎ on the last turn: under 1s on the fake, the menu never shown uncovered, the prompt back",
            o19c == .done && dt19c < 1.0 * ciSlow && seenMenu == 0 && input(r19c.pane) == "beta",
            String(format: "%.2fs, %d uncovered menu samples", dt19c, seenMenu))

    // Claude takes the last turn back, then the walk fails: that turn is hidden all the same.
    let r20 = await rewindPane("20", prompts: ["alpha", "beta", "gamma"], menu: ["other", "beta", "gamma"],
                               ["working": "footer", "takeback": true])
    let o20 = await c.rewind(r20.pane, turnUuid: "rw-20-u1", mode: .remove)
    r.check("…taken back, then a failed walk: the taken-back turn stays hidden", o20 != .done && r20.pane.rewoundFrom == "rw-20-u3",
            "\(o20) marker=\(r20.pane.rewoundFrom ?? "nil")")

    // A slow restore: the prompt comes back after lmux's first wait.
    let r21 = await rewindPane("21", prompts: ["alpha", "beta"], ["slow_restore_ms": 7000])
    let o21 = await c.rewind(r21.pane, turnUuid: "rw-21-u2", mode: .edit)
    r.check("a slow restore still counts once Claude is back", o21 == .done && r21.pane.rewoundFrom == "rw-21-u2" && input(r21.pane) == "beta",
            "\(o21)")

    // ⌘Z can't start a second driver on a pane lmux is already driving, and a rewind ends the undo toast.
    let r22 = await rewindPane("22", prompts: ["alpha", "beta"], ["lag_ms": 200])
    c.showUndoToast(r22.pane, prompt: "beta")
    let t22 = Task { await c.rewind(r22.pane, turnUuid: "rw-22-u1", mode: .remove) }
    _ = await waitFor(2) { r22.pane.busy }
    r.check("a rewind starting ends the pane's undo toast", c.pendingUndo == nil)
    r.check("…the pane's last frame is held over it while lmux drives the menu, the live terminal hidden under it",
            r22.pane.view.overlay.freezeShown && r22.pane.surface.alphaValue == 0)
    if let f = r22.pane.view.overlay.freeze as? FrozenFrameView, let l = r22.pane.surface.layer,
       let surf = l.contents.map({ unsafeBitCast($0 as AnyObject, to: IOSurfaceRef.self) }) {
        r.check("…its own pixels, shown like the terminal's layer (top left, same scale, same size, Display P3)",
                f.image.width == IOSurfaceGetWidth(surf) && f.image.height == IOSurfaceGetHeight(surf)
                && f.layer?.contentsGravity == l.contentsGravity && f.layer?.contentsScale == l.contentsScale
                && f.frame == r22.pane.view.overlay.bounds && r22.pane.view.overlay.frame == r22.pane.surface.frame && f.image.colorSpace?.name == CGColorSpace.displayP3,
                "\(f.image.width)x\(f.image.height) \(f.layer?.contentsGravity.rawValue ?? "?")/\(l.contentsGravity.rawValue) \(f.layer?.contentsScale ?? 0)/\(l.contentsScale) \(f.frame)/\(r22.pane.surface.frame)")
    } else {
        r.check("…its own pixels, shown like the terminal's layer", false, "no frozen frame view")
    }
    r.check("…and a calm “Rewinding…” shows once it takes a moment",
            await waitFor(2) { r22.pane.view.overlay.toast?.text.string == "Rewinding…" })
    c.showUndoToast(r22.pane, prompt: "beta")
    r.check("…⌘Z while it runs does nothing", !c.undoSend())
    c.clearPendingUndo()
    let o22 = await t22.value
    r.check("…and the rewind finishes with its own keys only", o22 == .done
            && keys(r22.log) == ["esc", "esc", "top", "enter", "enter", "ctrl-u"], keys(r22.log).joined(separator: " "))
    r.check("…done: the pane shows itself again, no note left, the menu gone, input released",
            !r22.pane.view.overlay.freezeShown && r22.pane.surface.alphaValue == 1 && r22.pane.view.overlay.toast == nil
            && RewindMenu.read(rows(r22.pane)) == .closed
            && !r22.pane.surface.inputHeld && !r22.pane.busy)

    // Its tab switched away while lmux drives the menu: no key into the hidden pane (its waits end
    // at once, the Escs would come in a burst); stopped, and it says so once it shows again.
    let r30 = await rewindPane("30", prompts: ["alpha", "beta", "gamma"], ["lag_ms": 300])
    let t30 = Task { await c.rewind(r30.pane, turnUuid: "rw-30-u1", mode: .remove) }
    // Mid-walk: the menu up, lmux waiting for its Home to be drawn.
    _ = await waitFor(4) { keys(r30.log).contains("top") }
    // (Its Home is in the fake's log already: anything after this is a key into the hidden pane.)
    let keysAtHide = keys(r30.log)
    let tab30 = c.newTab(r30.pane)
    let o30 = await t30.value
    await sleepMs(600)
    r.check("tab switched mid-rewind: stopped, not one key into the hidden pane, nothing restored",
            tab30 != nil && !c.onScreen(r30.pane) && o30 != .done && keys(r30.log) == keysAtHide
            && !acts(r30.log).contains { $0.hasPrefix("restore") } && !r30.pane.busy && !r30.pane.surface.inputHeld,
            "\(o30) at hide: \(keysAtHide.joined(separator: " ")) now: \(keys(r30.log).joined(separator: " "))")
    r.check("…no note while it's hidden (it would time out unseen), none on the tab shown instead",
            r30.pane.view.overlay.toast == nil && tab30?.view.overlay.toast == nil)
    r.check("…Claude's menu left open meanwhile (no key could close it)", RewindMenu.read(rows(r30.pane)) != .closed)
    c.selectTab(r30.pane)
    r.check("…shown again: lmux closes Claude's menu (input held meanwhile), then says the rewind stopped",
            await waitFor(4) { RewindMenu.read(rows(r30.pane)) == .closed && r30.pane.view.overlay.toast?.text.string.contains("hidden") == true }
            && !acts(r30.log).contains { $0.hasPrefix("restore") } && !r30.pane.busy && !r30.pane.surface.inputHeld,
            (r30.pane.view.overlay.toast?.text.string ?? "no toast") + " | " + acts(r30.log).joined(separator: "; "))
    // The same with its workspace switched away.
    let r34 = await rewindPane("34", prompts: ["alpha", "beta", "gamma"], ["lag_ms": 300])
    let t34 = Task { await c.rewind(r34.pane, turnUuid: "rw-34-u1", mode: .remove) }
    _ = await waitFor(4) { keys(r34.log).contains("top") }
    let keys34 = keys(r34.log)
    let ws34 = r34.pane.workspace!
    c.select(r30.pane.workspace!)
    let o34 = await t34.value
    await sleepMs(600)
    r.check("workspace switched mid-rewind: stopped, not one key into it, nothing restored",
            o34 != .done && keys(r34.log) == keys34 && !acts(r34.log).contains { $0.hasPrefix("restore") },
            "\(o34) at hide: \(keys34.joined(separator: " ")) now: \(keys(r34.log).joined(separator: " "))")
    c.select(ws34)
    r.check("…selected again: its menu closed, the note shown once",
            await waitFor(4) { RewindMenu.read(rows(r34.pane)) == .closed && r34.pane.view.overlay.toast?.text.string.contains("hidden") == true },
            r34.pane.view.overlay.toast?.text.string ?? "no toast")
    c.select(r30.pane.workspace!); c.select(ws34)
    r.check("…and not again on the next switch", r34.pane.view.overlay.toast == nil || r34.pane.pendingRewindNote == nil)
    // The user's own Esc just before (Claude still working): lmux's Esc waits out Claude's
    // double-press window after it, or the two would open the menu.
    let r31 = await rewindPane("31", prompts: ["alpha", "beta"], ["working": "spinner"])
    r31.pane.lastEscKey = Date()
    let t31start = Date()
    let t31 = Task { await c.rewind(r31.pane, turnUuid: "rw-31-u1", mode: .remove) }
    _ = await waitFor(3) { !keys(r31.log).isEmpty }
    let firstKey31 = Date().timeIntervalSince(t31start)
    let o31 = await t31.value
    r.check("a user's Esc just before: lmux's first Esc only after the double-press window, then rewound",
            firstKey31 >= 0.8 && o31 == .done && acts(r31.log).first == "interrupt" && acts(r31.log).contains("restore conversation 1"),
            String(format: "first key after %.2fs; ", firstKey31) + acts(r31.log).joined(separator: "; "))
    // Ctrl+C isn't an Esc: Claude's double press doesn't count it.
    if let sh = tab30 {
        func press(_ chars: String, _ ign: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                        windowNumber: c.window.windowNumber, context: nil, characters: chars,
                                        charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code) {
                sh.surface.keyDown(with: e)
            }
        }
        c.selectTab(sh)
        sh.lastEscKey = nil
        press("\u{3}", "c", 8, .control)
        let afterCtrlC = sh.lastEscKey
        press("\u{1b}", "\u{1b}", 0x35, [])
        r.check("Ctrl+C isn't kept as an Esc; Esc is", afterCtrlC == nil && sh.lastEscKey != nil)
    } else {
        r.check("a new tab for the Ctrl+C check", false)
    }

    // A `!` shell command: Claude's menu shows it as "! cmd" (the transcript has <bash-input>).
    // Walking past one works; rewinding to one is refused before any key (Claude would leave its
    // input in shell mode, and clearing it doesn't leave that mode).
    let bashTurns = ["a one", "b two", "c three", "<bash-input>ls -la</bash-input>", "e five"]
    let r32 = await rewindPane("32", prompts: bashTurns, menu: ["a one", "b two", "c three", "! ls -la", "e five"])
    let o32 = await c.rewind(r32.pane, turnUuid: "rw-32-u3", mode: .edit)
    r.check("✎ past a ! shell command: its menu entry is told as that turn, rewound",
            o32 == .done && keys(r32.log).prefix(5) == ["esc", "esc", "up", "up", "up"] && acts(r32.log).contains("restore conversation 3")
            && input(r32.pane) == "c three", "\(o32) " + keys(r32.log).joined(separator: " "))
    let r33 = await rewindPane("33", prompts: bashTurns, menu: ["a one", "b two", "c three", "! ls -la", "e five"])
    let o33 = await c.rewind(r33.pane, turnUuid: "rw-33-u4", mode: .remove)
    r.check("× on a ! shell command: refused before any key, a note says why",
            o33 != .done && fakeLog(r33.log).isEmpty, "\(o33) " + fakeLog(r33.log).joined(separator: "; "))
    c.requestRewind(r33.pane, turnIndex: r33.pane.hover.turns.first { $0.uuid == "rw-33-u4" }?.index ?? -1, edit: true)
    r.check("…and ✎ on it says so at once, no confirm card",
            !c.cardShown(r33.pane) && r33.pane.view.overlay.toast?.text.string.contains("shell command") == true,
            r33.pane.view.overlay.toast?.text.string ?? "no toast")

    // The hover pill on a ! shell command: ⧉ only (its ✎ × would only be refused), none without a reply.
    let shellFixture = [FixtureTurn(prompt: "list the files", reply: "OK list"),
                        FixtureTurn(prompt: "<bash-input>ls -la</bash-input>", reply: "Listed."),
                        FixtureTurn(prompt: "<bash-input>pwd</bash-input>", reply: nil),
                        FixtureTurn(prompt: "count them now", reply: "OK count")]
    let shPath = fx.appendingPathComponent("rw-shell.jsonl").path
    try? fixtureJSONL(session: "rw-shell", cwd: "/tmp", turns: shellFixture).write(toFile: shPath, atomically: true, encoding: .utf8)
    let shScreen = "❯ list the files\n\n⏺ OK list\n\n! ls -la\n  ⎿  total 0\n\n⏺ Listed.\n\n! pwd\n  ⎿  /tmp\n\n❯ count them now\n\n⏺ OK count\n\n"
    let wsSh = c.newWorkspace(program: ScreenFixture.script(shScreen, input: "", dir: fx, name: "rw-shell")); made.append(wsSh)
    let pSh = wsSh.panes[0]
    _ = await waitFor(5) { rows(pSh).contains { $0.contains("accept edits") } }
    hookEvent(c, pSh, "SessionStart", session: "rw-shell", transcript: shPath, ["source": "startup"])
    _ = await c.loadTurns(pSh)
    let shMap = c.screenMap(pSh, maxAge: 0)
    func shRow(_ text: String) -> Int { shMap.rows.firstIndex { $0.text.hasPrefix(text) } ?? 0 }
    let ovSh = pSh.view.overlay
    func pill(_ text: String) async -> TurnActionBar? {
        await hover(c, pSh, row: shRow(text))
        ovSh.layoutSubtreeIfNeeded()
        return c.hoveredTurn(pSh) == nil ? nil : ovSh.turnBar
    }
    let one = TurnActionBar.buttonSize.width + 4
    let barLs = await pill("! ls -la")
    r.check("hover on a ! shell command with a reply: ⧉ only, one button wide, at the pane's right edge",
            c.hoveredTurn(pSh) == 2 && barLs.map { !$0.copy.isHidden && $0.edit.isHidden && $0.remove.isHidden
                && $0.frame.width == one && abs($0.frame.maxX - (ovSh.bounds.width - 10)) < 0.5 } ?? false
            && barLs?.copy.toolTip?.contains("Claude’s reply") == true,
            "turn \(c.hoveredTurn(pSh).map { "\($0)" } ?? "nil") \(barLs?.frame ?? .zero)")
    r.check("…its output row is that turn too", await pill("  ⎿  total 0") != nil && c.hoveredTurn(pSh) == 2)
    let barPwd = await pill("! pwd")
    r.check("…without a reply: no pill at all", barPwd == nil && ovSh.turnBand == nil, "turn \(c.hoveredTurn(pSh).map { "\($0)" } ?? "nil")")
    r.check("…and its output row neither (not the turn above it)", await pill("  ⎿  /tmp") == nil)
    let barNext = await pill("❯ count them now")
    r.check("a normal turn after it: ⧉ ✎ × again, three buttons wide", c.hoveredTurn(pSh) == 4
            && barNext.map { !$0.copy.isHidden && !$0.edit.isHidden && !$0.remove.isHidden
                && $0.frame.width == 3 * TurnActionBar.buttonSize.width + 8 && $0.copy.frame.maxX <= $0.edit.frame.minX } ?? false,
            "\(barNext?.frame ?? .zero)")
    let barFirst = await pill("❯ list the files")
    r.check("…and before it (the first turn: ⧉ ✎, no ×)", c.hoveredTurn(pSh) == 1
            && barFirst.map { !$0.edit.isHidden && $0.remove.isHidden && $0.frame.width == 2 * TurnActionBar.buttonSize.width + 6 } ?? false,
            "\(barFirst?.frame ?? .zero)")
    pSh.surface.onMouseExit?()

    // A prompt queued while Claude works: an Esc would send it. Refused before any key, ⌘Z too.
    let r23 = await rewindPane("23", prompts: ["alpha", "beta"], ["working": "footer", "queued": "continue"])
    let o23 = await c.rewind(r23.pane, turnUuid: "rw-23-u1", mode: .remove)
    r.check("queued messages on screen: refused, no key sent", o23 != .done && fakeLog(r23.log).isEmpty, fakeLog(r23.log).joined(separator: "; "))
    r23.pane.busy = true
    let u23 = await c.undo(prompt: "beta", in: r23.pane)
    r.check("…⌘Z too: refused, no Esc, input released", u23 != .done && fakeLog(r23.log).isEmpty && !r23.pane.surface.inputHeld && !r23.pane.busy,
            fakeLog(r23.log).joined(separator: "; "))

    // The menu stays up a while after "Restore conversation": lmux waits, never an Esc after that Return.
    let r24 = await rewindPane("24", prompts: ["alpha", "beta"], ["slow_close_ms": 8000])
    let o24 = await c.rewind(r24.pane, turnUuid: "rw-24-u2", mode: .edit)
    r.check("a slow close after Restore conversation: no key after that Return, rewound",
            o24 == .done && keys(r24.log) == ["esc", "esc", "up", "enter", "enter"] && r24.pane.rewoundFrom == "rw-24-u2",
            "\(o24) " + keys(r24.log).joined(separator: " "))

    // Its tab hidden or closed meanwhile: back out, input released.
    let r25 = await rewindPane("25", prompts: ["alpha", "beta"], ["lag_ms": 400])
    let other = c.newTab(r25.pane, select: false)
    let t25 = Task { await c.rewind(r25.pane, turnUuid: "rw-25-u1", mode: .remove) }
    _ = await waitFor(3) { acts(r25.log).contains("open") }
    if let other { c.selectTab(other) }
    let o25 = await t25.value
    r.check("its tab switched away mid-rewind: backed out, nothing picked, input released",
            other != nil && o25 != .done && !acts(r25.log).contains { $0.hasPrefix("pick") } && !r25.pane.surface.inputHeld,
            "\(o25) " + acts(r25.log).joined(separator: "; "))
    let r26 = await rewindPane("26", prompts: ["alpha", "beta"], ["lag_ms": 400])
    let t26 = Task { await c.rewind(r26.pane, turnUuid: "rw-26-u1", mode: .remove) }
    _ = await waitFor(3) { acts(r26.log).contains("open") }
    if let ws = r26.pane.workspace { c.closeWorkspace(ws) }
    let o26 = await t26.value
    r.check("…its workspace closed mid-rewind: stops, nothing picked", o26 != .done && !acts(r26.log).contains { $0.hasPrefix("pick") },
            "\(o26) " + acts(r26.log).joined(separator: "; "))

    // Find, font size and Clear Screen don't act on a pane lmux is driving.
    let r27 = await rewindPane("27", prompts: ["alpha"])
    c.focus(r27.pane)
    r27.pane.surface.inputHeld = true
    c.menuFind(nil)
    r.check("Find on a held pane: nothing", r27.pane.view.overlay.findBar == nil)
    r27.pane.surface.inputHeld = false

    // The user's own keys, pastes and clicks don't reach the pane while lmux drives the menu.
    let r15 = await rewindPane("15", prompts: ["alpha", "beta"], ["lag_ms": 200])
    c.focus(r15.pane)
    let t15 = Task { await c.rewind(r15.pane, turnUuid: "rw-15-u1", mode: .remove) }
    _ = await waitFor(2) { r15.pane.surface.inputHeld }
    await type("jk\r", window: w)
    r15.pane.surface.paste(nil)
    let o15 = await t15.value
    r.check("keys typed meanwhile are dropped (no j / k / Return reach the menu)", o15 == .done
            && !fakeLog(r15.log).contains("typed") && keys(r15.log) == ["esc", "esc", "top", "enter", "enter", "ctrl-u"],
            keys(r15.log).joined(separator: " "))
    r15.pane.surface.inputHeld = true
    r.check("`lmux send` to a pane lmux is driving: refused", c.send(text: "x", toPane: r15.pane.id, token: c.token(for: r15.pane)) == .paneBusy)
    r15.pane.surface.inputHeld = false

    // 2.1.280's look (prompt bars on a background color, a "✻ … · done Wednesday 11:42 PM" line under
    // every reply, "● high · /effort" right above the input): the pointer on any row of a turn puts
    // the band over that turn alone and the pill on its prompt row, and × acts on that turn. The
    // conversation's first turn has ✎ but no ×.
    let rb = await rewindPane("bars", prompts: ["하이", "흠", "그럼 이건"], ["bars": true])
    rb.pane.hover.readAt = .distantPast
    let mb = c.screenMap(rb.pane, maxAge: 0)
    let textB = mb.rows.map(\.text)
    let headsB = mb.map?.promptHeads() ?? []
    r.check("bars: each prompt bar heads its turn", headsB.map(\.turn) == [1, 2, 3], "\(headsB) \(textB.prefix(20))")
    let ovB = rb.pane.view.overlay
    func rowOf(_ y: CGFloat) -> Int { Int(((y - mb.rows[0].top) / mb.rowHeight).rounded()) }
    for (k, h) in headsB.enumerated() {
        let footer = textB[h.row...].firstIndex { $0.hasPrefix("✻ Crunched") } ?? -1
        var wrong: [String] = []
        for row in [h.row, h.row + 2, footer] {
            await hover(c, rb.pane, row: row)
            _ = await waitFor(1) { c.hoveredTurn(rb.pane) == h.turn }
            ovB.layoutSubtreeIfNeeded()
            let pill = ovB.turnRow.map { rowOf($0.top) }, band = ovB.turnBand.map { (rowOf($0.minY), rowOf($0.maxY) - 1) }
            if c.hoveredTurn(rb.pane) != h.turn || pill != h.row || band?.0 != h.row || band?.1 != footer {
                wrong.append("row \(row): turn \(c.hoveredTurn(rb.pane).map(String.init) ?? "-") pill \(pill.map(String.init) ?? "-") band \(band.map { "\($0.0)..\($0.1)" } ?? "-")")
            }
        }
        let bar = ovB.turnBar
        let wide = (k == 0 ? 2 : 3) * TurnActionBar.buttonSize.width + (k == 0 ? 6 : 8)
        r.check("bars: pointer on turn \(h.turn)'s prompt, reply or footer: that turn, pill on its prompt row \(h.row), band \(h.row)…\(footer)"
                + (k == 0 ? "; the first turn: ⧉ ✎, no ×, two buttons wide" : "; ⧉ ✎ ×"),
                wrong.isEmpty && bar.map { !$0.edit.isHidden && $0.remove.isHidden == (k == 0) && $0.frame.width == wide } ?? false,
                wrong.joined(separator: "; ") + " \(bar?.frame ?? .zero)")
    }
    let effort = textB.firstIndex { $0.contains("● high · /effort") } ?? 0
    await hover(c, rb.pane, row: effort)
    r.check("bars: the “● high · /effort” note above the input is no turn's", c.hoveredTurn(rb.pane) == nil && ovB.turnBand == nil)
    // × on the first turn does nothing even if clicked (it is hidden there).
    await hover(c, rb.pane, row: headsB.first?.row ?? 0)
    _ = await waitFor(1) { c.hoveredTurn(rb.pane) == 1 }
    ovB.turnBar?.remove.performClick()
    r.check("bars: a click on the first turn's hidden × asks nothing", !c.cardShown(rb.pane))
    // × on turn 2 (pointer on its footer line) removes turn 2 and what came after, never turn 1.
    await hover(c, rb.pane, row: (textB.indices.filter { textB[$0].hasPrefix("✻ Crunched") }.dropFirst().first) ?? 0)
    _ = await waitFor(1) { c.hoveredTurn(rb.pane) == 2 }
    ovB.turnBar?.remove.performClick()
    r.check("bars: × from turn 2's footer asks about turn 2", c.cardShown(rb.pane)
            && (rb.pane.view.overlay.card?.message.stringValue ?? "").contains("흠"), rb.pane.view.overlay.card?.message.stringValue ?? "no card")
    _ = await confirmAndWait(rb.pane)
    r.check("bars: …and Claude restores the conversation to before message 2",
            acts(rb.log).contains("restore conversation 2") && !acts(rb.log).contains("restore conversation 1"), acts(rb.log).joined(separator: "; "))
    let tb = await c.loadTurns(rb.pane)
    r.check("bars: only turn 1 left", tb.map(\.prompt) == ["하이"], tb.map(\.prompt).joined(separator: " / "))

    // After `claude --resume`, 2.1.280 draws the replies of the turns a rewind removed under the turn
    // they hung off (no prompt rows): they are no turn's, the turn ends at its "✻ … · done" line.
    let ro = await rewindPane("bars-orphans", prompts: ["하이", "흠"], ["bars": true, "orphans": ["반복 1", "반복 2", "흠"]])
    ro.pane.hover.readAt = .distantPast
    let mo = c.screenMap(ro.pane, maxAge: 0)
    let textO = mo.rows.map(\.text)
    let orphanRows = textO.indices.filter { ["⏺ OK 반복 1", "⏺ OK 반복 2"].contains(textO[$0]) }
    let done1 = textO.firstIndex { $0.hasPrefix("✻ Crunched") } ?? -1
    r.check("resumed with removed turns' replies on screen: those rows are no turn's, turn 1 ends at its done line",
            orphanRows.count == 2 && orphanRows.allSatisfy { mo.map?.turnOfRow[$0] == nil } && mo.map?.block(of: 1, rows: textO)?.last == done1
            && mo.map?.promptHeads().map(\.turn) == [1, 2], "\(mo.map?.turnOfRow.prefix(16) ?? [])")
    await hover(c, ro.pane, row: orphanRows.first ?? 0)
    r.check("…the pointer on one: no pill, no band (not turn 1's)", c.hoveredTurn(ro.pane) == nil && ro.pane.view.overlay.turnBand == nil)
    let head2O = mo.map?.promptHeads().last?.row ?? 0
    await hover(c, ro.pane, row: head2O + 2)
    ro.pane.view.overlay.layoutSubtreeIfNeeded()
    r.check("…turn 2's reply: turn 2, its pill on its own prompt row", c.hoveredTurn(ro.pane) == 2
            && ro.pane.view.overlay.turnRow.map { Int((($0.top - mo.rows[0].top) / mo.rowHeight).rounded()) } == head2O)

    // A prompt on screen that the transcript doesn't have (here: the turn list lacks "흠"): its rows
    // are no turn's, never the turn above (the band over both, × removing both).
    let rm = await rewindPane("bars-missing", prompts: ["하이", "그럼 이건"], menu: ["하이", "흠", "그럼 이건"], ["bars": true])
    rm.pane.hover.readAt = .distantPast
    let mm = c.screenMap(rm.pane, maxAge: 0)
    let textM = mm.rows.map(\.text)
    let lost = textM.firstIndex { $0.hasPrefix("❯ 흠") } ?? 0
    r.check("an unknown prompt row ends the turn above it", mm.map?.turnOfRow[lost] == nil && mm.map?.turnOfRow[lost + 2] == nil
            && mm.map?.turnOfRow[lost - 2] == 1 && mm.map?.block(of: 1, rows: textM)?.last ?? 99 < lost, "\(mm.map?.turnOfRow.prefix(20) ?? [])")
    await hover(c, rm.pane, row: lost + 2)
    r.check("…pointer on its reply: no pill, no band", c.hoveredTurn(rm.pane) == nil && rm.pane.view.overlay.turnBand == nil)
    await hover(c, rm.pane, row: textM.firstIndex { $0.hasPrefix("❯ 그럼 이건") } ?? 0)
    r.check("…the turn below it still gets its own", c.hoveredTurn(rm.pane) == 2)

    // ------------------------------------------------------------ the turn Claude is still on
    func note(_ p: Pane) -> String { p.view.overlay.toast?.text.string ?? "" }
    // Claude writing its reply to the last turn: Esc stops it, then the menu, that turn picked.
    let rl = await rewindPane("run-last", prompts: ["alpha", "beta"], ["working": "footer"])
    let ol = await c.rewind(rl.pane, turnUuid: "rw-run-last-u2", mode: .remove)
    r.check("× on the last turn while Claude works on it: Esc first, then that turn rewound",
            ol == .done && acts(rl.log).first == "interrupt" && acts(rl.log).contains("restore conversation 2") && input(rl.pane) == "",
            "\(ol) " + acts(rl.log).joined(separator: "; ") + " | " + c.actionLog.suffix(3).joined(separator: "; "))
    // Claude asking for a permission on it (its dialog hides the input box): the pill is there (the
    // pane waits on the user), Esc declines it (again if the dialog ignored the first), then the menu.
    let rd = await rewindPane("dialog", prompts: ["alpha", "beta"], ["dialog": true, "dialog_ignore": 1])
    hookEvent(c, rd.pane, "UserPromptSubmit", session: "rw-dialog", ["prompt": "beta"])
    hookEvent(c, rd.pane, "Notification", session: "rw-dialog", ["message": "Claude needs your permission to use Bash",
                                                                 "notification_type": "permission_prompt"])
    _ = await waitFor(2) { if case .needsInput = rd.pane.agent.state { return true }; return false }
    let headD = c.screenMap(rd.pane, maxAge: 0).map?.promptHeads().first { $0.turn == 2 }?.row ?? 0
    await hover(c, rd.pane, row: headD)
    r.check("Claude asking on the last turn: its pill has ✎ ×", c.hoveredTurn(rd.pane) == 2
            && rd.pane.view.overlay.turnBar.map { !$0.edit.isHidden && !$0.remove.isHidden } ?? false)
    rd.pane.view.overlay.turnBar?.edit.performClick()
    let detailD = rd.pane.view.overlay.card?.detail.stringValue ?? ""
    r.check("…the card says Claude's question is declined first", detailD.contains("declined first"), detailD)
    let okD = await confirmAndWait(rd.pane)
    r.check("…✎: Esc (twice: the first ignored) declines it, then rewound, the prompt back, no note, the pane idle",
            okD && acts(rd.log).prefix(2) == ["dialog ignored esc", "decline"] && acts(rd.log).contains("restore conversation 2")
            && input(rd.pane) == "beta" && note(rd.pane).isEmpty && rd.pane.agent.state == .idle,
            acts(rd.log).joined(separator: "; ") + " input=\(input(rd.pane) ?? "nil") note=\(note(rd.pane)) \(rd.pane.agent.state)")
    // The same dialog with no hook saying Claude asks: lmux can't tell what it is, no key.
    let rn = await rewindPane("dialog-nohook", prompts: ["alpha", "beta"], ["dialog": true])
    let on = await c.rewind(rn.pane, turnUuid: "rw-dialog-nohook-u2", mode: .remove)
    r.check("an input box lmux can't find (no hook says Claude asks): refused, no key, the note says so",
            on != .done && fakeLog(rn.log).isEmpty && note(rn.pane) == "Couldn’t rewind: Claude’s input box isn’t on screen.",
            "\(on) note=\(note(rn.pane))")

    // Each refusal says why.
    let r8b = await rewindPane("8b", prompts: ["alpha", "beta"], ["input": "half typed"])
    _ = await c.rewind(r8b.pane, turnUuid: "rw-8b-u2", mode: .remove)
    r.check("note: unsent text in Claude's input", note(r8b.pane) == "Couldn’t rewind: Claude’s input has unsent text. Clear it first.", note(r8b.pane))
    let r23b = await rewindPane("23b", prompts: ["alpha", "beta"], ["working": "footer", "queued": "continue"])
    _ = await c.rewind(r23b.pane, turnUuid: "rw-23b-u2", mode: .remove)
    r.check("note: queued messages", note(r23b.pane) == "Couldn’t rewind: Claude has queued messages. Clear them first.", note(r23b.pane))
    _ = await c.rewind(r23b.pane, turnUuid: "rw-23b-nope", mode: .remove)
    r.check("note: a turn no longer in the session", note(r23b.pane) == "Couldn’t rewind: that message is no longer in Claude’s session.", note(r23b.pane))
    // A turn from before a compaction: no ✎ ×, and a rewind to it (⌘Z's path) says why.
    let rk = await rewindPane("compacted", prompts: ["old topic", "new topic"])
    try? fixtureJSONL(session: "rw-compacted", cwd: "/tmp", turns: [FixtureTurn(prompt: "old topic", reply: "OK"),
                                                                    FixtureTurn(prompt: "new topic", reply: "OK")], compactAfter: 1)
        .write(toFile: rk.path, atomically: true, encoding: .utf8)
    let kTurns2 = await c.loadTurns(rk.pane)
    rk.pane.hover.readAt = .distantPast
    let headK = c.screenMap(rk.pane, maxAge: 0).map?.promptHeads().first { $0.turn == 1 }?.row ?? 0
    await hover(c, rk.pane, row: headK)
    r.check("a turn from before a compaction: Copy only, no ✎ ×", kTurns2.first?.beforeCompaction == true && c.hoveredTurn(rk.pane) == 1
            && rk.pane.view.overlay.turnBar.map { $0.edit.isHidden && $0.remove.isHidden } ?? false,
            "\(kTurns2.map(\.beforeCompaction)) hovered=\(c.hoveredTurn(rk.pane).map(String.init) ?? "nil")")
    c.hideHoverActions(rk.pane)
    let ok2 = await c.rewind(rk.pane, turnUuid: "rw-compacted-u1", mode: .remove)
    r.check("…a rewind to it: refused, no key, the note says it was compacted",
            ok2 != .done && fakeLog(rk.log).isEmpty && note(rk.pane) == LmuxController.compactedNote, note(rk.pane))
    return made
}

/// `lmux-apptest --rewind`: just the rewind checks (App/scripts/apptest.sh runs them in the main pass).
@MainActor
func runRewind() async -> Int32 {
    let r = Report()
    let c = makeController()
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("fixtures", isDirectory: true)
    try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
    _ = await rewindChecks(r, c, c.window, fx: fx)
    return finish(r, c)
}
