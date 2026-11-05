import Foundation
import LmuxHooks

// lmux-hook                      hook mode (invoked by Claude Code; reads hook JSON on stdin)
// lmux-hook codex                hook mode for Codex CLI (same, events tagged "codex")
// lmux-hook install   [--codex] [--settings <path>] [--hook-path <path>] [--dry-run]
// lmux-hook uninstall [--codex] [--settings <path>] [--dry-run]
// lmux-hook status    [--codex] [--settings <path>]
//
// --codex edits $CODEX_HOME/hooks.json (default ~/.codex/hooks.json) instead of Claude Code's settings.json.
//
// Hook mode never writes to stdout and always exits 0.

func runHookMode(agent: AgentKind? = nil) -> Never {
    let startNanos = clock_gettime_nsec_np(CLOCK_REALTIME)
    signal(SIGPIPE, SIG_IGN)
    guard let paneC = getenv("LMUX_PANE_ID"), paneC.pointee != 0 else { exit(0) }
    guard isatty(STDIN_FILENO) == 0 else { exit(0) }

    var input: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let n = buf.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
        if n > 0 { input.append(contentsOf: buf[0..<n]); continue }
        if n < 0, errno == EINTR { continue }
        break
    }

    // The pane's secret: the app drops events for a pane that don't carry its token. LMUX_PANE_NONCE
    // (Codex can strip *TOKEN* names from what it runs); LMUX_PANE_TOKEN still read for one release.
    func variable(_ name: String) -> String? { getenv(name).flatMap { $0.pointee != 0 ? String(cString: $0) : nil } }
    let token = variable("LMUX_PANE_NONCE") ?? variable("LMUX_PANE_TOKEN")
    if let line = HookClient.envelope(pane: String(cString: paneC), payload: input, sentNanos: startNanos,
                                       process: .current(), token: token, agent: agent) {
        let path = getenv("LMUX_SOCKET").flatMap { $0.pointee != 0 ? String(cString: $0) : nil }
            ?? HookSocket.defaultPath()
        HookClient.send(line, socketPath: path)
    }
    exit(0)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("lmux-hook: \(msg)\n".utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    return args[i + 1]
}

func showDiff(_ change: HookInstaller.Change) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lmux-diff-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("before.json"), b = dir.appendingPathComponent("after.json")
    try? Data((change.before ?? "").utf8).write(to: a)
    try? Data(change.after.utf8).write(to: b)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    p.arguments = ["-u", "--label", change.path, "--label", change.path + " (lmux)", a.path, b.path]
    try? p.run()
    p.waitUntilExit()
}

func selfPath() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    return URL(fileURLWithPath: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().path
}

let args = Array(CommandLine.arguments.dropFirst())
guard let sub = args.first else { runHookMode() }
if sub == AgentKind.codex.rawValue { runHookMode(agent: .codex) }

let codex = args.contains("--codex")
let target = codex ? CodexHookInstaller.target : .claude
let settings = option("--settings", in: args) ?? (codex ? CodexHookInstaller.defaultHooksPath() : HookInstaller.defaultSettingsPath())
let dryRun = args.contains("--dry-run")

do {
    switch sub {
    case "install", "uninstall":
        let change = sub == "install"
            ? try HookInstaller.planInstall(settingsPath: settings, hookPath: option("--hook-path", in: args) ?? selfPath(),
                                            target: target)
            : try HookInstaller.planUninstall(settingsPath: settings, target: target)
        if !change.changed { print("\(settings): no changes (\(sub == "install" ? "already installed" : "nothing to remove"))"); exit(0) }
        if dryRun { showDiff(change); exit(0) }
        try HookInstaller.apply(change)
        print("\(settings): lmux hooks \(sub == "install" ? "installed" : "removed")")
        if codex, sub == "install" {
            print("Codex asks once to trust new hooks: choose \"Trust all and continue\" (until then they don't run)")
        }
    case "status":
        let s = try HookInstaller.status(of: try? HookInstaller.read(settings), target: target)
        print("settings: \(settings)")
        print("installed: \(s.installedEvents.isEmpty ? "-" : s.installedEvents.joined(separator: ", "))")
        print("missing:   \(s.missingEvents.isEmpty ? "-" : s.missingEvents.joined(separator: ", "))")
        for c in s.commands { print("command:   \(c)") }
        if codex {
            switch CodexHookInstaller.trust(hooksPath: settings, configPath: CodexHookInstaller.configPath()) {
            case .trusted: print("trust:     trusted in Codex")
            case .needsReview(let n): print("trust:     \(n) not trusted yet (Codex asks on its next start)")
            case .notInstalled: break
            }
        }
        exit(s.isComplete ? 0 : 3)
    case "-h", "--help", "help":
        print("usage: lmux-hook [install|uninstall|status] [--codex] [--settings <path>] [--hook-path <path>] [--dry-run]")
    default:
        // Unknown args in hook context must still never break claude.
        runHookMode()
    }
} catch {
    fail("\(error)")
}
