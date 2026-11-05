import AppKit
import Observation
import LmuxTokens
@testable import LmuxUI

// `lmux-apptest --zoom-clear-reorder`: split zoom (⇧⌘↩ / menu / Ghostty action), the row's manual
// "Clear Status", and sidebar drag-to-reorder (press-and-drag, multi-selection, Esc, persistence).

/// A sidebar row drag: mouse down on row `from`, dragged to `to`, released. Mirrors `click()`'s
/// down/dragged/up sequence (Harness.swift) but is kept local since the cancel test below needs
/// the down+dragged half without the up.
@MainActor
func dragRow(_ host: NSView, from: NSPoint, to: NSPoint, modifiers: NSEvent.ModifierFlags = []) async {
    await click(host, at: from, dragTo: to, modifiers: modifiers)
}

/// Mouse down on `from`, dragged to `to`, with no mouse up (the cancel test below ends the
/// sequence with Esc instead): the same event construction as `click()` (Harness.swift), just
/// without its final `leftMouseUp`.
@MainActor
func dragBegin(_ view: NSView, from: NSPoint, to: NSPoint) async {
    guard let window = view.window else { return }
    for (type, p) in [(NSEvent.EventType.leftMouseDown, from), (.leftMouseDragged, to)] {
        let loc = view.convert(p, to: nil)
        let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(e, atStart: true)
        if let ev = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
                                    until: .distantPast, inMode: .default, dequeue: true), ev.type == type {
            window.sendEvent(ev)
        } else {
            window.sendEvent(e)
        }
        await sleepMs(30)
    }
    await sleepMs(120)
}

/// Ends a `dragBegin` sequence that wasn't already ended by Esc / a commit (`type: .leftMouseDragged`:
/// the pointer moves on instead, still pressed).
@MainActor
func mouseUp(_ view: NSView, at p: NSPoint, type: NSEvent.EventType = .leftMouseUp) async {
    guard let window = view.window else { return }
    let loc = view.convert(p, to: nil)
    let e = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    NSApp.postEvent(e, atStart: true)
    if let ev = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
                                until: .distantPast, inMode: .default, dequeue: true), ev.type == type {
        window.sendEvent(ev)
    } else {
        window.sendEvent(e)
    }
    await sleepMs(120)
}

/// ⇧⌘↩ (Return, keyCode 36), the real key path (through `window.performKeyEquivalent`, same as
/// `cmd()` for ⌘D etc.), so the test exercises Ghostty's `toggle_split_zoom` binding, not just the
/// Swift method.
@MainActor
func cmdShiftReturn(window: NSWindow) async {
    let ts = ProcessInfo.processInfo.systemUptime
    for t in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [.command, .shift], timestamp: ts,
                                 windowNumber: window.windowNumber, context: nil, characters: "\r",
                                 charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        dispatchKey(e, window: window)
    }
    await sleepMs(150)
}

/// Fresh workspaces titled A, B, C, …, idle shells, the first selected (mirrors Sidebar.swift's
/// `stage`, kept local: each apptest file is self-contained).
@MainActor
func stageWorkspaces(_ c: LmuxController, _ titles: [String]) async -> [Workspace] {
    let old = c.model.workspaces
    var made: [Workspace] = []
    for t in titles {
        let ws = c.newWorkspace(cwd: "/tmp", select: false)
        ws.customTitle = t
        made.append(ws)
    }
    for o in old { c.closeWorkspace(o) }
    c.model.workspaces = made
    c.select(made[0])
    c.model.selection = []
    _ = await waitFor(10) { made.flatMap(\.panes).allSatisfy { $0.surface.foregroundPID > 0 } }
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    await sleepMs(200)
    return made
}

@MainActor
func runZoomClearReorder() async -> Int32 {
    let r = Report()
    let c = makeController()
    let w = c.window!

    // ------------------------------------------------------------- split zoom
    r.section = "split zoom"
    let ws = c.model.selected!
    let p1 = ws.panes[0]
    _ = await sinks.waitReady(p1.id)
    guard let p2 = c.split(p1, .right) else { r.check("split", false); return finish(r, c) }
    _ = await waitFor(5) { p2.surface.foregroundPID > 0 }
    r.check("split right: two panes, the new one focused", ws.panes.count == 2 && ws.focusedPane === p2)
    c.validateMenuItem(c.splitZoomMenuItem!)
    r.check("menu starts \"Zoom Split\"", c.splitZoomMenuItem?.title == "Zoom Split", c.splitZoomMenuItem?.title ?? "nil")

    c.toggleSplitZoom()
    r.check("⌘-method zooms the focused pane", ws.zoomedPane === p2 && ws.isZoomed)
    r.check("…the other pane is out of the window and stops rendering", p1.surface.window == nil && !p1.surface.occlusionVisible)
    r.check("…the zoomed pane renders", p2.surface.window != nil && p2.surface.occlusionVisible)
    c.validateMenuItem(c.splitZoomMenuItem!)
    r.check("menu flips to \"Unzoom Split\"", c.splitZoomMenuItem?.title == "Unzoom Split", c.splitZoomMenuItem?.title ?? "nil")
    c.menuToggleSplitZoom(nil)
    r.check("the menu action unzooms back", !ws.isZoomed && p1.surface.window != nil && p2.surface.window != nil)

    await cmdShiftReturn(window: w)
    r.check("⇧⌘↩ (the real key path, Ghostty's toggle_split_zoom) zooms", ws.isZoomed && ws.zoomedPane === p2)
    await cmdShiftReturn(window: w)
    r.check("⇧⌘↩ again unzooms", !ws.isZoomed)

    c.toggleSplitZoom()
    r.check("zoomed again", ws.isZoomed)
    c.closePane(p2)
    r.check("closing the zoomed pane unzooms first, then closes it normally", !ws.isZoomed && ws.panes.count == 1)

    guard let p3 = c.split(ws.panes[0], .down) else { r.check("re-split", false); return finish(r, c) }
    _ = await waitFor(5) { p3.surface.foregroundPID > 0 }
    c.toggleSplitZoom()
    r.check("zoomed again (2 panes)", ws.isZoomed)
    _ = c.split(ws.focusedPane!, .right)
    r.check("splitting while zoomed unzooms first, then splits as normal (3 panes, all visible)",
            !ws.isZoomed && ws.panes.count == 3 && ws.panes.allSatisfy { $0.surface.occlusionVisible })

    r.check("without a split, the shortcut is a no-op", {
        let solo = c.newWorkspace(select: true)
        return !solo.isSplit && { c.toggleSplitZoom(); return !solo.isZoomed }()
    }())

    // ------------------------------------------------------------- focus while zoomed
    // Focusing a pane that isn't the zoomed one unzooms first (Ghostty's behavior), on every path.
    r.section = "zoom + focus"
    let zw = c.newWorkspace(select: true)
    let za = zw.panes[0]
    _ = await waitFor(5) { za.surface.foregroundPID > 0 }
    guard let zb = c.split(za, .right) else { r.check("split", false); return finish(r, c) }
    _ = await waitFor(5) { zb.surface.foregroundPID > 0 }
    func zoomOnA() -> Bool { c.focus(za); c.toggleSplitZoom(); return zw.zoomedPane === za && zb.surface.window == nil }
    func unzoomedOnB() -> Bool {
        !zw.isZoomed && zw.focusedPane === zb && zb.surface.window != nil && zb.surface.occlusionVisible
            && firstResponderPane(c) === zb
    }
    r.check("zoomed on A", zoomOnA())
    c.focus(za)
    r.check("focusing the zoomed pane itself keeps the zoom", zw.zoomedPane === za)
    await cmd("]", window: w)
    r.check("⌘] (goto_split:next) to B unzooms and focuses B", unzoomedOnB(), "zoomed=\(zw.isZoomed)")
    r.check("zoomed on A again", zoomOnA())
    zb.unread = 1; zb.lastAlertAt = Date()
    c.jumpToLatestUnread()
    r.check("⇧⌘U (jump to latest unread) to B unzooms", unzoomedOnB())
    r.check("zoomed on A again", zoomOnA())
    hookEvent(c, zb, "SessionStart", session: "zoomfocus")
    hookEvent(c, zb, "PermissionRequest", session: "zoomfocus", ["tool_name": "Bash"])
    _ = await waitFor(2) { zb.needsInput }
    c.jumpToNextNeedsInput()
    r.check("⇧⌘J (next needs input) to B unzooms", zb.needsInput && unzoomedOnB())
    r.check("zoomed on A again", zoomOnA())
    c.notifier.simulateClick(paneID: zb.id)
    r.check("a system notification click for B unzooms", unzoomedOnB())
    r.check("zoomed on A again", zoomOnA())
    c.openNotification(NotificationEntry(paneID: zb.id, workspaceID: zw.id, title: "t", message: "m", kind: "notify", read: false))
    r.check("a bell-list row for B unzooms", unzoomedOnB())
    r.check("zoomed on A again", zoomOnA())
    c.surfaceDidFocus(zb)
    r.check("B's surface taking focus (surfaceDidFocus) unzooms", unzoomedOnB())
    r.check("zoomed on A again", zoomOnA())
    let other = c.newWorkspace(select: true)
    c.focus(zb)
    r.check("focusing B from another workspace selects it unzoomed", c.model.selected === zw && unzoomedOnB())
    c.closeWorkspace(other)

    // Hiding and showing the window while zoomed keeps the hidden pane occluded.
    r.check("zoomed on A again", zoomOnA())
    c.windowShownOverride = false
    c.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: w))
    r.check("window hidden: nothing renders", !za.surface.occlusionVisible && !zb.surface.occlusionVisible)
    c.windowShownOverride = nil
    c.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: w))
    r.check("shown again while zoomed: A renders, the hidden B stays occluded",
            za.surface.occlusionVisible && !zb.surface.occlusionVisible)
    c.toggleSplitZoom()
    r.check("unzoomed: both render", za.surface.occlusionVisible && zb.surface.occlusionVisible)

    // ------------------------------------------------------------- clear status
    r.section = "clear status"
    let cws = await stageWorkspaces(c, ["A", "B", "C"])
    let a = cws[0].panes[0], b = cws[1].panes[0]
    hookEvent(c, a, "SessionStart", session: "clear-1")
    hookEvent(c, a, "UserPromptSubmit", session: "clear-1", ["prompt": "do a thing"])
    hookEvent(c, a, "PermissionRequest", session: "clear-1", ["tool_name": "Bash"])
    _ = await waitFor(2) { a.needsInput }
    r.check("A needs input (a real hook-driven state)", a.needsInput && a.display.priority > 0)
    c.select(cws[1])  // A isn't the one on screen: its unread count is nonzero too
    _ = await waitFor(2) { a.unread > 0 }
    c.clearStatus(for: cws[0])
    r.check("Clear Status: idle, no badge, no ring, agent process untouched",
            cws[0].display == .idle && a.unread == 0 && !a.showsRing && a.claudeSessionID == "clear-1",
            "\(cws[0].display) unread=\(a.unread) session=\(a.claudeSessionID ?? "nil")")
    hookEvent(c, a, "PermissionRequest", session: "clear-1", ["tool_name": "Write"])
    _ = await waitFor(2) { a.needsInput }
    r.check("the next hook event updates it again", a.needsInput)

    // Multi-selection: the row menu item clears every selected row.
    hookEvent(c, b, "SessionStart", session: "clear-2")
    hookEvent(c, b, "UserPromptSubmit", session: "clear-2", ["prompt": "x"])
    hookEvent(c, b, "PermissionRequest", session: "clear-2", ["tool_name": "Bash"])
    _ = await waitFor(2) { b.needsInput }
    c.setSelection(Set([cws[0].id, cws[1].id]), anchor: cws[0].id)
    let menu = c.rowMenu(for: cws[0])
    menu.compactMap { $0 }.first { $0.title == "Clear Status" }?.run()
    r.check("Clear Status from the row menu, with a multi-selection, clears every selected row",
            !a.needsInput && !b.needsInput, "A \(a.display) B \(b.display)")

    // ------------------------------------------------------------- sidebar drag-to-reorder
    r.section = "sidebar drag"
    let host = c.root.sidebarHost
    func titles() -> String { c.model.workspaces.map(\.title).joined() }

    _ = await stageWorkspaces(c, ["A", "B", "C", "D", "E"])
    let past = NSPoint(x: rowPoint(c, 4).x, y: rowPoint(c, 4).y + 400)
    await dragRow(host, from: rowPoint(c, 0), to: past)
    _ = await waitFor(2) { titles() != "ABCDE" }
    r.check("drag A past the others: it lands at the end", titles() == "BCDEA", titles())
    r.check("…the drag ends cleanly", c.model.sidebarDrag == nil)

    // A drag over the middle: the slot follows the dragged row (a neighbor gives way once the row is
    // halfway over it), the rows in between slide up while the dragged one follows the pointer.
    _ = await stageWorkspaces(c, ["A", "B", "C", "D", "E"])
    let ids = c.model.workspaces.map(\.id)
    await dragBegin(host, from: rowPoint(c, 0), to: rowPoint(c, 2))
    _ = await waitFor(2) { c.model.sidebarDrag != nil }
    let rowStep = abs(rowPoint(c, 0).y - rowPoint(c, 1).y)
    r.check("dragged two rows down: its slot is after C", c.model.sidebarDrag?.dropIndex == 2,
            "\(String(describing: c.model.sidebarDrag))")
    r.check("…the pointer is tracked on its own (the row follows it)",
            abs((c.model.sidebarDragPointer?.translation ?? 0) - 2 * rowStep) < 1, "\(String(describing: c.model.sidebarDragPointer))")
    if let drag = c.model.sidebarDrag {
        let frames = c.root.sidebarHost.rootView.rowFrames.frames
        let shifts = SidebarDragGeometry(order: ids, moving: Set(drag.ids), frames: frames)
            .offsets(grabbed: drag.grabbedID, dropIndex: drag.dropIndex)
        r.check("…B and C slide up one row, D and E stay, A's slot is its own spot",
                abs((shifts[ids[1]] ?? 0) + rowStep) < 1 && abs((shifts[ids[2]] ?? 0) + rowStep) < 1
                    && shifts[ids[3]] == 0 && shifts[ids[4]] == 0 && shifts[ids[0]] == 0, "\(shifts) step \(rowStep)")
        // A move inside the slot changes the pointer only: nothing that re-lays out the rows.
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { _ = c.model.sidebarDrag } onChange: { flag.fired = true }
        let p = c.model.sidebarDragPointer!
        c.sidebarDragUpdate(c.model.workspaces[0], dropIndex: drag.dropIndex, pointerY: p.y + 3, translation: p.translation + 3)
        r.check("…a move within the slot doesn't touch the drag state the rows read", !flag.fired
                    && c.model.sidebarDragPointer?.translation == p.translation + 3)
    }
    await type("\u{1b}", window: w)
    r.check("Esc mid-list: order kept, drag and pointer cleared",
            titles() == "ABCDE" && c.model.sidebarDrag == nil && c.model.sidebarDragPointer == nil, titles())
    await mouseUp(host, at: rowPoint(c, 2))
    await sleepMs(100)
    await dragRow(host, from: rowPoint(c, 0), to: rowPoint(c, 2))
    _ = await waitFor(2) { titles() != "ABCDE" }
    r.check("dropped there: A lands after C", titles() == "BCADE" && c.model.sidebarDragPointer == nil, titles())
    await dragRow(host, from: rowPoint(c, 2), to: NSPoint(x: rowPoint(c, 2).x, y: rowPoint(c, 2).y + rowStep * 0.4))
    await sleepMs(100)
    r.check("less than halfway over a neighbor: stays put", titles() == "BCADE", titles())
    // The drop's spring settles and nothing keeps running: no per-frame work once the drag is over.
    await sleepMs(500)
    let after = await idleCost(4)
    print(String(format: "INFO  [sidebar drag] after drops and Esc: idle CPU %.2f%% over 4s, CVDisplayLink: %@", after.cpu, after.links.text))
    r.check(String(format: "after a drag, idle CPU < 1%% (%.2f%%)", after.cpu), after.cpu < 1.0)
    r.check("…no CVDisplayLink kept running (\(after.links.text))", !after.links.kept)

    // The drag geometry itself: one block per drag (a multi-selection closes up behind the grabbed row).
    let g = SidebarDragGeometry(order: ["a", "b", "c", "d"], moving: ["b", "d"],
                                frames: Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].enumerated().map {
                                    ($1, CGRect(x: 0, y: CGFloat($0) * 38, width: 200, height: 34)) }), gap: 4)
    r.check("geometry: no movement keeps the grabbed row's slot", g.dropIndex(grabbed: "b", translation: 0) == 1)
    r.check("geometry: past half a row up, the slot moves up", g.dropIndex(grabbed: "b", translation: -20) == 0
                && g.dropIndex(grabbed: "b", translation: -18) == 1)
    let go = g.offsets(grabbed: "d", dropIndex: 0)
    r.check("geometry: B closes up above D, the rest make room for both", go["b"] == 38 && go["d"] == 0
                && go["a"] == 76 && go["c"] == 38, "\(go)")

    let rows = await stageWorkspaces(c, ["A", "B", "C", "D", "E"])
    await click(host, at: rowPoint(c, 1))  // plain click: just B
    await click(host, at: rowPoint(c, 3), modifiers: .command)  // ⌘-click adds D: B + D selected
    r.check("B and D selected", c.model.selection == Set([rows[1].id, rows[3].id]), "\(c.model.selection)")
    let before = NSPoint(x: rowPoint(c, 0).x, y: rowPoint(c, 0).y - 400)
    await dragRow(host, from: rowPoint(c, 3), to: before, modifiers: .command)  // drag D (in the selection)
    _ = await waitFor(2) { titles() != "ABCDE" }
    r.check("dragging a row inside the multi-selection moves the whole selection, order kept (B before D)",
            titles() == "BDACE", titles())

    _ = await stageWorkspaces(c, ["A", "B", "C", "D", "E"])
    await dragBegin(host, from: rowPoint(c, 0), to: past)
    _ = await waitFor(2) { c.model.sidebarDrag != nil }
    r.check("a drag past the threshold is tracked", c.model.sidebarDrag != nil, "\(String(describing: c.model.sidebarDrag))")
    await type("\u{1b}", window: w)
    r.check("Esc cancels: no reorder", titles() == "ABCDE" && c.model.sidebarDrag == nil, titles())
    await mouseUp(host, at: past)  // let AppKit's own tracking end cleanly
    await sleepMs(100)
    r.check("…the stray mouse-up after Esc doesn't reorder either", titles() == "ABCDE", titles())

    // Esc is sticky for the rest of that press: moving on doesn't restart the drag, the mouse-up doesn't commit.
    _ = await stageWorkspaces(c, ["A", "B", "C", "D", "E"])
    await dragBegin(host, from: rowPoint(c, 0), to: past)
    _ = await waitFor(2) { c.model.sidebarDrag != nil }
    await type("\u{1b}", window: w)
    await mouseUp(host, at: NSPoint(x: past.x, y: past.y - 30), type: .leftMouseDragged)
    await mouseUp(host, at: past, type: .leftMouseDragged)
    r.check("after Esc, moving the pointer on doesn't start the drag again", c.model.sidebarDrag == nil,
            "\(String(describing: c.model.sidebarDrag))")
    await mouseUp(host, at: past)
    r.check("…and its mouse-up doesn't reorder", titles() == "ABCDE", titles())
    await dragRow(host, from: rowPoint(c, 0), to: past)
    _ = await waitFor(2) { titles() != "ABCDE" }
    r.check("the next press-and-drag works again", titles() == "BCDEA", titles())

    // ⌃⌘S mid-drag: the row's gone, the drag with it; Esc goes back to the pane (it stops Claude).
    _ = await stageWorkspaces(c, ["A", "B", "C", "D", "E"])
    let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, characters: "\u{1b}",
                               charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 0x35)!
    await dragBegin(host, from: rowPoint(c, 0), to: past)
    _ = await waitFor(2) { c.model.sidebarDrag != nil }
    c.toggleSidebar()
    r.check("hiding the sidebar mid-drag ends the drag", c.model.sidebarDrag == nil && !c.model.sidebarVisible)
    r.check("…and Esc is the pane's again (not swallowed)", !c.handleSidebarKey(esc))
    await mouseUp(c.root.content, at: NSPoint(x: 50, y: 50))
    c.toggleSidebar()
    r.check("…no reorder", titles() == "ABCDE", titles())
    // A drag whose row never saw the mouse-up (it went elsewhere) ends with the press.
    c.model.sidebarDrag = AppModel.SidebarDrag(ids: [c.model.workspaces[0].id], grabbedID: c.model.workspaces[0].id, dropIndex: 3)
    await mouseUp(c.root.content, at: NSPoint(x: 50, y: 50))
    r.check("a stray drag ends at the window's mouse-up", c.model.sidebarDrag == nil && titles() == "ABCDE", titles())
    r.check("…Esc reaches the pane", !c.handleSidebarKey(esc))

    // Persists in layout.json; ⌘1-⌘8 follow the new order without anything extra.
    let staged = await stageWorkspaces(c, ["A", "B", "C", "D"])
    await dragRow(host, from: rowPoint(c, 0), to: NSPoint(x: rowPoint(c, 3).x, y: rowPoint(c, 3).y + 400))
    _ = await waitFor(2) { titles() != "ABCD" }
    let order = titles()
    await cmd("1", window: w)
    r.check("⌘1 follows the new order", c.model.selected?.title == String(order.first!), c.model.selected?.title ?? "nil")
    // A split zoom survives the relaunch too: the selected workspace zoomed on its first pane (not
    // the split's newer one), and a hidden workspace zoomed on its second.
    let zsel = c.model.selected!, zbg = staged.first { $0 !== zsel }!
    let zLeft = zsel.panes[0]
    guard let zRight = c.split(zLeft, .right), let zbgRight = c.split(zbg.panes[0], .down) else {
        r.check("split for the zoom restore", false)
        return finish(r, c)
    }
    _ = await waitFor(5) { zRight.surface.foregroundPID > 0 && zbgRight.surface.foregroundPID > 0 }
    c.focus(zLeft)
    c.toggleSplitZoom()
    c.toggleSplitZoom(zbg)
    r.check("(setup) zoomed: the selected workspace on its first pane, a hidden one on its second",
            zsel.zoomedPane === zLeft && zbg.zoomedPane === zbgRight && c.model.selected === zsel)
    c.saveNow()
    guard let data = try? Data(contentsOf: c.paths.layoutFile), let saved = try? JSONDecoder().decode(LayoutFile.self, from: data) else {
        r.check("layout.json readable", false)
        return finish(r, c)
    }
    let savedTitles = saved.workspaces.compactMap(\.customTitle).joined()
    r.check("the order is in layout.json", savedTitles == order, "\(savedTitles) vs \(order)")

    c.shutdown()
    let c2 = makeController()
    r.check("relaunch (a fresh controller over the same state dir) restores the same order",
            c2.model.workspaces.map(\.title).joined() == order, c2.model.workspaces.map(\.title).joined())
    let rsel = c2.model.workspaces.first { $0.id == zsel.id }, rbg = c2.model.workspaces.first { $0.id == zbg.id }
    let rLeft = rsel?.panes.first { $0.id == zLeft.id }, rRight = rsel?.panes.first { $0.id == zRight.id }
    r.check("…the selected workspace comes back zoomed on the same pane, focused (first responder)",
            rsel != nil && rsel === c2.model.selected && rLeft != nil && rsel?.zoomedPane === rLeft
                && rsel?.focusedPane === rLeft && firstResponderPane(c2) === rLeft,
            "zoomed=\(rsel?.zoomedPane?.id ?? "nil") focused=\(rsel?.focusedPane?.id ?? "nil")")
    r.check("…only the zoomed pane renders, the other stays out of the window",
            rLeft?.surface.window != nil && rLeft?.surface.occlusionVisible == true
                && rRight?.surface.window == nil && rRight?.surface.occlusionVisible == false)
    r.check("…the hidden workspace keeps its zoom (on its second pane)",
            rbg?.zoomedPane != nil && rbg?.zoomedPane?.id == zbgRight.id && rbg?.focusedPane === rbg?.zoomedPane)
    c2.select(rbg!)
    r.check("…and shows it zoomed when selected", rbg?.zoomedPane?.surface.window != nil
                && rbg?.panes.filter { $0.surface.window != nil }.count == 1)
    c2.saveNow()

    // A zoom on a pane that isn't in the layout any more (edited, or an older lmux's) is ignored.
    c2.shutdown()
    if let d = try? Data(contentsOf: c2.paths.layoutFile), var f = try? JSONDecoder().decode(LayoutFile.self, from: d) {
        for i in f.workspaces.indices where f.workspaces[i].zoomedPane != nil { f.workspaces[i].zoomedPane = "no-such-pane" }
        try? JSONEncoder().encode(f).write(to: c2.paths.layoutFile)
    }
    let c3 = makeController()
    r.check("a stale zoomedPane is ignored: the layout loads whole, unzoomed",
            c3.model.workspaces.map(\.title).joined() == order && c3.model.workspaces.allSatisfy { !$0.isZoomed }
                && c3.model.workspaces.first { $0.id == zsel.id }?.panes.count == 2,
            c3.model.workspaces.map(\.title).joined())
    return finish(r, c3)
}
