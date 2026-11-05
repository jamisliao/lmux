/// Byte-level editing of a JSON document: values are located by span and edits splice
/// text in or out, so every byte lmux doesn't own (indentation, key order, number
/// literals, `\u` escapes, CRLF) stays exactly as it was.
struct JSONText {
    struct Span {
        enum Kind { case object, array, scalar }
        var kind: Kind
        /// `[start, end)` of the value.
        var start: Int
        var end: Int
        /// Object members: key, offset of the key's opening quote, value.
        var members: [(key: String, keyStart: Int, value: Span)] = []
        var elements: [Span] = []

        func member(_ key: String) -> Span? { members.first { $0.key == key }?.value }
    }

    enum Step { case key(String), index(Int) }

    private(set) var bytes: [UInt8]
    private(set) var root: Span
    /// Line break used by the file ("\r\n" if it has any).
    let newline: [UInt8]
    /// One indentation level ("" = compact, single-line JSON).
    let unit: [UInt8]
    /// Text between a key and its value (`": "`, `":"`, ...).
    let colon: [UInt8]

    init(_ text: String) throws {
        let b = Array(text.utf8)
        bytes = b
        root = try Self.parse(b)
        newline = b.indices.contains { $0 > 0 && b[$0] == 0x0A && b[$0 - 1] == 0x0D } ? [0x0D, 0x0A] : [0x0A]
        if let first = root.members.first {
            let gap = bytes[(root.start + 1)..<first.keyStart]
            if let nl = gap.lastIndex(of: 0x0A) { unit = Array(gap[(nl + 1)...]) } else { unit = [] }
            let keyEnd = Self.stringEnd(bytes, first.keyStart)
            colon = Array(bytes[keyEnd..<first.value.start])
        } else {
            unit = Array("  ".utf8)
            colon = Array(": ".utf8)
        }
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }
    var compact: Bool { unit.isEmpty }

    func span(_ path: [Step]) -> Span? {
        var cur = root
        for s in path {
            switch s {
            case .key(let k): guard let v = cur.member(k) else { return nil }; cur = v
            case .index(let i): guard cur.elements.indices.contains(i) else { return nil }; cur = cur.elements[i]
            }
        }
        return cur
    }

    func value(_ span: Span) throws -> JSONValue {
        try JSONValue.parse(String(decoding: bytes[span.start..<span.end], as: UTF8.self))
    }

    // MARK: Edits

    /// Insert `value` as the first element of the array at `path` (prepending keeps every
    /// existing line intact: no trailing comma has to be added anywhere).
    mutating func prependElement(_ path: [Step], _ value: JSONValue) throws {
        guard let arr = span(path), arr.kind == .array else { return }
        if let first = arr.elements.first {
            try insertBefore(first.start, render(value, level: level(at: first.start)))
        } else {
            try fillEmpty(arr, render(value, level: level(at: arr.start) + 1))
        }
    }

    /// Insert `value` as the last element of the array at `path`, on its own line after the
    /// current last one (`removeElement` of the last index is the exact inverse).
    mutating func appendElement(_ path: [Step], _ value: JSONValue) throws {
        guard let arr = span(path), arr.kind == .array else { return }
        guard let last = arr.elements.last else { return try prependElement(path, value) }
        let lv = level(at: last.start)
        let sep: [UInt8] = compact ? [UInt8(ascii: ",")] : [UInt8(ascii: ",")] + newline + indent(lv)
        try replace(last.end..<last.end, sep + render(value, level: lv))
    }

    /// Insert `"key": value` as the first member of the object at `path`.
    mutating func prependMember(_ path: [Step], key: String, _ value: JSONValue) throws {
        guard let obj = span(path), obj.kind == .object else { return }
        var keyText = ""
        JSONValue.writeString(key, to: &keyText)
        if let first = obj.members.first {
            let lv = level(at: first.keyStart)
            try insertBefore(first.keyStart, Array(keyText.utf8) + colon + render(value, level: lv))
        } else {
            let lv = level(at: obj.start) + 1
            try fillEmpty(obj, Array(keyText.utf8) + colon + render(value, level: lv))
        }
    }

    /// Remove element `index` of the array at `path` with its separator (exact inverse of
    /// `prependElement` for the first element). The last element leaves `[]`.
    mutating func removeElement(_ path: [Step], _ index: Int) throws {
        guard let arr = span(path), arr.elements.indices.contains(index) else { return }
        let els = arr.elements
        if els.count == 1 {
            try replace((arr.start + 1)..<(arr.end - 1), [])
        } else if index == 0 {
            try replace(els[0].start..<els[1].start, [])
        } else {
            try replace(els[index - 1].end..<els[index].end, [])
        }
    }

    /// Remove member `key` of the object at `path` with its separator. The last member leaves `{}`.
    mutating func removeMember(_ path: [Step], _ key: String) throws {
        guard let obj = span(path), let i = obj.members.firstIndex(where: { $0.key == key }) else { return }
        let ms = obj.members
        if ms.count == 1 {
            try replace((obj.start + 1)..<(obj.end - 1), [])
        } else if i == 0 {
            try replace(ms[0].keyStart..<ms[1].keyStart, [])
        } else {
            try replace(ms[i - 1].value.end..<ms[i].value.end, [])
        }
    }

    private mutating func insertBefore(_ offset: Int, _ item: [UInt8]) throws {
        let sep: [UInt8] = compact ? [UInt8(ascii: ",")] : [UInt8(ascii: ",")] + newline + indent(level(at: offset))
        try replace(offset..<offset, item + sep)
    }

    private mutating func fillEmpty(_ container: Span, _ item: [UInt8]) throws {
        let inner = (container.start + 1)..<(container.end - 1)
        if compact { try replace(inner, item); return }
        let outer = level(at: container.start)
        try replace(inner, newline + indent(outer + 1) + item + newline + indent(outer))
    }

    private mutating func replace(_ range: Range<Int>, _ with: [UInt8]) throws {
        bytes.replaceSubrange(range, with: with)
        root = try Self.parse(bytes)
    }

    // MARK: Layout

    /// Indentation level of the line `offset` is on (0 for compact files).
    func level(at offset: Int) -> Int {
        guard !compact else { return 0 }
        var s = offset
        while s > 0, bytes[s - 1] != 0x0A { s -= 1 }
        var n = 0
        while s + n < bytes.count, bytes[s + n] == 0x20 || bytes[s + n] == 0x09 { n += 1 }
        return n / max(1, unit.count)
    }

    func indent(_ level: Int) -> [UInt8] { Array([[UInt8]](repeating: unit, count: max(0, level)).joined()) }

    /// `value` in the file's style; continuation lines are indented from `level`.
    func render(_ value: JSONValue, level: Int) -> [UInt8] {
        var out: [UInt8] = []
        write(value, level: level, into: &out)
        return out
    }

    private func write(_ v: JSONValue, level: Int, into out: inout [UInt8]) {
        func open(_ c: Character) { out.append(UInt8(ascii: c.unicodeScalars.first!)) }
        switch v {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .number(let n): out += Array(n.utf8)
        case .string(let s):
            var t = ""
            JSONValue.writeString(s, to: &t)
            out += Array(t.utf8)
        case .array(let a):
            open("[")
            for (i, e) in a.enumerated() {
                if i > 0 { open(",") }
                if !compact { out += newline + indent(level + 1) }
                write(e, level: level + 1, into: &out)
            }
            if !compact && !a.isEmpty { out += newline + indent(level) }
            open("]")
        case .object(let m):
            open("{")
            for (i, mem) in m.enumerated() {
                if i > 0 { open(",") }
                if !compact { out += newline + indent(level + 1) }
                var k = ""
                JSONValue.writeString(mem.key, to: &k)
                out += Array(k.utf8) + colon
                write(mem.value, level: level + 1, into: &out)
            }
            if !compact && !m.isEmpty { out += newline + indent(level) }
            open("}")
        }
    }

    // MARK: Parsing

    struct ParseError: Error, CustomStringConvertible {
        let offset: Int
        var description: String { "JSON parse error at byte \(offset)" }
    }

    static func parse(_ b: [UInt8]) throws -> Span {
        var i = 0
        skipWS(b, &i)
        let v = try value(b, &i)
        skipWS(b, &i)
        guard i == b.count else { throw ParseError(offset: i) }
        return v
    }

    static func skipWS(_ b: [UInt8], _ i: inout Int) {
        while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
    }

    /// Offset just past the string starting at `start` (its opening quote).
    static func stringEnd(_ b: [UInt8], _ start: Int) -> Int {
        var i = start + 1
        while i < b.count {
            if b[i] == UInt8(ascii: "\\") { i += 2; continue }
            if b[i] == UInt8(ascii: "\"") { return i + 1 }
            i += 1
        }
        return b.count
    }

    static func value(_ b: [UInt8], _ i: inout Int) throws -> Span {
        guard i < b.count else { throw ParseError(offset: i) }
        let start = i
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var s = Span(kind: .object, start: start, end: start)
            skipWS(b, &i)
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; s.end = i; return s }
            while true {
                skipWS(b, &i)
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw ParseError(offset: i) }
                let keyStart = i
                i = stringEnd(b, i)
                let key = try JSONValue.parse(String(decoding: b[keyStart..<i], as: UTF8.self))
                guard case .string(let k) = key else { throw ParseError(offset: keyStart) }
                skipWS(b, &i)
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw ParseError(offset: i) }
                i += 1
                skipWS(b, &i)
                s.members.append((k, keyStart, try value(b, &i)))
                skipWS(b, &i)
                guard i < b.count else { throw ParseError(offset: i) }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; s.end = i; return s }
                throw ParseError(offset: i)
            }
        case UInt8(ascii: "["):
            i += 1
            var s = Span(kind: .array, start: start, end: start)
            skipWS(b, &i)
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; s.end = i; return s }
            while true {
                skipWS(b, &i)
                s.elements.append(try value(b, &i))
                skipWS(b, &i)
                guard i < b.count else { throw ParseError(offset: i) }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; s.end = i; return s }
                throw ParseError(offset: i)
            }
        case UInt8(ascii: "\""):
            i = stringEnd(b, i)
            guard i <= b.count, b[i - 1] == UInt8(ascii: "\"") else { throw ParseError(offset: start) }
            return Span(kind: .scalar, start: start, end: i)
        default:
            while i < b.count, !(b[i] == UInt8(ascii: ",") || b[i] == UInt8(ascii: "}") || b[i] == UInt8(ascii: "]")
                                 || b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09) { i += 1 }
            guard i > start else { throw ParseError(offset: i) }
            return Span(kind: .scalar, start: start, end: i)
        }
    }
}
