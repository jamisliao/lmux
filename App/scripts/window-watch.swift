// Test hygiene: no test window may ever reach a display, and no test process may show up in
// the Dock / ⌘Tab. Polls the window server every 50 ms while a harness runs (apptest.sh).
//
//   window-watch ROOT_PID OUT [STOP_FILE]
//     watches every process descended from ROOT_PID; each window of theirs whose bounds meet
//     a display, and each of them with a regular (Dock) activation policy, is written to OUT
//     once. Stops when STOP_FILE exists or ROOT_PID is gone. OUT empty = clean.
//   window-watch --all OUT [STOP_FILE]
//     same for every process named lmux* not running from /Applications (manual audits).

import AppKit
import Darwin

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write("usage: window-watch ROOT_PID|--all OUT [STOP_FILE]\n".data(using: .utf8)!); exit(2) }
let all = args[1] == "--all"
let root = pid_t(args[1]) ?? 0
let out = args[2]
let stop = args.count > 3 ? args[3] : nil
FileManager.default.createFile(atPath: out, contents: nil)
let fh = FileHandle(forWritingAtPath: out)!
let me = getpid()

func parent(_ p: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let n = proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return n == MemoryLayout<proc_bsdinfo>.size ? pid_t(info.pbi_ppid) : 0
}
/// The process's command line (which harness mode it is), for the report.
func command(_ p: pid_t) -> String {
    var mib = [CTL_KERN, KERN_PROCARGS2, p], size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var parts = buf[4..<size].split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    parts.removeFirst()  // the exec path
    return parts.prefix(argc).map { ($0 as NSString).lastPathComponent }.joined(separator: " ")
}
func path(_ p: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(p, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}
var watchedCache: [pid_t: Bool] = [:]
func watched(_ p: pid_t) -> Bool {
    if p == me { return false }
    if let w = watchedCache[p] { return w }
    let w: Bool
    if all {
        let exe = path(p)
        w = (exe as NSString).lastPathComponent.hasPrefix("lmux") && !exe.hasPrefix("/Applications/")
    } else {
        var q = p, hops = 0
        while q > 1 && q != root && hops < 64 { q = parent(q); hops += 1 }
        w = q == root
    }
    watchedCache[p] = w
    return w
}
func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    return Array(pids.prefix(Int(max(got, 0))))
}
func displays() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).map { CGDisplayBounds($0) }
}

var seen = Set<String>()
func report(_ key: String, _ line: String) {
    guard seen.insert(key).inserted else { return }
    let ts = String(format: "%.2f", Date().timeIntervalSince1970)
    fh.write("\(ts) \(line)\n".data(using: .utf8)!)
}

var tick = 0
while true {
    if let stop, FileManager.default.fileExists(atPath: stop) { break }
    if !all && kill(root, 0) != 0 { break }
    let screens = displays()
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, watched(pid),
              (w[kCGWindowIsOnscreen as String] as? Bool) == true,
              let b = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b),
              r.width > 0, r.height > 0, screens.contains(where: { $0.intersects(r) }) else { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        let name = w[kCGWindowName as String] as? String ?? ""
        report("w\(pid).\(num)", "WINDOW \(owner) pid=\(pid) [\(command(pid))] #\(num) layer=\(layer) alpha=\(alpha) bounds=\(r) name=\(name)")
    }
    // The Dock / ⌘Tab: a regular activation policy (checked every 4th tick, ~200 ms).
    if tick % 4 == 0 {
        for p in allPids() where p > 0 && watched(p) {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
                report("d\(p)", "DOCK pid=\(p) [\(command(p))] activationPolicy=regular")
            }
        }
    }
    tick += 1
    usleep(50_000)
}
