// lmux: tiny CLI for a running lmux app (bundled as lmux.app/Contents/Resources/bin/lmux,
// which is on PATH inside lmux panes).
//
//   lmux new-workspace [--cwd DIR] [--cmd CMD] [--background]   (--background: not selected, the view stays)
//   lmux new-tab [--pane ID] [--cmd CMD] [--background]   (a tab in that pane; default: this one, else the focused one)
//   lmux send [--pane ID] TEXT      ("\n" in TEXT presses Return; default pane: $LMUX_PANE_ID)
//   lmux notify [--title T] TEXT    (attributed to $LMUX_PANE_ID when run inside a pane)
//   lmux list [--json]              workspaces and panes: ids, titles, cwd, agent state
//   lmux wait ID [--until S] [--timeout SECS] [--json]
//                                   block until a pane's (or workspace's) agent gets there, print it
//
// Talks to $LMUX_CONTROL_SOCKET, else the control socket of $LMUX_STATE_DIR (the app's own
// rule, see LmuxPaths.socketDir), else ~/Library/Application Support/lmux/control.sock.

import Foundation

let env = ProcessInfo.processInfo.environment

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: lmux new-workspace [--cwd DIR] [--cmd CMD] [--background]
           lmux new-tab [--pane ID] [--cmd CMD] [--background]
           lmux send [--pane ID] TEXT
           lmux notify [--title TITLE] TEXT
           lmux list [--json]
           lmux wait PANE|WORKSPACE [--until idle|done|needs-you|any] [--timeout SECS] [--json]

    """.utf8))
    exit(2)
}

/// `fail`'s exit status (`lmux wait` keeps 1 and 2 for timeout and target gone).
var failStatus: Int32 = 1

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("lmux: \(msg)\n".utf8))
    exit(failStatus)
}

/// Parses `--name value` options; returns them plus the remaining positional args.
func parse(_ args: ArraySlice<String>, options: Set<String>) -> ([String: String], [String]) {
    var opts: [String: String] = [:], rest: [String] = []
    var i = args.startIndex
    while i < args.endIndex {
        let a = args[i]
        if options.contains(a) {
            guard i + 1 < args.endIndex else { fail("\(a) needs a value") }
            opts[a] = args[i + 1]
            i += 2
        } else {
            rest.append(a)
            i += 1
        }
    }
    return (opts, rest)
}

/// `\n`, `\t`, `\\` escapes so `lmux send "ls\n"` works from any shell.
func unescape(_ s: String) -> String {
    var out = "", it = s.makeIterator()
    while let c = it.next() {
        guard c == "\\" else { out.append(c); continue }
        switch it.next() {
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "\\": out.append("\\")
        case let other?: out.append("\\"); out.append(other)
        case nil: out.append("\\")
        }
    }
    return out
}

func socketPath() -> String {
    if let p = env["LMUX_CONTROL_SOCKET"], !p.isEmpty { return p }
    let home = env["HOME"] ?? NSHomeDirectory()
    let state = env["LMUX_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/Library/Application Support/lmux"
    let direct = URL(fileURLWithPath: state).appendingPathComponent("control.sock").path
    if direct.utf8.count < 100 { return direct }
    // Same as LmuxPaths.socketDir: a long state dir keeps its sockets in /tmp/lmux-<uid>/<hash>.
    var h: UInt64 = 1469598103934665603
    for b in URL(fileURLWithPath: state).standardizedFileURL.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    let base = "/tmp/lmux-\(getuid())", dir = base + "/" + String(h, radix: 36)
    // Like the app: only dirs that are ours (not someone else's, not a symlink) are trusted.
    for d in [base, dir] {
        var st = stat()
        guard lstat(d, &st) == 0 else { break }  // missing: connect fails with "not running"
        guard st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o077 == 0 else {
            fail("refusing \(d): not a private directory of this user")
        }
    }
    return dir + "/control.sock"
}

/// A connection to the app's control socket with `obj` sent on it.
func connectAndSend(_ obj: [String: Any]) -> Int32 {
    let path = socketPath()
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { fail("socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket failed") }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { fail("lmux is not running (\(path))") }
    // A connection lmux refused (too many clients) is closed before the request is written: an
    // EPIPE then, never a SIGPIPE that kills the CLI with no message.
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var line = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    line.append(0x0A)
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return fd
}

/// One response line, waiting up to `timeout` seconds for it (nil: as long as it takes).
/// nil when it didn't come in time, an empty dictionary when the app hung up without one (or
/// refused the connection: too many clients) or answered something that isn't JSON.
func readResponse(_ fd: Int32, timeout: Double?) -> [String: Any]? {
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    var resp = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        // Blocked in poll(2) until the app answers: nothing runs meanwhile, here or in the app.
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = deadline.map { Int32(max(0, min(Double(Int32.max), $0.timeIntervalSinceNow * 1000))) } ?? -1
        let ready = poll(&p, 1, ms)
        if ready < 0, errno == EINTR { continue }
        if ready == 0 { return nil }
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        resp.append(buf, count: n)
        if resp.last == 0x0A { break }
    }
    return (try? JSONSerialization.jsonObject(with: resp) as? [String: Any]) ?? [:]
}

func request(_ obj: [String: Any]) -> [String: Any] {
    let fd = connectAndSend(obj)
    defer { close(fd) }
    guard let r = readResponse(fd, timeout: 5), !r.isEmpty else { fail("no response from lmux") }
    return r
}

/// `lmux wait`: exit 0 once the target got there (its state printed, then the reply of a done
/// turn or what the row says: the question asked, the error), 1 on --timeout, 2 when lmux says
/// the target is gone (or never was; lmux quit), 3 for any other error (no answer at all included).
func wait(_ args: ArraySlice<String>) -> Never {
    failStatus = 3
    let (o, rest) = parse(args, options: ["--until", "--timeout", "--pane"])
    let json = rest.contains("--json")
    let ids = rest.filter { $0 != "--json" } + (o["--pane"].map { [$0] } ?? [])
    guard ids.count == 1, let target = ids.first else { fail("wait needs one pane or workspace id (lmux list shows them)") }
    let until = o["--until"] ?? "settled"
    guard ["idle", "done", "needs-you", "any", "settled"].contains(until) else { fail("--until is idle, done, needs-you or any") }
    var timeout: Double?
    if let t = o["--timeout"] {
        guard let v = Double(t), v >= 0 else { fail("--timeout needs seconds") }
        timeout = max(v, 0.05)  // (time for lmux to answer at all: a state it's already in still counts)
    }
    let fd = connectAndSend(["cmd": "wait", "target": target, "until": until])
    guard let r = readResponse(fd, timeout: timeout) else {
        close(fd)  // (the app sees the hang-up and forgets the wait)
        FileHandle.standardError.write(Data("lmux: timed out waiting for \(target)\n".utf8))
        exit(1)
    }
    close(fd)
    guard !r.isEmpty else { fail("no response from lmux") }
    if r["gone"] as? Bool == true {
        FileHandle.standardError.write(Data("lmux: \(target) is gone\n".utf8))
        exit(2)
    }
    guard r["ok"] as? Bool == true else { fail(r["error"] as? String ?? "failed") }
    if json {
        var out = r
        out["ok"] = nil
        let d = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: d, as: UTF8.self))
    } else {
        // Then the reply of a done turn, else what the row says (the question asked, the error).
        print(clean(r["state"]))
        let reply = r["state"] as? String == "done" ? r["reply"] as? String ?? "" : ""
        let more = reply.isEmpty ? r["detail"] as? String ?? "" : reply
        if !more.isEmpty { print(clean(more, keepNewlines: true)) }
    }
    exit(0)
}

// Titles, cwds and replies come from programs in the panes: no control characters reach this terminal.
// Fast check (a pane's cwd can be megabytes): strcspn for C0, DEL and 0xC2 (C1 is 0xC2 0x80-0x9F).
let rejectAll: [CChar] = ((1...0x1F).map { $0 } + [0x7F, 0xC2]).map { CChar(bitPattern: UInt8($0)) } + [0]
let rejectButNewline = rejectAll.filter { $0 != 0x0A }
func clean(_ v: Any?, keepNewlines: Bool = false) -> String {
    let s = v as? String ?? ""
    guard s.withCString({ strcspn($0, keepNewlines ? rejectButNewline : rejectAll) }) != s.utf8.count else { return s }
    return String(String.UnicodeScalarView(s.unicodeScalars.map {
        ($0.value < 0x20 && !(keepNewlines && $0.value == 0x0A)) || (0x7F...0x9F).contains($0.value) ? "?" : $0
    }))
}

let args = CommandLine.arguments.dropFirst()
guard let cmd = args.first else { usage() }
var req: [String: Any]
switch cmd {
case "new-workspace":
    let (o, rest) = parse(args.dropFirst(), options: ["--cwd", "--cmd"])
    guard rest.allSatisfy({ $0 == "--background" }) else { usage() }
    req = ["cmd": "new-workspace"]
    if !rest.isEmpty { req["background"] = true }
    if let cwd = o["--cwd"] {
        req["cwd"] = URL(fileURLWithPath: cwd, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
    }
    if let c = o["--cmd"] { req["command"] = c }
case "new-tab":
    let (o, rest) = parse(args.dropFirst(), options: ["--pane", "--cmd"])
    guard rest.allSatisfy({ $0 == "--background" }) else { usage() }
    req = ["cmd": "new-tab", "background": !rest.isEmpty]
    if let p = o["--pane"] ?? env["LMUX_PANE_ID"].flatMap({ $0.isEmpty ? nil : $0 }) { req["pane"] = p }
    if let c = o["--cmd"] { req["command"] = c }
case "send":
    let (o, rest) = parse(args.dropFirst(), options: ["--pane"])
    guard !rest.isEmpty else { usage() }
    guard let pane = o["--pane"] ?? env["LMUX_PANE_ID"] else { fail("send needs --pane ID (or run it inside a lmux pane)") }
    req = ["cmd": "send", "pane": pane, "text": unescape(rest.joined(separator: " "))]
case "notify":
    let (o, rest) = parse(args.dropFirst(), options: ["--title"])
    guard !rest.isEmpty else { usage() }
    req = ["cmd": "notify", "text": rest.joined(separator: " ")]
    if let t = o["--title"] { req["title"] = t }
    if let p = env["LMUX_PANE_ID"], !p.isEmpty { req["pane"] = p }
case "list":
    req = ["cmd": "list"]
case "wait":
    wait(args.dropFirst())
case "-h", "--help", "help":
    usage()
default:
    usage()
}

// Which pane this runs in (absent outside lmux): lmux only lets a pane type into itself.
// LMUX_PANE_NONCE (Codex can strip *TOKEN* names from what it runs); LMUX_PANE_TOKEN for one more release.
if let t = [env["LMUX_PANE_NONCE"], env["LMUX_PANE_TOKEN"]].compactMap({ $0 }).first(where: { !$0.isEmpty }) { req["token"] = t }
let r = request(req)
guard r["ok"] as? Bool == true else { fail(r["error"] as? String ?? "failed") }
if cmd == "list" {
    let wss = r["workspaces"] as? [[String: Any]] ?? []
    if args.contains("--json") {
        let d = (try? JSONSerialization.data(withJSONObject: wss, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: d, as: UTF8.self))
    } else {
        for ws in wss {
            print("\((ws["selected"] as? Bool) == true ? "*" : " ") workspace \(clean(ws["id"]))  \(clean(ws["title"]))")
            for p in ws["panes"] as? [[String: Any]] ?? [] {
                // A tab of a pane: "tab 2/3" (* the one shown).
                let tab = (p["tab"] as? Int).map { "tab \($0)/\(p["tabs"] as? Int ?? 0)\((p["tabShown"] as? Bool) == true ? "*" : "")  " } ?? ""
                let agent = clean(p["agent"])
                print("    pane \(clean(p["id"]))  \(tab)\(clean(p["title"]))  [\(clean(p["state"]))]  \(clean(p["cwd"]))"
                      + (agent.isEmpty ? "" : "  (\(agent))"))
            }
        }
    }
}
if cmd == "new-workspace" || cmd == "new-tab" {
    print("workspace \(r["workspace"] as? String ?? "") pane \(r["pane"] as? String ?? "")")
}
