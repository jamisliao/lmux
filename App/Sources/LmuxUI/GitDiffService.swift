import Darwin
import Foundation
import Observation

@MainActor
@Observable
public final class GitDiffService {
    public nonisolated static let maxDiffLinesPerFile = 100
    private nonisolated static let maxUntrackedReadBytes = 64 * 1024
    internal nonisolated static let maxFilterEnvBytes = 512 * 1024

    public private(set) var snapshot = GitDiffSnapshot()
    public private(set) var isLoading = false
    @ObservationIgnored
    public private(set) var snapshotHasHunks = true

    @ObservationIgnored
    private var currentGeneration: UInt64 = 0
    @ObservationIgnored
    private var activeProcess: Process?
    @ObservationIgnored
    private var emptyTreeByRoot: [String: String] = [:]
    @ObservationIgnored
    private let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    public nonisolated static func isPathContained(_ url: URL, inDirectory dir: String) -> Bool {
        let dirURL = URL(fileURLWithPath: dir).resolvingSymlinksInPath()
        let canonical = url.resolvingSymlinksInPath().path
        let prefix = dirURL.path == "/" ? "/" : dirURL.path + "/"
        return canonical.hasPrefix(prefix) || canonical == dirURL.path
    }

    public func refresh(cwd: String?, immediate: Bool = false, debounceMs: Int = 250, includeHunks: Bool = true) {
        currentGeneration &+= 1
        let gen = currentGeneration

        if let active = activeProcess, active.isRunning {
            active.terminate()
        }
        activeProcess = nil

        var isDir: ObjCBool = false
        guard let cwd, !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
              isDir.boolValue else {
            snapshot = GitDiffSnapshot(cwd: cwd, isGitRepo: false)
            snapshotHasHunks = true
            isLoading = false
            return
        }

        isLoading = true

        Task { @MainActor [weak self] in
            if !immediate, debounceMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounceMs) * 1_000_000)
            }
            guard let self, self.currentGeneration == gen else { return }

            // `rev-parse --show-toplevel` succeeds iff cwd is inside a git work tree, eliminating a separate `--is-inside-work-tree` call.
            let topRes = await self.runGit(["rev-parse", "--show-toplevel"], cwd: cwd, gen: gen)
            guard self.currentGeneration == gen else { return }

            let rawTop = topRes.status == 0
                ? topRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            if topRes.status != 0 || rawTop.isEmpty {
                let candidates = await Task.detached(priority: .utility) {
                    Self.scanPreviewCandidates(in: cwd)
                }.value
                guard self.currentGeneration == gen else { return }
                self.snapshot = GitDiffSnapshot(cwd: cwd, isGitRepo: false, previewCandidates: candidates)
                self.snapshotHasHunks = true
                self.isLoading = false
                return
            }
            let repoRoot = FileManager.default.fileExists(atPath: rawTop) ? rawTop : cwd

            let branch = await self.resolveBranch(in: cwd, repoRoot: repoRoot, gen: gen)
            guard self.currentGeneration == gen else { return }

            guard let filterEnv = await self.filterOverrideEnv(in: cwd, gen: gen) else {
                guard self.currentGeneration == gen else { return }
                self.snapshot = GitDiffSnapshot(cwd: cwd, isGitRepo: false)
                self.snapshotHasHunks = true
                self.isLoading = false
                return
            }
            // Read .gitattributes from this repo's own empty tree (SHA-1 or SHA-256) so worktree attributes are ignored.
            // Cached per repoRoot (after filterOverrideEnv succeeds) to avoid spawning hash-object on repeat refreshes.
            let emptyTreeHash: String
            if let cached = self.emptyTreeByRoot[repoRoot] {
                emptyTreeHash = cached
            } else {
                let emptyTreeRes = await self.runGit(["hash-object", "-t", "tree", "/dev/null"], cwd: cwd, gen: gen)
                guard self.currentGeneration == gen else { return }
                let h = emptyTreeRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                guard emptyTreeRes.status == 0, !h.isEmpty else {
                    self.snapshot = GitDiffSnapshot(cwd: cwd, isGitRepo: false)
                    self.snapshotHasHunks = true
                    self.isLoading = false
                    return
                }
                self.emptyTreeByRoot[repoRoot] = h
                emptyTreeHash = h
            }
            var diffEnv = filterEnv
            diffEnv["GIT_ATTR_SOURCE"] = emptyTreeHash

            let statusRes = await self.runGit(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all"], env: diffEnv, cwd: cwd, gen: gen)
            guard self.currentGeneration == gen else { return }
            guard statusRes.status == 0 else {
                self.snapshot = GitDiffSnapshot(cwd: cwd, isGitRepo: false)
                self.snapshotHasHunks = true
                self.isLoading = false
                return
            }

            let numstatRes: (status: Int32, stdout: String, stdoutData: Data, truncated: Bool)
            let diffRes: (status: Int32, stdout: String, stdoutData: Data, truncated: Bool)
            if Self.hasTrackedStatusEntries(statusRes.stdout) {
                let baseDiffFlags = ["diff", "--unified=3", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--src-prefix=a/", "--dst-prefix=b/"]
                var nRes = await self.runGit(baseDiffFlags + ["--numstat", "-z", "HEAD", "--"], env: diffEnv, cwd: cwd, gen: gen)
                guard self.currentGeneration == gen else { return }
                if nRes.status == 0 {
                    diffRes = includeHunks
                        ? await self.runGit(baseDiffFlags + ["HEAD", "--"], env: diffEnv, cwd: cwd, gen: gen)
                        : (0, "", Data(), false)
                } else {
                    nRes = await self.runGit(baseDiffFlags + ["--numstat", "-z", "--cached", "--"], env: diffEnv, cwd: cwd, gen: gen)
                    guard self.currentGeneration == gen else { return }
                    diffRes = (nRes.status == 0 && includeHunks)
                        ? await self.runGit(baseDiffFlags + ["--cached", "--"], env: diffEnv, cwd: cwd, gen: gen)
                        : (nRes.status == 0 ? 0 : nRes.status, "", Data(), false)
                }
                numstatRes = nRes
                guard self.currentGeneration == gen else { return }
                guard numstatRes.status == 0, diffRes.status == 0 else {
                    self.snapshot = GitDiffSnapshot(cwd: cwd, isGitRepo: false)
                    self.snapshotHasHunks = true
                    self.isLoading = false
                    return
                }
            } else {
                // Clean working tree or untracked-only: skip `git diff --numstat` and `git diff` completely.
                numstatRes = (0, "", Data(), false)
                diffRes = (0, "", Data(), false)
            }

            let built = await Task.detached(priority: .utility) {
                Self.buildSnapshot(
                    cwd: cwd,
                    repoRoot: repoRoot,
                    branch: branch,
                    numstatStdout: numstatRes.stdout,
                    diffStdout: diffRes.stdout,
                    diffTruncated: diffRes.truncated,
                    statusStdout: statusRes.stdout
                )
            }.value
            guard self.currentGeneration == gen else { return }

            self.snapshot = built
            self.snapshotHasHunks = includeHunks
            self.isLoading = false
        }
    }

    /// Stateless hardened `git config` scan discovering filter override env vars (`nonisolated static`).
    nonisolated static func buildFilterOverrideEnv(
        in cwd: String,
        gitPath: String = "/usr/bin/git"
    ) async -> [String: String]? {
        let res = await runGitHardened(
            ["config", "--includes", "--name-only", "-z", "--list"],
            env: ["LC_ALL": "C"],
            cwd: cwd,
            gitPath: gitPath,
            maxBytes: 2 * 1024 * 1024
        )
        guard !res.truncated, res.status == 0 else { return nil }
        return buildFilterOverrideEnv(from: res.stdoutData)
    }

    /// Stateless hardened empty tree hash lookup (`nonisolated static`) usable without `@MainActor` generation state.
    nonisolated static func emptyTreeHash(
        in cwd: String,
        gitPath: String = "/usr/bin/git"
    ) async -> String? {
        let res = await runGitHardened(["hash-object", "-t", "tree", "/dev/null"], cwd: cwd, gitPath: gitPath)
        let h = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (res.status == 0 && !h.isEmpty) ? h : nil
    }

    /// Discovers all configured `filter.*.(clean|process|smudge|required)` keys across every scope
    /// (including `.git/config`, `[include]`/`[includeIf]`, `.git/config.worktree`, global, and system)
    /// and returns `GIT_CONFIG_COUNT` env overrides that neutralize them without `-c` first-`=` splitting.
    /// Returns `nil` on error/timeout/truncation/unrepresentable keys so callers fail closed.
    private func filterOverrideEnv(in cwd: String, gen: UInt64) async -> [String: String]? {
        let res = await runGit(
            ["config", "--includes", "--name-only", "-z", "--list"],
            env: ["LC_ALL": "C"],
            cwd: cwd,
            gen: gen,
            maxBytes: 2 * 1024 * 1024
        )
        guard !res.truncated, res.status == 0 else {
            return nil
        }
        let data = res.stdoutData
        let env = await Task.detached(priority: .utility) {
            Self.buildFilterOverrideEnv(from: data)
        }.value
        guard self.currentGeneration == gen else { return nil }
        return env
    }

    private nonisolated static func buildFilterOverrideEnv(from data: Data) -> [String: String]? {
        if data.isEmpty { return [:] }

        let filterPrefix = Array("filter.".utf8)
        let suffixes: [[UInt8]] = [
            Array(".clean".utf8),
            Array(".process".utf8),
            Array(".smudge".utf8),
            Array(".required".utf8),
        ]
        let requiredSuffix = suffixes[3]

        var keys: [(key: String, isRequired: Bool)] = []
        var seen = Set<Data>()
        // Fail closed before Process.run() ARG_MAX limits (~1 MiB on macOS) if filter env vars exceed 512 KiB.
        var totalEnvBytes = "GIT_CONFIG_COUNT=".utf8.count + 12 + 1
        for rawSlice in data.split(separator: 0x00, omittingEmptySubsequences: true) {
            let lowered = rawSlice.map { ($0 >= 0x41 && $0 <= 0x5A) ? ($0 + 0x20) : $0 }
            guard lowered.starts(with: filterPrefix) else { continue }

            // Fail closed on any non-printable-ASCII byte in filter.* keys: Apple Foundation.Process
            // encodes env/argv via NSString.fileSystemRepresentation (decomposing NFC UTF-8 to NFD)
            // and cannot pass raw non-ASCII or control bytes faithfully in GIT_CONFIG_KEY_*.
            guard rawSlice.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else {
                return nil
            }
            let keyData = Data(rawSlice)
            guard let key = String(data: keyData, encoding: .utf8) else {
                return nil
            }
            guard suffixes.contains(where: { lowered.suffix($0.count).elementsEqual($0) }) else {
                continue
            }

            if seen.insert(keyData).inserted {
                let index = keys.count
                let isRequired = lowered.suffix(requiredSuffix.count).elementsEqual(requiredSuffix)
                let digits = String(index).utf8.count
                let entryBytes = "GIT_CONFIG_KEY_".utf8.count + digits + 1 + keyData.count + 1
                    + "GIT_CONFIG_VALUE_".utf8.count + digits + 1 + (isRequired ? 5 : 0) + 1
                totalEnvBytes += entryBytes
                guard totalEnvBytes <= maxFilterEnvBytes else {
                    return nil
                }
                keys.append((key: key, isRequired: isRequired))
            }
        }
        guard !keys.isEmpty else { return [:] }

        var env: [String: String] = ["GIT_CONFIG_COUNT": "\(keys.count)"]
        for (index, item) in keys.enumerated() {
            env["GIT_CONFIG_KEY_\(index)"] = item.key
            env["GIT_CONFIG_VALUE_\(index)"] = item.isRequired ? "false" : ""
        }
        return env
    }

    private nonisolated static func hasTrackedStatusEntries(_ statusStdout: String) -> Bool {
        let entries = statusStdout.split(separator: "\0", omittingEmptySubsequences: true)
        var i = 0
        while i < entries.count {
            let s = entries[i]
            let code = s.prefix(2)
            let isRenameOrCopy = code.contains("R") || code.contains("C")
            i += isRenameOrCopy ? 2 : 1
            if code != "??" && code != "!!" { return true }
        }
        return false
    }

    private func resolveBranch(in cwd: String, repoRoot: String, gen: UInt64) async -> String? {
        if let local = GitBranch.readStatus(cwd: repoRoot) ?? GitBranch.readStatus(cwd: cwd) {
            if !local.isDetached { return PreviewTarget.replacingUnsafeScalars(local.name) }
            let headRes = await runGit(["rev-parse", "--short", "HEAD"], cwd: cwd, gen: gen)
            let hStr = PreviewTarget.replacingUnsafeScalars(headRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            return hStr.isEmpty ? "(detached: \(PreviewTarget.replacingUnsafeScalars(local.name)))" : "(detached: \(hStr))"
        }
        let bRes = await runGit(["branch", "--show-current"], cwd: cwd, gen: gen)
        let bStr = PreviewTarget.replacingUnsafeScalars(bRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        if !bStr.isEmpty { return bStr }
        let headRes = await runGit(["rev-parse", "--short", "HEAD"], cwd: cwd, gen: gen)
        let hStr = PreviewTarget.replacingUnsafeScalars(headRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        return hStr.isEmpty ? nil : "(detached: \(hStr))"
    }

    private nonisolated static func buildSnapshot(
        cwd: String,
        repoRoot: String,
        branch: String?,
        numstatStdout: String,
        diffStdout: String,
        diffTruncated: Bool = false,
        statusStdout: String
    ) -> GitDiffSnapshot {
        let entries = statusStdout.split(separator: "\0", omittingEmptySubsequences: true)
        var statusOrder: [(path: String, status: String)] = []
        var statusByPath: [String: String] = [:]
        var i = 0
        while i < entries.count {
            let s = String(entries[i])
            let code = s.count >= 2 ? String(s.prefix(2)) : ""
            let isRenameOrCopy = code.contains("R") || code.contains("C")
            defer { i += isRenameOrCopy ? 2 : 1 }
            guard s.count >= 3 else { continue }
            let cleanPath = PreviewTarget.replacingUnsafeScalars(String(s.dropFirst(3)))
            guard !cleanPath.isEmpty else { continue }
            let rawSt = code.trimmingCharacters(in: .whitespaces)
            let st = rawSt.isEmpty ? "M" : rawSt
            if statusByPath[cleanPath] == nil {
                statusByPath[cleanPath] = st
                statusOrder.append((path: cleanPath, status: st))
            }
        }

        let numstatList = GitDiffParser.parseNumstat(numstatStdout)
        let parsedFiles = GitDiffParser.parseUnifiedDiff(diffStdout, maxLines: maxDiffLinesPerFile)
        var filesByPath = Dictionary(parsedFiles.map { ($0.path, $0) }, uniquingKeysWith: { _, latest in latest })
        if diffTruncated, let lastPath = parsedFiles.last?.path, var lastFile = filesByPath[lastPath] {
            lastFile.truncated = true
            filesByPath[lastPath] = lastFile
        }

        for (path, st) in statusByPath {
            if var f = filesByPath[path], f.status == "M" && st != "M" {
                f.status = st
                filesByPath[path] = f
            }
        }

        for item in numstatList {
            if var f = filesByPath[item.path] {
                f.added = item.added
                f.deleted = item.deleted
                filesByPath[item.path] = f
            } else {
                // Omitted from unified diff (e.g. exceeded maxBytes cap) or binary: mark truncated for non-binary diffs.
                let st = statusByPath[item.path] ?? "M"
                filesByPath[item.path] = GitDiffFile(
                    path: item.path,
                    status: st,
                    added: item.added,
                    deleted: item.deleted,
                    lines: [],
                    truncated: !item.isBinary
                )
            }
        }

        for entry in statusOrder where filesByPath[entry.path] == nil {
            let st = entry.status
            let isUntrackedOrAdded = st == "??" || st == "A" || st.hasPrefix("A")
            if isUntrackedOrAdded {
                // Git paths in diff/status are relative to the repository top-level, not necessarily cwd.
                let fullURL = URL(fileURLWithPath: repoRoot).appendingPathComponent(entry.path)
                let (lines, totalCount, isTruncated) = readUntrackedLines(at: fullURL, cwd: repoRoot)
                filesByPath[entry.path] = GitDiffFile(
                    path: entry.path,
                    status: st,
                    added: totalCount,
                    deleted: 0,
                    lines: lines,
                    truncated: isTruncated
                )
            } else {
                // Tracked file absent from both unified diff and numstat: preserve status without faking full-file additions.
                filesByPath[entry.path] = GitDiffFile(
                    path: entry.path,
                    status: st,
                    added: 0,
                    deleted: 0,
                    lines: [],
                    truncated: true
                )
            }
        }

        let files = Array(filesByPath.values)
            .sorted { $0.path < $1.path }
            .map { file in
                var f = file
                f.previewURL = PreviewTarget.resolve(f.path, cwd: repoRoot).flatMap { Self.isPathContained($0, inDirectory: repoRoot) ? $0 : nil }
                return f
            }
        let totalAdded = files.reduce(0) { $0 + $1.added }
        let totalDeleted = files.reduce(0) { $0 + $1.deleted }
        let previewCandidates = scanPreviewCandidates(in: cwd)

        return GitDiffSnapshot(
            cwd: cwd,
            repoRoot: repoRoot,
            isGitRepo: true,
            branch: branch,
            totalAdded: totalAdded,
            totalDeleted: totalDeleted,
            files: files,
            previewCandidates: previewCandidates
        )
    }

    nonisolated static func readUntrackedLines(at url: URL, cwd: String) -> ([GitDiffLine], Int, Bool) {
        let dirURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        let canonicalURL = url.resolvingSymlinksInPath()
        let prefix = dirURL.path == "/" ? "/" : dirURL.path + "/"
        guard canonicalURL.path.hasPrefix(prefix) else { return ([], 0, false) }

        // Open canonical path with O_NOFOLLOW | O_NONBLOCK and verify S_IFREG on the fd to close symlink/FIFO TOCTOU.
        let fd = Darwin.open(canonicalURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return ([], 0, false) }
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return ([], 0, false)
        }
        guard let data = try? fh.read(upToCount: maxUntrackedReadBytes),
              !data.contains(0),
              let content = String(data: data, encoding: .utf8),
              !content.isEmpty else {
            return ([], 0, false)
        }
        var contentLines = content.components(separatedBy: "\n")
        if contentLines.last == "", contentLines.count > 1 {
            contentLines.removeLast()
        }
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
        env: [String: String] = [:],
        cwd: String,
        gen: UInt64,
        maxBytes: Int = 256 * 1024,
        timeout: TimeInterval = 3.0
    ) async -> (status: Int32, stdout: String, stdoutData: Data, truncated: Bool) {
        await Self.runGitHardened(
            args,
            env: env,
            cwd: cwd,
            gitPath: gitPath,
            maxBytes: maxBytes,
            timeout: timeout,
            onProcessLaunch: { [weak self] p in
                DispatchQueue.main.async {
                    guard let self else {
                        if p.isRunning { p.terminate() }
                        return
                    }
                    if self.currentGeneration == gen {
                        self.activeProcess = p
                    } else if p.isRunning {
                        p.terminate()
                    }
                }
                return true
            },
            onProcessExit: { [weak self] p in
                DispatchQueue.main.async {
                    if self?.activeProcess === p {
                        self?.activeProcess = nil
                    }
                }
            }
        )
    }

    nonisolated static func runGitHardened(
        _ args: [String],
        env: [String: String] = [:],
        cwd: String,
        gitPath: String = "/usr/bin/git",
        maxBytes: Int = 256 * 1024,
        timeout: TimeInterval = 3.0,
        onProcessLaunch: (@Sendable (Process) -> Bool)? = nil,
        onProcessExit: (@Sendable (Process) -> Void)? = nil
    ) async -> (status: Int32, stdout: String, stdoutData: Data, truncated: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: gitPath)
                // Neutralize untrusted .git/config hooks, pagers, attributes, path quoting, submodules, ssh/credentials, and remote protocols.
                p.arguments = [
                    "-C", cwd,
                    "--no-pager",
                    "-c", "core.fsmonitor=false",
                    "-c", "core.quotePath=false",
                    "-c", "core.attributesfile=/dev/null",
                    "-c", "core.hooksPath=/dev/null",
                    "-c", "core.sshCommand=/usr/bin/false",
                    "-c", "credential.helper=",
                    "-c", "color.ui=false",
                    "-c", "color.diff=false",
                    "-c", "diff.relative=false",
                    "-c", "diff.ignoreSubmodules=all",
                    "-c", "diff.submodule=short",
                    "-c", "status.submoduleSummary=false",
                    "-c", "protocol.allow=never",
                    "-c", "protocol.file.allow=never",
                ] + args
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var procEnv = ProcessInfo.processInfo.environment
                for key in [
                    "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
                    "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_ATTR_SOURCE",
                    "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS",
                ] {
                    procEnv.removeValue(forKey: key)
                }
                for (key, value) in env {
                    procEnv[key] = value
                }
                procEnv["GIT_OPTIONAL_LOCKS"] = "0"
                procEnv["GIT_NO_LAZY_FETCH"] = "1"
                procEnv["GIT_ALLOW_PROTOCOL"] = ""
                p.environment = procEnv

                let outPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = FileHandle.nullDevice

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.setEventHandler {
                    if p.isRunning { p.terminate() }
                }

                do {
                    try p.run()
                    timer.schedule(deadline: .now() + timeout)
                    timer.resume()
                } catch {
                    timer.cancel()
                    try? outPipe.fileHandleForReading.close()
                    try? outPipe.fileHandleForWriting.close()
                    continuation.resume(returning: (-1, "", Data(), false))
                    return
                }

                // Register only after p.run() succeeds so Process.terminate() is never called on an unlaunched task.
                if let onProcessLaunch, !onProcessLaunch(p), p.isRunning {
                    p.terminate()
                }

                // Close parent copy of write end so reading hits EOF cleanly when git exits.
                try? outPipe.fileHandleForWriting.close()

                var outData = Data()
                var truncated = false
                let reader = outPipe.fileHandleForReading
                while true {
                    let chunk = (try? reader.read(upToCount: 64 * 1024)) ?? Data()
                    if chunk.isEmpty { break }
                    if outData.count < maxBytes {
                        let take = min(chunk.count, maxBytes - outData.count)
                        outData.append(chunk.prefix(take))
                        if chunk.count > take { truncated = true }
                    } else {
                        truncated = true
                    }
                }
                try? reader.close()
                p.waitUntilExit()
                timer.cancel()

                onProcessExit?(p)

                let str = String(decoding: outData, as: UTF8.self)
                continuation.resume(returning: (p.terminationStatus, str, outData, truncated))
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
