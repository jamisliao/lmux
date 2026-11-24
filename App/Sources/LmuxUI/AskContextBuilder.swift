import Foundation
import LmuxHooks
import LmuxTranscript

/// Assembles zero-token `AskSessionContext` from local transcript caches, recent tool calls, and pane-local git state.
enum AskContextBuilder {
    @MainActor
    static func build(
        for pane: Pane,
        transcripts: TranscriptCache,
        activeGitSnapshot: GitDiffSnapshot?
    ) async -> AskSessionContext {
        let paneID = pane.id
        let cwd = pane.cwd
        let transcriptPath = pane.transcriptPath
        let recentTools = formatRecentTools(Array(pane.agent.toolStream.entries.suffix(5)))

        var summary = TranscriptContextSummary()
        if let transcriptPath, !transcriptPath.isEmpty,
           let snap = await transcripts.snapshot(pane: paneID, path: transcriptPath, withCodexTitle: true) {
            let title = snap.customTitle ?? snap.aiTitle
            summary = TranscriptContextExtractor.extract(title: title, turns: snap.turns)
        }

        let (gitBranch, gitChangedCount) = await resolveGitSummary(
            cwd: cwd,
            activeGitSnapshot: activeGitSnapshot
        )

        return AskSessionContext(
            sessionTitle: summary.sessionTitle,
            initialGoal: summary.initialGoal,
            recentTurns: summary.recentTurns,
            touchedFiles: summary.touchedFiles,
            recentTools: recentTools,
            gitBranch: gitBranch,
            gitChangedCount: gitChangedCount
        )
    }

    private static func formatRecentTools(_ entries: [ToolCallEntry]) -> [String] {
        entries.map { entry in
            let name = PreviewTarget.replacingUnsafeScalars(entry.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let arg = entry.argument {
                let cleanArg = PreviewTarget.replacingUnsafeScalars(arg)
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanArg.isEmpty {
                    let text = "\(name): \(cleanArg)"
                    return String(text.prefix(80))
                }
            }
            return String(name.prefix(80))
        }.filter { !$0.isEmpty }
    }

    private nonisolated static func resolveGitSummary(
        cwd: String?,
        activeGitSnapshot: GitDiffSnapshot?
    ) async -> (branch: String?, changedCount: Int) {
        guard let cwd, !cwd.isEmpty else { return (nil, 0) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return (nil, 0)
        }

        if let activeGitSnapshot, activeGitSnapshot.cwd == cwd, activeGitSnapshot.isGitRepo {
            return (activeGitSnapshot.branch, activeGitSnapshot.files.count)
        }

        let topRes = await GitDiffService.runGitHardened(["rev-parse", "--show-toplevel"], cwd: cwd)
        let repoRoot = topRes.status == 0 ? topRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !repoRoot.isEmpty else { return (nil, 0) }

        var branch: String?
        if let local = GitBranch.readStatus(cwd: repoRoot) ?? GitBranch.readStatus(cwd: cwd) {
            if !local.isDetached {
                let clean = PreviewTarget.replacingUnsafeScalars(local.name).trimmingCharacters(in: .whitespacesAndNewlines)
                branch = clean.isEmpty ? nil : clean
            }
        }
        if branch == nil {
            let bRes = await GitDiffService.runGitHardened(["branch", "--show-current"], cwd: cwd)
            let bStr = PreviewTarget.replacingUnsafeScalars(bRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if !bStr.isEmpty {
                branch = bStr
            } else {
                let headRes = await GitDiffService.runGitHardened(["rev-parse", "--short", "HEAD"], cwd: cwd)
                let hStr = PreviewTarget.replacingUnsafeScalars(headRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                if !hStr.isEmpty { branch = "(detached: \(hStr))" }
            }
        }

        guard let filterEnv = await GitDiffService.buildFilterOverrideEnv(in: cwd),
              let emptyTree = await GitDiffService.emptyTreeHash(in: cwd) else {
            return (branch, 0)
        }
        var statusEnv = filterEnv
        statusEnv["GIT_ATTR_SOURCE"] = emptyTree
        let statusRes = await GitDiffService.runGitHardened(
            ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all"],
            env: statusEnv,
            cwd: cwd
        )
        let count = statusRes.status == 0 ? countStatusEntries(statusRes.stdout) : 0
        return (branch, count)
    }

    private nonisolated static func countStatusEntries(_ statusStdout: String) -> Int {
        let entries = statusStdout.split(separator: "\0", omittingEmptySubsequences: true)
        var count = 0
        var i = 0
        while i < entries.count {
            let s = entries[i]
            let code = s.count >= 2 ? String(s.prefix(2)) : ""
            let isRenameOrCopy = code.contains("R") || code.contains("C")
            if code != "!!" { count += 1 }
            i += isRenameOrCopy ? 2 : 1
        }
        return count
    }
}
