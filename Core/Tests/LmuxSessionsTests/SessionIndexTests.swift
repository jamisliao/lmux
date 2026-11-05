import Foundation
import Testing
import LmuxTranscript
@testable import LmuxSessions

/// Builds transcripts shaped like real Claude Code 2.1.x files (see LmuxTranscript/FORMAT.md).
struct Fixture {
    let sessionId: String
    let cwd: String
    var branch = "main"
    var lines: [String] = []
    var parent: String?
    var clock = 0

    init(_ sessionId: String, cwd: String) {
        self.sessionId = sessionId
        self.cwd = cwd
    }

    var data: Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    mutating func add(_ o: [String: Any]) {
        let d = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])
        lines.append(String(decoding: d, as: UTF8.self))
    }

    mutating func chain(_ type: String, _ fields: [String: Any], cwd: String? = nil) -> String {
        clock += 1
        let uuid = UUID().uuidString.lowercased()
        var o: [String: Any] = [
            "type": type, "uuid": uuid, "parentUuid": parent ?? NSNull(), "isSidechain": false,
            "sessionId": sessionId, "cwd": cwd ?? self.cwd, "gitBranch": branch, "version": "2.1.280",
            "timestamp": String(format: "2026-10-01T10:%02d:%02d.000Z", clock / 60, clock % 60),
        ]
        o.merge(fields) { _, n in n }
        add(o)
        parent = uuid
        return uuid
    }

    @discardableResult
    mutating func prompt(_ text: String, cwd: String? = nil) -> String {
        chain("user", ["message": ["role": "user", "content": text], "turnOrigin": "human", "promptSource": "typed"], cwd: cwd)
    }

    /// One API response: thinking, a tool call + its result, then the final text reply.
    mutating func reply(_ text: String, thinking: String = "secret thinking zebra", toolOutput: String = "tool output giraffe") {
        let mid = "msg_" + UUID().uuidString.prefix(8)
        _ = chain("assistant", ["message": ["id": mid, "role": "assistant", "content": [["type": "thinking", "thinking": thinking]]]])
        let tid = "toolu_" + UUID().uuidString.prefix(8)
        _ = chain("assistant", ["message": ["id": mid, "role": "assistant", "content": [["type": "tool_use", "id": tid, "name": "Bash", "input": ["command": "ls"]]]]])
        _ = chain("user", ["message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": tid, "content": toolOutput]]], "toolUseResult": ["stdout": toolOutput]])
        let mid2 = "msg_" + UUID().uuidString.prefix(8)
        _ = chain("assistant", ["message": ["id": mid2, "role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    mutating func meta(_ type: String, _ fields: [String: Any]) {
        var o: [String: Any] = ["type": type, "sessionId": sessionId]
        o.merge(fields) { _, n in n }
        add(o)
    }
}

final class Env {
    let root: URL
    let projects: URL
    let archive: URL
    let dbURL: URL

    init() throws {
        root = TestTemp.dir("lmux-sessions")
        projects = root.appendingPathComponent("projects", isDirectory: true)
        archive = root.appendingPathComponent("archive", isDirectory: true)
        dbURL = root.appendingPathComponent("db/sessions.db")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func index(archiving: Bool = true) throws -> SessionIndex {
        try SessionIndex(databaseURL: dbURL, projectsRoot: projects, archiveDirectory: archiving ? archive : nil)
    }

    func url(_ f: Fixture) -> URL {
        projects.appendingPathComponent(SessionIndex.projectDirectoryName(forCwd: f.cwd), isDirectory: true)
            .appendingPathComponent(f.sessionId + ".jsonl")
    }

    @discardableResult
    func write(_ f: Fixture) throws -> URL {
        let u = url(f)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try f.data.write(to: u)
        return u
    }

    func append(_ s: String, to f: Fixture) throws {
        let h = try FileHandle(forWritingTo: url(f))
        try h.seekToEnd()
        try h.write(contentsOf: Data(s.utf8))
        try h.close()
    }
}

/// mtime resolution can hide a rewrite done within the same instant; bump it explicitly.
func bumpMtime(_ u: URL, by seconds: Double = 5) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
    let d = (attrs[.modificationDate] as! Date).addingTimeInterval(seconds)
    try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: u.path)
}

let sid1 = "11111111-1111-4111-8111-111111111111"
let sid2 = "22222222-2222-4222-8222-222222222222"

func koreanFixture() -> Fixture {
    var f = Fixture(sid1, cwd: "/Users/me/work/my.repo_v2")
    f.meta("permission-mode", ["permissionMode": "default"])
    _ = f.chain("user", ["message": ["role": "user", "content": "<local-command-caveat>Caveat</local-command-caveat>"], "isMeta": true])
    f.prompt("지난번 세션을 복원하는 방법 알려줘")
    f.reply("`claude --resume` 명령으로 세션을 이어갈 수 있어요.")
    f.meta("ai-title", ["aiTitle": "세션 복원 방법"])
    f.prompt("Explain the Resume flag in English")
    f.reply("The resume flag reopens an EXISTING conversation.")
    f.meta("ai-title", ["aiTitle": "세션 복원과 resume 플래그"])
    f.meta("last-prompt", ["lastPrompt": "Explain", "leafUuid": f.parent!])
    return f
}

@Suite struct IndexingTests {
    @Test func indexesMetadataTitlesAndCwd() throws {
        let env = try Env()
        var a = koreanFixture()
        a.branch = "feature/x"
        try env.write(a)
        var b = Fixture(sid2, cwd: "/tmp/other")
        b.prompt("hello there")
        b.reply("hi")
        b.meta("ai-title", ["aiTitle": "AI title"])
        b.meta("custom-title", ["customTitle": "My name"])
        b.meta("ai-title", ["aiTitle": "later AI title"])
        try env.write(b)

        let idx = try env.index()
        let stats = try idx.refresh()
        #expect(stats.scanned == 2 && stats.reindexed == 2)

        let s1 = try #require(try idx.session(sid1))
        #expect(s1.cwd == "/Users/me/work/my.repo_v2")
        #expect(s1.projectDirectory == "-Users-me-work-my-repo-v2")
        #expect(s1.firstPrompt == "지난번 세션을 복원하는 방법 알려줘")
        #expect(s1.title == "세션 복원과 resume 플래그") // latest ai-title wins
        #expect(s1.turnCount == 2)
        #expect(s1.gitBranch == "main")
        #expect(s1.fileSize == a.data.count)
        #expect(s1.createdAt! < s1.updatedAt!)
        #expect(!s1.isMissing && !s1.isHidden)

        let s2 = try #require(try idx.session(sid2))
        #expect(s2.title == "My name") // custom title beats AI title
        #expect(s2.aiTitle == "later AI title")
        #expect(try idx.sessions().map(\.id).count == 2)
    }

    @Test func cwdPrefersTheDirectoryClaudeStoresTheFileIn() throws {
        let env = try Env()
        var f = Fixture(sid1, cwd: "/Users/me/proj")
        f.prompt("start")
        f.prompt("now in subdir", cwd: "/Users/me/proj/sub")
        // File placed as if the session started in /Users/me/proj, but first entry says sub.
        var g = Fixture(sid2, cwd: "/Users/me/proj")
        g.prompt("first", cwd: "/Users/me/proj/sub")
        g.prompt("second")
        try env.write(f)
        try env.write(g)
        let idx = try env.index()
        try idx.refresh()
        #expect(try idx.session(sid1)?.cwd == "/Users/me/proj")
        #expect(try idx.session(sid2)?.cwd == "/Users/me/proj")
        #expect(SessionIndex.projectDirectoryName(forCwd: "/Users/me/한글 dir") == "-Users-me----dir")
    }

    @Test func resumeFromAnywhere() throws {
        let env = try Env()
        var f = Fixture(sid1, cwd: "/Users/me/it's here")
        f.prompt("x")
        try env.write(f)
        let idx = try env.index()
        try idx.refresh()
        let r = try idx.resumeInfo(sid1)
        #expect(r.cwd == "/Users/me/it's here")
        #expect(r.arguments == ["claude", "--resume", sid1])
        #expect(r.shellCommand == "cd '/Users/me/it'\\''s here' && claude --resume \(sid1)")
        #expect(!r.needsRestore && !r.cwdExists)
        #expect(throws: SessionIndexError.notFound("nope")) { try idx.resumeInfo("nope") }
    }
}

@Suite struct StreamingParseTests {
    /// A first index streams the file (`Transcript.outline`): same result as parsing it whole,
    /// with tool output stripped, a partial last line left out, and a line longer than a read chunk.
    @Test func outlineMatchesWholeFileParse() throws {
        var f = Fixture("s-stream", cwd: "/tmp/stream")
        f.prompt("first question about 환불")
        f.reply("first answer", toolOutput: String(repeating: "big tool output ", count: 20_000))
        f.meta("ai-title", ["aiTitle": "환불 질문"])
        f.prompt("second question", cwd: "/tmp/stream/sub")
        f.reply("second answer")
        f.meta("custom-title", ["customTitle": "My name"])
        f.meta("last-prompt", ["lastPrompt": "second question"])
        var data = f.data
        data.append(Data(#"{"type":"user","partial"#.utf8))
        let url = TestTemp.dir("lmux-stream").appendingPathComponent("s-stream.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let whole = try SessionIndex.readCompleteLines(url, from: 0)
        let a = SessionIndex.parse(whole)
        let o = try Transcript.outline(url, chunkSize: 4096)
        let b = SessionIndex.parse(o.transcript, lineLengths: o.lineLengths)
        #expect(o.bytes == whole.count)
        #expect(a.turns == b.turns && b.turns.count == 2)
        #expect(a.lastTurnOffset == b.lastTurnOffset && b.lastTurnOffset != nil)
        #expect(a.cwds == b.cwds && a.gitBranch == b.gitBranch && a.customTitle == b.customTitle && a.aiTitle == b.aiTitle)
        #expect(a.firstTimestamp == b.firstTimestamp && a.lastTimestamp == b.lastTimestamp && a.rewound == b.rewound)
        #expect(b.turns.first?.assistantText == "first answer" && b.aiTitle == "환불 질문")
        let p = try SessionIndex.parseFile(url)
        #expect(p.indexedBytes == whole.count && p.fingerprint == Data(whole.suffix(SessionIndex.fingerprintLength)))
    }
}

@Suite struct IncrementalTests {
    @Test func unchangedFilesAreSkipped() throws {
        let env = try Env()
        try env.write(koreanFixture())
        let idx = try env.index()
        try idx.refresh()
        let s = try idx.refresh()
        #expect(s == RefreshStats(scanned: 1, unchanged: 1))
    }

    @Test func appendFastPathMatchesFullIndex() throws {
        let env = try Env()
        var f = koreanFixture()
        try env.write(f)
        let idx = try env.index()
        try idx.refresh()

        // A new turn plus a reply that continues it, appended in two steps.
        let before = f.lines.count
        f.prompt("세 번째 질문: 인덱스는 어디에")
        try env.append(f.lines[before...].joined(separator: "\n") + "\n", to: f)
        var s = try idx.refresh()
        #expect(s.appended == 1 && s.reindexed == 0)
        #expect(try idx.session(sid1)?.turnCount == 3)

        let mid = f.lines.count
        f.reply("인덱스는 Application Support 아래에 있어요")
        f.meta("custom-title", ["customTitle": "내 세션"])
        try env.append(f.lines[mid...].joined(separator: "\n") + "\n", to: f)
        s = try idx.refresh()
        #expect(s.appended == 1)
        let hits = try idx.search("Application Support")
        #expect(hits.count == 1 && hits[0].turnIndex == 3 && hits[0].field == .reply)
        #expect(try idx.session(sid1)?.title == "내 세션")
        #expect(try idx.session(sid1)?.turnCount == 3)

        // Same result as indexing from scratch.
        let env2 = try Env()
        try env2.write(f)
        let idx2 = try env2.index()
        try idx2.refresh()
        for q in ["세션", "인덱스", "resume", "Application"] {
            #expect(try idx.search(q).map(\.turnIndex) == idx2.search(q).map(\.turnIndex), "query \(q)")
        }
        let r1 = try #require(try idx.session(sid1))
        let r2 = try #require(try idx2.session(sid1))
        #expect((r1.turnCount, r1.firstPrompt, r1.title, r1.cwd, r1.fileSize) == (r2.turnCount, r2.firstPrompt, r2.title, r2.cwd, r2.fileSize))
    }

    @Test func partialLineWaitsForCompletion() throws {
        let env = try Env()
        var f = koreanFixture()
        try env.write(f)
        let idx = try env.index()
        try idx.refresh()
        let before = f.lines.count
        f.prompt("half written prompt about kangaroos")
        let line = f.lines[before]
        let cut = line.index(line.startIndex, offsetBy: line.count / 2)
        try env.append(String(line[..<cut]), to: f)
        #expect(try idx.refresh().appended == 1)
        #expect(try idx.search("kangaroos").isEmpty)
        try env.append(String(line[cut...]) + "\n", to: f)
        #expect(try idx.refresh().appended == 1)
        #expect(try idx.search("kangaroos").count == 1)
        #expect(try idx.session(sid1)?.turnCount == 3)
    }

    @Test func rewrittenFileIsFullyReindexed() throws {
        let env = try Env()
        try env.write(koreanFixture())
        let idx = try env.index()
        try idx.refresh()
        var g = Fixture(sid1, cwd: "/Users/me/work/my.repo_v2")
        g.prompt("completely different octopus")
        let u = try env.write(g)
        try bumpMtime(u)
        let s = try idx.refresh()
        #expect(s.reindexed == 1)
        #expect(try idx.search("세션").isEmpty)
        #expect(try idx.search("octopus").count == 1)
        #expect(try idx.session(sid1)?.turnCount == 1)
    }

    @Test func branchFromEarlierTurnFallsBackToFullIndex() throws {
        let env = try Env()
        var f = koreanFixture()
        try env.write(f)
        let idx = try env.index()
        try idx.refresh()
        // Fork from the first turn's prompt (like a rewind): new prompt's parent is old.
        let before = f.lines.count
        let firstPrompt = try #require(f.lines.first { $0.contains("지난번") })
        let obj = try JSONSerialization.jsonObject(with: Data(firstPrompt.utf8)) as! [String: Any]
        f.parent = obj["uuid"] as? String
        f.prompt("branch prompt walrus")
        f.meta("last-prompt", ["lastPrompt": "branch prompt walrus", "leafUuid": f.parent!])
        try env.append(f.lines[before...].joined(separator: "\n") + "\n", to: f)
        let s = try idx.refresh()
        #expect(s.reindexed == 1 && s.appended == 0)
        #expect(try idx.search("walrus").first?.turnIndex == 2)
    }
}

@Suite struct SearchTests {
    let env: Env
    let idx: SessionIndex

    init() throws {
        env = try Env()
        try env.write(koreanFixture())
        var b = Fixture(sid2, cwd: "/tmp/other")
        b.prompt("데이터베이스 마이그레이션 계획")
        b.reply("마이그레이션은 세 단계로 진행합니다.")
        try env.write(b)
        idx = try env.index()
        try idx.refresh()
    }

    @Test func koreanPartialWordsMatch() throws {
        // 2-syllable stem inside an inflected word ("세션을"), below trigram length.
        let hits = try idx.search("세션")
        #expect(Set(hits.map(\.session.id)) == [sid1])
        #expect(hits.map(\.turnIndex) == [1])
        #expect(hits[0].field == .prompt)
        #expect(hits[0].snippet.contains("세션을"))
        #expect(hits[0].highlights.map { String(hits[0].snippet[$0]) } == ["세션"])
        // 3+ syllables via the trigram index, also mid-word.
        #expect(try idx.search("복원하는").map(\.session.id) == [sid1])
        #expect(try idx.search("이그레이").map(\.session.id).allSatisfy { $0 == sid2 })
        // Particle-attached form found from the stem in the reply only.
        let r = try idx.search("단계")
        #expect(r.count == 1 && r[0].field == .reply && r[0].snippet.contains("세 단계로"))
        // One syllable.
        #expect(try idx.search("번").map(\.session.id) == [sid1])
        // Decomposed (NFD) query still matches precomposed text.
        #expect(try idx.search("세션을".decomposedStringWithCanonicalMapping).count == 1)
    }

    @Test func englishAndMixedQueries() throws {
        let h = try idx.search("existing")
        #expect(h.count == 1 && h[0].turnIndex == 2 && h[0].field == .reply)
        #expect(h[0].highlights.map { String(h[0].snippet[$0]) } == ["EXISTING"])
        #expect(try idx.search("RESUME flag").count == 1) // AND of terms, case-insensitive
        #expect(try idx.search("resume 세션").map(\.turnIndex) == [1]) // turn 1 reply has both
        #expect(try idx.search("resume nonexistentword").isEmpty)
        #expect(try idx.search("   ").isEmpty)
        #expect(try idx.search("100%_").isEmpty) // LIKE wildcards are literal
        #expect(try idx.search("\"quoted").isEmpty)
    }

    @Test func toolOutputAndThinkingAreNotIndexed() throws {
        #expect(try idx.search("giraffe").isEmpty)
        #expect(try idx.search("zebra").isEmpty)
        #expect(try idx.search("Caveat").isEmpty)
    }

    @Test func snippetIsWindowedWithEllipsis() {
        let text = String(repeating: "앞", count: 100) + " 목표단어 " + String(repeating: "뒤", count: 200)
        let (s, hl) = SessionIndex.snippet(text, terms: ["목표"])
        #expect(s.hasPrefix("…") && s.hasSuffix("…"))
        #expect(s.count < 140)
        #expect(hl.count == 1 && s[hl[0]] == "목표")
    }
}

@Suite struct LifecycleTests {
    @Test func softDeleteHidesFromListAndSearchAndSurvivesReindex() throws {
        let env = try Env()
        let u = try env.write(koreanFixture())
        let idx = try env.index()
        try idx.refresh()
        try idx.setHidden(sid1)
        #expect(try idx.sessions().isEmpty)
        #expect(try idx.search("세션").isEmpty)
        #expect(try idx.sessions(includeHidden: true).count == 1)
        #expect(try idx.search("세션", includeHidden: true).count == 1)
        try env.write(koreanFixture()) // rewritten (new uuids): full re-index
        try bumpMtime(u)
        #expect(try idx.refresh().reindexed == 1)
        #expect(try idx.session(sid1)?.isHidden == true)
        try idx.setHidden(sid1, false)
        #expect(try idx.sessions().count == 1)
        #expect(throws: SessionIndexError.notFound("x")) { try idx.setHidden("x") }
    }

    @Test func missingSourceKeepsRowAndSearch() throws {
        let env = try Env()
        let f = koreanFixture()
        let u = try env.write(f)
        let idx = try env.index(archiving: false)
        try idx.refresh()
        try FileManager.default.removeItem(at: u) // simulates Claude's retention cleanup (temp dir)
        let s = try idx.refresh()
        #expect(s.newlyMissing == 1)
        let r = try #require(try idx.session(sid1))
        #expect(r.isMissing && !r.isArchived && r.turnCount == 2)
        #expect(try idx.search("세션").count == 1)
        #expect(try idx.resumeInfo(sid1).needsRestore)
        #expect(throws: SessionIndexError.archivingDisabled) { try idx.archive(sid1) }
        #expect(try idx.refresh().newlyMissing == 0) // stays missing, not re-counted
        // File comes back (e.g. user restored it by hand): row is live again.
        try env.write(f)
        let s2 = try idx.refresh()
        #expect(s2.reappeared == 1 && s2.reindexed == 1)
        #expect(try idx.session(sid1)?.isMissing == false)
    }

    @Test func archiveAndRestore() throws {
        let env = try Env()
        var f = koreanFixture()
        let u = try env.write(f)
        var g = Fixture(sid2, cwd: "/tmp/other")
        g.prompt("other")
        try env.write(g)
        let idx = try env.index()
        try idx.refresh()

        #expect(try idx.archiveAll() == 2)
        #expect(try idx.archiveAll() == 0) // up to date
        let original = try Data(contentsOf: u)
        let archived = try #require(try idx.session(sid1))
        #expect(archived.isArchived)
        let file = env.archive.appendingPathComponent("-Users-me-work-my-repo-v2/\(sid1).jsonl.lzfse")
        #expect(FileManager.default.fileExists(atPath: file.path))

        // Grow the file: archive becomes stale and is refreshed.
        let before = f.lines.count
        f.prompt("one more")
        try env.append(f.lines[before...].joined(separator: "\n") + "\n", to: f)
        try idx.refresh()
        #expect(try idx.archiveAll() == 1)
        let grown = try Data(contentsOf: u)
        #expect(grown.count > original.count)

        // Retention cleanup removes the source.
        try FileManager.default.removeItem(at: u)
        try idx.refresh()
        #expect(try idx.session(sid1)?.isMissing == true)
        #expect(try idx.resumeInfo(sid1).needsRestore)

        let restored = try idx.restore(sid1)
        #expect(restored == u.standardizedFileURL || restored.path == u.path)
        #expect(try Data(contentsOf: u) == grown)
        let r = try #require(try idx.session(sid1))
        #expect(!r.isMissing && r.turnCount == 3)
        #expect(try !idx.resumeInfo(sid1).needsRestore)
        // Restoring again is a no-op; a different file in the way is never overwritten.
        _ = try idx.restore(sid1)
        try Data("different\n".utf8).write(to: u)
        #expect(throws: SessionIndexError.sourceExists(u.path)) { try idx.restore(sid1) }
        #expect(throws: SessionIndexError.noArchive(sid2)) {
            try FileManager.default.removeItem(at: env.archive.appendingPathComponent("-tmp-other/\(sid2).jsonl.lzfse"))
            try idx.restore(sid2)
        }
    }

    /// Restored transcripts, forget backups and rewritten transcripts / ↑ history hold the
    /// conversation: 0600 from the moment they exist (never the umask's 0644, not even briefly).
    /// The only test that sets `PrivateFile.didCreate` (a global), and it only looks at its own dir.
    @Test func conversationFilesArePrivateFromCreation() throws {
        let env = try Env()
        var f = koreanFixture()
        f.prompt("second prompt")
        let u = try env.write(f)
        let idx = try env.index()
        try idx.refresh()
        try idx.archive(sid1)
        try FileManager.default.removeItem(at: u)
        try idx.refresh()

        let lock = NSLock()
        var atCreation: [String: mode_t] = [:]
        PrivateFile.didCreate = { url in
            guard url.path.hasPrefix(env.root.path) else { return }
            lock.withLock { atCreation[url.lastPathComponent] = PrivateFile.mode(of: url.path) }
        }
        defer { PrivateFile.didCreate = nil }
        func mode(_ url: URL) -> mode_t? { PrivateFile.mode(of: url.path) }

        let restored = try idx.restore(sid1)
        #expect(lock.withLock { atCreation[restored.lastPathComponent] } == 0o600, "restore: mode when created")
        #expect(mode(restored) == 0o600, "restore: final mode")

        // Forget's surgery: the backup and the rewritten transcript.
        let t = try Transcript.load(restored)
        let first = try #require(t.turns().first)
        let backup = try #require(try t.removing(turnUuid: first.uuid).write(to: restored))
        #expect(lock.withLock { atCreation[backup.lastPathComponent] } == 0o600, "backup: mode when created")
        #expect(mode(backup) == 0o600 && mode(restored) == 0o600)
        #expect(lock.withLock { atCreation.keys.contains { $0.hasPrefix(".\(restored.lastPathComponent).lmux-") } },
                "the rewrite goes through a private temp file")
        #expect(lock.withLock { atCreation.values.allSatisfy { $0 == 0o600 } }, "\(atCreation)")

        // ↑ history rewrite: its temp file gets the history's own mode at creation.
        let hist = env.root.appendingPathComponent("history.jsonl")
        try Data((#"{"display":"x","pastedContents":{},"timestamp":1,"project":"/w","sessionId":"S"}"# + "\n").utf8).write(to: hist)
        chmod(hist.path, 0o600)
        #expect(try PromptHistory.remove(prompt: "x", projectDirectory: "-w", sessionID: "S", in: hist) == 1)
        #expect(lock.withLock { atCreation[".history.jsonl.lmux-\(getpid())"] } == 0o600)
        #expect(mode(hist) == 0o600)
    }

    @Test func onlySessionsAtRiskAreArchived() throws {
        let env = try Env()
        let old = try env.write(koreanFixture())
        var g = Fixture(sid2, cwd: "/tmp/other")
        g.prompt("fresh")
        let fresh = try env.write(g)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: old.path)
        let idx = try env.index()
        try idx.refresh()
        // Claude deletes after cleanupPeriodDays (30): archive what is older than 25 days.
        let cutoff = Date().addingTimeInterval(-25 * 86400)
        #expect(try idx.archiveAll(olderThan: cutoff) == 1)
        #expect(try idx.session(sid1)?.isArchived == true && idx.session(sid2)?.isArchived == false)
        #expect(try idx.archiveAll(olderThan: cutoff) == 0)
        // Hiding a session archives it (nothing in the list points at it any more).
        try idx.setHidden(sid2)
        #expect(try idx.session(sid2)?.isArchived == true)
        _ = fresh
    }

    @Test func trashingArchivesFirst() throws {
        let env = try Env()
        try env.write(koreanFixture())
        let idx = try env.index()
        try idx.refresh()
        #expect(try idx.session(sid1)?.isArchived == false)
        let trashed = try idx.moveToTrash(sid1)
        defer { for t in trashed { try? FileManager.default.removeItem(at: t) } } // our own temp items
        // The Trash renames on a name clash (other tests trash the same id), the extension stays.
        #expect(trashed.contains { $0.pathExtension == "lzfse" }, "\(trashed)")
    }

    @Test func archiveIsPrivate() throws {
        let env = try Env()
        try env.write(koreanFixture())
        let idx = try env.index()
        try idx.refresh()
        let file = try idx.archive(sid1)
        func mode(_ u: URL) throws -> Int {
            try (FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue
        }
        #expect(try mode(file) == 0o600)
        #expect(try mode(env.dbURL) == 0o600)
        #expect(try mode(file.deletingLastPathComponent()) == 0o700)
        #expect(try mode(env.archive) == 0o700)
    }

    @Test func cleanupCutoffFollowsClaudeSetting() throws {
        let env = try Env()
        let settings = env.root.appendingPathComponent("settings.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SessionIndex.archiveCutoff(settings: settings, now: now) == now.addingTimeInterval(-25 * 86400))
        try Data(#"{"model":"opus","cleanupPeriodDays":10}"#.utf8).write(to: settings)
        #expect(SessionIndex.archiveCutoff(settings: settings, now: now) == now.addingTimeInterval(-5 * 86400))
        try Data(#"{"cleanupPeriodDays":3}"#.utf8).write(to: settings)
        #expect(SessionIndex.archiveCutoff(settings: settings, now: now) == now)
        try Data("not json".utf8).write(to: settings)
        #expect(SessionIndex.archiveCutoff(settings: settings, now: now) == now.addingTimeInterval(-25 * 86400))
    }

    @Test func hardDeleteMovesToTrash() throws {
        let env = try Env()
        let u = try env.write(koreanFixture())
        let sidecar = u.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: sidecar.appendingPathComponent("agent-1.jsonl"))
        var other = Fixture(sid2, cwd: "/Users/me/work/my.repo_v2")
        other.prompt("keep me")
        let keep = try env.write(other)
        let idx = try env.index()
        try idx.refresh()
        try idx.archive(sid1)

        let trashed = try idx.moveToTrash(sid1)
        defer { for t in trashed { try? FileManager.default.removeItem(at: t) } } // our own temp items
        #expect(trashed.count == 3) // jsonl, <id>/ dir, archived copy
        #expect(trashed.allSatisfy { $0.path.contains("/.Trash/") && FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: u.path))
        #expect(!FileManager.default.fileExists(atPath: u.deletingPathExtension().path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(try idx.session(sid1) == nil)
        #expect(try idx.search("세션").isEmpty)
        #expect(try idx.refresh().newlyMissing == 0)
        #expect(throws: SessionIndexError.notFound(sid1)) { try idx.moveToTrash(sid1) }
    }

    @Test func reopeningKeepsState() throws {
        let env = try Env()
        try env.write(koreanFixture())
        do {
            let idx = try env.index()
            try idx.refresh()
            try idx.setHidden(sid1)
        }
        let idx = try env.index()
        #expect(try idx.refresh().unchanged == 1)
        #expect(try idx.session(sid1)?.isHidden == true)
    }
}

/// Read-only measurement against the real corpus. Opt in with
/// `LMUX_MEASURE_REAL=<dir for the db>`; only reads ~/.claude/projects.
@Test func measureRealCorpus() throws {
    guard let out = ProcessInfo.processInfo.environment["LMUX_MEASURE_REAL"] else { return }
    let dbURL = URL(fileURLWithPath: out).appendingPathComponent("sessions.db")
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbURL.path + suffix) }
    let archive = URL(fileURLWithPath: out).appendingPathComponent("archive")
    try? FileManager.default.removeItem(at: archive)
    let idx = try SessionIndex(databaseURL: dbURL, projectsRoot: SessionIndex.defaultProjectsRoot, archiveDirectory: archive)
    var t = Date()
    let full = try idx.refresh()
    let fullTime = Date().timeIntervalSince(t)
    t = Date()
    let noop = try idx.refresh()
    let noopTime = Date().timeIntervalSince(t)
    try idx.db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    let size = (try FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? NSNumber)?.intValue ?? 0
    var times: [String] = []
    for q in ["세션", "세션을", "resume", "인덱스 복원", "the"] {
        t = Date()
        let n = try idx.search(q, limit: 50).count
        times.append("\(q)=\(n) hits \(Int(Date().timeIntervalSince(t) * 1000))ms")
    }
    t = Date()
    let archivedCount = try idx.archiveAll()
    let archiveTime = Date().timeIntervalSince(t)
    let archiveBytes = FileManager.default.enumerator(at: archive, includingPropertiesForKeys: [.fileSizeKey])?
        .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +) ?? 0
    print("MEASURE archiveAll=\(archivedCount) in \(String(format: "%.2f", archiveTime))s, \(archiveBytes) bytes")
    print("MEASURE sessions=\(try idx.sessions(includeHidden: true).count) full=\(full) fullTime=\(String(format: "%.2f", fullTime))s dbSize=\(size) noop=\(noop) noopTime=\(String(format: "%.3f", noopTime))s search: \(times.joined(separator: ", "))")
}
