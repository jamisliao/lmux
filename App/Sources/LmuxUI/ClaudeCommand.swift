import Foundation
import LmuxHooks

/// The command that resumes a Claude Code session the way it was started: `claude` with
/// the flags that configure the session (and leading `VAR=value` assignments such as
/// `CLAUDE_CONFIG_DIR`), never a prompt, `-p`, or another session selector. Used by restore (R11).
///
/// Flag arity follows `claude --help` (2.1.x, commander): `<x...>` takes every argument
/// up to the next flag, `[x]` takes the next argument unless it is a flag, `<x>` takes one.
enum ClaudeCommand {
    enum Arity { case none, one, optional, many }

    /// Flags carried over to the resumed session.
    static let kept: [String: Arity] = [
        "--add-dir": .many, "--allowedTools": .many, "--allowed-tools": .many, "--disallowedTools": .many,
        "--disallowed-tools": .many, "--mcp-config": .many, "--betas": .many, "--tools": .many,
        "--model": .one, "--permission-mode": .one, "--settings": .one, "--setting-sources": .one, "--agent": .one,
        "--agents": .one, "--append-system-prompt": .one, "--append-system-prompt-file": .one, "--system-prompt": .one,
        "--system-prompt-file": .one, "--fallback-model": .one, "--plugin-dir": .one, "--plugin-url": .one,
        "--effort": .one, "--debug-file": .one, "--autocompact": .one, "--max-budget-usd": .one, "-n": .one,
        "--name": .one, "--permission-prompt-tool": .one, "--permission-prompts": .one,
        "--system-prompt-snapshot": .one, "--remote-control-session-name-prefix": .one,
        "-d": .optional, "--debug": .optional, "--prompt-suggestions": .optional, "--remote-control": .optional,
        "--dangerously-skip-permissions": .none, "--allow-dangerously-skip-permissions": .none, "--verbose": .none,
        "--strict-mcp-config": .none, "--ide": .none, "--chrome": .none, "--no-chrome": .none,
        "--disable-slash-commands": .none, "--bare": .none, "--brief": .none, "--ax-screen-reader": .none,
        "--safe-mode": .none, "--restricted": .none, "--exclude-dynamic-system-prompt-sections": .none,
        "--forward-subagent-text": .none, "--no-session-persistence": .none,
    ]

    /// Flags that pick another session, print mode, or one-shot startup work: dropped with their values.
    static let dropped: [String: Arity] = [
        "-r": .optional, "--resume": .optional, "-c": .none, "--continue": .none, "--session-id": .one,
        "--fork-session": .none, "--from-pr": .optional, "--teleport": .optional, "--cloud": .optional,
        "--environment": .one, "-p": .none, "--print": .none, "--output-format": .one, "--input-format": .one,
        "--json-schema": .one, "--include-partial-messages": .none, "--include-hook-events": .none,
        "--replay-user-messages": .none, "-w": .optional, "--worktree": .optional, "--tmux": .optional,
        "--bg": .none, "--background": .none, "--file": .many, "-v": .none, "--version": .none, "-h": .none, "--help": .none,
    ]

    /// `[VAR=value …] claude <session flags> [--resume <id>]`, shell-quoted.
    /// `environment` is the claude process's environment as lmux-hook reported it
    /// (`HookClient.replayable` names only); variables equal to `inherited` (what the
    /// pane's shell already has) are left out.
    static func resume(argv: [String]?, sessionID: String?, environment: [String: String] = [:],
                       inherited: [String: String] = ProcessInfo.processInfo.environment) -> String {
        var exe = "claude"
        var kept: [String] = []
        if let argv, let i = argv.firstIndex(where: { a in
            let b = (a as NSString).lastPathComponent
            return b == "claude" || a.hasSuffix("/cli.js") || a.hasSuffix("/cli.mjs")
        }) {
            if (argv[i] as NSString).lastPathComponent == "claude" { exe = argv[i] }
            var j = i + 1
            while j < argv.count {
                let a = argv[j]
                j += 1
                if a == "--" { break }  // the rest is the prompt
                guard a.hasPrefix("-"), a.count > 1 else { continue }  // positional: the prompt
                let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
                let inline = a.contains("=")
                let keep = Self.kept[name] != nil
                let arity = Self.kept[name] ?? Self.dropped[name] ?? .none
                var group = [a]
                if !inline {
                    switch arity {
                    case .none: break
                    case .one:
                        if j < argv.count { group.append(argv[j]); j += 1 }
                    case .optional:
                        if j < argv.count, !argv[j].hasPrefix("-") { group.append(argv[j]); j += 1 }
                    case .many:
                        while j < argv.count, !argv[j].hasPrefix("-") { group.append(argv[j]); j += 1 }
                    }
                }
                if keep, let g = pathOnly(group, name: name, inline: inline) { kept += g }
            }
        }
        let resume = sessionID.map { ["--resume", $0] } ?? []
        // A control character in anything that would be typed (argv or env read from the process):
        // nothing of it is replayed, only the plain resume.
        if ([exe] + kept).contains(where: hasControlCharacter)
            || environment.contains(where: { hasControlCharacter($0.key) || hasControlCharacter($0.value) }) {
            return (["claude"] + resume).map(shellQuote).joined(separator: " ")
        }
        let assignments = Self.assignments(environment, inherited: inherited)
        return (assignments + ([exe] + kept + resume).map(shellQuote)).joined(separator: " ")
    }

    /// Flags whose value may be inline content instead of a file (`--settings '{"env":{…}}'`,
    /// `--system-prompt "…"`): such content can carry secrets and would be typed into the shell
    /// (and land on screen / in scrollback), so only values that look like file paths are kept and a
    /// flag left without one is dropped. A path: no newline, not JSON (`{` / `[`), and a `/` or a
    /// file extension (`m1.json`, `./prompt.md`).
    static let pathOnlyFlags: Set<String> = ["--mcp-config", "--settings", "--system-prompt", "--append-system-prompt"]

    static func looksLikePath(_ v: String) -> Bool {
        guard !v.isEmpty, !v.contains(where: \.isNewline), let first = v.first, first != "{", first != "[" else { return false }
        return v.contains("/") || v.range(of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
    }

    /// `group` (the flag and its values) with only path values, nil when none is left.
    static func pathOnly(_ group: [String], name: String, inline: Bool) -> [String]? {
        guard pathOnlyFlags.contains(name) else { return group }
        if inline {
            let value = group[0].split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            return looksLikePath(value) ? group : nil
        }
        let values = group.dropFirst().filter(looksLikePath)
        return values.isEmpty ? nil : [group[0]] + values
    }

    /// C0 (incl. newline, ESC) / DEL / C1 controls.
    static func hasControlCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// A Claude Code session id (a UUID): the only thing ever typed after `--resume`.
    static func isSessionID(_ s: String) -> Bool {
        s.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                options: .regularExpression) != nil
    }

    /// `VAR=value` for the allowlisted variables whose value the shell doesn't already have.
    static func assignments(_ environment: [String: String], inherited: [String: String]) -> [String] {
        environment.filter { HookClient.replayable($0.key) && inherited[$0.key] != $0.value }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=" + shellQuote($0.value) }
    }

    /// The words of a command `shellQuote` wrote (plain words, '…' quoted parts, `\'` and `\\` outside
    /// quotes); nil for anything else: an operator, a substitution, a glob, an unclosed quote.
    static func shellWords(_ s: String) -> [String]? {
        var words: [String] = [], cur = "", inWord = false, quoted = false
        var it = s.makeIterator()
        while let c = it.next() {
            if quoted {
                if c == "'" { quoted = false } else { cur.append(c) }
            } else if c == " " {
                if inWord { words.append(cur); cur = ""; inWord = false }
            } else if c == "'" {
                quoted = true; inWord = true
            } else if c == "\\" {
                guard let e = it.next(), e == "'" || e == "\\" else { return nil }
                cur.append(e); inWord = true
            } else if c.isASCII && (c.isLetter || c.isNumber || "/-_.,:@%+=".contains(c)) {
                cur.append(c); inWord = true
            } else {
                return nil
            }
        }
        if quoted { return nil }
        if inWord { words.append(cur) }
        return words
    }

    /// Quoted for POSIX shells and fish alike: inside '…' fish treats \' and \\ as escapes, so a
    /// quote or a backslash never appears inside the quotes; each is written outside them, escaped
    /// (`\'`, `\\`), which both read as the literal character.
    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/-_.,:@%+=".contains($0)) }) { return s }
        var out = "'"
        for c in s {
            switch c {
            case "'": out += "'\\''"
            case "\\": out += "'\\\\'"
            default: out.append(c)
            }
        }
        return out + "'"
    }
}
