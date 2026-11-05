import AppKit
import Foundation
import LmuxHooks

/// The `lmux` CLI socket. One JSON request line per connection, one JSON
/// response line back:
///
///   {"cmd":"new-workspace","cwd":"/x","command":"make test","background":true} -> {"ok":true,"workspace":"..","pane":".."}
///   {"cmd":"send","pane":"<id>","text":"ls\n","token":".."}     -> {"ok":true}
///     (token = the caller's LMUX_PANE_NONCE; inside a pane, only that pane may be the target;
///      without a valid token only when the user turned on `allowExternalSend`, which also
///      gates `new-workspace` with a command)
///   {"cmd":"notify","text":"..","title":"..","pane":"<id>"}     -> {"ok":true}
///   {"cmd":"wait","target":"<pane or workspace id>","until":"done"} -> {"ok":true,"state":"done",..}
///     (answered when the target gets there: the connection stays open until then, see Wait.swift;
///      the client keeps it open both ways: an EOF, even a half-close after the request, ends the
///      wait unanswered; lmux quitting answers {"ok":true,"gone":true})
///
/// Runs on the main queue: requests are tiny and touch UI state. Only same-uid peers are served,
/// at most `maxClients` at a time (and `maxWaiting` waits), and a request over 1 MB is dropped as
/// soon as it is read.
public final class ControlServer {
    let path: String
    private let handle: ([String: Any]) -> [String: Any]
    /// `wait`: the request and its reply, answered later; returns what to do if the client leaves first.
    var handleWait: (([String: Any], @escaping ([String: Any]) -> Void) -> () -> Void)?
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clients: [Int32: (DispatchSourceRead, Data)] = [:]
    /// Connections whose `wait` isn't answered yet, and what ends that wait when they hang up.
    private var waiting: [Int32: (src: DispatchSourceRead, cancel: () -> Void)] = [:]
    private let maxRequestBytes = 1 << 20
    private let maxClients = 32
    private let maxWaiting = 64

    public enum StartError: Error { case alreadyRunning }

    public init(path: String, handle: @escaping ([String: Any]) -> [String: Any]) {
        self.path = path
        self.handle = handle
    }

    public func start() throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw NSError(domain: "lmux", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket path too long"])
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK {
            // A live server answers: that's another lmux. Only a stale socket is replaced.
            if let live = Self.connect(path) {
                close(live)
                throw StartError.alreadyRunning
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let rc = HookSocket.bindPrivately(fd, &addr)
        guard rc == 0, listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        chmod(path, 0o600)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.acceptAll(fd) }
        src.setCancelHandler { close(fd) }
        src.resume()
        listenFD = fd
        listenSource = src
    }

    static func connect(_ path: String) -> Int32? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(fd); return nil }
        return fd
    }

    /// A second launch: ask the running instance to come forward. True if one answered.
    /// Call off the main thread of the running app (tests) — it blocks up to 2s.
    public static func handOff(path: String) -> Bool {
        guard let fd = connect(path) else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let line = Array("{\"cmd\":\"activate\"}\n".utf8)
        guard write(fd, line, line.count) == line.count else { return false }
        var buf = [UInt8](repeating: 0, count: 256)
        let n = Darwin.read(fd, &buf, buf.count)
        return n > 0 && String(decoding: buf[0..<n], as: UTF8.self).contains("\"ok\":true")
    }

    /// The whole response, however large (`lmux list` with many panes is more than the socket
    /// buffer): sent without blocking the caller (`fd` is already O_NONBLOCK from `acceptAll`) —
    /// readiness-driven writes on `queue`, resumed each time the socket becomes writable again.
    /// Bounded by an overall 2s deadline, so a client that connects and never reads can't hang
    /// the app; `done` runs on `queue` exactly once, when the write finishes, fails, or times out.
    static func writeAll(_ fd: Int32, _ data: Data, queue: DispatchQueue = .main, done: @escaping () -> Void) {
        let src = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        var offset = 0
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            src.cancel()
            done()
        }
        src.setEventHandler {
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let base = buf.baseAddress else { return finish() }
                while offset < buf.count {
                    let n = write(fd, base + offset, buf.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EINTR { continue }
                    if n < 0, errno == EAGAIN { return }  // not writable yet: wait for the next event
                    return finish()  // n == 0 (peer gone), or a real error: give up
                }
                finish()
            }
        }
        src.setCancelHandler {}
        src.resume()
        queue.asyncAfter(deadline: .now() + 2, execute: finish)
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        for (_, c) in clients { c.0.cancel() }
        clients.removeAll()
        // Waits still open get their answer (lmux quit: the target is gone), written right away:
        // the process is about to end, a few bytes into an empty socket buffer don't block.
        let gone = Data("{\"ok\":true,\"gone\":true}\n".utf8)
        for (fd, w) in waiting {
            _ = gone.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            w.cancel()
            w.src.cancel()
        }
        waiting.removeAll()
        if listenFD >= 0 { unlink(path) }
        listenFD = -1
    }

    private func acceptAll(_ lfd: Int32) {
        while true {
            let cfd = accept(lfd, nil, nil)
            if cfd < 0 { return }
            guard clients.count < maxClients, HookSocket.peerIsSameUser(cfd) else { close(cfd); continue }
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL) | O_NONBLOCK)
            let src = DispatchSource.makeReadSource(fileDescriptor: cfd, queue: .main)
            src.setEventHandler { [weak self] in self?.read(cfd) }
            src.setCancelHandler { close(cfd) }
            clients[cfd] = (src, Data())
            src.resume()
        }
    }

    static func respond(_ fd: Int32, _ response: [String: Any], done: @escaping () -> Void) {
        var out = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"ok\":false}".utf8)
        out.append(0x0A)
        writeAll(fd, out, done: done)
    }

    private func answerWait(_ fd: Int32, _ response: [String: Any]) {
        guard let w = waiting.removeValue(forKey: fd) else { return }
        // Done reading: the read source is held still (a hung-up client's EOF would keep it firing
        // until the answer is out), then cancelled (closing the descriptor) once it's written.
        w.src.suspend()
        Self.respond(fd, response) {
            w.src.resume()
            w.src.cancel()
        }
    }

    /// A waiting client's connection is readable: anything it sends is read and dropped; its EOF
    /// (it hung up: its timeout, Ctrl-C) ends the wait unanswered.
    private func readWaiting(_ fd: Int32) {
        var sink = [UInt8](repeating: 0, count: 4096)
        var n = 0
        repeat { n = sink.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) } } while n > 0
        guard n == 0 || (errno != EAGAIN && errno != EINTR), let w = waiting.removeValue(forKey: fd) else { return }
        w.cancel()
        w.src.cancel()
    }

    private func read(_ fd: Int32) {
        guard case (let src, var buf)? = clients[fd] else {
            // Answered already (the response may still be going out): anything more the client
            // sends is discarded, so the read source doesn't keep firing on unread bytes.
            var sink = [UInt8](repeating: 0, count: 16 * 1024)
            while sink.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, $0.count) }) > 0 {}
            return
        }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var eof = false
        var tooBig = false
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let from = buf.endIndex
                buf.append(chunk, count: n)
                if buf[from...].contains(0x0A) { break }  // one request per connection: the rest is not read
                // Checked per read: a client can't make the app buffer more than the cap.
                if buf.count > maxRequestBytes { tooBig = true; break }
                continue
            }
            if n == 0 || (errno != EAGAIN && errno != EINTR) { eof = true }
            break
        }
        if tooBig {
            src.cancel()
            clients[fd] = nil
            return
        }
        if let nl = buf.firstIndex(of: 0x0A) ?? (eof && !buf.isEmpty ? buf.endIndex : nil) {
            let line = buf[buf.startIndex..<nl]
            var response: [String: Any]
            if var obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                // Who is asking (the kernel says, the client can't): pid of the peer process.
                var pid: pid_t = 0
                var len = socklen_t(MemoryLayout<pid_t>.size)
                obj["_peerpid"] = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 ? Int(pid) : 0
                if obj["cmd"] as? String == "wait", let handleWait {
                    clients[fd] = nil
                    guard waiting.count < maxWaiting else {
                        return Self.respond(fd, ["ok": false, "error": "too many waits"]) { src.cancel() }
                    }
                    // Until answered, the connection is only read for the client hanging up.
                    waiting[fd] = (src, {})
                    src.setEventHandler { [weak self] in self?.readWaiting(fd) }
                    let cancel = handleWait(obj) { [weak self] r in self?.answerWait(fd, r) }
                    if waiting[fd] != nil { waiting[fd]?.cancel = cancel }
                    return
                }
                response = handle(obj)
            } else {
                response = ["ok": false, "error": "malformed request"]
            }
            // Stop treating `fd` as a client right away (so a stray further read is a no-op);
            // `src` (and so `fd`, closed by its cancel handler) is kept alive by `writeAll`'s
            // completion closure until the async write finishes or its 2s deadline passes —
            // never by blocking this thread.
            clients[fd] = nil
            Self.respond(fd, response) { src.cancel() }
            return
        }
        if eof || buf.count > 1 << 20 {
            src.cancel()
            clients[fd] = nil
        } else {
            clients[fd] = (src, buf)
        }
    }
}

extension LmuxController {
    /// False only when another lmux already serves this socket.
    func startControlServer() -> Bool {
        let server = ControlServer(path: paths.controlSocket) { [weak self] req in
            MainActor.assumeIsolated { self?.handleControl(req) ?? ["ok": false, "error": "app is gone"] }
        }
        server.handleWait = { [weak self] req, reply in
            MainActor.assumeIsolated { self?.startWait(req, reply: reply) ?? {} }
        }
        do {
            try server.start()
            controlServer = server
        } catch ControlServer.StartError.alreadyRunning {
            NSLog("lmux: another lmux is running on %@", paths.controlSocket)
            return false
        } catch {
            NSLog("lmux: control socket not started: %@", "\(error)")
        }
        return true
    }

    static let externalSendOff = "typing into lmux from outside a pane is off (Settings > General > "
        + "Allow other apps to send input to lmux, or defaults write dev.lmux.app allowExternalSend -bool true)"

    public func handleControl(_ req: [String: Any]) -> [String: Any] {
        switch req["cmd"] as? String {
        case "new-workspace":
            let cwd = (req["cwd"] as? String).map { ($0 as NSString).expandingTildeInPath }
            if let cwd, !FileManager.default.fileExists(atPath: cwd) {
                return ["ok": false, "error": "no such directory: \(cwd)"]
            }
            let command = req["command"] as? String
            if command != nil, pane(token: req["token"] as? String) == nil, !allowExternalSend {
                return ["ok": false, "error": Self.externalSendOff]
            }
            // `background`: the row just appears; the user's view and focus stay where they are.
            let ws = newWorkspace(cwd: cwd, command: command, select: req["background"] as? Bool != true)
            return ["ok": true, "workspace": ws.id, "pane": ws.focusedPane?.id ?? ""]
        case "new-tab":
            // A tab in the given pane, else the calling one, else the focused one.
            let named = req["pane"] as? String
            guard let target = named.map({ self.pane(id: $0) }) ?? pane(token: req["token"] as? String) ?? model.selected?.focusedPane else {
                return ["ok": false, "error": "no such pane: \(named ?? "")"]
            }
            let command = req["command"] as? String
            if command != nil, pane(token: req["token"] as? String) == nil, !allowExternalSend {
                return ["ok": false, "error": Self.externalSendOff]
            }
            guard let tab = newTab(target, command: command, select: req["background"] as? Bool != true) else {
                return ["ok": false, "error": "no such pane: \(target.id)"]
            }
            return ["ok": true, "workspace": tab.workspace?.id ?? "", "pane": tab.id]
        case "list":
            return ["ok": true, "workspaces": model.workspaces.map { ws in
                ["id": ws.id, "title": ws.title, "selected": ws.id == model.selectedID,
                 "panes": ws.panes.map { p in
                     var e: [String: Any] = ["id": p.id, "title": p.headerTitle, "cwd": p.cwd ?? "", "state": p.display.stateName,
                                             "focused": ws.focusedPane === p, "claude": p.runsClaude,
                                             "agent": p.agentName ?? "", "session": p.claudeSessionID ?? "",
                                             "workspaceTitle": ws.title]
                     // One of several tabs of a pane: its place (1-based) and whether it's the one shown.
                     if let leaf = ws.root.find(p), leaf.hasTabs, let i = leaf.tabs.firstIndex(where: { $0 === p }) {
                         e["tab"] = i + 1
                         e["tabs"] = leaf.tabs.count
                         e["tabShown"] = leaf.shownTab === p
                     }
                     return e
                 }] as [String: Any]
            }]
        case "activate":
            activationRequests += 1
            reopenWindow()
            return ["ok": true]
        case "send":
            guard let pane = req["pane"] as? String, let text = req["text"] as? String else {
                return ["ok": false, "error": "send needs pane and text"]
            }
            switch send(text: text, toPane: pane, token: req["token"] as? String, peerPID: req["_peerpid"] as? Int) {
            case .sent: return ["ok": true]
            case .noSuchPane: return ["ok": false, "error": "no such pane: \(pane)"]
            case .crossPaneDenied:
                return ["ok": false, "error": "sending to another pane from inside lmux is off "
                        + "(defaults write dev.lmux.app allowCrossPaneSend -bool true)"]
            case .externalDenied:
                return ["ok": false, "error": Self.externalSendOff]
            case .paneBusy:
                return ["ok": false, "error": "that pane is busy rewinding Claude Code; try again in a moment"]
            }
        case "notify":
            guard let text = req["text"] as? String else { return ["ok": false, "error": "notify needs text"] }
            // The calling pane is the one its token names; LMUX_PANE_ID alone is only a hint.
            let from = callerPane(token: req["token"] as? String, peerPID: req["_peerpid"] as? Int)?.id ?? (req["pane"] as? String)
            notify(text: text, title: req["title"] as? String, paneID: from)
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown command"]
        }
    }
}
