import Foundation
import Testing
@testable import LmuxSessions

/// Forget: lmux's own copies of a session (archive, index text, WAL) don't outlive the edit.
@Suite struct PurgeTests {
    @Test func purgeRemovesArchiveAndIndexedText() throws {
        let env = try Env()
        let sid = "8e1f0c2a-0000-4000-8000-00000000c001"
        var f = Fixture(sid, cwd: "/tmp/purge")
        _ = f.prompt("remember PINEAPPLEWORD")
        f.reply("ok")
        try env.write(f)
        let idx = try env.index()
        try idx.refresh()
        let archived = try idx.archive(sid)
        #expect(FileManager.default.fileExists(atPath: archived.path))
        #expect(try !idx.search("PINEAPPLEWORD").isEmpty)
        // The transcript is rewritten without the turn (forget's surgery), then lmux purges its copies.
        var g = Fixture(sid, cwd: "/tmp/purge")
        _ = g.prompt("something else")
        g.reply("ok")
        try env.write(g)
        try idx.purgeCopies(sid)
        #expect(!FileManager.default.fileExists(atPath: archived.path))
        #expect(try idx.search("PINEAPPLEWORD").isEmpty)
        #expect(throws: SessionIndexError.noArchive(sid)) { try idx.restore(sid) }
        try idx.refresh()
        #expect(try idx.search("PINEAPPLEWORD").isEmpty)
        #expect(try idx.search("something").count == 1)
        // secure_delete is on and the WAL was truncated: the forgotten word is nowhere in the db files.
        for name in ["sessions.db", "sessions.db-wal"] {
            let u = env.dbURL.deletingLastPathComponent().appendingPathComponent(name)
            let d = (try? Data(contentsOf: u)) ?? Data()
            #expect(d.range(of: Data("PINEAPPLEWORD".utf8)) == nil, "\(name)")
        }
    }
}
