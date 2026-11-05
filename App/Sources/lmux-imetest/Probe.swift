import AppKit
import LmuxTerminal

/// Records every NSTextInputClient call the input method makes, then forwards
/// to the real implementation. Used to (1) record what the *real* macOS Korean
/// IME does and (2) show the call trace for each simulated test.
class RecordingSurfaceView: SurfaceView {
    var log: [String] = []
    private var inKeyDown = false
    /// Calls that arrived outside keyDown are prefixed with "!" (async IME delivery).
    private func rec(_ s: String) { log.append((inKeyDown ? "" : "!") + s) }

    private func describe(_ s: Any) -> String {
        if let a = s as? NSAttributedString { return a.string }
        return "\(s)"
    }

    override func keyDown(with event: NSEvent) {
        log.append("keyDown(\(event.keyCode)\(event.modifierFlags.contains(.shift) ? ",shift" : "")\(event.modifierFlags.contains(.command) ? ",cmd" : ""))")
        let was = inKeyDown
        inKeyDown = true
        super.keyDown(with: event)
        inKeyDown = was
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let r = super.performKeyEquivalent(with: event)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            log.append("performKeyEquivalent(\(event.keyCode))=\(r)")
        }
        return r
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        rec("setMarkedText(\"\(describe(string))\"\(replacementRange.location == NSNotFound ? "" : ", replacing \(replacementRange)"))")
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func unmarkText() {
        rec("unmarkText")
        super.unmarkText()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        rec("insertText(\"\(describe(string))\"\(replacementRange.location == NSNotFound ? "" : ", replacing \(replacementRange)"))")
        super.insertText(string, replacementRange: replacementRange)
    }
    override func doCommand(by selector: Selector) {
        rec("doCommand(\(NSStringFromSelector(selector)))")
        super.doCommand(by: selector)
    }
}

/// Drive the REAL Korean 2-Set input method with synthetic key events and print
/// the NSTextInputClient call sequence + pty bytes for each scenario.
@MainActor
func runRealIMEProbe(runtime: GhosttyRuntime) async -> Int32 {
    guard !headless else { print("--probe drives the real IME and needs --visible"); return 2 }
    let original = currentInputSourceID()
    let korean = "com.apple.inputmethod.Korean.2SetKorean"
    guard selectInputSource(korean) else { print("cannot select \(korean)"); return 2 }
    defer { selectInputSource(original) }

    let term = SinkTerminal(runtime: runtime, view: { RecordingSurfaceView(app: $0, options: $1) }, title: "probe")
    NSApp.activate(ignoringOtherApps: true)
    guard await term.waitReady() else { print("sink not ready"); return 2 }
    let view = term.view as! RecordingSurfaceView
    useCGEvents = true // CGEvent-backed NSEvents are what the real IME accepts
    if let ctx = view.inputContext {
        print("context source before: \(ctx.selectedKeyboardInputSource ?? "nil")")
        ctx.selectedKeyboardInputSource = korean
        ctx.activate()
    }
    print("input source: \(currentInputSourceID()), key window: \(term.window.isKeyWindow), active: \(NSApp.isActive)")

    let scenarios: [(String, [Key])] = [
        ("안녕하세요+space", Key.latin("dkssudgktpdy") + [.space]),
        ("안녕+Enter", Key.latin("dkssud") + [.enter]),
        ("안녕+Shift+Enter", Key.latin("dkssud") + [.shiftEnter]),
        ("한+BS,BS,BS,BS", Key.latin("gks") + [.backspace, .backspace, .backspace, .backspace]),
        ("가+Cmd+T", Key.latin("rk") + [.cmd("t")]),
        ("가+.", Key.latin("rk") + [Key.ch(".")]),
        ("가+Left", Key.latin("rk") + [.left]),
        ("가+Esc", Key.latin("rk") + [.escape] + [.space]),
        ("Ctrl+C", [.ctrlC(korean: true)]),
        ("가+Ctrl+C", Key.latin("rk") + [.ctrlC(korean: true)]),
        ("Cmd+C", [.cmd("c")]),
        ("가+Cmd+C", Key.latin("rk") + [.cmd("c")]),
    ]
    for (name, keys) in scenarios {
        view.log = []
        term.mark()
        await post(keys, to: term.window, gapMs: 30)
        let bytes = await term.waitBytes(atLeast: 1, timeout: 0.6)
        print("== \(name)")
        print("   calls: \(view.log.joined(separator: " | "))")
        print("   pty:   \(show(bytes))   preedit=\"\(view.currentPreedit)\"")
        // Clean any leftover composition.
        await post([.space], to: term.window)
    }
    // The kitty keyboard modes Claude Code pushes, with the real IME.
    for flags in [1, 5, 31] {
        let k = SinkTerminal(runtime: runtime, view: { RecordingSurfaceView(app: $0, options: $1) },
                             title: "probe kitty \(flags)", prelude: "\\033[>\(flags)u")
        guard await k.waitReady() else { print("kitty \(flags) sink not ready"); continue }
        let kv = k.view as! RecordingSurfaceView
        if let ctx = kv.inputContext { ctx.selectedKeyboardInputSource = korean; ctx.activate() }
        for (name, keys) in [("Ctrl+C", [Key.ctrlC(korean: true)]), ("가+Ctrl+C", Key.latin("rk") + [.ctrlC(korean: true)]),
                            ("Cmd+C", [Key.cmd("c")]), ("가+Cmd+C", Key.latin("rk") + [.cmd("c")])] {
            kv.log = []
            k.mark()
            await post(keys, to: k.window, gapMs: 30)
            let bytes = await k.waitBytes(atLeast: 1, timeout: 0.6)
            print("== kitty \(flags) \(name)")
            print("   calls: \(kv.log.joined(separator: " | "))")
            print("   pty:   \(show(bytes))   preedit=\"\(kv.currentPreedit)\"")
            await post([.space], to: k.window)
        }
        k.window.close()
    }

    // Every shortcut (Shortcuts.swift), legacy and kitty 1 / 5 / 31, idle and after composing 가.
    print("== shortcut matrix, real Korean IME")
    let t0 = Date()
    var fails = await runShortcutMatrix(runtime: runtime, real: true, attach: { t in
        if let ctx = t.view.inputContext { ctx.selectedKeyboardInputSource = korean; ctx.activate() }
        await sleepMs(200)
    }, report: { name, ok, detail in
        print("\(ok ? "PASS" : "FAIL")  [real-IME] \(name)\(detail.isEmpty ? "" : "  -- \(detail)")")
    })
    await reportOptionAsAlt(real: true, attach: { t in
        if let ctx = t.view.inputContext { ctx.selectedKeyboardInputSource = korean; ctx.activate() }
        await sleepMs(200)
    }, report: { print("NOTE  [real-IME] \($0)  -- \($1)") })
    fails += await probeFocusChange(runtime: runtime, korean: korean)
    fails += await probeDeadKeys(runtime: runtime, korean: korean)
    fails += await probeCJK(runtime: runtime)
    print(String(format: "shortcut probe: %d failure(s), %.0fs", fails, Date().timeIntervalSince(t0)))
    return fails == 0 ? 0 : 1
}

/// 가 composing, then the keyboard moves to another pane (a click, ⇧⌘J, ⇧⌘H: keys the IME never
/// sees) and back: the syllable is committed or kept, never lost, and typing goes on normally.
@MainActor
func probeFocusChange(runtime: GhosttyRuntime, korean: String) async -> Int {
    let a = SinkTerminal(runtime: runtime, view: { RecordingSurfaceView(app: $0, options: $1) }, title: "probe focus")
    guard await a.waitReady() else { print("FAIL  [real-IME] focus terminal ready"); return 1 }
    let b = RecordingSurfaceView(app: runtime.app!, options: SurfaceOptions(command: "/bin/cat"))
    b.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
    a.view.addSubview(b)
    if let ctx = a.view.inputContext { ctx.selectedKeyboardInputSource = korean; ctx.activate() }
    await sleepMs(200)
    let v = a.view as! RecordingSurfaceView
    v.log = []
    a.mark()
    await post(Key.latin("rk"), to: a.window, gapMs: 30)
    a.window.makeFirstResponder(b)
    await sleepMs(300)
    let away = a.newBytes(), preeditAway = v.currentPreedit
    a.window.makeFirstResponder(v)
    await sleepMs(200)
    await post(Key.latin("dk "), to: a.window, gapMs: 30)
    let all = await a.waitBytes(atLeast: 7, timeout: 1)
    let ok = show(all) == "가아 " && v.currentPreedit.isEmpty
    print("\(ok ? "PASS" : "FAIL")  [real-IME] 가 composing, focus to another pane and back, then 아: \"가아 \" -- away: pty=\"\(show(away))\" preedit=\"\(preeditAway)\"; after: pty=\"\(show(all))\" preedit=\"\(v.currentPreedit)\" calls: \(v.log.joined(separator: " | "))")
    b.removeFromSuperview()
    a.window.close()
    return ok ? 0 : 1
}

/// Dead keys with the ABC layout (⌥E E = é ...), legacy and kitty 1: the Control / Command
/// codepoint mapping must not touch them. Then the same keys with the Korean source, reported.
@MainActor
func probeDeadKeys(runtime: GhosttyRuntime, korean: String) async -> Int {
    let abc = "com.apple.keylayout.ABC"
    let opt = { (c: Character) in Key(keyCode: KC.map[c]!, chars: "", mods: [.option]) }
    let cases: [(String, [Key], String)] = [
        ("⌥E E", [opt("e"), Key.ch("e")], "é"), ("⌥U U", [opt("u"), Key.ch("u")], "ü"),
        ("⌥N N", [opt("n"), Key.ch("n")], "ñ"), ("⌥` E", [opt("`"), Key.ch("e")], "è"),
        ("⌥E space", [opt("e"), .space], "´"), ("⌃C", [.ctrlC(korean: false)], "\u{03}"),
    ]
    var fails = 0
    for (source, expect) in [(abc, true), (korean, false)] {
        guard selectInputSource(source) else { print("SKIP  [real-IME] dead keys: \(source) is not enabled"); continue }
        await sleepMs(300)
        for flags in [0, 1] {
            let k = SinkTerminal(runtime: runtime, view: { RecordingSurfaceView(app: $0, options: $1) }, title: "probe dead keys",
                                 prelude: flags == 0 ? "" : "\\033[>\(flags)u")
            guard await k.waitReady() else { fails += 1; continue }
            if let ctx = k.view.inputContext { ctx.selectedKeyboardInputSource = source; ctx.activate() }
            await sleepMs(200)
            let mode = flags == 0 ? "legacy" : "kitty \(flags)"
            for (name, keys, want) in cases {
                k.mark()
                await post(keys, to: k.window, gapMs: 30)
                await sleepMs(180)
                let b = String(decoding: k.newBytes(), as: UTF8.self)
                let wantHere = flags == 0 || name != "⌃C" ? want : "\u{1b}[99;5u"
                let ok = !expect || b == wantHere
                print("\(ok ? "PASS" : "FAIL")  [real-IME] [\(source == abc ? "ABC" : "Korean"), \(mode)] \(name)\(expect ? " = \(show(Array(wantHere.utf8)))" : " (reported)") -- pty=\"\(show(Array(b.utf8)))\"\(jamoLeak(b) ? " JAMO LEAK" : "")")
                if !ok { fails += 1 }
                if !k.view.currentPreedit.isEmpty { await post([.escape], to: k.window) }
            }
            k.window.close()
        }
    }
    selectInputSource(korean)
    return fails
}

/// The REAL Chinese (Pinyin - Simplified, Zhuyin - Traditional) and Japanese (Romaji) IMEs, if enabled: each scenario's
/// NSTextInputClient calls and pty bytes, legacy and kitty 1, plus checks that hold whatever the IME's
/// own choices: the committed text arrives once, no raw letters or kana key codes leak, Ctrl+C and
/// ⌘V idle are what ABC sends, the candidate window is at the cursor. Skipped (with how to enable)
/// when the source isn't enabled; this never enables a source.
@MainActor
func probeCJK(runtime: GhosttyRuntime) async -> Int {
    let L = Key.latin
    let right = Key(keyCode: KC.right, chars: "\u{F703}", mods: [.numericPad, .function])
    let shiftRight = Key(keyCode: KC.right, chars: "\u{F703}", mods: [.shift, .numericPad, .function])
    let down = Key(keyCode: KC.down, chars: "\u{F701}", mods: [.numericPad, .function])
    let sources: [(String, String, String, [(String, [Key], String?)])] = [
        ("com.apple.inputmethod.SCIM.ITABC", "Pinyin", "Chinese, Simplified → Pinyin - Simplified", [
            ("nihao Space", L("nihao") + [.space], "你好"), ("nihao 1", L("nihao") + [Key.ch("1")], "你好"),
            ("nihao Enter", L("nihao") + [.enter], "nihao"), ("nihao Esc", L("nihao") + [.escape], ""),
            ("nihao ⌫×5", L("nihao") + Array(repeating: .backspace, count: 5), ""), ("idle ,", [Key.ch(",")], nil),
            ("nihao .", L("nihao") + [Key.ch(".")], nil), ("nihao ←", L("nihao") + [.left, .escape], nil),
            ("nihao ⌃C", L("nihao") + [.ctrlC(korean: false)], nil), ("nihao ⌘V", L("nihao") + [.cmd("v")], nil),
            ("nihao ⌘C", L("nihao") + [.cmd("c")], nil),
        ]),
        // Zhuyin's keys are pressed by key code (s u 3 = ㄋ ㄧ ˇ); which 你 / 妳 comes first is the user's dictionary's.
        ("com.apple.inputmethod.TCIM.Zhuyin", "Zhuyin", "Chinese, Traditional → Zhuyin", [
            ("ㄋㄧˇㄏㄠˇ Enter", L("su3cl3") + [.enter], nil), ("ㄋㄧˇ Esc", L("su3") + [.escape], ""),
            ("ㄋㄧ ⌫⌫", L("su") + [.backspace, .backspace], ""), ("ㄋㄧˇ ↓ 2 Enter", L("su3") + [Key(keyCode: KC.down, chars: "\u{F701}",
                mods: [.numericPad, .function]), Key.ch("2"), .enter, .enter], nil),
            ("ㄋㄧˇ ⌃C", L("su3") + [.ctrlC(korean: false)], nil), ("ㄋㄧˇ ⌘V", L("su3") + [.cmd("v")], nil),
        ]),
        ("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "Japanese", "Japanese → Romaji", [
            ("nihongo Space Enter", L("nihongo") + [.space, .enter], "日本語"), ("nihongo Enter", L("nihongo") + [.enter], "にほんご"),
            ("nihongo Esc", L("nihongo") + [.escape, .escape], ""), ("ka ⌫", L("ka") + [.backspace], ""),
            (". , Enter", [Key.ch("."), Key.ch(","), .enter], nil), ("1 Enter", [Key.ch("1"), .enter], nil),
            ("nihongo ⌃C", L("nihongo") + [.ctrlC(korean: false)], nil), ("nihongo Space ⌘V", L("nihongo") + [.space, .cmd("v")], nil),
            ("nihongo ⌘C", L("nihongo") + [.cmd("c")], nil),
            // One clause at a time (watashi no namae ha: 2+ clauses). The traces settle which calls the
            // IME makes: insertText with a replacementRange inside the marked text, the rest marked again
            // or not (SurfaceView.insertText handles both; CJKChecks.partialSteps).
            ("clauses Space → Enter", L("watashinonamaeha") + [.space, right, .enter], nil),
            ("clauses Space ⇧→ Enter", L("watashinonamaeha") + [.space, shiftRight, .enter], nil),
            ("clauses Space → ka Enter", L("watashinonamaeha") + [.space, right] + L("ka") + [.enter], nil),
            ("clauses Space ↓ Enter", L("watashinonamaeha") + [.space, down, .enter], nil),
        ]),
    ]
    var fails = 0
    let pb = GhosttyRuntime.standardPasteboard
    for (id, name, how, scenarios) in sources {
        guard selectInputSource(id) else {
            print("SKIP  [real-IME] \(name): \(id) is not enabled (System Settings → Keyboard → Text Input → Edit… → + → \(how); then rerun --visible --probe)")
            continue
        }
        await sleepMs(300)
        for flags in [0, 1] {
            let mode = flags == 0 ? "legacy" : "kitty \(flags)"
            let k = SinkTerminal(runtime: runtime, view: { RecordingSurfaceView(app: $0, options: $1) }, title: "probe \(name) \(mode)",
                                 prelude: flags == 0 ? "" : "\\033[>\(flags)u")
            NSApp.activate(ignoringOtherApps: true)
            guard await k.waitReady(), let v = k.view as? RecordingSurfaceView else { fails += 1; continue }
            if let ctx = v.inputContext { ctx.selectedKeyboardInputSource = id; ctx.activate() }
            await sleepMs(300)
            for (scenario, keys, want) in scenarios {
                pb.declareTypes([.string], owner: nil)
                pb.setString("lmux-paste-OK", forType: .string)
                v.log = []
                k.mark()
                // The candidate window, asked for right after the first composing key.
                await post(Array(keys.prefix(1)), to: k.window, gapMs: 30)
                var rectNote = ""
                if v.hasMarkedText() {
                    let cur = imePoint(v)
                    let fr = v.convert(k.window.convertFromScreen(v.firstRect(forCharacterRange: v.markedRange(), actualRange: nil)), from: nil)
                    rectNote = abs(fr.minX - cur.minX) < 0.6 ? " rect at cursor" : " RECT OFF (x=\(fr.minX), cursor \(cur.minX))"
                    if !rectNote.hasPrefix(" rect at") { fails += 1 }
                }
                await post(Array(keys.dropFirst()), to: k.window, gapMs: 30)
                let raw = String(decoding: await k.waitBytes(atLeast: 1, timeout: 0.8), as: UTF8.self)
                let b = dropReleases(raw)
                // Raw letters only where the IME commits them (Pinyin's Enter, ⌃C / ⌘ keys: reported).
                let leak = jamoLeak(b) || cjkKeyLeak(b) || (want != nil && want != "nihao" && b.contains("nihao")) || b.contains("nihongo") || b.contains("su")
                let ok = !leak && (want.map { b == $0 } ?? true)
                if !ok { fails += 1 }
                print("\(want == nil && !leak ? "NOTE" : ok ? "PASS" : "FAIL")  [real-IME] [\(name), \(mode)] \(scenario)\(want.map { " = \"\($0)\"" } ?? "")"
                      + " -- pty=\"\(show(Array(b.utf8)))\" preedit=\"\(v.currentPreedit)\"\(rectNote)\(leak ? " LEAK" : "")")
                print("      calls: \(v.log.joined(separator: " | "))")
                for _ in 0..<3 where !v.currentPreedit.isEmpty { await post([.escape], to: k.window) }
            }
            // Idle keys must be what ABC sends.
            let intr = flags == 0 ? "\u{03}" : "\u{1b}[99;5u"
            for (keyName, key, want) in [("⌃C", Key.ctrlC(korean: false), intr), ("⌘V", Key.cmd("v"), "lmux-paste-OK")] {
                pb.setString("lmux-paste-OK", forType: .string)
                k.mark()
                await post([key], to: k.window, gapMs: 30)
                let b = dropReleases(String(decoding: await k.waitBytes(atLeast: want.utf8.count, timeout: 0.8), as: UTF8.self))
                let ok = b == want
                if !ok { fails += 1 }
                print("\(ok ? "PASS" : "FAIL")  [real-IME] [\(name), \(mode)] idle \(keyName) = \"\(show(Array(want.utf8)))\" -- pty=\"\(show(Array(b.utf8)))\"")
            }
            k.window.close()
        }
    }
    return fails
}
