import AppKit
import CoreText
import GhosttyKit
import IOSurface
import LmuxTerminal

/// libghostty apps are kept alive for the whole run (like the real app's single
/// runtime); freeing them mid-run is not something lmux does.
@MainActor var keepAlive: [AnyObject] = []

let koreanInputSourceID = "com.apple.inputmethod.Korean.2SetKorean"
/// The (Latin) input source active when the real-IME run started; the mid-word switch check goes back to it.
var startInputSourceID: String?

// MARK: - Result bookkeeping

struct CheckResult {
    let mode: String
    let name: String
    let pass: Bool
    let detail: String
}

@MainActor
final class Report {
    var results: [CheckResult] = []
    var mode = ""

    func check(_ name: String, _ pass: Bool, _ detail: @autoclosure () -> String = "") {
        let r = CheckResult(mode: mode, name: name, pass: pass, detail: detail())
        results.append(r)
        print("\(pass ? "PASS" : "FAIL")  [\(mode)] \(name)\(r.detail.isEmpty ? "" : "  -- \(r.detail)")")
    }
}

// MARK: - Pixel helpers (read the IOSurface libghostty renders into)

struct Frame {
    let w: Int, h: Int, bpr: Int
    let px: [UInt8] // BGRA
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let o = y * bpr + x * 4
        return (Int(px[o + 2]), Int(px[o + 1]), Int(px[o]))
    }
}

@MainActor
func grabFrame(_ view: NSView) -> Frame? {
    guard let contents = view.layer?.contents else { return nil }
    let surf = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
    IOSurfaceLock(surf, .readOnly, nil)
    defer { IOSurfaceUnlock(surf, .readOnly, nil) }
    let w = IOSurfaceGetWidth(surf), h = IOSurfaceGetHeight(surf), bpr = IOSurfaceGetBytesPerRow(surf)
    let base = IOSurfaceGetBaseAddress(surf).assumingMemoryBound(to: UInt8.self)
    return Frame(w: w, h: h, bpr: bpr, px: Array(UnsafeBufferPointer(start: base, count: bpr * h)))
}

/// Ink bounding box (pixels differing from the background) within a pixel rect.
func inkBox(_ f: Frame, x0: Int, x1: Int, y0: Int, y1: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
    let bg = f.rgb(f.w - 3, f.h - 3)
    var box: (Int, Int, Int, Int)?
    for y in max(0, y0)..<min(f.h, y1) {
        for x in max(0, x0)..<min(f.w, x1) {
            let p = f.rgb(x, y)
            if abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 90 {
                if let b = box { box = (min(b.0, x), max(b.1, x), min(b.2, y), max(b.3, y)) } else { box = (x, x, y, y) }
            }
        }
    }
    return box.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
}

/// Cell grid geometry in backing pixels, derived from libghostty's IME point
/// while the cursor is at column 0 of row 0.
struct Grid {
    let x0: Double, top: Double, cw: Double, ch: Double
    func col(_ c: Int) -> Int { Int((x0 + Double(c) * cw).rounded()) }
}

@MainActor
func gridAtOrigin(_ view: SurfaceView) -> Grid? {
    guard let surface = view.surface, let size = view.surfaceSize else { return nil }
    var x = 0.0, y = 0.0, w = 0.0, h = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &w, &h)
    let s = view.window?.backingScaleFactor ?? 2
    let cw = Double(size.cell_width_px), ch = Double(size.cell_height_px)
    return Grid(x0: x * s, top: y * s - ch, cw: cw, ch: ch)
}

@MainActor
func imePoint(_ view: SurfaceView) -> NSRect {
    var x = 0.0, y = 0.0, w = 0.0, h = 0.0
    ghostty_surface_ime_point(view.surface!, &x, &y, &w, &h)
    return NSRect(x: x, y: y, width: w, height: h)
}

@MainActor
func sleepMs(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

@MainActor
func primaryFontFamily(_ view: SurfaceView) -> String {
    guard let surface = view.surface, let raw = ghostty_surface_quicklook_font(surface) else { return "?" }
    let font = Unmanaged<CTFont>.fromOpaque(raw).takeRetainedValue()
    return CTFontCopyFamilyName(font) as String
}

// MARK: - IME checklist (runs against the simulated IME and, if available, the real one)

@MainActor
func runIMEChecks(_ r: Report, runtime: GhosttyRuntime, real: Bool) async {
    useCGEvents = real
    let gap = real ? 0 : 0
    var newTabCount = 0
    runtime.onAction = { tag, _ in if tag == GHOSTTY_ACTION_NEW_TAB { newTabCount += 1 } }
    defer { runtime.onAction = nil }

    let make: (ghostty_app_t, SurfaceOptions) -> SurfaceView = real
        ? { RecordingSurfaceView(app: $0, options: $1) }
        : { SimulatedKoreanIMEView(app: $0, options: $1) }

    // Real IME: make sure this view's input context talks to the Korean 2-Set IME.
    func attachIME(_ term: SinkTerminal) async {
        guard real, let ctx = term.view.inputContext else { return }
        ctx.selectedKeyboardInputSource = koreanInputSourceID
        ctx.activate()
        await sleepMs(200)
    }

    // ---- Fresh terminal for cursor / rendering checks.
    let t1 = SinkTerminal(runtime: runtime, view: make, title: "lmux-imetest render")
    if !headless { NSApp.activate(ignoringOtherApps: true) }
    guard await t1.waitReady() else { r.check("sink terminal ready", false); return }
    await attachIME(t1)
    await sleepMs(300)
    let v1 = t1.view
    let rect0 = imePoint(v1)
    let cell = v1.cellSize
    let grid = gridAtOrigin(v1)

    // firstRect while composing: "안" committed (2 cells), "녕" in preedit.
    t1.mark()
    await post(Key.latin("dkssud"), to: t1.window, gapMs: gap)
    _ = await t1.waitBytes(atLeast: 3)
    await sleepMs(150)
    let fr = v1.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
    let frView = v1.convert(t1.window.convertFromScreen(fr), from: nil)
    let expectedX = rect0.minX + 2 * cell.width
    // AppKit rect: bottom-left origin; libghostty IME point y is the cell bottom (top-left origin).
    let expectedY = v1.frame.height - rect0.minY
    r.check("firstRect(forCharacterRange:) is at the cursor while composing",
            abs(frView.minX - expectedX) < 0.6 && abs(frView.minY - expectedY) < 0.6 && v1.currentPreedit == "녕",
            "x=\(frView.minX) expected \(expectedX) (col 2), y=\(frView.minY) expected \(expectedY), preedit=\"\(v1.currentPreedit)\"")

    // Preedit is drawn at the cursor: ink in cols 2-3 of row 0, nothing right of it.
    if let g = grid, let f = grabFrame(v1) {
        let y0 = Int(g.top), y1 = Int(g.top + g.ch)
        let pre = inkBox(f, x0: g.col(2), x1: g.col(4), y0: y0, y1: y1)
        let after = inkBox(f, x0: g.col(4) + 1, x1: g.col(12), y0: y0, y1: y1)
        r.check("preedit is rendered at the cursor cell (cols 2-3), nowhere else",
                pre != nil && after == nil, "preedit ink=\(String(describing: pre)), ink right of it=\(String(describing: after))")
    } else {
        r.check("preedit is rendered at the cursor cell (cols 2-3), nowhere else", false, "no frame")
    }

    // Commit with space: no duplicate rendering of the committed syllable.
    await post([.space], to: t1.window, gapMs: gap)
    let b1 = await t1.waitBytes(atLeast: 7)
    await sleepMs(200)
    // The cursor row is the last non-empty row (the sink runs under login(1),
    // which prints "Last login" first).
    let line0 = v1.readText().components(separatedBy: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    var dupOK = show(b1) == "안녕 " && line0.trimmingCharacters(in: .whitespaces) == "안녕" && v1.currentPreedit == ""
    var dupDetail = "pty=\"\(show(b1))\" row0=\"\(line0)\" preedit=\"\(v1.currentPreedit)\""
    if let g = grid, let f = grabFrame(v1) {
        // Cursor is now at col 5; a stale preedit overlay would show ink at cols 4+.
        let stale = inkBox(f, x0: g.col(4) + 1, x1: g.col(12), y0: Int(g.top), y1: Int(g.top + g.ch))
        let cur = imePoint(v1)
        // The cursor block itself is drawn at col 5; ignore exactly that cell.
        // A duplicated syllable is a 2-cell glyph; the cursor (block, bar or the hollow box of an
        // unfocused window, whose outline reaches past its cell) is at most about one cell wide.
        let cellPx = g.col(1) - g.col(0)
        let staleOutsideCursor = stale.map { $0.maxX - $0.minX > cellPx + 3 || $0.maxX > g.col(6) + 2 } ?? false
        dupOK = dupOK && !staleOutsideCursor && abs(cur.minX - (rect0.minX + 5 * cell.width)) < 0.6
        dupDetail += " ink after col4=\(String(describing: stale)) cursorCol=\(Int(((cur.minX - rect0.minX) / cell.width).rounded()))"
    }
    r.check("no duplicate rendering of a committed syllable", dupOK, dupDetail)

    // Hangul is 2 cells: cursor advanced 2 cells per syllable (checked above: col 5 = 2+2+1).
    t1.window.close()

    // ---- Byte-level checks on a second terminal.
    let t = SinkTerminal(runtime: runtime, view: make, title: "lmux-imetest bytes")
    if !headless { NSApp.activate(ignoringOtherApps: true) }
    guard await t.waitReady() else { r.check("sink terminal ready", false); return }
    await attachIME(t)
    await sleepMs(300)
    let v = t.view

    let rec = v as? RecordingSurfaceView
    func trace() -> String { " trace: " + (rec?.log.joined(separator: " ") ?? "") }
    func run(_ keys: [Key], expectBytes: Int) async -> [UInt8] {
        rec?.log = []
        t.mark()
        await post(keys, to: t.window, gapMs: gap)
        return await t.waitBytes(atLeast: expectBytes)
    }

    // Baseline encodings (not composing).
    let enterBase = await run([.enter], expectBytes: 1)
    let shiftEnterBase = await run([.shiftEnter], expectBytes: 1)

    // 1. Rapid typing, including compound finals (값 -> 갑+스) and vowel moves (핫+ㅔ -> 하+세).
    let sentence = "dkssudgktpdy qksrkqtmqslek " // 안녕하세요 반갑습니다
    let rapid = await run(Key.latin(sentence), expectBytes: "안녕하세요 반갑습니다 ".utf8.count)
    r.check("no dropped syllables when typing fast (안녕하세요 반갑습니다)",
            show(rapid) == "안녕하세요 반갑습니다 ", "pty=\"\(show(rapid))\"")

    // 1b. The first syllable after an idle (passthrough) key: 하이 must not arrive as ㅎㅏ이.
    let idleEnter = await run([.enter], expectBytes: 1)
    let firstAfterIdle = await run(Key.latin("gkdl "), expectBytes: "하이 ".utf8.count)
    r.check("first syllable after an idle key composes (하이, not ㅎㅏ이)",
            show(firstAfterIdle) == "하이 ", "pty=\"\(show(firstAfterIdle))\" after \(show(idleEnter))" + trace())
    r.check("the surface's input context has no TSM document access (Korean IME direct mode off)",
            v.inputContextAdvertisesDocumentAccess == false, "\(String(describing: v.inputContextAdvertisesDocumentAccess))")
    if let sim = v as? SimulatedKoreanIMEView {
        // The simulator really models the bug: with document access it produces the loose jamo.
        sim.forceDocumentAccess = true
        _ = await run([.enter], expectBytes: 1)
        let broken = await run(Key.latin("gkdl "), expectBytes: "ㅎㅏ이 ".utf8.count)
        sim.forceDocumentAccess = false
        r.check("(simulator) with document access the first syllable splits, as on a real Mac before the fix",
                show(broken) == "ㅎㅏ이 ", "pty=\"\(show(broken))\"")
    }

    // 2. Enter while composing.
    let enter = await run(Key.latin("dkssud") + [.enter], expectBytes: 6 + enterBase.count)
    r.check("Enter while composing commits 녕 BEFORE the newline, once",
            enter == Array("안녕".utf8) + enterBase,
            "pty=\"\(show(enter))\" expected \"안녕\(show(enterBase))\"")

    // 3. Shift+Enter while composing.
    let shiftEnter = await run(Key.latin("dkssud") + [.shiftEnter], expectBytes: 6 + shiftEnterBase.count)
    r.check("Shift+Enter while composing commits 녕 BEFORE Shift+Enter, once",
            shiftEnter == Array("안녕".utf8) + shiftEnterBase,
            "pty=\"\(show(shiftEnter))\" expected \"안녕\(show(shiftEnterBase))\"")

    // 4. Backspace mid-composition edits the preedit only; never reaches the pty.
    t.mark()
    await post(Key.latin("gks") + [.backspace], to: t.window, gapMs: gap)
    await sleepMs(150)
    let pre1 = v.currentPreedit
    await post([.backspace], to: t.window, gapMs: gap)
    await sleepMs(150)
    let pre2 = v.currentPreedit
    await post([.backspace], to: t.window, gapMs: gap)
    await sleepMs(150)
    let pre3 = v.currentPreedit
    let bsComposing = await t.waitBytes(atLeast: 1, timeout: 0.3)
    let bsIdle = await run([.backspace], expectBytes: 1)
    r.check("Backspace mid-composition: 한→하→ㅎ→(empty), no bytes; then Backspace sends DEL",
            pre1 == "하" && pre2 == "ㅎ" && pre3 == "" && bsComposing.isEmpty && bsIdle == [0x7f],
            "preedit \(pre1)/\(pre2)/\"\(pre3)\" pty while composing=\"\(show(bsComposing))\" idle=\"\(show(bsIdle))\"")

    // 5. Esc while composing (vim users): commit, then Esc.
    let esc = await run(Key.latin("rk") + [.escape], expectBytes: 4)
    r.check("Esc while composing commits 가 then sends ESC", esc == Array("가".utf8) + [0x1b], "pty=\"\(show(esc))\"" + (esc == Array("가".utf8) + [0x1b] ? "" : trace()))

    // 6. Punctuation while composing.
    let dot = await run(Key.latin("rk") + [Key.ch(".")], expectBytes: 4)
    r.check("'.' while composing commits 가 then '.'", show(dot) == "가.", "pty=\"\(show(dot))\"")

    // 6b. Left arrow while composing (IME_CHECKLIST #12, the known-risk item): 가 committed, then
    // exactly ONE cursor-left, the same bytes a plain Left sends.
    let leftBase = await run([.left], expectBytes: 3)
    let left = await run(Key.latin("rk") + [.left], expectBytes: 3 + leftBase.count)
    r.check("Left while composing commits 가 then moves the cursor exactly once",
            !leftBase.isEmpty && left == Array("가".utf8) + leftBase,
            "pty=\"\(show(left))\" expected \"가\(show(leftBase))\"" + (left == Array("가".utf8) + leftBase ? "" : trace()))

    // 6c. Input source switched mid-word (IME_CHECKLIST #14), real IME only: 가 → Latin source → a = "가a".
    // (Programmatic switch: the Caps Lock / Ctrl+Space key itself can't be pressed from here.)
    if real, let latin = startInputSourceID, latin != koreanInputSourceID, let ctx = v.inputContext {
        t.mark()
        await post(Key.latin("rk"), to: t.window, gapMs: gap)
        await sleepMs(150)
        ctx.selectedKeyboardInputSource = latin
        selectInputSource(latin)
        await sleepMs(300)
        await post([Key.ch("a")], to: t.window, gapMs: gap)
        let mixed = await t.waitBytes(atLeast: 4)
        ctx.selectedKeyboardInputSource = koreanInputSourceID
        selectInputSource(koreanInputSourceID)
        await sleepMs(300)
        r.check("input source switched mid-word (가 → \(latin) → a) gives 가a", show(mixed) == "가a",
                "pty=\"\(show(mixed))\"")
    }

    // 7. Cmd shortcuts with the Korean input source active.
    newTabCount = 0
    let t0 = await run([.cmd("t")], expectBytes: 1)
    await sleepMs(100)
    let tabIdle = newTabCount
    let tc = await run(Key.latin("gks") + [.cmd("t")], expectBytes: 3)
    await sleepMs(100)
    r.check("Cmd+T works (idle and while composing; composing commits 한 first)",
            tabIdle == 1 && newTabCount == 2 && t0.isEmpty && show(tc) == "한",
            "new_tab actions idle=\(tabIdle) total=\(newTabCount), pty idle=\"\(show(t0))\" composing=\"\(show(tc))\"" + (newTabCount == 2 ? "" : trace()))

    let pb = GhosttyRuntime.standardPasteboard
    r.check("clipboard checks use a private pasteboard, not the user's", pb.name != NSPasteboard.general.name, pb.name.rawValue)
    pb.declareTypes([.string], owner: nil)
    pb.setString("lmux-paste-OK", forType: .string)
    let pasteIdle = await run([.cmd("v")], expectBytes: 13)
    let pasteComposing = await run(Key.latin("rk") + [.cmd("v")], expectBytes: 16)
    r.check("Cmd+V works (idle and while composing; composing commits 가 first)",
            show(pasteIdle) == "lmux-paste-OK" && show(pasteComposing) == "가lmux-paste-OK",
            "idle=\"\(show(pasteIdle))\" composing=\"\(show(pasteComposing))\"")

    pb.setString("before-copy", forType: .string)
    v.performBindingAction("select_all")
    await sleepMs(100)
    _ = await run([.cmd("c")], expectBytes: 1)
    await sleepMs(150)
    let copied = pb.string(forType: .string) ?? ""
    r.check("Cmd+C copies the selection", copied != "before-copy" && copied.contains("반갑습니다"),
            "clipboard=\"\(copied.prefix(40))...\"")

    t.window.close()

    // The IME answering late (after keyDown returned), with the Korean input mode's own key
    // characters (ㅎ for g): nothing may leak before the composition, in legacy and kitty 1 / 5.
    if !real {
        for flags in [0, 1, 5] {
            let k = SinkTerminal(runtime: runtime, view: make, title: "lmux-imetest late \(flags)",
                                 prelude: flags == 0 ? "" : "\\033[>\(flags)u")
            guard await k.waitReady(), let sim = k.view as? SimulatedKoreanIMEView else { r.check("late IME terminal ready", false); continue }
            await sleepMs(200)
            sim.respondLate = true
            k.mark()
            let jamoKeys: [(UInt16, String, String)] = [(KC.map["g"]!, "ㅎ", "g"), (KC.map["k"]!, "ㅏ", "k"), (KC.map["d"]!, "ㅇ", "d"), (KC.map["l"]!, "ㅣ", "l")]
            for (code, ch, base) in jamoKeys {
                for t in [NSEvent.EventType.keyDown, .keyUp] {
                    let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: k.window.windowNumber, context: nil, characters: ch,
                                             charactersIgnoringModifiers: base, isARepeat: false, keyCode: code)!
                    dispatch(e, to: k.window)
                }
                await sleepMs(30)
            }
            await post([.space], to: k.window)
            let b = await k.waitBytes(atLeast: "하이 ".utf8.count)
            await sleepMs(200)
            sim.respondLate = false
            r.check("IME answering late (kitty flags \(flags)): 하이, no jamo from the key events", show(b) == "하이 ", "pty=\"\(show(b))\"")
            k.window.close()
        }
    }

    // Kitty keyboard protocol (Claude Code pushes it): composed Hangul must never leak as jamo
    // carried by key events, in Claude's mode (1 = disambiguate) or with every flag (31).
    for flags in [1, 5, 31] {
        let k = SinkTerminal(runtime: runtime, view: make, title: "lmux-imetest kitty \(flags)", prelude: "\\033[>\(flags)u")
        if !headless { NSApp.activate(ignoringOtherApps: true) }
        guard await k.waitReady() else { r.check("kitty \(flags) terminal ready", false); continue }
        await attachIME(k)
        await sleepMs(300)
        k.mark()
        await post([.enter], to: k.window, gapMs: gap)
        _ = await k.waitBytes(atLeast: 1)
        await sleepMs(150)
        k.mark()
        await post(Key.latin("gkdl "), to: k.window, gapMs: gap)
        let b = await k.waitBytes(atLeast: 6)
        await sleepMs(200)
        // Key *release* reports (event type 3, flag 2) name the layout's key (ㅎ for g), as in
        // upstream Ghostty and the kitty spec; they carry no text. Everything else must be clean.
        let text = String(decoding: b, as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}\\[[0-9]+(::[0-9]+)?;[0-9]+:3u", with: "", options: .regularExpression)
        let jamo = text.unicodeScalars.contains { (0x3131...0x318E).contains($0.value) }
            || (0x3131...0x318E).contains { text.contains(";\($0)") || text.contains("[\($0)") }
        let has = { (ch: String, cp: Int) in text.contains(ch) || text.contains("\(cp)") }
        r.check("kitty keyboard flags \(flags): 하이 composes, no jamo leaks as key-event text",
                !jamo && has("하", 0xD558) && has("이", 0xC774) && (flags == 31 || show(b) == "하이 "), "pty=\"\(show(b))\"")
        k.window.close()
    }

    // Copy keys with the Korean source (a user copied, pasted, and found "ㅊ" typed in front of the paste
    // in Claude Code's prompt). Ctrl+C is the interrupt, never the jamo of its key, in legacy mode and in
    // the kitty mode Claude Code pushes; Cmd+C copies; Cmd+V right after pastes exactly the clipboard.
    // The same keys with the ABC source (no input method) as the baseline.
    if !real {
        r.check("Ctrl+C with the Korean source encodes as the C key (kitty: 99, not ㅊ 12618)",
                Ghostty.controlKeyCodepoint(0x314A, keyCode: KC.map["c"]!) == 99
                    && Ghostty.controlKeyCodepoint(0x0441, keyCode: KC.map["c"]!) == 0x0441
                    && Ghostty.controlKeyCodepoint(99, keyCode: KC.map["c"]!) == 99,
                "ㅊ→\(Ghostty.controlKeyCodepoint(0x314A, keyCode: KC.map["c"]!))")
    }
    var sources: [(String, (ghostty_app_t, SurfaceOptions) -> SurfaceView, Bool)] = [("Korean", make, true)]
    if !real, !currentInputSourceID().contains(".inputmethod.") {
        sources.append(("ABC", { RecordingSurfaceView(app: $0, options: $1) }, false))
    }
    for (name, makeView, korean) in sources {
        for flags in [0, 1] {
            let k = SinkTerminal(runtime: runtime, view: makeView, title: "lmux-imetest copy \(name) \(flags)",
                                 prelude: flags == 0 ? "" : "\\033[>\(flags)u")
            if !headless { NSApp.activate(ignoringOtherApps: true) }
            guard await k.waitReady() else { r.check("copy terminal ready", false); continue }
            if korean { await attachIME(k) }
            await sleepMs(300)
            let mode = "\(name) source, \(flags == 0 ? "legacy" : "kitty \(flags)")"
            let intr: [UInt8] = flags == 0 ? [0x03] : Array("\u{1b}[99;5u".utf8)
            let krec = k.view as? RecordingSurfaceView
            func keys(_ ks: [Key], _ n: Int) async -> [UInt8] {
                krec?.log = []
                k.mark()
                await post(ks, to: k.window, gapMs: gap)
                return await k.waitBytes(atLeast: n)
            }
            let noJamo = { (b: [UInt8]) in !String(decoding: b, as: UTF8.self).contains("ㅊ") && !show(b).contains("12618") }
            let ctrlC = Key.ctrlC(korean: korean)

            let idle = await keys([ctrlC], intr.count)
            r.check("[\(mode)] Ctrl+C sends the interrupt, no ㅊ", idle == intr && noJamo(idle), "pty=\"\(show(idle))\"")

            _ = await keys(Key.latin(korean ? "rk " : "ga "), 2)
            k.view.performBindingAction("select_all")
            await sleepMs(100)
            let sel = await keys([ctrlC], intr.count)
            r.check("[\(mode)] Ctrl+C with a selection sends the interrupt, no ㅊ", sel == intr && noJamo(sel), "pty=\"\(show(sel))\"")

            if korean {
                let comp = await keys(Key.latin("rk") + [ctrlC], 3 + intr.count)
                r.check("[\(mode)] Ctrl+C while composing commits 가, then the interrupt, no ㅊ",
                        comp == Array("가".utf8) + intr, "pty=\"\(show(comp))\"" + (comp == Array("가".utf8) + intr ? "" : " trace: " + (krec?.log.joined(separator: " ") ?? "")))
            }

            pb.declareTypes([.string], owner: nil)
            pb.setString("before-copy", forType: .string)
            k.view.performBindingAction("select_all")
            await sleepMs(100)
            let cc = await keys([korean ? .cmdCKorean : .cmd("c")], 1)
            await sleepMs(150)
            let copied = pb.string(forType: .string) ?? ""
            r.check("[\(mode)] Cmd+C with a selection copies it, types nothing",
                    copied != "before-copy" && copied.contains(korean ? "가" : "ga") && cc.isEmpty,
                    "clipboard=\"\(copied.prefix(40))\" pty=\"\(show(cc))\"")

            pb.setString("! gcloud auth login", forType: .string)
            let paste = await keys([ctrlC, .cmd("v")], intr.count + 19)
            r.check("[\(mode)] Ctrl+C then Cmd+V: the interrupt, then exactly the clipboard, no stray jamo",
                    paste == intr + Array("! gcloud auth login".utf8), "pty=\"\(show(paste))\"")
            k.window.close()
        }
    }
}

// MARK: - Font checks

@MainActor
func printText(_ term: SinkTerminal, _ text: String) async {
    let surface = term.view.surface!
    text.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
    _ = await term.waitBytes(atLeast: text.utf8.count)
    await sleepMs(250)
}

/// Draw "x가x" and measure Hangul glyph extent and baseline vs Latin.
@MainActor
func measureHangul(_ r: Report, runtime: GhosttyRuntime, label: String, expectFamily: String) async -> Double? {
    let term = SinkTerminal(runtime: runtime, view: { SurfaceView(app: $0, options: $1) }, title: "font \(label)")
    guard await term.waitReady() else { r.check("[\(label)] terminal ready", false); return nil }
    await sleepMs(300)
    let v = term.view
    let family = primaryFontFamily(v)
    r.check("[\(label)] primary font family is \(expectFamily)", family == expectFamily, "got \(family)")
    guard let g = gridAtOrigin(v) else { return nil }
    await printText(term, "x가xㅎx")
    let cur = imePoint(v)
    let cols = ((cur.minX * (v.window?.backingScaleFactor ?? 2) - g.x0) / g.cw).rounded()
    guard let f = grabFrame(v) else { r.check("[\(label)] frame", false); return nil }
    let y0 = Int(g.top), y1 = Int(g.top + g.ch)
    let x = inkBox(f, x0: g.col(0), x1: g.col(1), y0: y0, y1: y1)
    let ga = inkBox(f, x0: g.col(1), x1: g.col(3), y0: y0, y1: y1)
    let x2 = inkBox(f, x0: g.col(3), x1: g.col(4), y0: y0, y1: y1)
    let jamo = inkBox(f, x0: g.col(4), x1: g.col(6), y0: y0, y1: y1)
    guard let x, let ga, let x2, let jamo else {
        r.check("[\(label)] glyph ink found", false, "x=\(String(describing: x)) 가=\(String(describing: ga))")
        return nil
    }
    // Width: 가 must extend past its first cell and stay within its 2 cells.
    let wide = ga.maxX >= g.col(2) && ga.minX >= g.col(1) && ga.maxX < g.col(3) && x2.minX >= g.col(3)
    r.check("[\(label)] Hangul occupies exactly 2 cells (cursor col after \"x가xㅎx\" = 7)",
            cols == 7 && wide,
            "cursorCol=\(Int(cols)) 가 ink x=\(ga.minX)...\(ga.maxX) cells[\(g.col(1)),\(g.col(3))) cw=\(g.cw)px")
    // Baseline: compare the bottom of 가 / ㅎ with the bottom of x (Latin baseline).
    let dGa = Double(ga.maxY - x.maxY), dJamo = Double(jamo.maxY - x.maxY)
    // ㅎ has a flat bottom stroke that sits on the baseline; 가's ㅏ descends a
    // few px below it by design (same offset in D2Coding itself, cross-checked below).
    let inCell = ga.minY >= y0 && ga.maxY < y1 && jamo.minY >= y0 && jamo.maxY < y1
    let aligned = abs(dJamo) <= 1
    r.check("[\(label)] Hangul baseline-aligned with Latin (ㅎ bottom = x bottom ±1px) and inside the cell",
            inCell && aligned,
            "bottom(가)-bottom(x)=\(Int(dGa))px, bottom(ㅎ)-bottom(x)=\(Int(dJamo))px, cellH=\(Int(g.ch))px, 가 y=\(ga.minY)...\(ga.maxY) row=[\(y0),\(y1))")
    term.window.close()
    keepAlive.append(term)
    return dGa
}

@MainActor
func runFontChecks(_ r: Report) async {
    // The bundled D2Coding (Regular + Bold WOFF) is what got registered, not a system install.
    LmuxConfig.registerBundledFonts()
    let registered = LmuxConfig.registeredFontFiles.flatMap { url in
        (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []).compactMap {
            (CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String).map { ($0, url.lastPathComponent) }
        }
    }
    r.check("bundled fonts: D2Coding Regular + Bold only, as WOFF",
            Set(registered.map(\.1)) == ["D2Coding-Regular.woff", "D2Coding-Bold.woff"]
            && Set(registered.map(\.0)) == ["D2Coding", "D2CodingBold"], "\(registered)")
    r.mode = "font"
    // CoreText: D2Coding Hangul advance = 2 x Latin advance.
    let ct = CTFontCreateWithName("D2Coding" as CFString, 13, nil)
    var chars: [UniChar] = Array("a가".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: 2)
    CTFontGetGlyphsForCharacters(ct, &chars, &glyphs, 2)
    var adv = [CGSize](repeating: .zero, count: 2)
    CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyphs, &adv, 2)
    r.check("D2Coding (\(CTFontCopyFamilyName(ct) as String)) Hangul advance = 2 x Latin advance",
            (CTFontCopyFamilyName(ct) as String) == "D2Coding" && adv[1].width == 2 * adv[0].width,
            "a=\(adv[0].width) 가=\(adv[1].width)")

    guard let ko = GhosttyRuntime(fontProfile: .korean) else { r.check("runtime (korean)", false); return }
    keepAlive.append(ko)
    let dKo = await measureHangul(r, runtime: ko, label: "D2Coding", expectFamily: "D2Coding")
    guard let menlo = GhosttyRuntime(simulatedUserConfig: ["font-family = Menlo"], fontProfile: .korean) else {
        r.check("runtime (Menlo)", false); return
    }
    keepAlive.append(menlo)
    let dMenlo = await measureHangul(r, runtime: menlo, label: "Menlo+Hangul→D2Coding", expectFamily: "Menlo")
    r.check("Hangul vertical placement next to Menlo matches D2Coding's own (가 bottom offset)",
            dKo != nil && dMenlo != nil && abs(dKo! - dMenlo!) <= 1,
            "가 bottom - x bottom: D2Coding \(dKo.map { Int($0) } ?? -99)px, Menlo \(dMenlo.map { Int($0) } ?? -99)px")
}

// MARK: - Font profile / config precedence

@MainActor
func runConfigChecks(_ r: Report) async {
    r.mode = "config"
    let suite = "dev.lmux.imetest.\(getpid())"
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }

    let p1 = LmuxConfig.resolveFontProfile(defaults: d) { "ko-KR" }
    r.check("ko system language → korean profile (D2Coding)", p1 == .korean)
    let p2 = LmuxConfig.resolveFontProfile(defaults: d) { "en-US" }
    r.check("persisted profile is reused on next launch even if language changed", p2 == .korean,
            "stored=\(d.string(forKey: LmuxConfig.fontProfileDefaultsKey) ?? "nil")")
    d.removePersistentDomain(forName: suite)
    let p3 = LmuxConfig.resolveFontProfile(defaults: d) { "en-US" }
    r.check("en system language → default profile", p3 == .default)

    let none: (String) -> Bool = { _ in false }
    let userFont: (String) -> Bool = { $0 == "font-family" }
    let planKo = LmuxConfig.plan(fontProfile: .korean, userSets: none)
    let planEn = LmuxConfig.plan(fontProfile: .default, userSets: none)
    r.check("plan(ko): font-family = D2Coding after user config", planKo.afterUser == ["font-family = D2Coding"])
    r.check("plan(en): no font-family set", !(planEn.beforeUser + planEn.afterUser).contains { $0.hasPrefix("font-family") })
    r.check("plan(ko/en): user font-family wins (nothing injected)",
            LmuxConfig.plan(fontProfile: .korean, userSets: userFont).afterUser.isEmpty
            && LmuxConfig.plan(fontProfile: .default, userSets: userFont).afterUser.isEmpty)
    let cpm = planEn.beforeUser.filter { $0.hasPrefix("font-codepoint-map") }
    r.check("plan(both): Hangul codepoint-map → D2Coding loaded BEFORE user config (user mapping wins)",
            cpm.count == 5 && planKo.beforeUser.filter { $0.hasPrefix("font-codepoint-map") } == cpm)
    r.check("plan: theme = light:Nord Light,dark:Nord unless user sets theme",
            planEn.beforeUser.contains("theme = light:Nord Light,dark:Nord")
            && !LmuxConfig.plan(fontProfile: .default, userSets: { $0 == "theme" }).beforeUser.contains { $0.hasPrefix("theme") })

    // End to end: what libghostty actually resolves as the primary font.
    for (label, profile, user, expect) in [
        ("ko profile", LmuxConfig.FontProfile.korean, [String](), "D2Coding"),
        ("en profile", .default, [], "JetBrains Mono"),
        ("ko + user Menlo", .korean, ["font-family = Menlo"], "Menlo"),
        ("en + user Menlo", .default, ["font-family = Menlo"], "Menlo"),
    ] {
        guard let rt = GhosttyRuntime(simulatedUserConfig: user, fontProfile: profile) else {
            r.check("e2e \(label)", false, "runtime"); continue
        }
        keepAlive.append(rt)
        let v = SurfaceView(app: rt.app!, options: SurfaceOptions(command: "/bin/cat"))
        let fam = primaryFontFamily(v)
        r.check("e2e \(label): primary font = \(expect)", fam == expect, "got \(fam)")
        v.close()
    }
}

// MARK: - Entry

@MainActor
func runChecklist() async -> Int32 {
    let r = Report()
    print("lmux IME checklist — input source at start: \(currentInputSourceID())")

    await runConfigChecks(r)
    await runFontChecks(r)
    await runThemeChecks(r)

    guard let imeRuntime = GhosttyRuntime(fontProfile: .korean) else { print("runtime failed"); return 2 }
    keepAlive.append(imeRuntime)
    r.mode = "simulated-IME"
    NSEvent.layoutCharactersOverride = simulatedKoreanLayout
    await runIMEChecks(r, runtime: imeRuntime, real: false)
    r.mode = "shortcuts, simulated IME"
    _ = await runShortcutMatrix(runtime: imeRuntime, real: false, attach: { _ in }, report: { r.check($0, $1, $2) })
    await reportOptionAsAlt(real: false, attach: { _ in }, report: { print("NOTE  [\(r.mode)] \($0)  -- \($1)") })
    r.mode = "simulated CJK IME"
    NSEvent.layoutCharactersOverride = { simulatedKoreanLayout($0, $1) ?? simulatedCJKLayout($0, $1) }
    await runCJKChecks(r, runtime: imeRuntime)
    NSEvent.layoutCharactersOverride = nil

    if headless {
        print("SKIP  real-IME checks (need a visible, focused window; run with --visible)")
    } else {
        let original = currentInputSourceID()
        startInputSourceID = original
        let korean = koreanInputSourceID
        if selectInputSource(korean) {
            r.mode = "real-IME"
            await sleepMs(300)
            await runIMEChecks(r, runtime: imeRuntime, real: true)
            selectInputSource(original)
        } else {
            print("SKIP  real-IME checks: \(korean) is not enabled")
        }
    }

    let passed = r.results.filter(\.pass).count
    let total = r.results.count
    print("")
    print("RESULT: \(passed == total ? "PASS" : "FAIL") (\(passed)/\(total) checks passed)")
    return passed == total ? 0 : 1
}

// MARK: - Theme (Nord light/dark) + in-process screenshots

@MainActor
func savePNG(_ f: Frame, to url: URL) {
    let data = Data(f.px) as CFData
    guard let provider = CGDataProvider(data: data),
          let img = CGImage(width: f.w, height: f.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.bpr,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                     | CGImageAlphaInfo.premultipliedFirst.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return }
    let rep = NSBitmapImageRep(cgImage: img)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

@MainActor
func runThemeChecks(_ r: Report) async {
    r.mode = "theme"
    let snapDir = ProcessInfo.processInfo.environment["LMUX_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    guard let rt = GhosttyRuntime(fontProfile: .korean) else { r.check("runtime", false); return }
    keepAlive.append(rt)

    let dir = imetestTempDir
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("demo.sh")
    try? #"""
    #!/bin/sh
    printf 'dev@lmux ~/workspace %% claude\n'
    printf '안녕하세요! lmux는 한글 입력이 잘 되는 터미널입니다. (D2Coding, 2칸 폭)\n'
    printf 'ASCII  The quick brown fox jumps over the lazy dog 0123456789\n'
    for i in 0 1 2 3 4 5 6 7; do printf '\033[4%sm  \033[0m' $i; done; printf '\n'
    for i in 0 1 2 3 4 5 6 7; do printf '\033[10%sm  \033[0m' $i; done; printf '\n'
    printf '\033[31mred \033[32mgreen \033[33myellow \033[34mblue \033[35mmagenta \033[36mcyan\033[0m\n'
    printf '> '
    exec cat > /dev/null
    """#.write(to: script, atomically: true, encoding: .utf8)
    chmod(script.path, 0o755)

    for (name, appearance, expectBG) in [("dark", NSAppearance.Name.darkAqua, Nord.darkBackground),
                                         ("light", .aqua, Nord.lightBackground)] {
        NSApp.appearance = NSAppearance(named: appearance)
        await sleepMs(200)
        let v = SurfaceView(app: rt.app!, options: SurfaceOptions(command: script.path))
        let frame = headless ? NSRect(x: -10000, y: -10000, width: 760, height: 260) : NSRect(x: 200, y: 200, width: 760, height: 260)
        let w = NSWindow(contentRect: frame, styleMask: headless ? [.borderless] : [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = v
        w.orderFrontRegardless()
        if headless { w.setFrameOrigin(NSPoint(x: -10000, y: -10000)) }
        await sleepMs(1500)
        guard let f = grabFrame(v) else { r.check("[\(name)] frame", false); continue }
        let px = f.rgb(f.w - 3, f.h - 3)
        let e = expectBG.usingColorSpace(.sRGB)!
        let want = (Int((e.redComponent * 255).rounded()), Int((e.greenComponent * 255).rounded()), Int((e.blueComponent * 255).rounded()))
        let close = abs(px.0 - want.0) + abs(px.1 - want.1) + abs(px.2 - want.2) <= 6
        r.check("[\(name)] default theme renders Nord\(name == "light" ? " Light" : "") background",
                close, "pixel=\(px) expected=\(want)")
        let tb = v.terminalBackground?.usingColorSpace(.sRGB)
        let tbv = tb.map { (Int(($0.redComponent * 255).rounded()), Int(($0.greenComponent * 255).rounded()), Int(($0.blueComponent * 255).rounded())) }
        r.check("[\(name)] window chrome color (from CONFIG_CHANGE) = terminal background",
                tbv.map { abs($0.0 - want.0) + abs($0.1 - want.1) + abs($0.2 - want.2) <= 3 } ?? false,
                "terminalBackground=\(String(describing: tbv))")
        if let snapDir {
            try? FileManager.default.createDirectory(at: snapDir, withIntermediateDirectories: true)
            savePNG(f, to: snapDir.appendingPathComponent("lmux-\(name).png"))
        }
        w.close()
        keepAlive.append(v)
    }
    NSApp.appearance = nil
}
