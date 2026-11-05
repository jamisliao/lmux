import Foundation
import Testing
@testable import LmuxHooks
import LmuxPrivateFile

/// Security regressions: the pane token on the wire, per-read caps, malformed lines never logged,
/// settings.json writes with a private mode, stale pristine copies pruned.
@Suite struct HookSecurityTests {
    @Test func envelopeCarriesThePaneToken() throws {
        let line = try #require(HookClient.envelope(pane: "P", payload: Array(#"{"hook_event_name":"Stop"}"#.utf8),
                                                    sentNanos: 1, token: "t\"ok"))
        let e = try HookEvent.parse(line: Data(line))
        #expect(e.paneToken == "t\"ok" && e.paneID == "P")
        let none = try HookEvent.parse(line: Data(HookClient.envelope(pane: "P", payload: Array(#"{"hook_event_name":"Stop"}"#.utf8),
                                                                      sentNanos: 1)!))
        #expect(none.paneToken == nil)
    }

    /// LMUX_PANE_NONCE (Codex's shell_environment_policy can strip *TOKEN* names); the old
    /// LMUX_PANE_TOKEN is still read for one release, the new name winning when both are set.
    @Test(arguments: [
        (["LMUX_PANE_NONCE": "secret-nonce"], "secret-nonce"),
        (["LMUX_PANE_TOKEN": "secret-token"], "secret-token"),
        (["LMUX_PANE_NONCE": "secret-nonce", "LMUX_PANE_TOKEN": "old"], "secret-nonce"),
    ])
    func hookBinarySendsThePaneNonce(_ vars: [String: String], _ sent: String) throws {
        let bin = try hookBinary()
        let path = tempSocketPath()
        let inbox = Inbox()
        let server = HookSocketServer(path: path, onEvent: { inbox.add($0) })
        try server.start()
        defer { server.stop() }
        try runHook(bin, stdin: #"{"hook_event_name":"Stop","session_id":"s"}"#,
                    env: ["LMUX_PANE_ID": "P", "LMUX_SOCKET": path].merging(vars) { $1 })
        #expect(inbox.wait(count: 1))
        #expect(inbox.received.first?.0.paneToken == sent)
    }

    @Test func oversizedLineIsDroppedPerReadAndNeverLogged() throws {
        let path = tempSocketPath()
        let inbox = Inbox()
        let server = HookSocketServer(path: path, onEvent: { inbox.add($0) }, onError: { inbox.addError($0) })
        try server.start()
        defer { server.stop() }
        // Malformed: reported by size, never by content.
        #expect(HookClient.send(Array("not json SECRET-PAYLOAD\n".utf8), socketPath: path))
        #expect(inbox.wait(count: 1))
        #expect(inbox.errorList.allSatisfy { !$0.contains("SECRET") })
        // 24 MB without a newline: the server closes the connection after ~8 MB, mid-send.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = try #require(HookSocket.makeAddress(path))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(rc == 0)
        let block = [UInt8](repeating: 0x61, count: 64 * 1024)
        var sent = 0, dropped = false
        while sent < 24 << 20 {
            let n = block.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { dropped = true; break }
            sent += n
        }
        #expect(dropped && sent < 16 << 20, "sent \(sent)")
        // Still serving others.
        let ok = HookClient.envelope(pane: "P", payload: Array(#"{"hook_event_name":"Stop"}"#.utf8), sentNanos: 1)!
        #expect(HookClient.send(ok, socketPath: path))
        #expect(inbox.wait(count: 3))
    }

    @Test func manyLinesInOneReadAllArrive() throws {
        let path = tempSocketPath()
        let inbox = Inbox()
        let server = HookSocketServer(path: path, onEvent: { inbox.add($0) })
        try server.start()
        defer { server.stop() }
        var all: [UInt8] = []
        for i in 0..<2000 {
            all += HookClient.envelope(pane: "P\(i)", payload: Array(#"{"hook_event_name":"Stop"}"#.utf8), sentNanos: 1)!
        }
        #expect(HookClient.send(all, socketPath: path, writeTimeoutMs: 2000))
        #expect(inbox.wait(count: 2000, timeout: 10))
        #expect(inbox.received.map(\.0.paneID) == (0..<2000).map { "P\($0)" })
    }

    @Test func socketIsPrivateFromBind() throws {
        let path = tempSocketPath()
        let server = HookSocketServer(path: path, onEvent: { _ in })
        let old = umask(0)
        defer { umask(old) }
        try server.start()
        defer { server.stop() }
        #expect(PrivateFile.mode(of: path).map { $0 & 0o777 } == 0o600)
    }

    @Test func settingsWritesKeepModeNewFilesPrivate() throws {
        let dir = TestTemp.dir("sec-install")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let state = dir.appendingPathComponent("pristine", isDirectory: true)
        let fresh = dir.appendingPathComponent("new/settings.json").path
        try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: fresh, hookPath: "/x/lmux-hook"), pristineDirectory: state)
        #expect(PrivateFile.mode(of: fresh) == 0o600)
        let shared = dir.appendingPathComponent("settings.json").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: shared))
        chmod(shared, 0o640)
        try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: shared, hookPath: "/x/lmux-hook"), pristineDirectory: state)
        #expect(PrivateFile.mode(of: shared) == 0o640)
        // The first file was edited by hand since: its pristine copy can't be used any more and goes.
        try Data("{\"edited\":true}".utf8).write(to: URL(fileURLWithPath: fresh))
        let other = dir.appendingPathComponent("third.json").path
        try HookInstaller.apply(try HookInstaller.planInstall(settingsPath: other, hookPath: "/x/lmux-hook"), pristineDirectory: state)
        let kept = try FileManager.default.contentsOfDirectory(atPath: state.path).sorted()
        #expect(kept.count == 2, "\(kept)")
        #expect(HookInstaller.Pristine.load(state, fresh) == nil)
        #expect(HookInstaller.Pristine.load(state, shared) != nil && HookInstaller.Pristine.load(state, other) != nil)
    }
}
