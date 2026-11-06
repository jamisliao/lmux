import AppKit
import Foundation
import Observation

/// 管理 `<plugins 資料夾>/<名稱>/run`：啟動、透過 stdin/stdout 溝通（協定見 PluginProtocol.swift）、
/// 當掉時重啟、lmux 結束時一起關閉。每個 plugin 在 bar 上最多佔一行。
@MainActor @Observable
final class PluginHost {
    /// bar 上的一行：plugin 送來的內容，或它沒在跑的原因。
    struct Row: Identifiable, Equatable {
        let id: String
        var content: PluginRowContent?
        var problem: String?
    }

    /// 資料夾本身有問題（權限不安全）時那一行的 id。
    static let folderRowID = "plugins"
    /// 60 秒內結束這麼多次就不再重啟。
    static let maxExits = 3

    let dir: URL
    private let logDir: URL
    private let controlSocket: String
    private var states: [String: Row] = [:]
    @ObservationIgnored private var running: [String: Running] = [:]
    @ObservationIgnored private var exits: [String: [Date]] = [:]
    @ObservationIgnored private var pendingRestart: [String: DispatchWorkItem] = [:]

    /// 一個正在跑的 plugin 程序。
    private final class Running {
        let process: Process
        let input: Pipe
        var reader = PluginLineReader()
        /// lmux 主動停掉它（重新載入、lmux 結束），結束後不重啟。
        var stopping = false
        init(process: Process, input: Pipe) {
            self.process = process
            self.input = input
        }
    }

    /// 依名稱排序；只包含有內容或有問題的 plugin。
    var rows: [Row] {
        states.values.filter { $0.content != nil || $0.problem != nil }.sorted { $0.id < $1.id }
    }

    init(dir: URL, logDir: URL, controlSocket: String) {
        self.dir = dir
        self.logDir = logDir
        self.controlSocket = controlSocket
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    func logPath(_ name: String) -> String { logDir.appendingPathComponent("\(name).log").path }

    /// 停掉全部、重新掃描資料夾、全部重新啟動（右鍵選單的 Reload All Plugins，也是啟動時的第一次載入）。
    func reloadAll() {
        stopAll()
        exits.removeAll()
        states.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }  // 沒有資料夾：沒有 plugin，不顯示任何東西
        guard Self.isPrivate(dir.path, directory: true) else {
            states[Self.folderRowID] = Row(id: Self.folderRowID, problem: "unsafe permissions")
            return
        }
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for name in names {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue {
                launch(name)
            }
        }
    }

    /// 重新啟動一個 plugin（右鍵選單的 Restart，或點一下已停止的那一行）。
    func restart(_ name: String) {
        if name == Self.folderRowID { reloadAll(); return }
        stop(name)
        exits[name] = nil
        states[name] = Row(id: name)
        launch(name)
    }

    /// 使用者點了這一行：已停止就重啟，否則把點擊事件送給 plugin。
    func click(_ name: String) {
        if states[name]?.problem != nil { restart(name); return }
        guard let r = running[name] else { return }
        // 18 bytes，小於 PIPE_BUF：非阻塞寫入要嘛整行寫進去、要嘛 EAGAIN（plugin 沒在讀，丟掉這次點擊）。
        // plugin 已經結束時寫入只會失敗，F_SETNOSIGPIPE 讓 lmux 不會收到 SIGPIPE。
        let line = Array("{\"event\":\"click\"}\n".utf8)
        _ = line.withUnsafeBytes { Darwin.write(r.input.fileHandleForWriting.fileDescriptor, $0.baseAddress, $0.count) }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func launch(_ name: String) {
        let pluginDir = dir.appendingPathComponent(name)
        let run = pluginDir.appendingPathComponent("run")
        guard FileManager.default.fileExists(atPath: run.path) else { return }  // 沒有 run 的資料夾不算 plugin
        guard Self.isPrivate(pluginDir.path, directory: true), Self.isPrivate(run.path, directory: false),
              Darwin.access(run.path, X_OK) == 0 else {
            states[name] = Row(id: name, problem: "unsafe permissions or not executable")
            return
        }
        let process = Process()
        process.executableURL = run
        process.currentDirectoryURL = pluginDir
        var env = ProcessInfo.processInfo.environment
        // plugin 不在任何 pane 裡：不帶 pane 的身分；`lmux notify` 等指令透過 control socket 送到這個 lmux。
        for key in ["LMUX_PANE_ID", "LMUX_PANE_NONCE", "LMUX_PANE_TOKEN", "LMUX_SOCKET"] { env[key] = nil }
        env["LMUX_CONTROL_SOCKET"] = controlSocket
        env["LMUX_PLUGIN_NAME"] = name
        process.environment = env

        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = logHandle(name)
        let fd = input.fileHandleForWriting.fileDescriptor
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let r = Running(process: process, input: input)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF：不清掉 handler 的話會一直被叫（空轉吃 CPU）。
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, from: name, r) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(name, r) } }
        }
        do {
            try process.run()
        } catch {
            states[name] = Row(id: name, problem: "failed to start")
            return
        }
        running[name] = r
        if states[name] == nil { states[name] = Row(id: name) }
    }

    private func received(_ data: Data, from name: String, _ r: Running) {
        guard running[name] === r, !r.stopping else { return }
        switch r.reader.feed(data) {
        case .set(let content)?: states[name]?.content = content
        case .clear?: states[name]?.content = nil
        case nil: break
        }
    }

    private func exited(_ name: String, _ r: Running) {
        guard running[name] === r else { return }
        running[name] = nil
        try? r.input.fileHandleForWriting.close()
        if r.stopping { return }
        states[name]?.content = nil
        let now = Date()
        var recent = (exits[name] ?? []).filter { now.timeIntervalSince($0) < 60 }
        recent.append(now)
        exits[name] = recent
        if recent.count >= Self.maxExits {
            states[name] = Row(id: name, problem: "stopped")
            return
        }
        // 第 1 次結束後 1 秒、第 2 次後 2 秒再啟動。
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingRestart[name] = nil
                self?.launch(name)
            }
        }
        pendingRestart[name] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(1 << (recent.count - 1)), execute: work)
    }

    private func stop(_ name: String) {
        pendingRestart.removeValue(forKey: name)?.cancel()
        guard let r = running.removeValue(forKey: name) else { return }
        r.stopping = true
        try? r.input.fileHandleForWriting.close()  // stdin 收到 EOF：照約定 plugin 會自己結束
        if r.process.isRunning { r.process.terminate() }  // 沒照約定的也會收到 SIGTERM
    }

    private func stopAll() {
        for name in Array(running.keys) + Array(pendingRestart.keys) { stop(name) }
    }

    /// stderr 寫到 `<state dir>/plugins/<名稱>.log`，每次啟動時清空。
    // ponytail: 只在啟動時清空，plugin 長時間狂寫 stderr 會一直長大；需要時再改成輪替。
    private func logHandle(_ name: String) -> FileHandle {
        let fm = FileManager.default
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = logPath(name)
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        return FileHandle(forWritingAtPath: path) ?? FileHandle.nullDevice
    }

    /// 會被自動執行的東西必須屬於使用者本人，而且群組和其他人不能寫入（比照 LmuxPaths.secureStateDir）。
    static func isPrivate(_ path: String, directory: Bool) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o022 == 0 else { return false }
        return (st.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG)
    }
}
