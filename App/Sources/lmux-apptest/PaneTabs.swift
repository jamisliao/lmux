import AppKit
import LmuxTokens
@testable import LmuxUI

// `lmux-apptest --pane-tabs`: tabs inside a pane, with cmux's tab bar. The keys on the real key path
// (⌘T, ⌃⇥ / ⌃⇧⇥, ⇧⌘] / ⇧⌘[, ⌃1…⌃9, ⌥⇧⌘] / ⌥⇧⌘[, ⌥⌘T, ⌘W, ⌃⌘] / ⌃⌘[), the strip (on every pane, widths,
// ×, buttons, double-clicks, the context menu, pinned tabs, drag to reorder / into another pane /
// to split, overflow), hidden tabs not rendering, status across tabs (sidebar row, the tab's badge,
// ⇧⌘J, a notification), splits and zoom with tabs, the setting, layout.json (tabs + selected +
// pinned, old files), `lmux list` / `new-tab`. Saves a layout for `--pane-tabs-restore`.

/// ⌃⇥ (⇧: ⌃⇧⇥) through the real key path.
@MainActor
func ctrlTab(shift: Bool = false, window: NSWindow) async {
    let ts = ProcessInfo.processInfo.systemUptime
    var mods: NSEvent.ModifierFlags = [.control]
    if shift { mods.insert(.shift) }
    // As the keyboard sends it: ⇧⇥ is the back-tab character.
    let ch = shift ? "\u{19}" : "\t"
    for t in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ts,
                                 windowNumber: window.windowNumber, context: nil, characters: ch,
                                 charactersIgnoringModifiers: ch, isARepeat: false, keyCode: 48)!
        dispatchKey(e, window: window)
    }
    await sleepMs(150)
}

/// A double-click at a point of `view`.
@MainActor
func doubleClick(_ view: NSView, at p: NSPoint) async {
    guard let w = view.window else { return }
    let loc = view.convert(p, to: nil)
    for n in [1, 2] {
        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n,
                                       pressure: t == .leftMouseUp ? 0 : 1)!
            w.sendEvent(e)
            await sleepMs(20)
        }
    }
    await sleepMs(120)
}

/// The pointer over a point of `view` (hover, no button).
@MainActor
func hover(_ view: NSView, at p: NSPoint) {
    guard let w = view.window else { return }
    let e = NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(p, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 0, pressure: 0)!
    view.mouseMoved(with: e)
}

/// The middle of tab `i` in its strip.
@MainActor
func tabPoint(_ s: TabStripView, _ i: Int) -> NSPoint { NSPoint(x: s.tabRect(i).midX, y: s.bounds.midY) }

/// A point of `view` in `s`'s coordinates (a drag from a strip to somewhere else).
@MainActor
func point(_ p: NSPoint, of view: NSView, in s: NSView) -> NSPoint { s.convert(view.convert(p, to: nil), from: nil) }

@MainActor
func isHidden(_ p: Pane) -> Bool { p.surface.window == nil && !p.surface.occlusionVisible }
@MainActor
func isShown(_ p: Pane) -> Bool { p.surface.window != nil && p.surface.occlusionVisible }

/// A menu's titles, separators as "—".
@MainActor
func titles(_ m: NSMenu) -> [String] { m.items.map { $0.isSeparatorItem ? "—" : $0.title } }

/// Run a menu's item by title (false if it's missing or disabled).
@MainActor
@discardableResult
func run(_ m: NSMenu, _ title: String) -> Bool {
    guard let i = m.items.firstIndex(where: { $0.title == title }), m.items[i].isEnabled else { return false }
    m.performActionForItem(at: i)
    return true
}

@MainActor
func runPaneTabs() async -> Int32 {
    let r = Report()
    let c = makeController()
    let w = c.window!

    // ------------------------------------------------------------- basics
    r.section = "tabs"
    let ws = c.model.selected!
    let t1 = ws.panes[0]
    _ = await sinks.waitReady(t1.id)
    c.focusCurrent()
    let one = t1.view.tabStrip
    r.check("one tab: the tab bar shows anyway (cmux's default), one tab in it, no pane header",
            one != nil && one?.items.count == 1 && one?.selected == 0 && t1.view.header.isHidden, "\(one?.items ?? [])")
    r.check("…30 pt high, the terminal under it", t1.surface.frame.minY == 30 && TabStripView.height == 30, "\(t1.surface.frame)")
    let w0 = one?.items.first?.width ?? 0
    r.check("…the tab is sized to its title (48–220 pt), not stretched", w0 >= 48 && w0 < 220 && one!.bounds.width > 300, "\(w0)")
    // The strip sits on the terminal's background: it follows a light / dark switch (the theme pair).
    func luma(_ c: NSColor?) -> CGFloat {
        guard let s = c?.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * s.redComponent + 0.7152 * s.greenComponent + 0.0722 * s.blueComponent
    }
    for mode in [LmuxSettings.Appearance.light, .dark] {
        c.setAppearance(mode)
        let dark = mode == .dark
        _ = await waitFor(5) { (luma(t1.surface.terminalBackground) < 0.5) == dark }
        r.check("the strip's background follows a switch to \(mode) (the terminal's own background, its text tokens)",
                one?.background == t1.surface.terminalBackground && (luma(one?.background) < 0.5) == dark
                && (one?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua) == dark,
                "strip \(luma(one?.background)) terminal \(luma(t1.surface.terminalBackground))")
    }
    c.setAppearance(.system)
    c.validateMenuItem(c.closePaneMenuItem!)
    r.check("…⌘W says Close Pane", c.closePaneMenuItem?.title == "Close Pane", c.closePaneMenuItem?.title ?? "-")

    await cmd("t", window: w)
    let opened = await waitFor(3) { ws.panes.count == 2 }
    guard opened, let t2 = ws.panes.last, t2 !== t1 else {
        r.check("⌘T opens a tab", false, "\(ws.panes.count) panes"); return finish(r, c)
    }
    _ = await sinks.waitReady(t2.id)
    let leaf = ws.root.find(t1)
    r.check("⌘T (the real key path, Ghostty's new_tab): a second tab in the pane, not a workspace",
            c.model.workspaces.count == 1 && leaf != nil && leaf === ws.root.find(t2) && leaf?.tabs.count == 2)
    r.check("…the new tab is shown and focused, the first stops rendering",
            ws.focusedPane === t2 && leaf?.shownTab === t2 && isShown(t2) && isHidden(t1)
            && w.firstResponder === t2.surface, "t1 window \(t1.surface.window != nil) occl \(t1.surface.occlusionVisible)")
    let strip = t2.view.tabStrip
    r.check("…the same strip moves to the shown tab's view: 2 tabs, the second selected",
            strip != nil && strip === leaf?.strip && strip === one && strip?.superview === t2.view && strip?.items.count == 2
            && strip?.selected == 1 && t2.view.header.isHidden, "\(strip?.items.map(\.title) ?? [])")
    r.check("…the terminal sits under the strip", t2.surface.frame.minY == TabStripView.height
            && t2.surface.frame.height == t2.view.bounds.height - TabStripView.height, "\(t2.surface.frame)")
    r.check("…still one leaf: not a split", !ws.isSplit && ws.visiblePanes.count == 1)
    c.validateMenuItem(c.closePaneMenuItem!)
    r.check("…⌘W says Close Tab", c.closePaneMenuItem?.title == "Close Tab", c.closePaneMenuItem?.title ?? "-")

    await ctrlTab(window: w)
    r.check("⌃⇥ (wraps) goes to the first tab", leaf?.shownTab === t1 && ws.focusedPane === t1 && isShown(t1) && isHidden(t2)
            && w.firstResponder === t1.surface && strip?.superview === t1.view && strip?.selected == 0)
    await ctrlTab(shift: true, window: w)
    r.check("⌃⇧⇥ back to the second", leaf?.shownTab === t2 && isShown(t2) && isHidden(t1))
    await cmd("[", shift: true, window: w)
    r.check("⇧⌘[ (cmux's previous tab): the first", leaf?.shownTab === t1 && c.model.workspaces.count == 1)
    await cmd("]", shift: true, window: w)
    r.check("⇧⌘] (cmux's next tab): the second", leaf?.shownTab === t2)
    await press("1", .control, window: w)
    r.check("⌃1: the first tab", leaf?.shownTab === t1 && w.firstResponder === t1.surface)
    await press("9", .control, window: w)
    r.check("⌃9: the last tab", leaf?.shownTab === t2 && w.firstResponder === t2.surface)

    // Typing reaches only the shown tab.
    await type("ab", window: w)
    _ = await sinks.wait(t2.id, contains: "ab")
    r.check("typing goes to the shown tab only", sinks.text(t2.id).contains("ab") && !sinks.text(t1.id).contains("ab"),
            "t1=\(sinks.text(t1.id).debugDescription)")
    r.check("…⌃1 / ⌃9 didn't type into the terminal", !sinks.text(t2.id).contains("1") && !sinks.text(t1.id).contains("9"),
            sinks.text(t2.id))

    // Clicks on the strip.
    let s = strip!
    s.layoutSubtreeIfNeeded()
    await click(s, at: tabPoint(s, 0))
    r.check("click on a tab selects it", leaf?.shownTab === t1 && ws.focusedPane === t1 && isShown(t1) && isHidden(t2))
    await click(s, at: tabPoint(s, 0), dragTo: tabPoint(s, 1))
    r.check("drag a tab onto the next slot: reordered, still shown", leaf?.tabs.map(\.id) == [t2.id, t1.id]
            && leaf?.shownTab === t1 && s.selected == 1 && ws.panes.map(\.id) == [t2.id, t1.id])
    await click(s, at: tabPoint(s, 1), dragTo: tabPoint(s, 0))
    r.check("…and back", leaf?.tabs.map(\.id) == [t1.id, t2.id])
    await click(s, at: tabPoint(s, 1), dragTo: tabPoint(s, 0))
    r.check("a drag that starts on a tab behind: it moves, the shown tab stays in front (cmux: a drag doesn't select)",
            leaf?.tabs.map(\.id) == [t2.id, t1.id] && leaf?.shownTab === t1 && isShown(t1) && s.window != nil,
            leaf?.tabs.map(\.id).joined(separator: ",") ?? "-")
    c.moveTab(t2, to: 1)

    // A third tab opened behind (CLI): after the shown one (cmux's "current" placement).
    guard let t3 = c.newTab(t1, select: false) else { r.check("newTab behind", false); return finish(r, c) }
    _ = await sinks.waitReady(t3.id)
    r.check("a tab opened behind: placed right after the shown one, not shown, not rendering",
            leaf?.tabs.map(\.id) == [t1.id, t3.id, t2.id] && leaf?.shownTab === t1 && isHidden(t3) && s.items.count == 3)
    await press("]", [.command, .shift, .option], window: w)
    r.check("⌥⇧⌘]: the focused tab moves one place right", leaf?.tabs.map(\.id) == [t3.id, t1.id, t2.id] && leaf?.shownTab === t1)
    await press("[", [.command, .shift, .option], window: w)
    r.check("⌥⇧⌘[: and back left", leaf?.tabs.map(\.id) == [t1.id, t3.id, t2.id])

    // ×: on the shown tab always, on another one only while hovered.
    s.layoutSubtreeIfNeeded()
    hover(s, at: tabPoint(s, 2))
    r.check("hovering a tab behind: its × shows (its title moves aside for it)", s.items.count == 3, "")
    let xAt = NSPoint(x: s.closeRect(0).midX, y: s.closeRect(0).midY)
    hover(s, at: xAt)
    await click(s, at: xAt)
    r.check("× on a tab running something asks first (a card on that tab)", t1.view.overlay.card != nil && ws.panes.count == 3)
    t1.view.overlay.card?.confirm.performClick()
    _ = await waitFor(2) { ws.panes.count == 2 }
    r.check("…confirmed: the tab closes, the one to its right shows", !ws.panes.contains { $0 === t1 } && leaf?.shownTab === t3
            && ws.focusedPane === t3 && isShown(t3) && s.superview === t3.view)
    // Middle-click on the hidden tab (t2): asks on it (brought to the front).
    s.layoutSubtreeIfNeeded()
    s.middleClicked(at: tabPoint(s, 1))
    r.check("middle-click on a tab asks on that tab (brought to the front)", leaf?.shownTab === t2 && t2.view.overlay.card != nil)
    t2.view.overlay.card?.confirm.performClick()
    _ = await waitFor(2) { ws.panes.count == 1 }
    r.check("…closing the last tab of two: the one left (to its left) shows, the strip stays with one tab",
            ws.panes.map(\.id) == [t3.id] && t3.view.tabStrip === s && s.items.count == 1 && isShown(t3),
            "panes \(ws.panes.count) strip \(t3.view.tabStrip != nil) items \(s.items.count) shown \(isShown(t3))")
    guard let t4 = c.newTab(t3, select: false) else { r.check("newTab behind", false); return finish(r, c) }
    _ = await sinks.waitReady(t4.id)
    c.closePane(t4)
    r.check("closing a tab behind the shown one keeps the shown one (cmux)", ws.panes.map(\.id) == [t3.id] && leaf?.shownTab === t3
            && ws.focusedPane === t3 && w.firstResponder === t3.surface)
    c.closePane(t3)
    r.check("closing the last tab closes the pane (here: the workspace, a fresh one opens)",
            c.model.workspaces.count == 1 && c.model.selected !== ws)

    // ------------------------------------------------------- the strip's own controls
    r.section = "tabs: strip"
    let sw = c.model.selected!
    let a = sw.panes[0]
    _ = await sinks.waitReady(a.id)
    var sa = a.view.tabStrip!
    sa.layoutSubtreeIfNeeded()
    let mid = { (b: Int) in NSPoint(x: sa.buttonRect(b).midX, y: sa.bounds.midY) }
    await click(sa, at: mid(0))
    let plus = sw.panes.last!
    r.check("the strip's first button (New Terminal): a tab in this pane", sw.panes.count == 2 && sw.root.find(a)?.tabs.count == 2
            && sw.focusedPane === plus && plus !== a)
    _ = await sinks.waitReady(plus.id)
    c.closePane(plus)
    await click(sa, at: mid(1))
    r.check("…Split Right", sw.isSplit && sw.visiblePanes.count == 2 && sw.visiblePanes.first === a)
    guard sw.visiblePanes.count == 2 else { return finish(r, c) }
    let r1 = sw.visiblePanes[1]
    _ = await sinks.waitReady(r1.id)
    let sr = r1.view.tabStrip!
    sr.layoutSubtreeIfNeeded()
    await click(sr, at: NSPoint(x: sr.buttonRect(2).midX, y: sr.bounds.midY))
    r.check("…Split Down (on the right pane's strip)", sw.visiblePanes.count == 3 && sw.focusedPane !== r1)
    guard sw.visiblePanes.count == 3 else { return finish(r, c) }
    let r2 = sw.visiblePanes[2]
    _ = await sinks.waitReady(r2.id)
    r.check("…every pane of the split has its own strip", sw.visiblePanes.allSatisfy { $0.view.tabStrip != nil && $0.view.header.isHidden })
    sa = a.view.tabStrip!  // a split makes new leaves (and strips)

    // Double-clicks: on the empty part a new tab, on a tab a zoom.
    sa.layoutSubtreeIfNeeded()
    let empty = NSPoint(x: sa.tabRect(sa.items.count - 1).maxX + 20, y: sa.bounds.midY)
    await doubleClick(sa, at: empty)
    let aLeaf = sw.root.find(a)!
    r.check("double-click on the strip's empty part: a new tab there", aLeaf.tabs.count == 2 && aLeaf.shownTab !== a, "\(aLeaf.tabs.count)")
    let a2 = aLeaf.shownTab!
    _ = await sinks.waitReady(a2.id)
    sa.layoutSubtreeIfNeeded()
    await doubleClick(sa, at: tabPoint(sa, 0))
    r.check("double-click on a tab: that tab, zoomed (cmux)", sw.zoomedPane === a && aLeaf.shownTab === a && isShown(a) && isHidden(r1))
    c.refreshTabStrips(sw)
    sa.layoutSubtreeIfNeeded()
    let zr = sa.zoomRect(0)
    r.check("…the zoomed tab shows the exit-zoom button", zr != nil && sa.zoomed)
    if let zr { await click(sa, at: NSPoint(x: zr.midX, y: zr.midY)) }
    r.check("…which ends the zoom", sw.zoomedPane == nil && isShown(r1))

    // Widths: sized to the title, 48–220 pt.
    c.renamePane(a, to: String(repeating: "Refund validation ", count: 6))
    c.renamePane(a2, to: "ok")
    c.refreshTabStrips(sw)
    r.check("a long title: the tab stops at 220 pt (the title truncates)", sa.items[0].width == 220, "\(sa.items[0].width)")
    r.check("a short one: narrower, at least 48 pt", sa.items[1].width >= 48 && sa.items[1].width < 120, "\(sa.items[1].width)")

    // The context menu: cmux's items, in its order (the ones lmux has).
    let m = c.tabMenu(for: a2)
    r.check("right-click menu: cmux's items in cmux's order", titles(m) == [
        "Rename Tab…", "Remove Custom Tab Name", "—", "Close Tab", "Close Tabs to Left", "Close Tabs to Right", "Close Other Tabs", "Move Tab",
        "Move to Left Pane", "Move to Right Pane", "—", "New Terminal Tab to Right", "—", "Zoom Pane", "Pin Tab", "Mark Tab as Unread",
    ], titles(m).joined(separator: " | "))
    r.check("…what doesn't apply is disabled (no tab to its right, no pane to its left)",
            m.item(withTitle: "Close Tabs to Right")?.isEnabled == false && m.item(withTitle: "Move to Left Pane")?.isEnabled == false
            && m.item(withTitle: "Move to Right Pane")?.isEnabled == true && m.item(withTitle: "Close Tabs to Left")?.isEnabled == true)
    r.check("…the focused tab can't be marked unread (looking at it reads it)",
            c.tabMenu(for: a).item(withTitle: "Mark Tab as Unread")?.isEnabled == false && m.item(withTitle: "Mark Tab as Unread")?.isEnabled == true)
    r.check("…with cmux's shortcuts shown", m.item(withTitle: "Rename Tab…")?.keyEquivalent == "r"
            && m.item(withTitle: "Close Other Tabs")?.keyEquivalentModifierMask == [.command, .option])
    let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: sa.convert(tabPoint(sa, 0), to: nil), modifierFlags: [],
                                        timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    r.check("…right-click on a tab opens the menu for that tab", sa.menu(for: rightClick).map(titles)?.contains("Remove Custom Tab Name") == true)
    r.check("Remove Custom Tab Name (a renamed tab): back to its own title", run(c.tabMenu(for: a), "Remove Custom Tab Name")
            && !a.titleState.isManual && !sa.items[0].title.hasPrefix("Refund"))
    r.check("New Terminal Tab to Right: right after that tab, shown", run(c.tabMenu(for: a), "New Terminal Tab to Right")
            && aLeaf.tabs.count == 3 && aLeaf.tabs[0] === a && aLeaf.tabs[2] === a2 && aLeaf.shownTab === aLeaf.tabs[1])
    let a3 = aLeaf.tabs[1]
    _ = await sinks.waitReady(a3.id)
    r.check("Mark Tab as Unread (a tab behind): its badge, the sidebar counts it", run(c.tabMenu(for: a2), "Mark Tab as Unread")
            && a2.unread == 1 && sa.items[2].badge && sw.unread == 1)
    r.check("…Mark Tab as Read: gone", run(c.tabMenu(for: a2), "Mark Tab as Read") && a2.unread == 0 && !sa.items[2].badge)

    // Pinned tabs: first in the strip, a pin instead of ×, nothing closes them.
    r.check("Pin Tab: the tab moves to the front, pinned", run(c.tabMenu(for: a2), "Pin Tab")
            && aLeaf.tabs.map(\.id) == [a2.id, a.id, a3.id] && sa.items[0].pinned && a2.pinned)
    c.selectTab(a2)
    await cmd("w", window: w)
    r.check("…⌘W on it: it stays (no card, a beep)", aLeaf.tabs.count == 3 && a2.view.overlay.card == nil)
    sa.layoutSubtreeIfNeeded()
    sa.middleClicked(at: tabPoint(sa, 0))
    r.check("…middle-click: stays", aLeaf.tabs.count == 3 && a2.view.overlay.card == nil)
    r.check("…its menu: Close Tab disabled, Unpin Tab", c.tabMenu(for: a2).item(withTitle: "Close Tab")?.isEnabled == false
            && c.tabMenu(for: a2).item(withTitle: "Unpin Tab") != nil)
    c.moveTab(a3, to: 0)
    r.check("…a tab dragged before it stops after it", aLeaf.tabs.map(\.id) == [a2.id, a3.id, a.id], aLeaf.tabs.map(\.id).joined(separator: ","))
    c.selectTab(a)
    await press("t", [.command, .option], window: w)
    r.check("⌥⌘T (Close Other Tabs): the pinned one stays out of it; one card asks for the rest (something runs)",
            a.view.overlay.card != nil && aLeaf.tabs.count == 3)
    a.view.overlay.card?.confirm.performClick()
    _ = await waitFor(2) { aLeaf.tabs.count == 2 }
    r.check("…confirmed: the pinned tab and this one are left", aLeaf.tabs.map(\.id) == [a2.id, a.id] && aLeaf.shownTab === a)
    r.check("Unpin Tab", run(c.tabMenu(for: a2), "Unpin Tab") && !a2.pinned && !sa.items[0].pinned)

    // Moving tabs between panes: the menu, then drags.
    r.check("Move to Right Pane: into the pane beside it, at the end, shown and focused", run(c.tabMenu(for: a2), "Move to Right Pane")
            && sw.root.find(r1)?.tabs.last === a2 && sw.root.find(r1)?.shownTab === a2 && sw.focusedPane === a2
            && aLeaf.tabs.map(\.id) == [a.id] && isShown(a2) && w.firstResponder === a2.surface)
    let sub = c.tabMenu(for: a2).item(withTitle: "Move Tab")?.submenu
    r.check("Move Tab ▸ Move Tab to New Workspace: a workspace of its own, right after this one, selected",
            sub.map { run($0, "Move Tab to New Workspace") } == true && c.model.selected !== sw && c.model.selected?.panes.map(\.id) == [a2.id]
            && c.model.workspaces.firstIndex { $0 === c.model.selected } == (c.model.workspaces.firstIndex { $0 === sw } ?? -9) + 1
            && sw.root.find(r1)?.tabs.map(\.id) == [r1.id] && isShown(a2))
    let lone = c.model.selected!
    let back = c.tabMenu(for: a2).item(withTitle: "Move Tab")?.submenu
    r.check("…Move Tab ▸ (the old workspace): back into its focused pane; the emptied workspace goes",
            back.map { run($0, sw.title) } == true && c.model.selected === sw && !c.model.workspaces.contains { $0 === lone }
            && sw.panes.contains { $0 === a2 } && sw.focusedPane === a2 && isShown(a2))
    r.check("…and nothing of it is left behind (selection anchor, panes, focus)", c.model.selectionAnchorID != lone.id
            && lone.panes.isEmpty && lone.focusedPane == nil && lone.zoomedPane == nil)
    guard let homeLeaf = sw.root.find(a2) else { return finish(r, c) }
    c.moveTab(a2, into: r1, at: 0)
    r.check("(setup) a2 first in the right-top pane", sw.root.find(r1)?.tabs.first === a2, "\(homeLeaf.tabs.map(\.id))")
    // Drag a2 from the right-top strip onto the left pane's strip.
    let s1 = r1.view.tabStrip ?? a2.view.tabStrip!
    s1.layoutSubtreeIfNeeded(); sa.layoutSubtreeIfNeeded()
    let onA = point(NSPoint(x: sa.tabRect(0).maxX + 30, y: sa.bounds.midY), of: sa, in: s1)
    if let hit = c.tabDrop(for: a2, at: s1.convert(onA, to: nil)), case .strip(let target, let i) = hit.0 {
        let rect = hit.1
        r.check("dragging over another pane's strip: drops there at the pointer, a line marks the slot",
                target === a && i == 1 && rect.width == 2, "\(i) \(rect)")
    } else { r.check("dragging over another pane's strip", false) }
    await click(s1, at: tabPoint(s1, 0), dragTo: onA)
    r.check("…dropped: into that pane's tabs after its tab, shown and focused", sw.root.find(a)?.tabs.map(\.id) == [a.id, a2.id]
            && sw.root.find(a)?.shownTab === a2 && sw.focusedPane === a2 && sw.root.find(r1)?.tabs.map(\.id) == [r1.id]
            && c.tabDropPreview == nil)
    // Onto the middle of the bottom-right pane: into its strip, at the end.
    let s2 = a2.view.tabStrip!
    s2.layoutSubtreeIfNeeded()
    let r2mid = point(NSPoint(x: r2.view.bounds.midX, y: r2.view.bounds.midY), of: r2.view, in: s2)
    if let hit = c.tabDrop(for: a2, at: s2.convert(r2mid, to: nil)), case .pane(let target) = hit.0 {
        let rect = hit.1
        r.check("over a pane's middle: into that pane, the whole pane highlighted", target === r2
                && abs(rect.height - r2.surface.frame.height) < 1, "\(rect)")
    } else { r.check("over a pane's middle", false) }
    await click(s2, at: tabPoint(s2, 1), dragTo: r2mid)
    r.check("…dropped: at the end of that pane's tabs, shown", sw.root.find(r2)?.tabs.map(\.id) == [r2.id, a2.id]
            && sw.root.find(r2)?.shownTab === a2 && sw.root.find(a)?.tabs.map(\.id) == [a.id])
    // Onto the right edge of the top-right pane: a split there.
    let s3 = a2.view.tabStrip!
    s3.layoutSubtreeIfNeeded()
    let r1edge = point(NSPoint(x: r1.view.bounds.maxX - 6, y: r1.view.bounds.midY), of: r1.view, in: s3)
    if let hit = c.tabDrop(for: a2, at: s3.convert(r1edge, to: nil)), case .split(let target, .right) = hit.0 {
        let rect = hit.1
        r.check("over a pane's edge (outer quarter): a split on that side, its half highlighted", target === r1
                && abs(rect.width - r1.surface.frame.width / 2) < 1, "\(rect)")
    } else { r.check("over a pane's edge", false) }
    await click(s3, at: tabPoint(s3, 1), dragTo: r1edge)
    r.check("…dropped: the pane splits, the tab on the right of it, focused", sw.visiblePanes.count == 4
            && sw.root.find(a2)?.tabs.map(\.id) == [a2.id] && sw.root.find(r2)?.tabs.map(\.id) == [r2.id] && sw.focusedPane === a2
            && (sw.visiblePanes.firstIndex { $0 === a2 } ?? 0) == (sw.visiblePanes.firstIndex { $0 === r1 } ?? -9) + 1)
    // A tab onto its own pane's edge: only with another tab left behind.
    if let tab = c.newTab(a2) {
        _ = await sinks.waitReady(tab.id)
        let s4 = tab.view.tabStrip!
        s4.layoutSubtreeIfNeeded()
        let low = point(NSPoint(x: tab.view.bounds.midX, y: tab.view.bounds.maxY - 6), of: tab.view, in: s4)
        let centre = s4.convert(point(NSPoint(x: tab.view.bounds.midX, y: tab.view.bounds.midY), of: tab.view, in: s4), to: nil)
        r.check("its own pane's middle: nothing to do", c.tabDrop(for: tab, at: centre) == nil)
        await click(s4, at: tabPoint(s4, 1), dragTo: low)
        r.check("its own pane's bottom edge: the pane splits down, the tab below, the other tab above",
                sw.visiblePanes.count == 5 && sw.root.find(tab)?.tabs.count == 1 && sw.root.find(a2)?.tabs.count == 1)
        c.closePane(tab)
    }
    c.closePane(a2)

    // Review fixes: moving a tab out of a zoomed workspace, an empty strip, a drag cut short.
    if let x = c.newTab(a, select: false) {
        _ = await sinks.waitReady(x.id)
        c.focus(r2)
        c.toggleSplitZoom()
        c.moveTabToNewWorkspace(x)
        r.check("moving a tab that isn't in the zoomed pane out of the workspace keeps the zoom", sw.zoomedPane === r2
                && c.model.selected?.panes.map(\.id) == [x.id])
        c.closeWorkspace(c.model.selected!)
        c.select(sw)
        c.toggleSplitZoom()
    }
    let bare = TabStripView(node: sw.root.find(a)!)
    r.check("a strip not filled yet: drop slot math doesn't trap (empty items)", bare.insertionIndex(at: 10) == 0 && bare.insertionX(0) == 0)
    if let y = c.newTab(a) {
        _ = await sinks.waitReady(y.id)
        let sy = y.view.tabStrip!
        sy.layoutSubtreeIfNeeded()
        let start = sy.convert(tabPoint(sy, 1), to: nil)
        let into = r2.view.convert(NSPoint(x: r2.view.bounds.midX, y: r2.view.bounds.midY), to: nil)
        for (t, loc) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, into)] {
            let e = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if t == .leftMouseDown { sy.mouseDown(with: e) } else { sy.mouseDragged(with: e) }
        }
        r.check("(setup) mid-drag over another pane: the placeholder shows", c.tabDropPreview?.superview != nil)
        let away = c.newWorkspace(cwd: "/tmp")
        r.check("…the strip leaves the window before the mouse-up (another workspace): the placeholder goes",
                c.tabDropPreview == nil && sw.root.find(y)?.tabs.contains { $0 === y } == true)
        c.closeWorkspace(away)
        c.select(sw)
        c.closePane(y)
    }
    // With the strip off, a pinned tab alone in its pane still closes (nowhere to unpin it).
    c.setTabBarWithOneTab(false)
    c.togglePin(r1)
    c.requestClosePane(r1)
    r.check("strip off: a pinned single tab still closes (⌘W asks, as for any running tab)", r1.view.overlay.card != nil)
    r1.view.overlay.card?.cancel.performClick()
    c.togglePin(r1)
    c.setTabBarWithOneTab(true)

    // Too many tabs for the pane: they scroll sideways, the shown one in view.
    var many: [Pane] = []
    for i in 0..<7 {
        if let t = c.newTab(r2) { many.append(t); c.renamePane(t, to: "A long running build number \(i)") }
    }
    for t in many { _ = await sinks.waitReady(t.id) }
    let s5 = r2.view.tabStrip ?? many.last!.view.tabStrip!
    c.refreshTabStrips(sw)
    s5.layoutSubtreeIfNeeded()
    let tw = s5.bounds.width - TabStripView.laneWidth
    let shownRect = s5.tabRect(s5.selected)
    r.check("too many tabs: the strip scrolls, the shown (last) tab in view, the buttons stay",
            s5.items.reduce(0) { $0 + $1.width } > tw && s5.scroll > 0 && shownRect.maxX <= tw + 0.5 && shownRect.minX >= 0,
            "content \(s5.items.reduce(0) { $0 + $1.width }) width \(tw) scroll \(s5.scroll) shown \(shownRect)")
    await press("1", .control, window: w)
    s5.layoutSubtreeIfNeeded()
    r.check("…⌃1: the first tab, scrolled back", sw.root.find(r2)?.shownTab === r2 && s5.scroll == 0, "\(s5.scroll)")
    for t in many { c.closePane(t) }

    // The setting: the tab bar only with two or more tabs (cmux's "multiple-tabs").
    c.setTabBarWithOneTab(false)
    r.check("setting off: a one-tab pane has no strip; split panes get their header back",
            sw.visiblePanes.allSatisfy { $0.view.tabStrip == nil } && !r1.view.header.isHidden && r1.surface.frame.minY < 30)
    let two = c.newTab(r1)
    if let two { _ = await sinks.waitReady(two.id) }
    r.check("…two tabs: the strip again", two?.view.tabStrip != nil && two.map { sw.root.find($0)?.hasStrip } == true)
    if let two { c.closePane(two) }
    c.setTabBarWithOneTab(true)
    r.check("…on again: every pane has its strip", sw.visiblePanes.allSatisfy { $0.view.tabStrip != nil } && c.settings.tabBarWithOneTab)

    // Workspaces moved to cmux's keys.
    let next = c.newWorkspace(cwd: "/tmp")
    _ = await sinks.waitReady(next.panes[0].id)
    await press("[", [.command, .control], window: w)
    r.check("⌃⌘[ (cmux): the previous workspace", c.model.selected === sw)
    await press("]", [.command, .control], window: w)
    r.check("⌃⌘] : the next one", c.model.selected === next)
    c.closeWorkspace(next)
    c.closeWorkspace(sw)

    // ------------------------------------------------------- splits + zoom
    r.section = "tabs: splits"
    let ws2 = c.model.selected!
    let a0 = ws2.panes[0]
    _ = await sinks.waitReady(a0.id)
    guard let b = c.split(a0, .right), let b2 = c.newTab(b) else { r.check("split + tab", false); return finish(r, c) }
    _ = await sinks.waitReady(b2.id)
    let rightLeaf = ws2.root.find(b)
    r.check("a tab in the right half of a split: each half has its own strip, the right one with two tabs",
            ws2.isSplit && rightLeaf?.tabs.count == 2 && rightLeaf?.shownTab === b2 && b2.view.tabStrip?.items.count == 2
            && a0.view.tabStrip?.items.count == 1 && a0.view.tabStrip !== b2.view.tabStrip)
    guard let c1 = c.split(b2, .down) else { r.check("split a tabbed pane", false); return finish(r, c) }
    _ = await sinks.waitReady(c1.id)
    let kept = ws2.root.find(b2)
    r.check("splitting a pane with tabs: its tabs stay together on its side, the new pane has one",
            kept?.tabs.map(\.id) == [b.id, b2.id] && kept?.shownTab === b2 && ws2.root.find(c1)?.tabs.count == 1
            && c1.view.tabStrip?.items.count == 1 && b2.view.tabStrip === kept?.strip)
    c.focus(b2)
    c.toggleSplitZoom()
    r.check("zoom a tabbed pane: the strip comes along", ws2.zoomedPane === b2 && b2.view.tabStrip != nil && isShown(b2) && isHidden(a0))
    if let z1 = c.newTab(b2) {
        _ = await sinks.waitReady(z1.id)
        r.check("…a new tab in the zoomed pane: the zoom follows it, focus and zoom on the same tab, on screen",
                ws2.zoomedPane === z1 && ws2.focusedPane === z1 && isShown(z1) && isHidden(b2) && w.firstResponder === z1.surface)
        c.closePane(z1)
        r.check("…closing it: the zoom goes back to the tab left", ws2.zoomedPane === b2 && ws2.focusedPane === b2 && isShown(b2))
    }
    if let z2 = c.newTab(a0) {
        _ = await sinks.waitReady(z2.id)
        r.check("…a new tab in another pane while zoomed: the zoom ends, the new tab focused on screen",
                ws2.zoomedPane == nil && ws2.focusedPane === z2 && isShown(z2) && isShown(b2) && w.firstResponder === z2.surface)
        c.closePane(z2)
    }
    c.focus(b2)
    c.toggleSplitZoom()
    await ctrlTab(window: w)
    r.check("…⌃⇥ while zoomed: the zoom follows the tab", ws2.zoomedPane === b && isShown(b) && isHidden(b2) && b.view.tabStrip != nil)
    c.toggleSplitZoom()
    await cmd("]", window: w)
    r.check("⌘] (next pane) moves between panes on screen, not tabs",
            ws2.focusedPane !== b && ws2.visiblePanes.contains { $0 === ws2.focusedPane }, ws2.focusedPane?.id ?? "-")
    c.closePane(c1)
    r.check("closing the pane next to a tabbed one keeps its tabs", ws2.root.find(b)?.tabs.map(\.id) == [b.id, b2.id])

    // ------------------------------------------------------- status across tabs
    r.section = "tabs: status"
    // ws2: [a0 | (b, b2)], b shown. A hidden tab (b2) needs input while another workspace is on screen.
    let other = c.newWorkspace(cwd: "/tmp")
    _ = await sinks.waitReady(other.panes[0].id)
    r.check("setup: another workspace selected", c.model.selected === other)
    _ = sendHook(pane: b2.id, hook("UserPromptSubmit", session: "tab-s1", #""prompt":"hi""#))
    _ = sendHook(pane: b.id, hook("UserPromptSubmit", session: "tab-s2", #""prompt":"hi""#))
    _ = sendHook(pane: b.id, hook("PreToolUse", session: "tab-s2", #""tool_name":"Bash""#))
    r.check("sidebar row: running across tabs", await waitFor { ws2.display == .running("Bash") }, "\(ws2.display)")
    _ = sendHook(pane: b2.id, hook("PermissionRequest", session: "tab-s1", #""tool_name":"Bash""#))
    r.check("…a hidden tab that needs you wins (needs you > running)", await waitFor { ws2.display == .needsInput("Permission: Bash") },
            "\(ws2.display)")
    c.refreshPaneChrome()
    c.refreshHeaders(ws2)
    let st = ws2.root.find(b2)!.strip
    r.check("…its tab gets the badge, the shown one doesn't", st.items.map(\.badge) == [false, true], "\(st.items)")
    r.check("…the hidden tab still doesn't render", isHidden(b2))
    await cmd("j", shift: true, window: w)
    r.check("⇧⌘J jumps to that tab: its workspace, the tab in front, focused", c.model.selected === ws2
            && ws2.root.find(b2)?.shownTab === b2 && ws2.focusedPane === b2 && isShown(b2) && isHidden(b) && w.firstResponder === b2.surface)
    _ = sendHook(pane: b.id, hook("Stop", session: "tab-s2", #""last_assistant_message":"done""#))
    _ = sendHook(pane: b.id, hook("PermissionRequest", session: "tab-s2", #""tool_name":"Edit""#))
    _ = await waitFor { b.needsInput }
    c.select(other)
    c.notifier.simulateClick(paneID: b.id)
    r.check("a notification opens the right tab", c.model.selected === ws2 && ws2.root.find(b)?.shownTab === b
            && ws2.focusedPane === b && isShown(b) && isHidden(b2))

    // ------------------------------------------------------------- CLI
    r.section = "tabs: cli"
    let cli = paths.binDir!.appendingPathComponent("lmux").path
    let cliEnv = ["LMUX_CONTROL_SOCKET": paths.controlSocket, "LMUX_PANE_ID": ""]
    let list = await runProcess(cli, ["list"], env: cliEnv)
    r.check("lmux list: each tab is a pane line with its place (* shown)",
            list.out.contains("pane \(b.id)  tab 1/2*") && list.out.contains("pane \(b2.id)  tab 2/2  ")
            && !list.out.contains("pane \(a0.id)  tab"), list.out + list.err)
    let json = await runProcess(cli, ["list", "--json"], env: cliEnv)
    let parsed = (try? JSONSerialization.jsonObject(with: Data(json.out.utf8))) as? [[String: Any]]
    let jpanes = parsed?.first { $0["id"] as? String == ws2.id }?["panes"] as? [[String: Any]] ?? []
    let jb = jpanes.first { $0["id"] as? String == b.id }, jb2 = jpanes.first { $0["id"] as? String == b2.id }
    r.check("lmux list --json: tab, tabs, tabShown", jb?["tab"] as? Int == 1 && jb?["tabs"] as? Int == 2 && jb?["tabShown"] as? Bool == true
            && jb2?["tab"] as? Int == 2 && jb2?["tabShown"] as? Bool == false
            && jpanes.first { $0["id"] as? String == a0.id }?["tab"] == nil, json.out.prefix(400) + json.err)
    let nt = await runProcess(cli, ["new-tab", "--pane", a0.id, "--background", "--cmd", "echo tabbed"], env: cliEnv)
    let newID = nt.out.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    let made = c.pane(id: newID)
    r.check("lmux new-tab --pane --background: a tab behind in that pane", nt.status == 0 && made != nil
            && ws2.root.find(a0)?.tabs.map(\.id) == [a0.id, newID] && ws2.root.find(a0)?.shownTab === a0 && made.map(isHidden) == true,
            nt.out + nt.err)
    r.check("…types its command", await sinks.wait(newID, contains: "echo tabbed", timeout: 5), sinks.text(newID))
    let bad = await runProcess(cli, ["new-tab", "--pane", "nope"], env: cliEnv)
    r.check("lmux new-tab into an unknown pane fails", bad.status != 0 && bad.err.contains("no such pane"), bad.err)
    let send = await runProcess(cli, ["send", "--pane", newID, #"hidden\n"#], env: cliEnv)
    let arrived = await sinks.wait(newID, contains: "hidden\r")
    r.check("lmux send targets a hidden tab by its pane id", send.status == 0 && arrived, send.err)

    // ------------------------------------------------------------- persistence
    r.section = "tabs: layout.json"
    c.togglePin(made!)
    let file = c.snapshotLayout()
    let n = file.workspaces.first { $0.id == ws2.id }?.root
    let tabsLeaf = n?.children?[1]
    r.check("tabs saved per leaf with the selected one; the shown tab is also `pane` (older lmux opens it)",
            tabsLeaf?.tabs?.map(\.id) == [b.id, b2.id] && tabsLeaf?.selectedTab == 0 && tabsLeaf?.pane?.id == b.id
            && n?.children?[0].tabs?.map(\.id) == [newID, a0.id], "\(String(describing: n))")
    r.check("…a pinned tab saves as pinned (first), the others without the key",
            n?.children?[0].tabs?.map(\.pinned) == [true, nil] && n?.children?[0].selectedTab == 1)
    r.check("a pane without tabs saves as before (no tabs key)", file.workspaces.first { $0.id == other.id }?.root.tabs == nil)
    let enc = try! JSONEncoder().encode(file)
    r.check("round trip through JSON", (try? JSONDecoder().decode(LayoutFile.self, from: enc)) == file)
    let old = #"{"version":1,"workspaces":[{"id":"w","accent":0,"root":{"pane":{"id":"old-1","cwd":"/tmp"}}}]}"#
    let oldFile = try? JSONDecoder().decode(LayoutFile.self, from: Data(old.utf8))
    r.check("an old layout (no tabs) reads as one tab", oldFile?.workspaces.first?.root.leafPanes.map(\.id) == ["old-1"])
    // A leaf with tabs restores as tabs (built in this process: the relaunch is --pane-tabs-restore).
    if let built = c.buildNode(LayoutFile.NodeState(pane: .init(id: "nt-2", cwd: "/tmp"),
                                                     tabs: [.init(id: "nt-1", cwd: "/tmp"), .init(id: "nt-2", cwd: "/tmp")], selectedTab: 1)) {
        r.check("…buildNode: 2 tabs, the selected one shown", built.tabs.map(\.id) == ["nt-1", "nt-2"] && built.shownTab?.id == "nt-2")
        for p in built.tabs { c.discard(p) }
    } else { r.check("…buildNode", false) }
    var pin = LayoutFile.PaneState(id: "np-2", cwd: "/tmp")
    pin.pinned = true
    if let built = c.buildNode(LayoutFile.NodeState(pane: .init(id: "np-1", cwd: "/tmp"),
                                                     tabs: [.init(id: "np-1", cwd: "/tmp"), pin], selectedTab: 0)) {
        r.check("…a pinned tab saved behind an unpinned one restores first, the shown one still shown",
                built.tabs.map(\.id) == ["np-2", "np-1"] && built.shownTab?.id == "np-1" && built.pinnedCount == 1)
        for p in built.tabs { c.discard(p) }
    } else { r.check("…buildNode pinned", false) }

    // For the relaunch: ws2's hidden tab b2 runs a Claude session that should resume.
    let sid = "6f1f0b5e-7a3c-4c47-9d0e-2a7d3c1b9e40"
    b2.claudeSessionID = sid
    b2.resumeCommand = "claude --resume \(sid)"
    c.select(ws2)
    c.selectTab(b)
    c.saveNow()
    let expect: [String: Any] = ["ws": ws2.id, "b": b.id, "a2": b2.id, "a": a0.id, "new": newID, "sid": sid]
    try? JSONSerialization.data(withJSONObject: expect).write(to: paths.stateDir.appendingPathComponent("tabs-expect.json"))
    return finish(r, c)
}

@MainActor
func runPaneTabsRestore() async -> Int32 {
    let r = Report()
    r.section = "tabs: relaunch"
    guard let d = try? Data(contentsOf: paths.stateDir.appendingPathComponent("tabs-expect.json")),
          let e = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
        print("FAIL  [tabs: relaunch] no expectations from --pane-tabs"); return 1
    }
    let c = makeController()
    let ws = c.model.workspaces.first { $0.id == e["ws"] }
    let b = c.pane(id: e["b"]!), a2 = c.pane(id: e["a2"]!), a = c.pane(id: e["a"]!), nt = c.pane(id: e["new"]!)
    let leaf = b.flatMap { ws?.root.find($0) }
    r.check("relaunch: the tabs come back per pane, in order, the selected one shown",
            leaf?.tabs.map(\.id) == [e["b"]!, e["a2"]!] && leaf?.shownTab === b
            && a.flatMap { ws?.root.find($0) }?.tabs.map(\.id) == [e["new"]!, e["a"]!], "\(leaf?.tabs.map(\.id) ?? [])")
    r.check("…the pinned tab is still pinned", nt?.pinned == true && a?.pinned == false)
    r.check("…shown tabs render, hidden ones don't", c.model.selected === ws && b.map(isShown) == true && a2.map(isHidden) == true
            && nt.map(isHidden) == true && b?.view.tabStrip != nil)
    let resumed = await sinks.wait(e["a2"]!, contains: "claude --resume \(e["sid"]!)", timeout: 5)
    r.check("…the hidden tab's Claude session resumes", resumed && a2?.claudeSessionID == e["sid"], sinks.text(e["a2"]!))
    return finish(r, c)
}
