import Foundation

/// lmux's hooks for Codex CLI: `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`), the
/// same `{"hooks":{"<Event>":[{"hooks":[{"type":"command",…}]}]}}` shape as Claude Code's
/// settings, edited by `HookInstaller` with the same guarantees (diff first, byte-for-byte
/// restore, only lmux's lines removed, atomic writes, file mode kept).
///
/// Codex runs a hook only after the user trusted it once ("Hooks need review … Trust all and
/// continue"); it records that in config.toml as `[hooks.state."<file>:<event>:<group>:<handler>"]`.
/// `trust(…)` reads that (never writes it) to tell whether lmux's hooks were trusted.
public enum CodexHookInstaller {
    /// Events the state machine consumes. Codex has no Notification, Elicitation or failure
    /// events; Interrupt (Esc mid-turn) returns the pane to idle.
    public static let events: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "SubagentStart", "SubagentStop", "Stop", "Interrupt", "SessionEnd",
    ]

    public static let target = HookInstaller.Target(events: events, argument: AgentKind.codex.rawValue, appends: true)

    /// `$CODEX_HOME`, else `~/.codex`.
    public static func home(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? ((env["HOME"] ?? NSHomeDirectory()) + "/.codex")
    }

    public static func defaultHooksPath(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        home(environment: env) + "/hooks.json"
    }

    public static func configPath(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        home(environment: env) + "/config.toml"
    }

    /// Codex looks installed: its home exists, or a `codex` executable is on `PATH`.
    public static func isInstalled(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: home(environment: env), isDirectory: &dir), dir.boolValue { return true }
        for p in (env["PATH"] ?? "").split(separator: ":") where FileManager.default.isExecutableFile(atPath: "\(p)/codex") {
            return true
        }
        return false
    }

    public static func planInstall(hooksPath: String, hookPath: String) throws -> HookInstaller.Change {
        try HookInstaller.planInstall(settingsPath: hooksPath, hookPath: hookPath, target: target)
    }

    public static func planUninstall(hooksPath: String,
                                     pristineDirectory: URL? = HookInstaller.defaultPristineDirectory()) throws -> HookInstaller.Change {
        try HookInstaller.planUninstall(settingsPath: hooksPath, target: target, pristineDirectory: pristineDirectory)
    }

    public static func status(hooksPath: String) throws -> HookInstaller.Status {
        try HookInstaller.status(of: HookInstaller.read(hooksPath), target: target)
    }

    public static func isComplete(hooksPath: String) -> Bool {
        HookInstaller.isComplete(settingsPath: hooksPath, target: target)
    }

    // MARK: Trust

    public enum Trust: Equatable, Sendable {
        /// Codex recorded a trust decision for every lmux hook.
        case trusted
        /// lmux's hooks are installed, but Codex has no trust record for `count` of them yet:
        /// the next `codex` asks once ("Trust all and continue"); until then they don't run.
        case needsReview(count: Int)
        /// Not installed (nothing to trust).
        case notInstalled
    }

    /// Where lmux's handlers sit in the file, as Codex keys them: `<event_snake>:<group>:<handler>`.
    public static func positions(_ text: String?) throws -> [String] {
        guard var text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if text.hasPrefix(HookInstaller.bom) { text.removeFirst() }
        guard case .object(let root) = try JSONValue.parse(text),
              case .object(let hooks)? = root.last(where: { $0.key == "hooks" })?.value else { return [] }
        var out: [String] = []
        for m in hooks where events.contains(m.key) {
            guard case .array(let groups) = m.value else { continue }
            for (gi, g) in groups.enumerated() {
                guard case .array(let hs)? = g["hooks"] else { continue }
                for (hi, h) in hs.enumerated() where HookInstaller.isLmuxHandler(h) {
                    out.append("\(snake(m.key)):\(gi):\(hi)")
                }
            }
        }
        return out
    }

    static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// `PreToolUse` -> `pre_tool_use` (Codex's key for an event in its trust records).
    static func snake(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase, !out.isEmpty { out.append("_") }
            out.append(contentsOf: ch.lowercased())
        }
        return out
    }

    /// Reads hooks.json and config.toml (only reads them).
    public static func trust(hooksPath: String, configPath: String) -> Trust {
        let pos = (try? positions(HookInstaller.read(hooksPath))) ?? []
        guard !pos.isEmpty else { return .notInstalled }
        let config = (try? HookInstaller.read(configPath)) ?? nil
        return trust(positions: pos, hooksPath: hooksPath, config: config ?? "")
    }

    static func trust(positions pos: [String], hooksPath: String, config: String) -> Trust {
        // Codex names the file by the path it loaded it from, which may differ from ours by a
        // symlink (a linked ~/.codex, /tmp vs /private/tmp): compare real paths.
        let ours = realPath(hooksPath)
        var recorded = Set<String>()
        for line in config.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[hooks.state.\""), t.hasSuffix("\"]") else { continue }
            let key = String(t.dropFirst("[hooks.state.\"".count).dropLast(2))
            // `<file>:<event>:<group>:<handler>`
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }
            let file = parts.dropLast(3).joined(separator: ":")
            if file == hooksPath || realPath(file) == ours { recorded.insert(parts.suffix(3).joined(separator: ":")) }
        }
        let missing = pos.filter { !recorded.contains($0) }.count
        return missing == 0 ? .trusted : .needsReview(count: missing)
    }
}
