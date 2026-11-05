import AppKit
import LmuxTokens
@testable import LmuxUI

// `lmux-apptest --titlebar`: the titlebar buttons (sidebar toggle, bell, +) and ⇧⌘H in the real
// titled window chrome (toolbar, traffic lights, the titlebar view AppKit puts above the content),
// headless: the window is ordered in off screen (-10000, -10000; no display shows it), never key,
// the app never active, and the pointer never moves. Clicks are NSEvents routed by the window itself
// (hit test from its frame view, like a real click), and each button is also pressed through
// accessibility (what VoiceOver / performClick-style automation does).

@MainActor
func runTitlebar() async -> Int32 {
    let r = Report()
    LmuxController.headlessTitled = true
    let c = makeController()
    let w = c.window!
    let root = c.root!
    r.section = "titlebar"
    func offScreen() -> Bool { !NSScreen.screens.contains { $0.frame.intersects(w.frame) } }
    r.check("titled window, on no display, never key, app never active",
            w.styleMask.contains(.titled) && offScreen() && !w.isKeyWindow && !NSApp.isActive, "\(w.frame)")
    guard let host = root.titlebarHost else {
        r.check("the window has a titlebar view for the buttons", false)
        return finish(r, c)
    }
    r.check("the buttons live in the window's titlebar view", root.cluster.superview === host)
    let p1 = c.model.selected!.panes[0]
    r.check("pane ready", await sinks.waitReady(p1.id))

    let bs = LmuxTokens.Layout.titlebarButtonSize
    /// Button i (0 toggle, 1 bell, 2 +), in the cluster's coordinates.
    func point(_ i: Int) -> NSPoint {
        NSPoint(x: bs / 2 + CGFloat(i) * (bs + 2), y: root.cluster.bounds.midY)
    }
    func windowPoint(_ i: Int) -> NSPoint { root.cluster.convert(point(i), to: nil) }
    // What a real click at each button's center would hit: the window's frame view hit-tests in
    // window coordinates, through the titlebar container above the content view.
    let frameView = w.contentView!.superview!
    for (i, name) in ["sidebar toggle", "bell", "+"].enumerated() {
        let hit = frameView.hitTest(windowPoint(i))
        r.check("a click on \(name) hits the button (nothing above it takes it)",
                hit.map { $0.isDescendant(of: root.cluster) } ?? false, String(describing: hit))
    }
    if let lights = root.trafficLightsFrame {
        let cl = root.cluster.convert(root.cluster.bounds, to: nil)
        r.check("the buttons sit right of the traffic lights, centered on them",
                cl.minX >= lights.maxX + 4 && abs(cl.midY - lights.midY) <= 2, "cluster \(cl) lights \(lights)")
    }

    // + (mouse)
    let n0 = c.model.workspaces.count
    await click(root.cluster, at: point(2))
    _ = await waitFor(2) { c.model.workspaces.count == n0 + 1 }
    r.check("+ (clicked) adds a workspace and selects it",
            c.model.workspaces.count == n0 + 1 && c.model.selected === c.model.workspaces.last, "\(c.model.workspaces.count)")
    if let p = c.model.selected?.panes.first {
        _ = await sinks.waitReady(p.id)
        r.check("…its pane has the keyboard", firstResponderPane(c) === p)
    }

    // Sidebar toggle (mouse), twice at the same spot.
    let n1 = c.model.workspaces.count
    let at = windowPoint(0)
    await click(root.cluster, at: point(0))
    _ = await waitFor(2) { !c.model.sidebarVisible }
    root.layoutSubtreeIfNeeded()
    r.check("sidebar toggle (clicked) hides the sidebar", !c.model.sidebarVisible && root.sidebarHost.isHidden)
    r.check("…the toggle stays under the pointer", abs(windowPoint(0).x - at.x) < 0.5 && abs(windowPoint(0).y - at.y) < 0.5,
            "\(at) -> \(windowPoint(0))")
    r.check("…and still takes the click there", frameView.hitTest(at).map { $0.isDescendant(of: root.cluster) } ?? false)
    await click(root.cluster, at: root.cluster.convert(at, from: nil))
    _ = await waitFor(2) { c.model.sidebarVisible }
    root.layoutSubtreeIfNeeded()
    r.check("a second click at the same spot shows it again (no workspace added)",
            c.model.sidebarVisible && !root.sidebarHost.isHidden && c.model.workspaces.count == n1)
    r.check("…keyboard still in the pane", firstResponderPane(c) != nil, String(describing: w.firstResponder))

    // Bell (mouse): a click opens the notification list; ⌥-click jumps to the unread pane.
    // (On failure: every open / close the click caused, and what it hit.)
    var opens: [Bool] = [c.notificationsPanel.isOpen]
    let watch = Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in
        MainActor.assumeIsolated { if opens.last != c.notificationsPanel.isOpen { opens.append(c.notificationsPanel.isOpen) } }
    }
    func bellDiag() -> String {
        let hit = frameView.hitTest(windowPoint(1))
        return "open/close \(opens) · hit \(hit.map { String(describing: type(of: $0)) } ?? "nil")"
            + String(format: " · press %.0f ms · ", MouseQueue.lastPressMs) + MouseQueue.environment
    }
    await click(root.cluster, at: point(1))
    _ = await waitFor(2) { c.notificationsPanel.isOpen }
    r.check("bell (clicked) opens the notification list", c.notificationsPanel.isOpen, bellDiag())
    await click(root.cluster, at: point(1))
    _ = await waitFor(2) { !c.notificationsPanel.isOpen }
    r.check("…clicked again, closes it", !c.notificationsPanel.isOpen, bellDiag())
    watch.invalidate()
    p1.unread = 1
    p1.lastAlertAt = Date()
    await click(root.cluster, at: point(1), modifiers: .option)
    _ = await waitFor(2) { c.model.selected?.focusedPane === p1 }
    r.check("bell ⌥-clicked jumps to the unread pane", c.model.selected?.focusedPane === p1 && firstResponderPane(c) === p1
            && !c.notificationsPanel.isOpen)

    // ⇧⌘H: History search takes the keyboard (bringing the sidebar back), Esc Esc hands it back.
    r.section = "history search"
    let work = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("work", isDirectory: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    PolishFixture.writeHistory(root: c.history.projectsRoot, cwd: work.path)
    await c.history.refresh()
    _ = await waitFor(10) { c.history.totalCount > 0 }
    r.check("History has the closed sessions", c.history.totalCount > 0, "\(c.history.totalCount)")
    c.toggleSidebar()
    _ = await waitFor(2) { !c.model.sidebarVisible }
    await cmd("h", shift: true, window: w)
    _ = await waitFor(2) { w.firstResponder is NSText }
    r.check("⇧⌘H (sidebar hidden) shows the sidebar and focuses the History field",
            c.model.sidebarVisible && w.firstResponder is NSText, String(describing: w.firstResponder))
    await type("ab", window: w)
    _ = await waitFor(2) { c.history.query == "ab" }
    r.check("…typing goes into the field, not the pane", c.history.query == "ab" && !sinks.text(p1.id).contains("ab"),
            "query \(c.history.query.debugDescription) pane \(sinks.text(p1.id))")
    await type("\u{1b}", window: w)
    _ = await waitFor(2) { c.history.query.isEmpty }
    r.check("Esc clears the query, the field keeps the keyboard", c.history.query.isEmpty && w.firstResponder is NSText)
    await type("\u{1b}", window: w)
    _ = await waitFor(2) { firstResponderPane(c) != nil }
    r.check("a second Esc closes it: the keyboard is back in the pane", firstResponderPane(c) === c.model.selected?.focusedPane
            && firstResponderPane(c) != nil, String(describing: w.firstResponder))
    await type("z", window: w)
    r.check("…and keys reach the pane again", await sinks.wait(c.model.selected!.focusedPane!.id, contains: "z"))

    // AppKit settles key / active state asynchronously after the History field hands the keyboard
    // back (a transient key status can be reported mid-transition): wait on the real condition, a
    // bounded number of times, and say which part didn't hold.
    var settled = false
    for _ in 0..<3 where !settled {
        settled = await waitFor(1) { offScreen() && !w.isKeyWindow && !NSApp.isActive }
    }
    r.check("the window stayed off every display, never key", settled,
            "frame \(w.frame) offScreen=\(offScreen()) key=\(w.isKeyWindow) appActive=\(NSApp.isActive)")
    return finish(r, c)
}
