import Foundation

/// Claude Code's prompt history (`~/.claude/history.jsonl`, what ↑ recalls in the input).
/// One JSON object per line: `display` (the prompt as typed, pastes shown as
/// `[Pasted text #N +K lines]`), `pastedContents` (`{"N": {"content": …}}`), `timestamp`,
/// `project` (cwd) and `sessionId`.
///
/// Forgetting a turn also drops the lines that recorded exactly that prompt in that
/// project and session. Every other line is kept byte for byte. `project` is the
/// directory Claude was started in, which is also the transcript's folder under
/// `projects/` (sanitized), so lines are matched by that folder name.
public enum PromptHistory {
    public enum HistoryError: Error, Equatable, CustomStringConvertible {
        /// Claude held its lock on the history file the whole time lmux waited.
        case locked(String)
        public var description: String {
            switch self {
            case .locked(let p): "\(p) is locked by Claude Code"
            }
        }
    }

    /// Tests: runs right before the rewritten file replaces the original.
    nonisolated(unsafe) public static var beforeRename: (() -> Void)?
    public static func defaultURL(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let dir = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.claude")
        return URL(fileURLWithPath: dir).appendingPathComponent("history.jsonl")
    }

    /// Claude Code's folder name for a project path (`/a/b.c` -> `-a-b-c`).
    public static func projectDirectoryName(forCwd cwd: String) -> String {
        String(cwd.utf16.map { u -> Character in
            let isAlnum = (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122)
            return isAlnum ? Character(UnicodeScalar(UInt8(u))) : "-"
        })
    }

    static let pastePlaceholder = try! NSRegularExpression(pattern: #"\[Pasted text #(\d+)[^\]]*\]"#)

    /// The prompt a history line stands for: paste placeholders expanded, from the inline
    /// `content` or, for big pastes, `paste-cache/<contentHash>.txt` next to the history file.
    static func prompt(of o: [String: Any], pasteCache: URL?) -> String? {
        guard let display = o["display"] as? String else { return nil }
        guard let pasted = o["pastedContents"] as? [String: Any], !pasted.isEmpty else { return display }
        var out = display
        let ns = display as NSString
        for m in pastePlaceholder.matches(in: display, range: NSRange(location: 0, length: ns.length)).reversed() {
            let id = ns.substring(with: m.range(at: 1))
            let entry = pasted[id] as? [String: Any]
            var content = entry?["content"] as? String
            if content == nil, let hash = entry?["contentHash"] as? String, let dir = pasteCache, isHash(hash) {
                content = try? String(contentsOf: dir.appendingPathComponent(hash + ".txt"), encoding: .utf8)
            }
            guard let content, let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: content)
        }
        return out
    }

    static func isHash(_ s: String) -> Bool { !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isHexDigit } }

    static func hashes(of o: [String: Any]) -> [String] {
        ((o["pastedContents"] as? [String: Any]) ?? [:]).values.compactMap { ($0 as? [String: Any])?["contentHash"] as? String }
    }

    /// A transcript prompt with images is its text block(s) plus "[image]" per image block;
    /// history keeps only the text (`[Image #1] …`).
    static func same(_ history: String, _ prompt: String) -> Bool {
        if history == prompt { return true }
        let text = prompt.components(separatedBy: "\n").filter { $0 != "[image]" }.joined(separator: "\n")
        return text != prompt && history == text
    }

    /// `data` without the lines recording `prompt` for `sessionID` in the project whose
    /// transcript folder is `projectDirectory`. Also returns the paste-cache hashes those lines used.
    public static func removing(prompt: String, projectDirectory: String, sessionID: String, from data: Data,
                                pasteCache: URL? = nil) -> (Data, removed: Int) {
        let r = scan(prompt: prompt, projectDirectory: projectDirectory, sessionID: sessionID, data: data, pasteCache: pasteCache)
        return (r.out, r.removed)
    }

    static func scan(prompt: String, projectDirectory: String, sessionID: String, data: Data, pasteCache: URL?)
        -> (out: Data, removed: Int, hashes: Set<String>) {
        var out = Data()
        out.reserveCapacity(data.count)
        var removed = 0
        var hashes = Set<String>()
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A)
            let end = nl ?? data.endIndex
            let line = data[start..<end]
            var drop = false
            // Cheap prefilter before parsing: the session id must appear in the line.
            if line.range(of: Data(sessionID.utf8)) != nil,
               let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
               o["sessionId"] as? String == sessionID,
               (o["project"] as? String).map(projectDirectoryName) == projectDirectory,
               let p = self.prompt(of: o, pasteCache: pasteCache), same(p, prompt) {
                drop = true
                hashes.formUnion(Self.hashes(of: o))
            }
            if drop {
                removed += 1
            } else {
                out.append(line)
                if nl != nil { out.append(0x0A) }
            }
            start = nl.map { data.index(after: $0) } ?? data.endIndex
        }
        // The last line was dropped: keep the file's trailing-newline convention.
        if removed > 0, data.last != 0x0A, out.last == 0x0A { out.removeLast() }
        // So was the first: a UTF-8 BOM belongs to the file, not to that line.
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        if removed > 0, data.starts(with: bom), !out.starts(with: bom) { out.insert(contentsOf: bom, at: out.startIndex) }
        return (out, removed, hashes)
    }

    /// Claude Code appends to history.jsonl under proper-lockfile: a `<file>.lock` directory,
    /// stale after 10s. lmux takes the same lock around its rewrite.
    static let lockStale: TimeInterval = 10

    static func lock(_ file: URL, timeout: TimeInterval = 5) -> URL? {
        let lock = URL(fileURLWithPath: file.path + ".lock")
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if mkdir(lock.path, 0o755) == 0 { return lock }
            guard errno == EEXIST else { return nil }
            let m = (try? FileManager.default.attributesOfItem(atPath: lock.path)[.modificationDate] as? Date) ?? Date()
            if Date().timeIntervalSince(m) > lockStale { rmdir(lock.path); continue }
            usleep(50_000)
        }
        return nil
    }

    /// Rewrite `url` atomically without those lines (mode kept, from creation on), holding
    /// Claude's lock. A line appended to the old file while lmux rewrote it (a writer that
    /// didn't lock) is carried over after the rename. Paste-cache files of removed lines go
    /// too, unless another line still uses them. Returns how many lines were removed; 0 means
    /// none matched (nothing touched). Throws `HistoryError.locked` if Claude's lock stayed
    /// held for `lockTimeout` (retried every 50ms until then; nothing touched either).
    @discardableResult
    public static func remove(prompt: String, projectDirectory: String, sessionID: String, in url: URL,
                              lockTimeout: TimeInterval = 3) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        let real = url.resolvingSymlinksInPath()
        let cache = real.deletingLastPathComponent().appendingPathComponent("paste-cache", isDirectory: true)
        guard let lock = lock(real, timeout: lockTimeout) else { throw HistoryError.locked(real.path) }
        defer { rmdir(lock.path) }
        let old = try FileHandle(forReadingFrom: real)
        defer { try? old.close() }
        let data = try old.readToEnd() ?? Data()
        let r = scan(prompt: prompt, projectDirectory: projectDirectory, sessionID: sessionID, data: data, pasteCache: cache)
        guard r.removed > 0 else { return 0 }
        let tmp = real.deletingLastPathComponent().appendingPathComponent(".\(real.lastPathComponent).lmux-\(getpid())")
        try? fm.removeItem(at: tmp)
        try PrivateFile.create(tmp, r.out, mode: PrivateFile.mode(of: real.path) ?? 0o600)
        beforeRename?()
        guard rename(tmp.path, real.path) == 0 else {
            let e = errno
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        // Rename, then verify: whatever reached the old file after our read goes to the new one.
        try old.seek(toOffset: UInt64(data.count))
        if let late = try old.readToEnd(), !late.isEmpty, let h = FileHandle(forWritingAtPath: real.path) {
            defer { try? h.close() }
            try h.seekToEnd()
            if r.out.last != 0x0A, !r.out.isEmpty, late.first != 0x0A { try h.write(contentsOf: Data([0x0A])) }
            try h.write(contentsOf: late)
        }
        // Paste bodies nobody references any more.
        if !r.hashes.isEmpty {
            let remaining = (try? Data(contentsOf: real)) ?? Data()
            for hash in r.hashes where isHash(hash) && remaining.range(of: Data("\"\(hash)\"".utf8)) == nil {
                try? fm.removeItem(at: cache.appendingPathComponent(hash + ".txt"))
            }
        }
        return r.removed
    }
}
