// lmux: one window, a sidebar of workspaces, each a split tree of Ghostty surfaces.
//
// LMUX_HEADLESS=1: never show anything or take focus —
// prohibited activation policy (no Dock / app switcher), borderless window far
// off-screen, no activation, no system notifications, no onboarding sheet.
// Used for measurements and automation.
//
// LMUX_WINDOW_SIZE=<w>x<h> (headless only): the offscreen window's size in points (default
// 1280x800), for memory budgets at other sizes.
//
// LMUX_SNAPSHOT=<path.png>: render the window to a PNG ~2s after launch, then quit
// (LMUX_SNAPSHOT_DELAY overrides the delay in seconds).

import AppKit
import GhosttyKit
import LmuxNotificationBar
import LmuxTerminal
import LmuxUI

let env = ProcessInfo.processInfo.environment
let headless = env["LMUX_HEADLESS"] == "1"
// Headless runs are automation (tests, benchmarks, README renders): they must never read or
// write the user's real state dir (layout.json, sockets, History index).
if headless, (env["LMUX_STATE_DIR"] ?? "").isEmpty {
    FileHandle.standardError.write("lmux: LMUX_HEADLESS=1 needs an explicit LMUX_STATE_DIR (never the real one)\n".data(using: .utf8)!)
    exit(2)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var runtime: GhosttyRuntime!
    var controller: LmuxController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug aid: force the app appearance without touching the system setting.
        switch env["LMUX_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }

        guard let runtime = GhosttyRuntime() else {
            NSLog("lmux: failed to initialize libghostty")
            exit(1)
        }
        self.runtime = runtime
        let controller = LmuxController(runtime: runtime, headless: headless)
        self.controller = controller
        controller.buildMainMenu()
        let size = (headless ? env["LMUX_WINDOW_SIZE"] : nil)?.split(separator: "x").compactMap { Double($0) }
        if let size, size.count == 2 {
            controller.start(windowFrame: NSRect(x: 0, y: 0, width: size[0], height: size[1]))
        } else {
            controller.start()
        }
        if controller.unsafeStateDir {
            let msg = "lmux's state folder isn't private to you: \(controller.paths.stateDir.path)"
            FileHandle.standardError.write(Data("lmux: \(msg)\n".utf8))
            if !headless {
                let alert = NSAlert()
                alert.messageText = "lmux can't start"
                alert.informativeText = msg
                alert.runModal()
            }
            exit(1)
        }
        if controller.alreadyRunning {
            _ = ControlServer.handOff(path: controller.paths.controlSocket)
            exit(0)
        }
        // plugin：sidebar 底部的通知 bar（start() 提早 return 的情況上面已經 exit）。
        NotificationBarPlugin.install(on: controller)
        if !headless {
            NSApp.activate(ignoringOtherApps: true)
            // Coming from cmux: offer to bring the setup over first, then the hooks.
            controller.offerCmuxImportIfNeeded { controller.offerHooksOnboardingIfNeeded() }
        }

        if let out = env["LMUX_SNAPSHOT"] {
            let delay = Double(env["LMUX_SNAPSHOT_DELAY"] ?? "") ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                do { try controller.snapshotPNG(to: URL(fileURLWithPath: out)) } catch { NSLog("lmux: snapshot: %@", "\(error)") }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    // Closing the window keeps lmux and its panes running (Dock icon / ⌘N reopen it).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.reopenWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.shouldTerminate() ?? .terminateNow
    }
}

// `lmux --lmux-index ...`: History's background indexer (a child of the app), no UI.
if let code = HistoryIndexer.runIfRequested() { exit(code) }

// One lmux per state dir: an exclusive lock on <stateDir>/lmux.lock, taken before anything else
// (two launches at once both find no socket yet). A second launch asks the running one to come
// forward and exits: it never restores the layout, starts panes or takes over the sockets.
// The lock is held for the life of the process (closed by the kernel when it exits, never
// inherited by panes: close-on-exec).
let launchPaths = LmuxPaths()
try? FileManager.default.createDirectory(at: launchPaths.stateDir, withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
let instanceLock = open(launchPaths.stateDir.appendingPathComponent("lmux.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
if instanceLock < 0 {
    // No lock file (unwritable state dir): at least never start next to a live instance.
    if ControlServer.handOff(path: launchPaths.controlSocket) { exit(0) }
} else if flock(instanceLock, LOCK_EX | LOCK_NB) != 0 {
    // The running one may still be starting: give its control socket a few seconds to answer.
    for _ in 0..<50 {
        if ControlServer.handOff(path: launchPaths.controlSocket) { break }
        usleep(100_000)
    }
    exit(0)
}

// A clean environment for the panes (and for libghostty's own resources lookup), like
// Ghostty.app launched from the Dock: nothing from the terminal / Claude session lmux was
// started from. GHOSTTY_RESOURCES_DIR is kept only when it points into this bundle (or for
// headless automation, which sets it on purpose).
if !headless, let res = env["GHOSTTY_RESOURCES_DIR"], !res.hasPrefix(Bundle.main.bundlePath) {
    unsetenv("GHOSTTY_RESOURCES_DIR")
}
LmuxController.sanitizeInheritedEnvironment()

// Initialize Ghostty global state before anything else (as Ghostty.app does).
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    FileHandle.standardError.write("lmux: ghostty_init failed\n".data(using: .utf8)!)
    exit(1)
}

// SIGTERM (kill, logout), SIGINT, SIGHUP: the same shutdown as ⌘Q (without its confirmation),
// so the panes' processes are hung up instead of orphaned.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.controller?.shutdown() }
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(headless ? .prohibited : .regular)
app.run()
