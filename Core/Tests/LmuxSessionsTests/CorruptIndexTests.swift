import Foundation
import Testing
@testable import LmuxSessions

/// An unreadable sessions.db (garbage, truncated by a full disk or a crash) used to make every
/// SessionIndex init throw, so History stayed empty on every launch until the file was deleted
/// by hand. It is now kept aside and rebuilt from the transcripts.
struct CorruptIndexTests {
    func setup() throws -> (db: URL, root: URL, dir: URL) {
        let dir = TestTemp.dir("corrupt")
        let root = dir.appendingPathComponent("projects", isDirectory: true)
        let proj = root.appendingPathComponent("-work-app", isDirectory: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        var f = Fixture("s-corrupt", cwd: "/work/app")
        f.prompt("index me again")
        f.reply("done")
        try f.data.write(to: proj.appendingPathComponent("s-corrupt.jsonl"))
        return (dir.appendingPathComponent("sessions.db"), root, dir)
    }

    func asides(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("sessions.db.bad-") }.sorted()
    }

    @Test(arguments: ["garbage", "truncated"])
    func unreadableIndexIsKeptAsideAndRebuilt(_ kind: String) throws {
        let (db, root, dir) = try setup()
        if kind == "garbage" {
            try Data((0..<40_000).map { _ in UInt8.random(in: 0...255) }).write(to: db)
        } else {
            // A real index, cut short (what a torn write leaves).
            do { let i = try SessionIndex(databaseURL: db, projectsRoot: root, archiveDirectory: nil); _ = try i.refresh() }
            for s in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) }
            let whole = try Data(contentsOf: db)
            try whole.prefix(3000).write(to: db)
        }
        let original = try Data(contentsOf: db)

        let index = try SessionIndex(databaseURL: db, projectsRoot: root, archiveDirectory: nil)
        _ = try index.refresh()
        #expect(try index.sessions().map(\.id) == ["s-corrupt"])
        let kept = asides(dir)
        #expect(kept.contains { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
        let backup = kept.first { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }.map { dir.appendingPathComponent($0) }
        #expect(backup.flatMap { try? Data(contentsOf: $0) } == original)
    }

    @Test func healthyIndexIsNeverSetAside() throws {
        let (db, root, dir) = try setup()
        do { let i = try SessionIndex(databaseURL: db, projectsRoot: root, archiveDirectory: nil); _ = try i.refresh() }
        let again = try SessionIndex(databaseURL: db, projectsRoot: root, archiveDirectory: nil)
        #expect(try again.sessions().map(\.id) == ["s-corrupt"])
        #expect(asides(dir).isEmpty)
    }
}
