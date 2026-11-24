// @feature: liquid-glass-app.feature
// @scenario: Git Diff 服務讀取工作區變更統計與檔案 hunks，非 Git 目錄呈現空狀態
// @scenario: Hook 即時工具事件與終止事件更新即時 Tool Call 串流與狀態

import Darwin
import Foundation
import AppKit
import LmuxHooks
import LmuxTokens
import LmuxTranscript
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

    let renameNumstatZ = "4\t1\t\0Sources/OldName.swift\0Sources/NewName.swift\0" + "2\t0\tDocs/設計.md\0"
    let renameParsed = GitDiffService.parseNumstat(renameNumstatZ)
    r.check("parseNumstat -z resolves renames and UTF-8 paths without quote escaping",
            renameParsed.count == 2
            && renameParsed[0].path == "Sources/NewName.swift" && renameParsed[0].added == 4 && renameParsed[0].deleted == 1
            && renameParsed[1].path == "Docs/設計.md" && renameParsed[1].added == 2)

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
    diff --git a/my notes.md b/my notes.md
    index 1111111..2222222 100644
    --- a/my notes.md
    +++ b/my notes.md
    @@ -10,3 +10,2 @@
     old line
    -    old()
    +    new()
     end
    """
    let filesDiff = GitDiffService.parseUnifiedDiff(sampleDiff, maxLines: 2)
    r.check("parseUnifiedDiff parses multiple files including spaces with maxLines truncation",
            filesDiff.count == 2
            && filesDiff[0].path == "README.md"
            && filesDiff[0].lines.count <= 2
            && filesDiff[0].truncated == true
            && filesDiff[1].path == "my notes.md")

    // non-z parseNumstat renames ({old => new} and old => new)
    let plainRenameNumstat = "3\t1\tApp/{Old => New}/View.swift\n2\t0\tlegacy.txt => current.txt\n"
    let plainRenames = GitDiffService.parseNumstat(plainRenameNumstat)
    r.check("parseNumstat resolves non-z rename formats",
            plainRenames.count == 2
            && plainRenames[0].path == "App/New/View.swift" && plainRenames[0].added == 3 && plainRenames[0].deleted == 1
            && plainRenames[1].path == "current.txt" && plainRenames[1].added == 2)

    // parseUnifiedDiff A/D/R statuses, asymmetric rename header, and exact maxLines == count vs +1 boundary
    let adrDiff = """
    diff --git a/added.swift b/added.swift
    new file mode 100644
    --- /dev/null
    +++ b/added.swift
    @@ -0,0 +1,2 @@
    +a
    +b
    diff --git a/deleted.swift b/deleted.swift
    deleted file mode 100644
    --- a/deleted.swift
    +++ /dev/null
    @@ -1,1 +0,0 @@
    -gone
    diff --git a/old_name.swift b/renamed_dir/new_name.swift
    similarity index 90%
    rename from old_name.swift
    rename to renamed_dir/new_name.swift
    --- a/old_name.swift
    +++ b/renamed_dir/new_name.swift
    @@ -1 +1 @@
    -old
    +new
    """
    let exactBoundaryParsed = GitDiffService.parseUnifiedDiff(adrDiff, maxLines: 3)
    let tighterBoundaryParsed = GitDiffService.parseUnifiedDiff(adrDiff, maxLines: 2)
    r.check("parseUnifiedDiff handles A/D/R statuses and exact maxLines == count vs +1 truncation",
            exactBoundaryParsed.count == 3
            && exactBoundaryParsed[0].path == "added.swift" && exactBoundaryParsed[0].status == "A"
            && exactBoundaryParsed[0].lines.count == 3 && !exactBoundaryParsed[0].truncated
            && exactBoundaryParsed[1].path == "deleted.swift" && exactBoundaryParsed[1].status == "D"
            && exactBoundaryParsed[1].lines.count == 2 && !exactBoundaryParsed[1].truncated
            && exactBoundaryParsed[2].path == "renamed_dir/new_name.swift" && exactBoundaryParsed[2].status == "R"
            && exactBoundaryParsed[2].lines.count == 3 && !exactBoundaryParsed[2].truncated
            && tighterBoundaryParsed[0].lines.count == 2 && tighterBoundaryParsed[0].truncated == true)

    // parseUnifiedDiff preserves ---/+++ hunk lines and does not corrupt deleted file path on --- a/... content
    let headerLikeHunkDiff = """
    diff --git a/docs/frontmatter.yaml b/docs/frontmatter.yaml
    deleted file mode 100644
    --- a/docs/frontmatter.yaml
    +++ /dev/null
    @@ -1,4 +0,0 @@
    ----
    --- a/fake/path.yaml
    --- sql comment
    -title: old
    diff --git a/src/counter.c b/src/counter.c
    index 1111111..2222222 100644
    --- a/src/counter.c
    +++ b/src/counter.c
    @@ -1,2 +1,2 @@
    ---x;
    +++y;
     return;
    """
    let headerLikeParsed = GitDiffService.parseUnifiedDiff(headerLikeHunkDiff)
    r.check("parseUnifiedDiff preserves ---/+++ hunk lines and deleted path when hunk contains --- a/...",
            headerLikeParsed.count == 2
            && headerLikeParsed[0].path == "docs/frontmatter.yaml"
            && headerLikeParsed[0].status == "D"
            && headerLikeParsed[0].deleted == 4
            && headerLikeParsed[0].lines.count == 5
            && headerLikeParsed[0].lines[2].text == "--- a/fake/path.yaml"
            && headerLikeParsed[1].path == "src/counter.c"
            && headerLikeParsed[1].deleted == 1 && headerLikeParsed[1].added == 1
            && headerLikeParsed[1].lines[1].text == "---x;"
            && headerLikeParsed[1].lines[2].text == "+++y;")

    // 2. Malicious git config diff.external + core.fsmonitor test
    let fm = FileManager.default
    let pwnedPath = "/tmp/pwned_\(UUID().uuidString)"
    let pwnedFsMonitorPath = "/tmp/pwned_fsmonitor_\(UUID().uuidString)"
    let pwnedFilterPath = "/tmp/pwned_filter_\(UUID().uuidString)"
    let repoA = fm.temporaryDirectory.appendingPathComponent("repo-a-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: repoA)
        try? fm.removeItem(atPath: pwnedPath)
        try? fm.removeItem(atPath: pwnedFsMonitorPath)
        try? fm.removeItem(atPath: pwnedFilterPath)
    }
    try? fm.createDirectory(at: repoA, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "main"], env: ["GIT_DIR": repoA.appendingPathComponent(".git").path])
    let testFile = repoA.appendingPathComponent("test.txt")
    let attrsFile = repoA.appendingPathComponent(".gitattributes")
    try? "*.txt filter=evil\n".write(to: attrsFile, atomically: true, encoding: .utf8)
    try? "line1\nline2\n".write(to: testFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "add", "test.txt", ".gitattributes"])
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    // Configure malicious diff.external, core.fsmonitor, and filter.evil.* after commit setup so only GitDiffService is tested.
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "config", "diff.external", "touch \(pwnedPath)"])
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "config", "core.fsmonitor", "touch \(pwnedFsMonitorPath)"])
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "config", "filter.evil.clean", "touch \(pwnedFilterPath) && cat"])
    _ = await runProcess("/usr/bin/git", ["-C", repoA.path, "config", "filter.evil.smudge", "touch \(pwnedFilterPath) && cat"])
    try? "line1\nline2-edited\nline3\n".write(to: testFile, atomically: true, encoding: .utf8)

    let svc = GitDiffService()
    svc.refresh(cwd: repoA.path, immediate: true)
    let refreshed = await waitFor(8) { !svc.isLoading && svc.snapshot.isGitRepo }
    let testDiff = svc.snapshot.files.first(where: { $0.path == "test.txt" })
    r.check("refresh on git repo finishes without loading", refreshed)
    r.check("malicious diff.external, core.fsmonitor, and filter.*.clean are never executed",
            !fm.fileExists(atPath: pwnedPath) && !fm.fileExists(atPath: pwnedFsMonitorPath) && !fm.fileExists(atPath: pwnedFilterPath))
    r.check("snapshot has real unified diff hunks, exact added/deleted counts, and branch",
            svc.snapshot.isGitRepo
            && svc.snapshot.branch == "main"
            && svc.snapshot.totalAdded == 2
            && svc.snapshot.totalDeleted == 1
            && (testDiff?.lines.contains(where: { $0.kind == .hunkHeader && $0.text.hasPrefix("@@") }) == true),
            "added=\(svc.snapshot.totalAdded) deleted=\(svc.snapshot.totalDeleted) lines=\(testDiff?.lines.count ?? 0)")

    // 2b. Subdirectory Git cwd resolves repoRoot (--show-toplevel) for untracked files & previewURL
    let subDir = repoA.appendingPathComponent("nested/sub")
    try? fm.createDirectory(at: subDir, withIntermediateDirectories: true)
    let subNote = subDir.appendingPathComponent("sub-note.md")
    try? "# Nested\nline2\n".write(to: subNote, atomically: true, encoding: .utf8)
    svc.refresh(cwd: subDir.path, immediate: true)
    let subRefreshed = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == subDir.path }
    let subFileEntry = svc.snapshot.files.first(where: { $0.path == "nested/sub/sub-note.md" })
    let subResolved = InspectorDiffView.resolvePreviewURL(file: "nested/sub/sub-note.md", cwd: svc.snapshot.repoRoot ?? svc.snapshot.cwd)
    r.check("subdirectory cwd resolves repoRoot for untracked diff lines and previewURL",
            subRefreshed
            && svc.snapshot.repoRoot != nil
            && subFileEntry?.added == 2
            && subFileEntry?.previewURL != nil
            && subResolved?.resolvingSymlinksInPath() == subNote.resolvingSymlinksInPath(),
            "refreshed=\(subRefreshed) root=\(svc.snapshot.repoRoot ?? "nil") added=\(subFileEntry?.added ?? -1) url=\(subFileEntry?.previewURL?.path ?? "nil")")

    // 2c. A git without --attr-source also ignores GIT_ATTR_SOURCE: diff still works and repo filters stay disabled.
    let oldGit = fm.temporaryDirectory.appendingPathComponent("old-git-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: oldGit) }
    try? """
    #!/bin/sh
    for a in "$@"; do case "$a" in --attr-source*) echo "unknown option: $a" >&2; exit 129;; esac; done
    unset GIT_ATTR_SOURCE
    exec /usr/bin/git "$@"
    """.write(to: oldGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldGit.path)
    let oldGitSvc = GitDiffService(gitPath: oldGit.path)
    oldGitSvc.refresh(cwd: repoA.path, immediate: true)
    _ = await waitFor(8) { !oldGitSvc.isLoading && oldGitSvc.snapshot.isGitRepo }
    let oldGitEntry = oldGitSvc.snapshot.files.first(where: { $0.path == "test.txt" })
    r.check("git without --attr-source support still reports diff and never runs repo filters",
            oldGitEntry?.added == 2 && oldGitEntry?.deleted == 1 && !fm.fileExists(atPath: pwnedFilterPath),
            "added=\(oldGitEntry?.added ?? -1) deleted=\(oldGitEntry?.deleted ?? -1)")

    // 2d. SHA-256 repository: the attribute source must be that repo's own empty tree, not the SHA-1 constant.
    let sha256Repo = fm.temporaryDirectory.appendingPathComponent("sha256-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: sha256Repo) }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", "--object-format=sha256", sha256Repo.path])
    let sha256File = sha256Repo.appendingPathComponent("f.txt")
    try? "a\n".write(to: sha256File, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", sha256Repo.path, "add", "f.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", sha256Repo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    try? "a\nb\n".write(to: sha256File, atomically: true, encoding: .utf8)
    svc.refresh(cwd: sha256Repo.path, immediate: true)
    _ = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == sha256Repo.path }
    let sha256Entry = svc.snapshot.files.first(where: { $0.path == "f.txt" })
    r.check("SHA-256 repository reports diff counts",
            sha256Entry?.added == 1 && sha256Entry?.deleted == 0,
            "added=\(sha256Entry?.added ?? -1) deleted=\(sha256Entry?.deleted ?? -1)")

    // 2e. extensions.worktreeConfig + .git/info/attributes + [filter "a=b"] + filter.*.process/required never execute filter RCE
    let wtRepo = fm.temporaryDirectory.appendingPathComponent("wt-rce-\(UUID().uuidString)")
    let pwnedWtPath = "/tmp/pwned_wt_\(UUID().uuidString)"
    let pwnedEqPath = "/tmp/pwned_eq_\(UUID().uuidString)"
    let pwnedProcPath = "/tmp/pwned_proc_\(UUID().uuidString)"
    defer {
        try? fm.removeItem(at: wtRepo)
        try? fm.removeItem(atPath: pwnedWtPath)
        try? fm.removeItem(atPath: pwnedEqPath)
        try? fm.removeItem(atPath: pwnedProcPath)
    }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", wtRepo.path])
    let wtFile = wtRepo.appendingPathComponent("wt.txt")
    let eqFile = wtRepo.appendingPathComponent("eq.cfg")
    let procFile = wtRepo.appendingPathComponent("proc.dat")
    try? "wt1\n".write(to: wtFile, atomically: true, encoding: .utf8)
    try? "eq1\n".write(to: eqFile, atomically: true, encoding: .utf8)
    try? "p1\n".write(to: procFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", wtRepo.path, "add", "wt.txt", "eq.cfg", "proc.dat"])
    _ = await runProcess("/usr/bin/git", ["-C", wtRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    _ = await runProcess("/usr/bin/git", ["-C", wtRepo.path, "config", "core.repositoryformatversion", "1"])
    _ = await runProcess("/usr/bin/git", ["-C", wtRepo.path, "config", "extensions.worktreeConfig", "true"])
    _ = await runProcess("/usr/bin/git", ["-C", wtRepo.path, "config", "--worktree", "filter.wt.clean", "touch \(pwnedWtPath) && cat"])
    _ = await runProcess("/usr/bin/git", ["-C", wtRepo.path, "config", "filter.a=b.clean", "touch \(pwnedEqPath) && cat"])
    _ = await runProcess("/usr/bin/git", ["-C", wtRepo.path, "config", "filter.procreq.process", "touch \(pwnedProcPath) && cat"])
    _ = await runProcess("/usr/bin/git", ["-C", wtRepo.path, "config", "filter.procreq.required", "true"])
    let infoDir = wtRepo.appendingPathComponent(".git/info")
    try? fm.createDirectory(at: infoDir, withIntermediateDirectories: true)
    try? "*.txt filter=wt\n*.cfg filter=a=b\n*.dat filter=procreq\n".write(to: infoDir.appendingPathComponent("attributes"), atomically: true, encoding: .utf8)
    try? "wt1\nwt2\n".write(to: wtFile, atomically: true, encoding: .utf8)
    try? "eq1\neq2\n".write(to: eqFile, atomically: true, encoding: .utf8)
    try? "p1\np2\n".write(to: procFile, atomically: true, encoding: .utf8)
    svc.refresh(cwd: wtRepo.path, immediate: true)
    _ = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == wtRepo.path }
    r.check("worktreeConfig + info/attributes + '=' filter subsection + process/required never execute filter commands",
            svc.snapshot.isGitRepo
            && svc.snapshot.files.contains(where: { $0.path == "wt.txt" && $0.added == 1 })
            && svc.snapshot.files.contains(where: { $0.path == "eq.cfg" && $0.added == 1 })
            && svc.snapshot.files.contains(where: { $0.path == "proc.dat" && $0.added == 1 })
            && !fm.fileExists(atPath: pwnedWtPath)
            && !fm.fileExists(atPath: pwnedEqPath)
            && !fm.fileExists(atPath: pwnedProcPath),
            "files=\(svc.snapshot.files.map(\.path)) wt=\(fm.fileExists(atPath: pwnedWtPath)) eq=\(fm.fileExists(atPath: pwnedEqPath)) proc=\(fm.fileExists(atPath: pwnedProcPath))")

    // 2f. Dirty submodule with malicious filter config is ignored (--ignore-submodules=all)
    let subSrc = fm.temporaryDirectory.appendingPathComponent("sub-src-\(UUID().uuidString)")
    let parentSubRepo = fm.temporaryDirectory.appendingPathComponent("sub-parent-\(UUID().uuidString)")
    let pwnedSubPath = "/tmp/pwned_sub_\(UUID().uuidString)"
    defer {
        try? fm.removeItem(at: subSrc)
        try? fm.removeItem(at: parentSubRepo)
        try? fm.removeItem(atPath: pwnedSubPath)
    }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", subSrc.path])
    try? "s1\n".write(to: subSrc.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
    try? "*.txt filter=subevil\n".write(to: subSrc.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", subSrc.path, "add", "s.txt", ".gitattributes"])
    _ = await runProcess("/usr/bin/git", ["-C", subSrc.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "sub"])
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", parentSubRepo.path])
    try? "p1\n".write(to: parentSubRepo.appendingPathComponent("host.txt"), atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", parentSubRepo.path, "add", "host.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", parentSubRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    _ = await runProcess("/usr/bin/git", ["-C", parentSubRepo.path, "-c", "protocol.file.allow=always", "submodule", "add", subSrc.path, "vendor/sub"])
    _ = await runProcess("/usr/bin/git", ["-C", parentSubRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "add sub"])
    _ = await runProcess("/usr/bin/git", ["-C", parentSubRepo.appendingPathComponent("vendor/sub").path, "config", "filter.subevil.clean", "touch \(pwnedSubPath) && cat"])
    try? "s1\ns2\n".write(to: parentSubRepo.appendingPathComponent("vendor/sub/s.txt"), atomically: true, encoding: .utf8)
    try? "p1\np2\n".write(to: parentSubRepo.appendingPathComponent("host.txt"), atomically: true, encoding: .utf8)
    svc.refresh(cwd: parentSubRepo.path, immediate: true)
    _ = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == parentSubRepo.path }
    r.check("dirty submodule with filter.subevil.clean is skipped without running filter",
            svc.snapshot.isGitRepo
            && svc.snapshot.files.contains(where: { $0.path == "host.txt" && $0.added == 1 })
            && !fm.fileExists(atPath: pwnedSubPath),
            "files=\(svc.snapshot.files.map(\.path)) pwnedSub=\(fm.fileExists(atPath: pwnedSubPath))")

    // 2g. git config lookup error (status > 1) and status failure fail closed without false clean state or running diff/status
    let failClosedGit = fm.temporaryDirectory.appendingPathComponent("failclosed-git-\(UUID().uuidString)")
    let diffRanMarker = "/tmp/diff_ran_\(UUID().uuidString)"
    defer {
        try? fm.removeItem(at: failClosedGit)
        try? fm.removeItem(atPath: diffRanMarker)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config) exit 2 ;;
        diff|status) touch "\(diffRanMarker)"; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: failClosedGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failClosedGit.path)
    let failClosedSvc = GitDiffService(gitPath: failClosedGit.path)
    failClosedSvc.refresh(cwd: repoA.path, immediate: true)
    let failClosedDone = await waitFor(8) { !failClosedSvc.isLoading }
    r.check("git config failure fails closed without invoking diff/status or falsely reporting clean repo",
            failClosedDone && !failClosedSvc.snapshot.isGitRepo && !fm.fileExists(atPath: diffRanMarker),
            "done=\(failClosedDone) isGitRepo=\(failClosedSvc.snapshot.isGitRepo) diffRan=\(fm.fileExists(atPath: diffRanMarker))")

    let failStatusGit = fm.temporaryDirectory.appendingPathComponent("failstatus-git-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: failStatusGit) }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        status) exit 129 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: failStatusGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failStatusGit.path)
    let failStatusSvc = GitDiffService(gitPath: failStatusGit.path)
    failStatusSvc.refresh(cwd: repoA.path, immediate: true)
    let failStatusDone = await waitFor(8) { !failStatusSvc.isLoading }
    r.check("git status failure fails closed without falsely reporting clean repo",
            failStatusDone && !failStatusSvc.snapshot.isGitRepo,
            "done=\(failStatusDone) isGitRepo=\(failStatusSvc.snapshot.isGitRepo)")

    // 2h. Malformed newline filter key, hash-object failure, truncated >2MB config, non-UTF-8 filter keys, and superseded filterOverrideEnv abort fail safely
    let malformedConfigGit = fm.temporaryDirectory.appendingPathComponent("malformed-cfg-\(UUID().uuidString)")
    let malformedDiffRan = fm.temporaryDirectory.appendingPathComponent("malformed-diff-ran-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: malformedConfigGit)
        try? fm.removeItem(at: malformedDiffRan)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config) printf 'filter.bad\\nkey.clean\\0'; exit 0 ;;
        diff|status) touch '\(malformedDiffRan.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: malformedConfigGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: malformedConfigGit.path)
    let malformedSvc = GitDiffService(gitPath: malformedConfigGit.path)
    malformedSvc.refresh(cwd: repoA.path, immediate: true)
    let malformedDone = await waitFor(8) { !malformedSvc.isLoading }
    r.check("malformed newline filter key fails closed in filterOverrideEnv without running diff",
            malformedDone && !malformedSvc.snapshot.isGitRepo && !fm.fileExists(atPath: malformedDiffRan.path))

    let failHashObjGit = fm.temporaryDirectory.appendingPathComponent("failhash-git-\(UUID().uuidString)")
    let hashDiffRan = fm.temporaryDirectory.appendingPathComponent("hash-diff-ran-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: failHashObjGit)
        try? fm.removeItem(at: hashDiffRan)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        hash-object) exit 1 ;;
        diff|status) touch '\(hashDiffRan.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: failHashObjGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failHashObjGit.path)
    let failHashSvc = GitDiffService(gitPath: failHashObjGit.path)
    failHashSvc.refresh(cwd: repoA.path, immediate: true)
    let failHashDone = await waitFor(8) { !failHashSvc.isLoading }
    r.check("hash-object failure fails closed instead of running diff without GIT_ATTR_SOURCE",
            failHashDone && !failHashSvc.snapshot.isGitRepo && !fm.fileExists(atPath: hashDiffRan.path))

    let truncConfigGit = fm.temporaryDirectory.appendingPathComponent("trunc-cfg-\(UUID().uuidString)")
    let truncDiffRan = fm.temporaryDirectory.appendingPathComponent("trunc-diff-ran-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: truncConfigGit)
        try? fm.removeItem(at: truncDiffRan)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config)
          awk 'BEGIN { for (i = 0; i < 131073; i++) printf "filter.bg.clean%c", 0 }'
          exit 0
          ;;
        diff|status) touch '\(truncDiffRan.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: truncConfigGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: truncConfigGit.path)
    let truncSvc = GitDiffService(gitPath: truncConfigGit.path)
    truncSvc.refresh(cwd: repoA.path, immediate: true)
    let truncDone = await waitFor(8) { !truncSvc.isLoading }
    r.check("truncated >2MB filter config output fails closed in filterOverrideEnv without running diff",
            truncDone && !truncSvc.snapshot.isGitRepo && !fm.fileExists(atPath: truncDiffRan.path))

    let nonUtf8ConfigGit = fm.temporaryDirectory.appendingPathComponent("nonutf8-cfg-\(UUID().uuidString)")
    let nonUtf8DiffRan = fm.temporaryDirectory.appendingPathComponent("nonutf8-diff-ran-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: nonUtf8ConfigGit)
        try? fm.removeItem(at: nonUtf8DiffRan)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config)
          LC_ALL=C awk 'BEGIN { printf "filter.%c.clean%c", 255, 0 }'
          exit 0
          ;;
        diff|status) touch '\(nonUtf8DiffRan.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: nonUtf8ConfigGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nonUtf8ConfigGit.path)
    let nonUtf8Svc = GitDiffService(gitPath: nonUtf8ConfigGit.path)
    nonUtf8Svc.refresh(cwd: repoA.path, immediate: true)
    let nonUtf8Done = await waitFor(8) { !nonUtf8Svc.isLoading }
    r.check("non-UTF-8 filter key fails closed in filterOverrideEnv without running diff",
            nonUtf8Done && !nonUtf8Svc.snapshot.isGitRepo && !fm.fileExists(atPath: nonUtf8DiffRan.path))

    let nonUtf8Repo = fm.temporaryDirectory.appendingPathComponent("nonutf8-rce-\(UUID().uuidString)")
    let nonUtf8PwnedPath = "/tmp/pwned_nonutf8_\(UUID().uuidString)"
    defer {
        try? fm.removeItem(at: nonUtf8Repo)
        try? fm.removeItem(atPath: nonUtf8PwnedPath)
    }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", nonUtf8Repo.path])
    let cleanTxtFile = nonUtf8Repo.appendingPathComponent("clean.txt")
    try? "c1\n".write(to: cleanTxtFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", nonUtf8Repo.path, "add", "clean.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", nonUtf8Repo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    let nonUtf8CfgURL = nonUtf8Repo.appendingPathComponent(".git/config")
    if var cfgData = try? Data(contentsOf: nonUtf8CfgURL) {
        cfgData.append(contentsOf: "\n[filter \"".utf8)
        cfgData.append(0xFF)
        cfgData.append(contentsOf: "\"]\n\tclean = touch '\(nonUtf8PwnedPath)' && cat\n".utf8)
        try? cfgData.write(to: nonUtf8CfgURL, options: .atomic)
    }
    let nonUtf8InfoDir = nonUtf8Repo.appendingPathComponent(".git/info")
    try? fm.createDirectory(at: nonUtf8InfoDir, withIntermediateDirectories: true)
    var nonUtf8AttrData = Data("*.txt filter=".utf8)
    nonUtf8AttrData.append(0xFF)
    nonUtf8AttrData.append(0x0A)
    try? nonUtf8AttrData.write(to: nonUtf8InfoDir.appendingPathComponent("attributes"), options: .atomic)
    try? "c1\nc2\n".write(to: cleanTxtFile, atomically: true, encoding: .utf8)
    let nonUtf8RepoSvc = GitDiffService()
    nonUtf8RepoSvc.refresh(cwd: nonUtf8Repo.path, immediate: true)
    let nonUtf8RepoDone = await waitFor(8) { !nonUtf8RepoSvc.isLoading }
    r.check("real repo with non-UTF-8 filter subsection fails closed without executing filter RCE",
            nonUtf8RepoDone && !nonUtf8RepoSvc.snapshot.isGitRepo && !fm.fileExists(atPath: nonUtf8PwnedPath),
            "isGitRepo=\(nonUtf8RepoSvc.snapshot.isGitRepo) pwned=\(fm.fileExists(atPath: nonUtf8PwnedPath))")

    let benignNonUtf8Repo = fm.temporaryDirectory.appendingPathComponent("benign-nonutf8-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: benignNonUtf8Repo) }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", benignNonUtf8Repo.path])
    let okTxtFile = benignNonUtf8Repo.appendingPathComponent("ok.txt")
    try? "o1\n".write(to: okTxtFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", benignNonUtf8Repo.path, "add", "ok.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", benignNonUtf8Repo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    let benignCfgURL = benignNonUtf8Repo.appendingPathComponent(".git/config")
    if var benignCfgData = try? Data(contentsOf: benignCfgURL) {
        benignCfgData.append(contentsOf: "\n[user]\n\tname = ".utf8)
        benignCfgData.append(0xFF)
        benignCfgData.append(contentsOf: "bad\n[remote \"orig".utf8)
        benignCfgData.append(0xFF)
        benignCfgData.append(contentsOf: "\"]\n\turl = https://example.com\n[remote \"caf\u{00E9}\"]\n\turl = https://example.com/caf\n".utf8)
        try? benignCfgData.write(to: benignCfgURL, options: .atomic)
    }
    try? "o1\no2\n".write(to: okTxtFile, atomically: true, encoding: .utf8)
    let benignSvc = GitDiffService()
    benignSvc.refresh(cwd: benignNonUtf8Repo.path, immediate: true)
    let benignDone = await waitFor(8) { !benignSvc.isLoading }
    r.check("real repo with non-UTF-8 non-filter config key and value still loads cleanly",
            benignDone
            && benignSvc.snapshot.isGitRepo
            && benignSvc.snapshot.files.contains(where: { $0.path == "ok.txt" && $0.added == 1 }),
            "isGitRepo=\(benignSvc.snapshot.isGitRepo) files=\(benignSvc.snapshot.files.map(\.path))")

    let crlfConfigGit = fm.temporaryDirectory.appendingPathComponent("crlf-cfg-\(UUID().uuidString)")
    let crlfDiffRan = fm.temporaryDirectory.appendingPathComponent("crlf-diff-ran-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: crlfConfigGit)
        try? fm.removeItem(at: crlfDiffRan)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config) printf 'filter.bad\\r\\nkey.clean\\0'; exit 0 ;;
        diff|status) touch '\(crlfDiffRan.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: crlfConfigGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crlfConfigGit.path)
    let crlfSvc = GitDiffService(gitPath: crlfConfigGit.path)
    crlfSvc.refresh(cwd: repoA.path, immediate: true)
    let crlfDone = await waitFor(8) { !crlfSvc.isLoading }
    r.check("CRLF inside filter key fails closed in filterOverrideEnv without running diff",
            crlfDone && !crlfSvc.snapshot.isGitRepo && !fm.fileExists(atPath: crlfDiffRan.path))

    let nfcNfdConfigGit = fm.temporaryDirectory.appendingPathComponent("nfcnfd-cfg-\(UUID().uuidString)")
    let nfcNfdDiffRan = fm.temporaryDirectory.appendingPathComponent("nfcnfd-diff-ran-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: nfcNfdConfigGit)
        try? fm.removeItem(at: nfcNfdDiffRan)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config)
          LC_ALL=C awk 'BEGIN { printf "filter.caf%c%c.clean%cfilter.cafe%c%c.clean%c", 195, 169, 0, 204, 129, 0 }'
          exit 0
          ;;
        diff|status) touch '\(nfcNfdDiffRan.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: nfcNfdConfigGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nfcNfdConfigGit.path)
    let nfcNfdMockSvc = GitDiffService(gitPath: nfcNfdConfigGit.path)
    nfcNfdMockSvc.refresh(cwd: repoA.path, immediate: true)
    let nfcNfdMockDone = await waitFor(8) { !nfcNfdMockSvc.isLoading }
    r.check("non-ASCII UTF-8 NFC/NFD filter keys fail closed without running diff with mangled env",
            nfcNfdMockDone && !nfcNfdMockSvc.snapshot.isGitRepo && !fm.fileExists(atPath: nfcNfdDiffRan.path))

    let nfcNfdRepo = fm.temporaryDirectory.appendingPathComponent("nfcnfd-rce-\(UUID().uuidString)")
    let pwnedNfcPath = "/tmp/pwned_nfc_\(UUID().uuidString)"
    let pwnedNfdPath = "/tmp/pwned_nfd_\(UUID().uuidString)"
    defer {
        try? fm.removeItem(at: nfcNfdRepo)
        try? fm.removeItem(atPath: pwnedNfcPath)
        try? fm.removeItem(atPath: pwnedNfdPath)
    }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", nfcNfdRepo.path])
    let nfcTxtFile = nfcNfdRepo.appendingPathComponent("nfc.txt")
    let nfdTxtFile = nfcNfdRepo.appendingPathComponent("nfd.txt")
    try? "n1\n".write(to: nfcTxtFile, atomically: true, encoding: .utf8)
    try? "d1\n".write(to: nfdTxtFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", nfcNfdRepo.path, "add", "nfc.txt", "nfd.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", nfcNfdRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    let nfcNfdCfgURL = nfcNfdRepo.appendingPathComponent(".git/config")
    if var cfgData = try? Data(contentsOf: nfcNfdCfgURL) {
        cfgData.append(contentsOf: "\n[filter \"caf\u{00E9}\"]\n\tclean = touch '\(pwnedNfcPath)' && cat\n".utf8)
        cfgData.append(contentsOf: "[filter \"cafe\u{0301}\"]\n\tclean = touch '\(pwnedNfdPath)' && cat\n".utf8)
        try? cfgData.write(to: nfcNfdCfgURL, options: .atomic)
    }
    let nfcNfdInfoDir = nfcNfdRepo.appendingPathComponent(".git/info")
    try? fm.createDirectory(at: nfcNfdInfoDir, withIntermediateDirectories: true)
    let nfcNfdAttr = "nfc.txt filter=caf\u{00E9}\nnfd.txt filter=cafe\u{0301}\n"
    try? Data(nfcNfdAttr.utf8).write(to: nfcNfdInfoDir.appendingPathComponent("attributes"), options: .atomic)
    try? "n1\nn2\n".write(to: nfcTxtFile, atomically: true, encoding: .utf8)
    try? "d1\nd2\n".write(to: nfdTxtFile, atomically: true, encoding: .utf8)
    let nfcNfdRepoSvc = GitDiffService()
    nfcNfdRepoSvc.refresh(cwd: nfcNfdRepo.path, immediate: true)
    let nfcNfdRepoDone = await waitFor(8) { !nfcNfdRepoSvc.isLoading }
    r.check("real repo with NFC and NFD filter subsections fails closed without executing filter RCE",
            nfcNfdRepoDone
            && !nfcNfdRepoSvc.snapshot.isGitRepo
            && !fm.fileExists(atPath: pwnedNfcPath)
            && !fm.fileExists(atPath: pwnedNfdPath),
            "isGitRepo=\(nfcNfdRepoSvc.snapshot.isGitRepo) nfc=\(fm.fileExists(atPath: pwnedNfcPath)) nfd=\(fm.fileExists(atPath: pwnedNfdPath))")

    let caseFilterRepo = fm.temporaryDirectory.appendingPathComponent("case-filter-\(UUID().uuidString)")
    let pwnedUpperPath = "/tmp/pwned_upper_\(UUID().uuidString)"
    let pwnedLowerPath = "/tmp/pwned_lower_\(UUID().uuidString)"
    defer {
        try? fm.removeItem(at: caseFilterRepo)
        try? fm.removeItem(atPath: pwnedUpperPath)
        try? fm.removeItem(atPath: pwnedLowerPath)
    }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", caseFilterRepo.path])
    let upperFile = caseFilterRepo.appendingPathComponent("u.txt")
    let lowerFile = caseFilterRepo.appendingPathComponent("l.txt")
    try? "u1\n".write(to: upperFile, atomically: true, encoding: .utf8)
    try? "l1\n".write(to: lowerFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", caseFilterRepo.path, "add", "u.txt", "l.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", caseFilterRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    _ = await runProcess("/usr/bin/git", ["-C", caseFilterRepo.path, "config", "filter.CaseMix.clean", "touch '\(pwnedUpperPath)' && cat"])
    _ = await runProcess("/usr/bin/git", ["-C", caseFilterRepo.path, "config", "filter.casemix.clean", "touch '\(pwnedLowerPath)' && cat"])
    let caseInfoDir = caseFilterRepo.appendingPathComponent(".git/info")
    try? fm.createDirectory(at: caseInfoDir, withIntermediateDirectories: true)
    try? "u.txt filter=CaseMix\nl.txt filter=casemix\n".write(to: caseInfoDir.appendingPathComponent("attributes"), atomically: true, encoding: .utf8)
    try? "u1\nu2\n".write(to: upperFile, atomically: true, encoding: .utf8)
    try? "l1\nl2\n".write(to: lowerFile, atomically: true, encoding: .utf8)
    let caseSvc = GitDiffService()
    caseSvc.refresh(cwd: caseFilterRepo.path, immediate: true)
    let caseDone = await waitFor(8) { !caseSvc.isLoading }
    r.check("real repo with case-distinct ASCII filter subsections neutralizes both without RCE",
            caseDone
            && caseSvc.snapshot.isGitRepo
            && caseSvc.snapshot.files.contains(where: { $0.path == "u.txt" && $0.added == 1 })
            && caseSvc.snapshot.files.contains(where: { $0.path == "l.txt" && $0.added == 1 })
            && !fm.fileExists(atPath: pwnedUpperPath)
            && !fm.fileExists(atPath: pwnedLowerPath),
            "files=\(caseSvc.snapshot.files.map(\.path)) upper=\(fm.fileExists(atPath: pwnedUpperPath)) lower=\(fm.fileExists(atPath: pwnedLowerPath))")

    let slowConfigGit = fm.temporaryDirectory.appendingPathComponent("slowcfg-git-\(UUID().uuidString)")
    let slowStarted = fm.temporaryDirectory.appendingPathComponent("slowcfg-start-\(UUID().uuidString)")
    let slowRelease = fm.temporaryDirectory.appendingPathComponent("slowcfg-rel-\(UUID().uuidString)")
    let slowPidFile = fm.temporaryDirectory.appendingPathComponent("slowcfg-pid-\(UUID().uuidString)")
    defer {
        try? Data().write(to: slowRelease)
        try? fm.removeItem(at: slowConfigGit)
        try? fm.removeItem(at: slowStarted)
        try? fm.removeItem(at: slowRelease)
        try? fm.removeItem(at: slowPidFile)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config)
          echo $$ > "\(slowPidFile.path)"
          touch "\(slowStarted.path)"
          while [ ! -f "\(slowRelease.path)" ]; do sleep 0.01; done
          exit 1
          ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: slowConfigGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slowConfigGit.path)
    let supersedeSvc = GitDiffService(gitPath: slowConfigGit.path)
    supersedeSvc.refresh(cwd: repoA.path, immediate: true)
    let startedConfig = await waitFor(8) { fm.fileExists(atPath: slowStarted.path) }
    let slowPidStr = (try? String(contentsOf: slowPidFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let slowPid = slowPidStr.flatMap { Int32($0) }
    supersedeSvc.refresh(cwd: nil, immediate: true)
    var slowPidExited = false
    if let slowPid {
        slowPidExited = await waitFor(8) { Darwin.kill(slowPid, 0) != 0 }
    }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { cont.resume() } }
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { cont.resume() } }
    r.check("superseded git config termination does not overwrite newer refresh(cwd: nil) snapshot",
            startedConfig && slowPidExited && !supersedeSvc.isLoading && supersedeSvc.snapshot.cwd == nil && !supersedeSvc.snapshot.isGitRepo)

    // F18 / F27: inherited GIT_* and protocol/ssh/lazy-fetch env vars are stripped/disabled in child git processes
    func checkInheritedGitEnvStripping() async {
        let envRceMarker = fm.temporaryDirectory.appendingPathComponent("env-rce-marker-\(UUID().uuidString)")
        let envMalCfg = fm.temporaryDirectory.appendingPathComponent("env-mal-\(UUID().uuidString).cfg")
        let envAuditLog = fm.temporaryDirectory.appendingPathComponent("env-audit-\(UUID().uuidString).log")
        let envAuditGit = fm.temporaryDirectory.appendingPathComponent("env-audit-git-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: envRceMarker)
            try? fm.removeItem(at: envMalCfg)
            try? fm.removeItem(at: envAuditLog)
            try? fm.removeItem(at: envAuditGit)
        }
        try? """
        [diff]
        \texternal = touch '\(envRceMarker.path)'
        [filter "envpwn"]
        \tclean = touch '\(envRceMarker.path)'
        \trequired = true
        """.write(to: envMalCfg, atomically: true, encoding: .utf8)
        try? """
        #!/bin/sh
        sub=""
        for a in "$@"; do
          case "$a" in
            rev-parse|branch|config|hash-object|diff|status) sub="$a"; break ;;
          esac
        done
        printf '%s|cfg=%s|params=%s|cnt=%s|attr=%s|nolazy=%s|proto=%s|ssh=%s|sshbin=%s|ask=%s|sask=%s\\n' "$sub" "${GIT_CONFIG:-}" "${GIT_CONFIG_PARAMETERS:-}" "${GIT_CONFIG_COUNT:-}" "${GIT_ATTR_SOURCE:-}" "${GIT_NO_LAZY_FETCH:-}" "${GIT_ALLOW_PROTOCOL-UNSET}" "${GIT_SSH_COMMAND:-}" "${GIT_SSH:-}" "${GIT_ASKPASS:-}" "${SSH_ASKPASS:-}" >> "\(envAuditLog.path)"
        exec /usr/bin/git "$@"
        """.write(to: envAuditGit, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: envAuditGit.path)
        let envKeys = [
            "GIT_CONFIG", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_ATTR_SOURCE",
            "GIT_NO_LAZY_FETCH", "GIT_ALLOW_PROTOCOL", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_ASKPASS", "SSH_ASKPASS",
        ]
        let savedEnv = Dictionary(uniqueKeysWithValues: envKeys.map { k in (k, ProcessInfo.processInfo.environment[k]) })
        Darwin.setenv("GIT_CONFIG", envMalCfg.path, 1)
        Darwin.setenv("GIT_CONFIG_PARAMETERS", "'filter.envpwn.clean=touch \(envRceMarker.path)'", 1)
        Darwin.setenv("GIT_CONFIG_COUNT", "1", 1)
        Darwin.setenv("GIT_CONFIG_KEY_0", "diff.external", 1)
        Darwin.setenv("GIT_CONFIG_VALUE_0", "touch \(envRceMarker.path)", 1)
        Darwin.setenv("GIT_ATTR_SOURCE", "deadbeefdeadbeef", 1)
        Darwin.setenv("GIT_NO_LAZY_FETCH", "0", 1)
        Darwin.setenv("GIT_ALLOW_PROTOCOL", "ssh:file", 1)
        Darwin.setenv("GIT_SSH", "/usr/bin/touch", 1)
        Darwin.setenv("GIT_SSH_COMMAND", "touch '\(envRceMarker.path)'", 1)
        Darwin.setenv("GIT_ASKPASS", "/usr/bin/touch", 1)
        Darwin.setenv("SSH_ASKPASS", "/usr/bin/touch", 1)
        defer {
            for (k, v) in savedEnv {
                if let v { Darwin.setenv(k, v, 1) } else { Darwin.unsetenv(k) }
            }
        }
        let envAuditSvc = GitDiffService(gitPath: envAuditGit.path)
        envAuditSvc.refresh(cwd: repoA.path, immediate: true)
        let envAuditDone = await waitFor(8) { !envAuditSvc.isLoading && envAuditSvc.snapshot.cwd == repoA.path }
        let auditLines = ((try? String(contentsOf: envAuditLog, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
        let cfgLines = auditLines.filter { $0.hasPrefix("config|") || $0.hasPrefix("hash-object|") }
        let diffLines = auditLines.filter { $0.hasPrefix("diff|") || $0.hasPrefix("status|") }
        let expectedLockSuffix = "|nolazy=1|proto=|ssh=|sshbin=|ask=|sask="
        let allCfgStripped = !cfgLines.isEmpty && cfgLines.allSatisfy {
            $0.contains("|cfg=|params=|cnt=|attr=|") && $0.hasSuffix(expectedLockSuffix)
        }
        let diffAttrOverridden = !diffLines.isEmpty && diffLines.allSatisfy {
            $0.contains("|cfg=|params=|cnt=2|") && !$0.contains("attr=deadbeefdeadbeef") && !$0.contains("|attr=|") && $0.hasSuffix(expectedLockSuffix)
        }
        r.check("GitDiffService strips inherited GIT_CONFIG*, GIT_SSH*, ASKPASS and enforces GIT_NO_LAZY_FETCH=1 + empty GIT_ALLOW_PROTOCOL",
                envAuditDone && envAuditSvc.snapshot.isGitRepo && allCfgStripped && diffAttrOverridden && !fm.fileExists(atPath: envRceMarker.path),
                "cfg=\(cfgLines) diff=\(diffLines) rce=\(fm.fileExists(atPath: envRceMarker.path))")
    }
    await checkInheritedGitEnvStripping()

    // GitDiffService disables repo color.ui/color.diff + diff.relative and strips GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE
    func checkColorAndRelativeNeutralized() async {
        let colorRepo = fm.temporaryDirectory.appendingPathComponent("color-rel-\(UUID().uuidString)")
        let bogusGitDir = fm.temporaryDirectory.appendingPathComponent("bogus-gitdir-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: colorRepo)
            try? fm.removeItem(at: bogusGitDir)
        }
        let subDir = colorRepo.appendingPathComponent("nested/sub")
        try? fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: bogusGitDir, withIntermediateDirectories: true)
        _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", colorRepo.path])
        try? "old-line\n".write(to: subDir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        _ = await runProcess("/usr/bin/git", ["-C", colorRepo.path, "add", "nested/sub/note.md"])
        _ = await runProcess("/usr/bin/git", ["-C", colorRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
        try? "--- frontmatter\n++new-line\n".write(to: subDir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        _ = await runProcess("/usr/bin/git", ["-C", colorRepo.path, "config", "color.ui", "always"])
        _ = await runProcess("/usr/bin/git", ["-C", colorRepo.path, "config", "color.diff", "always"])
        _ = await runProcess("/usr/bin/git", ["-C", colorRepo.path, "config", "diff.relative", "true"])

        let savedGitDir = ProcessInfo.processInfo.environment["GIT_DIR"]
        let savedWorkTree = ProcessInfo.processInfo.environment["GIT_WORK_TREE"]
        let savedIndex = ProcessInfo.processInfo.environment["GIT_INDEX_FILE"]
        Darwin.setenv("GIT_DIR", bogusGitDir.path, 1)
        Darwin.setenv("GIT_WORK_TREE", bogusGitDir.path, 1)
        Darwin.setenv("GIT_INDEX_FILE", bogusGitDir.appendingPathComponent("idx").path, 1)
        defer {
            if let savedGitDir { Darwin.setenv("GIT_DIR", savedGitDir, 1) } else { Darwin.unsetenv("GIT_DIR") }
            if let savedWorkTree { Darwin.setenv("GIT_WORK_TREE", savedWorkTree, 1) } else { Darwin.unsetenv("GIT_WORK_TREE") }
            if let savedIndex { Darwin.setenv("GIT_INDEX_FILE", savedIndex, 1) } else { Darwin.unsetenv("GIT_INDEX_FILE") }
        }
        let colorSvc = GitDiffService()
        colorSvc.refresh(cwd: subDir.path, immediate: true)
        let colorDone = await waitFor(8) { !colorSvc.isLoading && colorSvc.snapshot.cwd == subDir.path }
        let noteFile = colorSvc.snapshot.files.first(where: { $0.path == "nested/sub/note.md" })
        let hasAnsi = noteFile?.lines.contains(where: { $0.text.contains("[3") || $0.text.contains("\u{1B}") }) ?? true
        let hasHunkLines = noteFile?.lines.contains(where: { $0.kind == .removed && $0.text == "-old-line" }) == true
            && noteFile?.lines.contains(where: { $0.kind == .added && $0.text == "+--- frontmatter" }) == true
            && noteFile?.lines.contains(where: { $0.kind == .added && $0.text == "+++new-line" }) == true
        r.check("GitDiffService disables color.diff/diff.relative and strips GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE",
                colorDone && colorSvc.snapshot.isGitRepo && noteFile?.added == 2 && noteFile?.deleted == 1 && !hasAnsi && hasHunkLines,
                "done=\(colorDone) paths=\(colorSvc.snapshot.files.map(\.path)) lines=\(noteFile?.lines.map(\.text) ?? [])")
    }
    await checkColorAndRelativeNeutralized()

    // F27: partial clone promisor + core.sshCommand never lazy-fetches or executes sshCommand
    let partialRepo = fm.temporaryDirectory.appendingPathComponent("partial-rce-\(UUID().uuidString)")
    let pwnedSshPath = "/tmp/pwned_ssh_\(UUID().uuidString)"
    defer {
        try? fm.removeItem(at: partialRepo)
        try? fm.removeItem(atPath: pwnedSshPath)
    }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", partialRepo.path])
    let partialFile = partialRepo.appendingPathComponent("missing.txt")
    try? "partial-blob\n".write(to: partialFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "add", "missing.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    let oidRes = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "rev-parse", "HEAD:missing.txt"])
    let oidOut = oidRes.out.trimmingCharacters(in: .whitespacesAndNewlines)
    try? "partial-blob\nchanged\n".write(to: partialFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "add", "missing.txt"])
    var removedBlobObj = false
    if oidRes.status == 0, oidOut.count >= 40 {
        let objDir = String(oidOut.prefix(2))
        let objFile = String(oidOut.dropFirst(2))
        let objURL = partialRepo.appendingPathComponent(".git/objects/\(objDir)/\(objFile)")
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: objURL.path)
        removedBlobObj = (try? fm.removeItem(at: objURL)) != nil
    }
    _ = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "config", "core.repositoryformatversion", "1"])
    _ = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "config", "core.sshCommand", "touch '\(pwnedSshPath)' && false"])
    _ = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "config", "extensions.partialClone", "origin"])
    _ = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "config", "remote.origin.url", "ssh://127.0.0.1/repo"])
    _ = await runProcess("/usr/bin/git", ["-C", partialRepo.path, "config", "remote.origin.promisor", "true"])
    let partialSvc = GitDiffService()
    partialSvc.refresh(cwd: partialRepo.path, immediate: true)
    let partialDone = await waitFor(8) { !partialSvc.isLoading }
    r.check("partialClone promisor with core.sshCommand fails closed without lazy fetching or SSH RCE",
            removedBlobObj && partialDone && !partialSvc.snapshot.isGitRepo && !fm.fileExists(atPath: pwnedSshPath),
            "removed=\(removedBlobObj) isGitRepo=\(partialSvc.snapshot.isGitRepo) sshRce=\(fm.fileExists(atPath: pwnedSshPath))")

    // F26: >maxFilterEnvBytes filter expansion (<2 MiB config stdout) fails closed before spawning hash-object/diff
    let argMaxConfigGit = fm.temporaryDirectory.appendingPathComponent("argmax-cfg-\(UUID().uuidString)")
    let argMaxDiffRan = fm.temporaryDirectory.appendingPathComponent("argmax-diff-ran-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: argMaxConfigGit)
        try? fm.removeItem(at: argMaxDiffRan)
    }
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config)
          awk 'BEGIN { for (i = 0; i < 9000; i++) printf "filter.k%05d.clean%c", i, 0 }'
          exit 0
          ;;
        hash-object|diff|status) touch '\(argMaxDiffRan.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: argMaxConfigGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: argMaxConfigGit.path)
    let argMaxSvc = GitDiffService(gitPath: argMaxConfigGit.path)
    argMaxSvc.refresh(cwd: repoA.path, immediate: true)
    let argMaxDone = await waitFor(8) { !argMaxSvc.isLoading }
    r.check("large filter key set exceeding maxFilterEnvBytes fails closed before spawning hash-object/diff",
            argMaxDone && !argMaxSvc.snapshot.isGitRepo && !fm.fileExists(atPath: argMaxDiffRan.path),
            "isGitRepo=\(argMaxSvc.snapshot.isGitRepo) ran=\(fm.fileExists(atPath: argMaxDiffRan.path))")

    // 2i. Real git fixture with deleted (D), renamed (R), binary tracked changes, and detached HEAD
    let histRepo = fm.temporaryDirectory.appendingPathComponent("hist-drb-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: histRepo) }
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", histRepo.path])
    try? "keep\n".write(to: histRepo.appendingPathComponent("delete-me.txt"), atomically: true, encoding: .utf8)
    try? "move-1\nmove-2\n".write(to: histRepo.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
    try? Data([0x00, 0x01, 0x02, 0x03]).write(to: histRepo.appendingPathComponent("img.bin"))
    _ = await runProcess("/usr/bin/git", ["-C", histRepo.path, "add", "."])
    _ = await runProcess("/usr/bin/git", ["-C", histRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "base"])
    let headShaRes = await runProcess("/usr/bin/git", ["-C", histRepo.path, "rev-parse", "--short", "HEAD"])
    let expectedDetached = "(detached: \(headShaRes.out.trimmingCharacters(in: .whitespacesAndNewlines)))"
    _ = await runProcess("/usr/bin/git", ["-C", histRepo.path, "checkout", "-q", "--detach", "HEAD"])
    try? fm.removeItem(at: histRepo.appendingPathComponent("delete-me.txt"))
    _ = await runProcess("/usr/bin/git", ["-C", histRepo.path, "mv", "before.txt", "after.txt"])
    try? Data([0x00, 0x01, 0xFF, 0xFE, 0x04]).write(to: histRepo.appendingPathComponent("img.bin"))
    svc.refresh(cwd: histRepo.path, immediate: true)
    let histDone = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == histRepo.path }
    let delFile = svc.snapshot.files.first(where: { $0.path == "delete-me.txt" })
    let renFile = svc.snapshot.files.first(where: { $0.path == "after.txt" })
    let binFile = svc.snapshot.files.first(where: { $0.path == "img.bin" })
    r.check("GitDiffService reports detached HEAD, deleted (D), renamed (R), and binary (truncated == false) files",
            histDone
            && svc.snapshot.isGitRepo
            && svc.snapshot.branch == expectedDetached
            && delFile?.status == "D" && delFile?.deleted == 1
            && renFile?.status == "R"
            && binFile != nil && binFile?.truncated == false,
            "branch=\(svc.snapshot.branch ?? "nil") del=\(delFile?.status ?? "nil") ren=\(renFile?.status ?? "nil") binTrunc=\(String(describing: binFile?.truncated))")

    // 3. Unborn HEAD repository
    let unbornRepo = fm.temporaryDirectory.appendingPathComponent("unborn-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: unbornRepo) }
    try? fm.createDirectory(at: unbornRepo, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "feat/unborn"], env: ["GIT_DIR": unbornRepo.appendingPathComponent(".git").path])
    let unbornFile = unbornRepo.appendingPathComponent("README.md")
    try? "# Unborn\n".write(to: unbornFile, atomically: true, encoding: .utf8)

    svc.refresh(cwd: unbornRepo.path, immediate: true)
    _ = await waitFor(8) { !svc.isLoading && svc.snapshot.isGitRepo }
    r.check("unborn HEAD reports isGitRepo without crash and finds untracked/staged files",
            svc.snapshot.isGitRepo
            && svc.snapshot.branch == "feat/unborn"
            && !svc.snapshot.files.isEmpty)

    // 4. previewCandidates + untracked sibling-prefix traversal / live-writer FIFO / truncation / exact maxFilterEnvBytes boundary checks
    let safeFile = unbornRepo.appendingPathComponent("sample.html")
    try? "<h1>hi</h1>".write(to: safeFile, atomically: true, encoding: .utf8)
    let symlinkToPasswd = unbornRepo.appendingPathComponent("passwd_link.txt")
    try? fm.createSymbolicLink(at: symlinkToPasswd, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
    let unbornSiblingEvil = fm.temporaryDirectory.appendingPathComponent(unbornRepo.lastPathComponent + "-evil")
    defer { try? fm.removeItem(at: unbornSiblingEvil) }
    try? fm.createDirectory(at: unbornSiblingEvil, withIntermediateDirectories: true)
    let siblingSecret = unbornSiblingEvil.appendingPathComponent("secret.txt")
    try? "top-secret\n".write(to: siblingSecret, atomically: true, encoding: .utf8)
    let siblingSymlink = unbornRepo.appendingPathComponent("sibling_link.txt")
    try? fm.createSymbolicLink(at: siblingSymlink, withDestinationURL: siblingSecret)
    let untrackedFifo = unbornRepo.appendingPathComponent("pipe_fifo.txt")
    _ = Darwin.mkfifo(untrackedFifo.path, 0o600)
    // Hold FIFO read end open so closing the writer leaves "fifo-leak\n" + clean EOF instead of EAGAIN;
    // unmutated S_IFREG rejects before read, while a missing S_IFREG check reads "fifo-leak".
    let fifoHoldFd = Darwin.open(untrackedFifo.path, O_RDONLY | O_NONBLOCK)
    defer {
        if fifoHoldFd >= 0 { Darwin.close(fifoHoldFd) }
    }
    let fifoWriterFd = Darwin.open(untrackedFifo.path, O_WRONLY | O_NONBLOCK)
    if fifoWriterFd >= 0 {
        let fifoPayload = Array("fifo-leak\n".utf8)
        _ = Darwin.write(fifoWriterFd, fifoPayload, fifoPayload.count)
        Darwin.close(fifoWriterFd)
    }
    let fifoDirectRead = GitDiffService.readUntrackedLines(at: untrackedFifo, cwd: unbornRepo.path)
    let bigUntracked = unbornRepo.appendingPathComponent("long_untracked.txt")
    try? (1...130).map { "line-\($0)" }.joined(separator: "\n").appending("\n").write(to: bigUntracked, atomically: true, encoding: .utf8)
    let hugeUntracked = unbornRepo.appendingPathComponent("huge_single_line.txt")
    try? (String(repeating: "x", count: 70_000) + "\n").write(to: hugeUntracked, atomically: true, encoding: .utf8)

    svc.refresh(cwd: unbornRepo.path, immediate: true)
    _ = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == unbornRepo.path && !svc.snapshot.previewCandidates.isEmpty }
    let candidates = svc.snapshot.previewCandidates
    let symlinkDiffEntry = svc.snapshot.files.first(where: { $0.path == "passwd_link.txt" })
    let siblingSymlinkEntry = svc.snapshot.files.first(where: { $0.path == "sibling_link.txt" })
    let siblingDirectRead = GitDiffService.readUntrackedLines(at: siblingSymlink, cwd: unbornRepo.path)
    let siblingContained = GitDiffService.isPathContained(siblingSecret, inDirectory: unbornRepo.path)
    let fifoDiffEntry = svc.snapshot.files.first(where: { $0.path == "pipe_fifo.txt" })
    let bigUntrackedEntry = svc.snapshot.files.first(where: { $0.path == "long_untracked.txt" })
    let hugeUntrackedEntry = svc.snapshot.files.first(where: { $0.path == "huge_single_line.txt" })
    r.check("previewCandidates and readUntrackedLines exclude escaping/sibling-prefix symlinks and writer FIFO without blocking, and cap >100-line / >64KB untracked files",
            candidates.first?.lastPathComponent == "README.md"
            && !candidates.contains(where: { $0.lastPathComponent == "passwd_link.txt" || $0.lastPathComponent == "sibling_link.txt" || $0.lastPathComponent == "pipe_fifo.txt" })
            && !siblingContained
            && siblingDirectRead.0.isEmpty && siblingDirectRead.1 == 0 && !siblingDirectRead.2
            && siblingSymlinkEntry?.lines.isEmpty == true && siblingSymlinkEntry?.previewURL == nil
            && symlinkDiffEntry?.lines.isEmpty == true && symlinkDiffEntry?.previewURL == nil
            && fifoDiffEntry == nil && fifoDirectRead.0.isEmpty && fifoDirectRead.1 == 0 && !fifoDirectRead.2
            && bigUntrackedEntry?.lines.count == GitDiffService.maxDiffLinesPerFile
            && bigUntrackedEntry?.truncated == true
            && hugeUntrackedEntry?.lines.count == 1
            && hugeUntrackedEntry?.truncated == true,
            "siblingContained=\(siblingContained) fifoCount=\(fifoDirectRead.0.count) sibRead=\(siblingDirectRead.0.count)")

    // Exact maxFilterEnvBytes boundary (512 KiB allowed vs +1 byte fails closed)
    func buildBoundaryConfigPayload(targetTotalBytes: Int) -> Data {
        var total = "GIT_CONFIG_COUNT=".utf8.count + 12 + 1
        var out = Data()
        var idx = 0
        let maxChunkKeyLen = 32_000
        while true {
            let digits = String(idx).utf8.count
            let fixedOverhead = "GIT_CONFIG_KEY_".utf8.count + digits + 1 + 1
                + "GIT_CONFIG_VALUE_".utf8.count + digits + 1 + 1
            let remaining = targetTotalBytes - total - fixedOverhead
            let minKeyLen = "filter.b\(idx).clean".utf8.count
            if remaining <= maxChunkKeyLen + minKeyLen + fixedOverhead + 64 {
                let pad = max(0, remaining - minKeyLen)
                let key = "filter.b\(idx)" + String(repeating: "x", count: pad) + ".clean"
                out.append(contentsOf: key.utf8)
                out.append(0)
                return out
            }
            let pad = maxChunkKeyLen - minKeyLen
            let key = "filter.b\(idx)" + String(repeating: "x", count: pad) + ".clean"
            out.append(contentsOf: key.utf8)
            out.append(0)
            total += fixedOverhead + key.utf8.count
            idx += 1
        }
    }
    let exactCfgBin = fm.temporaryDirectory.appendingPathComponent("exact-512k-\(UUID().uuidString).bin")
    let overCfgBin = fm.temporaryDirectory.appendingPathComponent("over-512k-\(UUID().uuidString).bin")
    let exactCfgGit = fm.temporaryDirectory.appendingPathComponent("exact-cfg-git-\(UUID().uuidString)")
    let overCfgGit = fm.temporaryDirectory.appendingPathComponent("over-cfg-git-\(UUID().uuidString)")
    let overDiffRan = fm.temporaryDirectory.appendingPathComponent("over-diff-ran-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: exactCfgBin)
        try? fm.removeItem(at: overCfgBin)
        try? fm.removeItem(at: exactCfgGit)
        try? fm.removeItem(at: overCfgGit)
        try? fm.removeItem(at: overDiffRan)
    }
    try? buildBoundaryConfigPayload(targetTotalBytes: GitDiffService.maxFilterEnvBytes).write(to: exactCfgBin, options: .atomic)
    try? buildBoundaryConfigPayload(targetTotalBytes: GitDiffService.maxFilterEnvBytes + 1).write(to: overCfgBin, options: .atomic)
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config) cat '\(exactCfgBin.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: exactCfgGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exactCfgGit.path)
    try? """
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        config) cat '\(overCfgBin.path)'; exit 0 ;;
        hash-object|diff|status) touch '\(overDiffRan.path)'; exit 0 ;;
      esac
    done
    exec /usr/bin/git "$@"
    """.write(to: overCfgGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: overCfgGit.path)
    let exactSvc = GitDiffService(gitPath: exactCfgGit.path)
    exactSvc.refresh(cwd: repoA.path, immediate: true)
    let exactDone = await waitFor(8) { !exactSvc.isLoading }
    let overSvc = GitDiffService(gitPath: overCfgGit.path)
    overSvc.refresh(cwd: repoA.path, immediate: true)
    let overDone = await waitFor(8) { !overSvc.isLoading }
    r.check("filter env limit allows exact maxFilterEnvBytes (512 KiB) and fails closed at +1 byte before spawning hash-object/diff",
            exactDone && exactSvc.snapshot.isGitRepo
            && overDone && !overSvc.snapshot.isGitRepo && !fm.fileExists(atPath: overDiffRan.path),
            "exactRepo=\(exactSvc.snapshot.isGitRepo) overRepo=\(overSvc.snapshot.isGitRepo) overRan=\(fm.fileExists(atPath: overDiffRan.path))")

    // 5. Non-git directory, missing cwd reset, and generation cancellation
    let nonGitDir = fm.temporaryDirectory.appendingPathComponent("nongit-\(UUID().uuidString)")
    let targetDir = fm.temporaryDirectory.appendingPathComponent("target-\(UUID().uuidString)")
    let missingDir = fm.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: nonGitDir)
        try? fm.removeItem(at: targetDir)
    }
    try? fm.createDirectory(at: nonGitDir, withIntermediateDirectories: true)
    try? "# Non-Git Preview\n".write(to: nonGitDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "target-branch"], env: ["GIT_DIR": targetDir.appendingPathComponent(".git").path])

    svc.refresh(cwd: nonGitDir.path, immediate: true)
    _ = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == nonGitDir.path }
    r.check("non-git directory sets isGitRepo = false, empty files, and scans previewCandidates",
            !svc.snapshot.isGitRepo && svc.snapshot.files.isEmpty && svc.snapshot.previewCandidates.first?.lastPathComponent == "README.md")

    // Rapid switch (cancellation)
    svc.refresh(cwd: nonGitDir.path)
    svc.refresh(cwd: targetDir.path, immediate: true)
    _ = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == targetDir.path }
    r.check("rapid directory switch keeps the final directory result",
            svc.snapshot.cwd == targetDir.path && svc.snapshot.isGitRepo && svc.snapshot.branch == "target-branch")

    // Missing directory after prior isGitRepo == true clears snapshot cleanly
    svc.refresh(cwd: missingDir.path, immediate: true)
    r.check("refresh(cwd: missingDir) clears prior isGitRepo snapshot cleanly",
            !svc.isLoading && svc.snapshot.cwd == missingDir.path && !svc.snapshot.isGitRepo && svc.snapshot.files.isEmpty)

    // 6. LayoutFile backwards-compatible decoding & out-of-bounds clamping
    let legacyJSON = """
    {
      "version": 1,
      "workspaces": [],
      "sidebarVisible": true,
      "sidebarWidth": 260.0
    }
    """
    if let legacyLayout = try? JSONDecoder().decode(LayoutFile.self, from: Data(legacyJSON.utf8)) {
        r.check("legacy layout.json decodes with default inspectorVisible == true", legacyLayout.inspectorVisible == true)
        r.check("legacy layout.json decodes with default inspectorWidth == 320", legacyLayout.inspectorWidth == Double(LmuxTokens.Layout.rightInspectorWidthDefault))
        r.check("legacy layout.json decodes with default inspectorTab == .preview", legacyLayout.inspectorTab == .preview)
    } else {
        r.check("legacy layout.json decodes with default inspectorVisible == true", false)
        r.check("legacy layout.json decodes with default inspectorWidth == 320", false)
        r.check("legacy layout.json decodes with default inspectorTab == .preview", false)
    }

    let outOfBoundsJSON = """
    {
      "version": 1,
      "workspaces": [],
      "sidebarVisible": true,
      "sidebarWidth": 40.0,
      "inspectorVisible": false,
      "inspectorWidth": 2500.0,
      "inspectorTab": "diff"
    }
    """
    if let clampedLayout = try? JSONDecoder().decode(LayoutFile.self, from: Data(outOfBoundsJSON.utf8)) {
        r.check("out-of-bounds widths clamp to sidebarWidthMin (180) and inspectorWidthMax (1600)",
                clampedLayout.sidebarWidth == Double(LmuxTokens.Layout.sidebarWidthMin)
                && clampedLayout.inspectorWidth == Double(LmuxTokens.Layout.rightInspectorWidthMax))
        r.check("inspectorVisible is restored as false", clampedLayout.inspectorVisible == false)
        r.check("inspectorTab is restored as diff", clampedLayout.inspectorTab == .diff)
    } else {
        r.check("out-of-bounds widths clamp to sidebarWidthMin (180) and inspectorWidthMax (1600)", false)
        r.check("inspectorVisible is restored as false", false)
        r.check("inspectorTab is restored as diff", false)
    }

    let unknownTabJSON = """
    {
      "version": 1,
      "workspaces": [],
      "sidebarWidth": 999.0,
      "inspectorWidth": 80.0,
      "inspectorTab": "future-unknown-tab"
    }
    """
    if let futureLayout = try? JSONDecoder().decode(LayoutFile.self, from: Data(unknownTabJSON.utf8)) {
        r.check("unknown inspectorTab falls back to .preview and clamps high sidebar / low inspector widths",
                futureLayout.inspectorTab == .preview
                && futureLayout.sidebarWidth == Double(LmuxTokens.Layout.sidebarWidthMax)
                && futureLayout.inspectorWidth == Double(LmuxTokens.Layout.rightInspectorWidthMin))
    } else {
        r.check("unknown inspectorTab falls back to .preview and clamps high sidebar / low inspector widths", false)
    }

    // 7. AppModel inspector & workspaceFilter defaults and roundtrip
    let model = AppModel()
    r.check("AppModel default inspectorVisible is true", model.inspectorVisible == true)
    r.check("AppModel default inspectorWidth is 320", model.inspectorWidth == LmuxTokens.Layout.rightInspectorWidthDefault)
    r.check("AppModel default inspectorTab is .preview", model.inspectorTab == .preview)
    r.check("AppModel default workspaceFilter is .all", model.workspaceFilter == .all)
    r.check("AppModel reduceMotionOverride initially nil", model.reduceMotionOverride == nil)

    let testWorkspaceURL = URL(fileURLWithPath: "/tmp/sample-preview.html")
    model.inspectorPreviewURLByWorkspace["ws-1"] = testWorkspaceURL
    r.check("inspectorPreviewURLByWorkspace remembers preview url",
            model.inspectorPreviewURLByWorkspace["ws-1"] == testWorkspaceURL)

    // Snapshot layout roundtrip
    let c = makeController()
    c.model.inspectorVisible = false
    c.model.inspectorWidth = 360
    c.model.inspectorTab = .trace
    let snap = c.snapshotLayout()
    r.check("snapshotLayout includes inspectorVisible false", snap.inspectorVisible == false)
    r.check("snapshotLayout includes inspectorWidth 360", snap.inspectorWidth == 360)
    r.check("snapshotLayout includes inspectorTab .trace", snap.inspectorTab == .trace)

    // 8. AgentTelemetryStore, Codex codexReport tool streaming, and sessionEnd cleanup
    let ws = c.model.workspaces.first!
    let pane = ws.panes.first!
    let store = c.model.telemetryStore ?? AgentTelemetryStore()
    c.model.telemetryStore = store

    let initialDisplay = store.display(for: pane)
    r.check("initial telemetry has 0 turns and inactive",
            initialDisplay.turnCount == 0 && !initialDisplay.isActiveAgent)

    let fakeTelemetry = AgentTelemetrySnapshot(
        model: "claude-sonnet-4.5",
        turnCount: 2,
        contextUsedTokens: 15_000,
        contextLimitTokens: 200_000,
        inputTokens: 10_000,
        outputTokens: 500,
        cacheReadTokens: 4_500,
        estimatedCostUSD: 0.05
    )
    store.recordSnapshot(fakeTelemetry, for: pane.id)
    var d = store.display(for: pane)
    r.check("recordSnapshot updates display model and tokens",
            d.model == "claude-sonnet-4.5" && d.turnCount == 2 && d.contextUsedTokens == 15_000)

    // Verify turnCount takes max(jsonl.turnCount, toolStream.turnCount)
    var promptEvent = HookEvent(paneID: pane.id, name: "UserPromptSubmit")
    promptEvent.agent = .claude
    pane.agent.recordToolEvent(promptEvent)
    pane.agent.recordToolEvent(promptEvent)
    pane.agent.recordToolEvent(promptEvent) // toolStream.turnCount = 3 > 2
    d = store.display(for: pane)
    r.check("display turnCount uses max of jsonl and toolStream", d.turnCount == 3)

    // Verify Codex in codexReport mode still captures tool events via HookEvent
    pane.codexReport = .working
    pane.agentKind = .codex
    var toolEvent = try! HookEvent(paneID: pane.id, payload: [
        "hook_event_name": "PreToolUse",
        "session_id": "codex-1",
        "tool_name": "Bash",
        "tool_input": ["command": "make test"],
        "tool_use_id": "call_cdx_1"
    ])
    toolEvent.agent = .codex
    c.handleHook(toolEvent)
    d = store.display(for: pane)
    r.check("codexReport mode records tool events into ToolCallStream",
            d.toolCalls.contains(where: { $0.id == "call_cdx_1" && $0.name == "Bash" && $0.category == .bash }))

    // Verify sessionEnd clears telemetry snapshot
    var endEvent = try! HookEvent(paneID: pane.id, payload: [
        "hook_event_name": "SessionEnd",
        "session_id": "codex-1"
    ])
    endEvent.agent = .codex
    c.handleHook(endEvent)
    d = store.display(for: pane)
    r.check("sessionEnd clears telemetry snapshot in AgentTelemetryStore",
            d.contextUsedTokens == 0)

    // Real JSONL transcript -> Controller.scheduleTelemetryRefresh -> TranscriptCache -> AgentTelemetryStore end-to-end
    let liveTranscript = fm.temporaryDirectory.appendingPathComponent("live-telemetry-\(UUID().uuidString).jsonl")
    defer { try? fm.removeItem(at: liveTranscript) }
    let jsonlLine = #"{"type":"assistant","uuid":"u-e2e-1","parentUuid":null,"timestamp":"2026-11-19T10:00:00Z","message":{"id":"msg_e2e_1","role":"assistant","model":"claude-sonnet-4-5-20250929","content":[{"type":"text","text":"hello"}],"usage":{"input_tokens":1200,"cache_read_input_tokens":800,"output_tokens":300}}}"# + "\n"
    try? jsonlLine.write(to: liveTranscript, atomically: true, encoding: .utf8)
    pane.claudeSessionID = "sess-live-e2e"
    pane.transcriptPath = liveTranscript.path
    c.scheduleTelemetryRefresh(pane, delay: 0.01)
    let liveReady = await waitFor(8) { store.display(for: pane).model == "claude-sonnet-4-5-20250929" }
    let liveDisplay = store.display(for: pane)
    r.check("Controller.scheduleTelemetryRefresh parses real JSONL file into AgentTelemetryStore",
            liveReady
            && liveDisplay.inputTokens == 1200
            && liveDisplay.outputTokens == 300
            && liveDisplay.cacheReadTokens == 800
            && liveDisplay.contextUsedTokens == 2000)

    // 7. InspectorDiffView.displayState(for:)
    let nonGitSnap = GitDiffSnapshot(cwd: "/tmp", isGitRepo: false)
    r.check("InspectorDiffView.displayState for non-git repo",
            InspectorDiffView.displayState(for: nonGitSnap) == .notGitRepo)

    let cleanSnap = GitDiffSnapshot(cwd: "/tmp", isGitRepo: true, branch: "main", files: [])
    r.check("InspectorDiffView.displayState for clean git repo",
            InspectorDiffView.displayState(for: cleanSnap) == .clean(branch: "main"))

    let diffFile = GitDiffFile(path: "Sources/Main.swift", status: "M", added: 5, deleted: 2, lines: [
        GitDiffLine(id: 0, kind: .added, text: "+let x = 1"),
        GitDiffLine(id: 1, kind: .removed, text: "-let x = 0")
    ])
    let dirtySnap = GitDiffSnapshot(cwd: "/tmp", isGitRepo: true, branch: "feat", totalAdded: 5, totalDeleted: 2, files: [diffFile])
    r.check("InspectorDiffView.displayState for dirty git repo",
            InspectorDiffView.displayState(for: dirtySnap) == .diff(branch: "feat", fileCount: 1, added: 5, deleted: 2))

    // symlink / traversal / unsafe preview check
    r.check("InspectorDiffView.resolvePreviewURL rejects unsafe control characters and path traversal",
            InspectorDiffView.resolvePreviewURL(file: "test\u{202E}file.txt", cwd: "/tmp") == nil
            && InspectorDiffView.resolvePreviewURL(file: "../README.md", cwd: unbornRepo.path) == nil
            && InspectorDiffView.resolvePreviewURL(file: "passwd_link.txt", cwd: unbornRepo.path) == nil)

    // Large tracked diff > maxBytes still retains numstat counts and truncated = true for omitted following files
    let hugeRepo = fm.temporaryDirectory.appendingPathComponent("huge-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: hugeRepo) }
    try? fm.createDirectory(at: hugeRepo, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-b", "main"], env: ["GIT_DIR": hugeRepo.appendingPathComponent(".git").path])
    let hugeFile = hugeRepo.appendingPathComponent("00-big.txt")
    let afterHugeFile = hugeRepo.appendingPathComponent("zz-after.txt")
    let bigChunk = String(repeating: "0123456789abcdef0123456789abcdef\n", count: 10_000) // ~330 KB (> 256 KB maxBytes)
    try? "seed\n".write(to: hugeFile, atomically: true, encoding: .utf8)
    try? "before\n".write(to: afterHugeFile, atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", hugeRepo.path, "add", "00-big.txt", "zz-after.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", hugeRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])
    try? bigChunk.write(to: hugeFile, atomically: true, encoding: .utf8)
    try? "before\nafter\n".write(to: afterHugeFile, atomically: true, encoding: .utf8)
    svc.refresh(cwd: hugeRepo.path, immediate: true)
    _ = await waitFor(8) { !svc.isLoading && svc.snapshot.cwd == hugeRepo.path }
    let bigDiffEntry = svc.snapshot.files.first(where: { $0.path == "00-big.txt" })
    let omittedAfterEntry = svc.snapshot.files.first(where: { $0.path == "zz-after.txt" })
    r.check("oversized unified diff omitted by maxBytes preserves numstat added count and sets truncated=true",
            bigDiffEntry?.truncated == true
            && bigDiffEntry?.lines.count == GitDiffService.maxDiffLinesPerFile
            && omittedAfterEntry?.added == 1
            && omittedAfterEntry?.lines.isEmpty == true
            && omittedAfterEntry?.truncated == true,
            "big=(\(bigDiffEntry?.lines.count ?? -1),\(bigDiffEntry?.truncated ?? false)) omitted=(\(omittedAfterEntry?.added ?? -1),\(omittedAfterEntry?.lines.count ?? -1),\(omittedAfterEntry?.truncated ?? false))")

    // Codex OSC 7501 SessionStart guard: compact/resumed retain toolStream while fresh startup resets it
    pane.codexReport = .working
    pane.agentKind = .codex
    var cdxBind = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "SessionStart", "session_id": "codex-prev", "source": "startup"])
    cdxBind.agent = .codex
    c.handleHook(cdxBind)
    var cdxPrompt = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "UserPromptSubmit", "session_id": "codex-prev"])
    cdxPrompt.agent = .codex
    c.handleHook(cdxPrompt)
    var cdxTool = try! HookEvent(paneID: pane.id, payload: [
        "hook_event_name": "PreToolUse",
        "session_id": "codex-prev",
        "tool_name": "Read",
        "tool_use_id": "call_cdx_prev"
    ])
    cdxTool.agent = .codex
    c.handleHook(cdxTool)
    let populatedBeforeCompact = pane.agent.toolStream.entries.count == 1 && pane.agent.toolStream.turnCount == 1
    pane.restoredDoneSession = "codex-resume"

    var cdxCompact = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "SessionStart", "session_id": "codex-prev", "source": "compact"])
    cdxCompact.agent = .codex
    c.handleHook(cdxCompact)
    let compactRetainedTools = pane.agent.toolStream.entries.count == 1 && pane.agent.toolStream.turnCount == 1

    pane.restoredDoneSession = "codex-resume"
    var cdxResumed = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "SessionStart", "session_id": "codex-resume", "source": "startup"])
    cdxResumed.agent = .codex
    c.handleHook(cdxResumed)
    let resumedRetainedTools = pane.agent.toolStream.entries.count == 1
        && pane.agent.toolStream.turnCount == 1
        && pane.restoredDoneSession == nil

    var cdxStart = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "SessionStart", "session_id": "codex-2", "source": "startup"])
    cdxStart.agent = .codex
    c.handleHook(cdxStart)
    r.check("codexReport SessionStart retains compact/resumed toolStream and resets fresh startup toolStream",
            populatedBeforeCompact
            && compactRetainedTools
            && resumedRetainedTools
            && pane.agent.toolStream.entries.isEmpty
            && pane.agent.toolStream.turnCount == 0,
            "pop=\(populatedBeforeCompact) compact=\(compactRetainedTools) resumed=\(resumedRetainedTools) endEntries=\(pane.agent.toolStream.entries.count) endTurns=\(pane.agent.toolStream.turnCount)")
    pane.codexReport = nil

    // Non-codex SessionStart retention (compact / isResumed) vs clear, handleHook -> scheduleTelemetryRefresh, and clearStatus cleanup
    pane.agentKind = .claude
    store.recordSnapshot(fakeTelemetry, for: pane.id)
    let compactStart = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "SessionStart", "session_id": "sess-live-e2e", "source": "compact"])
    c.handleHook(compactStart)
    r.check("SessionStart(source: compact) retains AgentTelemetryStore snapshot",
            store.display(for: pane).contextUsedTokens == 15_000)

    pane.restoredDoneSession = "sess-live-e2e"
    let resumedStart = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "SessionStart", "session_id": "sess-live-e2e", "source": "startup"])
    c.handleHook(resumedStart)
    r.check("SessionStart(isResumed) retains AgentTelemetryStore snapshot",
            store.display(for: pane).contextUsedTokens == 15_000)

    let freshStart = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "SessionStart", "session_id": "sess-fresh-clear", "source": "startup"])
    c.handleHook(freshStart)
    r.check("SessionStart(non-compact, non-resumed) clears AgentTelemetryStore snapshot",
            store.display(for: pane).contextUsedTokens == 0)

    let liveTranscript2 = fm.temporaryDirectory.appendingPathComponent("live-telemetry-hook-\(UUID().uuidString).jsonl")
    defer { try? fm.removeItem(at: liveTranscript2) }
    let jsonlLine2 = #"{"type":"assistant","uuid":"u-e2e-2","parentUuid":null,"timestamp":"2026-11-19T10:01:00Z","message":{"id":"msg_e2e_2","role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":2400,"cache_read_input_tokens":600,"output_tokens":450}}}"# + "\n"
    try? jsonlLine2.write(to: liveTranscript2, atomically: true, encoding: .utf8)
    let stopHook = try! HookEvent(paneID: pane.id, payload: [
        "hook_event_name": "Stop",
        "session_id": "sess-fresh-clear",
        "transcript_path": liveTranscript2.path
    ])
    c.handleHook(stopHook)
    let hookRefreshed = await waitFor(8) { store.display(for: pane).model == "claude-opus-4-5" }
    r.check("handleHook(.stop) schedules telemetry refresh and parses updated JSONL",
            hookRefreshed && store.display(for: pane).contextUsedTokens == 3000)

    c.clearStatus(pane)
    r.check("clearStatus(_:) clears AgentTelemetryStore snapshot",
            store.display(for: pane).contextUsedTokens == 0)

    // F2 + F20 regression: uncached clearStatus/SessionStart/resetAfterClaude cancel debounced telemetry and drop stale in-flight reads deterministically
    func flushTranscripts() async {
        await Task.yield()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in c.transcripts.queue.async { cont.resume() } }
        await Task { @MainActor in }.value
        await Task { @MainActor in }.value
    }

    let liveTranscript3 = fm.temporaryDirectory.appendingPathComponent("live-telemetry-cancel-\(UUID().uuidString).jsonl")
    defer { try? fm.removeItem(at: liveTranscript3) }
    let jsonlLine3 = #"{"type":"assistant","uuid":"u-e2e-3","parentUuid":null,"timestamp":"2026-11-19T10:02:00Z","message":{"id":"msg_e2e_3","role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"cancel"}],"usage":{"input_tokens":4200,"output_tokens":550}}}"# + "\n"
    try? jsonlLine3.write(to: liveTranscript3, atomically: true, encoding: .utf8)

    pane.transcriptPath = liveTranscript3.path
    pane.hover.loadedPath = nil
    pane.hover.stamp = nil
    store.clear(paneID: pane.id)
    c.scheduleTelemetryRefresh(pane, delay: 0.05)
    let hadPendingWork = c.telemetryWork[pane.id] != nil
    c.refreshTitleFromClaude(pane)
    c.clearStatus(pane)
    let clearedPendingWork = c.telemetryWork[pane.id] == nil
    await flushTranscripts()
    let clearDroppedTitleWrite = store.display(for: pane).contextUsedTokens == 0

    pane.hover.loadedPath = nil
    pane.hover.stamp = nil
    c.refreshTurns(pane)
    let freshStart2 = try! HookEvent(paneID: pane.id, payload: ["hook_event_name": "SessionStart", "session_id": "sess-fresh-clear-2", "source": "startup"])
    c.handleHook(freshStart2)
    await flushTranscripts()
    _ = await waitFor(8) { !pane.hover.loading }
    let sessionStartDroppedRefresh = store.display(for: pane).contextUsedTokens == 0

    pane.transcriptPath = liveTranscript3.path
    pane.hover.loadedPath = nil
    pane.hover.stamp = nil
    c.refreshTurns(pane)
    c.resetAfterClaude(pane)
    await flushTranscripts()
    _ = await waitFor(8) { !pane.hover.loading }
    let resetDroppedRefresh = store.display(for: pane).contextUsedTokens == 0

    // Deterministic epoch check for loadTurns(_:): pause transcripts.queue after loadTurns captures telemetryGen,
    // clearStatus while in-flight, then release and confirm stale telemetry snapshot is dropped.
    let releaseQueue = DispatchSemaphore(value: 0)
    await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
        c.transcripts.queue.async {
            started.resume()
            releaseQueue.wait()
        }
    }
    pane.transcriptPath = liveTranscript3.path
    pane.hover.loadedPath = nil
    pane.hover.stamp = nil
    let inFlightLoadTurns = Task { _ = await c.loadTurns(pane) }
    await Task.yield()
    c.clearStatus(pane)
    releaseQueue.signal()
    await inFlightLoadTurns.value
    let loadTurnsDroppedStaleWrite = store.display(for: pane).contextUsedTokens == 0

    r.check("clearStatus, SessionStart, and resetAfterClaude cancel telemetryWork and drop stale in-flight snapshot writes",
            hadPendingWork && clearedPendingWork && clearDroppedTitleWrite && sessionStartDroppedRefresh && resetDroppedRefresh && loadTurnsDroppedStaleWrite)

    // F9: concurrent refreshTurns while pane.hover.loading == true queues non-vacuous needsReload & drains all pendingThens
    let concurrentFile = fm.temporaryDirectory.appendingPathComponent("concurrent-turns-\(UUID().uuidString).jsonl")
    defer { try? fm.removeItem(at: concurrentFile) }
    let concLine1 = #"{"type":"assistant","uuid":"c-u-1","parentUuid":null,"timestamp":"2026-11-19T10:00:00Z","message":{"id":"c_msg_1","role":"assistant","model":"claude-sonnet-4-5-20250929","content":[{"type":"text","text":"one"}],"usage":{"input_tokens":500,"output_tokens":100}}}"# + "\n"
    let concLine2 = #"{"type":"assistant","uuid":"c-u-2","parentUuid":"c-u-1","timestamp":"2026-11-19T10:01:00Z","message":{"id":"c_msg_2","role":"assistant","model":"claude-sonnet-4-5-20250929","content":[{"type":"text","text":"two"}],"usage":{"input_tokens":900,"output_tokens":200}}}"# + "\n"
    try? concLine1.write(to: concurrentFile, atomically: true, encoding: .utf8)
    pane.transcriptPath = concurrentFile.path
    pane.hover.loadedPath = nil
    pane.hover.stamp = nil
    store.clear(paneID: pane.id)
    var callbackOrder: [Int] = []
    var outputAtSecondCallback = -1
    c.refreshTurns(pane) { callbackOrder.append(1) }
    c.refreshTurns(pane) {
        outputAtSecondCallback = store.display(for: pane).outputTokens
        try? (concLine1 + concLine2).write(to: concurrentFile, atomically: true, encoding: .utf8)
        callbackOrder.append(2)
    }
    c.refreshTurns(pane) { callbackOrder.append(3) }
    let concDone = await waitFor(8) {
        callbackOrder.count == 3 && store.display(for: pane).outputTokens == 300
    }
    r.check("concurrent refreshTurns runs all pendingThens and reloads appended transcript via needsReload",
            concDone && callbackOrder == [1, 2, 3] && outputAtSecondCallback == 100,
            "callbacks=\(callbackOrder) firstOut=\(outputAtSecondCallback) out=\(store.display(for: pane).outputTokens)")

    // F8: AgentTelemetryStore display(for: nil), active fallback ("claude"/"codex"), and CodexRollout wiring
    store.clear(paneID: pane.id)
    r.check("AgentTelemetryStore.display(for: nil) returns empty display",
            store.display(for: nil) == PaneTelemetryDisplay())
    pane.agentKind = .claude
    pane.agent.handle(HookEvent(paneID: pane.id, name: "UserPromptSubmit"), focused: true)
    let claudeFallback = store.display(for: pane).model
    pane.agentKind = .codex
    let codexFallback = store.display(for: pane).model
    r.check("AgentTelemetryStore.display(for:) falls back to claude/codex when active before snapshot",
            claudeFallback == "claude" && codexFallback == "codex",
            "claude=\(claudeFallback ?? "nil") codex=\(codexFallback ?? "nil")")

    // F8b: SessionStart while pane is still idle (before first prompt) should still show live agent + model
    let liveSessPane = ws.panes.first!
    c.handleHook(try! HookEvent(paneID: liveSessPane.id, payload: [
        "hook_event_name": "SessionStart",
        "session_id": "sess-idle-prompt",
        "source": "startup",
        "model": "claude-sonnet-4-5"
    ]))
    let withHookModel = store.display(for: liveSessPane)
    c.handleHook(try! HookEvent(paneID: liveSessPane.id, payload: [
        "hook_event_name": "SessionStart",
        "session_id": "sess-idle-prompt-2",
        "source": "startup"
    ]))
    let withoutHookModel = store.display(for: liveSessPane)
    c.handleHook(try! HookEvent(paneID: liveSessPane.id, payload: [
        "hook_event_name": "SessionEnd",
        "session_id": "sess-idle-prompt-2"
    ]))
    let afterSessionEnd = store.display(for: liveSessPane)
    r.check("SessionStart (idle at prompt) reports isActiveAgent and hookModel/claude fallback until SessionEnd",
            withHookModel.isActiveAgent && withHookModel.model == "claude-sonnet-4-5"
            && withHookModel.contextLimitTokens == 200_000
            && withoutHookModel.isActiveAgent && withoutHookModel.model == "claude"
            && !afterSessionEnd.isActiveAgent && afterSessionEnd.model == nil,
            "with=\(withHookModel.model ?? "nil") without=\(withoutHookModel.model ?? "nil") after=\(afterSessionEnd.isActiveAgent)")
    c.handleHook(try! HookEvent(paneID: liveSessPane.id, payload: [
        "hook_event_name": "SessionStart",
        "session_id": "sess-opus-55",
        "source": "startup",
        "model": "claude-opus-5-5"
    ]))
    let opus55Display = store.display(for: liveSessPane)
    r.check("SessionStart with claude-opus-5-5 hookModel resolves 1M contextLimitTokens before transcript snapshot",
            opus55Display.model == "claude-opus-5-5" && opus55Display.contextLimitTokens == 1_000_000,
            "model=\(opus55Display.model ?? "nil") limit=\(opus55Display.contextLimitTokens)")
    c.handleHook(try! HookEvent(paneID: liveSessPane.id, payload: [
        "hook_event_name": "SessionEnd",
        "session_id": "sess-opus-55"
    ]))

    let rolloutDir = fm.temporaryDirectory.appendingPathComponent("codex/sessions/2026/11/20-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: rolloutDir) }
    try? fm.createDirectory(at: rolloutDir, withIntermediateDirectories: true)
    let rolloutFile = rolloutDir.appendingPathComponent("rollout-2026-11-20T00-00-00-s1.jsonl")
    let rMeta = #"{"timestamp":"2026-11-20T00:00:00Z","type":"session_meta","payload":{"id":"cdx-roll","cwd":"/tmp","model":"gpt-5.3-codex"}}"#
    let rUser = #"{"timestamp":"2026-11-20T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"hi"}}"#
    let rTok = #"{"timestamp":"2026-11-20T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":272000,"last_token_usage":{"input_tokens":5000,"cached_input_tokens":1000,"output_tokens":300}}}}"#
    try? [rMeta, rUser, rTok].joined(separator: "\n").appending("\n").write(to: rolloutFile, atomically: true, encoding: .utf8)
    var codexStart = try! HookEvent(paneID: pane.id, payload: [
        "hook_event_name": "SessionStart",
        "session_id": "cdx-roll",
        "source": "startup"
    ])
    codexStart.agent = .codex
    c.handleHook(codexStart)
    var codexStop = try! HookEvent(paneID: pane.id, payload: [
        "hook_event_name": "Stop",
        "session_id": "cdx-roll",
        "transcript_path": rolloutFile.path
    ])
    codexStop.agent = .codex
    c.handleHook(codexStop)
    let codexSynced = await waitFor(8) { store.display(for: pane).model == "gpt-5.3-codex" }
    r.check("Codex rollout path wired through handleHook(.stop) updates AgentTelemetryStore",
            CodexRollout.isRollout(rolloutFile.path)
            && codexSynced
            && store.display(for: pane).contextUsedTokens == 5000
            && store.display(for: pane).contextLimitTokens == 272_000,
            "model=\(store.display(for: pane).model ?? "nil") used=\(store.display(for: pane).contextUsedTokens)")

    // 8. InspectorTraceView & WindowFooterView presentation boundaries
    let emptyDisplay = PaneTelemetryDisplay()
    let emptyPres = InspectorTraceView.presentation(for: emptyDisplay)
    r.check("InspectorTraceView empty display state",
            !emptyPres.hasActiveAgent && emptyPres.modelName == "—" && emptyPres.costText == "—")

    r.check("InspectorTraceView.formatTokens formats <1k, >=1k, >=1M boundaries",
            InspectorTraceView.formatTokens(999) == "999"
            && InspectorTraceView.formatTokens(1_000) == "1.0k"
            && InspectorTraceView.formatTokens(1_000_000) == "1.0M")

    let nilCostZeroLimitDisplay = PaneTelemetryDisplay(
        model: "claude-3-7-sonnet",
        turnCount: 1,
        contextUsedTokens: 500,
        contextLimitTokens: 0,
        estimatedCostUSD: nil,
        contextPercent: 1.5,
        toolCalls: [
            ToolCallEntry(id: "run-1", name: "Read", category: .read, argument: "a.swift", status: .running, startedAtNanos: 0)
        ],
        isActiveAgent: true
    )
    let nilCostTrace = InspectorTraceView.presentation(for: nilCostZeroLimitDisplay)
    r.check("InspectorTraceView formats nil cost as dash", nilCostTrace.costText == "—")

    let footerNeg = WindowFooterView.presentation(
        telemetry: PaneTelemetryDisplay(model: "m", contextUsedTokens: 1, contextLimitTokens: 100, contextPercent: -0.25, toolCalls: [ToolCallEntry(id: "r1", name: "Glob", category: .search, argument: "", status: .running, startedAtNanos: 0)], isActiveAgent: true),
        git: nil
    )
    let footerOver = WindowFooterView.presentation(
        telemetry: PaneTelemetryDisplay(model: "m", contextUsedTokens: 150, contextLimitTokens: 100, contextPercent: 1.4, toolCalls: [ToolCallEntry(id: "f1", name: "Bash", category: .bash, argument: "", status: .failed, startedAtNanos: 0)], isActiveAgent: true),
        git: nil
    )
    let footerZeroLimit = WindowFooterView.presentation(telemetry: nilCostZeroLimitDisplay, git: nil)
    r.check("WindowFooterView.presentation clamps <0/>1 percent, handles zero limit, and formats running/failed tool prefix",
            footerNeg.contextPercentText == "0%" && footerNeg.contextRatio == 0.0 && footerNeg.latestToolText == "▶ Glob"
            && footerOver.contextPercentText == "100%" && footerOver.contextRatio == 1.0 && footerOver.latestToolText == "✕ Bash"
            && footerZeroLimit.contextPercentText == "—" && footerZeroLimit.contextRatio == nil)

    let activeDisplay = PaneTelemetryDisplay(
        model: "claude-3-7-sonnet",
        turnCount: 5,
        contextUsedTokens: 45_000,
        contextLimitTokens: 200_000,
        inputTokens: 30_000,
        outputTokens: 5_000,
        cacheReadTokens: 10_000,
        estimatedCostUSD: 0.1234,
        contextPercent: 0.225,
        toolCalls: [
            ToolCallEntry(id: "1", name: "Bash", category: .bash, argument: "ls -la", status: .succeeded, startedAtNanos: 0, durationMs: 42),
            ToolCallEntry(id: "2", name: "Read", category: .read, argument: "file.txt", status: .running, startedAtNanos: 0)
        ],
        isActiveAgent: true
    )
    let activePres = InspectorTraceView.presentation(for: activeDisplay)
    r.check("InspectorTraceView active presentation formatting",
            activePres.hasActiveAgent && activePres.modelName == "claude-3-7-sonnet"
            && activePres.contextPercentText == "22.5%"
            && activePres.contextTokensText == "45.0k / 200.0k"
            && activePres.costText == "$0.1234"
            && activePres.toolCalls.count == 2
            && activePres.toolCalls[0].category == .bash
            && activePres.toolCalls[1].category == .read)

    // 9. Git usage reduction checks: includeHunks: false, clean-repo diff skip, hash-object cache, readOnlyTools filter
    let optLog = fm.temporaryDirectory.appendingPathComponent("git-opt-log-\(UUID().uuidString)")
    let optGit = fm.temporaryDirectory.appendingPathComponent("git-opt-wrap-\(UUID().uuidString)")
    defer {
        try? fm.removeItem(at: optLog)
        try? fm.removeItem(at: optGit)
    }
    try? """
    #!/bin/sh
    echo "$*" >> '\(optLog.path)'
    exec /usr/bin/git "$@"
    """.write(to: optGit, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: optGit.path)
    let optSvc = GitDiffService(gitPath: optGit.path)

    // First refresh on clean repo (histRepo has uncommitted edits; use a clean repo)
    let cleanOptRepo = fm.temporaryDirectory.appendingPathComponent("git-opt-clean-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: cleanOptRepo) }
    try? fm.createDirectory(at: cleanOptRepo, withIntermediateDirectories: true)
    _ = await runProcess("/usr/bin/git", ["init", "-q", "-b", "main", cleanOptRepo.path])
    try? "a\nb\n".write(to: cleanOptRepo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    _ = await runProcess("/usr/bin/git", ["-C", cleanOptRepo.path, "add", "f.txt"])
    _ = await runProcess("/usr/bin/git", ["-C", cleanOptRepo.path, "-c", "user.name=test", "-c", "user.email=t@e.com", "commit", "-m", "init"])

    optSvc.refresh(cwd: cleanOptRepo.path, immediate: true, includeHunks: false)
    _ = await waitFor(8) { !optSvc.isLoading }
    optSvc.refresh(cwd: cleanOptRepo.path, immediate: true, includeHunks: false)
    _ = await waitFor(8) { !optSvc.isLoading }
    let cleanInvocations = ((try? String(contentsOf: optLog, encoding: .utf8)) ?? "")
        .split(separator: "\n")
        .map(String.init)
    let cleanHashObjects = cleanInvocations.filter { $0.contains(" hash-object ") }.count
    let cleanDiffs = cleanInvocations.filter { $0.contains(" diff ") }.count
    let cleanBranches = cleanInvocations.filter { $0.contains(" branch ") }.count
    r.check("Clean repo skips git diff / branch commands and caches hash-object (2 refreshes <= 7 git calls)",
            cleanInvocations.count <= 7 && cleanHashObjects == 1 && cleanDiffs == 0 && cleanBranches == 0,
            "count=\(cleanInvocations.count) hash=\(cleanHashObjects) diff=\(cleanDiffs) branch=\(cleanBranches)")

    // Dirty repo with includeHunks: false keeps totals exact while skipping unified diff, then includeHunks: true loads hunks
    try? "".write(to: optLog, atomically: true, encoding: .utf8)
    try? "a\nb\nc\n".write(to: cleanOptRepo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    optSvc.refresh(cwd: cleanOptRepo.path, immediate: true, includeHunks: false)
    _ = await waitFor(8) { !optSvc.isLoading }
    let summaryAdded = optSvc.snapshot.totalAdded
    let summaryHasHunks = optSvc.snapshotHasHunks
    let summaryLines = optSvc.snapshot.files.first?.lines.count ?? -1
    let summaryInvocations = ((try? String(contentsOf: optLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    let summaryDiffCount = summaryInvocations.filter { $0.contains(" diff ") }.count

    optSvc.refresh(cwd: cleanOptRepo.path, immediate: true, includeHunks: true)
    _ = await waitFor(8) { !optSvc.isLoading }
    r.check("includeHunks=false computes exact totals with 1 diff (--numstat) and includeHunks=true loads lines",
            summaryAdded == 1 && !summaryHasHunks && summaryLines == 0 && summaryDiffCount == 1
            && optSvc.snapshotHasHunks && (optSvc.snapshot.files.first?.lines.isEmpty == false),
            "added=\(summaryAdded) hasHunks=\(summaryHasHunks) lines=\(summaryLines) diffs=\(summaryDiffCount)")

    r.check("shouldRefreshGitAfterTool skips read-only tools and allows mutating tools",
            !LmuxController.shouldRefreshGitAfterTool("Read")
            && !LmuxController.shouldRefreshGitAfterTool("Grep")
            && !LmuxController.shouldRefreshGitAfterTool("Glob")
            && !LmuxController.shouldRefreshGitAfterTool(nil)
            && LmuxController.shouldRefreshGitAfterTool("Edit")
            && LmuxController.shouldRefreshGitAfterTool("Write")
            && LmuxController.shouldRefreshGitAfterTool("Bash"))

    return finish(r, c)
}
