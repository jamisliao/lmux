import Foundation
import LmuxTranscript

/// The CLI a session belongs to (what resumes it).
public enum SessionAgent: String, Sendable, Equatable, CaseIterable {
    case claude
    case codex
}

/// A Claude Code (or Codex CLI) session as seen by lmux's History sidebar.
public struct SessionRecord: Sendable, Equatable {
    public let id: String
    /// Directory name under the projects root (`-Users-me-repo`).
    public let projectDirectory: String
    /// Where the transcript lives (or lived, if `isMissing`).
    public let path: URL
    /// Working directory the session was started in, from the entries' `cwd` field.
    public let cwd: String?
    /// Display title: custom title, else AI title, else legacy summary.
    public var title: String? { customTitle ?? aiTitle ?? summary }
    public let customTitle: String?
    public let aiTitle: String?
    public let summary: String?
    public let firstPrompt: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let turnCount: Int
    public let fileSize: Int
    public let gitBranch: String?
    /// Source jsonl no longer exists (e.g. Claude's retention cleanup). The row and its
    /// search text are kept; `isArchived` says whether it can be restored.
    public let isMissing: Bool
    /// Soft-deleted in lmux (hidden from the list and search by default).
    public let isHidden: Bool
    public let archivedAt: Date?
    public var isArchived: Bool { archivedAt != nil }
    public var agent: SessionAgent = .claude
}

public struct SearchHit: Sendable {
    public enum Field: String, Sendable { case prompt, reply }
    public let session: SessionRecord
    /// 1-based turn index (same numbering as `Transcript.turns()`).
    public let turnIndex: Int
    public let turnUuid: String
    public let timestamp: Date?
    public let field: Field
    /// One line of context around the first match; newlines collapsed.
    public let snippet: String
    /// Ranges in `snippet` matching any query term.
    public let highlights: [Range<String.Index>]
}

public struct ResumeInfo: Sendable, Equatable {
    public let cwd: String
    public let arguments: [String]
    /// `cd '<cwd>' && claude --resume <id>` (`codex resume <id>` for Codex), shell-quoted.
    public let shellCommand: String
    /// The transcript is gone; call `restore(_:)` first.
    public let needsRestore: Bool
    public let cwdExists: Bool
}

public struct RefreshStats: Sendable, Equatable {
    public var scanned = 0
    public var unchanged = 0
    public var appended = 0
    public var reindexed = 0
    public var newlyMissing = 0
    public var reappeared = 0
}

public enum SessionIndexError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case archivingDisabled
    case noArchive(String)
    case sourceExists(String)
    case outsideRoot(String)

    public var description: String {
        switch self {
        case .notFound(let id): "session not found: \(id)"
        case .archivingDisabled: "archiving is disabled (no archive directory configured)"
        case .noArchive(let id): "no archived copy of \(id)"
        case .sourceExists(let p): "refusing to overwrite existing transcript \(p)"
        case .outsideRoot(let p): "refusing to touch \(p): outside the configured root"
        }
    }
}

/// SQLite (FTS5) index of all Claude Code sessions under a projects root.
///
/// Source transcripts are only ever read, except by `restore` (writes a missing file
/// back) and `moveToTrash` (explicit hard delete, via the macOS Trash). Not thread-safe:
/// use from one actor/queue.
public final class SessionIndex {
    public let databaseURL: URL
    public let projectsRoot: URL
    /// lmux's own archive of compressed transcripts; nil disables archiving.
    public let archiveDirectory: URL?
    /// Codex CLI's home (`$CODEX_HOME`, `~/.codex`): its `sessions/` are indexed too. nil: Claude only.
    public let codexHome: URL?
    let db: SQLiteDB

    public static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }
    public static var defaultSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/lmux", isDirectory: true)
    }
    public static var defaultDatabaseURL: URL { defaultSupportDirectory.appendingPathComponent("sessions.db") }
    public static var defaultArchiveDirectory: URL { defaultSupportDirectory.appendingPathComponent("archive", isDirectory: true) }

    public init(databaseURL: URL = SessionIndex.defaultDatabaseURL,
                projectsRoot: URL = SessionIndex.defaultProjectsRoot,
                archiveDirectory: URL? = SessionIndex.defaultArchiveDirectory,
                codexHome: URL? = nil) throws {
        self.databaseURL = databaseURL
        self.projectsRoot = projectsRoot.standardizedFileURL
        self.archiveDirectory = archiveDirectory?.standardizedFileURL
        self.codexHome = codexHome?.standardizedFileURL
        // lmux's state dir: private like everything in it (0700, never the umask's 755).
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            db = try Self.open(databaseURL)
        } catch let e as SQLiteDB.Failure where e.isCorrupt {
            // The index is rebuilt from the transcripts: an unreadable one (a crash or a full disk
            // mid-write) is kept aside as `sessions.db.bad-<time>` and started over, instead of
            // History failing on every launch.
            Self.setAside(databaseURL)
            db = try Self.open(databaseURL)
        }
    }

    private static func open(_ url: URL) throws -> SQLiteDB {
        let db = try SQLiteDB(path: url.path)
        // secure_delete: freed pages are zeroed, so text removed by forget doesn't linger in the file.
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON;")
        try db.exec(Self.schema)
        try migrate(db)
        return db
    }

    /// Renames the database and its -wal / -shm to `<name>.bad-<unix time>[-wal|-shm]`.
    static func setAside(_ url: URL) {
        let bad = url.path + ".bad-\(Int(Date().timeIntervalSince1970))"
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            if rename(url.path + suffix, bad + suffix) != 0 { unlink(url.path + suffix) }
        }
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS sessions(
      id TEXT PRIMARY KEY,
      project_dir TEXT NOT NULL,
      path TEXT NOT NULL,
      cwd TEXT,
      first_prompt TEXT,
      custom_title TEXT,
      ai_title TEXT,
      summary TEXT,
      created REAL,
      updated REAL,
      turn_count INTEGER NOT NULL DEFAULT 0,
      git_branch TEXT,
      file_size INTEGER NOT NULL DEFAULT 0,
      file_mtime REAL NOT NULL DEFAULT 0,
      file_inode INTEGER NOT NULL DEFAULT 0,
      indexed_bytes INTEGER NOT NULL DEFAULT 0,
      tail_fp BLOB,
      last_turn_offset INTEGER,
      last_turn_uuid TEXT,
      missing INTEGER NOT NULL DEFAULT 0,
      hidden INTEGER NOT NULL DEFAULT 0,
      archive_path TEXT,
      archived_at REAL,
      archived_size INTEGER,
      archived_mtime REAL
    );
    CREATE INDEX IF NOT EXISTS sessions_updated ON sessions(updated DESC);
    CREATE VIRTUAL TABLE IF NOT EXISTS turns_fts USING fts5(
      prompt, reply,
      session_id UNINDEXED, turn UNINDEXED, turn_uuid UNINDEXED, ts UNINDEXED,
      tokenize='trigram'
    );
    """

    // MARK: - Listing

    static let recordColumns = """
    id, project_dir, path, cwd, custom_title, ai_title, summary, first_prompt, created, updated,
    turn_count, file_size, git_branch, missing, hidden, archived_at, agent
    """

    static func record(_ s: Statement, offset o: Int32 = 0) -> SessionRecord {
        SessionRecord(
            id: s.string(o) ?? "",
            projectDirectory: s.string(o + 1) ?? "",
            path: URL(fileURLWithPath: s.string(o + 2) ?? ""),
            cwd: s.string(o + 3),
            customTitle: s.string(o + 4),
            aiTitle: s.string(o + 5),
            summary: s.string(o + 6),
            firstPrompt: s.string(o + 7),
            createdAt: s.optDouble(o + 8).map(Date.init(timeIntervalSince1970:)),
            updatedAt: s.optDouble(o + 9).map(Date.init(timeIntervalSince1970:)),
            turnCount: s.int(o + 10),
            fileSize: s.int(o + 11),
            gitBranch: s.string(o + 12),
            isMissing: s.int(o + 13) != 0,
            isHidden: s.int(o + 14) != 0,
            archivedAt: s.optDouble(o + 15).map(Date.init(timeIntervalSince1970:)),
            agent: SessionAgent(rawValue: s.string(o + 16) ?? "") ?? .claude
        )
    }

    /// All sessions, most recently updated first, from every project directory.
    public func sessions(includeHidden: Bool = false) throws -> [SessionRecord] {
        let s = try db.prepare("SELECT \(Self.recordColumns) FROM sessions \(includeHidden ? "" : "WHERE hidden=0") ORDER BY updated DESC")
        var out: [SessionRecord] = []
        while try s.step() { out.append(Self.record(s)) }
        return out
    }

    public func session(_ id: String) throws -> SessionRecord? {
        let s = try db.prepare("SELECT \(Self.recordColumns) FROM sessions WHERE id=?")
        try s.bind([id])
        return try s.step() ? Self.record(s) : nil
    }

    func require(_ id: String) throws -> SessionRecord {
        guard let r = try session(id) else { throw SessionIndexError.notFound(id) }
        return r
    }

    // MARK: - Refresh

    struct Stored {
        let path: String
        let size: Int
        let mtime: Double
        let inode: Int
        let indexedBytes: Int
        let tailFP: Data?
        let lastTurnOffset: Int?
        let lastTurnUuid: String?
        let turnCount: Int
        let missing: Bool
        var agent: SessionAgent = .claude
    }

    struct FileInfo {
        let id: String
        let projectDir: String
        let url: URL
        let size: Int
        let mtime: Double
        let inode: Int
        var agent: SessionAgent = .claude
    }

    /// Scans the projects root and brings the index up to date. Unchanged files
    /// (same size and mtime) are skipped; files that only grew are parsed from their last
    /// turn onward; anything else is fully re-indexed. Sessions whose file vanished are
    /// marked missing, never dropped.
    @discardableResult
    public func refresh() throws -> RefreshStats {
        var stats = RefreshStats()
        let files = scan() + scanCodex()
        stats.scanned = files.count
        var stored: [String: Stored] = [:]
        let q = try db.prepare("""
            SELECT id, path, file_size, file_mtime, file_inode, indexed_bytes, tail_fp,
                   last_turn_offset, last_turn_uuid, turn_count, missing, agent FROM sessions
            """)
        while try q.step() {
            stored[q.string(0) ?? ""] = Stored(
                path: q.string(1) ?? "", size: q.int(2), mtime: q.double(3), inode: q.int(4),
                indexedBytes: q.int(5), tailFP: q.data(6), lastTurnOffset: q.optInt(7),
                lastTurnUuid: q.string(8), turnCount: q.int(9), missing: q.int(10) != 0,
                agent: SessionAgent(rawValue: q.string(11) ?? "") ?? .claude)
        }

        var appendable: [(FileInfo, Stored)] = []
        var full: [FileInfo] = []
        for f in files {
            let old = stored[f.id]
            if let old, !old.missing, old.path == f.url.path, old.size == f.size, old.mtime == f.mtime {
                stats.unchanged += 1
            } else if let old, !old.missing, old.path == f.url.path, old.inode == f.inode,
                      // >=: a previous refresh may have read lines written after its stat.
                      f.size >= old.indexedBytes, old.indexedBytes > 0 {
                appendable.append((f, old))
            } else {
                if let old, old.missing { stats.reappeared += 1 }
                full.append(f)
            }
        }
        try db.transaction {
            for (f, old) in appendable {
                if try appendIndex(f, old: old) {
                    stats.appended += 1
                } else {
                    try fullIndex(f)
                    stats.reindexed += 1
                }
            }
        }
        // Parsing dominates a full index and is independent per file: parse a small batch
        // in parallel (half the cores, so a first index never saturates the machine), write
        // it, and move on. Memory stays bounded by one batch instead of the whole corpus.
        let batch = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        for start in stride(from: 0, to: full.count, by: batch) {
            let slice = Array(full[start..<min(start + batch, full.count)])
            try autoreleasepool {
                let parsed = Self.parseInParallel(slice)
                try db.transaction {
                    for (f, p) in zip(slice, parsed) {
                        try fullIndex(f, parsed: try p.get())
                        stats.reindexed += 1
                    }
                }
            }
        }
        try updateCodexTitles()
        try db.transaction {
            let seen = Set(files.map(\.id))
            // Only the agents scanned this time (no Codex home: its sessions are left alone).
            for (id, old) in stored where !old.missing && !seen.contains(id) && (old.agent == .claude || codexHome != nil) {
                try db.run("UPDATE sessions SET missing=1 WHERE id=?", [id])
                stats.newlyMissing += 1
            }
        }
        return stats
    }

    func scan() -> [FileInfo] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [FileInfo] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      attrs[.type] as? FileAttributeType == .typeRegular else { continue }
                out.append(FileInfo(
                    id: String(name.dropLast(6)),
                    projectDir: dir.lastPathComponent,
                    url: url,
                    size: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                    mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                    inode: (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? 0))
            }
        }
        return out
    }

    /// Bytes before the indexed end that must be unchanged for the append fast path
    /// (several lines, so it covers per-entry uuids, not just a common line suffix).
    static let fingerprintLength = 4096

    /// Reads `[from, EOF)` and trims to the last complete line (a line being written is
    /// left for the next refresh).
    static func readCompleteLines(_ url: URL, from offset: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        let data = try h.readToEnd() ?? Data()
        guard let nl = data.lastIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return data.prefix(through: nl)
    }

    static func readRange(_ url: URL, _ offset: Int, _ length: Int) throws -> Data {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        return try h.read(upToCount: length) ?? Data()
    }

    static func fingerprint(_ url: URL, endingAt end: Int) throws -> Data {
        let start = max(0, end - fingerprintLength)
        return try readRange(url, start, end - start)
    }

    struct Chunk: Sendable {
        var turns: [Transcript.Turn] = []
        /// Byte offset (within the chunk) of the last turn's prompt line.
        var lastTurnOffset: Int?
        var cwds: [String] = []
        var gitBranch: String?
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var rewound = false
        /// A session the agent started for itself (Codex review/subagent threads): indexed hidden.
        var internalSession = false
    }

    static func parse(_ data: Data) -> Chunk {
        let t = Transcript(data: data)
        return parse(t, lineLengths: t.entries.map { $0.raw.utf8.count })
    }

    /// `lineLengths`: each entry's line in bytes (offsets of the last turn).
    static func parse(_ t: Transcript, lineLengths: [Int]) -> Chunk {
        var c = Chunk()
        c.turns = t.turns()
        let lastUuid = c.turns.last?.uuid
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var offset = 0
        for (e, length) in zip(t.entries, lineLengths) {
            defer { offset += length + 1 }
            guard let o = e.object else { continue }
            if let lastUuid, o["uuid"] as? String == lastUuid { c.lastTurnOffset = offset }
            if let cwd = o["cwd"] as? String, !cwd.isEmpty, c.cwds.last != cwd, !c.cwds.contains(cwd) { c.cwds.append(cwd) }
            if let b = o["gitBranch"] as? String, !b.isEmpty { c.gitBranch = b }
            if let ts = o["timestamp"] as? String, let d = iso.date(from: ts) ?? isoPlain.date(from: ts) {
                if c.firstTimestamp == nil { c.firstTimestamp = d }
                c.lastTimestamp = d
            }
            switch o["type"] as? String {
            case "custom-title": if let s = o["customTitle"] as? String, !s.isEmpty { c.customTitle = s }
            case "ai-title": if let s = o["aiTitle"] as? String, !s.isEmpty { c.aiTitle = s }
            case "summary": if let s = o["summary"] as? String, !s.isEmpty { c.summary = s }
            case "last-prompt":
                if o["explicit"] as? Bool == true || o["rewound"] != nil { c.rewound = true }
            default: break
            }
        }
        return c
    }

    /// Claude Code's project directory name for a cwd: every non-alphanumeric UTF-16 unit
    /// becomes `-`.
    public static func projectDirectoryName(forCwd cwd: String) -> String {
        PromptHistory.projectDirectoryName(forCwd: cwd)
    }

    /// The cwd that maps to the transcript's directory (sessions can `cd`; resume must
    /// run where Claude stores the file). Falls back to the first cwd seen.
    static func pickCwd(_ candidates: [String], projectDir: String) -> String? {
        candidates.first { projectDirectoryName(forCwd: $0) == projectDir }
            ?? candidates.first { cwd in
                let enc = projectDirectoryName(forCwd: cwd)
                return projectDir.count >= 200 && enc.count > 200 && projectDir.hasPrefix(String(enc.prefix(200)))
            }
            ?? candidates.first
    }

    struct Parsed: Sendable {
        let chunk: Chunk
        let indexedBytes: Int
        let fingerprint: Data
    }

    /// A first index streams the file (`Transcript.outline`): a 60MB transcript of tool output
    /// never sits in memory whole, nor as one JSON object per line.
    static func parseFile(_ url: URL, agent: SessionAgent = .claude) throws -> Parsed {
        if agent == .codex { return try parseCodexFile(url) }
        return try autoreleasepool {
            let o = try Transcript.outline(url)
            return Parsed(chunk: parse(o.transcript, lineLengths: o.lineLengths), indexedBytes: o.bytes,
                          fingerprint: try fingerprint(url, endingAt: o.bytes))
        }
    }

    static func parseInParallel(_ files: [FileInfo]) -> [Result<Parsed, Error>] {
        final class Box: @unchecked Sendable {
            var results: [Result<Parsed, Error>]
            let lock = NSLock()
            init(_ n: Int) { results = Array(repeating: .failure(SessionIndexError.notFound("")), count: n) }
        }
        let box = Box(files.count)
        let urls = files.map(\.url)
        let agents = files.map(\.agent)
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            let r = Result { try parseFile(urls[i], agent: agents[i]) }
            box.lock.withLock { box.results[i] = r }
        }
        return box.results
    }

    func fullIndex(_ f: FileInfo, parsed: Parsed? = nil) throws {
        let p = try parsed ?? Self.parseFile(f.url, agent: f.agent)
        let c = p.chunk
        try db.run("DELETE FROM turns_fts WHERE session_id=?", [f.id])
        try insertTurns(c.turns, sessionId: f.id, base: 0)
        let (fp, indexedBytes) = (p.fingerprint, p.indexedBytes)
        try db.run("""
            INSERT INTO sessions(id, project_dir, path, cwd, first_prompt, custom_title, ai_title, summary,
              created, updated, turn_count, git_branch, file_size, file_mtime, file_inode, indexed_bytes,
              tail_fp, last_turn_offset, last_turn_uuid, missing, agent, hidden)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?)
            ON CONFLICT(id) DO UPDATE SET project_dir=excluded.project_dir, path=excluded.path,
              cwd=excluded.cwd, first_prompt=excluded.first_prompt, custom_title=excluded.custom_title,
              ai_title=excluded.ai_title, summary=excluded.summary, created=excluded.created,
              updated=excluded.updated, turn_count=excluded.turn_count, git_branch=excluded.git_branch,
              file_size=excluded.file_size, file_mtime=excluded.file_mtime, file_inode=excluded.file_inode,
              indexed_bytes=excluded.indexed_bytes, tail_fp=excluded.tail_fp,
              last_turn_offset=excluded.last_turn_offset, last_turn_uuid=excluded.last_turn_uuid, missing=0,
              agent=excluded.agent
            """, [
                f.id, f.projectDir, f.url.path, Self.pickCwd(c.cwds, projectDir: f.projectDir),
                c.turns.first.map { Self.norm($0.prompt) }, c.customTitle, c.aiTitle, c.summary,
                (c.firstTimestamp?.timeIntervalSince1970) ?? f.mtime,
                (c.lastTimestamp?.timeIntervalSince1970) ?? f.mtime,
                c.turns.count, c.gitBranch, f.size, f.mtime, f.inode, indexedBytes, fp,
                c.lastTurnOffset, c.turns.last?.uuid, f.agent.rawValue, c.internalSession,
            ])
    }

    /// Append-only fast path: re-parses from the last indexed turn's prompt to EOF.
    /// Returns false (caller does a full index) if the prefix changed or the new tail
    /// does not continue the last indexed turn (rewind, branch, compaction oddities).
    func appendIndex(_ f: FileInfo, old: Stored) throws -> Bool {
        guard try Self.fingerprint(f.url, endingAt: old.indexedBytes) == old.tailFP else { return false }
        let start = old.lastTurnUuid != nil ? (old.lastTurnOffset ?? -1) : old.indexedBytes
        guard start >= 0, start <= old.indexedBytes else { return false }
        let data = try Self.readCompleteLines(f.url, from: start)
        let newEnd = start + data.count
        guard newEnd > old.indexedBytes else {
            // Only a partial line was added; remember size/mtime, nothing to index yet.
            try db.run("UPDATE sessions SET file_size=?, file_mtime=? WHERE id=?", [f.size, f.mtime, f.id])
            return true
        }
        let c = f.agent == .codex ? Self.parseCodex(data, at: start) : Self.parse(data)
        if c.rewound { return false }
        var base = 0
        if let lastUuid = old.lastTurnUuid {
            guard c.turns.first?.uuid == lastUuid else { return false }
            base = old.turnCount - 1
            try db.run("DELETE FROM turns_fts WHERE session_id=? AND turn>=?", [f.id, old.turnCount])
        }
        try insertTurns(c.turns, sessionId: f.id, base: base)

        let cur = try db.prepare("SELECT cwd, first_prompt, last_turn_offset FROM sessions WHERE id=?")
        try cur.bind([f.id])
        _ = try cur.step()
        let oldCwd = cur.string(0)
        var cwd = oldCwd
        if oldCwd.map({ Self.projectDirectoryName(forCwd: $0) != f.projectDir }) ?? true,
           let picked = Self.pickCwd(c.cwds, projectDir: f.projectDir),
           oldCwd == nil || Self.projectDirectoryName(forCwd: picked) == f.projectDir {
            cwd = picked
        }
        let firstPrompt = cur.string(1) ?? c.turns.first.map { Self.norm($0.prompt) }
        let lastTurnOffset = c.lastTurnOffset.map { start + $0 } ?? cur.optInt(2)
        let fp = try Self.fingerprint(f.url, endingAt: newEnd)
        try db.run("""
            UPDATE sessions SET cwd=?, first_prompt=?,
              custom_title=COALESCE(?, custom_title), ai_title=COALESCE(?, ai_title), summary=COALESCE(?, summary),
              updated=COALESCE(?, updated), turn_count=?, git_branch=COALESCE(?, git_branch),
              file_size=?, file_mtime=?, indexed_bytes=?, tail_fp=?, last_turn_offset=?,
              last_turn_uuid=COALESCE(?, last_turn_uuid)
            WHERE id=?
            """, [
                cwd, firstPrompt, c.customTitle, c.aiTitle, c.summary,
                c.lastTimestamp?.timeIntervalSince1970, base + c.turns.count, c.gitBranch,
                f.size, f.mtime, newEnd, fp, lastTurnOffset, c.turns.last?.uuid, f.id,
            ])
        return true
    }

    static func norm(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    func insertTurns(_ turns: [Transcript.Turn], sessionId: String, base: Int) throws {
        let ins = try db.prepare("INSERT INTO turns_fts(prompt, reply, session_id, turn, turn_uuid, ts) VALUES(?,?,?,?,?,?)")
        for t in turns {
            try ins.bind([Self.norm(t.prompt), t.assistantText.map(Self.norm), sessionId, base + t.index, t.uuid, t.timestamp])
            while try ins.step() {}
        }
    }

    // MARK: - Search

    /// Full-text search over human prompts and Claude's final text replies (no tool
    /// output, no thinking). Whitespace-separated terms are ANDed per turn; each term is a
    /// case-insensitive substring match, so Korean partial words work ("세션" finds
    /// "세션을"). Terms of 3+ characters use the FTS5 trigram index; shorter terms
    /// (common for Korean, e.g. 2-syllable words) fall back to LIKE on the same table.
    public func search(_ query: String, limit: Int = 50, includeHidden: Bool = false) throws -> [SearchHit] {
        let terms = Self.norm(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        let long = terms.filter { $0.count >= 3 }
        let short = terms.filter { $0.count < 3 }
        var conds: [String] = []
        var binds: [Any?] = []
        if !long.isEmpty {
            conds.append("turns_fts MATCH ?")
            binds.append(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND "))
        }
        for t in short {
            conds.append("(f.prompt LIKE ? ESCAPE '\\' OR f.reply LIKE ? ESCAPE '\\')")
            let pat = "%" + t.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            binds += [pat, pat]
        }
        if !includeHidden { conds.append("s.hidden=0") }
        binds.append(limit)
        let sql = """
            SELECT f.prompt, f.reply, f.turn, f.turn_uuid, f.ts, \(Self.recordColumns.split(separator: ",").map { "s." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", "))
            FROM turns_fts f JOIN sessions s ON s.id = f.session_id
            WHERE \(conds.joined(separator: " AND "))
            ORDER BY s.updated DESC, f.turn ASC LIMIT ?
            """
        let s = try db.prepare(sql)
        try s.bind(binds)
        var hits: [SearchHit] = []
        while try s.step() {
            let prompt = s.string(0) ?? ""
            let reply = s.string(1) ?? ""
            let inPrompt = terms.contains { prompt.range(of: $0, options: .caseInsensitive) != nil }
            let text = inPrompt ? prompt : reply
            let (snippet, highlights) = Self.snippet(text, terms: terms)
            hits.append(SearchHit(
                session: Self.record(s, offset: 5),
                turnIndex: s.int(2),
                turnUuid: s.string(3) ?? "",
                timestamp: Self.parseDate(s.string(4)),
                field: inPrompt ? .prompt : .reply,
                snippet: snippet,
                highlights: highlights))
        }
        return hits
    }

    static func snippet(_ text: String, terms: [String], before: Int = 30, after: Int = 90) -> (String, [Range<String.Index>]) {
        let first = terms.compactMap { text.range(of: $0, options: .caseInsensitive) }.min { $0.lowerBound < $1.lowerBound }
        let anchor = first?.lowerBound ?? text.startIndex
        let start = text.index(anchor, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(anchor, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if start > text.startIndex { s = "…" + s }
        if end < text.endIndex { s += "…" }
        var ranges: [Range<String.Index>] = []
        for t in terms {
            var from = s.startIndex
            while let r = s.range(of: t, options: .caseInsensitive, range: from..<s.endIndex) {
                ranges.append(r)
                from = r.upperBound
            }
        }
        return (s, ranges.sorted { $0.lowerBound < $1.lowerBound })
    }

    // MARK: - Resume

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "/-_.,:@%+=".contains($0) }), s.allSatisfy(\.isASCII) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Where and how to resume a session from any directory.
    public func resumeInfo(_ id: String) throws -> ResumeInfo {
        let r = try require(id)
        let cwd = r.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let args = r.agent == .codex ? ["codex", "resume", id] : ["claude", "--resume", id]
        var isDir: ObjCBool = false
        return ResumeInfo(
            cwd: cwd,
            arguments: args,
            shellCommand: "cd \(Self.shellQuote(cwd)) && " + args.map(Self.shellQuote).joined(separator: " "),
            // Codex sessions are never archived (Codex doesn't clean them up): nothing to restore.
            needsRestore: r.agent == .claude && !FileManager.default.fileExists(atPath: r.path.path),
            cwdExists: FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue)
    }

    // MARK: - Soft delete

    /// Hide a session from the list and search. Its transcript is archived first: nothing
    /// in lmux points at it any more, so Claude's cleanup would be the end of it.
    public func setHidden(_ id: String, _ hidden: Bool = true) throws {
        try db.run("UPDATE sessions SET hidden=? WHERE id=?", [hidden, id])
        if db.changes == 0 { throw SessionIndexError.notFound(id) }
        if hidden, archiveDirectory != nil, let r = try? session(id), !r.isArchived, r.agent == .claude { _ = try? archive(id) }
    }

    // MARK: - Archive

    func archiveURL(_ r: SessionRecord) throws -> URL {
        guard let dir = archiveDirectory else { throw SessionIndexError.archivingDisabled }
        return dir.appendingPathComponent(r.projectDirectory, isDirectory: true)
            .appendingPathComponent(r.id + ".jsonl.lzfse")
    }

    /// Copies the session's transcript, LZFSE-compressed, into lmux's archive so it
    /// survives Claude's retention cleanup. The source is only read.
    @discardableResult
    public func archive(_ id: String) throws -> URL {
        let r = try require(id)
        let dest = try archiveURL(r)
        guard FileManager.default.fileExists(atPath: r.path.path) else { throw SessionIndexError.notFound(r.path.path) }
        let attrs = try FileManager.default.attributesOfItem(atPath: r.path.path)
        let data = try Data(contentsOf: r.path, options: .mappedIfSafe)
        let compressed = try (data as NSData).compressed(using: .lzfse) as Data
        // Transcripts are private: dirs 0700, files 0600.
        let fm = FileManager.default
        if let root = archiveDirectory {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dest.deletingLastPathComponent().path)
        try compressed.write(to: dest, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        try db.run("UPDATE sessions SET archive_path=?, archived_at=?, archived_size=?, archived_mtime=? WHERE id=?", [
            dest.path, Date().timeIntervalSince1970, data.count,
            (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, id,
        ])
        return dest
    }

    /// Archives every present session whose archived copy is absent or stale. With
    /// `olderThan`, only sessions at risk: last written before that date (Claude's cleanup
    /// is coming for them) or hidden. Returns how many were (re)archived. Run `refresh()`
    /// first so new files are known.
    @discardableResult
    public func archiveAll(olderThan cutoff: Date? = nil) throws -> Int {
        guard archiveDirectory != nil else { throw SessionIndexError.archivingDisabled }
        let risk = cutoff.map { "AND (file_mtime < \($0.timeIntervalSince1970) OR hidden=1)" } ?? ""
        let s = try db.prepare("""
            SELECT id FROM sessions WHERE missing=0 AND agent='claude' AND
              (archived_at IS NULL OR archived_size IS NOT file_size OR archived_mtime IS NOT file_mtime) \(risk)
            """)
        var ids: [String] = []
        while try s.step() { ids.append(s.string(0) ?? "") }
        var n = 0
        for id in ids {
            do { try autoreleasepool { _ = try archive(id) }; n += 1 } catch SessionIndexError.notFound { continue }
        }
        return n
    }

    /// Claude Code deletes transcripts older than `cleanupPeriodDays` (settings.json,
    /// default 30). Sessions last written more than `cleanupPeriodDays - 5` days ago are
    /// at risk. `settings` is only read.
    public static func archiveCutoff(settings: URL, now: Date = Date()) -> Date {
        var days = 30.0
        if let d = try? Data(contentsOf: settings),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let n = o["cleanupPeriodDays"] as? NSNumber {
            days = n.doubleValue
        }
        return now.addingTimeInterval(-max(0, days - 5) * 86400)
    }

    /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
    public static func claudeSettingsURL(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let dir = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.claude")
        return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
    }

    /// Writes the archived copy back to the projects directory it came from so
    /// `claude --resume` finds it again. Never overwrites a different existing file.
    @discardableResult
    public func restore(_ id: String) throws -> URL {
        let r = try require(id)
        let src = try archiveURL(r)
        guard FileManager.default.fileExists(atPath: src.path) else { throw SessionIndexError.noArchive(id) }
        let data = try (NSData(contentsOf: src).decompressed(using: .lzfse)) as Data
        let dest = projectsRoot.appendingPathComponent(r.projectDirectory, isDirectory: true)
            .appendingPathComponent(id + ".jsonl")
        if FileManager.default.fileExists(atPath: dest.path) {
            guard (try? Data(contentsOf: dest)) == data else { throw SessionIndexError.sourceExists(dest.path) }
        } else {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PrivateFile.create(dest, data)  // 0600 from the first byte, like Claude's own transcripts
        }
        try refresh()
        return dest
    }

    /// The transcript was edited in place (forget): every other copy of what it held goes. The
    /// archived copy is deleted (restore would bring the removed turn back), the session's indexed
    /// text is dropped and re-read from the edited file at the next refresh, and the WAL is
    /// checkpointed and truncated so the old pages (zeroed by secure_delete) leave the disk too.
    public func purgeCopies(_ id: String) throws {
        if let r = try? session(id), let a = try? archiveURL(r), let root = archiveDirectory,
           FileManager.default.fileExists(atPath: a.path), isInside(a, root) {
            try FileManager.default.removeItem(at: a)
        }
        try db.transaction {
            try db.run("DELETE FROM turns_fts WHERE session_id=?", [id])
            try db.run("""
                UPDATE sessions SET first_prompt=NULL, custom_title=NULL, ai_title=NULL, summary=NULL,
                  archive_path=NULL, archived_at=NULL, archived_size=NULL, archived_mtime=NULL,
                  file_size=-1, indexed_bytes=0, tail_fp=NULL, last_turn_offset=NULL, last_turn_uuid=NULL
                WHERE id=?
                """, [id])
        }
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - Hard delete

    func isInside(_ url: URL, _ root: URL) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let r = root.standardizedFileURL.resolvingSymlinksInPath().path
        return p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    /// Explicit hard delete: moves the transcript, its `<id>/` directory (subagents,
    /// tool results) and lmux's archived copy to the macOS Trash (recoverable; nothing is
    /// unlinked), then drops the session from the index. Returns the items' Trash URLs.
    @discardableResult
    public func moveToTrash(_ id: String) throws -> [URL] {
        // A compressed copy goes to the Trash with it, so putting it back stays possible
        // even after the Trash's own transcript copy was edited or lost.
        if archiveDirectory != nil, let r = try? session(id), !r.isArchived, r.agent == .claude { _ = try? archive(id) }
        let r = try require(id)
        let fm = FileManager.default
        var items: [URL] = []
        let jsonl = r.path
        // A Codex rollout is one file (no sidecar directory), under its sessions folder.
        let sidecar = r.agent == .codex ? nil : jsonl.deletingPathExtension()
        let root = r.agent == .codex ? codexSessionsRoot : projectsRoot
        for u in [jsonl, sidecar].compactMap({ $0 }) where fm.fileExists(atPath: u.path) {
            guard let root, isInside(u, root) else { throw SessionIndexError.outsideRoot(u.path) }
            items.append(u)
        }
        if let a = try? archiveURL(r), let root = archiveDirectory, fm.fileExists(atPath: a.path) {
            guard isInside(a, root) else { throw SessionIndexError.outsideRoot(a.path) }
            items.append(a)
        }
        var trashed: [URL] = []
        for u in items {
            var result: NSURL?
            try fm.trashItem(at: u, resultingItemURL: &result)
            if let result { trashed.append(result as URL) }
        }
        try db.transaction {
            try db.run("DELETE FROM turns_fts WHERE session_id=?", [id])
            try db.run("DELETE FROM sessions WHERE id=?", [id])
        }
        return trashed
    }
}
