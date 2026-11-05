// lmux IME test harness.
//
//   lmux-imetest                      automated checklist, headless (simulated 2-Set, Pinyin, Japanese IMEs)
//   lmux-imetest --visible            also run the checks against the REAL Korean IME
//                                     (shows a window, takes focus, switches input source)
//   lmux-imetest --visible --probe    print the real IME's NSTextInputClient call traces
//
// Exit code 0 = all checks passed.

import AppKit
import GhosttyKit
import LmuxTerminal

if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    print("ghostty_init failed")
    exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)
// Copy / paste checks use a private pasteboard: the user's clipboard is never touched.
let testPasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lmux.imetest.\(getpid())"))
GhosttyRuntime.standardPasteboard = testPasteboard
GhosttyRuntime.headless = headless
let app = NSApplication.shared
// Headless runs never appear in the Dock / app switcher.
app.setActivationPolicy(headless ? .prohibited : .regular)

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let code: Int32
            if CommandLine.arguments.contains("--probe") {
                guard let runtime = GhosttyRuntime(fontProfile: .korean) else { print("runtime init failed"); exit(2) }
                code = await runRealIMEProbe(runtime: runtime)
            } else {
                code = await runChecklist()
            }
            // Skip atexit teardown: libghostty's renderer/IO threads are still
            // running and tearing them down at exit is not what we test here.
            testPasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: imetestTempDir)
            fflush(stdout)
            _exit(code)
        }
    }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
