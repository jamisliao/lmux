/// Minimal order-preserving JSON model so editing settings.json keeps every
/// foreign key in place. Numbers keep their literal text. `render()` matches
/// `JSON.stringify(value, null, 2)`, which is how Claude Code writes settings.json,
/// so an untouched file round-trips byte-for-byte.
public indirect enum JSONValue: Equatable, Sendable {
    case object([Member])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) { self.key = key; self.value = value }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let m) = self else { return nil }
        return m.first(where: { $0.key == key })?.value
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let offset: Int
        public let reason: String
        /// 1-based, so a hand-edited settings.json can be fixed in an editor (0: unknown).
        public var line = 0, column = 0
        public var description: String {
            line > 0 ? "JSON parse error at line \(line), column \(column): \(reason)" : "JSON parse error at byte \(offset): \(reason)"
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        guard p.i == p.bytes.count else { throw p.fail("trailing characters") }
        return v
    }

    public func render(indent: Int = 0) -> String {
        var out = ""
        write(to: &out, indent: indent)
        return out
    }

    private func write(to out: inout String, indent: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): JSONValue.writeString(s, to: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            let pad = String(repeating: " ", count: indent + 2)
            out += "[\n"
            for (i, v) in a.enumerated() {
                out += pad
                v.write(to: &out, indent: indent + 2)
                out += i == a.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "]"
        case .object(let m):
            if m.isEmpty { out += "{}"; return }
            let pad = String(repeating: " ", count: indent + 2)
            out += "{\n"
            for (i, mem) in m.enumerated() {
                out += pad
                JSONValue.writeString(mem.key, to: &out)
                out += ": "
                mem.value.write(to: &out, indent: indent + 2)
                out += i == m.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: " ", count: indent) + "}"
        }
    }

    static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let h = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        func fail(_ r: String) -> ParseError {
            let before = bytes[..<min(i, bytes.count)]
            let lineStart = before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            let column = String(decoding: bytes[lineStart..<before.endIndex], as: UTF8.self).count + 1
            return ParseError(offset: i, reason: r, line: before.filter { $0 == 0x0A }.count + 1, column: column)
        }

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ lit: String) throws {
            let l = Array(lit.utf8)
            guard i + l.count <= bytes.count, Array(bytes[i..<i + l.count]) == l else { throw fail("expected \(lit)") }
            i += l.count
        }

        mutating func value() throws -> JSONValue {
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try number()
            }
        }

        mutating func object() throws -> JSONValue {
            i += 1
            var members: [Member] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let k = try string()
                skipWS()
                try expect(":")
                skipWS()
                members.append(Member(k, try value()))
                skipWS()
                guard i < bytes.count else { throw fail("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail("expected , or }")
            }
        }

        mutating func array() throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < bytes.count else { throw fail("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }

        mutating func number() throws -> JSONValue {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start else { throw fail("unexpected character") }
            return .number(String(decoding: bytes[start..<i], as: UTF8.self))
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
            else { throw fail("bad \\u escape") }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var raw: [UInt8] = []
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let b = bytes[i]
                i += 1
                if b == UInt8(ascii: "\"") { break }
                if b != UInt8(ascii: "\\") { raw.append(b); continue }
                guard i < bytes.count else { throw fail("bad escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): raw.append(e)
                case UInt8(ascii: "b"): raw.append(0x08)
                case UInt8(ascii: "f"): raw.append(0x0C)
                case UInt8(ascii: "n"): raw.append(0x0A)
                case UInt8(ascii: "r"): raw.append(0x0D)
                case UInt8(ascii: "t"): raw.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if (0xD800..<0xDC00).contains(cp), i + 1 < bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let lo = try hex4()
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    }
                    raw += Array(String(Unicode.Scalar(cp).map(Character.init) ?? "\u{FFFD}").utf8)
                default: throw fail("bad escape")
                }
            }
            return String(decoding: raw, as: UTF8.self)
        }
    }
}
