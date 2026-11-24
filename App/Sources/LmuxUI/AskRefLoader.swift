import Darwin
import Foundation

/// Securely loads workspace-contained file snippets (`refs`) and single-file git diffs (`gitDiff`).
public enum AskRefLoader {
    public static let maxFileBytes = 512 * 1024
    public static let maxLines = 120
    private static let suffixRE = try? NSRegularExpression(pattern: #":(\d+)(?:-(\d+))?$"#)

    public static func loadFileRef(
        _ raw: String,
        baseDir: String?,
        repoRoot: String?
    ) -> AskFileRefResult {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty,
              !PreviewTarget.hasUnsafeScalar(trimmedRaw),
              !trimmedRaw.contains("://") else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: raw, errorMessage: "Invalid file reference")
        }
        guard let baseDir, !baseDir.isEmpty else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: trimmedRaw, errorMessage: "No workspace directory available")
        }

        let (relPath, startLine, endLine) = parsePathAndRange(trimmedRaw, baseDir: baseDir)
        guard isSafeRelativePath(relPath) else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: relPath, errorMessage: "Path outside workspace boundary")
        }

        let baseURL = URL(fileURLWithPath: baseDir).resolvingSymlinksInPath()
        let rootPath: String
        if let repoRoot, !repoRoot.isEmpty, GitDiffService.isPathContained(baseURL, inDirectory: repoRoot) {
            rootPath = URL(fileURLWithPath: repoRoot).resolvingSymlinksInPath().path
        } else {
            rootPath = baseURL.path
        }

        let candidateURL = baseURL.appendingPathComponent(relPath)
        guard GitDiffService.isPathContained(candidateURL, inDirectory: rootPath) else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: relPath, errorMessage: "Blocked symlink or path outside repository")
        }

        // Open canonical parent + leaf with O_NOFOLLOW | O_NONBLOCK so symlinks and FIFOs fail cleanly without blocking.
        let fd = Darwin.open(candidateURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: relPath, errorMessage: "Cannot open file securely")
        }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: relPath, errorMessage: "Not a regular file")
        }
        guard st.st_size <= off_t(maxFileBytes) else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: relPath, errorMessage: "File exceeds 512 KB limit")
        }
        guard let data = try? fh.read(upToCount: maxFileBytes + 1), data.count <= maxFileBytes else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: relPath, errorMessage: "File exceeds 512 KB limit")
        }
        guard !data.contains(0) else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: relPath, errorMessage: "Binary file cannot be displayed")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return AskFileRefResult(id: raw, raw: raw, relativePath: relPath, errorMessage: "File is not valid UTF-8 text")
        }

        var allLines = text.components(separatedBy: "\n")
        if allLines.last == "", allLines.count > 1 {
            allLines.removeLast()
        }

        let sliceStart = max(1, startLine ?? 1)
        let sliceEnd = min(allLines.count, max(sliceStart, endLine ?? allLines.count))
        let sliced: [String]
        if allLines.isEmpty || sliceStart > allLines.count {
            sliced = []
        } else {
            sliced = Array(allLines[(sliceStart - 1)...(sliceEnd - 1)])
        }
        let capped = Array(sliced.prefix(maxLines))
        let truncated = sliced.count > maxLines

        return AskFileRefResult(
            id: raw,
            raw: raw,
            relativePath: relPath,
            resolvedURL: candidateURL.resolvingSymlinksInPath(),
            startLine: sliceStart,
            endLine: capped.isEmpty ? sliceStart : sliceStart + capped.count - 1,
            lines: capped,
            truncated: truncated
        )
    }

    public static func loadGitDiff(_ relPath: String, cwd: String?) async -> AskGitDiffRefResult {
        let trimmed = relPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == relPath,
              !PreviewTarget.hasUnsafeScalar(trimmed),
              !trimmed.hasPrefix("-"),
              isSafeRelativePath(trimmed) else {
            return AskGitDiffRefResult(id: relPath, relativePath: relPath, errorMessage: "Invalid git diff path")
        }
        guard let cwd, !cwd.isEmpty else {
            return AskGitDiffRefResult(id: relPath, relativePath: trimmed, errorMessage: "No working directory")
        }

        let topRes = await GitDiffService.runGitHardened(["rev-parse", "--show-toplevel"], cwd: cwd)
        let rawTop = topRes.status == 0 ? topRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !rawTop.isEmpty else {
            return AskGitDiffRefResult(id: relPath, relativePath: trimmed, errorMessage: "Not inside a Git repository")
        }
        let repoRoot = URL(fileURLWithPath: rawTop).resolvingSymlinksInPath().path
        let cwdCanonical = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        let targetURL = cwdCanonical.appendingPathComponent(trimmed)
        guard GitDiffService.isPathContained(targetURL, inDirectory: repoRoot) else {
            return AskGitDiffRefResult(id: relPath, relativePath: trimmed, errorMessage: "Path outside Git repository")
        }

        guard let filterEnv = await GitDiffService.buildFilterOverrideEnv(in: cwd),
              let emptyTree = await GitDiffService.emptyTreeHash(in: cwd) else {
            return AskGitDiffRefResult(id: relPath, relativePath: trimmed, errorMessage: "Failed to isolate Git filters")
        }

        var diffEnv = filterEnv
        diffEnv["GIT_ATTR_SOURCE"] = emptyTree

        let baseDiffFlags = [
            "diff", "--unified=3", "--no-ext-diff", "--no-textconv",
            "--ignore-submodules=all", "--src-prefix=a/", "--dst-prefix=b/"
        ]
        let headCheck = await GitDiffService.runGitHardened(["rev-parse", "--verify", "HEAD"], cwd: cwd)
        let diffArgs = headCheck.status == 0
            ? baseDiffFlags + ["HEAD", "--", trimmed]
            : baseDiffFlags + ["--cached", "--", trimmed]
        let diffRes = await GitDiffService.runGitHardened(diffArgs, env: diffEnv, cwd: cwd)

        if diffRes.status == 0 {
            let parsed = GitDiffParser.parseUnifiedDiff(diffRes.stdout, maxLines: maxLines)
            if let first = parsed.first, !first.lines.isEmpty {
                return AskGitDiffRefResult(
                    id: relPath,
                    relativePath: trimmed,
                    lines: first.lines,
                    truncated: first.truncated || diffRes.truncated
                )
            }
        }

        // Fall back to safe untracked / newly added file inspection (including unborn HEAD repositories).
        let (lines, _, truncated) = GitDiffService.readUntrackedLines(at: targetURL, cwd: repoRoot)
        if !lines.isEmpty {
            return AskGitDiffRefResult(id: relPath, relativePath: trimmed, lines: lines, truncated: truncated)
        }

        let statusRes = await GitDiffService.runGitHardened(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all", "--", trimmed],
            env: diffEnv,
            cwd: cwd
        )
        if statusRes.stdout.isEmpty {
            return AskGitDiffRefResult(id: relPath, relativePath: trimmed, errorMessage: "No changes for \(trimmed)")
        }
        return AskGitDiffRefResult(id: relPath, relativePath: trimmed, errorMessage: "Binary or unreadable changed file")
    }

    private static func parsePathAndRange(_ raw: String, baseDir: String) -> (String, Int?, Int?) {
        let baseURL = URL(fileURLWithPath: baseDir)
        let exactURL = baseURL.appendingPathComponent(raw)
        if FileManager.default.fileExists(atPath: exactURL.path) {
            return (raw, nil, nil)
        }
        guard let re = suffixRE else { return (raw, nil, nil) }
        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = re.firstMatch(in: raw, range: nsRange),
              let fullRange = Range(match.range, in: raw),
              let startRange = Range(match.range(at: 1), in: raw),
              let startVal = Int(raw[startRange]) else {
            return (raw, nil, nil)
        }
        let pathPart = String(raw[..<fullRange.lowerBound])
        let endVal: Int?
        if match.range(at: 2).location != NSNotFound, let r2 = Range(match.range(at: 2), in: raw) {
            endVal = Int(raw[r2])
        } else {
            endVal = startVal
        }
        return (pathPart, startVal, endVal)
    }

    private static func isSafeRelativePath(_ relPath: String) -> Bool {
        guard !relPath.isEmpty,
              !relPath.hasPrefix("/"),
              !relPath.hasPrefix("~") else { return false }
        let components = relPath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0 == ".." || $0.isEmpty }
    }
}
