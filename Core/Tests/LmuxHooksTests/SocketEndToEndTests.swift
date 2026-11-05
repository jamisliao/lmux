import Foundation
import Testing
@testable import LmuxHooks

final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(HookEvent, UInt64)] = []
    private(set) var errors: [String] = []
    private let sem = DispatchSemaphore(value: 0)

    func add(_ e: HookEvent) {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        lock.withLock { events.append((e, now)) }
        sem.signal()
    }
    func addError(_ s: String) { lock.withLock { errors.append(s) }; sem.signal() }
    func wait(count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while lock.withLock({ events.count + errors.count }) < count {
            if sem.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return false }
        }
        return true
    }
    var received: [(HookEvent, UInt64)] { lock.withLock { events } }
    var errorList: [String] { lock.withLock { errors } }
}

/// `.build/<triple>/debug/lmux-hook`, next to the test bundle.
func hookBinary() throws -> URL {
    for b in Bundle.allBundles where b.bundlePath.hasSuffix(".xctest") {
        let u = b.bundleURL.deletingLastPathComponent().appendingPathComponent("lmux-hook")
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let u = root.appendingPathComponent(".build/debug/lmux-hook")
    guard FileManager.default.isExecutableFile(atPath: u.path) else {
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: u.path])
    }
    return u
}

func tempSocketPath() -> String {
    // sun_path is 104 bytes; keep it short.
    "/tmp/lmux-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
}

/// Runs lmux-hook like Claude Code does; returns (exit status, stdout bytes, wall ms, spawn time).
@discardableResult
func runHook(_ bin: URL, stdin: String, env: [String: String]) throws -> (Int32, Data, Double, UInt64) {
    let p = Process()
    p.executableURL = bin
    p.environment = env
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = FileHandle.nullDevice
    let t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    try p.run()
    inPipe.fileHandleForWriting.write(Data(stdin.utf8))
    try inPipe.fileHandleForWriting.close()
    p.waitUntilExit()
    let t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    let out = outPipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, out, Double(t1 - t0) / 1e6, t0)
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

@Suite(.serialized) struct SocketEndToEndTests {
    @Test func cliDeliversEventToServer() throws {
        let path = tempSocketPath()
        let inbox = Inbox()
        let server = HookSocketServer(path: path, onEvent: inbox.add, onError: inbox.addError)
        try server.start()
        defer { server.stop() }

        let (status, out, _, _) = try runHook(try hookBinary(), stdin: Payloads.notifPermission,
                                              env: ["LMUX_PANE_ID": "pane-42", "LMUX_SOCKET": path])
        #expect(status == 0)
        #expect(out.isEmpty)
        #expect(inbox.wait(count: 1))
        let e = try #require(inbox.received.first?.0)
        #expect(e.paneID == "pane-42" && e.kind == .notification && e.notificationType == "permission_prompt")
        #expect(e.sentAtNanos != nil && e.receivedAtNanos != nil)
        #expect(inbox.errorList.isEmpty)
    }

    @Test func cliIsSilentNoOpWithoutPaneOrServer() throws {
        let bin = try hookBinary()
        // No LMUX_PANE_ID: exit 0, no output, nothing sent.
        let path = tempSocketPath()
        let inbox = Inbox()
        let server = HookSocketServer(path: path, onEvent: inbox.add, onError: inbox.addError)
        try server.start()
        defer { server.stop() }
        let r1 = try runHook(bin, stdin: Payloads.stop, env: ["LMUX_SOCKET": path])
        #expect(r1.0 == 0 && r1.1.isEmpty)
        // Pane set but no server listening.
        let r2 = try runHook(bin, stdin: Payloads.stop, env: ["LMUX_PANE_ID": "p", "LMUX_SOCKET": "/tmp/lmux-nope-\(getpid()).sock"])
        #expect(r2.0 == 0 && r2.1.isEmpty)
        // Garbage stdin.
        let r3 = try runHook(bin, stdin: "not json", env: ["LMUX_PANE_ID": "p", "LMUX_SOCKET": path])
        #expect(r3.0 == 0 && r3.1.isEmpty)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(inbox.received.isEmpty)
    }

    @Test func serverSurvivesMalformedLinesAndConcurrentClients() throws {
        let path = tempSocketPath()
        let inbox = Inbox()
        let server = HookSocketServer(path: path, onEvent: inbox.add, onError: inbox.addError)
        try server.start()
        defer { server.stop() }

        let good = { (pane: String) in HookClient.envelope(pane: pane, payload: Array(Payloads.stop.utf8), sentNanos: 0)! }
        // One connection mixing garbage, a good line, a valid-JSON-but-wrong line, and a final line without newline.
        var mixed = Array("garbage\n".utf8) + good("a") + Array("{\"pane\":\"x\"}\n\n".utf8)
        mixed += good("b").dropLast()
        #expect(HookClient.send(mixed, socketPath: path))

        DispatchQueue.concurrentPerform(iterations: 64) { i in
            _ = HookClient.send(good("c\(i)"), socketPath: path)
        }
        #expect(inbox.wait(count: 2 + 2 + 64))
        let panes = Set(inbox.received.map(\.0.paneID))
        #expect(panes.isSuperset(of: ["a", "b"]))
        #expect(panes.count == 66)
        #expect(inbox.errorList.count == 2)
    }

    @Test func refusesToStealLiveSocketOrClobberFile() throws {
        let path = tempSocketPath()
        let s1 = HookSocketServer(path: path, onEvent: { _ in })
        try s1.start()
        defer { s1.stop() }
        #expect(throws: HookSocketServer.ServerError.alreadyRunning) {
            try HookSocketServer(path: path, onEvent: { _ in }).start()
        }
        let file = "/tmp/lmux-test-file-\(getpid())"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        defer { unlink(file) }
        #expect(throws: HookSocketServer.ServerError.notASocket(file)) {
            try HookSocketServer(path: file, onEvent: { _ in }).start()
        }
    }

    /// Latency proof: process spawn -> event delivered by the server.
    @Test func latency() throws {
        let bin = try hookBinary()
        let path = tempSocketPath()
        let inbox = Inbox()
        let server = HookSocketServer(path: path, onEvent: inbox.add)
        try server.start()
        defer { server.stop() }

        let env = ["LMUX_PANE_ID": "lat", "LMUX_SOCKET": path]
        try runHook(bin, stdin: Payloads.preBash, env: env)  // warm up
        #expect(inbox.wait(count: 1))

        let n = 50
        var e2e: [Double] = [], wall: [Double] = []
        for i in 0..<n {
            let (_, _, ms, t0) = try runHook(bin, stdin: Payloads.preBash, env: env)
            #expect(inbox.wait(count: i + 2))
            e2e.append(Double(inbox.received[i + 1].1 - t0) / 1e6)
            wall.append(ms)
        }
        var noSocket: [Double] = [], noPane: [Double] = []
        for _ in 0..<n {
            noSocket.append(try runHook(bin, stdin: Payloads.preBash,
                                        env: ["LMUX_PANE_ID": "lat", "LMUX_SOCKET": "/tmp/lmux-none-\(getpid()).sock"]).2)
            noPane.append(try runHook(bin, stdin: Payloads.preBash, env: [:]).2)
        }
        func fmt(_ xs: [Double]) -> String {
            String(format: "p50 %.2fms p95 %.2fms max %.2fms", percentile(xs, 0.5), percentile(xs, 0.95), xs.max()!)
        }
        print("[lmux latency] spawn->event received (n=\(n)): \(fmt(e2e))")
        print("[lmux latency] hook process wall, app running: \(fmt(wall))")
        print("[lmux latency] hook process wall, no socket:   \(fmt(noSocket))")
        print("[lmux latency] hook process wall, no pane id:  \(fmt(noPane))")
        #expect(percentile(e2e, 0.95) < 100)
        #expect(percentile(noSocket, 0.95) < 100)
    }
}
