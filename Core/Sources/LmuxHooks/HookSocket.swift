import Darwin
import Foundation

public enum HookSocket {
    /// `$LMUX_SOCKET`, else `~/Library/Application Support/lmux/lmux.sock`.
    public static func defaultPath(environment env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = env["LMUX_SOCKET"], !p.isEmpty { return p }
        let home = env["HOME"] ?? NSHomeDirectory()
        return home + "/Library/Application Support/lmux/lmux.sock"
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// The connected peer runs as this user (getpeereid). The socket files are 0600 in a 0700
    /// dir already; this also holds if either is ever loosened.
    public static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// bind(2) with umask 077, so the socket file is never briefly group/other accessible.
    public static func bindPrivately(_ fd: Int32, _ addr: inout sockaddr_un) -> Int32 {
        let old = umask(0o077)
        defer { umask(old) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}

// MARK: - Client (used by lmux-hook; Darwin calls only, no allocation-heavy work)

public enum HookClient {
    /// The process that ran the hook (Claude Code itself: the hook command `exec`s
    /// lmux-hook, so it is lmux-hook's parent), its process group, the process groups of
    /// its ancestors (a nested `claude -p` has the pane's foreground claude among them),
    /// and the configuration part of its environment (`CLAUDE_CONFIG_DIR=… claude`).
    public struct Origin: Sendable, Equatable {
        public var pid: Int32
        public var pgid: Int32
        public var ancestorGroups: [Int32]
        public var environment: [String: String]
        public init(pid: Int32, pgid: Int32, ancestorGroups: [Int32] = [], environment: [String: String] = [:]) {
            self.pid = pid
            self.pgid = pgid
            self.ancestorGroups = ancestorGroups
            self.environment = environment
        }

        /// lmux-hook's parent, its group, up to 8 ancestors' groups, and the replayable env.
        public static func current(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Origin {
            var pp = getppid()
            // A hook command that didn't `exec` (a pipeline, `sh -c` with more than one
            // command) leaves shell wrappers between Claude and lmux-hook: skip those in the
            // same process group, so the process reported is the one that ran the hook.
            for _ in 0..<4 {
                var info = proc_bsdinfo()
                let n = proc_pidinfo(pp, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { break }
                let parent = Int32(info.pbi_ppid)
                let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                guard shells.contains(comm), parent > 1, getpgid(parent) == getpgid(pp) else { break }
                pp = parent
            }
            var groups: [Int32] = []
            var cur = pp
            for _ in 0..<8 {
                var info = proc_bsdinfo()
                let n = proc_pidinfo(cur, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { break }
                let parent = Int32(info.pbi_ppid)
                guard parent > 1 else { break }
                groups.append(getpgid(parent))
                cur = parent
            }
            return Origin(pid: pp, pgid: getpgid(pp), ancestorGroups: groups,
                          environment: env.filter { replayable($0.key) })
        }
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]

    /// Environment variables replayed when a session is resumed: an explicit allowlist of
    /// non-secret settings that change which session or how it behaves (Claude Code docs,
    /// "Environment variables"). Nothing else is ever captured: not credentials, headers,
    /// URLs (they can carry user:pass@), certificates, proxies, or unknown names.
    ///   CLAUDE_CONFIG_DIR                       where the session lives; resume fails without it
    ///   ANTHROPIC_MODEL, ANTHROPIC_SMALL_FAST_MODEL, ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL,
    ///   CLAUDE_CODE_SUBAGENT_MODEL              model choice (a name, not a secret)
    ///   BASH_DEFAULT_TIMEOUT_MS, BASH_MAX_TIMEOUT_MS, MCP_TIMEOUT, MCP_TOOL_TIMEOUT   timeouts
    ///   CLAUDE_CODE_USE_BEDROCK, CLAUDE_CODE_USE_VERTEX   provider switch (0/1)
    ///   CODEX_HOME                              Codex CLI: where its sessions live; resume fails without it
    public static let replayableNames: Set<String> = [
        "CLAUDE_CONFIG_DIR", "CODEX_HOME",
        "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL",
        "BASH_DEFAULT_TIMEOUT_MS", "BASH_MAX_TIMEOUT_MS", "MCP_TIMEOUT", "MCP_TOOL_TIMEOUT",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
    ]

    /// Names that look like credentials are refused even if someone adds them to the list
    /// (so `*_TOKENS` budgets are not replayed either: the rule has no exceptions).
    static let credentialLike = try! NSRegularExpression(pattern: "KEY|TOKEN|SECRET|PASS|AUTH|HEADER|COOKIE|CREDENTIAL|URL|CERT")

    public static func replayable(_ name: String) -> Bool {
        replayableNames.contains(name)
            && credentialLike.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil
    }

    /// Wraps the raw hook stdin into one wire line. Returns nil if the payload is not a JSON object.
    /// `agent`: set for a non-Claude agent (`lmux-hook codex`), nil for Claude Code.
    public static func envelope(pane: String, payload: [UInt8], sentNanos: UInt64, process: Origin? = nil,
                                token: String? = nil, agent: AgentKind? = nil) -> [UInt8]? {
        var body = payload
        while let l = body.last, l == 0x20 || l == 0x0A || l == 0x0D || l == 0x09 { body.removeLast() }
        guard let first = body.firstIndex(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }),
              body[first] == UInt8(ascii: "{"), body.last == UInt8(ascii: "}") else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(body.count + pane.utf8.count + 64)
        out += Array(#"{"lmux":1,"pane":""#.utf8)
        appendEscaped(pane, to: &out)
        if let agent, agent != .claude { out += Array(#"","agent":""#.utf8) + Array(agent.rawValue.utf8) }
        if let token {
            out += Array(#"","token":""#.utf8)
            appendEscaped(token, to: &out)
        }
        out += Array(#"","sent_ns":"#.utf8)
        out += Array(String(sentNanos).utf8)
        if let process {
            out += Array(#","ppid":\#(process.pid),"ppgid":\#(process.pgid),"pgroups":["#.utf8)
            out += Array(process.ancestorGroups.map(String.init).joined(separator: ",").utf8)
            out += Array("],\"penv\":{".utf8)
            for (i, kv) in process.environment.sorted(by: { $0.key < $1.key }).enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                out.append(UInt8(ascii: "\""))
                appendEscaped(kv.key, to: &out)
                out += Array("\":\"".utf8)
                appendEscaped(kv.value, to: &out)
                out.append(UInt8(ascii: "\""))
            }
            out.append(UInt8(ascii: "}"))
        }
        out += Array(#","hook":"#.utf8)
        // Raw newlines can only appear between JSON tokens, so flattening them is safe.
        for b in body[first...] { out.append(b == 0x0A || b == 0x0D ? 0x20 : b) }
        out += Array("}\n".utf8)
        return out
    }

    static func appendEscaped(_ s: String, to out: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "\""): out += [0x5C, b]
            case UInt8(ascii: "\\"): out += [0x5C, b]
            case 0..<0x20: out += Array("\\u00".utf8) + [hex[Int(b >> 4)], hex[Int(b & 0xF)]]
            default: out.append(b)
            }
        }
    }

    /// Fire-and-forget send. Never blocks longer than `connectTimeoutMs + writeTimeoutMs`.
    @discardableResult
    public static func send(_ bytes: [UInt8], socketPath: String,
                            connectTimeoutMs: Int32 = 50, writeTimeoutMs: Int32 = 100) -> Bool {
        guard var addr = HookSocket.makeAddress(socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else { return false }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, connectTimeoutMs) == 1 else { return false }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return false }
        }

        var sent = 0
        let deadline = monotonicMillis() + Int64(writeTimeoutMs)
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EAGAIN || errno == EINTR {
                let left = deadline - monotonicMillis()
                guard left > 0 else { return false }
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&p, 1, Int32(left)) == 1 else { return false }
                continue
            }
            return false
        }
        return true
    }

    static func monotonicMillis() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)
    }
}

// MARK: - Server (used by the app)

/// Listens on a Unix socket for newline-delimited lmux-hook lines.
/// Malformed lines are reported to `onError` (their size only, never their content) and skipped;
/// the connection keeps going. Only peers of the same uid are served, at most `maxClients` at a
/// time, and a line longer than 8 MB drops its connection as soon as it is read.
public final class HookSocketServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable {
        case pathTooLong
        case alreadyRunning
        case notASocket(String)
        case posix(String, Int32)
    }

    public let path: String
    private let queue: DispatchQueue
    private let onEvent: @Sendable (HookEvent) -> Void
    private let onError: (@Sendable (String) -> Void)?
    private let maxLineBytes = 8 << 20
    private let maxClients = 64

    // Mutated only on `queue`.
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]

    public init(path: String = HookSocket.defaultPath(),
                queue: DispatchQueue = DispatchQueue(label: "lmux.hook-server"),
                onEvent: @escaping @Sendable (HookEvent) -> Void,
                onError: (@Sendable (String) -> Void)? = nil) {
        self.path = path
        self.queue = queue
        self.onEvent = onEvent
        self.onError = onError
    }

    public func start() throws {
        try queue.sync { try startLocked() }
    }

    public func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            for (_, c) in clients { c.source.cancel() }
            clients.removeAll()
            if listenFD >= 0 { unlink(path) }
            listenFD = -1
        }
    }

    deinit { listenSource?.cancel() }

    private func startLocked() throws {
        guard var addr = HookSocket.makeAddress(path) else { throw ServerError.pathTooLong }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Remove a stale socket, but never a regular file, and never a live server's socket.
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw ServerError.notASocket(path) }
            if HookClient.send([], socketPath: path, connectTimeoutMs: 50) { throw ServerError.alreadyRunning }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.posix("socket", errno) }
        let rc = HookSocket.bindPrivately(fd, &addr)
        guard rc == 0 else { let e = errno; close(fd); throw ServerError.posix("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 128) == 0 else { let e = errno; close(fd); throw ServerError.posix("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [unowned self] in self.acceptAll(fd) }
        src.setCancelHandler { close(fd) }
        src.resume()
        listenFD = fd
        listenSource = src
    }

    private func acceptAll(_ lfd: Int32) {
        while true {
            let cfd = accept(lfd, nil, nil)
            if cfd < 0 { return }  // EAGAIN: drained
            guard clients.count < maxClients, HookSocket.peerIsSameUser(cfd) else { close(cfd); continue }
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL) | O_NONBLOCK)
            let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: queue)
            src.setEventHandler { [unowned self] in self.readClient(cfd) }
            src.setCancelHandler { close(cfd) }
            clients[cfd] = (src, Data())
            src.resume()
        }
    }

    private func readClient(_ fd: Int32) {
        guard var client = clients[fd] else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var eof = false
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                // Complete lines go out as they arrive; only the unfinished tail is kept (one
                // compaction per read, searched from the new bytes on), so a sender can't make the
                // buffer grow past the cap or cost quadratic time.
                let scanFrom = client.buffer.endIndex
                client.buffer.append(chunk, count: n)
                var start = client.buffer.startIndex
                var from = scanFrom
                while let nl = client.buffer[from...].firstIndex(of: 0x0A) {
                    deliver(Data(client.buffer[start..<nl]))
                    start = nl + 1
                    from = start
                }
                if start > client.buffer.startIndex { client.buffer.removeSubrange(client.buffer.startIndex..<start) }
                if client.buffer.count > maxLineBytes {
                    onError?("line exceeds \(maxLineBytes) bytes; dropping connection")
                    client.buffer.removeAll()
                    eof = true
                    break
                }
                continue
            }
            if n == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { eof = true }
            break
        }
        if eof {
            if !client.buffer.isEmpty { deliver(client.buffer) }  // tolerate missing final newline
            client.source.cancel()
            clients[fd] = nil
        } else {
            clients[fd] = client
        }
    }

    private func deliver(_ line: Data) {
        guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { return }
        do {
            var event = try HookEvent.parse(line: line)
            event.receivedAtNanos = unixNanosNow()
            onEvent(event)
        } catch {
            onError?("malformed line (\(error), \(line.count) bytes)")
        }
    }
}
