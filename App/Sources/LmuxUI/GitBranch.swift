import Foundation

/// Cheap branch lookup: walk up from `cwd` to the first `.git`, read its HEAD.
/// No `git` process, no polling; callers refresh on cwd/title changes.
enum GitBranch {
    static func read(cwd: String) -> String? {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<64 {
            let dotgit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotgit.path, isDirectory: &isDir) {
                var gitDir = dotgit
                if !isDir.boolValue {
                    // Worktree / submodule: ".git" is a file "gitdir: <path>".
                    guard let s = try? String(contentsOf: dotgit, encoding: .utf8),
                          let line = s.split(whereSeparator: \.isNewline).first,
                          line.hasPrefix("gitdir:") else { return nil }
                    let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
                }
                return parseHEAD(try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    static func parseHEAD(_ text: String?) -> String? {
        guard let head = text?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        return String(head.prefix(7))  // detached
    }
}

/// `~/x/y` for display.
func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// `~/Desktop/workspace/lmux` -> `~/…/lmux`: the first and last components of a deep path.
func compactPath(_ path: String) -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count > 3 else { return path }
    return "\(parts[0])/…/\(parts[parts.count - 1])"
}
