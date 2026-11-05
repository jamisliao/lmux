import Foundation
import Testing
@testable import LmuxTranscript

/// `~/.claude/history.jsonl` (what ↑ recalls), shaped like Claude Code 2.1.x writes it.
/// Tests only ever touch temp copies.
@Suite struct PromptHistoryTests {
    static let lines = [
        #"{"display":"keep me","pastedContents":{},"timestamp":1,"project":"/w/a","sessionId":"S1"}"#,
        #"{"display":"remember PINEAPPLE","pastedContents":{},"timestamp":2,"project":"/w/a","sessionId":"S1"}"#,
        #"{"display":"remember PINEAPPLE","pastedContents":{},"timestamp":3,"project":"/w/b","sessionId":"S2"}"#,
        #"{"display":"remember PINEAPPLE","pastedContents":{},"timestamp":4,"project":"/w/a","sessionId":"OTHER"}"#,
        #"{"display":"remember PINEAPPLE please","pastedContents":{},"timestamp":5,"project":"/w/a","sessionId":"S1"}"#,
        #"{"display":"fix [Pasted text #1 +2 lines] now","pastedContents":{"1":{"id":1,"type":"text","content":"a\nb\nc"}},"timestamp":6,"project":"/w/a","sessionId":"S1"}"#,
        #"{"display":"한국어 \u00e9","pastedContents":{},  "timestamp":7,"project":"/w/a","sessionId":"S1"}"#,
        "not json at all",
        #"{"display":"remember PINEAPPLE","pastedContents":{},"timestamp":8,"project":"/w/a","sessionId":"S1"}"#,
    ]

    /// Big pastes: `{"id","type","contentHash"}`, the body in `paste-cache/<hash>.txt`; images: `[Image #N]`
    /// in `display`, nothing in `pastedContents` (the transcript has the text block, then image blocks).
    @Test func hashedPastesAndImagesMatch() throws {
        let dir = try tempFile("").deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = dir.appendingPathComponent("paste-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("line a\nline b\nline c".utf8).write(to: cache.appendingPathComponent("aaaa1111.txt"))
        try Data("shared".utf8).write(to: cache.appendingPathComponent("bbbb2222.txt"))
        let lines = [
            #"{"display":"fix [Pasted text #1 +2 lines] now","pastedContents":{"1":{"id":1,"type":"text","contentHash":"aaaa1111"}},"timestamp":1,"project":"/w/a","sessionId":"S1"}"#,
            #"{"display":"[Image #1] what is this","pastedContents":{},"timestamp":2,"project":"/w/a","sessionId":"S1"}"#,
            #"{"display":"also [Pasted text #1 +0 lines]","pastedContents":{"1":{"id":1,"type":"text","contentHash":"bbbb2222"}},"timestamp":3,"project":"/w/a","sessionId":"S1"}"#,
            #"{"display":"again [Pasted text #1 +0 lines]","pastedContents":{"1":{"id":1,"type":"text","contentHash":"bbbb2222"}},"timestamp":4,"project":"/w/b","sessionId":"S9"}"#,
        ]
        let url = dir.appendingPathComponent("history.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        // Hashed paste: matched through the cache, its cache file deleted (nothing else uses it).
        #expect(try PromptHistory.remove(prompt: "fix line a\nline b\nline c now", projectDirectory: "-w-a", sessionID: "S1", in: url) == 1)
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("aaaa1111.txt").path))
        // Image prompt: the transcript's prompt is the text block plus "[image]" per image block.
        #expect(try PromptHistory.remove(prompt: "[Image #1] what is this\n[image]", projectDirectory: "-w-a", sessionID: "S1", in: url) == 1)
        // A hash still referenced by another line stays.
        #expect(try PromptHistory.remove(prompt: "also shared", projectDirectory: "-w-a", sessionID: "S1", in: url) == 1)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("bbbb2222.txt").path))
        #expect(try String(contentsOf: url, encoding: .utf8) == lines[3] + "\n")
    }

    /// Claude Code appends under proper-lockfile (`history.jsonl.lock` dir): lmux takes the same
    /// lock, and a line appended to the old file while lmux rewrote it is carried over.
    @Test func honorsClaudesLockAndKeepsLateAppends() throws {
        let url = try tempFile(Self.lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = url.appendingPathExtension("lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let held = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? FileManager.default.removeItem(at: lock) }
        let late = #"{"display":"typed meanwhile","pastedContents":{},"timestamp":9,"project":"/w/a","sessionId":"S1"}"#
        PromptHistory.beforeRename = {
            let h = FileHandle(forWritingAtPath: url.path)!
            h.seekToEndOfFile(); h.write(Data((late + "\n").utf8)); h.closeFile()
        }
        defer { PromptHistory.beforeRename = nil }
        #expect(try PromptHistory.remove(prompt: "remember PINEAPPLE", projectDirectory: "-w-a", sessionID: "S1", in: url) == 2)
        #expect(Date().timeIntervalSince(held) >= 0.25)  // waited for Claude's lock
        #expect(!FileManager.default.fileExists(atPath: lock.path))  // and released its own
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.hasSuffix(late + "\n"), "\(after)")
        // A stale lock (older than Claude's 10s) is taken over.
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: lock.path)
        #expect(try PromptHistory.remove(prompt: "keep me", projectDirectory: "-w-a", sessionID: "S1", in: url) == 1)
    }

    func tempFile(_ text: String) throws -> URL {
        let dir = TestTemp.dir("lmux-hist")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.jsonl")
        try Data(text.utf8).write(to: url)
        chmod(url.path, 0o600)
        return url
    }

    @Test func removesOnlyExactMatchesOfThatProjectAndSession() throws {
        let text = Self.lines.joined(separator: "\n") + "\n"
        let (out, removed) = PromptHistory.removing(prompt: "remember PINEAPPLE", projectDirectory: "-w-a", sessionID: "S1",
                                                    from: Data(text.utf8))
        #expect(removed == 2)
        // Every other line byte for byte, in order.
        let expected = Self.lines.enumerated().filter { ![1, 8].contains($0.offset) }.map(\.element)
            .joined(separator: "\n") + "\n"
        #expect(out == Data(expected.utf8))
    }

    @Test func pastedPromptsMatchTheirExpandedText() throws {
        let text = Self.lines.joined(separator: "\n")
        let (out, removed) = PromptHistory.removing(prompt: "fix a\nb\nc now", projectDirectory: "-w-a", sessionID: "S1",
                                                    from: Data(text.utf8))
        #expect(removed == 1)
        #expect(!String(decoding: out, as: UTF8.self).contains("Pasted text"))
        #expect(!String(decoding: out, as: UTF8.self).hasSuffix("\n"))  // no trailing newline added
    }

    @Test func noMatchLeavesTheFileAlone() throws {
        let url = try tempFile(Self.lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(try PromptHistory.remove(prompt: "never sent", projectDirectory: "-w-a", sessionID: "S1", in: url) == 0)
        #expect(try Data(contentsOf: url) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == mtime)
    }

    @Test func fileRewriteIsAtomicAndKeepsMode() throws {
        let url = try tempFile(Self.lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try PromptHistory.remove(prompt: "remember PINEAPPLE", projectDirectory: "-w-a", sessionID: "S1", in: url) == 2)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.components(separatedBy: "\n").filter { $0.contains("PINEAPPLE") }.count == 3)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["history.jsonl"])
    }

    @Test func bomStaysWhenTheFirstLineIsRemoved() throws {
        let body = Self.lines[1] + "\n" + Self.lines[0] + "\n"
        let url = try tempFile("")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try (Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)).write(to: url)
        #expect(try PromptHistory.remove(prompt: "remember PINEAPPLE", projectDirectory: "-w-a", sessionID: "S1", in: url) == 1)
        #expect(try Data(contentsOf: url) == Data([0xEF, 0xBB, 0xBF]) + Data((Self.lines[0] + "\n").utf8))
    }

    /// Claude holding its lock the whole time is reported (forget tells the user), never a silent 0.
    @Test func lockHeldThroughoutThrowsAndTouchesNothing() throws {
        let url = try tempFile(Self.lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = url.appendingPathExtension("lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        let before = try Data(contentsOf: url)
        let start = Date()
        #expect(throws: PromptHistory.HistoryError.locked(url.resolvingSymlinksInPath().path)) {
            try PromptHistory.remove(prompt: "remember PINEAPPLE", projectDirectory: "-w-a", sessionID: "S1", in: url,
                                     lockTimeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) >= 0.25)  // retried until the timeout
        #expect(try Data(contentsOf: url) == before)
        #expect(FileManager.default.fileExists(atPath: lock.path))  // Claude's lock is left alone
    }
}
