import Foundation

/// Edits lmux's config file (Ghostty syntax) in place: comments and unrelated lines stay,
/// a key's lines are replaced where they were, and a named block (`# <name> start` …
/// `# <name> end`) is replaced as a whole, so writes are idempotent.
public struct LmuxConfigFile {
    public let url: URL
    public init(url: URL = LmuxConfig.configFile) { self.url = url }

    public var text: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    static func key(of line: Substring) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces)
    }

    /// Replace every `key = …` line outside named blocks with `values` (in place of the first
    /// one; appended when the key was absent). An empty `values` removes the key.
    public func set(_ key: String, _ values: [String]) throws {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var out: [String] = []
        var placed = false
        var inBlock = false
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# "), t.hasSuffix(" start") { inBlock = true }
            if t.hasPrefix("# "), t.hasSuffix(" end") { inBlock = false }
            if !inBlock, Self.key(of: Substring(l)) == key {
                if !placed { out += values.map { "\(key) = \($0)" }; placed = true }
                continue
            }
            out.append(l)
        }
        if !placed { out += values.map { "\(key) = \($0)" } }
        try write(out)
    }

    /// Replace (or append) the block `# name start` … `# name end` with `header` comments and `lines`.
    public func setBlock(_ name: String, header: [String], lines body: [String]) throws {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let block = header.map { "# " + $0 } + ["# \(name) start"] + body + ["# \(name) end"]
        if let r = Self.blockRange(name, in: lines) {
            lines.replaceSubrange(r, with: block)
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines += block
        }
        try write(lines)
    }

    /// A named block's lines, the header comments right above it included (the old block in
    /// `setBlock`'s terms).
    static func blockRange(_ name: String, in lines: [String]) -> ClosedRange<Int>? {
        let start = "# \(name) start", end = "# \(name) end"
        guard let a = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == start }),
              let b = lines[a...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == end }) else { return nil }
        var from = a
        while from > 0, lines[from - 1].hasPrefix("# "), !lines[from - 1].hasSuffix(" end") { from -= 1 }
        return from...b
    }

    /// The named block as it stands, header included (nil without one): what `replaceBlock` puts back.
    public func rawBlock(_ name: String) -> [String]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Self.blockRange(name, in: lines).map { Array(lines[$0]) }
    }

    /// Put a `rawBlock` back in place of the named block, or remove the block (nil) with the blank
    /// line `setBlock` put before it. Every other line stays as it is.
    public func replaceBlock(_ name: String, with raw: [String]?) throws {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let r = Self.blockRange(name, in: lines) else {
            guard let raw else { return }
            if let last = lines.last, !last.isEmpty { lines.append("") }
            try write(lines + raw)
            return
        }
        lines.replaceSubrange(r, with: raw ?? [])
        if raw == nil, r.lowerBound > 0, lines[r.lowerBound - 1].isEmpty { lines.remove(at: r.lowerBound - 1) }
        try write(lines)
    }

    /// Lines of a named block (nil without one).
    public func block(_ name: String) -> [String]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let a = lines.firstIndex(of: "# \(name) start"),
              let b = lines[a...].firstIndex(of: "# \(name) end") else { return nil }
        return Array(lines[(a + 1)..<b])
    }

    private func write(_ lines: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
