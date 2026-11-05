import Foundation

/// Who may report a pane's state with OSC 7501 (`state=…:app=<name>`), for programs other than
/// Codex. Any program can print the escape, also a file shown with `cat`: a report counts only
/// from the pane's foreground job when that job is the program it names, never a program that
/// prints other bytes (a file, a download, a remote shell).
public enum ProgramReporter {
    /// Programs that pass bytes they didn't write to the terminal: whatever they show could name anything.
    public static let printers: Set<String> = [
        "cat", "tac", "less", "more", "most", "head", "tail", "bat", "batcat", "nl", "xxd", "hexdump", "od",
        "strings", "curl", "wget", "nc", "ncat", "socat", "ssh", "mosh", "tmux", "screen", "script", "watch",
        "git", "man", "grep", "rg", "sed", "awk", "jq", "yq", "tee", "pv", "diff", "delta", "busybox", "echo", "printf",
        "sort", "cut", "column", "zcat", "gzcat", "bzcat", "xzcat", "zstdcat", "zless", "zmore",
        // Wrappers: they run something else under their own name.
        "xargs", "find", "sudo", "doas", "timeout", "nice", "nohup", "stdbuf", "parallel", "exec", "time",
        // Other machines' and containers' output.
        "docker", "podman", "kubectl", "journalctl", "log", "telnet",
        // Task runners: their jobs' children (a test, a build step) print under the runner's name.
        "make", "gmake", "npm", "yarn", "pnpm", "bunx", "cargo", "go", "just", "brew", "pytest", "rake",
        "gradle", "mvn", "tox", "nox", "poetry", "pipenv", "pipx",
    ]
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "xonsh", "elvish", "login"]
    /// Interpreters (and `python…`) run any script, a viewer too: their name is never a program's own.
    static let interpreters: Set<String> = [
        "node", "nodejs", "bun", "deno", "npx", "uv", "uvx", "ruby", "perl", "php", "java", "env",
    ]

    /// libghostty hands lmux at most this many bytes of `app` (scripts/ghostty.patch).
    static let appBytes = 15

    /// `argv` (the foreground job's) is the program named `app`: its executable, or the script a
    /// shell or interpreter runs (`sh ./my-agent`, `node …/bin/opencode`, `python3 -m aider`; an
    /// extension doesn't count, `my-agent.py` is `my-agent`). Never a printer, a shell or an
    /// interpreter. Best effort: the printers are a list, not every program that shows a file.
    public static func namesItself(_ app: String, argv: [String]) -> Bool {
        let a = app.lowercased()
        guard !a.isEmpty, !runsOthers(a), let first = argv.first else { return false }
        let exe = base(first).trimmingCharacters(in: CharacterSet(charactersIn: "-"))  // (a login shell's `-zsh`)
        guard !printers.contains(exe) else { return false }
        // The executable, and for a shell or interpreter its script or module: the first argument
        // that isn't a flag (any other program's first argument is a file, not its name).
        var names = [exe]
        if runsOthers(exe), let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) { names.append(base(script)) }
        // Cut to what libghostty passed on: a longer name only has to start the same.
        let cut = a.utf8.count >= appBytes
        return names.contains { n in
            [n, (n as NSString).deletingPathExtension].contains { cut ? $0.hasPrefix(a) : $0 == a }
        }
    }

    /// `argv` is a shell's (the pane's own at a prompt, or one running a script).
    public static func isShell(_ argv: [String]) -> Bool {
        argv.first.map { shells.contains(base($0).trimmingCharacters(in: CharacterSet(charactersIn: "-"))) } == true
    }

    /// A name that runs other programs' code or bytes: a printer, a shell or an interpreter.
    static func runsOthers(_ name: String) -> Bool {
        printers.contains(name) || shells.contains(name) || interpreters.contains(name) || name.hasPrefix("python")
    }

    static func base(_ path: String) -> String { (path as NSString).lastPathComponent.lowercased() }
}

/// `lmux wait --until`: which state of a pane (or workspace) ends a wait. States are the names
/// `lmux list` shows: idle, running, needs input, done, failed.
public enum WaitUntil: String, Sendable, CaseIterable {
    /// The default: no longer running (done, failed, needs you or idle).
    case settled
    case idle
    /// The turn ended: done or failed.
    case done
    case needsYou = "needs-you"
    /// The state changes from what it was when the wait began.
    case any

    /// `fresh`: the state came after the last input lmux typed into the target (`lmux send`,
    /// `new-workspace --cmd`), so it isn't the turn before that input. `changed`: it differs from
    /// the state when the wait began.
    public func reached(_ state: String, fresh: Bool, changed: Bool) -> Bool {
        switch self {
        case .any: return changed
        case .settled: return fresh && state != "running"
        case .idle: return fresh && state == "idle"
        case .done: return fresh && (state == "done" || state == "failed")
        case .needsYou: return fresh && state == "needs input"
        }
    }
}
