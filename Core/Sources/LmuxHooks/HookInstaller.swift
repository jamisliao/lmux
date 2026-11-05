import CryptoKit
import Foundation
import LmuxPrivateFile

/// Adds/removes lmux's hook entries in a Claude Code settings.json (or, with
/// `Target.codex`, a Codex CLI hooks.json: the same `{"hooks":{…}}` shape).
/// Foreign hooks (and every other key) are preserved in order and content.
/// A lmux entry is any hook handler whose `command` contains `marker`.
public enum HookInstaller {
    public static let marker = "# lmux-managed"

    /// Which agent's file is edited: the events lmux listens to there, the argument the
    /// hook command passes to lmux-hook, and where lmux's group goes in each event array.
    public struct Target: Sendable, Equatable {
        public var events: [String]
        /// `lmux-hook <argument>` (tags the events with the agent); nil for Claude Code.
        public var argument: String?
        /// Append lmux's group instead of prepending it. Codex remembers which hooks the user
        /// trusted by their position (`<file>:<event>:<group>:<handler>`), so lmux's group goes
        /// last and the user's own hooks keep their positions (and their trust).
        public var appends: Bool

        public static let claude = Target(events: HookInstaller.events, argument: nil, appends: false)
    }

    /// Events the state machine consumes (plus SubagentStart/Stop for the subagent counter).
    public static let events: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "PostToolUseFailure", "Notification", "SubagentStart",
        "SubagentStop", "Stop", "StopFailure", "Elicitation", "ElicitationResult",
        "SessionEnd",
    ]

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case notAnObject(String)
        case duplicateKey(String)
        /// The file is no longer what the change was planned from (edited since): plan again.
        case changedSincePlanned(String)
        public var description: String {
            switch self {
            case .changedSincePlanned(let p): return "\(p) changed since the change was shown; nothing was written"
            case .notAnObject(let w): return "unexpected settings shape: \(w) is not what Claude Code expects; refusing to edit"
            case .duplicateKey(let k):
                return "\"\(k)\" appears more than once in settings.json (Claude Code only reads the last one); "
                    + "merge them first, lmux won't guess which one to edit"
            }
        }
    }

    public struct Status: Equatable, Sendable {
        public var installedEvents: [String]
        public var missingEvents: [String]
        public var commands: [String]
        public var isComplete: Bool { missingEvents.isEmpty }
    }

    public struct Change: Sendable {
        public enum Kind: Sendable { case install, uninstall }
        public var path: String
        public var before: String?
        public var after: String
        public var kind: Kind = .install
        /// Uninstall of a file that did not exist before lmux created it.
        public var removesFile = false
        public var changed: Bool { removesFile || before != after }
    }

    /// Shell command for one hook entry. Outside lmux (`LMUX_PANE_ID` unset) or when the
    /// binary is gone, the shell exits 0 without spawning anything.
    public static func command(hookPath: String, argument: String? = nil) -> String {
        let q = "'" + hookPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let arg = argument.map { " " + $0 } ?? ""
        return "[ -n \"$LMUX_PANE_ID\" ] && [ -x \(q) ] && exec \(q)\(arg); exit 0 \(marker)"
    }

    static func group(hookPath: String, argument: String? = nil) -> JSONValue {
        .object([.init("hooks", .array([.object([
            .init("type", .string("command")),
            .init("command", .string(command(hookPath: hookPath, argument: argument))),
            .init("timeout", .number("5")),
        ])]))])
    }

    static func isLmuxHandler(_ v: JSONValue) -> Bool {
        if case .string(let c)? = v["command"] { return c.contains(marker) }
        return false
    }

    // MARK: Pure text transforms
    //
    // Both directions edit the file's text in place (JSONText): install prepends lmux's
    // group to each event array (so the diff only adds lines, in the file's own
    // indentation and line endings), uninstall cuts exactly those entries out again.
    // Nothing else is re-serialized.

    static let bom = "\u{FEFF}"

    public static func install(into text: String?, hookPath: String, target: Target = .claude) throws -> String {
        if let text, text.hasPrefix(bom) {
            return bom + (try install(into: String(text.dropFirst()), hookPath: hookPath, target: target))
        }
        let events = target.events
        let desired = group(hookPath: hookPath, argument: target.argument)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let fresh = JSONValue.object([.init("hooks", .object(events.map { .init($0, .array([desired])) }))])
            return fresh.render() + "\n"
        }
        var doc = try document(text, events: events)
        guard doc.root.member("hooks") != nil else {
            try doc.prependMember([], key: "hooks", .object(events.map { .init($0, .array([desired])) }))
            return doc.text
        }
        for event in events.reversed() {
            let path: [JSONText.Step] = [.key("hooks"), .key(event)]
            if let arr = doc.span(path) {
                guard case .array(let groups) = try doc.value(arr) else { throw InstallError.notAnObject("hooks.\(event)") }
                if groups.filter(containsLmux) == [desired] { continue }  // already exactly installed
                try strip(&doc, path)
                if target.appends { try doc.appendElement(path, desired) } else { try doc.prependElement(path, desired) }
            } else {
                try doc.prependMember([.key("hooks")], key: event, .array([desired]))
            }
        }
        // Drop lmux entries from events we no longer use.
        for m in doc.span([.key("hooks")])?.members.reversed() ?? [] where !events.contains(m.key) {
            try removeLmux(&doc, event: m.key)
        }
        return doc.text
    }

    /// Containers the user had before lmux installed (from the pristine copy): an emptied
    /// `"hooks": {}` or `"Stop": []` that was already there stays, instead of going with lmux's lines.
    public struct Kept: Equatable, Sendable {
        public var hooks = false
        public var events: Set<String> = []
        public init(hooks: Bool = false, events: Set<String> = []) { self.hooks = hooks; self.events = events }

        /// What `original` (the settings text before install; nil = no file) already had.
        public init(original: String?) {
            guard var t = original else { return }
            if t.hasPrefix(HookInstaller.bom) { t.removeFirst() }
            guard case .object(let hm)? = (try? JSONValue.parse(t))?["hooks"] else { return }
            hooks = true
            events = Set(hm.compactMap { m -> String? in if case .array = m.value { return m.key }; return nil })
        }
    }

    /// `kept`: the containers the user had before install (nil = unknown: emptied ones go).
    public static func uninstall(from text: String?, target: Target = .claude, kept: Kept? = nil) throws -> String? {
        guard let text else { return nil }
        if text.hasPrefix(bom) { return try uninstall(from: String(text.dropFirst()), target: target, kept: kept).map { bom + $0 } }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        var doc = try document(text, events: target.events)
        guard let hooks = doc.root.member("hooks") else { return text }
        var touched = false
        for m in hooks.members.reversed() where try removeLmux(&doc, event: m.key, keepEmpty: kept?.events.contains(m.key) ?? false) {
            touched = true
        }
        guard touched else { return text }
        if kept?.hooks != true, let h = doc.span([.key("hooks")]), h.members.isEmpty { try doc.removeMember([], "hooks") }
        return doc.text
    }

    public static func status(of text: String?, target: Target = .claude) throws -> Status {
        let events = target.events
        guard var text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Status(installedEvents: [], missingEvents: events, commands: [])
        }
        if text.hasPrefix(bom) { text.removeFirst() }
        // What Claude Code sees: JSON.parse keeps the LAST of duplicate keys.
        guard case .object(let root) = try JSONValue.parse(text) else { throw InstallError.notAnObject("settings root") }
        var hooks: [JSONValue.Member] = []
        if case .object(let m)? = root.last(where: { $0.key == "hooks" })?.value {
            for mem in m {
                hooks.removeAll { $0.key == mem.key }
                hooks.append(mem)
            }
        }
        var installed: [String] = []
        var commands: [String] = []
        for m in hooks {
            guard case .array(let groups) = m.value else { continue }
            for g in groups {
                guard case .array(let hs)? = g["hooks"] else { continue }
                for h in hs where isLmuxHandler(h) {
                    if !installed.contains(m.key) { installed.append(m.key) }
                    if case .string(let c)? = h["command"], !commands.contains(c) { commands.append(c) }
                }
            }
        }
        return Status(installedEvents: installed,
                      missingEvents: events.filter { !installed.contains($0) },
                      commands: commands)
    }

    // MARK: File operations

    /// `$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`.
    public static func defaultSettingsPath(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let dir = env["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.claude")
        // URL: a trailing slash in CLAUDE_CONFIG_DIR doesn't give ".../cc//settings.json" in the sheet.
        return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("settings.json").path
    }

    public static func planInstall(settingsPath: String, hookPath: String, target: Target = .claude) throws -> Change {
        let before = try read(settingsPath)
        return Change(path: settingsPath, before: before, after: try install(into: before, hookPath: hookPath, target: target))
    }

    /// Uninstall plan. If the file is exactly what lmux wrote at install, the pristine copy
    /// kept then comes back byte for byte (an empty file stays empty, a file lmux created
    /// goes away); otherwise lmux's entries are cut out of the current text.
    public static func planUninstall(settingsPath: String, target: Target = .claude,
                                     pristineDirectory: URL? = defaultPristineDirectory()) throws -> Change {
        let before = try read(settingsPath)
        if let dir = pristineDirectory, let rec = Pristine.load(dir, settingsPath),
           let before, rec.installed == Pristine.digest(before) {
            return Change(path: settingsPath, before: before, after: rec.original ?? "", kind: .uninstall,
                          removesFile: rec.original == nil)
        }
        // Edited since install: cut lmux's lines out, keeping the empty containers the original had.
        let kept = pristineDirectory.flatMap { Pristine.load($0, settingsPath) }.map { Kept(original: $0.original) }
        return Change(path: settingsPath, before: before, after: try uninstall(from: before, target: target, kept: kept) ?? "",
                      kind: .uninstall)
    }

    public static func isComplete(settingsPath: String, target: Target = .claude) -> Bool {
        (try? status(of: read(settingsPath), target: target))?.isComplete ?? false
    }

    /// Writes atomically to the symlink-resolved path, keeping the file mode (a new file: 0600),
    /// with the mode set from the first byte (PrivateFile). An install
    /// keeps the file's original bytes in `pristineDirectory` (lmux's state dir, 0600).
    /// Throws `changedSincePlanned` (and writes nothing) when the file is no longer `change.before`:
    /// a change shown for confirmation is never written over edits made meanwhile.
    public static func apply(_ change: Change, pristineDirectory: URL? = defaultPristineDirectory()) throws {
        guard change.changed else { return }
        guard try read(change.path) == change.before else { throw InstallError.changedSincePlanned(change.path) }
        let url = URL(fileURLWithPath: change.path).resolvingSymlinksInPath()
        if change.removesFile {
            try FileManager.default.removeItem(at: url)
            if let dir = pristineDirectory { Pristine.remove(dir, change.path) }
            return
        }
        guard !(change.before == nil && change.after.isEmpty) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFile.replace(url, Data(change.after.utf8), mode: PrivateFile.mode(of: url.path) ?? 0o600)
        guard let dir = pristineDirectory else { return }
        switch change.kind {
        case .install:
            Pristine.prune(dir, keeping: change.path)
            // A reinstall over lmux's own install keeps the first original.
            let prev = Pristine.load(dir, change.path)
            let original = prev.flatMap { p in change.before.map(Pristine.digest) == p.installed ? p : nil }
            try Pristine.save(dir, change.path, original: original.map { $0.original } ?? change.before,
                              installed: Pristine.digest(change.after))
        case .uninstall:
            Pristine.remove(dir, change.path)
        }
    }

    /// `$LMUX_STATE_DIR/hooks-pristine`, else `~/Library/Application Support/lmux/hooks-pristine`.
    public static func defaultPristineDirectory(environment env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = env["LMUX_STATE_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: (env["HOME"] ?? NSHomeDirectory()) + "/Library/Application Support/lmux", isDirectory: true)
        return base.appendingPathComponent("hooks-pristine", isDirectory: true)
    }

    /// The bytes a settings file had before lmux installed, and a digest of what lmux wrote.
    struct Pristine: Codable {
        var path: String
        /// nil: the file did not exist.
        var original: String?
        var installed: String

        static func digest(_ s: String) -> String {
            SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        static func file(_ dir: URL, _ path: String) -> URL {
            let key = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return dir.appendingPathComponent(String(digest(key).prefix(24)) + ".json")
        }
        static func load(_ dir: URL, _ path: String) -> Pristine? {
            guard let d = try? Data(contentsOf: file(dir, path)) else { return nil }
            return try? JSONDecoder().decode(Pristine.self, from: d)
        }
        static func save(_ dir: URL, _ path: String, original: String?, installed: String) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let url = file(dir, path)
            let rec = Pristine(path: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, original: original,
                               installed: installed)
            try PrivateFile.replace(url, JSONEncoder().encode(rec), mode: 0o600)
        }
        static func remove(_ dir: URL, _ path: String) { try? FileManager.default.removeItem(at: file(dir, path)) }
        /// Copies for other settings files that no longer hold what lmux installed there (edited,
        /// uninstalled by hand, deleted): nothing would restore them, and they keep old settings text.
        static func prune(_ dir: URL, keeping path: String) {
            let keep = file(dir, path).lastPathComponent
            let fm = FileManager.default
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension == "json" && f.lastPathComponent != keep {
                guard let d = try? Data(contentsOf: f), let rec = try? JSONDecoder().decode(Pristine.self, from: d),
                      let now = try? HookInstaller.read(rec.path), digest(now) == rec.installed else {
                    try? fm.removeItem(at: f)
                    continue
                }
            }
        }
    }

    /// The file's text with a UTF-8 BOM kept as a leading U+FEFF. Foundation's
    /// `String(contentsOfFile:encoding:)` drops the BOM, which would lose it on the way back out.
    public static func read(_ path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try decode(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func decode(_ data: Data) throws -> String {
        let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = hasBOM ? data.dropFirst(3) : data[...]
        let text = String(decoding: body, as: UTF8.self)
        guard text.utf8.elementsEqual(body) else {  // invalid UTF-8 was replaced: refuse, don't rewrite it
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return hasBOM ? bom + text : text
    }

    // MARK: Helpers

    private static func containsLmux(_ group: JSONValue) -> Bool {
        if case .array(let hs)? = group["hooks"] { return hs.contains(where: isLmuxHandler) }
        return false
    }

    /// Parse and check the shape Claude Code expects (root and `hooks` objects, arrays per event).
    private static func document(_ text: String, events: [String]) throws -> JSONText {
        let v = try JSONValue.parse(text)
        guard case .object(let rootMembers) = v else { throw InstallError.notAnObject("settings root") }
        if rootMembers.filter({ $0.key == "hooks" }).count > 1 { throw InstallError.duplicateKey("hooks") }
        if case .object(let hm)? = v["hooks"] {
            var seen = Set<String>()
            for m in hm where !seen.insert(m.key).inserted { throw InstallError.duplicateKey("hooks.\(m.key)") }
        }
        if let h = v["hooks"] {
            guard case .object(let hookEvents) = h else { throw InstallError.notAnObject("hooks") }
            for e in hookEvents where events.contains(e.key) {
                guard case .array = e.value else { throw InstallError.notAnObject("hooks.\(e.key)") }
            }
        }
        return try JSONText(text)
    }

    /// Remove lmux handlers from the event array at `path`; a group goes only if lmux emptied it.
    private static func strip(_ doc: inout JSONText, _ path: [JSONText.Step]) throws {
        guard let arr = doc.span(path), arr.kind == .array else { return }
        for gi in arr.elements.indices.reversed() {
            let g = try doc.value(arr.elements[gi])
            guard containsLmux(g), case .array(let hs)? = g["hooks"] else { continue }
            if hs.allSatisfy(isLmuxHandler) {
                try doc.removeElement(path, gi)
            } else {
                for hi in hs.indices.reversed() where isLmuxHandler(hs[hi]) {
                    try doc.removeElement(path + [.index(gi), .key("hooks")], hi)
                }
            }
        }
    }

    /// `strip`, and drop the event key if lmux's entries were all it had. True if anything changed.
    @discardableResult
    private static func removeLmux(_ doc: inout JSONText, event: String, keepEmpty: Bool = false) throws -> Bool {
        let path: [JSONText.Step] = [.key("hooks"), .key(event)]
        guard let arr = doc.span(path), arr.kind == .array,
              case .array(let groups) = try doc.value(arr), groups.contains(where: containsLmux) else { return false }
        try strip(&doc, path)
        if !keepEmpty, let after = doc.span(path), after.elements.isEmpty { try doc.removeMember([.key("hooks")], event) }
        return true
    }
}
