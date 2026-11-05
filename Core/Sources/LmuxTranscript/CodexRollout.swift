import Foundation

/// Codex CLI session files ("rollouts"): `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`,
/// one `{"timestamp","type","payload"}` object per line, append-only. The first line is
/// `session_meta` (id, cwd, cli_version, git). There is no uuid/parent tree: a turn is a user
/// prompt and what follows it up to the next prompt.
///
/// Two generations of the format are read:
/// - `event_msg` `user_message` (`message`) / `agent_message` (`message`, `phase`) (Codex ≤ 0.12x)
/// - `event_msg` `item_completed` with `item.type` `UserMessage` / `AgentMessage`
///   (`content: [{text}]`, `phase`) (0.16x)
/// plus `task_complete.last_agent_message` (the turn's final answer) and
/// `thread_name_updated.thread_name` (Codex's own title; newer versions keep titles only in
/// `$CODEX_HOME/session_index.jsonl`, see `CodexThreadNames`). `response_item` lines (what the
/// model saw, including injected context) are ignored: they are not what the user typed.
///
/// `CodexRollout` reads one file incrementally for a pane (the same append test as
/// `TranscriptIndex`: same inode, longer, unchanged bytes before the old end) and hands out
/// `TranscriptIndex.Turn`s, so hover and Copy original work the same way; `parse(_:)` reads a
/// whole file for History. Not thread-safe: use one instance from one queue.
public final class CodexRollout: @unchecked Sendable {
    public struct Meta: Sendable, Equatable {
        public var id: String?
        public var cwd: String?
        public var gitBranch: String?
        public var cliVersion: String?
        /// A session Codex started for itself (a review/subagent thread), not one the user opened.
        public var isSubagent = false
    }

    public let url: URL
    public private(set) var meta = Meta()
    /// Codex's own title for the session (`thread_name_updated`), if this file has one.
    public private(set) var threadName: String?
    public private(set) var turns: [TranscriptIndex.Turn] = []
    public private(set) var bytesParsed = 0
    public private(set) var fullReads = 0

    private var acc = Accumulator(keepText: false)
    private var indexedBytes = 0
    private var inode = 0
    private var tailFP = Data()
    /// A line longer than this is not parsed (like `Transcript.outlineMaxLine`): an unfinished line
    /// is never buffered past it.
    var maxLine = Transcript.outlineMaxLine
    /// The read stopped inside such a line: the next one drops the rest of it, up to its newline.
    private var skippingLine = false

    public init(url: URL) { self.url = url }

    /// A rollout's path (`…/sessions/YYYY/MM/DD/rollout-….jsonl`), not a Claude transcript.
    public static func isRollout(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// `$CODEX_HOME` of a rollout path (four directories above the file), if it is laid out so.
    public static func codexHome(ofRollout path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard parts.count > 5, parts[parts.count - 5] == "sessions" else { return nil }
        return NSString.path(withComponents: Array(parts.dropLast(5)))
    }

    /// Read what was appended since the last call (or everything if the file changed otherwise).
    @discardableResult
    public func update() throws -> Bool {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let ino = (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? 0
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var appendOnly = fullReads > 0 && ino == inode && size >= indexedBytes
        if appendOnly, indexedBytes > 0 {
            let start = max(0, indexedBytes - TranscriptIndex.fingerprintLength)
            try h.seek(toOffset: UInt64(start))
            appendOnly = (try h.read(upToCount: indexedBytes - start) ?? Data()) == tailFP
        }
        if !appendOnly {
            acc = Accumulator(keepText: false)
            meta = Meta()
            threadName = nil
            indexedBytes = 0
            inode = ino
            fullReads += 1
            skippingLine = false
        }
        if appendOnly && size == indexedBytes { return false }
        try h.seek(toOffset: UInt64(indexedBytes))
        var offset = indexedBytes  // the file offset of `pending`'s first byte
        var pending = Data()  // the unfinished line (no newline in it), then the chunk just read
        while true {
            var chunk: Data = try autoreleasepool { try h.read(upToCount: TranscriptIndex.readChunk) ?? Data() }
            if chunk.isEmpty { break }
            if skippingLine {
                guard let nl = chunk.firstIndex(of: 0x0A) else { offset += chunk.count; continue }
                skippingLine = false
                offset += nl - chunk.startIndex + 1
                chunk = chunk[chunk.index(after: nl)...]
            }
            let old = pending.count
            pending.append(chunk)
            // Only the new bytes can hold a newline: appending and searching stay linear in the line.
            if let lastNL = pending[(pending.startIndex + old)...].lastIndex(of: 0x0A) {
                let complete = pending[pending.startIndex...lastNL]
                autoreleasepool { acc.consumeLines(complete, at: offset) }
                offset += complete.count
                pending = Data(pending[pending.index(after: lastNL)...])
            }
            if pending.count > maxLine {
                offset += pending.count
                pending = Data()
                skippingLine = true
            }
        }
        bytesParsed += offset - indexedBytes
        indexedBytes = offset
        let fpStart = max(0, offset - TranscriptIndex.fingerprintLength)
        try h.seek(toOffset: UInt64(fpStart))
        tailFP = try h.read(upToCount: offset - fpStart) ?? Data()
        meta = acc.meta
        threadName = acc.threadName
        turns = acc.indexTurns()
        return true
    }

    /// The original markdown of the turn's final answer.
    public func reply(_ turn: TranscriptIndex.Turn) throws -> String? {
        guard let r = turn.replyLines.last else { return nil }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(r.lowerBound))
        guard let d = try h.read(upToCount: r.count),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return Self.classify(o)?.text
    }

    /// The whole prompt (turns keep at most `TranscriptIndex.promptCap` characters).
    public func fullPrompt(_ turn: TranscriptIndex.Turn) throws -> String {
        guard turn.promptIsTruncated else { return turn.prompt }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(turn.promptLine.lowerBound))
        guard let d = try h.read(upToCount: turn.promptLine.count),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return turn.prompt }
        return Self.classify(o)?.text ?? turn.prompt
    }

    // MARK: - Whole file (History)

    public struct Parsed: Sendable {
        public var meta: Meta
        public var threadName: String?
        /// Prompts and final answers in full (same shape as Claude's, for the search index).
        public var turns: [Transcript.Turn]
        public var firstTimestamp: Date?
        public var lastTimestamp: Date?
        /// Bytes read: up to and including the last newline.
        public var bytes: Int
        /// Byte offset of the last turn's prompt line.
        public var lastTurnOffset: Int?
    }

    /// Streams the file (one chunk at a time; a big rollout of tool output never sits in memory whole).
    public static func parse(_ url: URL, chunkSize: Int = 1 << 20) throws -> Parsed {
        try parse(url, from: 0, chunkSize: chunkSize)
    }

    /// From byte `offset` on (a line start), offsets stay absolute.
    public static func parse(_ url: URL, from offset: Int, chunkSize: Int = 1 << 20) throws -> Parsed {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        var acc = Accumulator(keepText: true)
        var pending = Data()
        var bytes = offset
        while let chunk = try autoreleasepool(invoking: { try h.read(upToCount: chunkSize) }), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastNL = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...lastNL]
            autoreleasepool { acc.consumeLines(complete, at: bytes) }
            bytes += complete.count
            pending = Data(pending[pending.index(after: lastNL)...])
        }
        return Parsed(meta: acc.meta, threadName: acc.threadName, turns: acc.transcriptTurns(),
                      firstTimestamp: acc.firstTimestamp, lastTimestamp: acc.lastTimestamp, bytes: bytes,
                      lastTurnOffset: acc.recs.last?.promptLine.lowerBound)
    }

    /// Complete lines already in memory, starting at byte `offset` of the file.
    public static func parse(_ data: Data, at offset: Int) -> Parsed {
        var acc = Accumulator(keepText: true)
        acc.consumeLines(data, at: offset)
        return Parsed(meta: acc.meta, threadName: acc.threadName, turns: acc.transcriptTurns(),
                      firstTimestamp: acc.firstTimestamp, lastTimestamp: acc.lastTimestamp, bytes: offset + data.count,
                      lastTurnOffset: acc.recs.last?.promptLine.lowerBound)
    }

    // MARK: - Lines

    enum Kind { case prompt, agentMessage, finalAnswer }

    /// What a line carries for lmux: a prompt, an agent message (final or commentary), or nothing.
    static func classify(_ o: [String: Any]) -> (kind: Kind, text: String, turnID: String?)? {
        guard o["type"] as? String == "event_msg", let p = o["payload"] as? [String: Any] else { return nil }
        let turnID = p["turn_id"] as? String
        switch p["type"] as? String {
        case "user_message":
            guard let m = p["message"] as? String else { return nil }
            return (.prompt, m, turnID)
        case "agent_message":
            guard let m = p["message"] as? String else { return nil }
            return (p["phase"] as? String == "final_answer" ? .finalAnswer : .agentMessage, m, turnID)
        case "task_complete":
            guard let m = p["last_agent_message"] as? String, !m.isEmpty else { return nil }
            return (.finalAnswer, m, turnID)
        case "item_completed":
            guard let item = p["item"] as? [String: Any] else { return nil }
            let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
            switch item["type"] as? String {
            case "UserMessage": return (.prompt, text, turnID)
            case "AgentMessage":
                return (item["phase"] as? String == "final_answer" ? .finalAnswer : .agentMessage, text, turnID)
            default: return nil
            }
        default:
            return nil
        }
    }

    struct Accumulator {
        struct Rec {
            var turnID: String?
            var timestamp: String?
            var prompt: String
            var promptTruncated: Bool
            var promptLine: Range<Int>
            var replyLine: Range<Int>?
            var replyIsFinal = false
            var reply: String?
            var replyHead: String?
            /// The turn id, else the prompt line's byte offset (stable across incremental reads).
            var uuid: String { turnID ?? "codex@\(promptLine.lowerBound)" }
        }

        let keepText: Bool
        var meta = Meta()
        var threadName: String?
        var recs: [Rec] = []
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        init(keepText: Bool) { self.keepText = keepText }

        mutating func consumeLines(_ data: Data, at base: Int) {
            var start = data.startIndex
            while start < data.endIndex {
                let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
                if nl > start {
                    let range = (base + (start - data.startIndex))..<(base + (nl - data.startIndex))
                    if let o = (try? JSONSerialization.jsonObject(with: data[start..<nl])) as? [String: Any] {
                        consume(o, range)
                    }
                }
                if nl == data.endIndex { break }
                start = data.index(after: nl)
            }
        }

        mutating func consume(_ o: [String: Any], _ range: Range<Int>) {
            let ts = o["timestamp"] as? String
            if let ts, let d = Self.iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) {
                if firstTimestamp == nil { firstTimestamp = d }
                lastTimestamp = d
            }
            let p = o["payload"] as? [String: Any]
            if o["type"] as? String == "session_meta", let p {
                meta.id = meta.id ?? (p["id"] as? String)
                meta.cwd = meta.cwd ?? (p["cwd"] as? String)
                meta.cliVersion = meta.cliVersion ?? (p["cli_version"] as? String)
                if let b = (p["git"] as? [String: Any])?["branch"] as? String, !b.isEmpty { meta.gitBranch = b }
                if let s = p["source"] as? [String: Any], s["subagent"] != nil { meta.isSubagent = true }
                return
            }
            if p?["type"] as? String == "thread_name_updated", let n = p?["thread_name"] as? String,
               !n.trimmingCharacters(in: .whitespaces).isEmpty {
                threadName = n
                return
            }
            guard let (kind, text, turnID) = CodexRollout.classify(o) else { return }
            switch kind {
            case .prompt:
                // One prompt can be reported twice (an event and its item): same turn, or same
                // text with nothing in between.
                if let last = recs.last, last.replyLine == nil,
                   (turnID != nil && last.turnID == turnID) || last.prompt == (keepText ? text : Self.cap(text).0) {
                    return
                }
                let (capped, truncated) = keepText ? (text, false) : Self.cap(text)
                recs.append(Rec(turnID: turnID, timestamp: ts, prompt: capped, promptTruncated: truncated, promptLine: range))
            case .agentMessage, .finalAnswer:
                guard !recs.isEmpty, !text.isEmpty else { return }
                let final = kind == .finalAnswer
                // A final answer wins over commentary; the latest of the same rank wins.
                if recs[recs.count - 1].replyIsFinal && !final { return }
                recs[recs.count - 1].replyLine = range
                recs[recs.count - 1].replyIsFinal = final
                recs[recs.count - 1].replyHead = String(text.prefix(TranscriptIndex.replyHeadCap))
                if keepText { recs[recs.count - 1].reply = text }
            }
        }

        static func cap(_ s: String) -> (String, Bool) {
            s.count > TranscriptIndex.promptCap ? (String(s.prefix(TranscriptIndex.promptCap)), true) : (s, false)
        }

        func indexTurns() -> [TranscriptIndex.Turn] {
            recs.enumerated().map { i, r in
                TranscriptIndex.Turn(index: i + 1, uuid: r.uuid, prompt: r.prompt,
                                     promptIsTruncated: r.promptTruncated, hasReply: r.replyLine != nil,
                                     replyHead: r.replyHead, assistantUuid: nil, beforeCompaction: false,
                                     editedFiles: [], createdFiles: [], promptLine: r.promptLine,
                                     replyLines: r.replyLine.map { [$0] } ?? [])
            }
        }

        func transcriptTurns() -> [Transcript.Turn] {
            recs.enumerated().map { i, r in
                Transcript.Turn(index: i + 1, uuid: r.uuid, timestamp: r.timestamp,
                                prompt: r.prompt, assistantText: r.reply, assistantUuid: nil, beforeCompaction: false,
                                entryUuids: [])
            }
        }
    }
}

/// Codex's session titles: `$CODEX_HOME/session_index.jsonl`, one `{"id","thread_name","updated_at"}`
/// line per (re)naming, newest last. Only read.
public enum CodexThreadNames {
    public static func file(codexHome: String) -> URL {
        URL(fileURLWithPath: codexHome).appendingPathComponent("session_index.jsonl")
    }

    /// Every session's latest name.
    public static func all(_ url: URL) -> [String: String] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        var out: [String: String] = [:]
        for line in d.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = o["id"] as? String, let n = o["thread_name"] as? String,
                  !n.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            out[id] = n
        }
        return out
    }

    /// One session's latest name, read from the end of the file in small chunks (the newest
    /// line naming it wins), up to `maxBytes`.
    public static func name(of id: String, in url: URL, maxBytes: Int = 4 << 20) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0 else { return nil }
        let needle = Data(id.utf8)
        let chunk = 64 << 10
        var end = Int(size)
        var carry = Data()
        while end > 0, Int(size) - end < maxBytes {
            let start = max(0, end - chunk)
            try? h.seek(toOffset: UInt64(start))
            var buf = (try? h.read(upToCount: end - start)) ?? Data()
            buf.append(carry)
            // The first (partial) line goes on to the next round unless this is the file's start.
            var lines = buf.split(separator: 0x0A, omittingEmptySubsequences: false)
            carry = start > 0 ? Data(lines.removeFirst()) : Data()
            for line in lines.reversed() where line.range(of: needle) != nil {
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                   o["id"] as? String == id, let n = o["thread_name"] as? String,
                   !n.trimmingCharacters(in: .whitespaces).isEmpty {
                    return n
                }
            }
            end = start
        }
        return nil
    }
}
