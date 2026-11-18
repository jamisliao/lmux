import Foundation
import Observation

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

@MainActor
@Observable
public final class GitDiffService {
    public private(set) var snapshot = GitDiffSnapshot()
    public private(set) var isLoading = false

    @ObservationIgnored
    private var currentGeneration: UInt64 = 0
    @ObservationIgnored
    private var activeProcess: Process?

    public init() {}

    public func refresh(cwd: String?, immediate: Bool = false) {
        currentGeneration &+= 1
        let gen = currentGeneration

        activeProcess?.terminate()
        activeProcess = nil

        guard let cwd, !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else {
            snapshot = GitDiffSnapshot(cwd: cwd, isGitRepo: false)
            isLoading = false
            return
        }

        isLoading = true

        Task { @MainActor [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self, self.currentGeneration == gen else { return }

            let check = await self.runGit(["-C", cwd, "rev-parse", "--is-inside-work-tree"], cwd: cwd, gen: gen)
            guard self.currentGeneration == gen else { return }

            if check.status != 0 || check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != "true" {
                self.snapshot = GitDiffSnapshot(cwd: cwd, isGitRepo: false)
                self.isLoading = false
                return
            }

            // Branch name
            var branch: String?
            let bRes = await self.runGit(["-C", cwd, "branch", "--show-current"], cwd: cwd, gen: gen)
            let bStr = PreviewTarget.replacingUnsafeScalars(bRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if !bStr.isEmpty {
                branch = bStr
            } else {
                let headRes = await self.runGit(["-C", cwd, "rev-parse", "--short", "HEAD"], cwd: cwd, gen: gen)
                let hStr = PreviewTarget.replacingUnsafeScalars(headRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                if !hStr.isEmpty {
                    branch = "(detached: \(hStr))"
                }
            }
            guard self.currentGeneration == gen else { return }

            // Diff & numstat
            var numstatRes = await self.runGit(
                ["-C", cwd, "diff", "--no-ext-diff", "--no-textconv", "-c", "core.fsmonitor=false", "--numstat", "HEAD", "--"],
                cwd: cwd, gen: gen
            )
            var diffRes = await self.runGit(
                ["-C", cwd, "diff", "--no-ext-diff", "--no-textconv", "-c", "core.fsmonitor=false", "HEAD", "--"],
                cwd: cwd, gen: gen
            )
            guard self.currentGeneration == gen else { return }

            // Unborn HEAD fallback
            if numstatRes.status != 0 {
                numstatRes = await self.runGit(
                    ["-C", cwd, "diff", "--no-ext-diff", "--no-textconv", "-c", "core.fsmonitor=false", "--numstat", "--cached", "--"],
                    cwd: cwd, gen: gen
                )
                diffRes = await self.runGit(
                    ["-C", cwd, "diff", "--no-ext-diff", "--no-textconv", "-c", "core.fsmonitor=false", "--cached", "--"],
                    cwd: cwd, gen: gen
                )
            }
            guard self.currentGeneration == gen else { return }

            let numstatList = Self.parseNumstat(numstatRes.stdout)
            var files = Self.parseUnifiedDiff(diffRes.stdout)

            // Merge numstat stats into files
            var filesByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
            for item in numstatList {
                if var f = filesByPath[item.path] {
                    f.added = item.added
                    f.deleted = item.deleted
                    filesByPath[item.path] = f
                } else {
                    filesByPath[item.path] = GitDiffFile(path: item.path, status: "M", added: item.added, deleted: item.deleted)
                }
            }

            // Check status for untracked / staged files
            let statusRes = await self.runGit(["-C", cwd, "status", "--porcelain=v1", "-z"], cwd: cwd, gen: gen)
            guard self.currentGeneration == gen else { return }

            let entries = statusRes.stdout.split(separator: "\0", omittingEmptySubsequences: true)
            for entry in entries {
                let s = String(entry)
                guard s.count >= 3 else { continue }
                let code = String(s.prefix(2))
                let rawPath = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let cleanPath = PreviewTarget.replacingUnsafeScalars(rawPath)
                guard !cleanPath.isEmpty else { continue }

                if filesByPath[cleanPath] == nil {
                    let st = code.trimmingCharacters(in: .whitespaces)
                    var lineCount = 0
                    var lines: [GitDiffLine] = []
                    let fullURL = URL(fileURLWithPath: cwd).appendingPathComponent(cleanPath)
                    if let content = try? String(contentsOf: fullURL, encoding: .utf8) {
                        let contentLines = content.components(separatedBy: "\n")
                        lineCount = contentLines.count
                        lines = contentLines.prefix(100).enumerated().map {
                            GitDiffLine(id: $0 + 1, kind: .added, text: "+" + $1)
                        }
                    }
                    filesByPath[cleanPath] = GitDiffFile(
                        path: cleanPath,
                        status: st.isEmpty ? "?" : st,
                        added: lineCount,
                        deleted: 0,
                        lines: lines,
                        truncated: lineCount > 100
                    )
                }
            }

            files = Array(filesByPath.values).sorted { $0.path < $1.path }
            let totalAdded = files.reduce(0) { $0 + $1.added }
            let totalDeleted = files.reduce(0) { $0 + $1.deleted }

            // Preview candidates
            let previewCandidates = self.scanPreviewCandidates(in: cwd)
            guard self.currentGeneration == gen else { return }

            self.snapshot = GitDiffSnapshot(
                cwd: cwd,
                isGitRepo: true,
                branch: branch,
                totalAdded: totalAdded,
                totalDeleted: totalDeleted,
                files: files,
                previewCandidates: previewCandidates
            )
            self.isLoading = false
        }
    }

    private func scanPreviewCandidates(in cwd: String) -> [URL] {
        let fm = FileManager.default
        let cwdURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        guard let items = try? fm.contentsOfDirectory(atPath: cwd) else { return [] }

        var resolvedList: [URL] = []
        for item in items {
            let cleanItem = PreviewTarget.replacingUnsafeScalars(item)
            guard !cleanItem.isEmpty, !cleanItem.hasPrefix(".") else { continue }
            guard let resolved = PreviewTarget.resolve(cleanItem, cwd: cwd, fileManager: fm) else { continue }
            // Security check: ensure symlinks cannot escape the workspace directory
            let canonicalTarget = resolved.resolvingSymlinksInPath()
            guard canonicalTarget.path.hasPrefix(cwdURL.path) else { continue }
            resolvedList.append(resolved)
        }

        resolvedList.sort { a, b in
            let aName = a.lastPathComponent.lowercased()
            let bName = b.lastPathComponent.lowercased()
            let aIsReadme = aName.hasPrefix("readme")
            let bIsReadme = bName.hasPrefix("readme")
            if aIsReadme != bIsReadme {
                return aIsReadme
            }
            return aName < bName
        }

        return Array(resolvedList.prefix(5))
    }

    private func runGit(
        _ args: [String],
        cwd: String,
        gen: UInt64,
        maxBytes: Int = 256 * 1024,
        timeout: TimeInterval = 3.0
    ) async -> (status: Int32, stdout: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [weak self] in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                p.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { $1 }

                let outPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = Pipe()

                var outData = Data()
                let lock = NSLock()
                var resumed = false

                func finish(status: Int32) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    let str = String(decoding: outData, as: UTF8.self)
                    continuation.resume(returning: (status, str))
                }

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return }
                    lock.lock()
                    if outData.count < maxBytes {
                        let toTake = min(chunk.count, maxBytes - outData.count)
                        outData.append(chunk.prefix(toTake))
                    }
                    let count = outData.count
                    lock.unlock()
                    if count >= maxBytes {
                        handle.readabilityHandler = nil
                    }
                }

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    p.terminate()
                }
                timer.resume()

                p.terminationHandler = { proc in
                    timer.cancel()
                    finish(status: proc.terminationStatus)
                }

                DispatchQueue.main.async {
                    if let self, self.currentGeneration == gen {
                        self.activeProcess = p
                    }
                }

                do {
                    try p.run()
                } catch {
                    timer.cancel()
                    finish(status: -1)
                }
            }
        }
    }

    public static func parseNumstat(_ raw: String) -> [(path: String, added: Int, deleted: Int, isBinary: Bool)] {
        var results: [(path: String, added: Int, deleted: Int, isBinary: Bool)] = []
        let lines = raw.components(separatedBy: "\n")
        for line in lines {
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

    public static func parseUnifiedDiff(_ raw: String, maxLines: Int = 100) -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        let lines = raw.components(separatedBy: "\n")
        var currentFile: GitDiffFile?
        var lineIndex = 0

        func flushCurrent() {
            if let f = currentFile {
                files.append(f)
                currentFile = nil
            }
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flushCurrent()
                lineIndex = 0
                var path = ""
                let parts = line.components(separatedBy: " ")
                if parts.count >= 4 {
                    let bPart = parts[3]
                    if bPart.hasPrefix("b/") {
                        path = String(bPart.dropFirst(2))
                    } else {
                        path = bPart
                    }
                }
                path = PreviewTarget.replacingUnsafeScalars(path)
                currentFile = GitDiffFile(path: path, status: "M", added: 0, deleted: 0, lines: [], truncated: false)
                continue
            }

            guard currentFile != nil else { continue }

            if line.hasPrefix("new file mode") {
                currentFile?.status = "A"
            } else if line.hasPrefix("deleted file mode") {
                currentFile?.status = "D"
            }

            let kind: GitDiffLine.Kind?
            if line.hasPrefix("@@") {
                kind = .hunkHeader
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                kind = .added
                currentFile?.added += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
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
}
