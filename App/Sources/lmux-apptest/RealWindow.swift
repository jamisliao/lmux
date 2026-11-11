import AppKit
import GhosttyKit
import LmuxTerminal
import LmuxTokens
@testable import LmuxUI

// `lmux-apptest --real-window` (App/scripts/realwindow.sh): the real lmux window, VISIBLE and
// focused, driven by real CGEvents posted to the HID event tap (window server -> AppKit, like a
// person with a mouse), on a GitHub-hosted runner only. It refuses to run anywhere else: it
// moves the pointer, takes focus and shows a window.
//
// Every interaction is followed by the same proof that the basics still work: click a pane,
// type a marker, and find it in that pane's pty (the sink file).

@MainActor
final class RW {
    let r: Report
    let c: LmuxController
    var w: NSWindow { c.window }
    let shots: URL?
    var steps: [String] = []

    init(r: Report, c: LmuxController, shots: URL?) {
        self.r = r
        self.c = c
        self.shots = shots
    }

    // MARK: Coordinates

    /// Global CG coordinates (top-left origin of the main display) of a point in window coordinates.
    func cg(_ windowPoint: NSPoint, in window: NSWindow? = nil) -> CGPoint {
        let win = window ?? w
        let screenPt = win.convertPoint(toScreen: windowPoint)
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: screenPt.x, y: h - screenPt.y)
    }

    func cg(_ view: NSView, _ p: NSPoint) -> CGPoint { cg(view.convert(p, to: nil), in: view.window) }
    func center(_ view: NSView) -> CGPoint { cg(view, NSPoint(x: view.bounds.midX, y: view.bounds.midY)) }

    // MARK: Events

    let src = CGEventSource(stateID: .hidSystemState)

    func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

    func move(_ p: CGPoint) async {
        post(CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        await sleepMs(40)
    }

    func click(_ p: CGPoint, count: Int = 1, flags: CGEventFlags = [], settle: Int = 250) async {
        await move(p)
        for n in 1...count {
            for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.flags = flags
                post(e)
                await sleepMs(25)
            }
        }
        await sleepMs(settle)
    }

    func drag(from a: CGPoint, to b: CGPoint, steps n: Int = 12, settle: Int = 400) async {
        await move(a)
        post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
        await sleepMs(120)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
            await sleepMs(25)
        }
        await sleepMs(80)
        post(CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
        await sleepMs(settle)
    }

    func scroll(at p: CGPoint, lines: Int32) async {
        await move(p)
        post(CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        await sleepMs(150)
    }

    func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], settle: Int = 30) async {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            post(e)
            await sleepMs(12)
        }
        await sleepMs(settle)
    }

    func type(_ s: String) async {
        for ch in s { await key(CGKeyCode(KC.map[ch]!)) }
        await sleepMs(120)
    }

    func cmd(_ ch: Character, _ extra: CGEventFlags = [], settle: Int = 500) async {
        await key(CGKeyCode(KC.map[ch]!), CGEventFlags.maskCommand.union(extra), settle: settle)
    }

    // MARK: Proofs

    var markerN = 0
    func marker() -> String {
        markerN += 1
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var n = markerN, s = "qz"
        repeat { s.append(letters[n % 26]); n /= 26 } while n > 0
        return s + "x"
    }

    var panes: [Pane] { c.model.selected?.panes ?? [] }

    /// Click inside `pane`'s terminal (away from overlays), type a marker, find it in its pty.
    @discardableResult
    func clickAndType(_ pane: Pane, _ label: String, at frac: NSPoint = NSPoint(x: 0.3, y: 0.55)) async -> Bool {
        let s = pane.surface
        guard s.window === w else {
            r.check("\(label): pane is in the window", false, steps.suffix(8).joined(separator: " > "))
            return false
        }
        let p = cg(s, NSPoint(x: s.bounds.width * frac.x, y: s.bounds.height * frac.y))
        await click(p)
        let m = marker()
        await type(m)
        let ok = await sinks.wait(pane.id, contains: m, timeout: 3)
        let fr = firstResponderPane(c)
        r.check("\(label): click a pane + type reaches its pty", ok,
                "marker \(m) missing; key=\(w.isKeyWindow) active=\(NSApp.isActive) fr=\(fr?.id.prefix(6) ?? "nil") "
                    + "pane=\(pane.id.prefix(6)) steps: \(steps.suffix(8).joined(separator: " > "))")
        return ok
    }

    func shot(_ name: String) async {
        guard let shots else { return }
        await sleepMs(300)
        let full = shots.appendingPathComponent("\(name)-screen.png").path
        _ = await runProcess("/usr/sbin/screencapture", ["-x", full])
        let f = w.frame, h = NSScreen.screens.first?.frame.height ?? 0
        let rect = "\(Int(f.minX) - 20),\(Int(h - f.maxY) - 20),\(Int(f.width) + 40),\(Int(f.height) + 40)"
        _ = await runProcess("/usr/sbin/screencapture", ["-x", "-R", rect, shots.appendingPathComponent("\(name)-window.png").path])
    }

    func waitUntil(_ t: Double = 3, _ cond: () -> Bool) async -> Bool { await waitFor(t, cond) }
}

/// The traffic light buttons, in global CG coordinates.
@MainActor
func trafficLight(_ rw: RW, _ b: NSWindow.ButtonType) -> CGPoint? {
    guard let v = rw.w.standardWindowButton(b) else { return nil }
    return rw.center(v)
}

@MainActor
func runRealWindow() async -> Int32 {
    guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
        print("lmux-apptest --real-window shows a window, moves the pointer and takes focus: it only runs on a")
        print("GitHub Actions runner (GITHUB_ACTIONS=true). Use App/scripts/apptest.sh locally (headless).")
        return 2
    }
    let r = Report()
    let shotsDir = ProcessInfo.processInfo.environment["LMUX_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
    if let d = shotsDir { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

    NSApp.setActivationPolicy(.regular)
    guard let runtime = GhosttyRuntime(fontProfile: .korean) else { print("runtime init failed"); return 2 }
    let c = LmuxController(runtime: runtime, paths: paths, headless: false)
    c.buildMainMenu()
    c.history.helper = Bundle.main.executableURL
    // Hosted runners have a 1024x768 screen: every point the test grabs must be on it.
    c.start(windowFrame: NSRect(x: 0, y: 0, width: 820, height: 540))
    let w = c.window!
    let home = NSRect(x: 100, y: 130, width: 820, height: 540)
    w.setFrame(home, display: true)
    NSApp.activate(ignoringOtherApps: true)
    w.makeKeyAndOrderFront(nil)
    let rw = RW(r: r, c: c, shots: shotsDir)

    // ------------------------------------------------------------------ setup
    r.section = "setup"
    let p1 = c.model.selected!.panes[0]
    r.check("pane ready", await sinks.waitReady(p1.id, timeout: 10))
    r.check("app active, window key", await rw.waitUntil(5) { NSApp.isActive && w.isKeyWindow },
            "active=\(NSApp.isActive) key=\(w.isKeyWindow)")
    r.check("Accessibility trust for posting events (informational: \(AXIsProcessTrusted()))", true)
    // Probe: does a posted CGEvent reach us at all?
    await rw.clickAndType(p1, "probe")
    await rw.shot("01-initial")

    // ---------------------------------------------------------------- chrome
    r.section = "titlebar chrome"
    let root = c.root!
    if let lights = root.trafficLightsFrame {
        let cl = root.cluster.convert(root.cluster.bounds, to: nil)
        r.check("titlebar buttons are inline with the traffic lights (same center y ±2pt)",
                abs(cl.midY - lights.midY) <= 2, "cluster \(cl) lights \(lights)")
        r.check("titlebar buttons sit right of the traffic lights", cl.minX >= lights.maxX + 4, "cluster \(cl) lights \(lights)")
        let sidebarTop = root.sidebarHost.convert(root.sidebarHost.bounds, to: nil).maxY
        r.check("the sidebar list starts below the buttons", sidebarTop <= cl.minY + 0.5, "sidebar top \(sidebarTop) cluster \(cl)")
        r.check("titlebar height matches the live window (\(root.titlebarHeight))",
                abs(root.titlebarHeight - (w.frame.height - w.contentLayoutRect.height)) < 0.5)
    } else {
        r.check("traffic lights exist", false)
    }

    // Each titlebar button, clicked for real, does its job.
    let bs = LmuxTokens.Layout.titlebarButtonSize
    func buttonPoint(_ i: Int) -> CGPoint {
        rw.cg(root.cluster, NSPoint(x: bs / 2 + CGFloat(i) * (bs + 2),
                                     y: root.cluster.bounds.midY))
    }
    let nWS = c.model.workspaces.count
    rw.steps.append("click +")
    await rw.click(buttonPoint(2), settle: 600)
    r.check("+ (clicked) adds a workspace", c.model.workspaces.count == nWS + 1, "\(c.model.workspaces.count)")
    if let p = c.model.selected?.panes.first { _ = await sinks.waitReady(p.id, timeout: 5); await rw.clickAndType(p, "after +") }
    rw.steps.append("click sidebar toggle")
    let togglePoint = buttonPoint(0)
    let wsCount = c.model.workspaces.count
    await rw.click(togglePoint, settle: 600)
    r.check("sidebar toggle (clicked) hides the sidebar", !c.model.sidebarVisible)
    r.check("…and the titlebar buttons stay where they were", abs(buttonPoint(0).x - togglePoint.x) < 0.5)
    await rw.shot("02-sidebar-hidden")
    rw.steps.append("click sidebar toggle again, same spot")
    await rw.click(togglePoint, settle: 600)
    r.check("a second click at the same spot shows it again (no workspace added)",
            c.model.sidebarVisible && c.model.workspaces.count == wsCount)
    // Bell: an unread alert in workspace 1, then ⌥-click the bell from workspace 2 (a plain click opens the list, below).
    p1.unread = 1
    p1.lastAlertAt = Date()
    rw.steps.append("⌥-click bell")
    await rw.click(buttonPoint(1), flags: .maskAlternate, settle: 600)
    r.check("bell (⌥-clicked) jumps to the unread pane", c.model.selected?.focusedPane === p1)
    await rw.clickAndType(p1, "after bell")

    // ------------------------------------------------------------- dragging
    r.section = "window drag"
    func dragCheck(_ label: String, from: CGPoint, by d: CGVector, expectMove: Bool) async {
        let before = w.frame.origin
        rw.steps.append("drag \(label)")
        await rw.drag(from: from, to: CGPoint(x: from.x + d.dx, y: from.y + d.dy))
        let after = w.frame.origin
        let moved = CGVector(dx: after.x - before.x, dy: -(after.y - before.y))
        if expectMove {
            r.check("drag by \(label) moves the window by the drag delta",
                    abs(moved.dx - d.dx) <= 2 && abs(moved.dy - d.dy) <= 2, "moved \(moved) want \(d)")
        } else {
            r.check("drag in \(label) does not move the window", moved.dx == 0 && moved.dy == 0, "moved \(moved)")
        }
    }
    let tb = root.titlebarHeight
    let header = root.header
    await dragCheck("empty content titlebar", from: rw.cg(header, NSPoint(x: header.bounds.width - 80, y: tb / 2)),
                    by: CGVector(dx: 50, dy: 30), expectMove: true)
    if let lights = root.trafficLightsFrame {
        let cl = root.cluster.convert(root.cluster.bounds, to: nil)
        let x = (lights.maxX + cl.minX) / 2
        await dragCheck("sidebar titlebar (between lights and buttons)", from: rw.cg(NSPoint(x: x, y: lights.midY)),
                        by: CGVector(dx: -40, dy: 20), expectMove: true)
    }
    await dragCheck("the content header's title", from: rw.cg(header.title, NSPoint(x: 10, y: header.title.bounds.midY)),
                    by: CGVector(dx: -20, dy: -30), expectMove: true)
    let s1 = p1.surface
    await rw.click(rw.center(s1))
    await dragCheck("the terminal", from: rw.cg(s1, NSPoint(x: 40, y: s1.bounds.height - 30)),
                    by: CGVector(dx: 260, dy: 60), expectMove: false)
    r.check("dragging in the terminal selects text", s1.hasSelection)
    await rw.clickAndType(p1, "after drags")
    await rw.shot("03-after-drags")

    // ------------------------------------------------------- double-click zoom
    r.section = "titlebar double-click"
    let action = TitlebarDragView.titlebarDoubleClickAction(.standard)
    let zoomed0 = w.isZoomed
    rw.steps.append("double-click titlebar")
    await rw.click(rw.cg(header, NSPoint(x: header.bounds.width - 60, y: tb / 2)), count: 2, settle: 900)
    if action == "Maximize" || action == "Fill" {
        r.check("double-click on the empty titlebar zooms (system setting: \(action))", w.isZoomed != zoomed0)
        await rw.click(rw.cg(header, NSPoint(x: header.bounds.width - 60, y: tb / 2)), count: 2, settle: 900)
        r.check("double-click again unzooms", w.isZoomed == zoomed0)
    } else {
        r.check("double-click follows the system setting (\(action))", true)
        if w.isMiniaturized { w.deminiaturize(nil); await sleepMs(800) }
    }
    await rw.clickAndType(p1, "after double-click")

    // ---------------------------------------------------------- traffic lights
    r.section = "traffic lights"
    if let m = trafficLight(rw, .miniaturizeButton) {
        rw.steps.append("click minimize")
        await rw.click(m, settle: 1200)
        r.check("yellow button minimizes", await rw.waitUntil(3) { w.isMiniaturized })
        c.reopenWindow()  // what a Dock icon click does (applicationShouldHandleReopen)
        r.check("reopen (Dock click) restores it", await rw.waitUntil(3) { !w.isMiniaturized && w.isVisible })
        await sleepMs(500)
        await rw.clickAndType(p1, "after minimize/restore")
    }
    if let z = trafficLight(rw, .zoomButton) {
        let f0 = w.frame
        rw.steps.append("option-click zoom")
        await rw.click(z, flags: .maskAlternate, settle: 1000)
        r.check("⌥-click green zooms", w.frame != f0, "\(w.frame)")
        if let z2 = trafficLight(rw, .zoomButton) { await rw.click(z2, flags: .maskAlternate, settle: 1000) }
        r.check("⌥-click green again unzooms", w.frame == f0, "\(w.frame) vs \(f0)")
        await rw.clickAndType(p1, "after zoom/unzoom")
        rw.steps.append("click green (full screen)")
        await rw.click(z, settle: 2500)
        r.check("green button enters full screen", await rw.waitUntil(4) { w.styleMask.contains(.fullScreen) })
        // The cluster and the traffic lights share the full-screen titlebar window's coordinates.
        func clusterRect() -> NSRect { root.cluster.convert(root.cluster.bounds, to: nil) }
        await rw.move(rw.center(p1.surface))
        r.check("full screen: the titlebar buttons sit at the left edge while the traffic lights are hidden",
                await rw.waitUntil(4) { !root.trafficLightsVisible && abs(clusterRect().minX - LmuxTokens.Layout.rowInsetX) < 1 },
                "cluster \(clusterRect()) lightsVisible=\(root.trafficLightsVisible)")
        await rw.shot("04-fullscreen")
        rw.steps.append("pointer to the top edge (reveal the titlebar)")
        let top = CGPoint(x: rw.center(p1.surface).x, y: 0)
        await rw.move(top)
        await rw.move(CGPoint(x: top.x + 1, y: 0))
        let revealed = await rw.waitUntil(4) { root.trafficLightsVisible }
        let clear = await rw.waitUntil(2) { root.trafficLightsFrame.map { clusterRect().minX >= $0.maxX + 4 } ?? false }
        r.check("…revealed (pointer at the top edge): right of the traffic lights, no overlap (revealed: \(revealed))",
                !revealed || clear, "cluster \(clusterRect()) lights \(root.trafficLightsFrame.map { "\($0)" } ?? "nil")")
        await rw.shot("04b-fullscreen-revealed")
        await rw.move(rw.center(p1.surface))
        await rw.clickAndType(p1, "in full screen")
        rw.steps.append("⌃⌘F exit full screen")
        await rw.key(3, [.maskCommand, .maskControl], settle: 2500)  // F
        if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        r.check("full screen exits", await rw.waitUntil(4) { !w.styleMask.contains(.fullScreen) })
        await sleepMs(800)
        await rw.clickAndType(p1, "after full screen")
        rw.steps.append("close in full screen")
        w.toggleFullScreen(nil)
        if await rw.waitUntil(4, { w.styleMask.contains(.fullScreen) }) {
            await sleepMs(800)
            w.performClose(nil)
            r.check("closing in full screen leaves full screen, then hides the window (no empty black Space)",
                    await rw.waitUntil(6) { !w.styleMask.contains(.fullScreen) && !w.isVisible },
                    "fullScreen=\(w.styleMask.contains(.fullScreen)) visible=\(w.isVisible)")
            c.reopenWindow()
            r.check("…reopen brings it back, windowed", await rw.waitUntil(3) { w.isVisible && !w.styleMask.contains(.fullScreen) })
            // Back from the full-screen Space: keys typed while the Space switch still runs are lost
            // (seen on a runner, where it takes longer): on the active Space, then the settle time.
            _ = await rw.waitUntil(5) { w.isOnActiveSpace }
            await sleepMs(Int(500 * ciSlow))
            await rw.clickAndType(p1, "after close in full screen")
        } else {
            r.check("full screen re-enters (for close in full screen)", false)
        }
    }
    if let x = trafficLight(rw, .closeButton) {
        let ids = c.model.workspaces.flatMap(\.panes).map(\.id)
        rw.steps.append("click close")
        await rw.click(x, settle: 800)
        r.check("red button closes the window", await rw.waitUntil(3) { !w.isVisible }, "visible=\(w.isVisible) frame=\(w.frame)")
        r.check("…and every pane keeps running", c.model.workspaces.flatMap(\.panes).map(\.id) == ids)
        let n = c.model.workspaces.count
        rw.steps.append("⌘N with no window")
        await rw.cmd("n", settle: 1200)
        r.check("⌘N brings the window back", await rw.waitUntil(3) { w.isVisible && w.isKeyWindow })
        r.check("…with a new workspace", c.model.workspaces.count == n + 1)
        if let p = c.model.selected?.panes.first { _ = await sinks.waitReady(p.id, timeout: 5); await rw.clickAndType(p, "after close/⌘N") }
        await rw.click(x, settle: 800)
        c.reopenWindow()
        r.check("Dock reopen after close shows the window", await rw.waitUntil(3) { w.isVisible })
        await rw.clickAndType(c.model.selected!.panes[0], "after close/Dock reopen")
    }

    // ------------------------------------------------------ splits and resize
    r.section = "splits"
    w.setFrame(home, display: true)
    c.select(c.model.workspaces.first { $0.panes.contains { $0 === p1 } }!)
    await rw.click(rw.center(p1.surface))
    rw.steps.append("⌘D")
    await rw.cmd("d", settle: 800)
    let ws = c.model.selected!
    r.check("⌘D splits", ws.panes.count == 2)
    let p2 = ws.panes[1]
    _ = await sinks.waitReady(p2.id, timeout: 5)
    await sleepMs(300)
    r.check("the new pane of a split has no selection (no stray grey block)", !p2.surface.hasSelection)
    await rw.shot("05a-after-split")
    if let split = p1.view.superview as? SplitContainerView {
        let d = split.divider
        let w0 = p1.view.frame.width
        rw.steps.append("drag divider")
        await rw.drag(from: rw.center(d), to: { var p = rw.center(d); p.x += 120; return p }())
        r.check("dragging the divider resizes the panes", abs(p1.view.frame.width - (w0 + 120)) <= 4, "\(w0) -> \(p1.view.frame.width)")
        // Grab it 2pt off its 1pt line (the grab area), then drag back.
        let near = rw.cg(d, NSPoint(x: d.bounds.midX + 2.5, y: d.bounds.midY))
        let w1 = p1.view.frame.width
        await rw.drag(from: near, to: CGPoint(x: near.x - 60, y: near.y))
        r.check("the divider's grab area (±3pt) works", abs(p1.view.frame.width - (w1 - 60)) <= 5, "\(w1) -> \(p1.view.frame.width)")
    } else {
        r.check("split view exists", false)
    }
    await rw.clickAndType(p2, "right pane after divider drag")
    await rw.clickAndType(p1, "left pane after divider drag")

    r.section = "sidebar resize"
    let sw0 = c.model.sidebarWidth
    let handle = root.resizeHandle
    rw.steps.append("drag sidebar edge")
    await rw.drag(from: rw.center(handle), to: { var p = rw.center(handle); p.x += 60; return p }())
    r.check("dragging the sidebar edge resizes it", abs(c.model.sidebarWidth - min(sw0 + 60, LmuxTokens.Layout.sidebarWidthMax)) <= 3,
            "\(sw0) -> \(c.model.sidebarWidth)")
    await dragCheck("empty content titlebar after sidebar resize",
                    from: rw.cg(header, NSPoint(x: header.bounds.width - 80, y: tb / 2)), by: CGVector(dx: 30, dy: 25), expectMove: true)
    await rw.clickAndType(p1, "after sidebar resize")

    r.section = "window resize"
    w.setFrame(home, display: true)
    await sleepMs(300)
    let f0 = w.frame
    let corner = CGPoint(x: f0.maxX - 2, y: (NSScreen.screens.first?.frame.height ?? 0) - f0.minY - 2)
    rw.steps.append("drag window corner")
    await rw.drag(from: corner, to: CGPoint(x: corner.x + 60, y: corner.y + 40), settle: 800)
    r.check("dragging the bottom-right corner resizes the window",
            abs(w.frame.width - (f0.width + 60)) <= 3 && abs(w.frame.height - (f0.height + 40)) <= 3, "\(f0) -> \(w.frame)")
    for (i, p) in ws.panes.enumerated() {
        await rw.clickAndType(p, "pane \(i) near its right edge after resize", at: NSPoint(x: 0.96, y: 0.9))
        await rw.clickAndType(p, "pane \(i) near its bottom-left after resize", at: NSPoint(x: 0.04, y: 0.06))
    }
    await rw.shot("05-split-resized")

    // ----------------------------------------------------------- overlays
    r.section = "overlays leave no dead areas"
    for (name, show, hide) in [
        ("guard card", { c.showCard(p1, message: NSAttributedString(string: "test"), detail: "d", confirmTitle: "OK", onConfirm: {}) },
         { if let card = p1.view.overlay.card { card.cancel.performClick() } }),
        ("toast", { c.showNote(p1, "note", duration: nil) }, { c.hideToast(p1) }),
        ("find bar", { c.searchStarted(p1, needle: nil) }, { c.searchEnded(p1) }),
    ] as [(String, () -> Void, () -> Void)] {
        show()
        p1.view.overlay.layoutSubtreeIfNeeded()
        let ov = p1.view.overlay
        let v = ov.card ?? ov.toast ?? ov.findBar
        let rect = v.map { $0.convert($0.bounds, to: p1.surface) }
        r.check("\(name) shows", v != nil)
        hide()
        await sleepMs(200)
        r.check("\(name) is removed from the view tree when dismissed",
                v?.superview == nil && ov.card == nil && ov.toast == nil && ov.findBar == nil)
        if let rect {
            let f = NSPoint(x: rect.midX / p1.surface.bounds.width, y: rect.midY / p1.surface.bounds.height)
            await rw.clickAndType(p1, "click where the \(name) was", at: f)
        }
    }

    // ------------------------------------------------------------- idle cost
    // Real-Mac report: after Claude exited without SessionEnd and a big flood, idle CPU stuck at
    // 5-6% with ~65-156 CVDisplayLink threads for 2 surfaces.
    r.section = "idle after flood + claude exit"
    let flood = paths.stateDir.appendingPathComponent("flood.sh")
    try? """
    #!/bin/sh
    touch "$LMUX_SINK_DIR/$LMUX_PANE_ID.ready"
    yes x | head -n 2000000
    stty raw echo
    exec /bin/cat > "$LMUX_SINK_DIR/$LMUX_PANE_ID.bin"
    """.write(to: flood, atomically: true, encoding: .utf8)
    chmod(flood.path, 0o755)
    let wsF = c.newWorkspace(cwd: "/tmp", program: flood.path)
    let pF = wsF.panes[0]
    _ = await sinks.waitReady(pF.id, timeout: 10)
    hookEvent(c, pF, "SessionStart", session: "flood-1")
    hookEvent(c, pF, "UserPromptSubmit", session: "flood-1", ["prompt": "x"])
    let deadPID = Process()
    deadPID.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? deadPID.run(); deadPID.waitUntilExit()
    pF.claudePID = deadPID.processIdentifier  // Claude gone without SessionEnd
    if let pF2 = c.split(pF, .right) { _ = await sinks.waitReady(pF2.id, timeout: 5) }
    // Let the flood finish and the shell title come back.
    _ = await rw.waitUntil(20) { FileManager.default.fileExists(atPath: sinks.dir.appendingPathComponent("\(pF.id).bin").path) }
    pF.surface.onTitleChange?("…/tmp")
    await rw.clickAndType(pF, "after flood")
    await sleepMs(3000)
    let visible = c.model.selected?.panes.count ?? 0
    let links = threadNames().filter { $0.contains("CVDisplayLink") }.count
    r.check("CVDisplayLink threads ≤ visible surfaces + 1 (\(links) for \(visible))", links <= visible + 1)
    let cpu = await cpuPercent(seconds: 8)
    r.check(String(format: "idle CPU < 1%% after the flood and Claude's exit (%.2f%%)", cpu), cpu < 1.0)
    r.check("no input-label polling left for a pane whose Claude is gone", c.overlayWork[pF.id] == nil && !pF.runsClaude)

    // --------------------------------------------------- randomized basics
    r.section = "randomized"
    var rng = SplitMix(seed: UInt64(ProcessInfo.processInfo.environment["LMUX_RW_SEED"] ?? "") ?? 0x1A2B3C)
    print("randomized seed: \(rng.seed)")
    let n = Int(ProcessInfo.processInfo.environment["LMUX_RW_STEPS"] ?? "") ?? 200
    var misses = 0
    for i in 0..<n {
        let action = await randomAction(rw, &rng)
        rw.steps.append("\(i):\(action)")
        await sleepMs(120)
        if NSApp.modalWindow != nil || w.attachedSheet != nil {
            r.check("no modal left open after \(action)", false, rw.steps.suffix(8).joined(separator: " > "))
            NSApp.abortModal()
            if let s = w.attachedSheet { w.endSheet(s) }
        }
        let panes = c.model.selected?.panes ?? []
        guard !panes.isEmpty else { continue }
        let target = panes[Int(rng.next() % UInt64(panes.count))]
        if !(await rw.clickAndType(target, "random step \(i) (\(action))")) {
            misses += 1
            if misses > 5 { break }
        }
    }
    r.check("randomized: every step's click + type arrived (\(n) steps, seed \(rng.seed))", misses == 0)
    await rw.shot("06-end")

    // ------------------------------------------------------- sidebar × / multi-select
    // The real pointer on a row shows its ×; a real click on the × (at its actual frame) closes
    // that row without selecting it first. The sink panes run `cat`, so each close asks first.
    r.section = "sidebar ×"
    let keep = c.model.selected!
    let x1 = c.newWorkspace(select: false), x2 = c.newWorkspace(select: false), x3 = c.newWorkspace(select: false)
    for x in [x1, x2, x3] { _ = await sinks.waitReady(x.panes[0].id, timeout: 5) }
    root.layoutSubtreeIfNeeded()
    let i1 = c.model.workspaces.firstIndex { $0 === x1 }!
    await rw.move(rw.cg(root.sidebarHost, rowPoint(c, i1)))
    _ = await rw.waitUntil(2) { c.model.hoveredRowID == x1.id }
    r.check("the real pointer on a row hovers it", c.model.hoveredRowID == x1.id)
    await rw.shot("07-sidebar-hover-x")
    let xr = closeButtonRect(c, x1)
    await rw.click(rw.cg(root.sidebarHost, NSPoint(x: xr.midX, y: xr.midY)))
    let hostPane = keep.focusedPane!
    r.check("clicking its × asks (cat is running) without selecting the row", c.cardShown(hostPane) && c.model.selected === keep)
    if let b = hostPane.view.overlay.card?.confirm { await rw.click(rw.center(b)) }
    _ = await rw.waitUntil(2) { !c.model.workspaces.contains { $0 === x1 } }
    r.check("Close closes just that row; the selection stays", !c.model.workspaces.contains { $0 === x1 } && c.model.selected === keep)
    // ⌘-click two rows, × on one of them: one question for both.
    for x in [x2, x3] {
        await rw.click(rw.cg(root.sidebarHost, rowPoint(c, c.model.workspaces.firstIndex { $0 === x }!)), flags: .maskCommand)
    }
    r.check("⌘-click builds a multi-selection", c.model.isMultiSelection && c.model.selection == Set([keep.id, x2.id, x3.id])
            && c.model.selected === x3)
    await rw.shot("08-sidebar-multiselect")
    let i2 = c.model.workspaces.firstIndex { $0 === x2 }!
    await rw.move(rw.cg(root.sidebarHost, rowPoint(c, i2)))
    _ = await rw.waitUntil(2) { c.model.hoveredRowID == x2.id }
    let xr2 = closeButtonRect(c, x2)
    await rw.click(rw.cg(root.sidebarHost, NSPoint(x: xr2.midX, y: xr2.midY)))
    let shown = c.model.selected!.focusedPane!
    r.check("× on a selected row asks once for the whole selection",
            (shown.view.overlay.card?.message.stringValue ?? "").hasPrefix("Close 3 workspaces?"), shown.view.overlay.card?.message.stringValue ?? "")
    await rw.key(53, settle: 300)
    r.check("Esc cancels: all three stay", [keep, x2, x3].allSatisfy { w in c.model.workspaces.contains { $0 === w } })
    await rw.clickAndType(c.model.selected!.focusedPane!, "after the sidebar ×")
    for x in [x2, x3] { c.closeWorkspace(x) }

    // ---------------------------------------------------------------- bell
    // A real click on the bell opens the popover (real NSPopover, real window); a click on a row
    // jumps there and closes it; Esc closes it too.
    r.section = "bell"
    let target = c.newWorkspace(select: false)
    _ = await sinks.waitReady(target.panes[0].id, timeout: 5)
    hookEvent(c, target.panes[0], "SessionStart", session: "rw-bell")
    hookEvent(c, target.panes[0], "UserPromptSubmit", session: "rw-bell", ["prompt": "x"])
    hookEvent(c, target.panes[0], "Stop", session: "rw-bell", ["last_assistant_message": "done for the bell"])
    await rw.click(buttonPoint(1), settle: 600)
    r.check("clicking the bell opens the notification popover", c.notificationsPanel.isOpen && c.notificationsPopover?.isShown == true)
    await rw.shot("09-bell-popover")
    if let v = c.notificationsView {
        let y = NotificationsView.headerHeight + 4 + NotificationsView.rowHeight / 2
        await rw.click(rw.cg(v, NSPoint(x: 160, y: v.isFlipped ? y : v.bounds.height - y)), settle: 600)
    }
    r.check("clicking its newest row jumps to that workspace and closes it", c.model.selected === target
            && c.notificationsPopover?.isShown != true && target.panes[0].unread == 0)
    await rw.click(buttonPoint(1), settle: 600)
    let beforeEsc = "open=\(c.notificationsPanel.isOpen) shown=\(c.notificationsPopover?.isShown == true) "
        + "key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") fr=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") "
        + "reduceMotion=\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) "
        + "popoverWindow=\(c.notificationsView?.window.map { "\(type(of: $0)) canKey=\($0.canBecomeKey) key=\($0.isKeyWindow)" } ?? "nil")"
    await rw.key(53, settle: 500)
    r.check("Esc closes it", c.notificationsPopover?.isShown != true && !c.notificationsPanel.isOpen, beforeEsc)
    await rw.clickAndType(c.model.selected!.focusedPane!, "after the bell")
    c.closeWorkspace(target)

    // ------------------------------------------------- polish (POLISH.md)
    // The mockup's scene in a real window (translucent sidebar over the desktop, real hover,
    // real ⇧⌘H), shot in light and dark: polish-*.png, compared against design/previews/polish-*.png.
    r.section = "polish"
    w.setFrame(NSRect(x: 10, y: 60, width: 1000, height: 640), display: true)
    let scene = await stagePolishScene(c, fx: paths.stateDir.appendingPathComponent("polish", isDirectory: true))
    if let lights = root.trafficLightsFrame {
        let cl = root.cluster.convert(root.cluster.bounds, to: nil)
        r.check("polish: titlebar glyph centers on the traffic lights within 1px (2x)", abs(cl.midY - lights.midY) * 2 <= 1,
                "cluster \(cl.midY) lights \(lights.midY)")
    }
    r.check("polish: sidebar is the translucent material (Reduce Transparency off)",
            !root.sidebarBackdrop.material.isHidden && root.sidebarBackdrop.material.blendingMode == .behindWindow,
            "reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
    // Claude finished the left pane's turn: the turn Claude is still writing gets no ✎ × (updateHover),
    // and the fixture's earlier turn makes this one removable (the conversation's first has no ×).
    hookEvent(c, scene.left, "Stop", session: "polish-1", ["last_assistant_message": "Found it."])
    _ = await rw.waitUntil(3) { scene.left.agent.state != .running }
    for (dark, name) in [(false, "light"), (true, "dark")] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await sleepMs(1200)
        c.root.updateHeader()
        // Real pointer on the prompt, then on ×: the pill, the band and (after 600ms) the tip.
        scene.left.hover.readAt = .distantPast
        let m = c.screenMap(scene.left, maxAge: 0)
        if let h = m.map?.promptHeads().first {
            let y = m.rows[h.row].top + m.rowHeight / 2
            await rw.move(rw.cg(scene.left.view.overlay, NSPoint(x: 120, y: y)))
            // The pill comes after the turns are (re)read off the main thread: waited for, not 500ms.
            if !(await rw.waitUntil(2) { scene.left.view.overlay.turnBar?.shown == true }) {
                // (One more move, as a hand would: a move that landed while the History field still had
                // the keyboard can come before the pane's tracking area is live again.)
                await rw.move(rw.cg(scene.left.view.overlay, NSPoint(x: 124, y: y)))
                _ = await rw.waitUntil(2) { scene.left.view.overlay.turnBar?.shown == true }
            }
            if let bar = scene.left.view.overlay.turnBar, bar.shown {
                await rw.move(rw.center(bar.remove))
                await sleepMs(900)
            }
        }
        r.check("polish \(name): hovering the prompt shows ✎ × and, on ×, its explanation",
                scene.left.view.overlay.turnBar?.shown == true && !scene.left.view.overlay.tip.isHidden,
                "head=\(m.map?.promptHeads().first.map { "\($0.row)" } ?? "nil") bar=\(scene.left.view.overlay.turnBar.map { "\($0.shown)" } ?? "nil") "
                + "tip hidden=\(scene.left.view.overlay.tip.isHidden) turns=\(scene.left.hover.turns.count)")
        await rw.shot("polish-\(name)-hover")
        // ⇧⌘H, type, the panel; Esc Esc hands the keyboard back.
        await rw.move(rw.cg(scene.right.surface, NSPoint(x: 300, y: 200)))
        await rw.cmd("h", .maskShift, settle: 600)
        r.check("polish \(name): ⇧⌘H focuses the History field", w.firstResponder is NSText, "\(String(describing: w.firstResponder))")
        await rw.type("refund")
        _ = await rw.waitUntil(3) { c.history.searchedQuery == "refund" }
        await sleepMs(500)
        r.check("polish \(name): typing searches History (3 results)", c.history.items.count == 3, "\(c.history.items.count)")
        await rw.shot("polish-\(name)-search")
        await rw.key(53, settle: 200)
        await rw.key(53, settle: 400)
        r.check("polish \(name): Esc Esc clears, collapses and returns the keyboard to the pane",
                c.history.query.isEmpty && firstResponderPane(c) != nil, "\(String(describing: w.firstResponder))")
    }
    // First launch: one Home row and the hooks sheet (Esc = Not Now).
    let homeWS = c.newWorkspace(cwd: NSHomeDirectory())
    for x in c.model.workspaces where x !== homeWS { c.closeWorkspace(x) }
    for (dark, name) in [(false, "light"), (true, "dark")] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await sleepMs(1000)
        c.root.updateHeader()
        c.presentHooksSheet(install: true, firstRun: true)
        _ = await rw.waitUntil(3) { w.attachedSheet != nil }
        await sleepMs(800)
        // Collapsed: exactly the height of the sheet's content with the diff hidden (shown, it adds up to 200pt).
        // (It used to say "fits in 400pt"; the copy and preview card make it 427-445pt on every Mac, 2x or 1x.)
        let collapsed = HooksSheet.window(install: true, diff: "", settingsPath: HooksSetup.settingsPath(), cancelTitle: "Not Now") { _ in }
        let collapsedHeight = collapsed.contentViewController?.view.fittingSize.height ?? 0
        let screenHeight = w.screen?.visibleFrame.height ?? 0
        r.check("polish \(name): the hooks sheet is the custom sheet (no NSAlert), diff collapsed, fits on the screen",
                w.attachedSheet.map { !($0 is NSPanel) && abs($0.frame.height - collapsedHeight) <= 1 && $0.frame.height <= screenHeight } ?? false,
                "\(w.attachedSheet.map { "\($0.frame)" } ?? "no sheet") collapsed \(collapsedHeight) screen \(screenHeight)")
        await rw.shot("polish-\(name)-onboarding")
        await rw.key(53, settle: 600)
        r.check("polish \(name): Esc is Not Now (sheet gone, keyboard on the pane)",
                w.attachedSheet == nil && firstResponderPane(c) != nil)
    }
    NSApp.appearance = nil

    print("\n\(r.passed) passed, \(r.failed) failed")
    return r.failed == 0 ? 0 : 1
}

struct SplitMix: RandomNumberGenerator {
    let seed: UInt64
    var state: UInt64
    init(seed: UInt64) { self.seed = seed; state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// One random everyday interaction (real events where a person would use the mouse/keys).
@MainActor
func randomAction(_ rw: RW, _ rng: inout SplitMix) async -> String {
    let c = rw.c, root = c.root!
    let bs = LmuxTokens.Layout.titlebarButtonSize
    func button(_ i: Int) -> CGPoint { rw.cg(root.cluster, NSPoint(x: bs / 2 + CGFloat(i) * (bs + 2), y: root.cluster.bounds.midY)) }
    let total = c.model.workspaces.flatMap(\.panes).count
    switch rng.next() % 13 {
    case 0:
        guard c.model.sidebarVisible, !c.model.workspaces.isEmpty else { return "noop" }
        let i = Int(rng.next() % UInt64(min(c.model.workspaces.count, 6)))
        await rw.click(rw.cg(root.sidebarHost, rowPoint(c, i)))
        return "click sidebar row \(i)"
    case 1:
        guard total < 10 else { return "noop" }
        await rw.click(button(2), settle: 500)
        return "click +"
    case 2:
        await rw.click(button(1), flags: .maskAlternate); return "⌥-click bell"
    case 3:
        await rw.click(button(0), settle: 400); return "click sidebar toggle"
    case 4:
        guard let p = c.model.selected?.focusedPane, total < 10 else { return "noop" }
        await rw.click(rw.center(p.surface))
        await rw.cmd("d", settle: 600)
        return "⌘D split"
    case 5:
        guard let ws = c.model.selected, ws.panes.count > 1, let p = ws.focusedPane else { return "noop" }
        c.closePane(p)  // ⌘W asks first for a running process; the sink is one
        return "close pane"
    case 6:
        guard let p = c.model.selected?.focusedPane else { return "noop" }
        await rw.click(rw.center(p.surface))
        await rw.cmd("f", settle: 300)
        await rw.key(53, settle: 300)  // esc closes it
        if p.view.overlay.findBar != nil { c.searchEnded(p) }
        return "⌘F + esc"
    case 7:
        guard let p = c.model.selected?.panes.randomElement(using: &rng) else { return "noop" }
        c.showCard(p, message: NSAttributedString(string: "card"), detail: "", confirmTitle: "Send", onConfirm: {})
        await sleepMs(150)
        await rw.key(53)  // esc = cancel
        return "card + esc"
    case 8:
        guard let p = c.model.selected?.panes.randomElement(using: &rng) else { return "noop" }
        c.showNote(p, "toast", duration: 0.3)
        await sleepMs(450)
        return "toast"
    case 9:
        guard let split = (c.model.selected?.panes.first?.view.superview as? SplitContainerView) else { return "noop" }
        let a = rw.center(split.divider)
        let dx = CGFloat(Int(rng.next() % 160)) - 80
        await rw.drag(from: a, to: CGPoint(x: a.x + (split.axis == .horizontal ? dx : 0), y: a.y + (split.axis == .vertical ? dx : 0)))
        return "drag divider \(Int(dx))"
    case 10:
        guard let p = c.model.selected?.panes.randomElement(using: &rng) else { return "noop" }
        let s = p.surface
        await rw.move(rw.cg(s, NSPoint(x: s.bounds.width * 0.5, y: s.bounds.height * 0.5)))
        await rw.move(rw.cg(s, NSPoint(x: s.bounds.width * 0.8, y: s.bounds.height * 0.2)))
        return "hover"
    case 11:
        guard let p = c.model.selected?.panes.randomElement(using: &rng) else { return "noop" }
        await rw.scroll(at: rw.center(p.surface), lines: Int32(Int(rng.next() % 7)) - 3)
        return "scroll"
    default:
        let h = root.header
        let from = rw.cg(h, NSPoint(x: h.bounds.width - 60, y: root.titlebarHeight / 2))
        let dx = CGFloat(Int(rng.next() % 60)) - 30
        await rw.drag(from: from, to: CGPoint(x: from.x + dx, y: from.y + dx / 2))
        return "drag titlebar"
    }
}

/// Names of this process's threads (pthread names).
func threadNames() -> [String] {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
    defer {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    }
    var names: [String] = []
    for i in 0..<Int(count) {
        var info = thread_extended_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &n) }
        }
        if kr == KERN_SUCCESS {
            names.append(withUnsafeBytes(of: info.pth_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
        }
        mach_port_deallocate(mach_task_self_, list[i])
    }
    return names
}

/// This process's CPU use over `seconds` (user + system, percent of one core).
@MainActor
func cpuPercent(seconds: Double) async -> Double {
    func now() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    let t0 = now(), w0 = Date()
    await sleepMs(Int(seconds * 1000))
    return (now() - t0) / Date().timeIntervalSince(w0) * 100
}
