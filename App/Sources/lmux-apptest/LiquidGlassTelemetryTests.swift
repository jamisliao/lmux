// @feature: liquid-glass-app.feature
// @scenario: Git Diff 服務讀取工作區變更統計與檔案 hunks，非 Git 目錄呈現空狀態

import Foundation
import AppKit
@testable import LmuxUI

@MainActor
func runLiquidGlassTelemetry() async -> Int32 {
    let r = Report()
    r.section = "liquid-glass-telemetry"

    // 1. parseNumstat & parseUnifiedDiff
    let sampleNumstat = """
    10\t2\tSources/App.swift
    -\t-\tAssets/logo.png
    5\t0\tREADME.md
    """
    let numstatParsed = GitDiffService.parseNumstat(sampleNumstat)
    r.check("parseNumstat parses added/deleted and marks binary",
            numstatParsed.count == 3
            && numstatParsed[0].path == "Sources/App.swift" && numstatParsed[0].added == 10 && numstatParsed[0].deleted == 2 && !numstatParsed[0].isBinary
            && numstatParsed[1].path == "Assets/logo.png" && numstatParsed[1].isBinary
            && numstatParsed[2].path == "README.md" && numstatParsed[2].added == 5 && numstatParsed[2].deleted == 0)

    let sampleDiff = """
    diff --git a/README.md b/README.md
    index 1234567..89abcde 100644
    --- a/README.md
    +++ b/README.md
    @@ -1,3 +1,4 @@
     # Title
    +New Line 1
    +New Line 2
     End
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -10,3 +10,2 @@
     func run() {
    -    old()
    +    new()
     }
    """
    let filesDiff = GitDiffService.parseUnifiedDiff(sampleDiff, maxLines: 2)
    r.check("parseUnifiedDiff parses multiple files with maxLines truncation",
            filesDiff.count == 2
            && filesDiff[0].path == "README.md"
            && filesDiff[0].lines.count <= 2
            && filesDiff[0].truncated == true
            && filesDiff[1].path == "Sources/App.swift")

    // 2. Malicious git config diff.external test
    let fm = FileManager.default
    let pwnedPath = "/tmp/pwned_\(UUID().uuidString)"
    let repoA = fm.temporaryDirectory.appendingPathComponent("repo-a-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: repoA)
        try? fm.removeItem(atPath: pwnedPath)
    }
    try? fm.createDirectory(at: repoA, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "main"], env: ["GIT_DIR": repoA.appendingPathComponent(".git").path])
    // Configure malicious diff.external
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "config", "diff.external", "touch \(pwnedPath)"])
    let testFile = repoA.appendingPathComponent("test.txt")
    try? "hello\n".write(to: testFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "add", "test.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    try? "hello\nworld\n".write(to: testFile, atomically: true, encoding: .utf8)

    let svc = GitDiffService()
    svc.refresh(cwd: repoA.path, immediate: true)
    let refreshed = await waitFor(3) { !svc.isLoading && svc.snapshot.isGitRepo }
    r.check("refresh on git repo finishes without loading", refreshed)
    r.check("malicious diff.external is never executed", !fm.fileExists(atPath: pwnedPath))
    r.check("snapshot has correct branch and stats",
            svc.snapshot.isGitRepo
            && svc.snapshot.branch == "main"
            && svc.snapshot.totalAdded >= 1
            && svc.snapshot.files.contains(where: { $0.path == "test.txt" }))

    // 3. Unborn HEAD repository
    let unbornRepo = fm.temporaryDirectory.appendingPathComponent("unborn-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: unbornRepo) }
    try? fm.createDirectory(at: unbornRepo, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "feat/unborn"], env: ["GIT_DIR": unbornRepo.appendingPathComponent(".git").path])
    let unbornFile = unbornRepo.appendingPathComponent("README.md")
    try? "# Unborn\n".write(to: unbornFile, atomically: true, encoding: .utf8)

    svc.refresh(cwd: unbornRepo.path, immediate: true)
    _ = await waitFor(3) { !svc.isLoading && svc.snapshot.isGitRepo }
    r.check("unborn HEAD reports isGitRepo without crash and finds untracked/staged files",
            svc.snapshot.isGitRepo
            && svc.snapshot.branch == "feat/unborn"
            && !svc.snapshot.files.isEmpty)

    // 4. previewCandidates with README.md prioritization and unsafe scalar / symlink filtering
    let safeFile = unbornRepo.appendingPathComponent("sample.html")
    try? "<h1>hi</h1>".write(to: safeFile, atomically: true, encoding: .utf8)
    let symlinkToPasswd = unbornRepo.appendingPathComponent("passwd_link.txt")
    try? fm.createSymbolicLink(at: symlinkToPasswd, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))

    svc.refresh(cwd: unbornRepo.path, immediate: true)
    _ = await waitFor(3) { !svc.isLoading && !svc.snapshot.previewCandidates.isEmpty }
    let candidates = svc.snapshot.previewCandidates
    r.check("previewCandidates prioritizes README.md and excludes unsafe symlink outside repo",
            candidates.first?.lastPathComponent == "README.md"
            && !candidates.contains(where: { $0.lastPathComponent == "passwd_link.txt" }))

    // 5. Non-git directory and generation cancellation
    let nonGitDir = fm.temporaryDirectory.appendingPathComponent("nongit-\(UUID().uuidString)")
    let targetDir = fm.temporaryDirectory.appendingPathComponent("target-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: nonGitDir)
        try? fm.removeItem(at: targetDir)
    }
    try? fm.createDirectory(at: nonGitDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "target-branch"], env: ["GIT_DIR": targetDir.appendingPathComponent(".git").path])

    svc.refresh(cwd: nonGitDir.path, immediate: true)
    _ = await waitFor(3) { !svc.isLoading }
    r.check("non-git directory sets isGitRepo = false and empty files",
            !svc.snapshot.isGitRepo && svc.snapshot.files.isEmpty)

    // Rapid switch (cancellation)
    svc.refresh(cwd: nonGitDir.path)
    svc.refresh(cwd: targetDir.path, immediate: true)
    _ = await waitFor(3) { !svc.isLoading && svc.snapshot.cwd == targetDir.path }
    r.check("rapid directory switch keeps the final directory result",
            svc.snapshot.cwd == targetDir.path && svc.snapshot.isGitRepo && svc.snapshot.branch == "target-branch")

    print("\nRESULT: \(r.failed == 0 ? "PASS" : "FAIL") (\(r.passed)/\(r.passed + r.failed) checks passed)\n")
    return r.failed == 0 ? 0 : 1
}
