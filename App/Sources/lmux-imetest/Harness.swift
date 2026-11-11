import AppKit
import Carbon
import GhosttyKit
import LmuxTerminal

/// macOS ANSI virtual key codes used by the tests.
enum KC {
    static let map: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ".": 47, ",": 43,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "=": 24, "-": 27, "[": 33, "]": 30, ";": 41, "'": 39, "/": 44, "`": 50, "\\": 42,
    ]
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

/// One key press to synthesize.
struct Key {
    var keyCode: UInt16
    var chars: String
    var mods: NSEvent.ModifierFlags = []
    /// charactersIgnoringModifiers, when not derived from `chars` (the Korean source's "ㅊ" for C).
    var ign: String? = nil

    static func ch(_ c: Character, shift: Bool = false) -> Key {
        let s = shift ? String(c).uppercased() : String(c)
        return Key(keyCode: KC.map[Character(c.lowercased())]!, chars: s, mods: shift ? [.shift] : [])
    }
    static func latin(_ s: String) -> [Key] { s.map { $0 == " " ? .space : ch($0, shift: $0.isUppercase) } }
    static let enter = Key(keyCode: KC.returnKey, chars: "\r")
    static let shiftEnter = Key(keyCode: KC.returnKey, chars: "\r", mods: [.shift])
    static let backspace = Key(keyCode: KC.delete, chars: "\u{7f}")
    static let space = Key(keyCode: KC.space, chars: " ")
    static let escape = Key(keyCode: KC.escape, chars: "\u{1b}")
    static let left = Key(keyCode: KC.left, chars: "\u{F702}", mods: [.numericPad, .function])
    static func cmd(_ c: Character) -> Key { Key(keyCode: KC.map[c]!, chars: String(c), mods: [.command]) }
    /// Ctrl+C as the Korean 2-Set source delivers it (ETX, the key's own character "ㅊ"); `korean: false` = ABC.
    static func ctrlC(korean: Bool) -> Key { Key(keyCode: KC.map["c"]!, chars: "\u{03}", mods: [.control], ign: korean ? "ㅊ" : "c") }
    /// Cmd+C as the Korean source delivers it ("c", ignoring modifiers "ㅊ").
    static let cmdCKorean = Key(keyCode: KC.map["c"]!, chars: "c", mods: [.command], ign: "ㅊ")
}

/// The harness never shows a window or takes focus unless `--visible` is passed
/// (needed only for the real-IME checks, which require an active key window).
let headless = !CommandLine.arguments.contains("--visible")

/// Sink scripts, sinks and demo scripts of this run (removed when the harness exits).
let imetestTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("lmux-imetest-\(getpid())")

/// A terminal window whose child process is a byte sink: the pty is put in
/// raw mode (echo kept on so text is rendered) and everything the terminal
/// writes to the pty is appended to a file we can inspect.
final class SinkTerminal {
    let window: NSWindow
    let view: SurfaceView
    let sinkURL: URL
    private var offset: Int = 0

    init(runtime: GhosttyRuntime, view makeView: (ghostty_app_t, SurfaceOptions) -> SurfaceView,
         title: String, echo: Bool = true, frame: NSRect = NSRect(x: 200, y: 200, width: 640, height: 300),
         prelude: String = "", window makeWindow: ((NSRect, NSWindow.StyleMask) -> NSWindow)? = nil) {
        let dir = imetestTempDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.prefix(8)
        sinkURL = dir.appendingPathComponent("sink-\(id).bin")
        let ready = dir.appendingPathComponent("ready-\(id)")
        let script = dir.appendingPathComponent("sink-\(id).sh")
        try? """
        #!/bin/sh
        stty raw \(echo ? "echo" : "-echo")
        \(prelude.isEmpty ? "" : "printf '\(prelude)' > /dev/tty")
        : > '\(sinkURL.path)'
        touch '\(ready.path)'
        exec /bin/cat > '\(sinkURL.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)

        view = makeView(runtime.app!, SurfaceOptions(command: script.path))
        if headless {
            // Borderless and far off-screen: rendered (so pixels can be read
            // from the IOSurface) but never visible, never key, never activating.
            let offscreen = NSRect(x: -10000, y: -10000, width: frame.width, height: frame.height)
            window = makeWindow?(offscreen, [.borderless])
                ?? NSWindow(contentRect: offscreen, styleMask: [.borderless], backing: .buffered, defer: false)
        } else {
            window = makeWindow?(frame, [.titled, .resizable])
                ?? NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        }
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = view
        if headless {
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        window.makeFirstResponder(view)
        self.readyURL = ready
    }
    let readyURL: URL

    func waitReady() async -> Bool {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: readyURL.path) {
                try? await Task.sleep(for: .milliseconds(150))
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Bytes written to the pty since the last call to `mark()`.
    func newBytes() -> [UInt8] {
        let data = (try? Data(contentsOf: sinkURL)) ?? Data()
        guard data.count > offset else { return [] }
        return Array(data[offset...])
    }

    func mark() {
        offset = ((try? Data(contentsOf: sinkURL)) ?? Data()).count
    }

    /// Wait until at least `count` new bytes arrived (or a timeout), then a bit more
    /// to catch any extra (e.g. duplicated) bytes.
    func waitBytes(atLeast count: Int, timeout: Double = 2.0) async -> [UInt8] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, newBytes().count < count {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(150))
        return newBytes()
    }
}

/// Deliver one key event. Visible mode posts it to the AppKit queue so it takes
/// the hardware route (NSApp.sendEvent -> performKeyEquivalent / keyDown of the
/// key window). Headless mode has no key window, so it dequeues the event itself
/// (which makes it NSApp.currentEvent, as during real dispatch) and performs the
/// same routing NSApplication does: key equivalents first (the window, then the main menu), then the window.
@MainActor
func dispatch(_ ev: NSEvent, to window: NSWindow) {
    guard headless else {
        // The queue hands a key event to the key window: make that `window` (the CJK checks type into
        // an ABC reference terminal and the IME's terminal in turn; the reference keys used to reach
        // whichever was key).
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        NSApp.postEvent(ev, atStart: false)
        return
    }
    NSApp.postEvent(ev, atStart: true)
    guard let e = NSApp.nextEvent(matching: [.keyDown, .keyUp], until: .distantPast,
                                  inMode: .default, dequeue: true) else { return }
    if e.type == .keyDown, !e.modifierFlags.isDisjoint(with: [.command, .control]),
       window.performKeyEquivalent(with: e) || NSApp.mainMenu?.performKeyEquivalent(with: e) == true {
        return
    }
    window.sendEvent(e)
}

/// Post synthetic key events (see `dispatch`).
/// When true, events are built from real CGEvents (with keyboard-layout data
/// filled in by the system) instead of NSEvent.keyEvent(...).
var useCGEvents = false

@MainActor
func post(_ keys: [Key], to window: NSWindow, gapMs: Int = 0) async {
    for k in keys {
        if useCGEvents {
            let src = CGEventSource(stateID: .hidSystemState)
            for isDown in [true, false] {
                let cg = CGEvent(keyboardEventSource: src, virtualKey: k.keyCode, keyDown: isDown)!
                var flags: CGEventFlags = []
                if k.mods.contains(.shift) { flags.insert(.maskShift) }
                if k.mods.contains(.command) { flags.insert(.maskCommand) }
                if k.mods.contains(.control) { flags.insert(.maskControl) }
                if k.mods.contains(.option) { flags.insert(.maskAlternate) }
                cg.flags = flags
                dispatch(NSEvent(cgEvent: cg)!, to: window)
            }
            if gapMs > 0 { try? await Task.sleep(for: .milliseconds(gapMs)) }
            continue
        }
        let ts = ProcessInfo.processInfo.systemUptime
        let ignoring = k.ign ?? (k.mods.contains(.shift) ? k.chars : k.chars.lowercased())
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: k.mods, timestamp: ts,
                                    windowNumber: window.windowNumber, context: nil, characters: k.chars,
                                    charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: k.keyCode)!
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: k.mods, timestamp: ts + 0.01,
                                  windowNumber: window.windowNumber, context: nil, characters: k.chars,
                                  charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: k.keyCode)!
        dispatch(down, to: window)
        dispatch(up, to: window)
        if gapMs > 0 { try? await Task.sleep(for: .milliseconds(gapMs)) }
    }
    // Let the queue drain.
    try? await Task.sleep(for: .milliseconds(100))
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { b in
        if b >= 0x20 && b < 0x7f { return String(UnicodeScalar(b)) }
        return String(format: "\\x%02x", b)
    }.joined()
}

func show(_ bytes: [UInt8]) -> String {
    // Render UTF-8 where valid, escape control bytes.
    guard let s = String(bytes: bytes, encoding: .utf8) else { return hex(bytes) }
    return s.unicodeScalars.map { u in
        u.value < 0x20 || u.value == 0x7f ? String(format: "\\x%02x", u.value) : String(u)
    }.joined()
}

func currentInputSourceID() -> String {
    let src = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)!
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

@discardableResult
func selectInputSource(_ id: String) -> Bool {
    let props = [kTISPropertyInputSourceID: id] as CFDictionary
    guard let list = TISCreateInputSourceList(props, false)?.takeRetainedValue() as? [TISInputSource],
          let src = list.first else { return false }
    return TISSelectInputSource(src) == noErr
}
