import Foundation
import LmuxHooks

/// The command that resumes a Codex CLI session the way it was started:
/// `codex resume <session flags> <id>`, keeping the flags that configure the session
/// (model, sandbox, approvals, profile, `-c key=value`, cwd, extra dirs, search, the bypass
/// switches as given) and never a prompt, an image, a subcommand's own flags or another
/// session selector. Arity follows `codex --help` / `codex resume --help` (0.166.0).
enum CodexCommand {
    /// Flags carried over, with whether they take a value.
    static let kept: [String: Bool] = [
        "-m": true, "--model": true, "-s": true, "--sandbox": true, "-a": true, "--ask-for-approval": true,
        "-p": true, "--profile": true, "-c": true, "--config": true, "-C": true, "--cd": true,
        "--add-dir": true, "--enable": true, "--disable": true, "--local-provider": true,
        "--oss": false, "--search": false, "--full-auto": false, "--yolo": false,
        "--dangerously-bypass-approvals-and-sandbox": false, "--dangerously-bypass-hook-trust": false,
        "--approve-for-me": false, "--no-alt-screen": false, "--no-daemon": false, "--strict-config": false,
    ]

    /// Flags dropped with their value: one-shot input, other sessions, a new worktree.
    static let dropped: [String: Bool] = [
        "-i": true, "--image": true, "--last": false, "--all": false, "--include-non-interactive": false,
        "--worktree": false, "-h": false, "--help": false, "-V": false, "--version": false,
        // A remote app server's address can carry credentials, and its token comes from the env.
        "--remote": true, "--remote-auth-token-env": true,
    ]

    /// `-c key=value` overrides kept on resume: settings that pick how the session behaves, never
    /// where it connects or what it runs (providers' base URLs and env keys, MCP servers, shell
    /// environment, notify commands…): those can carry secrets or commands, and would be typed.
    static let keptConfigKeys: Set<String> = [
        "model", "model_provider", "model_reasoning_effort", "model_reasoning_summary", "model_verbosity",
        "model_context_window", "model_auto_compact_token_limit", "approval_policy", "sandbox_mode",
        "sandbox_workspace_write.network_access", "profile", "hide_agent_reasoning", "show_raw_agent_reasoning",
        "web_search", "tools.web_search", "disable_response_storage", "personality",
    ]

    /// A kept `-c` value: an allowlisted key (or a `features.<name>` switch) and a short plain value.
    static func isKeptConfig(_ kv: String) -> Bool {
        let parts = kv.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1]
        let featureSwitch = key.hasPrefix("features.") && key.dropFirst(9).allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard keptConfigKeys.contains(key) || featureSwitch else { return false }
        return value.count <= 64 && !value.contains("{") && !value.contains("[") && !value.contains("://")
    }

    /// `[VAR=value …] codex resume <session flags> <id>` (or a fresh `codex <flags>` without an id),
    /// shell-quoted. `argv` is the codex process's (the native binary under the npm wrapper takes
    /// the same arguments); `environment` as lmux-hook reported it (`CODEX_HOME`).
    static func resume(argv: [String]?, sessionID: String?, environment: [String: String] = [:],
                       inherited: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var exe = "codex"
        var kept: [String] = []
        if let argv, let i = argv.firstIndex(where: { ($0 as NSString).lastPathComponent == "codex" || $0.hasSuffix("/codex.js") }) {
            // A path the user typed is kept; the npm package's internals (the native binary in
            // node_modules) are reached through the `codex` on PATH instead. So is the package's
            // bin link that node was given for a typed `codex` (nvm: …/node/v16/bin/codex, gone
            // with that node version).
            let npmLink = i > 0 && (argv[0] as NSString).lastPathComponent.hasPrefix("node")
                && URL(fileURLWithPath: argv[i]).resolvingSymlinksInPath().path.contains("/node_modules/@openai/codex/")
            if (argv[i] as NSString).lastPathComponent == "codex", argv[i].contains("/"), !argv[i].contains("/node_modules/"), !npmLink {
                exe = argv[i]
            }
            var j = i + 1
            while j < argv.count {
                let a = argv[j]
                j += 1
                if a == "--" { break }  // the rest is the prompt
                // Positionals: a subcommand (`resume`, `fork`), a session id, a prompt. None is kept.
                guard a.hasPrefix("-"), a.count > 1 else { continue }
                let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
                let inline = a.contains("=") && a.hasPrefix("--")
                let takesValue = Self.kept[name] ?? Self.dropped[name] ?? false
                var group = [a]
                if takesValue, !inline, j < argv.count { group.append(argv[j]); j += 1 }
                if ["-c", "--config"].contains(name) {
                    let kv = inline ? String(a.split(separator: "=", maxSplits: 1).last ?? "") : (group.count > 1 ? group[1] : "")
                    if !isKeptConfig(kv) { continue }
                }
                if Self.kept[name] != nil { kept += group }
            }
        }
        let tail = sessionID.map { ["resume"] + kept + [$0] } ?? kept
        // A control character in anything that would be typed: only the plain resume.
        if ([exe] + kept).contains(where: ClaudeCommand.hasControlCharacter)
            || environment.contains(where: { ClaudeCommand.hasControlCharacter($0.key) || ClaudeCommand.hasControlCharacter($0.value) }) {
            return (["codex"] + (sessionID.map { ["resume", $0] } ?? [])).map(ClaudeCommand.shellQuote).joined(separator: " ")
        }
        let assignments = ClaudeCommand.assignments(environment, inherited: inherited)
        return (assignments + ([exe] + tail).map(ClaudeCommand.shellQuote)).joined(separator: " ")
    }

    /// `argv` (a saved command's words) is a command lmux wrote for `session`: `codex … resume … <id>`.
    static func isResume(_ argv: [String], session: String) -> Bool {
        guard ClaudeCommand.isSessionID(session), argv.last == session, let exe = argv.first, !exe.contains("="),
              (exe as NSString).lastPathComponent == "codex" else { return false }
        return argv.dropFirst().contains("resume")
    }
}
