import Foundation

/// Where lmux keeps its state and sockets. Everything is overridable from the
/// environment so tests never touch the user's real files.
///
///   LMUX_STATE_DIR      state dir (default ~/Library/Application Support/lmux)
///   LMUX_BIN_DIR        dir holding `lmux` (CLI) and `lmux-hook` (default: lmux.app/Contents/Resources/bin)
///   LMUX_PANE_COMMAND   run this instead of the login shell in every pane (tests)
///
/// The app deliberately ignores LMUX_SOCKET / LMUX_PANE_ID from its own
/// environment: those belong to a parent lmux when lmux is launched from a pane.
public struct LmuxPaths {
    public var stateDir: URL
    public var binDir: URL?
    public var paneCommand: String?

    public init(environment env: [String: String] = ProcessInfo.processInfo.environment) {
        if let dir = env["LMUX_STATE_DIR"], !dir.isEmpty {
            stateDir = URL(fileURLWithPath: dir)
        } else {
            stateDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/lmux")
        }
        if let dir = env["LMUX_BIN_DIR"], !dir.isEmpty {
            binDir = URL(fileURLWithPath: dir)
        } else {
            binDir = Bundle.main.resourceURL.map { $0.appendingPathComponent("bin") }
        }
        paneCommand = env["LMUX_PANE_COMMAND"].flatMap { $0.isEmpty ? nil : $0 }
    }

    public var layoutFile: URL { stateDir.appendingPathComponent("layout.json") }
    /// Hook socket (LmuxHooks wire format). Same default as `HookSocket.defaultPath()`.
    public var hookSocket: String { socketDir.appendingPathComponent("lmux.sock").path }
    /// CLI control socket.
    public var controlSocket: String { socketDir.appendingPathComponent("control.sock").path }

    /// Where the sockets live: the state dir, unless its path is too long for a Unix socket
    /// (104 bytes on macOS), then a short per-user dir `/tmp/lmux-<uid>/<hash of the state dir>`
    /// (0700, must be ours), so a deep LMUX_STATE_DIR never silently disables agent state.
    public var socketDir: URL {
        if stateDir.appendingPathComponent("control.sock").path.utf8.count < 100 { return stateDir }
        var h: UInt64 = 1469598103934665603
        for b in stateDir.standardizedFileURL.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let base = URL(fileURLWithPath: "/tmp/lmux-\(getuid())", isDirectory: true)
        let dir = base.appendingPathComponent(String(h, radix: 36), isDirectory: true)
        let fm = FileManager.default
        for d in [base, dir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var st = stat()
            // Someone else's (or a symlinked) dir: fall back to the state dir (sockets fail loudly there).
            guard lstat(d.path, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFDIR else { return stateDir }
            if st.st_mode & 0o077 != 0 { chmod(d.path, 0o700) }
        }
        return dir
    }
    /// The state dir is a directory of this user (lstat; a symlink to one is followed once), made
    /// 0700. False when it belongs to someone else: lmux then starts nothing from it.
    public func secureStateDir() -> Bool {
        var st = stat()
        guard lstat(stateDir.path, &st) == 0, st.st_uid == getuid() else { return false }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            guard stat(stateDir.path, &st) == 0, st.st_uid == getuid() else { return false }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        if st.st_mode & 0o077 != 0 { return chmod(stateDir.path, 0o700) == 0 }
        return true
    }
    public var hookBinary: String? { binDir.map { $0.appendingPathComponent("lmux-hook").path } }
}
