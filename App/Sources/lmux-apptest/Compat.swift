import AppKit
import GhosttyKit
import LmuxHooks
import LmuxTerminal
@testable import LmuxUI

// `lmux-apptest --compat`: everyday terminal work outside the happy path, on real programs
// (python fixtures, vim, less, top) in headless panes: wide text, huge output, binary garbage,
// title / bell / OSC storms, kitty keyboard flags, mouse reporting, bracketed and huge pastes,
// resize storms, occlusion, appearance switches, malformed hook payloads. Nothing touches the
// user's clipboard (private pasteboard), history (isolated shell) or Claude config.

@MainActor
private final class StallMeter {
    /// Longest gap between main-queue ticks (ms) while running: how long the UI froze.
    private(set) var worst: Double = 0
    private var last = CACurrentMediaTime()
    private var timer: Timer?
    func start() {
        worst = 0; last = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.worst = max(self.worst, (now - self.last) * 1000)
                self.last = now
            }
        }
    }
    func stop() -> Double { timer?.invalidate(); timer = nil; return worst }
}

@MainActor
func runCompat() async -> Int32 {
    let r = Report()
    // Every pane must run the isolated shell (App/scripts/isolated-shell.sh), never the user's login zsh.
    guard (env["LMUX_PANE_COMMAND"] ?? "").hasSuffix("pane-shell") else {
        print("lmux-apptest --compat: LMUX_PANE_COMMAND must be isolated-shell.sh's pane-shell")
        return 2
    }
    let c = makeController()
    let w = c.window!
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("compat", isDirectory: true)
    try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
    let py = env["LMUX_COMPAT_PYTHON"] ?? "/usr/bin/python3"
    let only = env["LMUX_COMPAT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    func want(_ s: String) -> Bool { only?.contains(s) ?? true }

    /// A python fixture as a pane program; `out` is where it reports.
    func program(_ name: String, _ code: String) -> String {
        let f = fx.appendingPathComponent("\(name).py")
        try? code.write(to: f, atomically: true, encoding: .utf8)
        let sh = fx.appendingPathComponent("\(name).sh")
        try? "#!/bin/sh\nexec '\(py)' '\(f.path)' '\(fx.path)'\n".write(to: sh, atomically: true, encoding: .utf8)
        chmod(sh.path, 0o755)
        return sh.path
    }
    func out(_ name: String) -> String { (try? String(contentsOf: fx.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    func waitFile(_ name: String, contains: String = "", _ t: Double = 10) async -> Bool {
        await waitFor(t) { let s = out(name); return !s.isEmpty && (contains.isEmpty || s.contains(contains)) }
    }
    func shown(_ ws: Workspace) async { c.select(ws); await sleepMs(150) }

    // ------------------------------------------------------------------ text
    if want("text") {
        r.section = "text"
        let samples: [(String, String, Int)] = [
            ("korean", "한글 테스트", 11), ("japanese", "日本語のテキスト", 16), ("chinese", "中文测试", 8),
            ("emoji-zwj", "👨‍👩‍👧‍👦", 2), ("flag", "🇰🇷", 2), ("combining", "e\u{301}a\u{308}", 2),
            ("rtl", "שלום عربى", 9), ("nerd-pua", "\u{e0a0}\u{f121}", 2),
        ]
        var code = "import sys,os,tty,termios\nd=sys.argv[1]\nfd=sys.stdin.fileno()\ntty.setraw(fd)\nres=[]\n"
        code += "def col(s):\n  os.write(1,b'\\r\\x1b[2K'+s.encode()+b'\\x1b[6n')\n  b=b''\n  while not b.endswith(b'R'): b+=os.read(fd,1)\n  return int(b.split(b';')[1][:-1])-1\n"
        for (n, s, _) in samples { code += "res.append('\(n)=%d' % col(\(String(reflecting: s))))\nos.write(1,b'\\r\\n')\n" }
        code += "open(d+'/text.out','w').write('\\n'.join(res)+'\\n')\nimport time\ntime.sleep(1000)\n"
        let ws = c.newWorkspace(program: program("text", code))
        await shown(ws)
        let ok = await waitFile("text.out", contains: "nerd-pua")
        let got = Dictionary(uniqueKeysWithValues: out("text.out").split(separator: "\n").compactMap { l -> (String, Int)? in
            let kv = l.split(separator: "="); return kv.count == 2 ? (String(kv[0]), Int(kv[1]) ?? -1) : nil })
        r.check("the fixture reported cursor columns", ok)
        for (n, s, cols) in samples {
            r.check("\(n): cursor after \(s.debugDescription) at column \(cols)", got[n] == cols, "got \(got[n].map(String.init) ?? "-")")
        }
        let screen = ws.panes[0].surface.readText()
        for (n, s, _) in samples where !["combining", "rtl"].contains(n) {
            r.check("\(n): reads back from the screen", screen.contains(s), screen.prefix(300).description)
        }
        c.closeWorkspace(ws)
    }

    // ------------------------------------------------------------- huge output
    if want("huge") {
        r.section = "huge"
        let sh = fx.appendingPathComponent("huge.sh")
        try? """
        #!/bin/sh
        S=$(date +%s)
        yes 'the quick brown fox jumps over the lazy dog 0123456789' | head -n 2000000
        head -c 300000 /dev/zero | tr '\\0' 'x'; echo
        echo "$(($(date +%s) - S))" > '\(fx.path)/huge.done'
        exec sleep 1000
        """.write(to: sh, atomically: true, encoding: .utf8)
        chmod(sh.path, 0o755)
        let m = StallMeter()
        m.start()
        let t0 = Date()
        let ws = c.newWorkspace(program: sh.path)
        await shown(ws)
        let done = await waitFile("huge.done", 120)
        let secs = Date().timeIntervalSince(t0)
        let stall = m.stop()
        r.check("2M lines + a 300k-char line finish", done, String(format: "%.1fs", secs))
        r.check("the UI never froze for more than 1s meanwhile", stall < 1000, String(format: "worst main-queue gap %.0f ms, %.1fs total", stall, secs))
        print(String(format: "      huge output: %.1fs, worst main-queue gap %.0f ms", secs, stall))
        let lines = ws.panes[0].surface.readText().split(separator: "\n")
        r.check("the screen ends with the long line wrapped (no crash, still drawing)", lines.contains { $0.hasPrefix("xxxxxxxx") })
        c.closeWorkspace(ws)
    }

    // --------------------------------------------------------- binary garbage
    if want("garbage") {
        r.section = "garbage"
        let sh = fx.appendingPathComponent("garbage.sh")
        try? """
        #!/bin/sh
        head -c 3000000 /dev/urandom
        printf '\\033c'
        echo GARBAGE-SURVIVED
        echo ok > '\(fx.path)/garbage.done'
        exec sleep 1000
        """.write(to: sh, atomically: true, encoding: .utf8)
        chmod(sh.path, 0o755)
        let m = StallMeter(); m.start()
        let ws = c.newWorkspace(program: sh.path)
        await shown(ws)
        let done = await waitFile("garbage.done", 60)
        let stall = m.stop()
        r.check("3MB of /dev/urandom then RIS: the app survives", done)
        r.check("…and the terminal draws text again", await waitFor(3) { ws.panes[0].surface.readText().contains("GARBAGE-SURVIVED") })
        r.check("…the UI never froze for more than 1s", stall < 1000, String(format: "%.0f ms", stall))
        r.check("…the window title is still sane", (ws.panes[0].title.count) <= 4096, "\(ws.panes[0].title.count) chars")
        c.closeWorkspace(ws)
    }

    // ------------------------------------------------- title, bell, OSC 9 storms
    if want("osc") {
        r.section = "osc"
        let other = c.newWorkspace(select: false)  // so the storm pane is never the only one
        let storms: [(String, String)] = [
            ("bigtitle", "w('\\x1b]2;' + 'T'*20000 + '\\x07')"),
            ("titles", "for i in range(3000): w('\\x1b]2;spin %d\\x07' % i)"),
            ("bells", "for i in range(2000): w('\\x07')"),
            ("osc9", "for i in range(500): w('\\x1b]9;note %d\\x07' % i)"),
        ]
        for (name, body) in storms {
            let code = """
            import sys,os,time
            d=sys.argv[1]
            w=lambda s: os.write(1,s.encode())
            while not os.path.exists(d+'/\(name).go'): time.sleep(0.02)
            \(body)
            open(d+'/\(name).done','w').write('ok')
            time.sleep(1000)
            """
            let ws = c.newWorkspace(program: program(name, code))
            await shown(ws)
            await sleepMs(500)
            let m = StallMeter(); m.start()
            FileManager.default.createFile(atPath: fx.appendingPathComponent("\(name).go").path, contents: Data())
            let done = await waitFile("\(name).done", 20)
            await sleepMs(1500)
            let stall = m.stop()
            // 3000 distinct titles used to refresh the row 3000 times on the main thread (~0.9s frozen):
            // a burst is applied once per main-queue turn now.
            let limit: Double = name == "titles" ? 250 : 1000
            r.check("\(name) storm: the UI never froze for more than \(Int(limit))ms", done && stall < limit, String(format: "%.0f ms", stall))
            if name == "bigtitle" {
                r.check("a 20k-char title doesn't end up whole in the row title", ws.title.count <= 64, "\(ws.title.count) chars")
                c.saveNow()
                let after = (try? Data(contentsOf: paths.layoutFile)).map { $0.count } ?? 0
                r.check("layout.json after a 20k-char title (\(after) bytes)", after < 20000)
            }
            if name == "titles" { r.check("the last title wins", ws.panes[0].title == "spin 2999", ws.panes[0].title) }
            c.closeWorkspace(ws)
        }
        c.closeWorkspace(other)
    }

    // ------------------------------------------------------------ kitty keys
    if want("kitty") {
        r.section = "kitty"
        // Push the kitty flags Claude Code uses, then record every byte the pty gets.
        for flags in [1, 5] {
            let name = "kitty\(flags)"
            let code = """
            import sys,os,tty
            d=sys.argv[1]
            fd=sys.stdin.fileno(); tty.setraw(fd)
            os.write(1,b'\\x1b[>\(flags)u')
            open(d+'/\(name).ready','w').write('1')
            f=open(d+'/\(name).bin','wb',buffering=0)
            while True:
                b=os.read(fd,4096)
                if not b: break
                f.write(b)
            """
            let ws = c.newWorkspace(program: program(name, code))
            await shown(ws)
            let p = ws.panes[0]
            _ = await waitFile("\(name).ready")
            await sleepMs(200)
            var mark = 0
            func bytes() -> String { String(out("\(name).bin").unicodeScalars.dropFirst(mark)).unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? String(format: "\\x%02x", $0.value) : String($0) }.joined() }
            // `lmux send` (also how forget / restore type a command)
            p.surface.sendText("ab\n")
            await sleepMs(300)
            let sent = bytes()
            r.check("flags \(flags): `lmux send \"ab\\n\"` arrives as ab + Return", sent.hasPrefix("ab") && (sent.contains("\\x0d") || sent.contains("[13u")), sent)
            mark = out("\(name).bin").unicodeScalars.count
            // Ctrl-C the way forget interrupts Claude.
            p.surface.sendKey(keyCode: 8, codepoint: 0x63, control: true)
            await sleepMs(300)
            let cc = bytes()
            mark = out("\(name).bin").unicodeScalars.count
            r.check("flags \(flags): forget's Ctrl-C reaches the program", cc.contains("\\x03") || cc.contains("99;5u"), cc)
            // Esc key
            p.surface.sendKey(keyCode: 53, codepoint: 0x1b)
            await sleepMs(300)
            let esc = bytes()
            r.check("flags \(flags): Esc reaches the program", esc.contains("\\x1b"), esc)
            // ⌘D still splits (lmux shortcut is not swallowed by the kitty mode)
            c.focus(p)
            let before = ws.panes.count
            await cmd("d", window: w)
            r.check("flags \(flags): ⌘D still splits", ws.panes.count == before + 1)
            c.closeWorkspace(ws)
        }
    }

    // ------------------------------------------------- mouse reporting / paste
    if want("mouse") {
        r.section = "mouse"
        let code = """
        import sys,os,tty
        d=sys.argv[1]
        fd=sys.stdin.fileno(); tty.setraw(fd)
        os.write(1,b'\\x1b[?1049h\\x1b[?1000h\\x1b[?1006h\\x1b[?2004h\\x1b[Halt screen\\r\\n! open -a Safari ~')
        open(d+'/mouse.ready','w').write('1')
        f=open(d+'/mouse.bin','wb',buffering=0)
        while True:
            b=os.read(fd,65536)
            if not b: break
            f.write(b)
        """
        let ws = c.newWorkspace(program: program("mouse", code))
        await shown(ws)
        let p = ws.panes[0]
        _ = await waitFile("mouse.ready")
        await sleepMs(300)
        c.focus(p)
        let s = p.surface
        let at = NSPoint(x: 100, y: s.bounds.height - 60)
        if let mv = NSEvent.mouseEvent(with: .mouseMoved, location: s.convert(at, to: nil), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { s.mouseMoved(with: mv) }
        await click(s, at: at)
        var mark = 0
        func fresh() -> String { String(out("mouse.bin").unicodeScalars.dropFirst(mark)) }
        func size() -> Int { (try? FileManager.default.attributesOfItem(atPath: fx.appendingPathComponent("mouse.bin").path)[.size] as? Int) ?? 0 }
        _ = await waitFor(2) { out("mouse.bin").contains("\u{1b}[<0;") }
        let mb = out("mouse.bin")
        r.check("SGR mouse: a click reaches the program as press + release", mb.contains("M\u{1b}[<0;") && mb.hasSuffix("m"), mb.debugDescription)
        mark = out("mouse.bin").unicodeScalars.count
        // ⌘V of a multi-line text into a bracketed-paste program (private pasteboard).
        let pb = GhosttyRuntime.standardPasteboard
        pb.clearContents(); pb.setString("line1\nline2", forType: .string)
        await cmd("v", window: w)
        _ = await waitFor(2) { fresh().contains("\u{1b}[201~") }
        let pasted = fresh()
        r.check("bracketed paste: ⌘V arrives wrapped in 200~ / 201~", pasted.hasPrefix("\u{1b}[200~line1") && pasted.contains("line2\u{1b}[201~"), pasted.debugDescription)
        // An image on the clipboard, then text copied in the pane: ⌘V sends that text, one paste, no image.
        let tile = NSImage(size: NSSize(width: 8, height: 8))
        tile.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); tile.unlockFocus()
        pb.clearContents(); pb.setData(tile.tiffRepresentation, forType: .tiff)
        _ = s.performBindingAction("select_all")
        _ = s.performBindingAction("copy_to_clipboard")
        _ = s.performBindingAction("clear_selection")
        mark = out("mouse.bin").unicodeScalars.count
        await cmd("v", window: w)
        _ = await waitFor(2) { fresh().contains("\u{1b}[201~") }
        await sleepMs(200)
        let afterImage = fresh()
        r.check("image, then text copied in the pane: ⌘V pastes the text alone, once",
                afterImage.contains("Safari ~\u{1b}[201~") && afterImage.components(separatedBy: "\u{1b}[200~").count == 2
                && !afterImage.contains(".png"), afterImage.debugDescription)
        mark = out("mouse.bin").unicodeScalars.count
        // 10 MB paste
        let base = size()
        let big = String(repeating: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\n", count: 160_000)  // ~10 MB
        pb.clearContents(); pb.setString(big, forType: .string)
        let m = StallMeter(); m.start()
        let t0 = Date()
        await cmd("v", window: w)
        let arrived = await waitFor(60) { size() - base >= big.utf8.count + 12 }
        let stall = m.stop()
        let got = size() - base
        r.check("10 MB paste arrives whole", arrived && got == big.utf8.count + 12, "\(got) of \(big.utf8.count + 12) bytes in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        r.check("…the UI never froze for more than 1s", stall < 1000, String(format: "%.0f ms", stall))
        print(String(format: "      10MB paste: %.1fs, worst main-queue gap %.0f ms", Date().timeIntervalSince(t0), stall))
        // paste while composing (Korean preedit "ㅎ")
        mark = out("mouse.bin").unicodeScalars.count
        pb.clearContents(); pb.setString("XY", forType: .string)
        s.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        await cmd("v", window: w)
        await sleepMs(300)
        let comp = fresh()
        r.check("⌘V while composing: the pasted text arrives once", comp.components(separatedBy: "XY").count == 2, comp.debugDescription)
        s.unmarkText()
        pb.clearContents()
        c.closeWorkspace(ws)
    }

    // ------------------------------------------------------- resize storm
    if want("resize") {
        r.section = "resize"
        let code = """
        import sys,os,signal,time,fcntl,termios,struct
        d=sys.argv[1]
        os.write(1,b'\\x1b[?1049h')
        def sz():
            r,c,_,_=struct.unpack('HHHH',fcntl.ioctl(1,termios.TIOCGWINSZ,b'\\0'*8))
            return r,c
        def on(*a):
            r,c=sz(); open(d+'/resize.log','a').write('%d %d\\n'%(r,c))
            os.write(1,('\\x1b[H\\x1b[2Jsize %d x %d'%(r,c)).encode())
        signal.signal(signal.SIGWINCH,on)
        on()
        while True: time.sleep(1)
        """
        let ws = c.newWorkspace(program: program("resize", code))
        await shown(ws)
        let p = ws.panes[0]
        _ = await waitFile("resize.log")
        let m = StallMeter(); m.start()
        var rng = SystemRandomNumberGenerator()
        for i in 0..<200 {
            let wdt = CGFloat(Int.random(in: 600...1800, using: &rng)), hgt = CGFloat(Int.random(in: 360...1100, using: &rng))
            w.setFrame(NSRect(x: -10000, y: -10000, width: wdt, height: hgt), display: false)
            if i % 25 == 0 { c.toggleSidebar() }
            if i % 10 == 0 { await sleepMs(5) }
        }
        if !c.model.sidebarVisible { c.toggleSidebar() }
        w.setFrame(NSRect(x: -10000, y: -10000, width: 1280, height: 800), display: false)
        w.contentView?.layoutSubtreeIfNeeded()
        await sleepMs(800)
        let stall = m.stop()
        let gs = ghostty_surface_size(p.surface.surface!)
        let last = out("resize.log").split(separator: "\n").last.map(String.init) ?? ""
        r.check("after 200 resizes + sidebar toggles, the program's size = the terminal's", last == "\(gs.rows) \(gs.columns)",
                "program \(last), terminal \(gs.rows) \(gs.columns)")
        r.check("…and the screen shows the final size", await waitFor(2) { p.surface.readText().contains("size \(gs.rows) x \(gs.columns)") })
        r.check("…the UI never froze for more than 1s", stall < 1000, String(format: "%.0f ms", stall))
        c.closeWorkspace(ws)
    }

    // ------------------------------------------------ occlusion / appearance
    if want("occlusion") {
        r.section = "occlusion"
        let code = """
        import sys,os,time
        d=sys.argv[1]
        while not os.path.exists(d+'/occ.go'): time.sleep(0.05)
        os.write(1,b'\\x1b[2J\\x1b[Hwritten-while-hidden')
        open(d+'/occ.done','w').write('1')
        time.sleep(1000)
        """
        let ws = c.newWorkspace(program: program("occ", code))
        await shown(ws)
        let p = ws.panes[0]
        c.windowShownOverride = false
        c.syncOcclusion()
        FileManager.default.createFile(atPath: fx.appendingPathComponent("occ.go").path, contents: Data())
        _ = await waitFile("occ.done")
        await sleepMs(200)
        c.windowShownOverride = nil
        c.syncOcclusion()
        r.check("output while occluded is there once visible again", await waitFor(2) { p.surface.readText().contains("written-while-hidden") })
        // Appearance switch at runtime, a few times.
        for a in [NSAppearance.Name.aqua, .darkAqua, .aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: a)
            await sleepMs(150)
        }
        NSApp.appearance = nil
        await sleepMs(150)
        r.check("appearance switches: the pane still draws", p.surface.readText().contains("written-while-hidden"))
        c.closeWorkspace(ws)
    }

    // ------------------------------------------------------- vim / less / top
    if want("tui") {
        r.section = "tui"
        let tf = fx.appendingPathComponent("file.txt")
        try? (1...500).map { "line \($0) 한글 😀" }.joined(separator: "\n").write(to: tf, atomically: true, encoding: .utf8)
        func tui(_ name: String, _ cmdline: String, ready: String, keys: [(UInt16, String)], until: () -> Bool) async {
            let sh = fx.appendingPathComponent("\(name).sh")
            // libghostty points TERMINFO at its resources dir; the test one has no terminfo.
            let ti = env["LMUX_COMPAT_TERMINFO"].map { "export TERMINFO='\($0)'\n" } ?? ""
            try? "#!/bin/sh\n\(ti)\(cmdline)\necho \"\(name)-exit=$?\" | tee '\(fx.path)/\(name).exit'\nexec sleep 1000\n".write(to: sh, atomically: true, encoding: .utf8)
            chmod(sh.path, 0o755)
            let ws = c.newWorkspace(program: sh.path)
            await shown(ws)
            let p = ws.panes[0]
            c.focus(p)
            let up = await waitFor(8) { p.surface.readText().contains(ready) }
            r.check("\(name): starts and draws", up, p.surface.readText().prefix(200).description)
            for i in 0..<5 {  // resize while it runs
                w.setFrame(NSRect(x: -10000, y: -10000, width: 900 + CGFloat(i * 80), height: 600 + CGFloat(i * 40)), display: false)
                await sleepMs(60)
            }
            w.setFrame(NSRect(x: -10000, y: -10000, width: 1280, height: 800), display: false)
            await sleepMs(300)
            for (code, ch) in keys {
                let ts = ProcessInfo.processInfo.systemUptime
                for t in [NSEvent.EventType.keyDown, .keyUp] {
                    let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ts, windowNumber: w.windowNumber,
                                             context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
                    dispatchKey(e, window: w)
                }
                await sleepMs(60)
            }
            let quit = await waitFile("\(name).exit", 8)
            r.check("\(name): quits on its own keys (exit status 0)", quit && out("\(name).exit").contains("=0"), out("\(name).exit"))
            let screen = p.surface.readText()
            r.check("\(name): the normal screen is back (alternate screen left)", until() && screen.contains("\(name)-exit=0")
                    && !screen.contains("line 30 "), screen.suffix(200).description)
            c.closeWorkspace(ws)
        }
        let vimOut = fx.appendingPathComponent("vim-out.txt").path
        await tui("vim", "vim -u NONE -N -n -i NONE -c 'set mouse=a' '\(tf.path)'", ready: "line 1 한글",
                  keys: [(53, "\u{1b}"), (2, "d"), (2, "d"), (41, ":"), (13, "w"), (49, " ")]
                    + "\(vimOut)".map { (UInt16(0), String($0)) } + [(36, "\r"), (41, ":"), (12, "q"), (47, "!"), (36, "\r")],
                  until: { (try? String(contentsOfFile: vimOut, encoding: .utf8))?.hasPrefix("line 2 ") ?? false })
        await tui("less", "LESSHISTFILE=- less '\(tf.path)'", ready: "line 1 한글",
                  keys: [(49, " "), (49, " "), (5, "G"), (12, "q")], until: { true })
        await tui("top", "top -s 1 -n 10", ready: "Processes", keys: [(12, "q")], until: { true })
    }

    // -------------------------------------------------------- hook fuzz
    if want("hooks") {
        r.section = "hooks"
        let ws = c.newWorkspace()
        let p = ws.panes[0]
        let junk = [
            "{}", #"{"hook_event_name":""}"#, #"{"hook_event_name":42}"#, #"{"hook_event_name":"FutureEvent2027","session_id":"s1"}"#,
            #"{"hook_event_name":"SessionStart","session_id":123,"cwd":null}"#,
            #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_input":"not an object"}"#,
            #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_input":{"command":["array"]}}"#,
            #"{"hook_event_name":"Notification","session_id":"s1","notification_type":{"x":1},"message":7}"#,
            #"{"hook_event_name":"Stop","session_id":"s1","stop_hook_active":"yes","last_assistant_message":{"a":1}}"#,
            #"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"\#(String(repeating: "x", count: 2_000_000))"}"#,
            #"{"hook_event_name":"SessionStart","session_id":"../../etc","transcript_path":"/dev/zero","cwd":"/nonexistent"}"#,
            #"{"hook_event_name":"SessionEnd","session_id":"never-started","reason":"other"}"#,
            "[1,2,3]", "{\"hook_event_name\":\"Stop\"", "\u{0}\u{1}\u{2}",
        ]
        var sent = 0
        for j in junk { if sendHook(pane: p.id, j) { sent += 1 } }
        // A raw line that isn't an envelope at all, and one of 9 MB.
        _ = HookClient.send(Array("not json at all\n".utf8), socketPath: paths.hookSocket)
        _ = HookClient.send(Array(repeating: UInt8(ascii: "a"), count: 9 << 20), socketPath: paths.hookSocket, writeTimeoutMs: 2000)
        await sleepMs(800)
        // Then a normal session still works.
        var events: [HookEvent] = []
        c.hookTap = { events.append($0) }
        _ = sendHook(pane: p.id, hook("UserPromptSubmit", session: "fuzz-ok", #""prompt":"hi""#))
        r.check("after \(junk.count) malformed / unknown payloads, a normal event still arrives",
                await waitFor(3) { events.contains { $0.sessionID == "fuzz-ok" } }, "sent \(sent)")
        r.check("…and the app answers the CLI", c.handleControl(["cmd": "list"])["ok"] as? Bool == true)
        c.hookTap = nil
        c.closeWorkspace(ws)
    }

    // ----------------------------------------------- Option as Meta, layouts
    if want("keys") {
        r.section = "keys"
        let code = """
        import sys,os,tty
        d=sys.argv[1]
        fd=sys.stdin.fileno(); tty.setraw(fd)
        open(d+'/keys.ready','w').write('1')
        f=open(d+'/keys.bin','wb',buffering=0)
        while True:
            b=os.read(fd,4096)
            if not b: break
            f.write(b)
        """
        let ws = c.newWorkspace(program: program("keys", code))
        await shown(ws)
        let p = ws.panes[0]
        c.focus(p)
        _ = await waitFile("keys.ready")
        await sleepMs(200)
        func key(_ chars: String, _ ign: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) async {
            let ts = ProcessInfo.processInfo.systemUptime
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ts, windowNumber: w.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code)!
                dispatchKey(e, window: w)
            }
            await sleepMs(150)
        }
        var mark = 0
        func fresh() -> String { let s = out("keys.bin"); defer { mark = s.unicodeScalars.count }; return String(s.unicodeScalars.dropFirst(mark)) }
        let cfg = LmuxConfigFile(url: LmuxConfig.configFile)
        for (setting, want) in [("false", "∫"), ("true", "\u{1b}b")] {
            try? cfg.set("macos-option-as-alt", [setting])
            c.reloadTerminalConfig()
            await sleepMs(300)
            _ = fresh()
            await key("∫", "b", 11, [.option])
            let got = fresh()
            if setting == "false" {
                r.check("macos-option-as-alt = false: ⌥B types \(want.debugDescription)", got == want, got.debugDescription)
            } else {
                // ESC + the current input source's character for B (ESC ㅠ with Korean 2-Set selected, as in
                // Ghostty): depends on the machine's input source, so reported only.
                r.check("macos-option-as-alt = true: ⌥B sends ESC + a character", got.hasPrefix("\u{1b}") && got.count == 2, got.debugDescription)
                print("      option-as-alt ⌥B -> \(got.debugDescription) (current input source)")
            }
        }
        try? cfg.set("macos-option-as-alt", [])
        c.reloadTerminalConfig()
        // Dvorak: the key that types "d" is QWERTY's H (keyCode 4); ⌘ of it is still ⌘D.
        let before = ws.panes.count
        await key("d", "d", 4, [.command])
        r.check("Dvorak ⌘D (H key position) splits", ws.panes.count == before + 1, "\(ws.panes.count)")
        c.closeWorkspace(ws)
    }

    // ---------------------------------------------------- screens (cmux #532 #2791 #1836 #1331)
    if want("screens") {
        r.section = "screens"
        let main = NSRect(x: 0, y: 0, width: 1512, height: 944), ext = NSRect(x: 1512, y: 0, width: 2560, height: 1415)
        let onExt = NSRect(x: 2000, y: 300, width: 1280, height: 800)
        r.check("on a screen: left alone", LmuxController.frameKeptOnScreen(onExt, screens: [main, ext]) == nil)
        r.check("partly off screen but the titlebar can be grabbed: left alone",
                LmuxController.frameKeptOnScreen(NSRect(x: 1300, y: 100, width: 1280, height: 800), screens: [main]) == nil)
        let back = LmuxController.frameKeptOnScreen(onExt, screens: [main])
        r.check("its display unplugged: back on the remaining one, same size",
                back.map { main.contains($0) && $0.size == onExt.size } ?? false, "\(String(describing: back))")
        let moved = NSRect(x: -2560, y: 0, width: 2560, height: 1415)  // the external display rearranged to the left
        let re = LmuxController.frameKeptOnScreen(onExt, screens: [main, moved])
        r.check("display arrangement changed under it: back on a screen", re.map { r in [main, moved].contains { $0.contains(r) } } ?? false,
                "\(String(describing: re))")
        let big = NSRect(x: 1600, y: 0, width: 2400, height: 1400)
        let shrunk = LmuxController.frameKeptOnScreen(big, screens: [main])
        r.check("bigger than the screen left: fits it", shrunk.map { main.contains($0) } ?? false, "\(String(describing: shrunk))")
        let below = NSRect(x: 100, y: -900, width: 1280, height: 800)  // titlebar under the bottom edge (wake)
        r.check("titlebar below every screen (after wake): comes back up",
                LmuxController.frameKeptOnScreen(below, screens: [main]).map { main.contains($0) } ?? false)
        r.check("headless never moves its off-screen window", { () -> Bool in
            let f = w.frame; c.keepWindowOnScreen(); return w.frame == f }())
    }

    // ------------------------------------------------- soft-wrapped copy (cmux #3096)
    if want("wrapcopy") {
        r.section = "wrapcopy"
        let long = (0..<30).map { "word\($0)" }.joined(separator: "-") + "-END"  // longer than the pane is wide
        let code = """
        import sys,os,time
        os.write(1,b'\\x1b[2J\\x1b[H' + \(String(reflecting: long)).encode() + b'\\r\\nnext line\\r\\n')
        time.sleep(1000)
        """
        let ws = c.newWorkspace(program: program("wrapcopy", code))
        await shown(ws)
        let p = ws.panes[0]
        c.split(p, .right).map { _ in () }  // narrow it so the line wraps
        await sleepMs(400)
        _ = await waitFor(3) { p.surface.readText().contains("next line") }
        let cols = Int(ghostty_surface_size(p.surface.surface!).columns)
        let pb = GhosttyRuntime.standardPasteboard
        pb.clearContents()
        _ = p.surface.performBindingAction("select_all")
        _ = p.surface.performBindingAction("copy_to_clipboard")
        let copied = pb.string(forType: .string) ?? ""
        r.check("the line really wraps (\(long.count) chars, \(cols) columns)", long.count > cols)
        r.check("copying it gives the line whole, no newline at the wrap", copied.contains(long + "\nnext line"), copied.debugDescription)
        pb.clearContents()
        c.closeWorkspace(ws)
    }

    // ------------------------------------- ⌘ shortcuts with the Korean IME (cmux #1790 #1945 #2215)
    if want("imecmd") {
        r.section = "imecmd"
        // The Korean 2-Set source: ⌘ events carry the Latin character, the key's own character is the jamo.
        let jamo: [String: String] = ["n": "ㅜ", "d": "ㅇ", "D": "ㅇ", "w": "ㅈ", "W": "ㅉ", "f": "ㄹ", "s": "ㄴ"]
        func press(_ ch: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) async {
            let ts = ProcessInfo.processInfo.systemUptime
            let ign = jamo[ch] ?? ch
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ts, windowNumber: w.windowNumber,
                                         context: nil, characters: ch, charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code)!
                dispatchKey(e, window: w)
            }
            await sleepMs(200)
        }
        let L = NSString(format: "%C", unichar(NSLeftArrowFunctionKey)) as String
        let R = NSString(format: "%C", unichar(NSRightArrowFunctionKey)) as String
        for composing in [false, true] {
            let tag = composing ? "composing" : "idle"
            while c.model.workspaces.count > 1 { c.closeWorkspace(c.model.workspaces.last!) }
            let base = c.model.workspaces[0]
            c.select(base)
            func compose() {
                guard composing, let s = c.model.selected?.focusedPane?.surface else { return }
                s.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            func done() { c.model.selected?.focusedPane?.surface.unmarkText() }
            var results: [(String, Bool)] = []
            func step(_ name: String, _ ch: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags, _ ok: () -> Bool) async {
                compose(); await press(ch, code, mods); done()
                results.append((name, ok()))
            }
            let n0 = c.model.workspaces.count
            await step("⌘N", "n", 45, [.command]) { c.model.workspaces.count == n0 + 1 }
            let ws = c.model.selected!
            await step("⌘D", "d", 2, [.command]) { ws.panes.count == 2 }
            await step("⇧⌘D", "D", 2, [.command, .shift]) { ws.panes.count == 3 }
            let f0 = ws.focusedPane
            await step("⌘[", "[", 33, [.command]) { ws.focusedPane !== f0 }
            let f1 = ws.focusedPane
            await step("⌘]", "]", 30, [.command]) { ws.focusedPane !== f1 }
            let f2 = ws.focusedPane
            await step("⌥⌘←", L, 123, [.command, .option, .numericPad, .function]) { ws.focusedPane !== f2 }
            let f3 = ws.focusedPane
            await step("⌥⌘→", R, 124, [.command, .option, .numericPad, .function]) { ws.focusedPane !== f3 }
            let r0 = ws.root.ratio
            await step("⌃⌘→ (resize)", R, 124, [.command, .control, .numericPad, .function]) { ws.root.ratio != r0 }
            await step("⌃⌘= (equalize)", "=", 24, [.command, .control]) { abs(ws.root.ratio - 0.5) < 0.02 || ws.root.ratio != r0 }
            await step("⌘1", "1", 18, [.command]) { c.model.selected === base }
            await step("⌘2", "2", 19, [.command]) { c.model.selected === ws }
            await step("⌃⌘[", "[", 33, [.command, .control]) { c.model.selected === base }
            await step("⌃⌘]", "]", 30, [.command, .control]) { c.model.selected === ws }
            let t0 = ws.focusedPane
            await step("⌘T", "t", 17, [.command]) { ws.focusedPane !== t0 && ws.root.find(t0!)?.tabs.count == 2 }
            await step("⇧⌘[", "{", 33, [.command, .shift]) { ws.focusedPane === t0 }
            await step("⇧⌘]", "}", 30, [.command, .shift]) { ws.focusedPane !== t0 }
            await step("⌘9", "9", 25, [.command]) { c.model.selected === c.model.workspaces.last }
            let sb = c.model.sidebarVisible
            await step("⌃⌘S", "s", 1, [.command, .control]) { c.model.sidebarVisible != sb }
            if c.model.sidebarVisible != sb { c.toggleSidebar() }
            c.select(ws)
            await step("⌘F", "f", 3, [.command]) { ws.focusedPane?.view.overlay.findBar != nil }
            ws.focusedPane?.view.overlay.findBar?.onClose?()
            let pc = ws.panes.count
            await step("⌘W", "w", 13, [.command]) { ws.panes.count == pc - 1 }
            let wc = c.model.workspaces.count
            await step("⇧⌘W", "W", 13, [.command, .shift]) { c.model.workspaces.count == wc - 1 }
            let bad = results.filter { !$0.1 }.map(\.0)
            r.check("Korean source, \(tag): every shortcut works (\(results.map(\.0).joined(separator: " ")))", bad.isEmpty,
                    "failed: \(bad.joined(separator: " "))")
        }
    }

    // ⌃/⌥ menu shortcuts are matched on the key's own character: ㄴ for S with Korean 2-Set (was: nothing happened).
    if want("imecmd") {
        r.section = "imecmd"
        for (ch, ign) in [("s", "s"), ("\u{13}", "s"), ("s", "ㄴ"), ("\u{13}", "ㄴ")] {
            let sb = c.model.sidebarVisible
            let ts = ProcessInfo.processInfo.systemUptime
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [.command, .control], timestamp: ts, windowNumber: w.windowNumber,
                                         context: nil, characters: ch, charactersIgnoringModifiers: ign, isARepeat: false, keyCode: 1)!
                dispatchKey(e, window: w)
            }
            await sleepMs(200)
            r.check("⌃⌘S toggles the sidebar (characters \(ch.debugDescription), ignoring modifiers \(ign))", c.model.sidebarVisible != sb)
            if c.model.sidebarVisible != sb { c.toggleSidebar() }
        }
    }

    // Every key equivalent in lmux's menus, as the Korean 2-Set source delivers it (⌘ keys carry the
    // Latin character, the key's own character is the jamo: ㅓ for J), reaches its own item. The
    // keyboard is off the panes here, so no Ghostty binding takes a key first; the items record
    // instead of acting.
    if want("imecmd") {
        r.section = "imecmd"
        final class Hits: NSObject { var items: [NSMenuItem] = []; @objc func hit(_ s: NSMenuItem) { items.append(s) } }
        let jamo: [Character: Character] = [
            "q": "ㅂ", "w": "ㅈ", "e": "ㄷ", "r": "ㄱ", "t": "ㅅ", "y": "ㅛ", "u": "ㅕ", "i": "ㅑ", "o": "ㅐ", "p": "ㅔ",
            "a": "ㅁ", "s": "ㄴ", "d": "ㅇ", "f": "ㄹ", "g": "ㅎ", "h": "ㅗ", "j": "ㅓ", "k": "ㅏ", "l": "ㅣ",
            "z": "ㅋ", "x": "ㅌ", "c": "ㅊ", "v": "ㅍ", "b": "ㅠ", "n": "ㅜ", "m": "ㅡ",
        ]
        let shiftJamo: [Character: Character] = ["q": "ㅃ", "w": "ㅉ", "e": "ㄸ", "r": "ㄲ", "t": "ㅆ", "o": "ㅒ", "p": "ㅖ"]
        let codes: [Character: UInt16] = KC.map.merging(["5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29, "=": 24, "-": 27, ",": 43, "\r": 36]) { a, _ in a }
        let arrows: [Int: UInt16] = [NSLeftArrowFunctionKey: 123, NSRightArrowFunctionKey: 124, NSDownArrowFunctionKey: 125, NSUpArrowFunctionKey: 126]
        var items: [NSMenuItem] = []
        // AppKit's own items (Start Dictation, Emoji & Symbols, fn-F full screen) use fn / Space: not lmux's.
        func walk(_ m: NSMenu) {
            for i in m.items {
                if let sub = i.submenu { walk(sub) } else if !i.keyEquivalent.isEmpty, i.keyEquivalent != " ", i.keyEquivalent.unicodeScalars.allSatisfy({ $0.value < 0x80 || (0xF700...0xF8FF).contains($0.value) }),
                                                            !i.keyEquivalentModifierMask.contains(.function) { items.append(i) }
            }
        }
        if let m = NSApp.mainMenu { walk(m) }
        let hits = Hits()
        let saved = items.map { ($0.target, $0.action) }
        for i in items { i.target = hits; i.action = #selector(Hits.hit(_:)) }
        let ws = c.model.selected!
        w.makeFirstResponder(nil)
        var bad: [String] = [], names: [String] = []
        for i in items {
            let mods = i.keyEquivalentModifierMask
            let name = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "")
                + (mods.contains(.command) ? "⌘" : "") + i.keyEquivalent.uppercased().replacingOccurrences(of: "\r", with: "↩")
            // ⌘+ (Ghostty's increase_font_size:1 trigger) is ⇧⌘= on the keyboard.
            let plus = i.keyEquivalent == "+"
            let key = plus ? "=" : Character(i.keyEquivalent.lowercased())
            let shift = mods.contains(.shift) || plus
            let fn = i.keyEquivalent.utf16.first.flatMap { arrows[Int($0)] }
            guard let code = fn ?? codes[key] else { bad.append("\(name) (no key code)"); continue }
            let shifted: [Character: String] = ["[": "{", "]": "}", "=": "+", "-": "_", ",": "<", "1": "!", "2": "@", "3": "#",
                                                "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")"]
            let typed = key.isLetter || !shift ? i.keyEquivalent : shifted[key] ?? i.keyEquivalent
            let ign = key.isLetter ? String(shift ? shiftJamo[key] ?? jamo[key]! : jamo[key]!) : typed
            let chars = !mods.contains(.command) && mods.contains(.control) && key.isLetter
                ? String(UnicodeScalar(key.asciiValue! & 0x1f)) : typed
            hits.items = []
            let ts = ProcessInfo.processInfo.systemUptime
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                let em = shift ? mods.union(.shift) : mods
                let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: fn != nil ? em.union([.numericPad, .function]) : em,
                                         timestamp: ts, windowNumber: w.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: ign, isARepeat: false, keyCode: code)!
                dispatchKey(e, window: w)
            }
            await sleepMs(30)
            names.append(name)
            if hits.items.count != 1 || hits.items.first !== i {
                // ⇧ + a non-letter ("]" for ⇧⌘]) never matches from the menu, with any source: the key
                // arrives as "}". In a pane Ghostty's binding takes it; elsewhere it's a known gap.
                if shift, !key.isLetter, typed != i.keyEquivalent {
                    print("NOTE  [imecmd] \(name) \(i.title): the menu can't match it (arrives as \(typed)); works in a pane (Ghostty binding)")
                    continue
                }
                bad.append("\(name) \(i.title) -> \(hits.items.map(\.title))")
            }
        }
        for (i, (t, a)) in zip(items, saved) { i.target = t; i.action = a }
        c.focus(ws.focusedPane!)
        r.check("Korean source: every menu key reaches its item (\(names.joined(separator: " ")))", bad.isEmpty, "failed: \(bad.joined(separator: ", "))")
    }

    // ------------------------------- Japanese / Chinese composition (cmux #265 #3679 #2060 #787)
    if want("cjkime") {
        r.section = "cjkime"
        let code = """
        import sys,os,tty
        d=sys.argv[1]
        fd=sys.stdin.fileno(); tty.setraw(fd)
        os.write(1,b'\\x1b[2J\\x1b[5;9Habc')
        open(d+'/cjk.ready','w').write('1')
        f=open(d+'/cjk.bin','wb',buffering=0)
        while True:
            b=os.read(fd,4096)
            if not b: break
            f.write(b)
        """
        let ws = c.newWorkspace(program: program("cjk", code))
        await shown(ws)
        let p = ws.panes[0], s = p.surface
        c.focus(p)
        _ = await waitFile("cjk.ready")
        await sleepMs(300)
        let none = NSRange(location: NSNotFound, length: 0)
        let cell = s.cellSize
        // Cursor at row 5, column 12 (1-based) after "abc" at column 9.
        let expectX = s.terminalPadding.width + 11 * cell.width
        var mark = 0
        func fresh() -> String { String(out("cjk.bin").unicodeScalars.dropFirst(mark)) }
        for (lang, steps, commit) in [("Japanese", ["に", "にほ", "にほん", "にほんご"], "日本語"),
                                      ("Chinese (pinyin)", ["z", "zh", "zho", "zhong"], "中")] {
            for st in steps { s.setMarkedText(st, selectedRange: NSRange(location: st.count, length: 0), replacementRange: none) }
            await sleepMs(100)
            let rect = w.convertFromScreen(s.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil))
            let local = s.convert(rect, from: nil)
            r.check("\(lang): the composition window sits at the cursor (column 12)", abs(local.minX - expectX) <= cell.width * 0.6,
                    String(format: "x=%.1f expected %.1f", local.minX, expectX))
            // Candidate selection: the IME replaces the marked text with the candidate, then commits it.
            s.setMarkedText(commit, selectedRange: NSRange(location: 0, length: commit.count), replacementRange: none)
            s.insertText(commit, replacementRange: none)
            await sleepMs(250)
            r.check("\(lang): the chosen candidate arrives once, no reading leaks", fresh() == commit, fresh().debugDescription)
            mark = out("cjk.bin").unicodeScalars.count
        }
        // Ctrl+H while composing belongs to the IME (it edits the reading): nothing reaches the program.
        let before = out("cjk.bin")
        s.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        let ts = ProcessInfo.processInfo.systemUptime
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [.control], timestamp: ts, windowNumber: w.windowNumber,
                                     context: nil, characters: "\u{8}", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4)!
            dispatchKey(e, window: w)
        }
        await sleepMs(250)
        let after = out("cjk.bin")
        r.check("Ctrl+H while composing sends no ^H / DEL to the program", !String(after.dropFirst(before.count)).contains("\u{8}")
                && !String(after.dropFirst(before.count)).contains("\u{7f}"), after.debugDescription)
        s.unmarkText()
        c.closeWorkspace(ws)
    }

    // ----------------------- alt screen + resize: cursor and screen (cmux #5763 #1156 #3203)
    if want("altresize") {
        r.section = "altresize"
        let code = """
        import sys,os,signal,time,fcntl,termios,struct,tty
        d=sys.argv[1]
        fd=sys.stdin.fileno(); tty.setraw(fd)
        w=lambda s: os.write(1,s.encode())
        def dsr():
            w('\\x1b[6n'); b=b''
            while not b.endswith(b'R'): b+=os.read(fd,1)
            r,c=b[2:-1].split(b';'); return int(r),int(c)
        def size():
            r,c,_,_=struct.unpack('HHHH',fcntl.ioctl(1,termios.TIOCGWINSZ,b'\\0'*8)); return r,c
        log=open(d+'/alt.log','a')
        w('\\x1b[2J\\x1b[HMAIN-MARK\\r\\n$ ')
        log.write('main %d %d\\n' % dsr()); log.flush()
        winch=[0]
        signal.signal(signal.SIGWINCH, lambda *a: winch.__setitem__(0, winch[0]+1))
        for cycle in range(3):
            w('\\x1b[?1049h\\x1b[2J')
            seen=winch[0]
            open(d+'/alt.go%d' % cycle,'w').write('1')
            while not os.path.exists(d+'/alt.resized%d' % cycle): time.sleep(0.05)
            time.sleep(0.3)
            r,c=size()
            # a Claude-like redraw: input box on the last rows, cursor in it
            w('\\x1b[H\\x1b[2Jtop\\x1b[%d;1H> input\\x1b[%d;9H' % (r, r))
            log.write('alt %d %d size %d %d\\n' % (dsr() + (r, c))); log.flush()
            w('\\x1b[?1049l')
            log.write('back %d %d\\n' % dsr()); log.flush()
        open(d+'/alt.done','w').write('1')
        time.sleep(1000)
        """
        let ws = c.newWorkspace(program: program("alt", code))
        await shown(ws)
        let p = ws.panes[0]
        for cycle in 0..<3 {
            _ = await waitFile("alt.go\(cycle)")
            for i in 0..<6 {
                w.setFrame(NSRect(x: -10000, y: -10000, width: 700 + CGFloat((i * 137 + cycle * 61) % 900), height: 400 + CGFloat((i * 89) % 500)), display: false)
                await sleepMs(30)
            }
            if cycle == 1 { c.toggleSidebar(); await sleepMs(50); c.toggleSidebar() }
            FileManager.default.createFile(atPath: fx.appendingPathComponent("alt.resized\(cycle)").path, contents: Data("1".utf8))
        }
        let done = await waitFile("alt.done", 15)
        let log = out("alt.log").split(separator: "\n").map(String.init)
        let main = log.first ?? ""
        r.check("the fixture ran 3 alt-screen + resize cycles", done && log.count == 7, log.joined(separator: " | "))
        let alts = log.filter { $0.hasPrefix("alt ") }.map { $0.split(separator: " ").compactMap { Int($0) } }
        r.check("in the alt screen after each resize the cursor is where the program put it (last row, column 9)",
                !alts.isEmpty && alts.allSatisfy { $0.count == 4 && $0[0] == $0[2] && $0[1] == 9 }, alts.description)
        let backs = log.filter { $0.hasPrefix("back ") }
        r.check("leaving the alt screen puts the cursor back where it was (row 2, column 3)", backs.count == 3 && backs.allSatisfy { $0 == "back 2 3" }
                && main == "main 2 3", backs.description + " " + main)
        w.setFrame(NSRect(x: -10000, y: -10000, width: 1280, height: 800), display: false)
        await sleepMs(300)
        r.check("the main screen isn't blank afterwards", p.surface.readText().contains("MAIN-MARK"), p.surface.readText().prefix(120).description)
        c.closeWorkspace(ws)
    }

    // ------------------------------------------------- corrupted state files
    if want("state") {
        r.section = "state"
        let fm = FileManager.default
        func badCopies(_ dir: URL, _ prefix: String) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(prefix + ".bad-") }
        }
        // layout.json: one good workspace, one whose split lost a child (hand edit, older bug).
        let dir = fx.appendingPathComponent("state-layout", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = UUID().uuidString, orphan = UUID().uuidString
        let layout = """
        {"version":1,"selected":"W1","workspaces":[
          {"id":"W1","accent":0,"root":{"pane":{"id":"\(good)"}}},
          {"id":"W2","accent":1,"root":{"axis":"horizontal","ratio":0.5,"children":[{"pane":{"id":"\(orphan)"}},{"axis":"vertical"}]}}]}
        """
        try? layout.write(to: dir.appendingPathComponent("layout.json"), atomically: true, encoding: .utf8)
        let c2 = LmuxController(runtime: c.runtime, paths: LmuxPaths(environment: env.merging(["LMUX_STATE_DIR": dir.path]) { $1 }), headless: true)
        c2.start(windowFrame: NSRect(x: 0, y: 0, width: 900, height: 600))
        r.check("a layout with a broken workspace restores the good one", c2.model.workspaces.map(\.id) == ["W1"],
                "\(c2.model.workspaces.map(\.id))")
        r.check("…the broken split starts no pane (no shell left running unseen)", c2.pane(id: orphan) == nil)
        r.check("…and the original layout is kept aside (layout.json.bad-*)",
                badCopies(dir, "layout.json").contains { (try? String(contentsOf: $0, encoding: .utf8)) == layout })
        c2.shutdown()
        c2.window.orderOut(nil)

        // settings.plist that isn't a plist: defaults, and the bytes are kept before a change overwrites them.
        let sdir = fx.appendingPathComponent("state-settings", isDirectory: true)
        try? fm.createDirectory(at: sdir, withIntermediateDirectories: true)
        let surl = sdir.appendingPathComponent("settings.plist")
        let junk = Data("<?xml version=\"1.0\"?><plist><dict><key>appearance</key><string>dark".utf8)
        try? junk.write(to: surl)
        let st = LmuxSettings(url: surl)
        r.check("an unreadable settings.plist reads as defaults", st.appearance == .system)
        st.warnBeforeQuit = false
        let kept = badCopies(sdir, "settings.plist")
        r.check("…and its bytes are kept aside (settings.plist.bad-*) before a change writes over it",
                kept.contains { (try? Data(contentsOf: $0)) == junk }, "\(kept.map(\.lastPathComponent))")
        r.check("…readable settings are never set aside", { () -> Bool in
            _ = LmuxSettings(url: surl); return badCopies(sdir, "settings.plist").count == kept.count }())
    }

    print("compat: \(r.passed) passed, \(r.failed) failed")
    return r.failed == 0 ? 0 : 1
}
