import Foundation

/// A Claude Code session transcript (`~/.claude/projects/<cwd>/<sessionId>.jsonl`).
///
/// Lines are kept as raw strings; only lines that must change are rewritten, and then
/// by targeted substitution so every other byte (key order, escaping, unknown fields)
/// survives. See FORMAT.md for the format notes this relies on.
public struct Transcript {
    public struct Entry {
        /// The line exactly as it will be written (no trailing newline).
        public internal(set) var raw: String
        /// Parsed object, nil for blank or unparseable lines (kept verbatim).
        public internal(set) var object: [String: Any]?

        var type: String? { object?["type"] as? String }
        var uuid: String? { object?["uuid"] as? String }
        var parentUuid: String? { object?["parentUuid"] as? String }
        var isSidechain: Bool { object?["isSidechain"] as? Bool ?? false }
        /// Entries that take part in the parentUuid chain.
        var isChainNode: Bool { uuid != nil && object?.keys.contains("parentUuid") == true }
        var isCompactBoundary: Bool { type == "system" && object?["subtype"] as? String == "compact_boundary" }
        var message: [String: Any]? { object?["message"] as? [String: Any] }
    }

    public struct Turn: Sendable, Equatable {
        /// 1-based position among all listed turns (pre-compaction turns included).
        public let index: Int
        public let uuid: String
        public let timestamp: String?
        public let prompt: String
        public var firstLine: String {
            String(prompt.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
        }
        /// Original markdown of Claude's final text reply in this turn, if any.
        public let assistantText: String?
        /// uuid of the first assistant entry carrying that final reply.
        public let assistantUuid: String?
        /// Turn lies before a compaction boundary; it is no longer in the model's context
        /// verbatim and cannot be removed.
        public let beforeCompaction: Bool
        /// uuids of the chain entries making up this turn (prompt first).
        public let entryUuids: [String]
    }

    public enum TranscriptError: Error, Equatable, CustomStringConvertible {
        case turnNotFound(String)
        case beforeCompaction(String)
        case wouldOrphanToolResult(String)
        case fileChangedSinceLoad(String)
        case noMessage(String)
        case notUTF8(String)

        public var description: String {
            switch self {
            case .turnNotFound(let s): "turn not found: \(s)"
            case .beforeCompaction(let s): "turn \(s) is before a compaction boundary; its content lives in the summary and cannot be removed"
            case .wouldOrphanToolResult(let s): "refusing: removal would leave tool_result \(s) without its tool_use"
            case .fileChangedSinceLoad(let p): "refusing: \(p) changed since it was loaded (is Claude running in this session?)"
            case .noMessage(let s): "no assistant text for \(s)"
            case .notUTF8(let p): "refusing: \(p) is not valid UTF-8, rewriting it would change bytes lmux didn't touch"
            }
        }
    }

    public internal(set) var entries: [Entry]
    let trailingNewline: Bool
    /// The bytes this transcript was loaded from, used to detect concurrent writers.
    let originalData: Data?
    let sourceURL: URL?
    /// The bytes decoded without loss (a BOM is kept as U+FEFF on the first line; invalid
    /// UTF-8 would be replaced by U+FFFD, so such a file is never written back).
    let lossless: Bool

    public init(data: Data, sourceURL: URL? = nil) {
        let text = String(decoding: data, as: UTF8.self)
        lossless = text.utf8.elementsEqual(data)
        var lines = text.components(separatedBy: "\n")
        trailingNewline = text.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        entries = lines.map { line in
            let obj = line.isEmpty ? nil
                : (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            return Entry(raw: line, object: obj)
        }
        originalData = data
        self.sourceURL = sourceURL
    }

    init(scanned entries: [Entry], sourceURL: URL) {
        self.entries = entries
        trailingNewline = true
        originalData = nil
        self.sourceURL = sourceURL
        lossless = false
    }

    /// A read-only outline of a transcript for indexing (`turns()`, titles, cwd, timestamps):
    /// read line by line up to the last complete line, keeping of each entry only the keys
    /// the turn list and the session summary look at. Tool inputs and results (most of a big
    /// file's bytes) are reduced to their block type, and `raw` is empty, so memory stays at a
    /// fraction of the file. Never written back (`serialized()` would be empty).
    public struct Outline {
        public let transcript: Transcript
        /// Byte length of each entry's line (without its newline).
        public let lineLengths: [Int]
        /// Bytes read: up to and including the last newline.
        public let bytes: Int
    }

    static let outlineKeys: Set<String> = [
        "type", "uuid", "parentUuid", "isSidechain", "subtype", "logicalParentUuid", "isMeta", "isCompactSummary",
        "toolUseResult", "sourceToolUseID", "sourceToolAssistantUUID", "turnOrigin", "timestamp", "cwd", "gitBranch",
        "customTitle", "aiTitle", "summary", "explicit", "rewound", "leafUuid",
    ]

    static func outlineObject(_ o: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in o where outlineKeys.contains(k) { out[k] = k == "toolUseResult" ? true : v }
        if let m = o["message"] as? [String: Any] {
            var msg: [String: Any] = [:]
            if let id = m["id"] { msg["id"] = id }
            if let role = m["role"] { msg["role"] = role }
            if let s = m["content"] as? String {
                msg["content"] = s
            } else if let blocks = m["content"] as? [[String: Any]] {
                msg["content"] = blocks.map { b -> [String: Any] in
                    b["type"] as? String == "text" ? ["type": "text", "text": b["text"] ?? ""] : ["type": b["type"] ?? "?"]
                }
            }
            out["message"] = msg
        }
        return out
    }

    /// A line longer than this is not parsed (it still counts, as an unreadable entry): an
    /// unfinished line is never buffered past it.
    public static let outlineMaxLine = 64 << 20

    public static func outline(_ url: URL, chunkSize: Int = 1 << 20, maxLine: Int = outlineMaxLine) throws -> Outline {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var entries: [Entry] = []
        var lengths: [Int] = []
        var pending = Data()
        var skipped = 0  // bytes of an over-long line already dropped
        var bytes = 0
        // Each read in its own pool: Foundation hands the chunks back autoreleased, and a 60MB
        // file's chunks would otherwise all stay alive until the caller's pool drains.
        while let chunk = try autoreleasepool(invoking: { try h.read(upToCount: chunkSize) }), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            // Only the new bytes can hold the next newline (the rest was searched already).
            var from = pending.index(pending.endIndex, offsetBy: -chunk.count)
            while let nl = pending[from...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[start..<nl]
                if skipped > 0 {
                    entries.append(Entry(raw: "", object: nil))
                } else {
                    autoreleasepool {
                        let obj = line.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                        entries.append(Entry(raw: "", object: obj.map(outlineObject)))
                    }
                }
                lengths.append(skipped + line.count)
                bytes += skipped + line.count + 1
                skipped = 0
                start = pending.index(after: nl)
                from = start
            }
            pending = Data(pending[start...])
            if skipped + pending.count > maxLine {
                skipped += pending.count
                pending = Data()
            }
        }
        return Outline(transcript: Transcript(scanned: entries, sourceURL: url), lineLengths: lengths, bytes: bytes)
    }

    public static func load(_ url: URL) throws -> Transcript {
        Transcript(data: try Data(contentsOf: url), sourceURL: url)
    }

    public func serialized() -> Data {
        var s = entries.map(\.raw).joined(separator: "\n")
        if trailingNewline { s += "\n" }
        return Data(s.utf8)
    }

    // MARK: - Chain

    /// The leaf, mirroring Claude Code's loader (2.1.x): the last `last-prompt` entry's
    /// `leafUuid` wins if it exists, except that a non-explicit one yields to the last chain entry in file order
    /// when that entry descends from it. And, as Claude has it live: a prompt typed after the
    /// pointer (after an explicit one, or outside a non-explicit one's branch: a rewind, then a
    /// new prompt, before Claude re-appends the pointer) is the branch; its last chain entry is
    /// the leaf. Anything else after an explicit pointer (a late entry of the branch rewound
    /// away) doesn't move it.
    var leafIndex: Int? {
        let lastChain = entries.lastIndex { $0.isChainNode && !$0.isSidechain }
        guard let at = entries.lastIndex(where: { $0.type == "last-prompt" && $0.object?["leafUuid"] is String }),
              let leafUuid = entries[at].object?["leafUuid"] as? String
        else { return lastChain }
        let byUuid = indexByUuid
        guard let target = byUuid[leafUuid], !entries[target].isSidechain else { return lastChain }
        func descends(_ i: Int, from ancestor: Int) -> Bool {
            var cur: Int? = i
            var seen = Set<Int>()
            while let j = cur, seen.insert(j).inserted {
                if j == ancestor { return true }
                cur = entries[j].parentUuid.flatMap { byUuid[$0] }
            }
            return false
        }
        let prompt = entries.indices.last { $0 > at && Self.isHumanPrompt(entries[$0]) }
        func branch(_ p: Int) -> Int? {
            entries.indices.last { $0 >= p && entries[$0].isChainNode && !entries[$0].isSidechain && descends($0, from: p) }
        }
        if entries[at].object?["explicit"] as? Bool == true { return prompt.flatMap(branch) ?? target }
        if let last = lastChain, descends(last, from: target) { return last }
        if let prompt, !descends(prompt, from: target) { return branch(prompt) }
        return target
    }

    var indexByUuid: [String: Int] {
        var map: [String: Int] = [:]
        for (i, e) in entries.enumerated() { if let u = e.uuid { map[u] = i } }
        return map
    }

    /// Active conversation chain from root to leaf, following `logicalParentUuid` across
    /// compaction boundaries. Each element: (entry index, isBeforeCompaction).
    func activeChain() -> [(index: Int, beforeCompaction: Bool)] {
        guard let leaf = leafIndex else { return [] }
        let byUuid = indexByUuid
        var out: [(Int, Bool)] = []
        var seen = Set<Int>()
        var cur: Int? = leaf
        var crossed = false
        while let i = cur, seen.insert(i).inserted {
            let e = entries[i]
            out.append((i, crossed))
            if let p = e.parentUuid {
                cur = byUuid[p]
            } else if e.isCompactBoundary, let lp = e.object?["logicalParentUuid"] as? String {
                crossed = true
                cur = byUuid[lp]
            } else {
                cur = nil
            }
        }
        return out.reversed()
    }

    // MARK: - Classification

    static let nonPromptPrefixes = [
        "<bash-stdout>", "<bash-stderr>", "<local-command-stdout>", "<local-command-stderr>",
        "<local-command-caveat>", "<task-notification>", "[Request interrupted by user",
    ]

    /// A prompt a human (or `claude -p`) actually sent, as opposed to tool results,
    /// meta/skill expansions, compaction summaries, command output, or notifications.
    static func isHumanPrompt(_ e: Entry) -> Bool {
        guard let o = e.object, e.type == "user", !e.isSidechain else { return false }
        if o["isMeta"] as? Bool == true || o["isCompactSummary"] as? Bool == true { return false }
        if o["toolUseResult"] != nil || o["sourceToolUseID"] != nil || o["sourceToolAssistantUUID"] != nil { return false }
        if let origin = o["turnOrigin"] as? String, !["human", "sdk"].contains(origin) { return false }
        guard let content = e.message?["content"] else { return false }
        let text: String
        if let s = content as? String {
            text = s
        } else if let blocks = content as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return false }
            text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return false
        }
        let trimmed = text.drop { $0.isWhitespace }
        return !nonPromptPrefixes.contains { trimmed.hasPrefix($0) }
    }

    static func promptText(_ e: Entry) -> String {
        let content = e.message?["content"]
        if let s = content as? String { return s }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.map { b in
            (b["text"] as? String) ?? "[\(b["type"] as? String ?? "?")]"
        }.joined(separator: "\n")
    }

    static func textBlocks(_ e: Entry) -> [String] {
        guard e.type == "assistant", let blocks = e.message?["content"] as? [[String: Any]] else { return [] }
        return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
    }

    // MARK: - Turns

    struct Span {
        let promptIndex: Int
        let entryIndices: [Int]
        let beforeCompaction: Bool
    }

    func spans() -> [Span] {
        let chain = activeChain()
        var spans: [Span] = []
        var current: (prompt: Int, members: [Int], before: Bool)?
        for (i, before) in chain {
            let e = entries[i]
            if Self.isHumanPrompt(e) {
                if let c = current { spans.append(Span(promptIndex: c.prompt, entryIndices: c.members, beforeCompaction: c.before)) }
                current = (i, [i], before)
            } else if e.isCompactBoundary {
                if let c = current { spans.append(Span(promptIndex: c.prompt, entryIndices: c.members, beforeCompaction: c.before)) }
                current = nil
            } else if current != nil {
                current!.members.append(i)
            }
        }
        if let c = current { spans.append(Span(promptIndex: c.prompt, entryIndices: c.members, beforeCompaction: c.before)) }
        return spans
    }

    public func turns() -> [Turn] {
        spans().enumerated().map { n, span in
            let p = entries[span.promptIndex]
            let (text, auuid) = finalReply(in: span.entryIndices)
            return Turn(
                index: n + 1,
                uuid: p.uuid ?? "",
                timestamp: p.object?["timestamp"] as? String,
                prompt: Self.promptText(p),
                assistantText: text,
                assistantUuid: auuid,
                beforeCompaction: span.beforeCompaction,
                entryUuids: span.entryIndices.compactMap { entries[$0].uuid }
            )
        }
    }

    /// Text of the last API message in the span that carries text. Claude Code writes one
    /// entry per content block, so a message's blocks are gathered by `message.id`.
    func finalReply(in indices: [Int]) -> (String?, String?) {
        guard let last = indices.last(where: { !Self.textBlocks(entries[$0]).isEmpty }) else { return (nil, nil) }
        return (originalMarkdown(atIndex: last, among: indices), firstEntryUuid(sameMessageAs: last, among: indices))
    }

    func messageId(_ i: Int) -> String? { entries[i].message?["id"] as? String }

    func sameMessage(as i: Int, among indices: [Int]) -> [Int] {
        guard let mid = messageId(i) else { return [i] }
        return indices.filter { entries[$0].type == "assistant" && messageId($0) == mid }
    }

    func firstEntryUuid(sameMessageAs i: Int, among indices: [Int]) -> String? {
        sameMessage(as: i, among: indices).compactMap { entries[$0].uuid }.first
    }

    func originalMarkdown(atIndex i: Int, among indices: [Int]) -> String? {
        let parts = sameMessage(as: i, among: indices).flatMap { Self.textBlocks(entries[$0]) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Original markdown of the assistant message containing the entry `uuid`
    /// (all text blocks of that API message, joined by blank lines).
    public func originalMarkdown(forAssistantUuid uuid: String) throws -> String {
        guard let i = indexByUuid[uuid], entries[i].type == "assistant" else { throw TranscriptError.noMessage(uuid) }
        guard let md = originalMarkdown(atIndex: i, among: Array(entries.indices)) else { throw TranscriptError.noMessage(uuid) }
        return md
    }

    /// Resolve a selector: 1-based turn index, full uuid, or a uuid prefix (>= 6 chars).
    public func turn(matching selector: String) throws -> Turn {
        let all = turns()
        if let n = Int(selector), let t = all.first(where: { $0.index == n }) { return t }
        if let t = all.first(where: { $0.uuid == selector }) { return t }
        let hits = selector.count >= 6 ? all.filter { $0.uuid.hasPrefix(selector) } : []
        if hits.count == 1 { return hits[0] }
        throw TranscriptError.turnNotFound(selector)
    }

    // MARK: - Removal

    public struct RemovalPlan: Sendable {
        public let turn: Turn
        public let removedUuids: [String]
        /// uuid of the entry that got relinked, and its new parent.
        public let relinked: [(uuid: String, newParent: String?)]
    }

    /// Returns a copy with the turn (prompt + everything until the next prompt) removed and
    /// the chain relinked around it.
    public func removing(turnUuid: String) throws -> Transcript {
        try removingWithPlan(turnUuid: turnUuid).0
    }

    public func removingWithPlan(turnUuid: String) throws -> (Transcript, RemovalPlan) {
        let all = turns()
        guard let turn = all.first(where: { $0.uuid == turnUuid }),
              let span = spans().first(where: { entries[$0.promptIndex].uuid == turnUuid })
        else { throw TranscriptError.turnNotFound(turnUuid) }
        if span.beforeCompaction { throw TranscriptError.beforeCompaction("#\(turn.index) \(turnUuid)") }

        let chainSet = Set(activeChain().map(\.index))
        var removed = Set(span.entryIndices.compactMap { entries[$0].uuid })
        // Off-chain descendants (abandoned branches, legacy inline sidechains) go with it.
        var changed = true
        while changed {
            changed = false
            for (i, e) in entries.enumerated() where !chainSet.contains(i) {
                if let u = e.uuid, !removed.contains(u), let p = e.parentUuid, removed.contains(p) {
                    removed.insert(u); changed = true
                }
            }
        }
        let newParent = entries[span.promptIndex].parentUuid

        var out = self
        var relinked: [(String, String?)] = []
        var keep: [Entry] = []
        var removedInOrder: [String] = []
        for (i, var e) in entries.enumerated() {
            if let u = e.uuid, removed.contains(u) { removedInOrder.append(u); continue }
            if let p = e.parentUuid, removed.contains(p) {
                e.setString("parentUuid", from: p, to: newParent)
                relinked.append((e.uuid ?? "?", newParent))
            }
            // Stale resume pointers into the removed turn, and the SDK queue record of its
            // prompt, would otherwise keep the forgotten prompt text (shown by /resume).
            if e.type == "last-prompt", let leaf = e.object?["leafUuid"] as? String, removed.contains(leaf) { continue }
            if e.type == "queue-operation", e.object?["content"] as? String == turn.prompt { continue }
            // Claude's generated title, written once the forgotten prompt was there, is often made
            // of its words ("Remember secret word PINEAPPLE"); lmux shows it and History indexes it.
            // A title the user set (`custom-title`) stays.
            if e.type == "ai-title", i > span.promptIndex { continue }
            keep.append(e)
        }
        out.entries = keep
        try out.checkToolPairs()
        let plan = RemovalPlan(turn: turn, removedUuids: removedInOrder, relinked: relinked)
        return (out, plan)
    }

    /// Every tool_result on a non-sidechain entry must answer a tool_use that still exists.
    func checkToolPairs() throws {
        var uses = Set<String>()
        for e in entries where e.type == "assistant" {
            for b in e.message?["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_use" {
                if let id = b["id"] as? String { uses.insert(id) }
            }
        }
        for e in entries where e.type == "user" && !e.isSidechain {
            for b in e.message?["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_result" {
                if let id = b["tool_use_id"] as? String, !uses.contains(id) {
                    throw TranscriptError.wouldOrphanToolResult(id)
                }
            }
        }
    }

    // MARK: - Writing

    /// Atomically writes the transcript, keeping the file's mode (0600 for a new file). If
    /// `url` exists it is first copied to `<name>.bak` (or `<name>.bak.N` if that exists),
    /// created 0600. When `url` is the file this transcript was loaded from, refuses if it
    /// changed on disk since loading.
    @discardableResult
    public func write(to url: URL) throws -> URL? {
        guard lossless else { throw TranscriptError.notUTF8(url.path) }
        let fm = FileManager.default
        var backup: URL?
        let mode = PrivateFile.mode(of: url.path) ?? 0o600
        if fm.fileExists(atPath: url.path) {
            let current = try Data(contentsOf: url)
            if let src = sourceURL, src.standardizedFileURL == url.standardizedFileURL, current != originalData {
                throw TranscriptError.fileChangedSinceLoad(url.path)
            }
            var candidate = url.appendingPathExtension("bak")
            var n = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = url.appendingPathExtension("bak.\(n)")
                n += 1
            }
            try PrivateFile.create(candidate, current)
            backup = candidate
        }
        try PrivateFile.replace(url, serialized(), mode: mode)
        return backup
    }
}

extension Transcript.Entry {
    /// Replace a string field, touching only that substring of the raw line when possible.
    mutating func setString(_ key: String, from old: String, to new: String?) {
        let needle = "\"\(key)\":\"\(old)\""
        let replacement = "\"\(key)\":" + (new.map { "\"\($0)\"" } ?? "null")
        if raw.components(separatedBy: needle).count == 2 {
            raw = raw.replacingOccurrences(of: needle, with: replacement)
        } else if var o = object {
            // Fallback: re-serialize (key order may change, content is preserved).
            o[key] = new ?? NSNull()
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) {
                raw = String(decoding: d, as: UTF8.self)
            }
        }
        object?[key] = new ?? NSNull()
    }
}
