import AppKit
import LmuxTokens
import SwiftUI
@testable import LmuxUI

// `lmux-apptest --sidebar`: the row × on hover and the Finder-style multi-selection (⌘-click,
// ⇧-click), closing one row, a selection, idle shells and busy panes, headless. Panes run the
// isolated zsh (apptest.sh passes it as LMUX_PANE_COMMAND); busy rows run `sleep`.

/// Where the row × of `ws` sits (when hovered), in sidebar host coordinates: line 1's trailing
/// slot. (SwiftUI builds no accessibility tree without an assistive client, so this is geometry;
/// clicks and pixels below prove the button is there.)
@MainActor
func closeButtonRect(_ c: LmuxController, _ ws: Workspace) -> NSRect {
    let host = c.root.sidebarHost
    let i = c.model.workspaces.firstIndex { $0 === ws } ?? 0
    let two = ws.showsStateLine
    let h = two ? LmuxTokens.Layout.workspaceRowHeightDouble : LmuxTokens.Layout.workspaceRowHeightSingle
    let s = LmuxTokens.Layout.rowCloseButtonSize
    let center = rowPoint(c, i).y
    let fromTop = (host.isFlipped ? center : host.bounds.height - center) - h / 2 + WorkspaceRow.closeTop(two)
    let y = host.isFlipped ? fromTop : host.bounds.height - fromTop - s
    return NSRect(x: host.bounds.width - WorkspaceRow.closeTrailing - s, y: y, width: s, height: s)
}

/// The sidebar's pixels in `rect` (host coordinates).
@MainActor
func sidebarPixels(_ c: LmuxController, _ rect: NSRect) -> Data? {
    let host = c.root.sidebarHost
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
    host.cacheDisplay(in: rect, to: rep)
    return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) }
}

/// A SwiftUI view rendered offscreen (never shown) as raw RGBA bytes.
@MainActor
func renderBytes<V: View>(_ view: V, size: NSSize, dark: Bool) -> Data? {
    let v = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    v.frame = NSRect(origin: .zero, size: size)
    let holder = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    holder.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    holder.contentView = v
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    return rep.bitmapData.map { Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh) }
}

@MainActor
func runSidebar() async -> Int32 {
    let r = Report()
    let c = makeController()
    let w = c.window!
    let host = c.root.sidebarHost
    var activations: [String] = []   // (sections in which the app became active, for a failed check)
    let actObs = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { activations.append(r.section) }
    }
    _ = actObs
    let busyScript = paths.stateDir.appendingPathComponent("busy.sh")
    try? "#!/bin/sh\nexec /bin/sleep 600\n".write(to: busyScript, atomically: true, encoding: .utf8)
    chmod(busyScript.path, 0o755)

    /// Rows titled A, B, C, … (idle shells), `busy` ones running sleep; the first selected.
    func stage(_ titles: [String], busy: Set<String> = []) async -> [Workspace] {
        let old = c.model.workspaces
        var made: [Workspace] = []
        for t in titles {
            let ws = c.newWorkspace(cwd: "/tmp", select: false, program: busy.contains(t) ? busyScript.path : nil)
            ws.customTitle = t
            made.append(ws)
        }
        for o in old { c.closeWorkspace(o) }
        c.model.workspaces = made
        c.select(made[0])
        c.model.hoveredRowID = nil
        _ = await waitFor(10) {
            made.flatMap(\.panes).allSatisfy { p in
                let busyRow = busy.contains(p.workspace?.customTitle ?? "")
                return p.surface.foregroundPID > 0 && (busyRow ? c.runningProcess(p) == "sleep" : c.runningProcess(p) == nil)
            }
        }
        host.layoutSubtreeIfNeeded()
        await sleepMs(200)
        return made
    }
    func idx(_ ws: Workspace) -> Int { c.model.workspaces.firstIndex { $0 === ws } ?? -1 }
    func titles() -> String { c.model.workspaces.map(\.title).joined() }
    /// Point the pointer at row i: a mouse-moved event through the window (the tracking area),
    /// or, when AppKit doesn't route a synthesized move to SwiftUI, the row's onHover state directly.
    var hoverByEvent = false
    func hover(_ ws: Workspace?) async {
        if let ws {
            let p = host.convert(rowPoint(c, idx(ws)), to: nil)
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                w.sendEvent(e)
            }
            await sleepMs(60)
            if c.model.hoveredRowID == ws.id { hoverByEvent = true } else { c.model.hoveredRowID = ws.id }
        } else {
            c.model.hoveredRowID = nil
        }
        host.layoutSubtreeIfNeeded()
        await sleepMs(150)
    }
    func clickClose(_ ws: Workspace) async -> Bool {
        await hover(ws)
        let f = closeButtonRect(c, ws)
        await click(host, at: NSPoint(x: f.midX, y: f.midY))
        return true
    }
    /// The × is drawn: the slot's pixels differ hovered vs not.
    func xDrawn(_ ws: Workspace) async -> Bool {
        let f = closeButtonRect(c, ws)
        let was = c.model.hoveredRowID
        c.model.hoveredRowID = nil; await sleepMs(120)
        let off = sidebarPixels(c, f)
        c.model.hoveredRowID = was; await sleepMs(120)
        return sidebarPixels(c, f) != off
    }

    // ------------------------------------------------------------- × on hover
    r.section = "sidebar ×"
    var ws = await stage(["A", "B", "C", "D"])
    r.check("rows staged, shells idle", c.model.workspaces.count == 4 && ws.flatMap(\.panes).allSatisfy { c.runningProcess($0) == nil },
            ws.flatMap(\.panes).map { c.runningProcess($0) ?? "-" }.joined(separator: ","))
    await hover(ws[2])
    r.check("hovering a row draws its × in the trailing slot", await xDrawn(ws[2]))
    let fC = closeButtonRect(c, ws[2])
    r.check("…hit target ≥ 20×20pt (rowCloseButtonSize), line 1's trailing 12pt slot centered in it",
            fC.width >= 20 && fC.height >= 20 && abs(fC.midX - (host.bounds.width - 8 - 8 - 6)) < 0.5, "\(fC)")
    r.check("…accessibility label “Close C”, tooltip “Close Workspace (⇧⌘W)”", WorkspaceRow.closeLabel("C") == "Close C"
            && WorkspaceRow.closeHelp(c.closeTitle(count: 1)) == "Close Workspace (⇧⌘W)")
    print("INFO  [sidebar ×] hover from a synthesized mouse-moved event: \(hoverByEvent) (else the row's hover state is set directly)")
    await hover(nil)
    // Not hovered there is no ×: a click on that spot just selects the row.
    await click(host, at: NSPoint(x: fC.midX, y: fC.midY))
    r.check("not hovered, the same spot is the row (click selects C, nothing closes)", c.model.selected === ws[2] && titles() == "ABCD", titles())
    c.select(ws[0])
    await hover(ws[0])
    r.check("…the selected row shows it too (on the pill)", await xDrawn(ws[0]))
    await hover(nil)
    // Hovered, the trailing slot is only the ×: a Done row with "4m" and a needs-input row with a
    // badge render exactly like an idle row; not hovered they differ.
    let size = NSSize(width: 240, height: LmuxTokens.Layout.workspaceRowHeightDouble)
    for dark in [false, true] {
        func row(_ state: AgentDisplay, age: String?, unread: Int, hover: Bool) -> Data? {
            renderBytes(WorkspaceRowContent(title: "bench", accent: 1, state: state,
                                            detail: .init(text: "RSS table", tone: .secondary, age: age),
                                            unread: unread, selected: false, hover: hover), size: size, dark: dark)
        }
        let idleH = row(.idle, age: nil, unread: 0, hover: true)
        let name = dark ? "dark" : "light"
        r.check("hovered (\(name)): the state glyph and elapsed time give way to the ×",
                idleH != nil && row(.done(nil), age: "4m", unread: 0, hover: true) == idleH)
        r.check("hovered (\(name)): the unread badge too", row(.needsInput(nil), age: nil, unread: 2, hover: true) == idleH)
        r.check("not hovered (\(name)): unchanged (glyph and time drawn)", row(.done(nil), age: "4m", unread: 0, hover: false)
                != row(.idle, age: nil, unread: 0, hover: false))
    }

    // Click × on an idle, non-selected row: only it closes, selection unchanged.
    let selBefore = c.model.selectedID
    r.check("× on a non-selected idle row closes only it", await clickClose(ws[2]) && titles() == "ABD", titles())
    r.check("…selection unchanged", c.model.selectedID == selBefore && c.model.selected === ws[0])
    r.check("…keyboard still in the visible pane", firstResponderPane(c) === ws[0].panes[0], String(describing: w.firstResponder))
    // × on the selected row: the one below becomes active.
    r.check("× on the selected row closes it", await clickClose(ws[0]) && titles() == "BD", titles())
    r.check("…and selects the neighbor below", c.model.selected === ws[1] && firstResponderPane(c) === ws[1].panes[0])
    c.select(ws[3])
    r.check("× on the selected last row selects the one above", await clickClose(ws[3]) && titles() == "B" && c.model.selected === ws[1])
    r.check("× on the only row leaves a fresh workspace (as ⇧⌘W)", await clickClose(ws[1]) && c.model.workspaces.count == 1
            && c.model.selected != nil && c.model.selected !== ws[1])

    // A closed Claude session stays resumable: × never touches its transcript (History lists it).
    ws = await stage(["A", "B"])
    let work = paths.stateDir.appendingPathComponent("work", isDirectory: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    PolishFixture.writeHistory(root: c.history.projectsRoot, cwd: work.path)
    let tdir = c.history.projectsRoot.appendingPathComponent("-tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: tdir, withIntermediateDirectories: true)
    let tpath = tdir.appendingPathComponent("sidebar-x-1.jsonl").path
    try? fixtureJSONL(session: "sidebar-x-1", cwd: "/tmp", turns: [FixtureTurn(prompt: "keep me", reply: "kept")])
        .write(toFile: tpath, atomically: true, encoding: .utf8)
    let tBefore = FileManager.default.contents(atPath: tpath)
    hookEvent(c, ws[1].panes[0], "SessionStart", session: "sidebar-x-1", transcript: tpath, ["source": "startup"])
    _ = await waitFor(2) { ws[1].panes[0].claudeSessionID == "sidebar-x-1" }
    let allJSONL = { (try? FileManager.default.subpathsOfDirectory(atPath: c.history.projectsRoot.path))?.filter { $0.hasSuffix(".jsonl") }.sorted() ?? [] }
    let before = allJSONL()
    _ = await clickClose(ws[1])
    await c.history.refresh()
    _ = await waitFor(10) { c.history.sessions.contains { $0.id == "sidebar-x-1" } }
    r.check("× on a Claude row keeps every transcript byte for byte", titles() == "A" && FileManager.default.contents(atPath: tpath) == tBefore
            && allJSONL() == before, "\(before.count) -> \(allJSONL().count)")
    r.check("…and the closed session is in History (resumable)", c.history.sessions.contains { $0.id == "sidebar-x-1" },
            c.history.sessions.map(\.id).joined(separator: ","))

    // Busy rows ask first, naming the process; clicking × never selects the row first.
    r.section = "sidebar × busy"
    ws = await stage(["A", "B", "C"], busy: ["B"])
    r.check("B runs sleep", c.runningProcess(ws[1].panes[0]) == "sleep", c.runningProcess(ws[1].panes[0]) ?? "nil")
    var selections: [String?] = []
    let watch = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
        MainActor.assumeIsolated { if selections.last != c.model.selectedID { selections.append(c.model.selectedID) } }
    }
    selections = [c.model.selectedID]
    let shown = ws[0].panes[0]
    r.check("× on a row running a process asks first", await clickClose(ws[1]) && c.cardShown(shown) && titles() == "ABC")
    r.check("…naming the workspace and the process", (shown.view.overlay.card?.message.stringValue ?? "").contains("“B”")
            && (shown.view.overlay.card?.message.stringValue ?? "").contains("sleep"), shown.view.overlay.card?.message.stringValue ?? "")
    r.check("…without selecting the row first", c.model.selected === ws[0] && selections == [ws[0].id], "\(selections)")
    shown.view.overlay.card?.cancel.performClick()
    r.check("Cancel keeps it", !c.cardShown(shown) && titles() == "ABC")
    _ = await clickClose(ws[1])
    shown.view.overlay.card?.confirm.performClick()
    _ = await waitFor(2) { titles() == "AC" }
    r.check("Close closes it (and only it)", titles() == "AC" && c.model.selected === ws[0])
    r.check("…selection never moved", selections == [ws[0].id], "\(selections)")
    watch.invalidate()

    // ------------------------------------------------------------- multi-selection
    r.section = "multi-select"
    ws = await stage(["A", "B", "C", "D", "E"])
    func sel() -> String { c.model.workspaces.filter { c.model.isInSelection($0) }.map(\.title).joined() }
    await click(host, at: rowPoint(c, 2), modifiers: .command)
    r.check("⌘-click adds a row; it becomes the active workspace", sel() == "AC" && c.model.selected === ws[2], sel())
    r.check("…announced to VoiceOver", c.lastSelectionAnnouncement == "2 workspaces selected", c.lastSelectionAnnouncement ?? "nil")
    r.check("Close titles follow the selection", c.closeTitle(count: c.model.selectedWorkspaces.count) == "Close 2 Workspaces"
            && (c.closePaneMenuItem.map { c.validateMenuItem($0); return $0.title } ?? "") == "Close 2 Workspaces")
    await click(host, at: rowPoint(c, 3), modifiers: .command)
    await click(host, at: rowPoint(c, 0), modifiers: .command)
    r.check("⌘-click on a selected row removes it", sel() == "CD" && c.model.selected === ws[3], sel())
    await click(host, at: rowPoint(c, 3), modifiers: .command)
    r.check("…removing the active row moves the active one to the nearest selected", sel() == "C" && c.model.selected === ws[2]
            && !c.model.isMultiSelection, sel())
    await click(host, at: rowPoint(c, 0), modifiers: .shift)
    r.check("⇧-click selects the range from the anchor", sel() == "ABC" && c.model.selected === ws[0], sel())
    await click(host, at: rowPoint(c, 4), modifiers: .shift)
    r.check("…⇧-click again re-ranges from the same anchor", sel() == "CDE" && c.model.selected === ws[4], sel())
    await click(host, at: rowPoint(c, 1))
    r.check("a plain click resets to that one row", sel() == "B" && c.model.selected === ws[1] && !c.model.isMultiSelection,
            sel() + " " + sidebarClickDiagnosis(c, rowPoint(c, 1)))
    r.check("…and its pane has the keyboard", firstResponderPane(c) === ws[1].panes[0])
    // Esc right after ⌘-clicking clears back to the active workspace; later Esc goes to the terminal.
    await click(host, at: rowPoint(c, 3), modifiers: .command)
    r.check("⌘-click again", sel() == "BD", sel() + " " + sidebarClickDiagnosis(c, rowPoint(c, 3)))
    await type("\u{1b}", window: w)
    r.check("Esc clears the multi-selection to the active workspace", sel() == "D" && c.model.selected === ws[3], sel())
    r.check("…announced", c.lastSelectionAnnouncement == "1 workspace selected", c.lastSelectionAnnouncement ?? "nil")

    // Context menu (Control-click / right-click).
    r.section = "row menu"
    let single = c.rowMenu(for: ws[1]).map { $0?.title ?? "—" }
    r.check("row menu: Close, Rename, Clear Status (no Move to Top / Bottom: drag reorders)",
            single == ["Close Workspace", "Rename Workspace…", "—", "Clear Status"], "\(single)")
    await click(host, at: rowPoint(c, 0), modifiers: .command)  // D + A
    // (A synthesized Control-click would open the real menu: the click handler is checked directly.)
    c.clickRow(ws[2], modifiers: .control)
    r.check("Control-click doesn't change the selection", sel() == "AD", sel())
    let multiMenu = c.rowMenu(for: ws[3]).map { $0?.title ?? "—" }
    r.check("in a multi-selection: Close 2 Workspaces, no Rename", multiMenu == ["Close 2 Workspaces", "—", "Clear Status"],
            "\(multiMenu)")
    r.check("…a row outside it gets its own menu", c.rowMenu(for: ws[2]).first??.title == "Close Workspace")

    // × with a multi-selection.
    r.section = "multi-select close"
    ws = await stage(["A", "B", "C", "D", "E"])
    await click(host, at: rowPoint(c, 1), modifiers: .command)
    await click(host, at: rowPoint(c, 3), modifiers: .command)  // A B D, D active
    await hover(ws[2])
    r.check("× on a row outside the selection says Close Workspace; inside, Close 3 Workspaces",
            c.closeTargets(for: ws[2]).count == 1 && c.closeTargets(for: ws[0]).count == 3)
    r.check("× on an unselected row closes only it", await clickClose(ws[2]) && titles() == "ABDE" && sel() == "ABD"
            && c.model.selected === ws[3], "\(titles()) \(sel())")
    r.check("× on a selected row closes the whole selection", await clickClose(ws[0]) && titles() == "E", titles())
    r.check("…the active workspace is the next row that stays", c.model.selected === ws[4] && !c.model.isMultiSelection
            && firstResponderPane(c) === ws[4].panes[0])

    // ⌘W with a multi-selection closes them all; busy ones ask once, together.
    ws = await stage(["A", "B", "C", "D"], busy: ["B", "C"])
    await click(host, at: rowPoint(c, 3), modifiers: .shift)  // A…D
    await click(host, at: rowPoint(c, 3), modifiers: .command)  // A B C, C active
    r.check("selection A B C (C active)", sel() == "ABC" && c.model.selected === ws[2], sel())
    let host2 = ws[2].panes[0]
    await cmd("w", window: w)
    let msg = host2.view.overlay.card?.message.stringValue ?? ""
    r.check("⌘W with busy rows asks once for all of them", c.cardShown(host2) && titles() == "ABCD"
            && c.model.workspaces.flatMap(\.panes).filter { c.cardShown($0) }.count == 1, msg)
    r.check("…“Close 3 workspaces? “B” is running sleep, “C” is running sleep.”",
            msg == "Close 3 workspaces? “B” is running sleep, “C” is running sleep.", msg)
    await type("\u{1b}", window: w)
    r.check("Cancel (Esc) keeps all three", !c.cardShown(host2) && titles() == "ABCD" && sel() == "ABC")
    await cmd("w", window: w)
    await type("\r", window: w)
    _ = await waitFor(3) { titles() == "D" }
    r.check("Close (Enter) closes all three", titles() == "D" && c.model.selected === ws[3] && firstResponderPane(c) === ws[3].panes[0], titles())
    // ⇧⌘W (Close Workspace) the same; all idle: no question.
    ws = await stage(["A", "B", "C"])
    await click(host, at: rowPoint(c, 2), modifiers: .command)
    await cmd("w", shift: true, window: w)
    _ = await waitFor(2) { titles() == "B" }
    r.check("⇧⌘W with an idle multi-selection closes them without asking", titles() == "B" && c.model.selected === ws[1], titles())
    // Plain ⌘W without a multi-selection is still Close Pane.
    if let p = c.split(ws[1].panes[0], .right) {
        _ = await waitFor(5) { p.surface.foregroundPID > 0 && c.runningProcess(p) == nil }
        await cmd("w", window: w)
        _ = await waitFor(2) { ws[1].panes.count == 1 }
        r.check("⌘W without a multi-selection still closes just the pane", ws[1].panes.count == 1 && c.model.workspaces.count == 1)
    }
    r.check("the window stayed off every display, never key", !NSScreen.screens.contains { $0.frame.intersects(w.frame) }
            && !w.isKeyWindow && !NSApp.isActive, "frame \(w.frame) key=\(w.isKeyWindow) appActive=\(NSApp.isActive) activations \(activations)")
    return finish(r, c)
}

/// `--feedback-shots D`: the polish scene with a sidebar multi-selection (⌘-click) and the pointer
/// on a selected row (its ×), and the pointer on a finished reply (the turn band and ⧉ ✎ × pill),
/// light and dark: D/feedback-{light,dark}.png. Rendered offscreen, never shown.
@MainActor
func runFeedbackShots(_ dir: URL) async -> Int32 {
    let c = makeController()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s = await stagePolishScene(c, fx: paths.stateDir.appendingPathComponent("polish", isDirectory: true))
    // Claude finished the left pane's turn: its reply can be hovered.
    hookEvent(c, s.left, "Stop", session: "polish-1", ["last_assistant_message": "Found it."])
    await sleepMs(300)
    let rows = c.model.workspaces
    if rows.count > 3 { c.clickRow(rows[2], modifiers: .command); c.clickRow(rows[3], modifiers: .command); c.select(s.ws, focusing: s.left); c.setSelection(Set([s.ws.id, rows[2].id, rows[3].id]), anchor: s.ws.id) }
    c.model.hoveredRowID = rows.count > 2 ? rows[2].id : nil
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await sleepMs(1200)
        s.left.hover.readAt = .distantPast
        _ = await c.loadTurns(s.left)
        let m = c.screenMap(s.left, maxAge: 0)
        if let row = m.rows.firstIndex(where: { $0.text.contains("createPartialRefund") }) {
            c.paneMouseMoved(s.left, NSPoint(x: 260, y: s.left.surface.bounds.height - (m.rows[row].top + m.rowHeight / 2)))
        }
        await sleepMs(400)
        c.root.updateHeader()
        c.window.contentView?.needsDisplay = true
        await sleepMs(300)
        let out = dir.appendingPathComponent("feedback-\(dark ? "dark" : "light").png")
        do { try c.snapshotPNG(to: out); print("wrote \(out.path)") } catch { print("snapshot failed: \(error)") }
        print("INFO  turn pill: \(c.hoveredTurn(s.left).map(String.init) ?? "none"), selection \(c.model.selection.count), hovered row \(c.model.hoveredRowID != nil)")
    }
    NSApp.appearance = nil
    c.shutdown()
    return 0
}

/// What a sidebar click at `p` (sidebar host coordinates) would have hit, for a failed click check.
@MainActor
func sidebarClickDiagnosis(_ c: LmuxController, _ p: NSPoint) -> String {
    let host = c.root.sidebarHost
    let inWindow = host.convert(p, to: nil)
    let hit = c.window.contentView?.hitTest(c.window.contentView!.convert(inWindow, from: nil))
    var chain: [String] = []
    var v = hit
    while let cur = v, chain.count < 4 { chain.append(String(describing: type(of: cur))); v = cur.superview }
    func scrolls(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(scrolls) }
    let offsets = scrolls(host).map { "\($0.documentVisibleRect.origin.y)/\($0.frame.height)" }
    return "[hit \(chain.joined(separator: "<")) · scroll \(offsets) · host \(host.frame) · sheet \(c.window.attachedSheet != nil)"
        + " · hover \(c.model.hoveredRowID.flatMap { id in c.model.workspaces.first { $0.id == id }?.title } ?? "-")"
        + String(format: " · press %.0f ms", MouseQueue.lastPressMs) + " · global mods \(NSEvent.modifierFlags.intersection([.command, .shift, .control, .option]).rawValue) · \(MouseQueue.environment)]"
}
