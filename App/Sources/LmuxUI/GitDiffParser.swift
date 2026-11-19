import Foundation

public struct GitDiffLine: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
        case hunkHeader
    }

    public var id: Int
    public var kind: Kind
    public var text: String

    public init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

public struct GitDiffFile: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var status: String
    public var added: Int
    public var deleted: Int
    public var lines: [GitDiffLine]
    public var truncated: Bool

    public init(
        path: String,
        status: String = "M",
        added: Int = 0,
        deleted: Int = 0,
        lines: [GitDiffLine] = [],
        truncated: Bool = false
    ) {
        self.path = path
        self.status = status
        self.added = added
        self.deleted = deleted
        self.lines = lines
        self.truncated = truncated
    }
}

public struct GitDiffSnapshot: Equatable, Sendable {
    public var cwd: String?
    public var isGitRepo: Bool
    public var branch: String?
    public var totalAdded: Int
    public var totalDeleted: Int
    public var files: [GitDiffFile]
    public var previewCandidates: [URL]

    public init(
        cwd: String? = nil,
        isGitRepo: Bool = false,
        branch: String? = nil,
        totalAdded: Int = 0,
        totalDeleted: Int = 0,
        files: [GitDiffFile] = [],
        previewCandidates: [URL] = []
    ) {
        self.cwd = cwd
        self.isGitRepo = isGitRepo
        self.branch = branch
        self.totalAdded = totalAdded
        self.totalDeleted = totalDeleted
        self.files = files
        self.previewCandidates = previewCandidates
    }
}

enum GitDiffParser {
    static func parseNumstat(_ raw: String) -> [(path: String, added: Int, deleted: Int, isBinary: Bool)] {
        var results: [(path: String, added: Int, deleted: Int, isBinary: Bool)] = []
        for line in raw.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let addStr = parts[0].trimmingCharacters(in: .whitespaces)
            let delStr = parts[1].trimmingCharacters(in: .whitespaces)
            let path = PreviewTarget.replacingUnsafeScalars(parts[2].trimmingCharacters(in: .whitespaces))
            guard !path.isEmpty else { continue }
            let isBin = (addStr == "-" && delStr == "-")
            let added = isBin ? 0 : (Int(addStr) ?? 0)
            let deleted = isBin ? 0 : (Int(delStr) ?? 0)
            results.append((path: path, added: added, deleted: deleted, isBinary: isBin))
        }
        return results
    }

    static func parseUnifiedDiff(_ raw: String, maxLines: Int = GitDiffService.maxDiffLinesPerFile) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        let lines = raw.components(separatedBy: "\n")
        var currentFile: GitDiffFile?
        var lineIndex = 0
        var sawPlusPath = false

        func flushCurrent() {
            if let f = currentFile, !f.path.isEmpty {
                files.append(f)
            }
            currentFile = nil
            sawPlusPath = false
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flushCurrent()
                lineIndex = 0
                let fallback = extractGitHeaderPath(from: line)
                currentFile = GitDiffFile(path: fallback, status: "M", added: 0, deleted: 0, lines: [], truncated: false)
                continue
            }

            guard currentFile != nil else { continue }

            if line.hasPrefix("new file mode") {
                currentFile?.status = "A"
                continue
            } else if line.hasPrefix("deleted file mode") {
                currentFile?.status = "D"
                continue
            } else if line.hasPrefix("rename from ") {
                currentFile?.status = "R"
                continue
            } else if line.hasPrefix("--- a/") && !sawPlusPath {
                let p = PreviewTarget.replacingUnsafeScalars(String(line.dropFirst(6)))
                if !p.isEmpty { currentFile?.path = p }
                continue
            } else if line.hasPrefix("+++ b/") {
                let p = PreviewTarget.replacingUnsafeScalars(String(line.dropFirst(6)))
                if !p.isEmpty {
                    currentFile?.path = p
                    sawPlusPath = true
                }
                continue
            } else if line.hasPrefix("---") || line.hasPrefix("+++") {
                continue
            }

            let kind: GitDiffLine.Kind?
            if line.hasPrefix("@@") {
                kind = .hunkHeader
            } else if line.hasPrefix("+") {
                kind = .added
                currentFile?.added += 1
            } else if line.hasPrefix("-") {
                kind = .removed
                currentFile?.deleted += 1
            } else if line.hasPrefix(" ") {
                kind = .context
            } else {
                kind = nil
            }

            if let kind {
                if (currentFile?.lines.count ?? 0) < maxLines {
                    lineIndex += 1
                    currentFile?.lines.append(GitDiffLine(id: lineIndex, kind: kind, text: line))
                } else {
                    currentFile?.truncated = true
                }
            }
        }
        flushCurrent()
        return files
    }

    /// Extract the `b/<path>` part of a `diff --git a/<p> b/<p>` header, handling spaces in paths.
    static func extractGitHeaderPath(from line: String) -> String {
        guard line.hasPrefix("diff --git ") else { return "" }
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("a/") {
            let afterA = String(rest.dropFirst(2))
            if let range = afterA.range(of: " b/") {
                let aCandidate = String(afterA[..<range.lowerBound])
                let bCandidate = String(afterA[range.upperBound...])
                if aCandidate == bCandidate {
                    return PreviewTarget.replacingUnsafeScalars(bCandidate)
                }
            }
            if let range = afterA.range(of: " b/", options: .backwards) {
                return PreviewTarget.replacingUnsafeScalars(String(afterA[range.upperBound...]))
            }
        }
        let parts = rest.components(separatedBy: " ")
        if parts.count >= 2 {
            let bPart = parts.last ?? ""
            let raw = bPart.hasPrefix("b/") ? String(bPart.dropFirst(2)) : bPart
            return PreviewTarget.replacingUnsafeScalars(raw)
        }
        return ""
    }
}
