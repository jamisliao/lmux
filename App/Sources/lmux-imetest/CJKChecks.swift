import AppKit
import GhosttyKit
import LmuxTerminal

// Chinese (Pinyin, Zhuyin) and Japanese (Romaji, Kana Typing) with the simulated IMEs (SimulatedCJKIMEView),
// in legacy mode and the kitty modes Claude Code / Codex push (1, 5, 31). Every key sequence is also
// pressed in a terminal with the ABC source: what the pty gets with the IME must be exactly the text
// the IME committed plus what ABC sends for the keys the IME passed on. Nothing leaks (raw letters,
// kana / bopomofo as text or as a kitty key code), nothing is dropped or doubled.

extension Key {
    /// A letter key as Kana Typing delivers it: its kana (そ for C) as the text and ignoring modifiers.
    static func kana(_ c: Character) -> Key {
        let k = String(kanaKeys[c]!)
        return Key(keyCode: KC.map[c]!, chars: k, ign: k)
    }
    /// A key as Zhuyin delivers it: its bopomofo or tone mark (ㄏ for C, ˇ for 3).
    static func zhuyin(_ c: Character) -> Key {
        let k = String(zhuyinKeys[c]!)
        return Key(keyCode: KC.map[c]!, chars: k, ign: k)
    }
    /// ⌘ / ⌃ + letter, with the key's own character (ignoring modifiers) as the source gives it
    /// (`layout`: the input method's key characters, kana or bopomofo; ABC when nil).
    static func mod(_ c: Character, _ mods: NSEvent.ModifierFlags, layout: [Character: Character]? = nil) -> Key {
        let chars = mods.contains(.control) && !mods.contains(.command) ? String(UnicodeScalar(c.asciiValue! & 0x1f)) : String(c)
        return Key(keyCode: KC.map[c]!, chars: chars, mods: mods, ign: String(layout?[c] ?? c))
    }
    /// Shift pressed and released alone (flagsChanged; Pinyin switches 中 / 英 on it).
    static let shiftTap = Key(keyCode: 56, chars: "")
}

/// What the pty must get: committed text (encoded like any committed text) and keys (what ABC sends).
enum Part { case text(String), keys([Key]) }

struct CJKStep {
    let name: String
    let keys: [Key]
    let expect: [Part]
    var preedit = ""
    /// Set on the IME before the keys are pressed.
    var setup: ((SimulatedCJKIMEView) -> Void)? = nil
}

/// The bytes as the app reads them: without key-release reports (flag 2: a key the IME consumed still
/// reports its release, as upstream Ghostty does) and modifier-key reports (Shift: CSI 57441 u), and
/// flag 8's text keys (CSI 44;;65292u for ，) as their text.
func normalizeKitty(_ s: String) -> String {
    let t = s.replacingOccurrences(of: "\u{1b}\\[[0-9:]*;[0-9]+:3(;[0-9:]+)?[A-Za-z~]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\u{1b}\\[574(4[1-9]|5[0-4])[;:0-9]*u", with: "", options: .regularExpression)
    let re = try! NSRegularExpression(pattern: "\u{1b}\\[[0-9:]+;[0-9:]*;([0-9:]+)u")
    var out = t
    for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
        let cps = (t as NSString).substring(with: m.range(at: 1)).split(separator: ":").compactMap { UInt32($0).flatMap(UnicodeScalar.init) }
        out = (out as NSString).replacingCharacters(in: m.range, with: String(String.UnicodeScalarView(cps)))
    }
    return out
}

/// A kana / bopomofo / jamo key code in a CSI sequence (kitty: Ctrl+そ instead of Ctrl+C). Stray text
/// is caught by comparing the bytes with ABC's.
func cjkKeyLeak(_ s: String) -> Bool {
    let re = try! NSRegularExpression(pattern: "\u{1b}\\[([0-9;:]*)[A-Za-z~]")
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).contains { m in
        (s as NSString).substring(with: m.range(at: 1)).split(whereSeparator: { $0 == ";" || $0 == ":" })
            .contains { UInt32($0).map(Ghostty.isInputMethodKeyCharacter) ?? false }
    }
}

@MainActor
func postCJK(_ keys: [Key], to window: NSWindow) async {
    for k in keys {
        guard k.keyCode == Key.shiftTap.keyCode else { await post([k], to: window); continue }
        for mods in [NSEvent.ModifierFlags.shift, []] {
            let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: mods,
                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
            NSApp.postEvent(e, atStart: true)
            if let d = NSApp.nextEvent(matching: .flagsChanged, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(d) }
        }
        await sleepMs(30)
    }
    await sleepMs(60)
}

func cjkSteps(_ kind: SimulatedCJKIMEView.Kind) -> [CJKStep] {
    let L = Key.latin
    let ctrlC = Key.mod("c", [.control]), cmdV = Key.mod("v", [.command])
    let idle: [CJKStep] = [
        CJKStep(name: "idle Enter, Shift+Enter, Esc, Tab, arrows, ⌫ (as ABC)",
                keys: [.enter, .shiftEnter, .escape, Key(keyCode: KC.tab, chars: "\t"), .left,
                       Key(keyCode: KC.up, chars: "\u{F700}", mods: [.numericPad, .function]), .backspace],
                expect: [.keys([.enter, .shiftEnter, .escape, Key(keyCode: KC.tab, chars: "\t"), .left,
                                Key(keyCode: KC.up, chars: "\u{F700}", mods: [.numericPad, .function]), .backspace])]),
    ]
    switch kind {
    case .pinyin:
        return idle + [
            CJKStep(name: "nihao Space → 你好", keys: L("nihao") + [.space], expect: [.text("你好")]),
            CJKStep(name: "nihao 2 → 拟好 (no digit leaks)", keys: L("nihao") + [Key.ch("2")], expect: [.text("拟好")]),
            CJKStep(name: "nihao Enter → the letters, Enter consumed", keys: L("nihao") + [.enter], expect: [.text("nihao")]),
            CJKStep(name: "nihao Esc → nothing", keys: L("nihao") + [.escape], expect: []),
            CJKStep(name: "nihao ⌫×5 → nothing, then ⌫ → DEL", keys: L("nihao") + Array(repeating: .backspace, count: 6),
                    expect: [.keys([.backspace])]),
            CJKStep(name: "nihao . → 你好。 (full-width)", keys: L("nihao") + [Key.ch(".")], expect: [.text("你好。")]),
            CJKStep(name: "idle , → ，", keys: [Key.ch(",")], expect: [.text("，")]),
            CJKStep(name: "nihao ← moves the caret in the composition, sends nothing", keys: L("nihao") + [.left], expect: [], preedit: "nihao"),
            CJKStep(name: "nihao ↓ pages candidates, sends nothing", keys: L("nihao") + [Key(keyCode: KC.down, chars: "\u{F701}", mods: [.numericPad, .function])],
                    expect: [], preedit: "nihao"),
            CJKStep(name: "nihao ← ← Space → 你好 (no arrow leaks)", keys: L("nihao") + [.left, .left, .space], expect: [.text("你好")]),
            CJKStep(name: "first syllable after Enter: ni Space → 你", keys: [.enter] + L("ni") + [.space],
                    expect: [.keys([.enter]), .text("你")]),
            CJKStep(name: "Shift mid-word: ni ⇧ a ⇧ hao Space → nia好", keys: L("ni") + [.shiftTap] + L("a") + [.shiftTap] + L("hao") + [.space],
                    expect: [.text("ni"), .text("a"), .text("好")]),
            CJKStep(name: "idle ⌃C → the interrupt", keys: [ctrlC], expect: [.keys([ctrlC])]),
            CJKStep(name: "nihao ⌃C → nihao, then the interrupt", keys: L("nihao") + [ctrlC], expect: [.text("nihao"), .keys([ctrlC])]),
            CJKStep(name: "idle ⌘V pastes once", keys: [cmdV], expect: [.keys([cmdV])]),
            CJKStep(name: "nihao ⌘V → nihao, then the paste", keys: L("nihao") + [cmdV], expect: [.text("nihao"), .keys([cmdV])]),
        ]
    case .zhuyin:
        let Z = { (s: String) in s.map(Key.zhuyin) }
        let kc = { (c: Character, m: NSEvent.ModifierFlags) in Key.mod(c, m, layout: zhuyinKeys) }
        let nihao = Z("su3cl3") // ㄋㄧˇ ㄏㄠˇ
        let down = Key(keyCode: KC.down, chars: "\u{F701}", mods: [.numericPad, .function])
        return idle + [
            CJKStep(name: "ㄋㄧˇㄏㄠˇ Enter → 你好", keys: nihao + [.enter], expect: [.text("你好")]),
            CJKStep(name: "ㄋㄧˇ → preedit 你 (the tone key ˇ sends nothing)", keys: Z("su3"), expect: [], preedit: "你"),
            CJKStep(name: "ㄓㄨㄥ Space ㄨㄣˊ Enter → 中文 (Space is the first tone)", keys: Z("5j/") + [.space] + Z("jp6") + [.enter],
                    expect: [.text("中文")]),
            CJKStep(name: "ㄋㄧˇ ↓ 2 Enter → 妳 (candidate 2)", keys: Z("su3") + [down, Key.zhuyin("2"), .enter], expect: [.text("妳")]),
            CJKStep(name: "ㄋㄧˇ Space Space Enter Enter → 妳 (the next candidate)", keys: Z("su3") + [.space, .space, .enter, .enter],
                    expect: [.text("妳")]),
            CJKStep(name: "ㄋㄧˇㄏㄠˇ Esc → nothing", keys: nihao + [.escape], expect: []),
            CJKStep(name: "ㄋㄧˇㄏㄠˇ ⌫ → preedit 你", keys: nihao + [.backspace], expect: [], preedit: "你"),
            CJKStep(name: "ㄋㄧ ⌫ ⌫ → nothing, then ⌫ → DEL", keys: Z("su") + [.backspace, .backspace, .backspace], expect: [.keys([.backspace])]),
            CJKStep(name: "ㄋㄧˇㄏㄠˇ ← stays composing", keys: nihao + [.left], expect: [], preedit: "你好"),
            CJKStep(name: "ㄋㄧˇㄏㄠˇ ← ㄨㄣˊ Enter → 你文好 (typed at the caret)", keys: nihao + [.left] + Z("jp6") + [.enter],
                    expect: [.text("你文好")]),
            CJKStep(name: "first syllable after Enter: ㄋㄧˇ Enter → 你", keys: [.enter] + Z("su3") + [.enter],
                    expect: [.keys([.enter]), .text("你")]),
            CJKStep(name: "idle ⌃C (key ㄏ) → the interrupt, not ⌃ㄏ", keys: [kc("c", [.control])], expect: [.keys([ctrlC])]),
            CJKStep(name: "ㄋㄧˇ ⌃C → 你, then the interrupt", keys: Z("su3") + [kc("c", [.control])], expect: [.text("你"), .keys([ctrlC])]),
            CJKStep(name: "idle ⌃A ⌃E ⌃R ⌃U (keys ㄇ ㄍ ㄐ ㄧ) as ABC",
                    keys: [kc("a", [.control]), kc("e", [.control]), kc("r", [.control]), kc("u", [.control])],
                    expect: [.keys([Key.mod("a", [.control]), Key.mod("e", [.control]), Key.mod("r", [.control]), Key.mod("u", [.control])])]),
            CJKStep(name: "idle ⌘V (key ㄒ) pastes once", keys: [kc("v", [.command])], expect: [.keys([cmdV])]),
            CJKStep(name: "ㄋㄧˇ ⌘V → 你, then the paste", keys: Z("su3") + [kc("v", [.command])], expect: [.text("你"), .keys([cmdV])]),
        ]
    case .romaji:
        return idle + [
            CJKStep(name: "nihongo Space Enter → 日本語", keys: L("nihongo") + [.space, .enter], expect: [.text("日本語")]),
            CJKStep(name: "nihongo Enter → にほんご, Enter consumed", keys: L("nihongo") + [.enter], expect: [.text("にほんご")]),
            CJKStep(name: "kanji Space Space Enter → 感じ (2nd candidate)", keys: L("kanji") + [.space, .space, .enter], expect: [.text("感じ")]),
            CJKStep(name: "nihongo Space Esc Enter → にほんご", keys: L("nihongo") + [.space, .escape, .enter], expect: [.text("にほんご")]),
            CJKStep(name: "nihongo Esc → nothing", keys: L("nihongo") + [.escape], expect: []),
        ] + partialSteps(L("nihongo") + [.space, .enter]) + [
            CJKStep(name: "nihongo Space ⌫ → preedit 日本 (only the last character goes)", keys: L("nihongo") + [.space, .backspace],
                    expect: [], preedit: "日本"),
            CJKStep(name: "nihongo Space ⌫ Enter → 日本", keys: L("nihongo") + [.space, .backspace, .enter], expect: [.text("日本")]),
            CJKStep(name: "ka ⌫ → nothing, then ⌫ → DEL", keys: L("ka") + [.backspace, .backspace], expect: [.keys([.backspace])]),
            CJKStep(name: "kanji Space, then typing commits 漢字: nihongo Space Enter", keys: L("kanji") + [.space] + L("nihongo") + [.space, .enter],
                    expect: [.text("漢字"), .text("日本語")]),
            CJKStep(name: ". , Enter → 。、", keys: [Key.ch("."), Key.ch(","), .enter], expect: [.text("。、")]),
            CJKStep(name: "1 Enter → 1 (no digit leaks)", keys: [Key.ch("1"), .enter], expect: [.text("1")]),
            CJKStep(name: "nihongo ← stays composing", keys: L("nihongo") + [.left], expect: [], preedit: "にほんご"),
            CJKStep(name: "first character after Enter: ka Enter → か", keys: [.enter] + L("ka") + [.enter], expect: [.keys([.enter]), .text("か")]),
            CJKStep(name: "idle ⌃C → the interrupt", keys: [ctrlC], expect: [.keys([ctrlC])]),
            CJKStep(name: "nihongo ⌃C → にほんご, then the interrupt", keys: L("nihongo") + [ctrlC], expect: [.text("にほんご"), .keys([ctrlC])]),
            CJKStep(name: "nihongo Space ⌃C → 日本語, then the interrupt", keys: L("nihongo") + [.space, ctrlC], expect: [.text("日本語"), .keys([ctrlC])]),
            CJKStep(name: "idle ⌘V pastes once", keys: [cmdV], expect: [.keys([cmdV])]),
            CJKStep(name: "nihongo Space ⌘V → 日本語, then the paste", keys: L("nihongo") + [.space, cmdV], expect: [.text("日本語"), .keys([cmdV])]),
        ]
    case .kana:
        let K = Key.kana
        let kc = { (c: Character, m: NSEvent.ModifierFlags) in Key.mod(c, m, layout: kanaKeys) }
        return idle + [
            CJKStep(name: "かな Space Enter → 仮名", keys: [K("t"), K("u"), .space, .enter], expect: [.text("仮名")]),
            CJKStep(name: "かな Enter → かな", keys: [K("t"), K("u"), .enter], expect: [.text("かな")]),
            CJKStep(name: "idle ⌃C (key そ) → the interrupt, not ⌃そ", keys: [kc("c", [.control])], expect: [.keys([ctrlC])]),
            CJKStep(name: "かな ⌃C → かな, then the interrupt", keys: [K("t"), K("u"), kc("c", [.control])], expect: [.text("かな"), .keys([ctrlC])]),
            CJKStep(name: "idle ⌃A ⌃E ⌃R ⌃U (keys ち い す な) as ABC",
                    keys: [kc("a", [.control]), kc("e", [.control]), kc("r", [.control]), kc("u", [.control])],
                    expect: [.keys([Key.mod("a", [.control]), Key.mod("e", [.control]), Key.mod("r", [.control]), Key.mod("u", [.control])])]),
            CJKStep(name: "idle ⌘V (key ひ) pastes once", keys: [kc("v", [.command])], expect: [.keys([cmdV])]),
            CJKStep(name: "かな ⌘V → かな, then the paste", keys: [K("t"), K("u"), kc("v", [.command])], expect: [.text("かな"), .keys([cmdV])]),
        ]
    }
}

/// Replacement ranges inside the marked text 日本語, at the Enter that would confirm it. An IME that
/// confirms one clause may mark the rest again (no "語" twice) or, as NSTextView has it, treat the
/// rest as confirmed (no "語" lost); an empty range is an insertion only strictly inside the marked
/// text: at either end it is the caret / `selectedRange()` ({0, 0}) and means all of it, so 하 + 한
/// can't become "한하".
func partialSteps(_ keys: [Key]) -> [CJKStep] {
    let none = NSRange(location: NSNotFound, length: 0)
    func r(_ l: Int, _ n: Int) -> NSRange { NSRange(location: l, length: n) }
    func step(_ name: String, _ expect: [Part], preedit: String = "", _ calls: @escaping (SimulatedCJKIMEView) -> Void) -> CJKStep {
        CJKStep(name: "日本語 Enter: " + name, keys: keys, expect: expect, preedit: preedit, setup: { $0.onEnter = calls })
    }
    return [
        step("insertText(二本, 0-2) → 二本語 (the rest, not marked again, is committed)", [.text("二本語")]) {
            $0.insertText("二本", replacementRange: r(0, 2))
        },
        step("insertText(二本, 0-2) setMarkedText(語) → 二本, 語 still marked (not twice)", [.text("二本")], preedit: "語") {
            $0.insertText("二本", replacementRange: r(0, 2)); $0.setMarkedText("語", selectedRange: r(1, 0), replacementRange: none)
        },
        step("insertText(二本, 0-2) setMarkedText(k) → 二本語, k marked", [.text("二本語")], preedit: "k") {
            $0.insertText("二本", replacementRange: r(0, 2)); $0.setMarkedText("k", selectedRange: r(1, 0), replacementRange: none)
        },
        step("insertText(二本, 0-2) insertText(。) → 二本語。", [.text("二本語。")]) {
            $0.insertText("二本", replacementRange: r(0, 2)); $0.insertText("。", replacementRange: none)
        },
        step("insertText(二本, 0-2) unmarkText → 二本語", [.text("二本語")]) {
            $0.insertText("二本", replacementRange: r(0, 2)); $0.unmarkText()
        },
        step("insertText(x, 1-1 empty) → 日x本語 (inserted inside)", [.text("日x本語")]) {
            $0.insertText("x", replacementRange: r(1, 0))
        },
        step("insertText(日本語, 3-3 empty, the end) → 日本語 once", [.text("日本語")]) {
            $0.insertText("日本語", replacementRange: r(3, 0))
        },
        step("insertText(日本語, 0-0 empty, selectedRange) → 日本語 once", [.text("日本語")]) {
            $0.insertText("日本語", replacementRange: r(0, 0))
        },
        step("setMarkedText(X, 1-1 empty) → marked 日X本語", [], preedit: "日X本語") {
            $0.setMarkedText("X", selectedRange: r(1, 0), replacementRange: r(1, 0))
        },
        step("setMarkedText(にほん, 0-0 empty) → marked にほん, not にほん日本語", [], preedit: "にほん") {
            $0.setMarkedText("にほん", selectedRange: r(3, 0), replacementRange: r(0, 0))
        },
        step("setMarkedText(X, 3-3 empty) → marked X, not 日本語X", [], preedit: "X") {
            $0.setMarkedText("X", selectedRange: r(1, 0), replacementRange: r(3, 0))
        },
    ]
}

@MainActor
func runCJKChecks(_ r: Report, runtime: GhosttyRuntime) async {
    let pb = GhosttyRuntime.standardPasteboard
    var newTabCount = 0
    runtime.onAction = { tag, _ in if tag == GHOSTTY_ACTION_NEW_TAB { newTabCount += 1 } }
    defer { runtime.onAction = nil }

    await runCJKCandidateWindowChecks(r, runtime: runtime)
    await runCJKRenderChecks(r, runtime: runtime)

    for flags in [0, 1, 5, 31] {
        let mode = flags == 0 ? "legacy" : "kitty \(flags)"
        let prelude = flags == 0 ? "" : "\\033[>\(flags)u"
        let abc = SinkTerminal(runtime: runtime, view: { RecordingSurfaceView(app: $0, options: $1) }, title: "cjk abc \(mode)", prelude: prelude)
        guard await abc.waitReady() else { r.check("[\(mode)] ABC terminal ready", false); continue }
        await sleepMs(150)
        /// ABC's bytes for each part (committed text is sent as the IME's text would be).
        func reference(_ parts: [Part]) async -> String {
            var out = ""
            for p in parts {
                abc.mark()
                switch p {
                case .text(let s):
                    abc.view.sendText(s)
                    out += String(decoding: await abc.waitBytes(atLeast: s.utf8.count, timeout: 1), as: UTF8.self)
                case .keys(let ks):
                    await post(ks, to: abc.window)
                    out += String(decoding: await abc.waitBytes(atLeast: 1, timeout: 0.4), as: UTF8.self)
                }
            }
            return out
        }

        for kind in [SimulatedCJKIMEView.Kind.pinyin, .zhuyin, .romaji, .kana] {
            let t = SinkTerminal(runtime: runtime, view: { app, o in
                let v = SimulatedCJKIMEView(app: app, options: o); v.kind = kind; return v
            }, title: "cjk \(kind.rawValue) \(mode)", prelude: prelude)
            guard await t.waitReady(), let v = t.view as? SimulatedCJKIMEView else { r.check("[\(kind.rawValue), \(mode)] terminal ready", false); continue }
            await sleepMs(150)
            let tag = "[\(kind.rawValue), \(mode)]"

            for step in cjkSteps(kind) {
                pb.declareTypes([.string], owner: nil)
                pb.setString("lmux-paste-OK", forType: .string)
                let want = normalizeKitty(await reference(step.expect))
                v.log = []
                step.setup?(v)
                t.mark()
                await postCJK(step.keys, to: t.window)
                let raw = String(decoding: await t.waitBytes(atLeast: max(1, want.utf8.count), timeout: want.isEmpty ? 0.3 : 1), as: UTF8.self)
                let got = normalizeKitty(raw)
                let leak = cjkKeyLeak(got)
                let ok = got == want && v.currentPreedit == step.preedit && !leak
                r.check("\(tag) \(step.name)", ok,
                        "pty=\"\(show(Array(got.utf8)))\" expected \"\(show(Array(want.utf8)))\" preedit=\"\(v.currentPreedit)\"\(leak ? " KEY LEAK" : "")"
                        + (ok ? "" : " calls: \(v.log.joined(separator: " | "))"))
                for _ in 0..<3 where !v.currentPreedit.isEmpty { await post([.escape], to: t.window) }
                if !v.currentPreedit.isEmpty { v.setMarkedText("", selectedRange: NSRange(), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                await sleepMs(30)
                t.mark()
            }

            // ⌘T fires once (idle and composing), ⌘C copies the selection and types nothing.
            let layout: [Character: Character]? = kind == .kana ? kanaKeys : kind == .zhuyin ? zhuyinKeys : nil
            let (compose, committed): ([Key], String) = switch kind {
            case .kana: ([.kana("t"), .kana("u")], "かな")
            case .zhuyin: ("su3".map(Key.zhuyin), "你")
            case .pinyin: (Key.latin("nihao"), "nihao")
            case .romaji: (Key.latin("nihongo"), "にほんご")
            }
            newTabCount = 0
            t.mark()
            await post([Key.mod("t", [.command], layout: layout)], to: t.window)
            await sleepMs(100)
            let idleTabs = newTabCount, idleBytes = t.newBytes()
            t.mark()
            await post(compose + [Key.mod("t", [.command], layout: layout)], to: t.window)
            let compBytes = String(decoding: await t.waitBytes(atLeast: committed.utf8.count, timeout: 1), as: UTF8.self)
            r.check("\(tag) ⌘T opens one tab (idle and composing; composing commits \(committed) first)",
                    idleTabs == 1 && newTabCount == 2 && idleBytes.isEmpty && normalizeKitty(compBytes) == committed,
                    "new_tab idle=\(idleTabs) total=\(newTabCount) pty idle=\"\(show(idleBytes))\" composing=\"\(show(Array(compBytes.utf8)))\"")

            pb.declareTypes([.string], owner: nil)
            pb.setString("before-copy", forType: .string)
            v.performBindingAction("select_all")
            await sleepMs(100)
            t.mark()
            await post([Key.mod("c", [.command], layout: layout)], to: t.window)
            await sleepMs(150)
            let copied = pb.string(forType: .string) ?? ""
            let cc = normalizeKitty(String(decoding: t.newBytes(), as: UTF8.self))
            r.check("\(tag) ⌘C with a selection copies it, types nothing", copied != "before-copy" && !copied.isEmpty && cc.isEmpty,
                    "clipboard=\"\(copied.suffix(30))\" pty=\"\(show(Array(cc.utf8)))\"")
            t.window.close()
        }
        abc.window.close()
    }
}

/// The candidate window: `firstRect(forCharacterRange:)` while composing is at the cursor cell in screen
/// coordinates (any backing scale, the pane inside the window as with the sidebar or a split), also with a
/// selection on screen, and inside a converted preedit it is at the clause (日本語: 本 is 2 cells in).
@MainActor
func runCJKCandidateWindowChecks(_ r: Report, runtime: GhosttyRuntime) async {
    for kind in [SimulatedCJKIMEView.Kind.pinyin, .romaji] {
        let t = SinkTerminal(runtime: runtime, view: { app, o in
            let v = SimulatedCJKIMEView(app: app, options: o); v.kind = kind; return v
        }, title: "cjk rect \(kind.rawValue)", frame: NSRect(x: 200, y: 200, width: 840, height: 300))
        guard await t.waitReady(), let v = t.view as? SimulatedCJKIMEView else { r.check("[\(kind.rawValue)] rect terminal ready", false); continue }
        // The pane 180pt in from the window's left edge (the sidebar).
        let container = NSView(frame: NSRect(origin: .zero, size: t.window.frame.size))
        t.window.contentView = container
        v.frame = NSRect(x: 180, y: 0, width: container.frame.width - 180, height: container.frame.height)
        container.addSubview(v)
        t.window.makeFirstResponder(v)
        await sleepMs(400)
        let tag = "[\(kind.rawValue)]"
        let scale = t.window.backingScaleFactor
        v.sendText("ab")
        _ = await t.waitBytes(atLeast: 2)
        await sleepMs(150)
        let cur = imePoint(v), cell = v.cellSize
        func expect(cells: Int) -> NSPoint {
            NSPoint(x: t.window.frame.minX + 180 + cur.minX + Double(cells) * cell.width, y: t.window.frame.minY + v.frame.height - cur.minY)
        }
        func near(_ a: NSPoint, _ b: NSPoint) -> Bool { abs(a.x - b.x) < 0.6 && abs(a.y - b.y) < 0.6 }

        await post(Key.latin(kind == .pinyin ? "nihao" : "nihongo"), to: t.window)
        await sleepMs(150)
        let marked = v.markedRange()
        let whole = v.firstRect(forCharacterRange: marked, actualRange: nil)
        r.check("\(tag) candidate window at the cursor while composing (screen coords, pane offset 180pt, scale \(scale))",
                near(whole.origin, expect(cells: 0)) && marked.length > 0,
                "rect=\(whole) expected origin \(expect(cells: 0)) markedRange=\(marked) preedit=\"\(v.currentPreedit)\"")
        // Text selected (a mouse drag) while the preedit is up: still the cursor, not the selection.
        v.performBindingAction("select_all")
        await sleepMs(100)
        let sel = v.firstRect(forCharacterRange: marked, actualRange: nil)
        r.check("\(tag) candidate window stays at the cursor when text is selected mid-composition",
                v.hasSelection && near(sel.origin, expect(cells: 0)), "rect=\(sel) selection=\(v.hasSelection)")

        if kind == .romaji {
            await post([.space], to: t.window)
            await sleepMs(150)
            let clause = v.firstRect(forCharacterRange: NSRange(location: 1, length: 2), actualRange: nil)
            r.check("\(tag) candidate window at the clause inside 日本語 (本語: 2 cells in, 4 wide)",
                    v.currentPreedit == "日本語" && near(clause.origin, expect(cells: 2)) && abs(clause.width - 4 * cell.width) < 0.6,
                    "rect=\(clause) expected origin \(expect(cells: 2)) width \(4 * cell.width) preedit=\"\(v.currentPreedit)\"")
        }

        // The preedit is drawn at the cursor, nowhere else.
        let cells = kind == .pinyin ? 5 : 6
        if let f = grabFrame(v), let size = v.surfaceSize {
            let cw = Double(size.cell_width_px), ch = Double(size.cell_height_px)
            let x0 = (cur.minX - cell.width / 2) * scale, top = cur.minY * scale - ch
            let px = { (c: Double) in Int((x0 + c * cw).rounded()) }
            let ink = inkBox(f, x0: px(0), x1: px(Double(cells)), y0: Int(top), y1: Int(top + ch))
            let after = inkBox(f, x0: px(Double(cells)) + 2, x1: px(Double(cells) + 10), y0: Int(top), y1: Int(top + ch))
            r.check("\(tag) preedit \"\(v.currentPreedit)\" is rendered at the cursor (\(cells) cells), nowhere else",
                    ink != nil && after == nil, "ink=\(String(describing: ink)) right of it=\(String(describing: after))")
        } else {
            r.check("\(tag) preedit is rendered at the cursor", false, "no frame")
        }
        for _ in 0..<3 where !v.currentPreedit.isEmpty { await post([.escape], to: t.window) }
        t.window.close()
    }
}

/// How much ink a pixel rect holds (sum of the distance from the background), for weight comparisons.
func inkMass(_ f: Frame, x0: Int, x1: Int, y0: Int, y1: Int) -> Int {
    let bg = f.rgb(f.w - 3, f.h - 3)
    var m = 0
    for y in max(0, y0)..<min(f.h, y1) {
        for x in max(0, x0)..<min(f.w, x1) {
            let p = f.rgb(x, y)
            m += abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2)
        }
    }
    return m
}

/// The preedit as drawn: the IME's caret inside a composition (manaflow-ai/cmux#1521) and the glyph
/// weight with `font-thicken` (manaflow-ai/cmux#32410).
@MainActor
func runCJKRenderChecks(_ r: Report, runtime: GhosttyRuntime) async {
    func terminal(_ rt: GhosttyRuntime, _ kind: SimulatedCJKIMEView.Kind, _ title: String) async -> (SinkTerminal, SimulatedCJKIMEView)? {
        let t = SinkTerminal(runtime: rt, view: { app, o in
            let v = SimulatedCJKIMEView(app: app, options: o); v.kind = kind; return v
        }, title: title)
        guard await t.waitReady(), let v = t.view as? SimulatedCJKIMEView else { return nil }
        await sleepMs(300)
        return (t, v)
    }
    // Pixel geometry of the cursor cell (x0 = its left edge) in backing pixels.
    func geometry(_ v: SurfaceView) -> (x0: Double, top: Int, cw: Double, ch: Int)? {
        guard let size = v.surfaceSize else { return nil }
        let p = imePoint(v), s = v.window?.backingScaleFactor ?? 2
        let cw = Double(size.cell_width_px), ch = Int(size.cell_height_px)
        return ((p.minX - v.cellSize.width / 2) * s, Int(p.minY * s) - ch, cw, ch)
    }

    // The caret: "nihao" with the caret at the end draws no bar; ← ← puts it before "a": the frames
    // differ only around that cell boundary (col 3 of the preedit).
    if let (t, v) = await terminal(runtime, .pinyin, "cjk caret") {
        await post(Key.latin("nihao"), to: t.window)
        await sleepMs(250)
        let g = geometry(v), end = grabFrame(v)
        await post([.left, .left], to: t.window)
        await sleepMs(250)
        let mid = grabFrame(v)
        var detail = "no frame"
        var ok = false
        if let g, let a = end, let b = mid, a.w == b.w, a.h == b.h {
            let edge = Int((g.x0 + 3 * g.cw).rounded())
            var diffX: [Int] = []
            for y in g.top..<(g.top + g.ch) {
                for x in max(0, Int(g.x0) - 4)..<min(a.w, Int(g.x0 + 8 * g.cw)) where a.rgb(x, y) != b.rgb(x, y) { diffX.append(x) }
            }
            ok = !diffX.isEmpty && diffX.allSatisfy { abs($0 - edge) <= Int(g.cw / 2) }
            detail = "changed pixels x=\(diffX.min() ?? -1)...\(diffX.max() ?? -1), caret edge x=\(edge), cell \(g.cw)px, preedit=\"\(v.currentPreedit)\""
        }
        r.check("[Pinyin] caret inside the composition (nihao ← ←) is drawn before \"a\", and only there", ok, detail)
        for _ in 0..<2 where !v.currentPreedit.isEmpty { await post([.escape], to: t.window) }
        t.window.close()
    }

    // font-thicken: the preedit gains weight like committed text does.
    var mass: [Bool: (preedit: Int, committed: Int)] = [:]
    for thicken in [false, true] {
        guard let rt = GhosttyRuntime(simulatedUserConfig: ["font-thicken = \(thicken)", "font-thicken-strength = 255"], fontProfile: .korean),
              let (t, v) = await terminal(rt, .romaji, "cjk thicken \(thicken)"), let g0 = geometry(v) else {
            r.check("[font-thicken \(thicken)] terminal ready", false); continue
        }
        keepAlive.append(rt)
        // Glyph rows only: the preedit's underline sits at the bottom of the cell.
        let rows = (g0.top, g0.top + g0.ch * 7 / 10)
        let span = (Int(g0.x0), Int(g0.x0 + 6 * g0.cw))
        await post(Key.latin("nihongo") + [.space], to: t.window)
        await sleepMs(300)
        let pre = grabFrame(v).map { inkMass($0, x0: span.0, x1: span.1, y0: rows.0, y1: rows.1) } ?? 0
        await post([.enter], to: t.window)
        _ = await t.waitBytes(atLeast: 9)
        await sleepMs(300)
        let com = grabFrame(v).map { inkMass($0, x0: span.0, x1: span.1, y0: rows.0, y1: rows.1) } ?? 0
        mass[thicken] = (pre, com)
        t.window.close()
    }
    if let off = mass[false], let on = mass[true], off.preedit > 0, off.committed > 0 {
        let rp = Double(on.preedit) / Double(off.preedit), rc = Double(on.committed) / Double(off.committed)
        r.check("[font-thicken] the preedit 日本語 thickens like committed text (ink ×\(String(format: "%.2f", rp)) vs ×\(String(format: "%.2f", rc)))",
                rc > 1.02 && rp > 1.02 && abs(rp - rc) < 0.15 * rc,
                "ink preedit off/on=\(off.preedit)/\(on.preedit) committed off/on=\(off.committed)/\(on.committed)")
    } else {
        r.check("[font-thicken] preedit weight measured", false, "\(mass)")
    }
}
