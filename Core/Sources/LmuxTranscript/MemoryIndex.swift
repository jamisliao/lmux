import Darwin
import Foundation

/// Claude's auto memory index: `<project>/memory/MEMORY.md`, one line per memory file,
/// each linking to it (`- [Title](file.md) — hook`). When forget deletes a memory file,
/// its index line goes too, or Claude keeps a pointer to a file that is gone.
public enum MemoryIndex {
    public static let fileName = "MEMORY.md"

    /// Remove the lines of `memoryDir/MEMORY.md` that link to `file` (a file in `memoryDir`,
    /// linked by its path relative to it, e.g. `file.md`, `./file.md` or `file.md "title"`).
    /// Only a line whose single markdown link targets `file` is removed: a line with more
    /// than one link is left untouched even when one of them matches, so another file's
    /// mention on the same line is never lost. Atomic; if MEMORY.md is a symlink, its real
    /// target is rewritten and the symlink itself is kept. Mode kept (0600 if unknown).
    /// Returns how many lines were removed; 0 touches nothing.
    @discardableResult
    public static func removeLinks(to file: URL, memoryDir: URL) throws -> Int {
        // Resolved on both sides the same way, so a symlinked ancestor (e.g. /tmp -> /private/tmp)
        // can't make an in-`memoryDir` file look like it's outside, or vice versa. `file` is
        // typically already gone by the time this runs (trashed), so `canonicalPath` can't rely
        // on it existing, unlike Foundation's `resolvingSymlinksInPath()` (which also leaves
        // /tmp, /etc and /var alone, the very case this needs to handle).
        let dir = canonicalPath(memoryDir)
        let path = canonicalPath(file)
        guard path.hasPrefix(dir + "/") else { return 0 }
        let target = String(path.dropFirst(dir.count + 1))
        guard target != fileName else { return 0 }
        let index = memoryDir.appendingPathComponent(fileName)
        guard let data = FileManager.default.contents(atPath: index.path) else { return 0 }
        let text = String(decoding: data, as: UTF8.self)
        guard Data(text.utf8) == data else { return 0 }  // not UTF-8: leave it alone
        var removed = 0
        var kept: [Substring] = []
        // Split keeping each line's terminator, so the file is otherwise byte-for-byte the same.
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = text[start..<end]
            let targets = linkTargets(in: line)
            if targets.count == 1, targets[0] == target { removed += 1 } else { kept.append(line) }
            start = end
        }
        guard removed > 0 else { return 0 }
        // Write through a symlinked MEMORY.md to its real target: `PrivateFile.replace` renames a
        // temp file over the given path, which would otherwise replace the symlink itself.
        let realIndex = index.resolvingSymlinksInPath()
        try PrivateFile.replace(realIndex, Data(kept.joined().utf8), mode: PrivateFile.mode(of: index.path) ?? 0o600)
        return removed
    }

    /// Markdown inline link targets on a line: the destination between `](` and the next
    /// `)`, with a trailing ` "title"` (separated from the destination by whitespace, as in
    /// `[Title](file.md "hook")`) dropped and a leading `./` stripped.
    static func linkTargets(in line: Substring) -> [String] {
        var out: [String] = []
        var rest = line[...]
        while let open = rest.range(of: "](") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: ")") else { break }
            out.append(linkTarget(from: after[..<close]))
            rest = after[after.index(after: close)...]
        }
        return out
    }

    private static func linkTarget(from raw: Substring) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let space = s.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            s = String(s[s.startIndex..<space])
        }
        if s.hasPrefix("./") { s.removeFirst(2) }
        return s
    }

    /// `url`'s path with every symlinked ancestor resolved via `realpath(3)`, including /tmp,
    /// /etc and /var (which `URL.resolvingSymlinksInPath()` deliberately leaves alone). `url`
    /// itself need not exist: this walks up to the nearest existing ancestor, resolves that,
    /// and reattaches whatever doesn't exist yet, unresolved.
    private static func canonicalPath(_ url: URL) -> String {
        var dirURL = url.standardizedFileURL
        var suffix: [String] = []
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        while true {
            if realpath(dirURL.path, &buf) != nil {
                let len = buf.firstIndex(of: 0) ?? buf.count
                let resolved = String(decoding: buf[..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return suffix.reversed().reduce(resolved) { $0 + "/" + $1 }
            }
            let parent = dirURL.deletingLastPathComponent()
            guard parent.path != dirURL.path else { return url.standardizedFileURL.path }  // nothing resolved
            suffix.append(dirURL.lastPathComponent)
            dirURL = parent
        }
    }
}
