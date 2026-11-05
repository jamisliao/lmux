import Foundation
import LmuxSessions

/// The heavy History work (parsing every transcript on a first index, compressing them
/// into the archive) runs in a short-lived child process: the lmux binary itself with
/// `--lmux-index`. The app only reads the index (list, search), so the memory a big
/// index churns through is returned to the system when the child exits instead of
/// staying in the app's malloc zones.
///
///   <exe> --lmux-index refresh|archive <sessions.db> <projects root> <archive dir> [<at-risk cutoff, unix s>] [--codex <codex home>]
public enum HistoryIndexer {
    public static let flag = "--lmux-index"

    /// Call first thing in `main`; returns an exit code when this process is the helper.
    public static func runIfRequested(_ args: [String] = CommandLine.arguments) -> Int32? {
        guard args.count >= 6, args[1] == flag else { return nil }
        // Never outlive the app: exit when the parent (lmux) goes away, even if it was killed.
        let parent = getppid()
        let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
        watch.setEventHandler { _exit(3) }
        watch.resume()
        if getppid() != parent || getppid() == 1 { _exit(3) }
        defer { watch.cancel() }
        var args = args
        var codex: URL?
        if let i = args.firstIndex(of: "--codex"), i + 1 < args.count {
            codex = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            args.removeSubrange(i...(i + 1))
        }
        do {
            let index = try SessionIndex(databaseURL: URL(fileURLWithPath: args[3]),
                                         projectsRoot: URL(fileURLWithPath: args[4], isDirectory: true),
                                         archiveDirectory: URL(fileURLWithPath: args[5], isDirectory: true), codexHome: codex)
            switch args[2] {
            case "refresh": try index.refresh()
            case "archive": try index.archiveAll(olderThan: args.count > 6 ? Double(args[6]).map(Date.init(timeIntervalSince1970:)) : nil)
            default: return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("lmux-index: \(error)\n".utf8))
            return 1
        }
    }

    /// Run the helper and wait (call off the main thread). False if it couldn't run.
    static func run(_ exe: URL, _ mode: String, db: URL, root: URL, archive: URL, cutoff: Date? = nil, codex: URL? = nil,
                    qos: QualityOfService) -> Bool {
        let p = Process()
        p.executableURL = exe
        p.arguments = [flag, mode, db.path, root.path, archive.path] + (cutoff.map { ["\($0.timeIntervalSince1970)"] } ?? [])
            + (codex.map { ["--codex", $0.path] } ?? [])
        p.qualityOfService = qos
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
