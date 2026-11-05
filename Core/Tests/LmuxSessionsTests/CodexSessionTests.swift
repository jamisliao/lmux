import Foundation
import Testing
import LmuxTranscript
@testable import LmuxSessions

/// Codex CLI sessions in History, next to Claude's: indexing, titles, Korean search, resume,
/// the append fast path, internal (subagent) sessions, missing files, Trash, an older database.
@Suite struct CodexSessionTests {
    final class CodexEnv {
        let env: Env
        let home: URL
        init() throws {
            env = try Env()
            home = env.root.appendingPathComponent("codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        }
        func index() throws -> SessionIndex {
            try SessionIndex(databaseURL: env.dbURL, projectsRoot: env.projects, archiveDirectory: env.archive, codexHome: home)
        }
        @discardableResult
        func rollout(_ id: String, _ text: String, day: String = "2026/11/02") throws -> URL {
            let dir = home.appendingPathComponent("sessions/\(day)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let u = dir.appendingPathComponent("rollout-2026-11-02T15-37-31-\(id).jsonl")
            try Data((text + "\n").utf8).write(to: u)
            return u
        }
        func names(_ text: String) throws {
            try Data((text + "\n").utf8).write(to: home.appendingPathComponent("session_index.jsonl"))
        }
    }

    static let noteID = "01a19afa-3664-79f1-b4d9-2fd9b2ca2250"
    static let madeID = "01a19af7-a41b-7be0-a747-28b261b34a33"

    static func korean(_ id: String) -> String {
        [
            #"{"timestamp":"2026-10-01T01:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"/Users/me/shop","cli_version":"0.166.0","source":"cli","git":{"branch":"fix/refund"}}}"#,
            #"{"timestamp":"2026-10-01T01:00:01.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t-1","item":{"type":"UserMessage","content":[{"type":"text","text":"부분환불할 때 금액 검증이 빠져 있어"}]}}}"#,
            #"{"timestamp":"2026-10-01T01:00:09.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t-1","item":{"type":"AgentMessage","content":[{"type":"Text","text":"검증 로직을 추가했어요."}],"phase":"final_answer"}}}"#,
        ].joined(separator: "\n")
    }

    @Test func indexesCodexNextToClaude() throws {
        let cx = try CodexEnv()
        var claude = Fixture(sid1, cwd: "/Users/me/work")
        claude.prompt("hello claude")
        claude.reply("hi")
        try cx.env.write(claude)
        try cx.rollout(Self.noteID, CodexRollouts.readNote)
        try cx.rollout(Self.madeID, CodexRollouts.createMade)
        try cx.names(CodexRollouts.sessionIndex)
        let idx = try cx.index()
        let stats = try idx.refresh()
        #expect(stats.scanned == 3 && stats.reindexed == 3)
        let all = try idx.sessions()
        #expect(Set(all.map(\.id)) == [sid1, Self.noteID, Self.madeID])
        let note = try #require(try idx.session(Self.noteID))
        #expect(note.agent == .codex && note.cwd == "/Users/me/proj" && note.turnCount == 1)
        #expect(note.title == "Read note.txt")  // Codex's own title, from session_index.jsonl
        #expect(note.firstPrompt?.hasPrefix("Run `cat note.txt`") == true)
        #expect(try idx.session(sid1)?.agent == .claude)
        // Resume with the right CLI, from any directory.
        let r = try idx.resumeInfo(Self.noteID)
        #expect(r.arguments == ["codex", "resume", Self.noteID] && !r.needsRestore)
        #expect(r.shellCommand == "cd /Users/me/proj && codex resume \(Self.noteID)")
        #expect(try idx.resumeInfo(sid1).arguments.first == "claude")
        // Unchanged: nothing re-read.
        let again = try idx.refresh()
        #expect(again.unchanged == 3 && again.reindexed == 0)
        // Search finds prompts and final answers in both.
        #expect(Set(try idx.search("hello").map(\.session.id)) == [sid1, Self.noteID])
        #expect(try idx.search("hello").first { $0.session.id == Self.noteID }?.field == .reply)
        #expect(try idx.search("note.txt").map(\.session.id) == [Self.noteID])
    }

    @Test func koreanSearchAndRename() throws {
        let cx = try CodexEnv()
        let id = "0a0a0a0a-0000-4000-8000-000000000001"
        try cx.rollout(id, Self.korean(id))
        let idx = try cx.index()
        try idx.refresh()
        #expect(try idx.search("환불").first?.session.id == id)          // 2 syllables: LIKE path
        #expect(try idx.search("금액 검증").first?.field == .prompt)
        #expect(try idx.search("로직을").first?.field == .reply)
        #expect(try idx.session(id)?.gitBranch == "fix/refund" && (try idx.session(id))?.title == nil)
        // Codex renames it (session_index.jsonl only): picked up on the next refresh.
        try cx.names(#"{"id":"\#(id)","thread_name":"환불 검증","updated_at":"2026-10-01T01:01:00Z"}"#)
        try idx.refresh()
        #expect(try idx.session(id)?.title == "환불 검증")
    }

    @Test func appendFastPath() throws {
        let cx = try CodexEnv()
        let lines = CodexRollouts.readNote.split(separator: "\n").map(String.init)
        let u = try cx.rollout(Self.noteID, lines.prefix(5).joined(separator: "\n"))
        let idx = try cx.index()
        try idx.refresh()
        #expect(try idx.session(Self.noteID)?.turnCount == 1)
        #expect(try idx.search("hello").isEmpty)
        let h = try FileHandle(forWritingTo: u)
        try h.seekToEnd()
        try h.write(contentsOf: Data((lines.dropFirst(5).joined(separator: "\n") + "\n" + Self.second).utf8))
        try h.close()
        try bumpMtime(u)
        let s = try idx.refresh()
        #expect(s.appended == 1 && s.reindexed == 0)
        #expect(try idx.session(Self.noteID)?.turnCount == 2)
        #expect(try idx.search("hello").first?.turnIndex == 1)
        #expect(try idx.search("second question").first?.turnIndex == 2)
        // Same as a full index of the same file.
        let fresh = try SessionIndex(databaseURL: cx.env.root.appendingPathComponent("db2.db"), projectsRoot: cx.env.projects,
                                     archiveDirectory: nil, codexHome: cx.home)
        try fresh.refresh()
        #expect(try fresh.search("second question").first?.turnIndex == 2)
        #expect(try fresh.session(Self.noteID)?.turnCount == 2)
    }

    static let second = [
        #"{"timestamp":"2026-11-02T06:40:00.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t-2","item":{"type":"UserMessage","content":[{"type":"text","text":"a second question"}]}}}"#,
        #"{"timestamp":"2026-11-02T06:40:05.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t-2","last_agent_message":"second answer"}}"#,
    ].joined(separator: "\n") + "\n"

    @Test func internalSessionsAreHiddenAndMissingKept() throws {
        let cx = try CodexEnv()
        let sub = "0b0b0b0b-0000-4000-8000-000000000002"
        try cx.rollout(sub, #"{"timestamp":"2026-04-23T07:35:09.610Z","type":"session_meta","payload":{"id":"\#(sub)","cwd":"/r","source":{"subagent":"review"}}}"#
                       + "\n" + Self.korean(sub).split(separator: "\n").dropFirst().joined(separator: "\n"))
        let u = try cx.rollout(Self.noteID, CodexRollouts.readNote)
        let idx = try cx.index()
        try idx.refresh()
        #expect(try idx.sessions().map(\.id) == [Self.noteID])
        #expect(try idx.search("환불").isEmpty)
        try FileManager.default.removeItem(at: u)
        #expect(try idx.refresh().newlyMissing == 1)
        #expect(try idx.session(Self.noteID)?.isMissing == true)
        // An index without a Codex home leaves Codex rows alone (never marks them missing).
        let claudeOnly = try cx.env.index()
        #expect(try claudeOnly.refresh().newlyMissing == 0)
    }

    @Test func trashAndNoArchive() throws {
        let cx = try CodexEnv()
        let u = try cx.rollout(Self.noteID, CodexRollouts.readNote)
        let idx = try cx.index()
        try idx.refresh()
        #expect(try idx.archiveAll() == 0)          // Codex files are never copied into lmux's archive
        try idx.setHidden(Self.noteID)
        #expect(try idx.session(Self.noteID)?.isArchived == false)
        let trashed = try idx.moveToTrash(Self.noteID)
        defer { for t in trashed { try? FileManager.default.removeItem(at: t) } }
        #expect(trashed.count == 1 && !FileManager.default.fileExists(atPath: u.path))
        #expect(try idx.session(Self.noteID) == nil)
    }

    @Test func olderDatabaseGainsTheAgentColumn() throws {
        let cx = try CodexEnv()
        var claude = Fixture(sid1, cwd: "/Users/me/work")
        claude.prompt("hello claude")
        try cx.env.write(claude)
        // A database written by an lmux without Codex support.
        try FileManager.default.createDirectory(at: cx.env.dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let old = try SQLiteDB(path: cx.env.dbURL.path)
            try old.exec(SessionIndex.schema)
        }
        try FileManager.default.createDirectory(at: cx.env.dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = try cx.env.index()
        try first.refresh()
        try cx.rollout(Self.noteID, CodexRollouts.readNote)
        let idx = try cx.index()
        try idx.refresh()
        #expect(try idx.session(sid1)?.agent == .claude && (try idx.session(Self.noteID))?.agent == .codex)
    }

    @Test func sessionIDFromFileName() {
        #expect(SessionIndex.codexSessionID(fileName: "rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl")
                == "01a19afa-3664-79f1-b4d9-2fd9b2ca2250")
        #expect(SessionIndex.codexSessionID(fileName: "rollout-x.jsonl") == nil)
        #expect(SessionIndex.codexSessionID(fileName: "01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl") == nil)
    }
}
