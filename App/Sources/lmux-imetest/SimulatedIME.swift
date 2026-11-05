import AppKit
import LmuxTerminal

/// Hangul 2-Set (두벌식) composition automaton.
struct HangulComposer {
    static let cho: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let jung: [Character] = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    static let jong: [Character] = Array(" ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")

    static let keymap: [Character: Character] = [
        "q": "ㅂ", "Q": "ㅃ", "w": "ㅈ", "W": "ㅉ", "e": "ㄷ", "E": "ㄸ", "r": "ㄱ", "R": "ㄲ",
        "t": "ㅅ", "T": "ㅆ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "O": "ㅒ", "p": "ㅔ",
        "P": "ㅖ", "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ",
        "k": "ㅏ", "l": "ㅣ", "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ",
        "m": "ㅡ",
    ]
    static let vowelPairs: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ",
    ]
    static let finalPairs: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",
        "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ",
    ]

    var c: Character?
    var v: Character?
    var f: Character?

    var isEmpty: Bool { c == nil && v == nil && f == nil }

    var text: String {
        if let c, let v {
            let ci = Self.cho.firstIndex(of: c)!, vi = Self.jung.firstIndex(of: v)!
            let fi = f.flatMap { Self.jong.firstIndex(of: $0) } ?? 0
            return String(UnicodeScalar(0xAC00 + (ci * 21 + vi) * 28 + fi)!)
        }
        return [c, v, f].compactMap { $0 }.map(String.init).joined()
    }

    private static func split(_ f: Character) -> (Character, Character)? {
        finalPairs.first { $0.value == f }.map { (Array($0.key)[0], Array($0.key)[1]) }
    }

    /// Feed one jamo. Returns the syllable committed by this input, if any.
    mutating func add(_ j: Character) -> String? {
        let isVowel = Self.jung.contains(j)
        if !isVowel {
            if c != nil, v != nil {
                if f == nil, Self.jong.contains(j) { f = j; return nil }
                if let f, let pair = Self.finalPairs[String([f, j])] { self.f = pair; return nil }
            }
            let out = isEmpty ? nil : text
            (c, v, f) = (j, nil, nil)
            return out
        }
        // Vowel
        if let f, c != nil, v != nil {
            // The final consonant (or its second half) moves to the next syllable.
            let (keep, move): (Character?, Character) = Self.split(f).map { ($0.0, $0.1) } ?? (nil, f)
            self.f = keep
            let out = text
            (c, v, self.f) = (move, j, nil)
            return out
        }
        if let v0 = v, let pair = Self.vowelPairs[String([v0, j])] { v = pair; return nil }
        if c != nil, v == nil { v = j; return nil }
        let out = isEmpty ? nil : text
        (c, v, f) = (nil, j, nil)
        return out
    }

    mutating func backspace() {
        if let f0 = f { f = Self.split(f0)?.0; return }
        if let v0 = v { v = Self.vowelPairs.first { $0.value == v0 }.map { Array($0.key)[0] }; return }
        c = nil
    }
}

/// A SurfaceView whose input method is a deterministic model of the macOS
/// Korean 2-Set IME. The NSTextInputClient call sequences replicate what the
/// real IME was recorded doing (see `lmux-imetest --probe`, macOS 26 / 2-Set):
///
///   jamo, no commit       setMarkedText(new)
///   jamo, commits         setMarkedText(done) insertText(done) setMarkedText(new)
///   space / punctuation   setMarkedText(p) insertText(p + " ")  |  ... insertText(p) insertText(".")
///   Enter/Esc/arrows/Tab  setMarkedText(p) insertText(p) doCommand(insertNewline: ...)
///   Cmd+key, Ctrl+key     setMarkedText(p) insertText(p) doCommand(noop:)   (idle: doCommand(noop:))
///   Backspace             setMarkedText(shorter)  |  last jamo: setMarkedText(p) insertText(p) doCommand(deleteBackward:)
///
/// Direct mode (recorded on macOS 15/26, ghostty-org/ghostty#13235): when the client's TSM
/// document advertises document access, a composition that starts from nothing (first key,
/// or after a passthrough key such as Enter or Cmd+key) commits its first jamo with
/// insertText and expects to rebuild the syllable by replacing it, which a terminal can't
/// do: the next jamo starts a fresh composition, so 안 arrives as ㅇㅏㄴ.
final class SimulatedKoreanIMEView: RecordingSurfaceView {
    private var composer = HangulComposer()
    /// The next composition starts from nothing (direct mode applies to its first jamo).
    private var directArmed = true
    /// Tests: pretend the input context advertises document access (AppKit's default context).
    var forceDocumentAccess = false
    private var directMode: Bool { forceDocumentAccess || (inputContextAdvertisesDocumentAccess ?? true) }
    /// Tests: the IME answers a key only after keyDown returned (out of order / deferred), as the
    /// real one sometimes does right after activation.
    var respondLate = false
    /// The simulated input source is an input method (the real check reads the selected source).
    override var inputMethodActive: Bool { true }

    override func interpretKeyEvents(_ events: [NSEvent]) {
        if respondLate {
            for e in events { DispatchQueue.main.async { [weak self] in self?.handle(e) } }
            return
        }
        for e in events { handle(e) }
    }

    private func commitAll(_ suffix: String = "") {
        let p = composer.text
        composer = HangulComposer()
        setMarkedText(p, selectedRange: NSRange(location: p.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        insertText(p + suffix, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func command(for e: NSEvent) -> Selector? {
        if !e.modifierFlags.isDisjoint(with: [.command, .control]) { return Selector(("noop:")) }
        switch e.keyCode {
        case 36: return #selector(NSResponder.insertNewline(_:))
        case 48: return #selector(NSResponder.insertTab(_:))
        case 51: return #selector(NSResponder.deleteBackward(_:))
        case 53: return #selector(NSResponder.cancelOperation(_:))
        case 123: return #selector(NSResponder.moveLeft(_:))
        case 124: return #selector(NSResponder.moveRight(_:))
        case 125: return #selector(NSResponder.moveDown(_:))
        case 126: return #selector(NSResponder.moveUp(_:))
        default: return nil
        }
    }

    private func handle(_ e: NSEvent) {
        let none = NSRange(location: NSNotFound, length: 0)
        let chars = e.characters ?? ""

        if e.keyCode == 51, !composer.isEmpty, !e.modifierFlags.contains(.command) {
            var next = composer
            next.backspace()
            if next.isEmpty {
                commitAll()
                doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            } else {
                composer = next
                setMarkedText(composer.text, selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            }
            return
        }

        if let sel = command(for: e) {
            if !composer.isEmpty { commitAll() }
            doCommand(by: sel)
            directArmed = true
            return
        }

        // The real Korean input mode's events carry its own characters (ㅎ for g): map by the key.
        let keyChars = HangulComposer.keymap[chars.first ?? " "] != nil ? chars : (e.charactersIgnoringModifiers ?? chars)
        if let ch = keyChars.first, keyChars.count == 1, let jamo = HangulComposer.keymap[ch] {
            if composer.isEmpty, directArmed {
                directArmed = false
                if directMode {
                    insertText(String(jamo), replacementRange: none)
                    return
                }
            }
            if let done = composer.add(jamo) {
                // The real IME re-sends the finished syllable, commits it, then
                // starts the next preedit.
                setMarkedText(done, selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
                insertText(done, replacementRange: none)
            }
            setMarkedText(composer.text, selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
            return
        }

        // Space, digits, punctuation: commit (space is merged into the commit,
        // like the real IME), then insert.
        if chars == " " && !composer.isEmpty { commitAll(" "); return }
        if !composer.isEmpty { commitAll() }
        if !chars.isEmpty { insertText(chars, replacementRange: none) }
    }
}

/// The 2-Set layout's character for a letter key (ㅊ for C, ㅃ for Shift+Q), for events at a
/// SimulatedKoreanIMEView: what `characters(byApplyingModifiers:)` gives on a Mac with the Korean
/// source selected, whatever source this machine has selected right now. Other keys: nil (AppKit).
func simulatedKoreanLayout(_ e: NSEvent, _ mods: NSEvent.ModifierFlags) -> String? {
    guard e.window?.firstResponder is SimulatedKoreanIMEView,
          mods.intersection([.shift, .control, .option, .command]).isSubset(of: [.shift]),
          let c = KC.map.first(where: { $0.value == e.keyCode })?.key, c.isLetter else { return nil }
    return Key.jamo(c, shift: mods.contains(.shift))
}

// MARK: - Chinese (Pinyin) and Japanese (Romaji / Kana Typing)

/// Romaji to kana, as the Japanese IME converts while typing (only what the tests type, plus the rows).
struct RomajiComposer {
    static let table: [String: String] = {
        var t: [String: String] = ["a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
                                   "shi": "し", "chi": "ち", "tsu": "つ", "fu": "ふ", "ji": "じ", "wo": "を", "-": "ー"]
        let rows: [(String, String)] = [("k", "かきくけこ"), ("s", "さしすせそ"), ("t", "たちつてと"), ("n", "なにぬねの"),
                                        ("h", "はひふへほ"), ("m", "まみむめも"), ("r", "らりるれろ"), ("g", "がぎぐげご"),
                                        ("z", "ざじずぜぞ"), ("d", "だぢづでど"), ("b", "ばびぶべぼ"), ("p", "ぱぴぷぺぽ")]
        for (c, kana) in rows { for (v, k) in zip("aiueo", kana) { t[c + String(v)] = String(k) } }
        for (y, k) in zip(["ya", "yu", "yo", "wa"], ["や", "ゆ", "よ", "わ"]) { t[y] = k }
        for (c, i) in [("k", "き"), ("n", "に"), ("h", "ひ"), ("m", "み"), ("r", "り"), ("g", "ぎ"), ("b", "び"), ("p", "ぴ")] {
            for (v, small) in zip(["a", "u", "o"], ["ゃ", "ゅ", "ょ"]) { t[c + "y" + v] = i + small }
        }
        for (v, small) in zip(["a", "u", "o"], ["ゃ", "ゅ", "ょ"]) { t["sh" + v] = "し" + small; t["ch" + v] = "ち" + small; t["j" + v] = "じ" + small }
        return t
    }()

    var kana = ""
    var pending = ""
    var text: String { kana + pending }
    var isEmpty: Bool { text.isEmpty }

    mutating func add(_ c: Character) {
        pending.append(c)
        if pending == "nn" { kana += "ん"; pending = ""; return }
        if pending.count == 2, pending.first == "n", let c2 = pending.last, !"aiueoy".contains(c2) {
            kana += "ん"; pending.removeFirst()
        }
        if pending.count == 2, pending.first == pending.last, let c1 = pending.first, !"aiueon".contains(c1) {
            kana += "っ"; pending.removeFirst()
        }
        if let k = Self.table[pending] { kana += k; pending = ""; return }
        if !Self.table.keys.contains(where: { $0.hasPrefix(pending) }) { kana += pending; pending = "" }
    }

    /// Conversion starts: a trailing n is ん.
    mutating func finish() { if pending == "n" { kana += "ん" } else { kana += pending }; pending = "" }

    mutating func backspace() { if !pending.isEmpty { pending.removeLast() } else if !kana.isEmpty { kana.removeLast() } }
}

/// The JIS kana layout (Kana Typing) on the ANSI key codes the tests press: C is そ.
let kanaKeys: [Character: Character] = [
    "q": "た", "w": "て", "e": "い", "r": "す", "t": "か", "y": "ん", "u": "な", "i": "に", "o": "ら", "p": "せ",
    "a": "ち", "s": "と", "d": "し", "f": "は", "g": "き", "h": "く", "j": "ま", "k": "の", "l": "り",
    "z": "つ", "x": "さ", "c": "そ", "v": "ひ", "b": "こ", "n": "み", "m": "も",
]

/// The Zhuyin (Dachen) layout on the ANSI key codes: C is ㄏ, and 3 4 6 7 are the tone marks ˇ ˋ ˊ ˙.
let zhuyinKeys: [Character: Character] = [
    "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ", "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ", "e": "ㄍ", "d": "ㄎ",
    "c": "ㄏ", "r": "ㄐ", "f": "ㄑ", "v": "ㄒ", "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ", "y": "ㄗ", "h": "ㄘ",
    "n": "ㄙ", "u": "ㄧ", "j": "ㄨ", "m": "ㄩ", "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ", "9": "ㄞ", "o": "ㄟ",
    "l": "ㄠ", ".": "ㄡ", "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ", "-": "ㄦ", "3": "ˇ", "4": "ˋ", "6": "ˊ", "7": "˙",
]

/// A SurfaceView whose input method is a deterministic model of the macOS Chinese (Pinyin -
/// Simplified, Zhuyin - Traditional) or Japanese (Romaji / Kana Typing) IME. Unlike Korean 2-Set, nothing is committed
/// while typing: every key goes into the marked text, and the key that commits it is consumed.
/// The call sequences (assumed from how the IMEs behave in TextEdit; `--visible --probe` prints the
/// real ones when the sources are enabled):
///
///   Pinyin   letters             setMarkedText("nihao")
///            Space / 1-9         insertText(candidate)                       (consumed)
///            Enter               insertText("nihao") — the raw letters       (consumed)
///            Esc                 setMarkedText("")                           (consumed)
///            Backspace           setMarkedText(shorter), "" on the last letter (consumed)
///            ， 。 ？ (CN mode)   insertText(candidate) insertText("。")  |  idle insertText("，")
///            Shift (tap)         commits the raw letters (outside keyDown), toggles English
///            ← →                 setMarkedText(same, caret moved)              (consumed)
///            ↑ ↓ Tab             (candidate paging, consumed)
///   Japanese letters / 、。ー 1  setMarkedText("にほんご") (Romaji converts as it goes)
///            Space               setMarkedText("日本語") converts, again: next candidate
///            Enter               insertText("日本語")                         (consumed)
///            Esc                 converting: back to kana; else setMarkedText("") (consumed)
///            Backspace           converting: setMarkedText("", replacementRange: last char) (日本語 → 日本);
///                                else setMarkedText(shorter)                  (consumed)
///            letter while converting   insertText("日本語") setMarkedText("k")
///   Zhuyin   ㄋ ㄧ                setMarkedText("ㄋㄧ") (the keys' own characters are bopomofo)
///            tone ˇ ˋ ˊ ˙ / Space setMarkedText("你") the syllable becomes a character, still marked
///            Space (no syllable) ↓ the candidates of the character before the caret; 1-9 / Enter pick
///            Enter               insertText("你好")                           (consumed)
///            Esc / Backspace     as Pinyin; Backspace deletes a bopomofo, else a character
///            ← →                 setMarkedText(same, caret moved); typing goes in at the caret
///   all      Cmd+key, Ctrl+key   insertText(preedit) doCommand(noop:)  (idle: doCommand(noop:))
///            idle Enter/Esc/Tab/BS/arrows   doCommand(insertNewline: ...)
final class SimulatedCJKIMEView: RecordingSurfaceView {
    enum Kind: String { case pinyin = "Pinyin", zhuyin = "Zhuyin", romaji = "Japanese Romaji", kana = "Japanese Kana" }
    var kind: Kind = .pinyin
    private var pinyin = ""
    /// Pinyin: where ← / → put the caret inside the letters (UTF-16; the end when nil).
    private var caret: Int?
    private var english = false
    private var roma = RomajiComposer()
    private var candidates: [String] = []
    private var ci = 0
    private var converting: Bool { !candidates.isEmpty }
    /// Zhuyin: the converted characters (each with its candidates and the one chosen), the syllable
    /// being typed (inserted at `caret`, a character index), and whether the candidate window is open.
    private var zhuyin: [(cands: [String], i: Int)] = []
    private var syllable = ""
    private var candidateWindow = false
    private var zc: Int?
    /// Tests: the next Enter while composing makes these NSTextInputClient calls instead of the
    /// usual insertText (once): the call orders an IME confirming one clause may use.
    var onEnter: ((SimulatedCJKIMEView) -> Void)?
    override var inputMethodActive: Bool { true }

    static let pinyinDict: [String: [String]] = ["nihao": ["你好", "拟好"], "ni": ["你", "呢"], "hao": ["好", "号"],
                                                 "zhongwen": ["中文", "中闻"]]
    static let zhuyinDict: [String: [String]] = ["ㄋㄧˇ": ["你", "妳", "擬"], "ㄏㄠˇ": ["好", "郝"], "ㄓㄨㄥ": ["中", "忠"],
                                                  "ㄨㄣˊ": ["文", "聞"]]
    static let kanjiDict: [String: [String]] = ["にほんご": ["日本語", "にほんご"], "かんじ": ["漢字", "感じ"], "かな": ["仮名", "かな"]]
    static let fullWidth: [Character: String] = [",": "，", ".": "。", "?": "？", "!": "！", ";": "；", ":": "："]

    private let none = NSRange(location: NSNotFound, length: 0)
    private func mark(_ s: String) {
        setMarkedText(s, selectedRange: NSRange(location: caret ?? s.utf16.count, length: 0), replacementRange: none)
    }
    private func commit(_ s: String) { insertText(s, replacementRange: none) }

    var preedit: String {
        switch kind {
        case .pinyin: return pinyin
        case .zhuyin:
            let cs = zhuyin.map { $0.cands[$0.i] }, at = zc ?? cs.count
            return (cs[..<at] + [syllable] + cs[at...]).joined()
        case .romaji, .kana: return converting ? candidates[ci] : roma.text
        }
    }
    var composing: Bool { !preedit.isEmpty }
    private func reset() {
        pinyin = ""; caret = nil; roma = RomajiComposer(); candidates = []; ci = 0
        zhuyin = []; syllable = ""; zc = nil; candidateWindow = false
    }

    override func interpretKeyEvents(_ events: [NSEvent]) { for e in events { handle(e) } }

    /// Shift tapped alone (Pinyin): the IME commits the raw letters and toggles English.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard kind == .pinyin, event.keyCode == 56, !event.modifierFlags.contains(.shift) else { return }
        if !pinyin.isEmpty { let p = pinyin; reset(); commit(p) }
        english.toggle()
    }

    private func command(for e: NSEvent) -> Selector? {
        if !e.modifierFlags.isDisjoint(with: [.command, .control]) { return Selector(("noop:")) }
        switch e.keyCode {
        case 36: return #selector(NSResponder.insertNewline(_:))
        case 48: return #selector(NSResponder.insertTab(_:))
        case 51: return #selector(NSResponder.deleteBackward(_:))
        case 53: return #selector(NSResponder.cancelOperation(_:))
        case 123: return #selector(NSResponder.moveLeft(_:))
        case 124: return #selector(NSResponder.moveRight(_:))
        case 125: return #selector(NSResponder.moveDown(_:))
        case 126: return #selector(NSResponder.moveUp(_:))
        default: return nil
        }
    }

    private func handle(_ e: NSEvent) {
        let mods = e.modifierFlags
        if !mods.isDisjoint(with: [.command, .control]) {
            if composing { let p = preedit; reset(); commit(p) }
            doCommand(by: Selector(("noop:")))
            return
        }
        switch kind {
        case .pinyin: handlePinyin(e)
        case .zhuyin: handleZhuyin(e)
        case .romaji, .kana: handleJapanese(e)
        }
    }

    private func handlePinyin(_ e: NSEvent) {
        let chars = e.characters ?? ""
        let c = chars.count == 1 ? chars.first! : "\0"
        if pinyin.isEmpty || english {
            if c.isLetter, c.isASCII, !english { pinyin.append(c); mark(pinyin); return }
            if let sel = command(for: e) { doCommand(by: sel); return }
            if !english, let p = Self.fullWidth[c] { commit(p); return }
            if !chars.isEmpty { commit(chars) }
            return
        }
        let cands = Self.pinyinDict[pinyin] ?? [pinyin]
        switch e.keyCode {
        case 49: reset(); commit(cands[0]); return
        case 36: let p = pinyin; reset(); commit(p); return
        case 53: reset(); mark(""); return
        case 51: pinyin.removeLast(); mark(pinyin); return
        case 123, 124:
            caret = max(0, min(pinyin.count, (caret ?? pinyin.count) + (e.keyCode == 123 ? -1 : 1)))
            mark(pinyin)
            return
        case 125, 126, 48: return
        default: break
        }
        if c.isLetter, c.isASCII { pinyin.append(c); caret = nil; mark(pinyin); return }
        if let n = c.wholeNumberValue, n >= 1, n <= cands.count { reset(); commit(cands[n - 1]); return }
        if let p = Self.fullWidth[c] { reset(); commit(cands[0]); commit(p); return }
    }

    private func handleZhuyin(_ e: NSEvent) {
        let chars = e.characters ?? ""
        let c = chars.count == 1 ? chars.first! : "\0"
        let tones: [Character: String] = ["ˇ": "ˇ", "ˋ": "ˋ", "ˊ": "ˊ", "˙": "˙", " ": ""]
        func show() { caret = zc.map { $0 + syllable.utf16.count }; mark(preedit) }
        /// The character before the caret, whose candidates the window lists.
        var last: Int? { let at = zc ?? zhuyin.count; return at > 0 ? at - 1 : nil }
        if candidateWindow, let n = e.keyCode == KC.returnKey ? zhuyin[last!].i + 1 : KC.map.first(where: { $0.value == e.keyCode })?.key.wholeNumberValue,
           n >= 1, n <= zhuyin[last!].cands.count {
            zhuyin[last!].i = n - 1; candidateWindow = false; show(); return
        }
        let wasOpen = candidateWindow
        candidateWindow = false
        if zhuyinKeys.values.contains(c), tones[c] == nil {
            syllable.append(c); show(); return
        }
        if !syllable.isEmpty, let tone = tones[c] {
            let at = zc ?? zhuyin.count
            zhuyin.insert((Self.zhuyinDict[syllable + tone] ?? [syllable + tone], 0), at: at)
            syllable = ""
            if zc != nil { zc = at + 1 }
            show()
            return
        }
        if !composing {
            if let sel = command(for: e) { doCommand(by: sel) } else if !chars.isEmpty { commit(chars) }
            return
        }
        switch e.keyCode {
        case KC.space, KC.down:
            // Opens the candidate window; again: the next candidate.
            guard syllable.isEmpty, let l = last else { break }
            if wasOpen { zhuyin[l].i = (zhuyin[l].i + 1) % zhuyin[l].cands.count; show() }
            candidateWindow = true
        case KC.returnKey: let p = preedit; reset(); commit(p)
        case KC.escape: reset(); mark("")
        case KC.delete:
            if !syllable.isEmpty { syllable.removeLast() } else if let l = last { zhuyin.remove(at: l); if zc != nil { zc = l } }
            if zhuyin.isEmpty && syllable.isEmpty { reset(); mark("") } else { show() }
        case KC.left, KC.right where syllable.isEmpty:
            let at = max(0, min(zhuyin.count, (zc ?? zhuyin.count) + (e.keyCode == KC.left ? -1 : 1)))
            zc = at == zhuyin.count ? nil : at
            show()
        default: break // ↑, Tab, a tone mark with no syllable
        }
    }

    private func handleJapanese(_ e: NSEvent) {
        let chars = e.characters ?? ""
        let c = chars.count == 1 ? chars.first! : "\0"
        let kanaChar: Character? = kind == .kana ? (kanaKeys.values.contains(c) ? c : nil) : nil
        let typed: Character? = kanaChar ?? ((c.isLetter && c.isASCII) || "-1234567890".contains(c) ? c : nil)
        let punct: String? = [",": "、", ".": "。"][c]
        if typed != nil || punct != nil {
            if converting { let p = candidates[ci]; reset(); commit(p) }
            if let k = kanaChar { roma.kana.append(k) } else if let p = punct { roma.finish(); roma.kana += p }
            else if let t = typed { kind == .kana && t.isNumber ? roma.kana.append(t) : roma.add(Character(t.lowercased())) }
            mark(roma.text)
            return
        }
        if !composing {
            if let sel = command(for: e) { doCommand(by: sel) } else if !chars.isEmpty { commit(chars) }
            return
        }
        switch e.keyCode {
        case 49:
            if converting { ci = (ci + 1) % candidates.count } else { roma.finish(); candidates = Self.kanjiDict[roma.kana] ?? [roma.kana]; ci = 0 }
            mark(preedit)
        case 36:
            let p = preedit
            reset()
            if let f = onEnter { onEnter = nil; f(self) } else { commit(p) }
        case 51 where converting:
            // Deletes the conversion's last character: an empty replacement of it (manaflow-ai/cmux#13416).
            let d = candidates[ci], rest = String(d.dropLast())
            if rest.isEmpty { reset() } else { candidates = [rest]; ci = 0 }
            setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                          replacementRange: NSRange(location: d.utf16.count - 1, length: 1))
        case 53, 51:
            if converting { candidates = []; mark(roma.text); return }
            if e.keyCode == 53 { reset() } else { roma.backspace() }
            mark(roma.text)
        default: break // arrows, Tab: clause / candidate navigation
        }
    }
}

/// The layout's characters for a key at a SimulatedCJKIMEView: Pinyin and Romaji type on the ABC
/// layout (whatever this Mac has selected), Kana Typing gives kana for the letter keys (そ for C),
/// Zhuyin bopomofo and tone marks for letters, digits and punctuation (ㄏ for C, ˇ for 3).
func simulatedCJKLayout(_ e: NSEvent, _ mods: NSEvent.ModifierFlags) -> String? {
    guard let v = e.window?.firstResponder as? SimulatedCJKIMEView,
          mods.intersection([.shift, .control, .option, .command]).isSubset(of: [.shift]),
          let c = KC.map.first(where: { $0.value == e.keyCode })?.key else { return nil }
    if v.kind == .zhuyin { return zhuyinKeys[c].map(String.init) }
    guard c.isLetter else { return nil }
    if v.kind == .kana { return kanaKeys[c].map(String.init) }
    return mods.contains(.shift) ? String(c).uppercased() : String(c)
}
