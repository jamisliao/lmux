import Foundation
import Observation

@MainActor
@Observable
public final class GitDiffService {
    public nonisolated static let maxDiffLinesPerFile = 100
    private nonisolated static let maxUntrackedReadBytes = 64 * 1024

    public private(set) var snapshot = GitDiffSnapshot()
    public private(set) var isLoading = false

    @ObservationIgnored
    private var currentGeneration: UInt64 = 0
    @ObservationIgnored
    private var activeProcess: Process?

    public init() {}

    public static func isPathContained(_ url: URL, inDirectory dir: String) -> Bool {
        let dirURL = URL(fileURLWithPath: dir).resolvingSymlinksInPath()
        let canonical = url.resolvingSymlinksInPath().path
        let prefix = dirURL.path == "/" ? "/" : dirURL.path + "/"
        return canonical.hasPrefix(prefix) || canonical == dirURL.path
    }

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

            let branch = await self.resolveBranch(in: cwd, gen: gen)
            guard self.currentGeneration == gen else { return }

            let baseDiffFlags = ["-C", cwd, "-c", "core.fsmonitor=false", "diff", "--no-ext-diff", "--no-textconv"]
            var numstatRes = await self.runGit(baseDiffFlags + ["--numstat", "HEAD", "--"], cwd: cwd, gen: gen)
            var diffRes = await self.runGit(baseDiffFlags + ["HEAD", "--"], cwd: cwd, gen: gen)
            guard self.currentGeneration == gen else { return }

            if numstatRes.status != 0 {
                numstatRes = await self.runGit(baseDiffFlags + ["--numstat", "--cached", "--"], cwd: cwd, gen: gen)
                diffRes = await self.runGit(baseDiffFlags + ["--cached", "--"], cwd: cwd, gen: gen)
            }
            guard self.currentGeneration == gen else { return }

            let statusRes = await self.runGit(["-C", cwd, "status", "--porcelain=v1", "-z"], cwd: cwd, gen: gen)
            guard self.currentGeneration == gen else { return }

            let built = await Task.detached(priority: .utility) {
                Self.buildSnapshot(
                    cwd: cwd,
                    branch: branch,
                    numstatStdout: numstatRes.stdout,
                    diffStdout: diffRes.stdout,
                    statusStdout: statusRes.stdout
                )
            }.value
            guard self.currentGeneration == gen else { return }

            self.snapshot = built
            self.isLoading = false
        }
    }

    private func resolveBranch(in cwd: String, gen: UInt64) async -> String? {
        let bRes = await runGit(["-C", cwd, "branch", "--show-current"], cwd: cwd, gen: gen)
        let bStr = PreviewTarget.replacingUnsafeScalars(bRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        if !bStr.isEmpty { return bStr }
        let headRes = await runGit(["-C", cwd, "rev-parse", "--short", "HEAD"], cwd: cwd, gen: gen)
        let hStr = PreviewTarget.replacingUnsafeScalars(headRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        return hStr.isEmpty ? nil : "(detached: \(hStr))"
    }

    private nonisolated static func buildSnapshot(
        cwd: String,
        branch: String?,
        numstatStdout: String,
        diffStdout: String,
        statusStdout: String
    ) -> GitDiffSnapshot {
        let numstatList = GitDiffParser.parseNumstat(numstatStdout)
        let parsedFiles = GitDiffParser.parseUnifiedDiff(diffStdout, maxLines: maxDiffLinesPerFile)
        var filesByPath = Dictionary(uniqueKeysWithValues: parsedFiles.map { ($0.path, $0) })

        for item in numstatList {
            if var f = filesByPath[item.path] {
                f.added = item.added
                f.deleted = item.deleted
                filesByPath[item.path] = f
            } else {
                filesByPath[item.path] = GitDiffFile(path: item.path, status: "M", added: item.added, deleted: item.deleted)
            }
        }

        let entries = statusStdout.split(separator: "\0", omittingEmptySubsequences: true)
        var i = 0
        while i < entries.count {
            let s = String(entries[i])
            let code = s.count >= 2 ? String(s.prefix(2)) : ""
            let isRenameOrCopy = code.first == "R" || code.first == "C"
            defer { i += isRenameOrCopy ? 2 : 1 }
            guard s.count >= 3 else { continue }
            let rawPath = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let cleanPath = PreviewTarget.replacingUnsafeScalars(rawPath)
            guard !cleanPath.isEmpty, filesByPath[cleanPath] == nil else { continue }

            let st = code.trimmingCharacters(in: .whitespaces)
            let fullURL = URL(fileURLWithPath: cwd).appendingPathComponent(cleanPath)
            let (lines, totalCount, isTruncated) = readUntrackedLines(at: fullURL, cwd: cwd)
            filesByPath[cleanPath] = GitDiffFile(
                path: cleanPath,
                status: st.isEmpty ? "?" : st,
                added: totalCount,
                deleted: 0,
                lines: lines,
                truncated: isTruncated
            )
        }

        let files = Array(filesByPath.values).sorted { $0.path < $1.path }
        let totalAdded = files.reduce(0) { $0 + $1.added }
        let totalDeleted = files.reduce(0) { $0 + $1.deleted }
        let previewCandidates = scanPreviewCandidates(in: cwd)

        return GitDiffSnapshot(
            cwd: cwd,
            isGitRepo: true,
            branch: branch,
            totalAdded: totalAdded,
            totalDeleted: totalDeleted,
            files: files,
            previewCandidates: previewCandidates
        )
    }

    private nonisolated static func readUntrackedLines(at url: URL, cwd: String) -> ([GitDiffLine], Int, Bool) {
        let dirURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        let canonical = url.resolvingSymlinksInPath().path
        let prefix = dirURL.path == "/" ? "/" : dirURL.path + "/"
        guard canonical.hasPrefix(prefix),
              let rv = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]),
              rv.isRegularFile == true,
              let fh = try? FileHandle(forReadingFrom: url) else {
            return ([], 0, false)
        }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: maxUntrackedReadBytes),
              let content = String(data: data, encoding: .utf8) else {
            return ([], 0, false)
        }
        let contentLines = content.components(separatedBy: "\n")
        let capped = contentLines.prefix(maxDiffLinesPerFile).enumerated().map {
            GitDiffLine(id: $0 + 1, kind: .added, text: "+" + $1)
        }
        return (capped, contentLines.count, contentLines.count > maxDiffLinesPerFile || data.count == maxUntrackedReadBytes)
    }

    private nonisolated static func scanPreviewCandidates(in cwd: String) -> [URL] {
        let fm = FileManager.default
        let cwdURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        let prefix = cwdURL.path == "/" ? "/" : cwdURL.path + "/"
        guard let items = try? fm.contentsOfDirectory(atPath: cwd) else { return [] }

        var resolvedList: [URL] = []
        for item in items {
            let cleanItem = PreviewTarget.replacingUnsafeScalars(item)
            guard !cleanItem.isEmpty, !cleanItem.hasPrefix(".") else { continue }
            guard let resolved = PreviewTarget.resolve(cleanItem, cwd: cwd, fileManager: fm) else { continue }
            let canonicalTarget = resolved.resolvingSymlinksInPath()
            guard canonicalTarget.path.hasPrefix(prefix) else { continue }
            resolvedList.append(resolved)
        }

        resolvedList.sort { a, b in
            let aName = a.lastPathComponent.lowercased()
            let bName = b.lastPathComponent.lowercased()
            let aIsReadme = aName.hasPrefix("readme")
            let bIsReadme = bName.hasPrefix("readme")
            if aIsReadme != bIsReadme { return aIsReadme }
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
                p.standardError = FileHandle.nullDevice

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    p.terminate()
                }
                timer.resume()

                DispatchQueue.main.async {
                    if let self, self.currentGeneration == gen {
                        self.activeProcess = p
                    }
                }

                do {
                    try p.run()
                } catch {
                    timer.cancel()
                    try? outPipe.fileHandleForReading.close()
                    try? outPipe.fileHandleForWriting.close()
                    continuation.resume(returning: (-1, ""))
                    return
                }

                // Close parent copy of write end so reading hits EOF cleanly when git exits.
                try? outPipe.fileHandleForWriting.close()

                var outData = Data()
                let reader = outPipe.fileHandleForReading
                while true {
                    let chunk = (try? reader.read(upToCount: 64 * 1024)) ?? Data()
                    if chunk.isEmpty { break }
                    if outData.count < maxBytes {
                        outData.append(chunk.prefix(maxBytes - outData.count))
                    }
                }
                try? reader.close()
                p.waitUntilExit()
                timer.cancel()

                let str = String(decoding: outData, as: UTF8.self)
                continuation.resume(returning: (p.terminationStatus, str))
            }
        }
    }

    public nonisolated static func parseNumstat(_ raw: String) -> [(path: String, added: Int, deleted: Int, isBinary: Bool)] {
        GitDiffParser.parseNumstat(raw)
    }

    public nonisolated static func parseUnifiedDiff(_ raw: String, maxLines: Int = maxDiffLinesPerFile) -> [GitDiffFile] {
        GitDiffParser.parseUnifiedDiff(raw, maxLines: maxLines)
    }
}
