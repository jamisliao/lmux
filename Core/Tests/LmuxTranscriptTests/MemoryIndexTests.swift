import Foundation
import Testing
@testable import LmuxTranscript

/// Claude's `memory/MEMORY.md` index, on temp dirs only.
@Suite struct MemoryIndexTests {
    static let index = """
        - [Workspace](project_workspace.md) — save artifacts under ~/Desktop
        - [Reply in Korean](feedback_reply_in_korean.md) — every line, even progress
        - [Old reply rule](old_feedback_reply_in_korean.md) — superseded
        Mentions feedback_reply_in_korean.md in prose, no link.
        - [Two](a.md) and [Korean again](feedback_reply_in_korean.md)

        """

    func setUp(mode: mode_t = 0o600) throws -> URL {
        let mem = TestTemp.dir("memory")
        try FileManager.default.createDirectory(at: mem, withIntermediateDirectories: true)
        let url = mem.appendingPathComponent("MEMORY.md")
        try PrivateFile.create(url, Data(Self.index.utf8), mode: mode)
        return mem
    }

    @Test func removesOnlyExactLinkLines() throws {
        let mem = try setUp()
        let n = try MemoryIndex.removeLinks(to: mem.appendingPathComponent("feedback_reply_in_korean.md"), memoryDir: mem)
        // Only the line whose SOLE link targets the file is removed. The last line also links
        // to it, but has a second link (to a.md) too: left untouched so that link isn't lost.
        #expect(n == 1)
        let after = try String(contentsOf: mem.appendingPathComponent("MEMORY.md"), encoding: .utf8)
        #expect(after == """
            - [Workspace](project_workspace.md) — save artifacts under ~/Desktop
            - [Old reply rule](old_feedback_reply_in_korean.md) — superseded
            Mentions feedback_reply_in_korean.md in prose, no link.
            - [Two](a.md) and [Korean again](feedback_reply_in_korean.md)

            """)
    }

    @Test func multiLinkLineNeverRemoved() throws {
        let mem = try setUp()
        // a.md is also only mentioned on the multi-link line: removing it must leave that line
        // (and its still-valid link to feedback_reply_in_korean.md) alone.
        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("a.md"), memoryDir: mem) == 0)
        #expect(try String(contentsOf: mem.appendingPathComponent("MEMORY.md"), encoding: .utf8) == Self.index)
    }

    @Test func matchesRelativeDotSlashAndTitledLinks() throws {
        let mem = try setUp()
        let text = """
            - [Dot slash](./dotslash.md) — hook
            - [Titled](titled.md "a hook") — hook
            - [TitledDotSlash](./both.md "a hook") — hook

            """
        try PrivateFile.replace(mem.appendingPathComponent("MEMORY.md"), Data(text.utf8), mode: 0o600)
        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("dotslash.md"), memoryDir: mem) == 1)
        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("titled.md"), memoryDir: mem) == 1)
        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("both.md"), memoryDir: mem) == 1)
        #expect(try String(contentsOf: mem.appendingPathComponent("MEMORY.md"), encoding: .utf8) == "")
    }

    @Test func symlinkedMemoryFileRewritesRealTargetAndKeepsTheSymlink() throws {
        let mem = TestTemp.dir("memory")
        try FileManager.default.createDirectory(at: mem, withIntermediateDirectories: true)
        let real = mem.appendingPathComponent("real-MEMORY.md")
        try PrivateFile.create(real, Data(Self.index.utf8), mode: 0o600)
        let link = mem.appendingPathComponent("MEMORY.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real-MEMORY.md")

        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("feedback_reply_in_korean.md"), memoryDir: mem) == 1)

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "real-MEMORY.md",
                "the symlink itself must still be there, pointing at the same name")
        let after = try String(contentsOf: real, encoding: .utf8)
        #expect(after == """
            - [Workspace](project_workspace.md) — save artifacts under ~/Desktop
            - [Old reply rule](old_feedback_reply_in_korean.md) — superseded
            Mentions feedback_reply_in_korean.md in prose, no link.
            - [Two](a.md) and [Korean again](feedback_reply_in_korean.md)

            """, "the real file (the symlink's target) must be rewritten")
        // Reading through the symlink sees the same, updated content.
        #expect(try String(contentsOf: link, encoding: .utf8) == after)
    }

    @Test func resolvesSymlinksConsistentlyOnBothSides() throws {
        // `file` is given through a symlinked ancestor directory while `memoryDir` is given
        // directly: both must resolve to the same real directory (as /tmp vs /private/tmp would)
        // for the file to still be recognized as inside it.
        let real = TestTemp.dir("memory")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let url = real.appendingPathComponent("MEMORY.md")
        try PrivateFile.create(url, Data(Self.index.utf8), mode: 0o600)
        let link = TestTemp.root.appendingPathComponent("memory-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let n = try MemoryIndex.removeLinks(to: link.appendingPathComponent("feedback_reply_in_korean.md"), memoryDir: real)
        #expect(n == 1)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after.contains("project_workspace.md") && !after.contains("[Reply in Korean]"))
    }

    @Test func keepsModeAndIsAtomic() throws {
        let mem = try setUp(mode: 0o640)
        let url = mem.appendingPathComponent("MEMORY.md")
        let inode = { () -> ino_t in var st = stat(); stat(url.path, &st); return st.st_ino }
        let before = inode()
        // Written through PrivateFile.replace (a new file with the final mode from its first
        // byte, renamed over the old one), so the mode is kept and nobody sees a partial file.
        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("project_workspace.md"), memoryDir: mem) == 1)
        #expect(PrivateFile.mode(of: url.path) == 0o640)
        #expect(inode() != before, "replaced by rename, not rewritten in place")
        let left = try FileManager.default.contentsOfDirectory(atPath: mem.path)
        #expect(left == ["MEMORY.md"], "no temp file left: \(left)")
    }

    @Test func newIndexModeDefaultsPrivate() throws {
        let mem = try setUp(mode: 0o600)
        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("project_workspace.md"), memoryDir: mem) == 1)
        #expect(PrivateFile.mode(of: mem.appendingPathComponent("MEMORY.md").path) == 0o600)
    }

    @Test func noMatchTouchesNothing() throws {
        let mem = try setUp()
        let url = mem.appendingPathComponent("MEMORY.md")
        let m0 = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("nope.md"), memoryDir: mem) == 0)
        // Outside the memory dir, or MEMORY.md itself: never.
        #expect(try MemoryIndex.removeLinks(to: URL(fileURLWithPath: "/tmp/a.md"), memoryDir: mem) == 0)
        #expect(try MemoryIndex.removeLinks(to: url, memoryDir: mem) == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.index)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == m0)
    }

    @Test func missingIndexIsFine() throws {
        let mem = TestTemp.dir("memory")
        try FileManager.default.createDirectory(at: mem, withIntermediateDirectories: true)
        #expect(try MemoryIndex.removeLinks(to: mem.appendingPathComponent("a.md"), memoryDir: mem) == 0)
        #expect(!FileManager.default.fileExists(atPath: mem.appendingPathComponent("MEMORY.md").path))
    }
}
