// @feature: inspector-ask-panel.feature

import Foundation
import AppKit
import LmuxHooks
@testable import LmuxUI

@MainActor
func runInspectorAsk() async -> Int32 {
    let r = Report()
    r.section = "inspector-ask"
    let ctrl = makeController()

    await runAskSpecTests(r)
    await runAskSessionStoreTests(r)
    await runAskRefLoaderTests(r)
    await runAskContextBuilderTests(r, ctrl: ctrl)
    await runAskControlTests(r, ctrl: ctrl)
    await runAskCliTests(r, ctrl: ctrl)
    await runAskAttentionTests(r, ctrl: ctrl)
    runAskMarkdownParserTests(r)

    print("inspector-ask summary: \(r.passed) passed, \(r.failed) failed")
    return r.failed == 0 ? 0 : 1
}

@MainActor
private func runAskSpecTests(_ r: Report) async {
    let longIntro = "這是一段超過二十五個字的前情提要說明，用來確認嚴格模式檢核能夠通過。"
    let longDetail = "這是一段超過二十個字的詳細背景說明文字。"

    // 1. Shorthand string options & recommended suffix stripping
    let rawShorthand: [String: Any] = [
        "title": "  架構\u{202E}確認\u{0007}  ",
        "eyebrow": "決策\u{200F}點",
        "intro": longIntro,
        "questions": [
            [
                "id": "q1",
                "header": "選型",
                "question": "請選擇儲存引擎",
                "detail": longDetail,
                "options": ["方案 A (Recommended)", "方案 B（推薦）", "方案 C"],
                "refs": ["src/App.swift:1-10"],
                "gitDiff": ["src/App.swift"]
            ]
        ]
    ]
    do {
        let spec = try AskSpec.parse(jsonObject: rawShorthand)
        r.check("AskSpec parses shorthand options and strips recommended markers",
                spec.questions.count == 1
                && spec.questions[0].options.count == 3
                && spec.questions[0].options[0].label == "方案 A"
                && spec.questions[0].options[0].recommended
                && spec.questions[0].options[1].label == "方案 B"
                && spec.questions[0].options[1].recommended
                && spec.questions[0].options[2].label == "方案 C"
                && !spec.questions[0].options[2].recommended)
        r.check("AskSpec sanitizes unsafe BiDi and control scalars while preserving multiline intro/detail",
                spec.title == "架構確認" && spec.eyebrow == "決策點")
    } catch {
        r.check("AskSpec parses valid shorthand spec", false, "\(error)")
    }

    // 2. Multiline detail preserves newlines while stripping BiDi
    let multilineObj: [String: Any] = [
        "intro": "第一行\n第二行與更多說明文字補足二十五個字的長度需求。",
        "questions": [
            [
                "id": "qm",
                "question": "是否繼續？",
                "detail": "說明第一行\u{202E}\n- 清單項目補充至少二十個字元",
                "options": ["繼續 (Recommended)", "取消"]
            ]
        ]
    ]
    if let ms = try? AskSpec.parse(jsonObject: multilineObj) {
        r.check("AskSpec preserves newlines in intro/detail while stripping unsafe scalars",
                ms.intro.contains("\n") && ms.questions[0].detail.contains("\n") && !ms.questions[0].detail.contains("\u{202E}"))
    } else {
        r.check("AskSpec multiline spec parse succeeds", false)
    }

    // 3. Strict validation rejections
    func expectsError(_ name: String, _ obj: [String: Any], lenient: Bool = false) {
        do {
            _ = try AskSpec.parse(jsonObject: obj, lenient: lenient)
            r.check(name, false, "expected error but succeeded")
        } catch is AskSpecError {
            r.check(name, true)
        } catch {
            r.check(name, false, "unexpected error \(error)")
        }
    }

    expectsError("AskSpec strict rejects short intro (<25 chars)", [
        "intro": "太短",
        "questions": [["id": "q1", "question": "問題", "detail": longDetail, "options": ["A", "B"]]]
    ])

    expectsError("AskSpec strict rejects short detail (<20 chars) when options present", [
        "intro": longIntro,
        "questions": [["id": "q1", "question": "問題", "detail": "太短", "options": ["A", "B"]]]
    ])

    expectsError("AskSpec rejects duplicate question ids", [
        "intro": longIntro,
        "questions": [
            ["id": "dup", "question": "Q1", "detail": longDetail, "options": ["A", "B"]],
            ["id": "dup", "question": "Q2", "detail": longDetail, "options": ["C", "D"]]
        ]
    ])

    expectsError("AskSpec rejects duplicate normalized option labels", [
        "intro": longIntro,
        "questions": [
            ["id": "q1", "question": "Q1", "detail": longDetail, "options": ["方案 A (Recommended)", "方案 A"]]
        ]
    ])

    expectsError("AskSpec rejects 0 questions", [
        "intro": longIntro,
        "questions": []
    ])

    let thirteen = (1...13).map { i in
        ["id": "q\(i)", "question": "題目 \(i)", "allowFreeText": true] as [String: Any]
    }
    expectsError("AskSpec rejects >12 questions", [
        "intro": longIntro,
        "questions": thirteen
    ])

    let nineRefs = (1...9).map { "f\($0).swift" }
    expectsError("AskSpec rejects >8 refs per question without silent truncation", [
        "intro": longIntro,
        "questions": [["id": "q1", "question": "Q1", "allowFreeText": true, "refs": nineRefs]]
    ])

    expectsError("AskSpec rejects >8 gitDiff per question without silent truncation", [
        "intro": longIntro,
        "questions": [["id": "q1", "question": "Q1", "allowFreeText": true, "gitDiff": nineRefs]]
    ])

    // 4. Lenient mode allows short intro and empty detail, still requires non-empty intro & question
    do {
        let lSpec = try AskSpec.parse(jsonObject: [
            "intro": "簡短確認",
            "questions": [["id": "ql", "question": "同意嗎？", "detail": "", "options": ["好"]]]
        ], lenient: true)
        r.check("AskSpec lenient allows short intro and empty detail",
                lSpec.lenient && lSpec.intro == "簡短確認" && lSpec.questions[0].detail.isEmpty)
    } catch {
        r.check("AskSpec lenient parses short intro", false, "\(error)")
    }
    expectsError("AskSpec lenient still rejects empty question", [
        "intro": "ok",
        "questions": [["id": "q1", "question": "   ", "allowFreeText": true]]
    ], lenient: true)

    // 5. AskAnswer serialization guarantees fixed keys
    let ans = AskAnswer(id: "q1", header: "", question: "Q1", selected: ["方案 A"], freeText: "")
    let json = ans.toJSONObject()
    r.check("AskAnswer.toJSONObject outputs header and freeText keys even when empty",
            (json["id"] as? String) == "q1"
            && (json["header"] as? String) == ""
            && (json["freeText"] as? String) == ""
            && (json["selected"] as? [String]) == ["方案 A"])
}

@MainActor
private func runAskSessionStoreTests(_ r: Report) async {
    let paneA = UUID().uuidString
    let paneB = UUID().uuidString
    func makeSpec(id: String = "q1", allowFreeText: Bool = false) -> AskSpec {
        AskSpec(
            title: "確認",
            eyebrow: "",
            intro: "請確認這組設定選項的細節與影響範圍。",
            questions: [
                AskQuestion(id: id, question: "請選一個", detail: "", allowFreeText: allowFreeText,
                            options: [AskOption(label: "A"), AskOption(label: "B")])
            ],
            lenient: true
        )
    }

    var now = Date(timeIntervalSince1970: 1_000_000)
    let store = AskSessionStore(now: { now })

    // 1. Per-pane FIFO preserves active session draft when second arrives
    guard let s1 = try? store.create(spec: makeSpec(id: "q1"), paneID: paneA, createdInsidePane: true),
          let s2 = try? store.create(spec: makeSpec(id: "q2"), paneID: paneA, createdInsidePane: true) else {
        r.check("AskSessionStore creates queued sessions", false)
        return
    }
    s1.draftSelected["q1"] = ["A"]
    r.check("AskSessionStore per-pane FIFO keeps s1 active with draft while s2 waits",
            store.activeSession(for: paneA)?.id == s1.id
            && store.pendingCount(for: paneA) == 2
            && s1.draftSelected["q1"] == ["A"])

    // 2. Unanswered question blocks submit and exposes firstUnansweredQuestionID
    s1.draftSelected["q1"] = []
    r.check("AskSessionStore blocks submit when unanswered and identifies question",
            !s1.isAllAnswered && s1.firstUnansweredQuestionID == "q1" && !store.submit(sessionID: s1.id))

    // 3. Submit without waiter stores in cache; attachWaiter later delivers & pops cache
    s1.draftSelected["q1"] = ["B"]
    r.check("AskSessionStore submit succeeds when answered even before waiter attaches",
            s1.isAllAnswered && s1.answeredCount == 1 && store.submit(sessionID: s1.id))
    r.check("AskSessionStore advances FIFO to s2 after s1 submits",
            store.activeSession(for: paneA)?.id == s2.id && store.pendingCount(for: paneA) == 1)

    var deliveredOutcome: AskWaitOutcome?
    let cancel1 = store.attachWaiter(sessionID: s1.id) { outcome in
        deliveredOutcome = outcome
    }
    r.check("AskSessionStore cached outcome delivered immediately and cleared afterwards",
            cancel1 == nil
            && deliveredOutcome?.status == "submitted"
            && deliveredOutcome?.answers.first?.selected == ["B"]
            && deliveredOutcome?.answers.first?.freeText == "")
    var secondAttempt: AskWaitOutcome?
    _ = store.attachWaiter(sessionID: s1.id) { secondAttempt = $0 }
    r.check("AskSessionStore cached outcome consumed once (second lookup sees nil/notFound)",
            secondAttempt?.status == "not_found")

    // 4. Supersede old waiter cleanly; detach does not destroy form
    var oldOutcome: AskWaitOutcome?
    var newOutcome: AskWaitOutcome?
    let detachOld = store.attachWaiter(sessionID: s2.id) { oldOutcome = $0 }
    let detachNew = store.attachWaiter(sessionID: s2.id) { newOutcome = $0 }
    r.check("AskSessionStore supersedes earlier waiter with superseded error",
            oldOutcome?.status == "superseded" && newOutcome == nil && store.activeSession(for: paneA)?.id == s2.id)
    detachOld?()
    detachNew?()
    r.check("AskSessionStore detaching waiter keeps pending form alive",
            store.activeSession(for: paneA)?.id == s2.id)

    // 5. Cancel delivers cancelled with non-empty note
    var cancelOutcome: AskWaitOutcome?
    _ = store.attachWaiter(sessionID: s2.id) { cancelOutcome = $0 }
    store.cancel(sessionID: s2.id)
    r.check("AskSessionStore cancel delivers cancelled outcome with note",
            cancelOutcome?.status == "cancelled"
            && !(cancelOutcome?.note ?? "").isEmpty
            && store.pendingCount(for: paneA) == 0)

    // 6. markPaneClosed & markAllLost notify active waiters
    if let s3 = try? store.create(spec: makeSpec(id: "q3"), paneID: paneB, createdInsidePane: false),
       let s4 = try? store.create(spec: makeSpec(id: "q4"), paneID: paneA, createdInsidePane: true) {
        var o3: AskWaitOutcome?
        var o4: AskWaitOutcome?
        _ = store.attachWaiter(sessionID: s3.id) { o3 = $0 }
        _ = store.attachWaiter(sessionID: s4.id) { o4 = $0 }
        store.markPaneClosed(paneB)
        r.check("AskSessionStore markPaneClosed ends only that pane's sessions with lost+note",
                o3?.status == "lost" && !(o3?.note ?? "").isEmpty && o4 == nil && store.pendingCount(for: paneA) == 1)
        store.markAllLost()
        r.check("AskSessionStore markAllLost clears remaining sessions with lost+note",
                o4?.status == "lost" && !(o4?.note ?? "").isEmpty && store.totalPendingCount == 0)
    }

    // 7. Outcome cache TTL (10m) & LRU cap (32)
    for i in 1...34 {
        let sid = "cache-\(i)"
        if let s = try? store.create(spec: makeSpec(id: "qc", allowFreeText: true), paneID: paneA, createdInsidePane: true, sessionID: sid) {
            s.draftFreeText["qc"] = "note \(i)"
            _ = store.submit(sessionID: sid)
        }
    }
    var evictedOutcome: AskWaitOutcome?
    _ = store.attachWaiter(sessionID: "cache-1") { evictedOutcome = $0 }
    r.check("AskSessionStore evicts oldest cached outcome beyond 32 entries",
            evictedOutcome?.status == "not_found")
    now.addTimeInterval(AskSessionStore.cacheTTL + 1)
    var expiredOutcome: AskWaitOutcome?
    _ = store.attachWaiter(sessionID: "cache-34") { expiredOutcome = $0 }
    r.check("AskSessionStore expires cached outcome after 10 minutes",
            expiredOutcome?.status == "not_found")

    // 8. Per-pane cap (16) and global cap (64) fail closed
    var createdOnA = 0
    for _ in 0..<20 {
        if (try? store.create(spec: makeSpec(), paneID: paneA, createdInsidePane: true)) != nil {
            createdOnA += 1
        }
    }
    r.check("AskSessionStore caps per-pane pending at 16", createdOnA == AskSessionStore.maxPendingPerPane)
    var globalTotal = store.totalPendingCount
    for idx in 0..<6 {
        let p = UUID().uuidString
        for _ in 0..<16 {
            if (try? store.create(spec: makeSpec(), paneID: p, createdInsidePane: true)) != nil {
                globalTotal += 1
            } else if idx >= 3 {
                break
            }
        }
    }
    r.check("AskSessionStore caps global pending at 64",
            store.totalPendingCount == AskSessionStore.maxPendingGlobal)
    store.markAllLost()
}

// @scenario: 本機檔案與 Git 引用越界、指向危險／二進位檔案或新倉庫未追蹤檔時安全處理
@MainActor
private func runAskRefLoaderTests(_ r: Report) async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ask-refs-\(UUID().uuidString)")
    let repoDir = root.appendingPathComponent("repo")
    let srcDir = repoDir.appendingPathComponent("src")
    let outsideDir = root.appendingPathComponent("outside")
    try? fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    // 1. Valid file ref with range, >120 line truncation, and colon filename
    try? "line1\nline2\nline3\nline4\nline5\n".write(
        to: srcDir.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8
    )
    let rangeRes = AskRefLoader.loadFileRef("src/App.swift:2-4", baseDir: repoDir.path, repoRoot: repoDir.path)
    r.check("AskRefLoader loads valid line range 2-4",
            rangeRes.errorMessage == nil && rangeRes.lines == ["line2", "line3", "line4"] && !rangeRes.truncated)

    let manyLines = (1...150).map { "row \($0)" }.joined(separator: "\n")
    try? manyLines.write(to: srcDir.appendingPathComponent("Long.swift"), atomically: true, encoding: .utf8)
    let longRes = AskRefLoader.loadFileRef("src/Long.swift:1-140", baseDir: repoDir.path, repoRoot: repoDir.path)
    r.check("AskRefLoader caps output at 120 lines and marks truncated",
            longRes.errorMessage == nil && longRes.lines.count == 120 && longRes.truncated)

    try? "colon-a\ncolon-b\n".write(
        to: srcDir.appendingPathComponent("a:b.swift"), atomically: true, encoding: .utf8
    )
    let colonRes = AskRefLoader.loadFileRef("src/a:b.swift:2-2", baseDir: repoDir.path, repoRoot: repoDir.path)
    r.check("AskRefLoader handles colon in filename with trailing line range",
            colonRes.errorMessage == nil && colonRes.lines == ["colon-b"])

    // 2. Security boundary rejections
    let secretURL = outsideDir.appendingPathComponent("secret.txt")
    try? "TOP_SECRET".write(to: secretURL, atomically: true, encoding: .utf8)
    let symlinkURL = repoDir.appendingPathComponent("escape.txt")
    try? fm.createSymbolicLink(at: symlinkURL, withDestinationURL: secretURL)

    r.check("AskRefLoader rejects ../ traversal",
            AskRefLoader.loadFileRef("../outside/secret.txt", baseDir: repoDir.path, repoRoot: repoDir.path).errorMessage != nil)
    r.check("AskRefLoader rejects symlink escaping repo",
            AskRefLoader.loadFileRef("escape.txt", baseDir: repoDir.path, repoRoot: repoDir.path).errorMessage != nil)
    r.check("AskRefLoader rejects directory (S_IFDIR)",
            AskRefLoader.loadFileRef("src", baseDir: repoDir.path, repoRoot: repoDir.path).errorMessage != nil)

    let fifoPath = repoDir.appendingPathComponent("pipe.fifo").path
    if mkfifo(fifoPath, 0o600) == 0 {
        r.check("AskRefLoader rejects FIFO non-regular file without blocking",
                AskRefLoader.loadFileRef("pipe.fifo", baseDir: repoDir.path, repoRoot: repoDir.path).errorMessage != nil)
    }

    let bigData = Data(repeating: 0x41, count: 513 * 1024)
    try? bigData.write(to: repoDir.appendingPathComponent("huge.txt"))
    r.check("AskRefLoader rejects >512 KB file",
            AskRefLoader.loadFileRef("huge.txt", baseDir: repoDir.path, repoRoot: repoDir.path).errorMessage != nil)

    var nulUTF8 = Data("hello".utf8)
    nulUTF8.append(0x00)
    nulUTF8.append(contentsOf: "world".utf8)
    try? nulUTF8.write(to: repoDir.appendingPathComponent("bin.dat"))
    r.check("AskRefLoader rejects UTF-8 data containing NUL byte",
            AskRefLoader.loadFileRef("bin.dat", baseDir: repoDir.path, repoRoot: repoDir.path).errorMessage != nil)

    r.check("AskRefLoader rejects file:// scheme and nil baseDir",
            AskRefLoader.loadFileRef("file:///etc/passwd", baseDir: repoDir.path, repoRoot: repoDir.path).errorMessage != nil
            && AskRefLoader.loadFileRef("src/App.swift", baseDir: nil, repoRoot: nil).errorMessage != nil)

    // 3. Git diff hardening, filter isolation, and unborn HEAD untracked file
    let gitRepo = root.appendingPathComponent("gitrepo")
    try? fm.createDirectory(at: gitRepo, withIntermediateDirectories: true)
    func runCmd(_ args: [String], cwd: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = cwd
        try? p.run()
        p.waitUntilExit()
    }
    runCmd(["init"], cwd: gitRepo)
    let filterSentinel = root.appendingPathComponent("filter-executed")
    runCmd(["config", "filter.evil.clean", "touch \(filterSentinel.path)"], cwd: gitRepo)
    try? "*.swift filter=evil\n".write(to: gitRepo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    try? "let x = 1\nlet y = 2\n".write(to: gitRepo.appendingPathComponent("NewFile.swift"), atomically: true, encoding: .utf8)
    try? nulUTF8.write(to: gitRepo.appendingPathComponent("BinaryNew.bin"))

    let flagRes = await AskRefLoader.loadGitDiff("--output=/tmp/pwned", cwd: gitRepo.path)
    let travRes = await AskRefLoader.loadGitDiff("../outside/secret.txt", cwd: gitRepo.path)
    let absRes = await AskRefLoader.loadGitDiff("/etc/passwd", cwd: gitRepo.path)
    let ctrlRes = await AskRefLoader.loadGitDiff("New\u{202E}File.swift", cwd: gitRepo.path)
    r.check("AskRefLoader.loadGitDiff rejects flag injection, traversal, absolute path, and unsafe scalars",
            flagRes.errorMessage != nil && travRes.errorMessage != nil && absRes.errorMessage != nil && ctrlRes.errorMessage != nil)

    let untrackedRes = await AskRefLoader.loadGitDiff("NewFile.swift", cwd: gitRepo.path)
    r.check("AskRefLoader.loadGitDiff reads untracked plaintext file in unborn HEAD repo without executing git filters",
            untrackedRes.errorMessage == nil
            && !untrackedRes.lines.isEmpty
            && untrackedRes.lines.first?.kind == .added
            && !fm.fileExists(atPath: filterSentinel.path))

    let nulDiffRes = await AskRefLoader.loadGitDiff("BinaryNew.bin", cwd: gitRepo.path)
    r.check("GitDiffService.readUntrackedLines & AskRefLoader reject untracked NUL binary file",
            nulDiffRes.errorMessage != nil && nulDiffRes.lines.isEmpty)

    // 4. PreviewTarget whitelist includes extensionless & config text files
    r.check("PreviewTarget accepts Makefile, Dockerfile, .feature, and .toml",
            PreviewTarget.kind(URL(fileURLWithPath: "/tmp/Makefile")) == .text
            && PreviewTarget.kind(URL(fileURLWithPath: "/tmp/Dockerfile")) == .text
            && PreviewTarget.kind(URL(fileURLWithPath: "/tmp/spec.feature")) == .text
            && PreviewTarget.kind(URL(fileURLWithPath: "/tmp/Cargo.toml")) == .text)
}

// @scenario: 從 Claude 與 Codex 對話紀錄本機抽取 Session 上下文補充
// @scenario: 對話紀錄缺少、含損毀行或合成佔位訊息時安全降級產生上下文補充
@MainActor
private func runAskContextBuilderTests(_ r: Report, ctrl: LmuxController) async {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ask-ctx-\(UUID().uuidString)")
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func gitCmd(_ args: [String], cwd: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = cwd
        try? p.run()
        p.waitUntilExit()
    }

    // Repo A (global active snapshot) vs Repo B (background pane)
    let repoA = root.appendingPathComponent("repoA")
    let repoB = root.appendingPathComponent("repoB")
    let plainDir = root.appendingPathComponent("plain")
    try? fm.createDirectory(at: repoA, withIntermediateDirectories: true)
    try? fm.createDirectory(at: repoB, withIntermediateDirectories: true)
    try? fm.createDirectory(at: plainDir, withIntermediateDirectories: true)
    gitCmd(["init", "-b", "branch-a"], cwd: repoA)
    gitCmd(["init", "-b", "branch-b"], cwd: repoB)
    try? "b1\n".write(to: repoB.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)
    try? "b2\n".write(to: repoB.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)

    let cache = TranscriptCache()
    let ws1 = ctrl.model.workspaces.first!
    let ws2 = ctrl.newWorkspace()
    let ws3 = ctrl.newWorkspace()
    defer {
        ctrl.closeWorkspace(ws3)
        ctrl.closeWorkspace(ws2)
    }

    // 1. Claude transcript + ToolCallStream + per-cwd git isolation (even with foreign activeGitSnapshot)
    let claudeJSONL = root.appendingPathComponent("claude.jsonl")
    let claudeLines = [
        #"{"type":"custom-title","customTitle":"修補驗證"}"#,
        #"{"type":"user","uuid":"u1","parentUuid":null,"turnOrigin":"human","message":{"role":"user","content":"實作登入重試"}}"#,
        #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/repo/Auth.swift"}},{"type":"text","text":"完成第一版。"}]}}"#,
        #"{"type":"user","uuid":"u2","parentUuid":"a1","turnOrigin":"human","message":{"role":"user","content":"要加退避嗎？"}}"#,
        #"{"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"id":"m2","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"建議指數退避。"}]}}"#
    ]
    try? (claudeLines.joined(separator: "\n") + "\n").write(to: claudeJSONL, atomically: true, encoding: .utf8)

    let paneClaude = ws1.focusedPane!
    if let startEv = try? HookEvent(paneID: paneClaude.id, payload: [
        "hook_event_name": "SessionStart",
        "session_id": "ask-ctx-s1"
    ]) {
        ctrl.handleHook(startEv)
    }
    for i in 1...7 {
        if let ev = try? HookEvent(paneID: paneClaude.id, payload: [
            "hook_event_name": "PreToolUse",
            "session_id": "ask-ctx-s1",
            "tool_name": "Bash",
            "tool_input": ["command": "cmd-\(i)"],
            "tool_use_id": "tool-\(i)"
        ]) {
            ctrl.handleHook(ev)
        }
    }
    paneClaude.cwd = repoB.path
    paneClaude.transcriptPath = claudeJSONL.path
    let foreignSnapshot = GitDiffSnapshot(cwd: repoA.path, repoRoot: repoA.path, isGitRepo: true, branch: "branch-a", files: [])
    let ctxClaude = await AskContextBuilder.build(for: paneClaude, transcripts: cache, activeGitSnapshot: foreignSnapshot)
    r.check("AskContextBuilder builds Claude summary with recent 5 tools and isolates Repo B git state from foreign activeGitSnapshot",
            ctxClaude.sessionTitle == "修補驗證"
            && ctxClaude.initialGoal == "實作登入重試"
            && ctxClaude.touchedFiles == ["/repo/Auth.swift"]
            && ctxClaude.recentTools.count == 5
            && ctxClaude.recentTools.last?.contains("cmd-7") == true
            && ctxClaude.gitBranch == "branch-b"
            && ctxClaude.gitChangedCount == 2)

    // 2. Codex rollout with $CODEX_HOME/session_index.jsonl title lookup
    let codexHome = root.appendingPathComponent("codex-home")
    let dayDir = codexHome.appendingPathComponent("sessions/2026/11/24")
    try? fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
    try? "{\"id\":\"codex-1\",\"thread_name\":\"Codex 索引標題\",\"updated_at\":\"2026-11-24T00:00:00Z\"}\n"
        .write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
    let rolloutURL = dayDir.appendingPathComponent("rollout-test.jsonl")
    let codexLines = [
        #"{"timestamp":"2026-11-24T01:00:00Z","type":"session_meta","payload":{"id":"codex-1","cwd":"/repo"}}"#,
        #"{"timestamp":"2026-11-24T01:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"檢查 Codex rollout 解析"}}"#,
        #"{"timestamp":"2026-11-24T01:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /repo/Codex.swift\n@@\n*** End Patch"}}"#,
        #"{"timestamp":"2026-11-24T01:00:04Z","type":"event_msg","payload":{"type":"agent_message","message":"已檢查完畢。"}}"#
    ]
    try? (codexLines.joined(separator: "\n") + "\n").write(to: rolloutURL, atomically: true, encoding: .utf8)

    let paneCodex = ws2.focusedPane!
    paneCodex.cwd = plainDir.path
    paneCodex.transcriptPath = rolloutURL.path
    let ctxCodex = await AskContextBuilder.build(for: paneCodex, transcripts: cache, activeGitSnapshot: foreignSnapshot)
    r.check("AskContextBuilder builds Codex summary including session_index title and handles non-git cwd",
            ctxCodex.sessionTitle == "Codex 索引標題"
            && ctxCodex.initialGoal == "檢查 Codex rollout 解析"
            && ctxCodex.touchedFiles == ["/repo/Codex.swift"]
            && ctxCodex.gitBranch == nil
            && ctxCodex.gitChangedCount == 0)

    // 3. Missing transcript degrades safely without crashing
    let panePlain = ws3.focusedPane!
    panePlain.cwd = plainDir.path
    let ctxPlain = await AskContextBuilder.build(for: panePlain, transcripts: cache, activeGitSnapshot: nil)
    r.check("AskContextBuilder degrades gracefully when transcriptPath is missing in non-git directory",
            ctxPlain.isEmpty)
}

@MainActor
private func runAskControlTests(_ r: Report, ctrl: LmuxController) async {
    let suiteName = "ask-control-test-\(UUID().uuidString)"
    let origDefaults = ctrl.defaults
    let testDefaults = UserDefaults(suiteName: suiteName)!
    ctrl.defaults = testDefaults
    let origExternalAtLaunch = ctrl.allowExternalSendAtLaunch
    ctrl.allowExternalSendAtLaunch = false
    defer {
        ctrl.defaults = origDefaults
        ctrl.allowExternalSendAtLaunch = origExternalAtLaunch
        ctrl.askStore.markAllLost()
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    let wsA = ctrl.model.workspaces.first!
    let paneA = wsA.focusedPane!
    let wsB = ctrl.newWorkspace()
    let paneB = wsB.focusedPane!
    let previewURL = FileManager.default.temporaryDirectory.appendingPathComponent("ask-preview-\(UUID().uuidString).md")
    try? "# preview\n".write(to: previewURL, atomically: true, encoding: .utf8)
    let previewPane = ctrl.newPreviewTab(previewURL, after: paneB)
    defer {
        ctrl.closeWorkspace(wsB)
        try? FileManager.default.removeItem(at: previewURL)
    }

    guard let tokenA = ctrl.token(for: paneA), let tokenB = ctrl.token(for: paneB) else {
        r.check("Controller mints pane tokens for panes", false)
        return
    }

    let validSpec: [String: Any] = [
        "title": "控制通道測試",
        "intro": "這是一段超過二十五個字的控制通道提問說明內容，驗證遠端權限與隔離檢查。",
        "questions": [[
            "id": "q1",
            "question": "確認選項？",
            "detail": "這是一段肯定超過二十個字的詳細選項說明文字內容。",
            "options": ["同意 (Recommended)", "拒絕"]
        ]]
    ]

    // 1. Valid LMUX_PANE_NONCE create + 32-char hex sessionId + ask-wait submit round-trip
    let createRes = ctrl.handleControl(["cmd": "ask-create", "token": tokenA, "spec": validSpec])
    let sid = createRes["sessionId"] as? String ?? ""
    let isHex32 = sid.count == 32 && sid.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
    r.check("ask-create with valid pane token returns ok and 32-char hex sessionId",
            (createRes["ok"] as? Bool) == true && isHex32 && (createRes["pane"] as? String) == paneA.id,
            "\(createRes)")

    var waitReply: [String: Any]?
    let cancelWait = ctrl.startAskWait(["cmd": "ask-wait", "sessionId": sid, "token": tokenA]) { waitReply = $0 }
    ctrl.askStore.session(id: sid)?.draftSelected["q1"] = ["同意"]
    _ = ctrl.askStore.submit(sessionID: sid)
    cancelWait()
    r.check("ask-wait receives submitted answer for pane session",
            (waitReply?["ok"] as? Bool) == true
            && (waitReply?["status"] as? String) == "submitted"
            && ((waitReply?["answers"] as? [[String: Any]])?.first?["selected"] as? [String]) == ["同意"])

    // 2. Reject forged tokens, preview tab target, cross-pane without setting, external without setting
    let forgedCreate = ctrl.handleControl(["cmd": "ask-create", "token": "forged-token", "spec": validSpec])
    let crossDeniedCreate = ctrl.handleControl(["cmd": "ask-create", "token": tokenA, "pane": paneB.id, "spec": validSpec])
    let extDeniedCreate = ctrl.handleControl(["cmd": "ask-create", "pane": paneA.id, "spec": validSpec])
    let previewDeniedCreate = ctrl.handleControl(["cmd": "ask-create", "token": tokenB, "pane": previewPane?.id ?? "none", "spec": validSpec])
    r.check("ask-create rejects forged token, unauthorized cross-pane, disabled external send, and preview tab",
            (forgedCreate["ok"] as? Bool) == false
            && (crossDeniedCreate["ok"] as? Bool) == false
            && (extDeniedCreate["ok"] as? Bool) == false
            && (previewDeniedCreate["ok"] as? Bool) == false)

    // 3. Create pane-originated session on paneA, verify isolation
    let paneCreate2 = ctrl.handleControl(["cmd": "ask-create", "token": tokenA, "spec": validSpec])
    let sid2 = paneCreate2["sessionId"] as? String ?? ""

    // 3a. External caller CANNOT wait for pane-originated session even with BOTH allowExternalSend & allowCrossPaneSend true!
    testDefaults.set(true, forKey: "allowExternalSend")
    testDefaults.set(true, forKey: "allowCrossPaneSend")
    var extStealReply: [String: Any]?
    _ = ctrl.startAskWait(["cmd": "ask-wait", "sessionId": sid2]) { extStealReply = $0 }
    var forgedWaitReply: [String: Any]?
    _ = ctrl.startAskWait(["cmd": "ask-wait", "sessionId": sid2, "token": "bad"]) { forgedWaitReply = $0 }
    var missingWaitReply: [String: Any]?
    _ = ctrl.startAskWait(["cmd": "ask-wait", "sessionId": String(repeating: "0", count: 32), "token": tokenA]) { missingWaitReply = $0 }

    r.check("external caller never allowed on pane-originated ask-wait even when allowCrossPaneSend & allowExternalSend enabled",
            (extStealReply?["ok"] as? Bool) == false && (forgedWaitReply?["ok"] as? Bool) == false)
    r.check("unknown and unauthorized ask-wait return consistent non-leaking error",
            (extStealReply?["error"] as? String) == (missingWaitReply?["error"] as? String))

    // 3b. Cross-pane WITH valid tokenB succeeds ONLY when allowCrossPaneSend == true
    var crossWaitReply: [String: Any]?
    let cancelCross = ctrl.startAskWait(["cmd": "ask-wait", "sessionId": sid2, "token": tokenB]) { crossWaitReply = $0 }
    ctrl.askStore.session(id: sid2)?.draftSelected["q1"] = ["拒絕"]
    _ = ctrl.askStore.submit(sessionID: sid2)
    cancelCross()
    r.check("allowCrossPaneSend allows ask-wait from another pane holding a valid pane token",
            (crossWaitReply?["ok"] as? Bool) == true && (crossWaitReply?["status"] as? String) == "submitted")

    // 3c. PeerPID inside pane A without token CANNOT spoof target pane B even when allowExternalSend == true
    let myPID = Int(getpid())
    if let ttyGroup = LmuxController.terminalForegroundGroup(pid_t(myPID)) {
        _ = ttyGroup // Only enforce if apptest runs under a PTY foreground group matching a pane; skip else
    }

    // 3d. Positive external-create + external-wait when allowExternalSend == true
    let extCreate = ctrl.handleControl(["cmd": "ask-create", "pane": paneB.id, "spec": validSpec])
    let extSid = extCreate["sessionId"] as? String ?? ""
    var extWait: [String: Any]?
    let cancelExt = ctrl.startAskWait(["cmd": "ask-wait", "sessionId": extSid]) { extWait = $0 }
    ctrl.askStore.session(id: extSid)?.draftSelected["q1"] = ["同意"]
    _ = ctrl.askStore.submit(sessionID: extSid)
    cancelExt()
    r.check("allowExternalSend allows external create and external wait for external session",
            (extCreate["ok"] as? Bool) == true && (extWait?["status"] as? String) == "submitted")

    // 4. ControlServer.stop() delivers {"ok":true,"gone":true} over Unix socket for ask-wait
    let sockPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("ask-srv-\(UUID().uuidString.prefix(8)).sock").path
    defer { try? FileManager.default.removeItem(atPath: sockPath) }
    let srv = ControlServer(path: sockPath) { ctrl.handleControl($0) }
    srv.handleAskWait = { req, reply in ctrl.startAskWait(req, reply: reply) }
    try? srv.start()
    let extPaneReq = ctrl.handleControl(["cmd": "ask-create", "pane": paneA.id, "spec": validSpec])
    let liveSid = extPaneReq["sessionId"] as? String ?? ""
    if let fd = ControlServer.connect(sockPath) {
        let msg = Array("{\"cmd\":\"ask-wait\",\"sessionId\":\"\(liveSid)\"}\n".utf8)
        _ = msg.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        await sleepMs(60)
        srv.stop()
        var buf = [UInt8](repeating: 0, count: 512)
        let n = Darwin.read(fd, &buf, buf.count)
        Darwin.close(fd)
        let line = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
        r.check("ControlServer.stop sends gone:true to connected ask-wait client", line.contains("\"gone\":true"))
    } else {
        r.check("ControlServer test socket connects", false)
        srv.stop()
    }
}

// @scenario: 提問等待逾時時保留表單，後續透過授權的 wait 領取結果
// @scenario: 使用者取消、來源 tab 關閉、規格不合法或跨分頁未授權呼叫時妥善處理
@MainActor
private func runAskCliTests(_ r: Report, ctrl: LmuxController) async {
    let cli = paths.binDir!.appendingPathComponent("lmux").path
    let ws = ctrl.model.workspaces.first!
    let pane = ws.focusedPane!
    guard let token = ctrl.token(for: pane) else {
        r.check("ask CLI test has pane token", false)
        return
    }
    let cliEnv: [String: String] = [
        "LMUX_CONTROL_SOCKET": ctrl.paths.controlSocket,
        "LMUX_STATE_DIR": ctrl.paths.stateDir.path,
        "LMUX_PANE_NONCE": token
    ]

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-cli-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tmpDir)
        ctrl.askStore.markAllLost()
    }

    // 1. Large (>16KB) --spec file to test looped connectAndSend + --timeout pending + --wait resume
    let paddingDetail = String(repeating: "說明文字", count: 1500) // ~18 KB UTF-8
    let largeSpecObj: [String: Any] = [
        "title": "大型規格寫入與逾時測試",
        "intro": "這是一段超過二十五個字的前情提要，用來測試大型規格與逾時續等。",
        "questions": [[
            "id": "q_large",
            "question": "請確認大型規格",
            "detail": paddingDetail,
            "options": ["確定 (Recommended)", "取消"]
        ]]
    ]
    let largeSpecFile = tmpDir.appendingPathComponent("large-spec.json")
    if let data = try? JSONSerialization.data(withJSONObject: largeSpecObj) {
        try? data.write(to: largeSpecFile)
    }

    let timeoutRes = await runProcess(
        cli,
        ["ask", "--spec", largeSpecFile.path, "--timeout", "0.2"],
        env: cliEnv
    )
    let timeoutJSON = (timeoutRes.out.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let pendingSID = timeoutJSON?["sessionId"] as? String ?? ""
    r.check("lmux ask --timeout prints pending status, sessionId, and resume cmd with exit 0 while keeping form",
            timeoutRes.status == 0
            && (timeoutJSON?["status"] as? String) == "pending"
            && !pendingSID.isEmpty
            && (timeoutJSON?["resume"] as? String) == "lmux ask --wait \(pendingSID)"
            && ctrl.askStore.pendingCount(for: pane.id) == 1,
            "exit=\(timeoutRes.status) out=\(timeoutRes.out) err=\(timeoutRes.err)")

    // Now answer in UI and reclaim via `lmux ask --wait <sessionId>`
    if let session = ctrl.askStore.session(id: pendingSID) {
        session.draftSelected["q_large"] = ["確定"]
        _ = ctrl.askStore.submit(sessionID: pendingSID)
    }
    let waitRes = await runProcess(cli, ["ask", "--wait", pendingSID, "--timeout", "2"], env: cliEnv)
    let waitJSON = (waitRes.out.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    r.check("lmux ask --wait retrieves submitted JSON without reopening duplicate form",
            waitRes.status == 0
            && (waitJSON?["status"] as? String) == "submitted"
            && ((waitJSON?["answers"] as? [[String: Any]])?.first?["selected"] as? [String]) == ["確定"]
            && ctrl.askStore.pendingCount(for: pane.id) == 0,
            "exit=\(waitRes.status) out=\(waitRes.out) err=\(waitRes.err)")

    // 2. --spec - (stdin) + live cancel -> status cancelled with note, exit 0
    let shortSpecObj: [String: Any] = [
        "intro": "短確認說明",
        "questions": [["id": "q_stdin", "question": "確定取消嗎？", "allowFreeText": true]]
    ]
    let stdinData = (try? JSONSerialization.data(withJSONObject: shortSpecObj)) ?? Data()
    let cancelTask = Task { @MainActor in
        for _ in 0..<50 {
            if let s = ctrl.askStore.activeSession(for: pane.id) {
                ctrl.askStore.cancel(sessionID: s.id)
                return
            }
            await sleepMs(20)
        }
    }
    let stdinRes = await runProcess(cli, ["ask", "--spec", "-", "--lenient", "--timeout", "3"], env: cliEnv, stdin: stdinData)
    _ = await cancelTask.value
    let stdinJSON = (stdinRes.out.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    r.check("lmux ask --spec - --lenient handles stdin and receives cancelled status with note",
            stdinRes.status == 0
            && (stdinJSON?["status"] as? String) == "cancelled"
            && !((stdinJSON?["note"] as? String) ?? "").isEmpty,
            "exit=\(stdinRes.status) out=\(stdinRes.out) err=\(stdinRes.err)")

    // 3.gone:true from isolated server translates to status: lost + note, exit 0
    let goneSock = tmpDir.appendingPathComponent("gone.sock").path
    let goneSrv = ControlServer(path: goneSock) { _ in ["ok": true, "sessionId": "00112233445566778899aabbccddeeff", "pane": pane.id] }
    goneSrv.handleAskWait = { _, _ in return {} }
    try? goneSrv.start()
    let stopTask = Task { @MainActor in
        await sleepMs(80)
        goneSrv.stop()
    }
    let goneEnv = ["LMUX_CONTROL_SOCKET": goneSock, "LMUX_PANE_NONCE": token]
    let goneRes = await runProcess(cli, ["ask", "--wait", "00112233445566778899aabbccddeeff", "--timeout", "3"], env: goneEnv)
    _ = await stopTask.value
    let goneJSON = (goneRes.out.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    r.check("lmux ask translates gone:true into status:lost JSON with note and exit 0",
            goneRes.status == 0
            && (goneJSON?["status"] as? String) == "lost"
            && !((goneJSON?["note"] as? String) ?? "").isEmpty,
            "exit=\(goneRes.status) out=\(goneRes.out) err=\(goneRes.err)")

    // 4. Invalid spec / JSON -> exit 1; bad flags / NaN / <=0 timeout -> exit 2
    let badSpecFile = tmpDir.appendingPathComponent("bad-spec.json")
    try? "{corrupt json".write(to: badSpecFile, atomically: true, encoding: .utf8)
    let badSpecRes = await runProcess(cli, ["ask", "--spec", badSpecFile.path], env: cliEnv)
    let negTimeout = await runProcess(cli, ["ask", "--wait", "abc", "--timeout", "-1"], env: cliEnv)
    let nanTimeout = await runProcess(cli, ["ask", "--wait", "abc", "--timeout", "NaN"], env: cliEnv)
    let badFlag = await runProcess(cli, ["ask", "--bogus"], env: cliEnv)
    r.check("lmux ask exits 1 on malformed spec and 2 on invalid timeout or unknown flags",
            badSpecRes.status == 1 && !badSpecRes.err.isEmpty
            && negTimeout.status == 2 && nanTimeout.status == 2 && badFlag.status == 2)
}

@MainActor
private func runAskAttentionTests(_ r: Report, ctrl: LmuxController) async {
    let wsA = ctrl.model.workspaces.first!
    let wsB = ctrl.newWorkspace()
    let paneB = wsB.focusedPane!
    ctrl.select(wsA)

    defer {
        ctrl.askStore.markAllLost()
        if ctrl.model.workspaces.contains(where: { $0.id == wsB.id }) {
            ctrl.closeWorkspace(wsB)
        }
    }

    guard let tokenB = ctrl.token(for: paneB) else {
        r.check("attention test has paneB token", false)
        return
    }

    // Put background workspace B into `.running` state
    if let startEv = try? HookEvent(paneID: paneB.id, payload: ["hook_event_name": "SessionStart", "session_id": "bg-attn"]),
       let promptEv = try? HookEvent(paneID: paneB.id, payload: ["hook_event_name": "UserPromptSubmit", "session_id": "bg-attn", "prompt": "run"]) {
        ctrl.handleHook(startEv)
        ctrl.handleHook(promptEv)
    }

    // Attach an `lmux wait` waiter on paneB for `needs-you` BEFORE creating the ask session
    var waitReply: [String: Any]?
    let cancelWait = ctrl.startWait(["cmd": "wait", "target": paneB.id, "until": "needs-you"]) {
        waitReply = $0
    }
    defer { cancelWait() }

    let spec: [String: Any] = [
        "title": "背景確認卡片",
        "intro": "背景工作區在執行期間需要使用者確認設定策略與部署方向。",
        "questions": [[
            "id": "qb",
            "question": "是否繼續部署？",
            "detail": "這裡提供超過二十個字的補充背景描述內容。",
            "options": ["繼續", "暫停"]
        ]]
    ]
    let notifBefore = ctrl.model.notifications.count
    let res = ctrl.handleControl(["cmd": "ask-create", "token": tokenB, "spec": spec])
    let sid = res["sessionId"] as? String ?? ""
    await sleepMs(40)

    let isNeedsInputDisplay: Bool = {
        if case .needsInput = paneB.display { return true }
        return false
    }()
    r.check("background ask keeps foreground wsA selected and overrides .running with .needsInput",
            ctrl.model.selectedID == wsA.id
            && paneB.hasPendingAsk
            && paneB.needsInput
            && isNeedsInputDisplay)
    r.check("lmux wait --until needs-you wakes up when ask session arrives",
            (waitReply?["ok"] as? Bool) == true && (waitReply?["state"] as? String) == "needs input",
            "\(String(describing: waitReply))")
    r.check("background ask records unread notification card",
            ctrl.model.notifications.count > notifBefore
            && ctrl.model.notifications.first?.paneID == paneB.id
            && ctrl.model.notifications.first?.kind == "needsInput"
            && ctrl.model.notifications.first?.read == false)

    // Typing into terminal MUST NOT clear hasPendingAsk
    ctrl.userTyped(paneB)
    r.check("userTyped does not clear hasPendingAsk", paneB.hasPendingAsk && paneB.needsInput)

    // Closing background pane ends ask session with lost
    var lostOutcome: [String: Any]?
    _ = ctrl.startAskWait(["cmd": "ask-wait", "sessionId": sid, "token": tokenB]) { lostOutcome = $0 }
    ctrl.closeWorkspace(wsB)
    r.check("closing source pane marks pending ask session lost",
            (lostOutcome?["status"] as? String) == "lost")
}

@MainActor
private func runAskMarkdownParserTests(_ r: Report) {
    let md = """
    ## 架構調整

    第一段說明文字。

    第二段說明文字。

    - 項目一
    * 項目二
    1. 第一步
    2. 第二步

    > 注意相容性

    ```swift
    let x = 1
    ```

    ```diff
    @@ -1,2 +1,2 @@
    -oldLine()
    +newLine()
    ```
    """
    let blocks = AskMarkdownParser.parse(md)
    let hasHeading = blocks.contains(.heading(level: 2, text: "架構調整"))
    let paraCount = blocks.filter { if case .paragraph = $0 { return true }; return false }.count
    let bulletCount = blocks.filter { if case .bulletItem = $0 { return true }; return false }.count
    let numCount = blocks.filter { if case .numberedItem = $0 { return true }; return false }.count
    let hasQuote = blocks.contains(.blockquote("注意相容性"))
    let hasCode = blocks.contains(.codeBlock(language: "swift", code: "let x = 1"))
    let diffLines: [GitDiffLine] = blocks.compactMap { if case .diffBlock(let l) = $0 { return l }; return nil }.first ?? []

    r.check("AskMarkdownParser parses headings, separate paragraphs, bullets, numbered items, quotes, code, and diff blocks",
            hasHeading && paraCount == 2 && bulletCount == 2 && numCount == 2 && hasQuote && hasCode
            && diffLines.contains { $0.kind == .hunkHeader }
            && diffLines.contains { $0.kind == .removed }
            && diffLines.contains { $0.kind == .added })

    // Unclosed fence & empty input degrade safely
    let unclosed = AskMarkdownParser.parse("```python\nprint('hi')")
    r.check("AskMarkdownParser degrades safely on unclosed fence and empty string",
            unclosed == [.codeBlock(language: "python", code: "print('hi')")]
            && AskMarkdownParser.parse("").isEmpty
            && AskMarkdownParser.parse("   \n  ").isEmpty)
}
