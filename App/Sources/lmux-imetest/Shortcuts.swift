import AppKit
import GhosttyKit
import LmuxTerminal
import LmuxUI

// Every shortcut a user can press, with the Korean 2-Set source, in legacy mode and in the kitty
// keyboard modes Claude Code / Codex push (1, 5, 31): the action happens and nothing leaks to the
// pty (no jamo as text or as a kitty codepoint, no stray text), idle and while a syllable is
// composing (the syllable is committed first, or at least kept). Headless it runs with the
// simulated IME; `--visible --probe` runs the same table with the REAL IME (CGEvents).
//
// The window is an LmuxWindow (its ASCII-layout retry for ⌃/⌥ menu keys) under a main menu with
// lmux's default key equivalents; the items record instead of acting, and every Ghostty action
// is recorded and consumed (nothing quits, closes, opens or goes full screen).

/// What a shortcut should do.
enum ShortcutCheck {
    /// The Ghostty binding action reached the host, or (no tag) the mirrored menu item fired.
    case action
    /// libghostty asked to close the surface (⌘W).
    case closeSurface
    /// A Control key: legacy sends the C0 byte (Ctrl+I / Ctrl+M have none in Ghostty: fixterms
    /// CSI 105;5u / 109;5u), kitty CSI <ASCII>;5u; never the jamo's codepoint.
    case control(UInt8)
    /// Exactly these bytes reach the pty (Ghostty `text:` / `esc:` bindings).
    case bytes(String)
    /// ⌘C with a selection: the private pasteboard gets it, the pty nothing.
    case copy
    /// ⌘V: the pty gets exactly this.
    case paste(String)
    /// ⌘A: a selection exists afterwards.
    case selectAll
    /// ⌘= ⌘- ⌘0: the cell size changed (CELL_SIZE).
    case cellSize
    /// ⌘K: the screen is cleared, and with it the selection (no stray text).
    case clear
    /// Typing: the pty gets exactly this.
    case text(String)
    /// The action when it applies (⌘E with a selection), else the key as with the ABC source: legacy
    /// nothing, kitty CSI <ASCII>;<mods>u.
    case actionOrKey(UInt8)
    /// CSI <ASCII>;<mods>u in every mode (⌃⇧ letters: fixterms in legacy mode too).
    case csi(UInt8)
    /// Reported only (⌥ letters with option-as-alt off): just no jamo leak, nothing lost.
    case observe
}

struct Shortcut {
    let name: String
    let keys: [Key]
    var ghostty: [ghostty_action_tag_e] = []
    var menu: String? = nil
    var check: ShortcutCheck = .action
    /// A Ghostty binding action run first (a selection to copy, a font size to reset).
    var prep: String? = nil
    /// Also run it right after composing 가.
    var compose = true
}

extension Key {
    /// Unshifted / shifted jamo of each letter key on the 2-Set layout.
    static func jamo(_ c: Character, shift: Bool) -> String {
        let k = Character(shift ? String(c).uppercased() : String(c))
        return HangulComposer.keymap[k].map(String.init) ?? HangulComposer.keymap[Character(String(c).lowercased())].map(String.init) ?? String(c)
    }
    static let shiftedASCII: [Character: Character] = [
        "[": "{", "]": "}", "=": "+", "-": "_", ",": "<", ".": ">", "/": "?", ";": ":", "'": "\"", "`": "~", "\\": "|",
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
    ]
    /// The ABC layout's ⌥ characters (simulated events only; the real IME decides for itself).
    static let optionChars: [Character: String] = [
        "a": "å", "b": "∫", "c": "ç", "d": "∂", "f": "ƒ", "g": "©", "h": "˙", "j": "∆", "k": "˚", "l": "¬",
        "m": "µ", "o": "ø", "p": "π", "q": "œ", "r": "®", "s": "ß", "t": "†", "v": "√", "w": "∑", "x": "≈", "y": "¥", "z": "Ω",
    ]
    static let named: [Character: (UInt16, String, Bool)] = [
        "←": (KC.left, "\u{F702}", true), "→": (KC.right, "\u{F703}", true), "↑": (KC.up, "\u{F700}", true),
        "↓": (KC.down, "\u{F701}", true), "↩": (KC.returnKey, "\r", false), "⌫": (KC.delete, "\u{7f}", false),
        "⇥": (KC.tab, "\t", false),
    ]

    /// `c` pressed with `mods`, shaped as the Korean 2-Set source delivers it: ⌘ keys carry the Latin
    /// character, the key's own character (ignoring modifiers) is the jamo. CGEvents (the real probe)
    /// use only the key code and modifiers.
    static func korean(_ c: Character, _ mods: NSEvent.ModifierFlags = []) -> Key {
        if let (code, s, fn) = named[c] {
            return Key(keyCode: code, chars: s, mods: fn ? mods.union([.numericPad, .function]) : mods, ign: s)
        }
        let shift = mods.contains(.shift)
        let latin = shift ? (c.isLetter ? String(c).uppercased() : String(shiftedASCII[c] ?? c)) : String(c)
        var chars = latin
        if mods.contains(.control), !mods.contains(.command), let a = c.asciiValue, c.isLetter {
            chars = String(UnicodeScalar(a & 0x1f))
        } else if mods == [.option] {
            chars = optionChars[c] ?? latin
        }
        return Key(keyCode: KC.map[c]!, chars: chars, mods: mods, ign: c.isLetter ? jamo(c, shift: shift) : latin)
    }
}

/// The table: Ghostty's macOS defaults that lmux keeps, lmux's own menu keys, the Control keys
/// Claude Code and Codex use, and the typing keys that must not regress.
func shortcutTable() -> [Shortcut] {
    let cmd: NSEvent.ModifierFlags = [.command], sc: NSEvent.ModifierFlags = [.command, .shift]
    let K = Key.korean
    var t: [Shortcut] = [
        // Ghostty bindings on letter keys (the ones the jamo can break). ⌘C with nothing selected first:
        // the selection ⌘A makes stays.
        Shortcut(name: "⌘C (no selection)", keys: [K("c", cmd)], check: .actionOrKey(99)),
        Shortcut(name: "⌘A select all", keys: [K("a", cmd)], check: .selectAll),
        Shortcut(name: "⌘C copy (selection)", keys: [K("c", cmd)], check: .copy, prep: "select_all", compose: false),
        Shortcut(name: "⌘V paste", keys: [K("v", cmd)], check: .paste("lmux-paste-OK")),
        Shortcut(name: "⌘K clear screen", keys: [K("k", cmd)], check: .clear, prep: "select_all"),
        Shortcut(name: "⌘N new workspace", keys: [K("n", cmd)], ghostty: [GHOSTTY_ACTION_NEW_WINDOW], menu: "New Workspace"),
        Shortcut(name: "⌘T new tab", keys: [K("t", cmd)], ghostty: [GHOSTTY_ACTION_NEW_TAB]),
        Shortcut(name: "⌘D split right", keys: [K("d", cmd)], ghostty: [GHOSTTY_ACTION_NEW_SPLIT], menu: "Split Right"),
        Shortcut(name: "⇧⌘D split down", keys: [K("d", sc)], ghostty: [GHOSTTY_ACTION_NEW_SPLIT], menu: "Split Down"),
        Shortcut(name: "⌘W close pane", keys: [K("w", cmd)], menu: "Close Pane", check: .closeSurface),
        Shortcut(name: "⇧⌘W close workspace", keys: [K("w", sc)], ghostty: [GHOSTTY_ACTION_CLOSE_WINDOW], menu: "Close Workspace"),
        Shortcut(name: "⌘F find", keys: [K("f", cmd)], ghostty: [GHOSTTY_ACTION_START_SEARCH], menu: "Find…"),
        Shortcut(name: "⌘E find selection", keys: [K("e", cmd)], ghostty: [GHOSTTY_ACTION_START_SEARCH], check: .actionOrKey(101)),
        Shortcut(name: "⌘Z undo send", keys: [K("z", cmd)], ghostty: [GHOSTTY_ACTION_UNDO], menu: "Undo Send"),
        Shortcut(name: "⇧⌘Z redo", keys: [K("z", sc)], ghostty: [GHOSTTY_ACTION_REDO]),
        Shortcut(name: "⇧⌘T undo (reopen)", keys: [K("t", sc)], ghostty: [GHOSTTY_ACTION_UNDO]),
        Shortcut(name: "⌃⌘F full screen", keys: [K("f", [.command, .control])], ghostty: [GHOSTTY_ACTION_TOGGLE_FULLSCREEN], menu: "Enter Full Screen"),
        Shortcut(name: "⇧⌘P command palette", keys: [K("p", sc)], ghostty: [GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE]),
        Shortcut(name: "⌥⌘I inspector", keys: [K("i", [.command, .option])], ghostty: [GHOSTTY_ACTION_INSPECTOR]),
        Shortcut(name: "⌘Q quit", keys: [K("q", cmd)], ghostty: [GHOSTTY_ACTION_QUIT], menu: "Quit lmux"),
        // lmux's own menu keys (no Ghostty binding: the menu takes them).
        Shortcut(name: "⌃⌘S toggle sidebar", keys: [K("s", [.command, .control])], menu: "Toggle Sidebar"),
        Shortcut(name: "⇧⌘J jump to the agent that needs you", keys: [K("j", sc)], menu: "Jump to Agent That Needs You"),
        Shortcut(name: "⇧⌘U latest unread", keys: [K("u", sc)], menu: "Jump to Latest Unread"),
        Shortcut(name: "⇧⌘H search history", keys: [K("h", sc)], menu: "Search History"),
        Shortcut(name: "⌥⌘C copy the last reply", keys: [K("c", [.command, .option])], menu: "Copy Original Reply"),
        Shortcut(name: "⌘H hide", keys: [K("h", cmd)], menu: "Hide lmux"),
        Shortcut(name: "⌥⌘H hide others", keys: [K("h", [.command, .option])], menu: "Hide Others"),
        Shortcut(name: "⌘M minimize", keys: [K("m", cmd)], menu: "Minimize"),
        // Non-letter keys (layout-independent, but composing still has to commit first).
        Shortcut(name: "⌘, settings", keys: [K(",", cmd)], ghostty: [GHOSTTY_ACTION_OPEN_CONFIG], menu: "Settings…"),
        Shortcut(name: "⌘= bigger", keys: [K("=", cmd)], check: .cellSize),
        Shortcut(name: "⌘0 reset size", keys: [K("0", cmd)], check: .cellSize, prep: "increase_font_size:1"),
        Shortcut(name: "⌘- smaller", keys: [K("-", cmd)], check: .cellSize),
        Shortcut(name: "⌘[ previous pane", keys: [K("[", cmd)], ghostty: [GHOSTTY_ACTION_GOTO_SPLIT], menu: "Previous Pane"),
        Shortcut(name: "⌘] next pane", keys: [K("]", cmd)], ghostty: [GHOSTTY_ACTION_GOTO_SPLIT], menu: "Next Pane"),
        Shortcut(name: "⇧⌘[ previous workspace", keys: [K("[", sc)], ghostty: [GHOSTTY_ACTION_GOTO_TAB], menu: "Previous Workspace"),
        Shortcut(name: "⇧⌘] next workspace", keys: [K("]", sc)], ghostty: [GHOSTTY_ACTION_GOTO_TAB], menu: "Next Workspace"),
        Shortcut(name: "⌃⇥ next workspace", keys: [K("⇥", [.control])], ghostty: [GHOSTTY_ACTION_GOTO_TAB]),
        Shortcut(name: "⌘1 workspace 1", keys: [K("1", cmd)], ghostty: [GHOSTTY_ACTION_GOTO_TAB], menu: "Select Workspace 1"),
        Shortcut(name: "⌘9 last workspace", keys: [K("9", cmd)], ghostty: [GHOSTTY_ACTION_GOTO_TAB], menu: "Select Last Workspace"),
        Shortcut(name: "⇧⌘↩ zoom split", keys: [K("↩", sc)], ghostty: [GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM], menu: "Zoom Split"),
        Shortcut(name: "⌥⌘← pane left", keys: [K("←", [.command, .option])], ghostty: [GHOSTTY_ACTION_GOTO_SPLIT]),
        Shortcut(name: "⌃⌘→ resize", keys: [K("→", [.command, .control])], ghostty: [GHOSTTY_ACTION_RESIZE_SPLIT]),
        Shortcut(name: "⌃⌘= equalize", keys: [K("=", [.command, .control])], ghostty: [GHOSTTY_ACTION_EQUALIZE_SPLITS]),
        Shortcut(name: "⌘← line start", keys: [K("←", cmd)], check: .bytes("\u{01}")),
        Shortcut(name: "⌘→ line end", keys: [K("→", cmd)], check: .bytes("\u{05}")),
        Shortcut(name: "⌘⌫ delete line", keys: [K("⌫", cmd)], check: .bytes("\u{15}")),
        Shortcut(name: "⌥← word left", keys: [K("←", [.option])], check: .bytes("\u{1b}b")),
        Shortcut(name: "⌥→ word right", keys: [K("→", [.option])], check: .bytes("\u{1b}f")),
    ]
    // Control keys Claude Code / Codex / readline use (Ctrl+Space is the input-source switch: never pressed).
    for c in "abcdefghijklmnopqrstuvwxyz" {
        t.append(Shortcut(name: "⌃\(c.uppercased())", keys: [K(c, [.control])], check: .control(c.asciiValue!)))
    }
    t.append(Shortcut(name: "⌃⇧A", keys: [K("a", [.control, .shift])], check: .csi(97)))
    // Typing that must not regress: Shift letters (ㄲ ㅆ), ⌥ letters (option-as-alt off).
    t.append(Shortcut(name: "⇧ letters compose (까싸)", keys: Key.latin("RkTk "), check: .text("까싸 "), compose: false))
    for c in "bfptd" {
        t.append(Shortcut(name: "⌥\(c.uppercased())", keys: [K(c, [.option])], check: .observe))
    }
    return t
}

/// lmux's main menu key equivalents (Menu.swift defaults); the items record instead of acting.
/// Copy / Paste / Select All keep their real actions (to the first responder, the surface).
@MainActor
final class MenuRecorder: NSObject {
    var hits: [String] = []
    @objc func hit(_ s: NSMenuItem) { hits.append(s.title) }

    func menu() -> NSMenu {
        let main = NSMenu()
        typealias Item = (String, String, NSEvent.ModifierFlags, Selector?)
        var items: [Item] = [
            ("Settings…", ",", [.command], nil), ("Hide lmux", "h", [.command], nil), ("Hide Others", "h", [.command, .option], nil),
            ("Quit lmux", "q", [.command], nil),
            ("New Workspace", "n", [.command], nil), ("Split Right", "d", [.command], nil), ("Split Down", "D", [.command, .shift], nil),
            ("Close Pane", "w", [.command], nil), ("Close Workspace", "W", [.command, .shift], nil),
            ("Undo Send", "z", [.command], nil), ("Copy", "c", [.command], #selector(SurfaceView.copy(_:))),
            ("Copy Original Reply", "c", [.command, .option], nil), ("Paste", "v", [.command], #selector(SurfaceView.paste(_:))),
            ("Select All", "a", [.command], #selector(NSResponder.selectAll(_:))),
            ("Find…", "f", [.command], nil), ("Find Next", "g", [.command], nil), ("Find Previous", "G", [.command, .shift], nil),
            ("Toggle Sidebar", "s", [.command, .control], nil), ("Search History", "H", [.command, .shift], nil),
            ("Zoom Split", "\r", [.command, .shift], nil), ("Increase Font Size", "=", [.command], nil),
            ("Decrease Font Size", "-", [.command], nil), ("Reset Font Size", "0", [.command], nil), ("Clear Screen", "k", [.command], nil),
            ("Enter Full Screen", "f", [.command, .control], nil), ("Jump to Latest Unread", "U", [.command, .shift], nil),
            ("Jump to Agent That Needs You", "J", [.command, .shift], nil), ("Minimize", "m", [.command], nil),
            ("Next Pane", "]", [.command], nil), ("Previous Pane", "[", [.command], nil),
            ("Next Workspace", "]", [.command, .shift], nil), ("Previous Workspace", "[", [.command, .shift], nil),
        ]
        for i in 1...9 { items.append((i == 9 ? "Select Last Workspace" : "Select Workspace \(i)", "\(i)", [.command], nil)) }
        let item = NSMenuItem()
        let sub = NSMenu(title: "lmux")
        for (title, key, mods, sel) in items {
            let it = NSMenuItem(title: title, action: sel ?? #selector(hit(_:)), keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            if sel == nil { it.target = self }
            sub.addItem(it)
        }
        item.submenu = sub
        main.addItem(item)
        return main
    }
}

/// Ghostty actions that only report state: let the runtime handle them. Every other action is
/// recorded and consumed.
private let passthroughActions: Set<UInt32> = Set([
    GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE, GHOSTTY_ACTION_MOUSE_SHAPE,
    GHOSTTY_ACTION_MOUSE_VISIBILITY, GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_RENDER,
    GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_SELECTION_CHANGED,
    GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_INITIAL_SIZE, GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_SEARCH_TOTAL,
    GHOSTTY_ACTION_SEARCH_SELECTED, GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE,
].map(\.rawValue))

final class ActionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tags: [UInt32] = []
    func add(_ t: ghostty_action_tag_e) { lock.lock(); tags.append(t.rawValue); lock.unlock() }
    func take() -> [UInt32] { lock.lock(); defer { tags = []; lock.unlock() }; return tags }
}

/// The kitty / fixterms modifier parameter (1 + shift 1, alt 2, ctrl 4, super 8).
func csiMods(_ m: NSEvent.ModifierFlags) -> Int {
    1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.option) ? 2 : 0) + (m.contains(.control) ? 4 : 0) + (m.contains(.command) ? 8 : 0)
}

/// Any Hangul jamo in the bytes: as text, or as a number in a CSI sequence (a kitty key code).
/// Key *release* reports (flag 2) naming a composing jamo key are upstream Ghostty / the kitty spec
/// and carry no text; they are dropped first (see the kitty check in Checklist.swift).
func jamoLeak(_ s: String) -> Bool {
    let isJamo = { (v: UInt32) in (0x1100...0x11FF).contains(v) || (0x3131...0x318E).contains(v) }
    if s.unicodeScalars.contains(where: { isJamo($0.value) }) { return true }
    let re = try! NSRegularExpression(pattern: "\u{1b}\\[([0-9;:]*)[A-Za-z~]")
    for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        let params = (s as NSString).substring(with: m.range(at: 1))
        if params.split(whereSeparator: { $0 == ";" || $0 == ":" }).contains(where: { UInt32($0).map(isJamo) ?? false }) { return true }
    }
    return false
}

/// The bytes without kitty key-release reports.
func dropReleases(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1b}\\[[0-9:]+;[0-9]+:3u", with: "", options: .regularExpression)
}

/// Text left once escape sequences are removed (stray text a shortcut must not send).
func strayText(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1b}\\[[0-9;:?<>=]*[ -/]*[@-~]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\u{1b}.", with: "", options: .regularExpression)
        .filter { $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f } }
}

/// Run the table in legacy mode and kitty 1 / 5 / 31, idle and right after composing 가.
/// `report(name, pass, detail)`; returns the number of failures.
@MainActor
func runShortcutMatrix(runtime: GhosttyRuntime, real: Bool, attach: @escaping (SinkTerminal) async -> Void,
                       report: (String, Bool, String) -> Void) async -> Int {
    let table = shortcutTable()
    let recorder = MenuRecorder()
    let actions = ActionLog()
    var closes = 0
    let savedMenu = NSApp.mainMenu, savedHandler = runtime.actionHandler, savedClose = runtime.onCloseSurface
    NSApp.mainMenu = recorder.menu()
    runtime.actionHandler = { _, action, _ in
        actions.add(action.tag)
        return passthroughActions.contains(action.tag.rawValue) ? nil : true
    }
    runtime.onCloseSurface = { _, _ in closes += 1 }
    defer { NSApp.mainMenu = savedMenu; runtime.actionHandler = savedHandler; runtime.onCloseSurface = savedClose }
    let pb = GhosttyRuntime.standardPasteboard
    let settle = real ? 120 : 100
    var failures = 0
    let make: (ghostty_app_t, SurfaceOptions) -> SurfaceView = real
        ? { RecordingSurfaceView(app: $0, options: $1) }
        : { SimulatedKoreanIMEView(app: $0, options: $1) }

    for flags in [0, 1, 5, 31] {
        let mode = flags == 0 ? "legacy" : "kitty \(flags)"
        let k = SinkTerminal(runtime: runtime, view: make, title: "lmux shortcuts \(mode)",
                             prelude: flags == 0 ? "" : "\\033[>\(flags)u",
                             window: { LmuxWindow(contentRect: $0, styleMask: $1, backing: .buffered, defer: false) })
        if real { NSApp.activate(ignoringOtherApps: true) }
        guard await k.waitReady() else { report("[\(mode)] shortcut terminal ready", false, ""); failures += 1; continue }
        await attach(k)
        let v = k.view, rec = v as? RecordingSurfaceView
        for sc in table {
            // Composing runs in legacy and kitty 1 (Claude Code's mode); kitty 5 / 31 idle only.
            for composing in (sc.compose && flags <= 1 ? [false, true] : [false]) {
                let name = "[\(mode)\(composing ? ", composing 가" : "")] \(sc.name)"
                switch sc.check {
                case .copy:
                    pb.declareTypes([.string], owner: nil)
                    pb.setString("before-copy", forType: .string)
                case .paste(let s):
                    pb.declareTypes([.string], owner: nil)
                    pb.setString(s, forType: .string)
                default: break
                }
                if let p = sc.prep { v.performBindingAction(p); await sleepMs(50) }
                _ = actions.take(); recorder.hits = []; closes = 0; rec?.log = []
                k.mark()
                await post((composing ? Key.latin("rk") : []) + sc.keys, to: k.window, gapMs: real ? 25 : 0)
                await sleepMs(settle)
                let raw = String(decoding: k.newBytes(), as: UTF8.self)
                let tags = actions.take(), hits = recorder.hits, preedit = v.currentPreedit
                let s = dropReleases(raw)
                // Composing: 가 is committed before anything the key sends, or (a menu key the IME never
                // saw) still composing; it is never lost or doubled.
                var body = s
                var composeOK = true
                if composing {
                    if s.hasPrefix("가") { body = String(s.dropFirst()) } else { composeOK = s.isEmpty && preedit == "가" }
                    composeOK = composeOK && !body.contains("가")
                }
                // Kitty flag 8 reports a text key (⌥B typing ∫) by the layout's key, ㅠ, with the base
                // layout's b as its alternate: the kitty spec, as in upstream Ghostty (and with option-as-alt
                // off, ⌥B is ∫ with the ABC source too, never Meta-B). Reported, not a leak.
                let layoutKeyReport: Bool = {
                    guard case .observe = sc.check, flags & 8 != 0 else { return false }
                    return s.range(of: "^(\u{1b}\\[[0-9]+::[0-9]+;[0-9:]+(;[0-9]+)?u)+$", options: .regularExpression) != nil
                }()
                let leak = jamoLeak(s) && !layoutKeyReport
                let stray = strayText(body)
                let ghosttyFired = sc.ghostty.contains { t in tags.contains(t.rawValue) }
                let menuFired = sc.menu.map { m in hits == [m] } ?? false
                var ok: Bool
                switch sc.check {
                case .action:
                    ok = (ghosttyFired || menuFired) && body.isEmpty
                case .closeSurface:
                    ok = (closes == 1 || menuFired) && body.isEmpty
                case .control(let a):
                    let want = flags == 0 && a != 105 && a != 109 ? String(UnicodeScalar(a & 0x1f)) : "\u{1b}[\(a);5u"
                    ok = body == want
                case .bytes(let b):
                    ok = body == b
                case .copy:
                    let got = pb.string(forType: .string) ?? ""
                    ok = got != "before-copy" && !got.isEmpty && body.isEmpty
                case .paste(let p):
                    ok = body == p
                case .selectAll:
                    ok = v.hasSelection && body.isEmpty
                case .cellSize:
                    ok = tags.contains(GHOSTTY_ACTION_CELL_SIZE.rawValue) && body.isEmpty
                case .clear:
                    ok = !v.hasSelection && stray.isEmpty
                case .text(let x):
                    ok = s == x
                case .actionOrKey(let a):
                    ok = ghosttyFired ? body.isEmpty : body == (flags == 0 ? "" : "\u{1b}[\(a);\(csiMods(sc.keys.last!.mods))u")
                case .csi(let a):
                    // Kitty flag 4 adds the shifted key (97:65 for ⇧A), as with the ABC source.
                    ok = body.replacingOccurrences(of: ":\(a - 32);", with: ";") == "\u{1b}[\(a);\(csiMods(sc.keys.last!.mods))u"
                case .observe:
                    ok = true
                }
                ok = ok && !leak && composeOK
                let detail = "pty=\"\(show(Array(raw.utf8)))\" preedit=\"\(preedit)\""
                    + (tags.isEmpty ? "" : " actions=\(tags.map { String($0) }.joined(separator: ","))")
                    + (hits.isEmpty ? "" : " menu=\(hits)") + (closes > 0 ? " close=\(closes)" : "")
                    + (leak ? " JAMO LEAK" : "") + (ok || rec == nil ? "" : " calls: \(rec!.log.joined(separator: " | "))")
                if case .observe = sc.check { report(name, ok, detail) } else { report(name, ok, ok ? "" : detail) }
                if !ok { failures += 1 }
                // Leave nothing composing, no font change, no selection for the next key.
                if !v.currentPreedit.isEmpty { await post([.escape], to: k.window) }
                if case .cellSize = sc.check { v.performBindingAction("reset_font_size"); await sleepMs(30) }
                if !v.currentPreedit.isEmpty || sc.prep != nil { await sleepMs(30) }
            }
        }
        k.window.close()
    }
    return failures
}

/// `macos-option-as-alt = true` (what Claude Code's docs suggest for ⌥ as Meta): ⌥B / ⌥F / ⌥P / ⌥T
/// with the Korean source, legacy and kitty 1. Reported only, against what the ABC source sends
/// (legacy ESC b, kitty CSI 98;3u).
@MainActor
func reportOptionAsAlt(real: Bool, attach: @escaping (SinkTerminal) async -> Void, report: (String, String) -> Void) async {
    guard let rt = GhosttyRuntime(simulatedUserConfig: ["macos-option-as-alt = true"], fontProfile: .korean) else { return }
    keepAlive.append(rt)
    let make: (ghostty_app_t, SurfaceOptions) -> SurfaceView = real
        ? { RecordingSurfaceView(app: $0, options: $1) }
        : { SimulatedKoreanIMEView(app: $0, options: $1) }
    for flags in [0, 1] {
        let mode = flags == 0 ? "legacy" : "kitty \(flags)"
        let k = SinkTerminal(runtime: rt, view: make, title: "lmux option-as-alt \(mode)", prelude: flags == 0 ? "" : "\\033[>\(flags)u")
        if real { NSApp.activate(ignoringOtherApps: true) }
        guard await k.waitReady() else { continue }
        await attach(k)
        for c in "bfpt" {
            k.mark()
            await post([Key.korean(c, [.option])], to: k.window, gapMs: real ? 25 : 0)
            await sleepMs(real ? 180 : 120)
            let b = k.newBytes(), a = c.asciiValue!
            let abc = flags == 0 ? "\u{1b}\(c)" : "\u{1b}[\(a);3u"
            report("[option-as-alt, \(mode)] ⌥\(c.uppercased())", "pty=\"\(show(b))\" preedit=\"\(k.view.currentPreedit)\" (ABC: \"\(show(Array(abc.utf8)))\")"
                   + (jamoLeak(String(decoding: b, as: UTF8.self)) || k.view.currentPreedit != "" ? " JAMO" : ""))
            if !k.view.currentPreedit.isEmpty { await post([.escape], to: k.window) }
        }
        k.window.close()
    }
}
