import Foundation

/// Incremental, bounded-memory reader of one session transcript, for what the app does
/// over and over (hover actions, titles): the turn list, nothing else.
///
/// Only appended bytes are parsed. A file is known to have grown by appending when its
/// inode is the same, it got longer, and the last `fingerprintLength` bytes before the
/// end of what was read are unchanged (the same test as `SessionIndex`); anything else
/// (forget surgery, a rewrite) reads it again from the start. Memory holds one small
/// record per chain entry (uuids, flags, a capped prompt, the first few hundred
/// characters of a reply, the line's byte range); full prompts and reply markdown are
/// read back from the file on demand.
///
/// Not thread-safe: use one instance from one queue.
public final class TranscriptIndex: @unchecked Sendable {
    public struct Turn: Sendable, Equatable {
        /// 1-based, same numbering as `Transcript.Turn.index`.
        public let index: Int
        public let uuid: String
        /// The prompt, capped at `promptCap` characters (`fullPrompt` reads all of it).
        public let prompt: String
        public let promptIsTruncated: Bool
        public var firstLine: String {
            String(prompt.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
        }
        public let hasReply: Bool
        /// Start of Claude's final reply (for titles); `reply(_:)` reads the whole markdown.
        public let replyHead: String?
        public let assistantUuid: String?
        public let beforeCompaction: Bool
        /// Files the turn's Edit/Write/MultiEdit/NotebookEdit calls touched.
        public let editedFiles: [String]
        /// Files the turn's Write calls created (the tool result says `"type":"create"`).
        public let createdFiles: [String]
        /// The turn ends with Esc's `[Request interrupted by user…]` record: Claude stopped
        /// working on it, though no Stop hook came (Claude Code sends none on interrupt).
        public internal(set) var interrupted = false
        let promptLine: Range<Int>
        let replyLines: [Range<Int>]
        /// Byte offset of the prompt's line in the file (newer turns sit further down).
        public var promptOffset: Int { promptLine.lowerBound }
    }

    public static let promptCap = 4096
    static let replyHeadCap = 400
    static let fingerprintLength = 4096
    static let readChunk = 4 << 20
    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    public let url: URL
    /// Bytes parsed since creation (tests: a repeated read parses only what was appended).
    public private(set) var bytesParsed = 0
    /// Times the file was read from the start.
    public private(set) var fullReads = 0
    public private(set) var customTitle: String?
    public private(set) var aiTitle: String?
    /// Current turn list (recomputed after each `update()` that saw new lines).
    public private(set) var turns: [Turn] = []

    private struct Node {
        var uuid: String?
        var parent: String?
        var isChainNode: Bool
        var isSidechain: Bool
        var isCompactBoundary: Bool
        var logicalParent: String?
        var isAssistant: Bool
        var isHumanPrompt: Bool
        /// A user or assistant message (not an attachment or system entry).
        var isMessage = false
        var isInterruptMarker = false
        var prompt: String?
        var promptTruncated = false
        var messageID: String?
        var hasText = false
        var textHead: String?
        var editFiles: [String] = []
        var createdFiles: [String] = []
        var line: Range<Int>
    }

    private var nodes: [Node] = []
    private var byUuid: [String: Int] = [:]
    /// Last `last-prompt` pointer: (leaf uuid, explicit, how many nodes came before it).
    private var pointer: (String, Bool, Int)?
    private var indexedBytes = 0
    private var inode = 0
    private var tailFP = Data()

    public init(url: URL) { self.url = url }

    /// Read what was appended since the last call (or everything, if the file changed
    /// otherwise). Returns true if the turn list may have changed.
    @discardableResult
    public func update() throws -> Bool {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let ino = (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? 0
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var appendOnly = fullReads > 0 && ino == inode && size >= indexedBytes
        if appendOnly, indexedBytes > 0 {
            let start = max(0, indexedBytes - Self.fingerprintLength)
            try h.seek(toOffset: UInt64(start))
            appendOnly = (try h.read(upToCount: indexedBytes - start) ?? Data()) == tailFP
        }
        if !appendOnly {
            reset()
            inode = ino
            fullReads += 1
        }
        if size == indexedBytes && appendOnly { return false }
        try h.seek(toOffset: UInt64(indexedBytes))
        var offset = indexedBytes
        var carry = Data()
        var changed = !appendOnly
        while true {
            let chunk: Data = try autoreleasepool { try h.read(upToCount: Self.readChunk) ?? Data() }
            if chunk.isEmpty { break }
            var buf = carry
            buf.append(chunk)
            guard let lastNL = buf.lastIndex(of: 0x0A) else { carry = buf; continue }
            let complete = buf[buf.startIndex...lastNL]
            carry = Data(buf[buf.index(after: lastNL)...])
            autoreleasepool { parseLines(complete, at: offset) }
            offset += complete.count
            changed = true
        }
        bytesParsed += offset - indexedBytes
        indexedBytes = offset
        let fpStart = max(0, offset - Self.fingerprintLength)
        try h.seek(toOffset: UInt64(fpStart))
        tailFP = try h.read(upToCount: offset - fpStart) ?? Data()
        if changed { turns = computeTurns() }
        return changed
    }

    private func reset() {
        nodes = []
        byUuid = [:]
        pointer = nil
        customTitle = nil
        aiTitle = nil
        indexedBytes = 0
        tailFP = Data()
        turns = []
    }

    // MARK: - Parsing

    private func parseLines(_ data: Data, at base: Int) {
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let range = (base + (start - data.startIndex))..<(base + (nl - data.startIndex))
            if nl > start { parseLine(data[start..<nl], range) }
            start = data.index(after: min(nl, data.endIndex - 1))
            if nl == data.endIndex { break }
        }
    }

    private func parseLine(_ line: Data, _ range: Range<Int>) {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let type = o["type"] as? String
        switch type {
        case "last-prompt":
            if let leaf = o["leafUuid"] as? String { pointer = (leaf, o["explicit"] as? Bool == true, nodes.count) }
            return
        case "custom-title":
            if let t = o["customTitle"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty { customTitle = t }
            return
        case "ai-title":
            if let t = o["aiTitle"] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty { aiTitle = t }
            return
        default: break
        }
        guard let uuid = o["uuid"] as? String else { return }
        let message = o["message"] as? [String: Any]
        var n = Node(uuid: uuid, parent: o["parentUuid"] as? String, isChainNode: o.keys.contains("parentUuid"),
                     isSidechain: o["isSidechain"] as? Bool ?? false,
                     isCompactBoundary: type == "system" && o["subtype"] as? String == "compact_boundary",
                     logicalParent: o["logicalParentUuid"] as? String, isAssistant: type == "assistant",
                     isHumanPrompt: false, line: range)
        n.isMessage = type == "user" || type == "assistant"
        if type == "user", !n.isSidechain, Self.isInterruptMarker(message) { n.isInterruptMarker = true }
        if type == "user", Self.isHumanPrompt(o, message) {
            n.isHumanPrompt = true
            let p = Self.promptText(message)
            n.prompt = p.count > Self.promptCap ? String(p.prefix(Self.promptCap)) : p
            n.promptTruncated = p.count > Self.promptCap
        }
        if type == "user", let r = o["toolUseResult"] as? [String: Any], r["type"] as? String == "create",
           let f = r["filePath"] as? String {
            n.createdFiles.append(f)
        }
        if n.isAssistant, let blocks = message?["content"] as? [[String: Any]] {
            n.messageID = message?["id"] as? String
            let texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            if !texts.isEmpty {
                n.hasText = true
                n.textHead = String(texts.joined(separator: "\n\n").prefix(Self.replyHeadCap))
            }
            for b in blocks where b["type"] as? String == "tool_use" && Self.editTools.contains(b["name"] as? String ?? "") {
                let input = b["input"] as? [String: Any]
                if let f = (input?["file_path"] ?? input?["notebook_path"]) as? String { n.editFiles.append(f) }
            }
        }
        byUuid[uuid] = nodes.count
        nodes.append(n)
    }

    /// Mirrors `Transcript.isHumanPrompt` on a parsed object.
    static func isHumanPrompt(_ o: [String: Any], _ message: [String: Any]?) -> Bool {
        if o["isSidechain"] as? Bool == true { return false }
        if o["isMeta"] as? Bool == true || o["isCompactSummary"] as? Bool == true { return false }
        if o["toolUseResult"] != nil || o["sourceToolUseID"] != nil || o["sourceToolAssistantUUID"] != nil { return false }
        if let origin = o["turnOrigin"] as? String, !["human", "sdk"].contains(origin) { return false }
        guard let content = message?["content"] else { return false }
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
        return !Transcript.nonPromptPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// `[Request interrupted by user]` / `… for tool use]`, as a string or a text block.
    static func isInterruptMarker(_ message: [String: Any]?) -> Bool {
        let content = message?["content"]
        let text = (content as? String) ?? ((content as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return text.hasPrefix("[Request interrupted by user")
    }

    static func promptText(_ message: [String: Any]?) -> String {
        let content = message?["content"]
        if let s = content as? String { return s }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.map { b in (b["text"] as? String) ?? "[\(b["type"] as? String ?? "?")]" }.joined(separator: "\n")
    }

    // MARK: - Turns (same rules as `Transcript.turns()`)

    /// Same rules as `Transcript.leafIndex`.
    private var leafIndex: Int? {
        let lastChain = nodes.lastIndex { $0.isChainNode && !$0.isSidechain }
        guard let (leaf, explicit, at) = pointer, let target = byUuid[leaf], !nodes[target].isSidechain else { return lastChain }
        let prompt = nodes.indices.last { $0 >= at && nodes[$0].isHumanPrompt }
        func branch(_ p: Int) -> Int? {
            nodes.indices.last { $0 >= p && nodes[$0].isChainNode && !nodes[$0].isSidechain && descends($0, from: p) }
        }
        if explicit { return prompt.flatMap(branch) ?? target }
        if let last = lastChain, descends(last, from: target) { return last }
        if let prompt, !descends(prompt, from: target) { return branch(prompt) }
        return target
    }

    /// `i` is `ancestor` or below it in the parentUuid chain.
    private func descends(_ i: Int, from ancestor: Int) -> Bool {
        var cur: Int? = i
        var seen = Set<Int>()
        while let j = cur, seen.insert(j).inserted {
            if j == ancestor { return true }
            cur = nodes[j].parent.flatMap { byUuid[$0] }
        }
        return false
    }

    private func computeTurns() -> [Turn] {
        guard let leaf = leafIndex else { return [] }
        var chain: [(Int, Bool)] = []
        var seen = Set<Int>()
        var cur: Int? = leaf
        var crossed = false
        while let i = cur, seen.insert(i).inserted {
            chain.append((i, crossed))
            let n = nodes[i]
            if let p = n.parent {
                cur = byUuid[p]
            } else if n.isCompactBoundary, let lp = n.logicalParent {
                crossed = true
                cur = byUuid[lp]
            } else {
                cur = nil
            }
        }
        chain.reverse()
        var spans: [(prompt: Int, members: [Int], before: Bool)] = []
        var current: (prompt: Int, members: [Int], before: Bool)?
        for (i, before) in chain {
            let n = nodes[i]
            if n.isHumanPrompt {
                if let c = current { spans.append(c) }
                current = (i, [i], before)
            } else if n.isCompactBoundary {
                if let c = current { spans.append(c) }
                current = nil
            } else if current != nil {
                current!.members.append(i)
            }
        }
        if let c = current { spans.append(c) }

        return spans.enumerated().map { k, span in
            let p = nodes[span.prompt]
            var replyLines: [Range<Int>] = []
            var head: String?
            var auuid: String?
            if let last = span.members.last(where: { nodes[$0].hasText }) {
                let mid = nodes[last].messageID
                let same = mid == nil ? [last] : span.members.filter { nodes[$0].isAssistant && nodes[$0].messageID == mid }
                replyLines = same.map { nodes[$0].line }
                auuid = same.compactMap { nodes[$0].uuid }.first
                head = String(same.compactMap { nodes[$0].textHead }.joined(separator: "\n\n").prefix(Self.replyHeadCap))
            }
            var files: [String] = []
            var created: [String] = []
            for i in span.members {
                for f in nodes[i].editFiles where !files.contains(f) { files.append(f) }
                for f in nodes[i].createdFiles where !created.contains(f) { created.append(f) }
            }
            var turn = Turn(index: k + 1, uuid: p.uuid ?? "", prompt: p.prompt ?? "", promptIsTruncated: p.promptTruncated,
                            hasReply: !replyLines.isEmpty, replyHead: head, assistantUuid: auuid,
                            beforeCompaction: span.before, editedFiles: files, createdFiles: created, promptLine: p.line, replyLines: replyLines)
            turn.interrupted = span.members.last(where: { nodes[$0].isMessage }).map { nodes[$0].isInterruptMarker } ?? false
            return turn
        }
    }

    // MARK: - On demand

    private func readLine(_ r: Range<Int>, _ h: FileHandle) throws -> [String: Any]? {
        try h.seek(toOffset: UInt64(r.lowerBound))
        let d = try h.read(upToCount: r.count) ?? Data()
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// The original markdown of the turn's final reply (all text blocks of that message).
    public func reply(_ turn: Turn) throws -> String? {
        guard !turn.replyLines.isEmpty else { return nil }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var parts: [String] = []
        for r in turn.replyLines {
            let o = try readLine(r, h)
            let blocks = (o?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            parts += blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The whole prompt (the turn list keeps at most `promptCap` characters of it).
    public func fullPrompt(_ turn: Turn) throws -> String {
        guard turn.promptIsTruncated else { return turn.prompt }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        return Self.promptText(try readLine(turn.promptLine, h)?["message"] as? [String: Any])
    }
}
