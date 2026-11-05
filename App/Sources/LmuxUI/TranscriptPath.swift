import Foundation

/// Which `transcript_path` values lmux will read or carry over a restart.
/// The path comes from a hook event, so before lmux reads or keeps it, it must have the shape of
/// an agent's own transcript, not be any file the sender named.
enum TranscriptPath {
    /// Claude Code: `<config dir>/projects/<project dir>/<session uuid>.jsonl` (the config dir can
    /// be any CLAUDE_CONFIG_DIR, so only the shape below it is checked), a regular file of this user
    /// if it exists yet (Claude creates it at the first message).
    static func isClaudeTranscript(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard isPlainAbsolute(path) else { return false }
        let name = url.lastPathComponent
        guard name.hasSuffix(".jsonl"), ClaudeCommand.isSessionID(String(name.dropLast(".jsonl".count))) else { return false }
        let project = url.deletingLastPathComponent()
        guard !project.lastPathComponent.isEmpty, project.lastPathComponent != "/",
              project.deletingLastPathComponent().lastPathComponent == "projects" else { return false }
        return isOwnRegularFileOrAbsent(path)
    }

    /// Codex CLI: `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<timestamp>-<session uuid>.jsonl` (the
    /// home can be any CODEX_HOME, so only the shape below it is checked), a regular file of this
    /// user if it exists yet. lmux only reads these (Copy original, titles), never rewrites them.
    static func isCodexTranscript(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard isPlainAbsolute(path) else { return false }
        let name = url.lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), name.count > "rollout-.jsonl".count + 36,
              ClaudeCommand.isSessionID(String(name.dropLast(".jsonl".count).suffix(36))),
              !ClaudeCommand.hasControlCharacter(name) else { return false }
        let parts = url.pathComponents
        guard parts.count > 5, parts[parts.count - 5] == "sessions",
              parts[(parts.count - 4)...(parts.count - 2)].allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        return isOwnRegularFileOrAbsent(path)
    }

    /// Absolute, no `.` / `..` component, no `//`. (Not `standardizedFileURL`: it also drops a
    /// leading /private, so a CODEX_HOME under /private/tmp or /private/var never matched.)
    static func isPlainAbsolute(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("//")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    /// Any agent transcript lmux knows.
    static func isValid(_ path: String) -> Bool {
        isClaudeTranscript(path) || isCodexTranscript(path)
    }

    static func isOwnRegularFileOrAbsent(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT }
        return (st.st_mode & S_IFMT) == S_IFREG && st.st_uid == getuid()
    }
}
