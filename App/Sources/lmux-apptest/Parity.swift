import AppKit
import GhosttyKit
import LmuxTerminal
@testable import LmuxUI

// `lmux-apptest --parity`: Ghostty parity for the scrollback scroller (libghostty's SCROLLBAR
// action -> a native overlay NSScroller) and link hover (MOUSE_OVER_LINK -> the URL bottom-left,
// pointing-hand cursor, ⌘-click opens). Headless; opening a link is captured, never handed to
// the system.

@MainActor
func runParity() async -> Int32 {
    let r = Report()
    var opened: [URL] = []
    GhosttyRuntime.openURL = { opened.append($0) }
    let c = makeController()
    let w = c.window!

    // ------------------------------------------------------------- scrollbar
    r.section = "scrollbar"
    r.check("Ghostty's `scrollbar` setting is on (system) by default", c.runtime.showsScrollbar)
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("fixtures", isDirectory: true)
    try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
    let p0 = c.model.selected!.panes[0]
    _ = await sinks.waitReady(p0.id)
    _ = await waitFor(3) { p0.surface.scrollbar != nil && p0.surface.cellSize.height > 0 }
    r.check("libghostty reports the scrollbar state", p0.surface.scrollbar != nil, "\(String(describing: p0.surface.scrollbar))")
    func hit(_ sc: SurfaceScroller, _ pt: NSPoint) -> NSView? { sc.hitTest(sc.convert(pt, to: sc.superview)) }
    let sc0 = p0.view.scroller
    r.check("no scrollback: the scroller takes no clicks (the last column stays the terminal's)",
            hit(sc0, NSPoint(x: sc0.bounds.maxX - 4, y: sc0.bounds.midY)) == nil && hit(sc0, NSPoint(x: sc0.bounds.midX, y: sc0.bounds.midY)) == nil)
    // A program that prints 300 lines: 300 rows of output, most of them scrolled off.
    let lines = (1...300).map { "scrollback line \($0)" }.joined(separator: "\n") + "\n"
    let wsS = c.newWorkspace(program: ScreenFixture.script(lines, input: nil, dir: fx, name: "scrollback"))
    let p = wsS.panes[0]
    let s = p.surface
    let sc = p.view.scroller
    p.view.layoutSubtreeIfNeeded()
    let center = NSPoint(x: sc.bounds.midX, y: sc.bounds.midY)
    let edge = NSPoint(x: sc.bounds.maxX - 4, y: sc.bounds.midY)
    func hit(_ pt: NSPoint) -> NSView? { hit(sc, pt) }
    _ = await waitFor(5) { (s.scrollbar?.total ?? 0) >= 300 }
    let sb0 = s.scrollbar
    r.check("output beyond the screen grows the scrollback, viewport at the bottom",
            sb0.map { $0.total > $0.len && $0.offset + $0.len == $0.total } ?? false, "\(String(describing: sb0))")
    let k0 = sc.knob
    r.check("the knob's size is screen / scrollback and it sits at the bottom",
            k0.map { abs($0.proportion - CGFloat(sb0!.len) / CGFloat(sb0!.total)) < 0.02 && $0.position > 0.99 } ?? false,
            "\(String(describing: k0))")
    r.check("the scroller is the native overlay style (fades out on its own)", sc.scroller?.scrollerStyle == .overlay)
    r.check("faded out, it takes no clicks: the right edge and the middle stay the terminal's",
            hit(edge) == nil && hit(center) == nil, "\(String(describing: hit(edge)))")
    let pv = p.view
    let midInPane = pv.convert(NSPoint(x: sc.frame.midX, y: sc.frame.midY), to: pv.superview)
    r.check("…so a click mid-pane still reaches the terminal", pv.hitTest(midInPane) === s,
            String(describing: pv.hitTest(midInPane)))

    // Scrolling the terminal moves the knob.
    _ = s.performBindingAction("scroll_page_up")
    _ = await waitFor(2) { (s.scrollbar?.offset ?? 0) < sb0!.offset }
    r.check("scrolling up (scroll_page_up) moves the knob up", (sc.knob?.position ?? 1) < 0.99 && (s.scrollbar?.offset ?? 0) < sb0!.offset,
            "\(String(describing: s.scrollbar)) \(String(describing: sc.knob))")
    r.check("scrolling shows it: the knob takes the click at the right edge (the middle stays the terminal's)",
            await waitFor(1) { hit(edge).map { $0 is NSScroller } ?? false } && hit(center) == nil,
            "\(String(describing: hit(edge)))")
    // The wheel over the scroller scrolls the terminal (never the scroller's empty document).
    let before = s.scrollbar!.offset
    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0),
       let wheel = NSEvent(cgEvent: cg), let target = hit(edge) ?? sc.scroller {
        target.scrollWheel(with: wheel)
    }
    _ = await waitFor(2) { s.scrollbar!.offset < before }
    r.check("the wheel over the scroller scrolls the terminal", s.scrollbar!.offset < before, "\(before) -> \(s.scrollbar!.offset)")
    // Dragging the knob scrolls the terminal (scroll_to_row).
    sc.liveScroll(toPosition: 0)
    _ = await waitFor(2) { s.scrollbar?.offset == 0 }
    r.check("dragging the knob to the top shows the first line", s.scrollbar?.offset == 0 && s.readText().contains("scrollback line 1\n"),
            "\(String(describing: s.scrollbar))")
    sc.liveScroll(toPosition: 1)
    _ = await waitFor(2) { s.scrollbar.map { $0.offset + $0.len == $0.total } ?? false }
    r.check("…and to the bottom, back to the live screen", s.scrollbar.map { $0.offset + $0.len == $0.total } ?? false,
            "\(String(describing: s.scrollbar))")
    r.check("…then it fades out on its own, like macOS (the edge is the terminal's again)",
            await waitFor(5) { hit(edge) == nil })
    // Resize: the knob follows the new screen size (no drift between grid and knob).
    let sb1 = s.scrollbar!
    c.split(p, .down)
    _ = await waitFor(3) { (s.scrollbar?.len ?? sb1.len) != sb1.len }
    r.check("a split (fewer rows) updates the knob", s.scrollbar.map { sb in
        sc.knob.map { abs($0.proportion - CGFloat(sb.len) / CGFloat(sb.total)) < 0.02 } ?? false } ?? false,
        "\(String(describing: s.scrollbar)) \(String(describing: sc.knob))")

    // ------------------------------------------------------------- link hover
    r.section = "link hover"
    let url = "https://example.com/lmux?q=1"
    let wsL = c.newWorkspace(program: ScreenFixture.script("see \(url) for details\n", input: nil, dir: fx, name: "link"))
    let q = wsL.panes[0]
    _ = await waitFor(5) { q.surface.readText().contains(url) && q.surface.cellSize.width > 0 }
    let qs = q.surface
    q.view.layoutSubtreeIfNeeded()
    // The URL's cells on row 0: x past "see ", y the row's middle (surface coordinates, unflipped).
    let cell = qs.cellSize
    let padX: CGFloat = 14, padY: CGFloat = 10
    let onURL = NSPoint(x: padX + cell.width * 10.5, y: qs.bounds.height - padY - cell.height / 2)
    let offText = NSPoint(x: qs.bounds.midX, y: qs.bounds.midY)
    func move(_ pt: NSPoint, _ mods: NSEvent.ModifierFlags) async {
        let e = NSEvent.mouseEvent(with: .mouseMoved, location: qs.convert(pt, to: nil), modifierFlags: mods,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        qs.mouseMoved(with: e)
        await sleepMs(150)
    }
    await move(onURL, [])
    r.check("without ⌘ a URL is plain text (Ghostty's default: links on ⌘-hover)", qs.hoverURL == nil && q.view.overlay.link.isHidden)
    // ⌘ held, the pointer moves on along the URL (libghostty rechecks links when it changes cell).
    await move(NSPoint(x: onURL.x + cell.width * 3, y: onURL.y), .command)
    _ = await waitFor(2) { qs.hoverURL != nil }
    r.check("⌘-hover over a URL reports it (MOUSE_OVER_LINK)", qs.hoverURL == url, qs.hoverURL ?? "nil")
    let banner = q.view.overlay.link
    let ob = q.view.overlay.bounds
    r.check("…shows it in a small banner at the pane's bottom-left",
            !banner.isHidden && banner.text == url && banner.frame.minX == 0 && abs(banner.frame.maxY - ob.maxY) < 0.5
                && banner.frame.width < ob.width && banner.frame.height <= 24,
            "\(banner.frame) in \(ob) \(banner.text)")
    _ = await waitFor(2) { qs.pointerCursor == .pointingHand }
    r.check("…and the pointer becomes the pointing hand", qs.pointerCursor == .pointingHand)
    r.check("the banner never takes a click", banner.hitTest(NSPoint(x: 5, y: 5)) == nil)

    // ⌘-click opens it (captured: never opened for real).
    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: t, location: qs.convert(onURL, to: nil), modifierFlags: .command,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)!
        w.sendEvent(e)
        await sleepMs(40)
    }
    _ = await waitFor(2) { !opened.isEmpty }
    r.check("⌘-click opens the URL", opened == [URL(string: url)!], "\(opened)")

    await move(offText, .command)
    _ = await waitFor(2) { qs.hoverURL == nil }
    r.check("moving off the link hides the banner and restores the pointer",
            qs.hoverURL == nil && banner.isHidden && qs.pointerCursor != .pointingHand)
    // Over the banner's corner, it moves to the bottom-right (like Ghostty), out of the way.
    q.view.overlay.showLink(url, pointer: NSPoint(x: 10, y: 6))
    r.check("with the pointer over it, the banner moves to the bottom-right",
            banner.onRight && abs(banner.frame.maxX - ob.maxX) < 0.5, "\(banner.frame)")
    q.view.overlay.showLink(nil, pointer: nil)
    r.check("a link can't hide its target: invisible / bidi characters are shown escaped",
            LinkBanner.displayString("https://a.example/\u{202E}gpj.exe\u{200B}") == "https://a.example/\\u{202E}gpj.exe\\u{200B}")

    // ------------------------------------------------------------- untrusted links
    // OSC 8 targets and ⌘-clicked text come from terminal output (Ghostty's UntrustedURL policy).
    r.section = "link-policy"
    var prompts: [UntrustedURLPrompt] = []
    var answer = false
    UntrustedURLAlert.testHook = { prompts.append($0); return answer }
    func decide(_ s: String) -> UntrustedURL.Decision { UntrustedURL(s).decision }
    let lf = fx.appendingPathComponent("links", isDirectory: true)
    try? FileManager.default.createDirectory(at: lf, withIntermediateDirectories: true)
    let notes = lf.appendingPathComponent("notes.txt"); try? "hi".write(to: notes, atomically: true, encoding: .utf8)
    let script = lf.appendingPathComponent("run.sh"); try? "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
    let command = lf.appendingPathComponent("go.command"); try? "ls\n".write(to: command, atomically: true, encoding: .utf8)
    let bare = lf.appendingPathComponent("tool"); try? Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: bare); chmod(bare.path, 0o755)
    let bundle = lf.appendingPathComponent("Evil.app", isDirectory: true)
    try? FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let canon = { (u: URL) in u.standardizedFileURL.resolvingSymlinksInPath() }
    r.check("http(s) with a host opens directly", decide("https://example.com/a?b") == .allow(URL(string: "https://example.com/a?b")!))
    r.check("…without a host is blocked", decide("https:relative") == .deny(.invalidWebURL))
    r.check("mailto with an address opens directly, a bare mailto: is blocked",
            decide("mailto:a@example.com") == .allow(URL(string: "mailto:a@example.com")!) && decide("mailto:") == .deny(.malformedURL))
    r.check("an existing plain file or folder opens directly",
            decide(notes.absoluteString) == .allow(canon(notes)) && decide(lf.absoluteString) == .allow(canon(lf)))
    r.check("executable targets are blocked: .app, .command, .sh, an executable without extension",
            [bundle, command, script, bare].allSatisfy { decide($0.absoluteString) == .deny(.unsafeFile) },
            [bundle, command, script, bare].map { "\(decide($0.absoluteString))" }.joined(separator: " "))
    r.check("a missing file is blocked", decide(lf.appendingPathComponent("nope.txt").absoluteString) == .deny(.inaccessibleFile))
    r.check("control / bidi / zero-width characters are blocked",
            ["https://a.example/\u{202E}gpj.exe", "https://a.example/x\u{200B}", "https://a.example/\nx"]
                .allSatisfy { decide($0) == .deny(.unsafeCharacters) })
    r.check("…and soft hyphen / Hangul filler (also invisible padding) are too",
            ["https://a.example/x\u{00AD}", "https://a.example/x\u{3164}"]
                .allSatisfy { decide($0) == .deny(.unsafeCharacters) })
    r.check("…while an ordinary URL with none of those is unaffected",
            decide("https://a.example/x-y_z.html?q=1") == .allow(URL(string: "https://a.example/x-y_z.html?q=1")!))
    r.check("other schemes ask first", decide("lmux-test-scheme://open?x=1") == .confirm(URL(string: "lmux-test-scheme://open?x=1")!))
    r.check("no scheme is never opened as is", decide("notes.txt") == .deny(.malformedURL))

    // Through OPEN_URL, as libghostty sends them.
    opened.removeAll()
    GhosttyRuntime.openTerminalURL("https://example.com/osc8", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, window: w)
    r.check("OSC 8 https link: opened, no prompt", opened == [URL(string: "https://example.com/osc8")!] && prompts.isEmpty, "\(opened)")
    opened.removeAll()
    GhosttyRuntime.openTerminalURL(script.absoluteString, kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, window: w)
    r.check("OSC 8 link to a script: blocked with its reason, nothing opened",
            opened.isEmpty && prompts.last == .block(reason: .unsafeFile, display: canon(script).path), "\(prompts)")
    let pb = GhosttyRuntime.standardPasteboard
    answer = true
    GhosttyRuntime.openTerminalURL(script.absoluteString, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: w)
    r.check("…“Copy Link” copies the shown target (private pasteboard), still nothing opened",
            opened.isEmpty && pb.string(forType: .string) == canon(script).path, pb.string(forType: .string) ?? "nil")
    answer = false
    prompts.removeAll()
    GhosttyRuntime.openTerminalURL("lmux-test-scheme://open", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, window: w)
    var handlerShown = false
    if case .confirm(_, let display, let handler)? = prompts.last { handlerShown = display == "lmux-test-scheme://open" && !handler.isEmpty }
    r.check("custom scheme: asks first, naming the app that would open it; Cancel opens nothing",
            opened.isEmpty && handlerShown, "\(prompts)")
    answer = true
    GhosttyRuntime.openTerminalURL("lmux-test-scheme://open", kind: GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, window: w)
    r.check("…“Open Link” opens it", opened == [URL(string: "lmux-test-scheme://open")!], "\(opened)")
    answer = false
    opened.removeAll(); prompts.removeAll()
    GhosttyRuntime.openTerminalURL(notes.path, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: w)
    r.check("⌘-clicked plain path to a text file: opened directly", opened == [canon(notes)] && prompts.isEmpty, "\(opened) \(prompts)")
    opened.removeAll()
    GhosttyRuntime.openTerminalURL(command.path, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: w)
    r.check("⌘-clicked path to a .command: blocked", opened.isEmpty && prompts.last == .block(reason: .unsafeFile, display: canon(command).path))
    opened.removeAll(); prompts.removeAll()
    let cfgFile = lf.appendingPathComponent("config.ghostty")
    GhosttyRuntime.openTerminalURL(cfgFile.path, kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, window: w)
    r.check("config files (text kind) open as before, without the policy", opened == [URL(filePath: NSString(string: cfgFile.path).standardizingPath)] && prompts.isEmpty, "\(opened)")
    UntrustedURLAlert.testHook = nil
    return finish(r, c)
}
