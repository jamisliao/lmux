import Foundation
import LmuxTranscript

// Codex CLI sessions in History: `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`, read
// with `CodexRollout` and indexed in the same tables as Claude's (an `agent` column tells them
// apart). Titles come from Codex itself: `thread_name_updated` in the rollout, else
// `$CODEX_HOME/session_index.jsonl`. Codex files are only ever read (and moved to the Trash
// on an explicit hard delete); they are not archived: Codex doesn't clean them up.

extension SessionIndex {
    /// `<codexHome>/sessions`.
    public var codexSessionsRoot: URL? { codexHome?.appendingPathComponent("sessions", isDirectory: true) }

    /// `$CODEX_HOME`, else `~/.codex`.
    public static func defaultCodexHome(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = env["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    /// Adds columns newer lmux versions use to a database an older one created.
    static func migrate(_ db: SQLiteDB) throws {
        let s = try db.prepare("PRAGMA table_info(sessions)")
        var cols = Set<String>()
        while try s.step() { cols.insert(s.string(1) ?? "") }
        if !cols.contains("agent") { try db.exec("ALTER TABLE sessions ADD COLUMN agent TEXT NOT NULL DEFAULT 'claude'") }
    }

    /// The session id in a rollout's name: the UUID at its end.
    static func codexSessionID(fileName name: String) -> String? {
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let base = name.dropLast(6)
        guard base.count > 36 else { return nil }
        let id = String(base.suffix(36))
        return UUID(uuidString: id) == nil ? nil : id.lowercased()
    }

    /// Every rollout under `sessions/YYYY/MM/DD/`.
    func scanCodex() -> [FileInfo] {
        guard let root = codexSessionsRoot else { return [] }
        let fm = FileManager.default
        var out: [FileInfo] = []
        func dirs(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        for y in dirs(root) { for m in dirs(y) { for d in dirs(m) {
            for name in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] {
                guard let id = Self.codexSessionID(fileName: name) else { continue }
                let url = d.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      attrs[.type] as? FileAttributeType == .typeRegular else { continue }
                out.append(FileInfo(
                    id: id,
                    projectDir: "codex/\(y.lastPathComponent)/\(m.lastPathComponent)/\(d.lastPathComponent)",
                    url: url,
                    size: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                    mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                    inode: (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? 0,
                    agent: .codex))
            }
        } } }
        return out
    }

    static func chunk(_ p: CodexRollout.Parsed, base: Int) -> Chunk {
        var c = Chunk()
        c.turns = p.turns
        c.lastTurnOffset = p.lastTurnOffset.map { $0 - base }
        c.cwds = p.meta.cwd.map { [$0] } ?? []
        c.gitBranch = p.meta.gitBranch
        c.aiTitle = p.threadName
        c.firstTimestamp = p.firstTimestamp
        c.lastTimestamp = p.lastTimestamp
        c.internalSession = p.meta.isSubagent
        return c
    }

    static func parseCodexFile(_ url: URL) throws -> Parsed {
        try autoreleasepool {
            let p = try CodexRollout.parse(url)
            return Parsed(chunk: chunk(p, base: 0), indexedBytes: p.bytes, fingerprint: try fingerprint(url, endingAt: p.bytes))
        }
    }

    /// Complete lines from byte `offset` on (the append fast path); offsets in the chunk are relative to it.
    static func parseCodex(_ data: Data, at offset: Int) -> Chunk {
        chunk(CodexRollout.parse(data, at: offset), base: offset)
    }

    /// Titles Codex keeps outside the rollout (`session_index.jsonl`): applied where the
    /// rollout itself has none (or an older one).
    func updateCodexTitles() throws {
        guard let home = codexHome else { return }
        let names = CodexThreadNames.all(CodexThreadNames.file(codexHome: home.path))
        guard !names.isEmpty else { return }
        let s = try db.prepare("SELECT id, ai_title FROM sessions WHERE agent='codex'")
        var changed: [(String, String)] = []
        while try s.step() {
            let id = s.string(0) ?? ""
            if let n = names[id], n != s.string(1) { changed.append((id, n)) }
        }
        guard !changed.isEmpty else { return }
        try db.transaction {
            for (id, n) in changed { try db.run("UPDATE sessions SET ai_title=? WHERE id=?", [n, id]) }
        }
    }
}
