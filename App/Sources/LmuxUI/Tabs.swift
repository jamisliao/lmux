import AppKit
import LmuxTerminal
import LmuxTokens

private typealias T = LmuxTokens

// Tabs inside a pane (cmux's surfaces), with cmux's tab bar: a split leaf holds an ordered list of
// terminals, one shown. Every tab is an ordinary `Pane` (its own id, agent state, History,
// scrollback); only the shown one is in the window, the rest stay occluded like a hidden
// workspace's panes. Every leaf has a strip (cmux's default; the setting off: only with two tabs).
//
//   ⌘T (Ghostty `new_tab`)   new tab after the shown one     ⇧⌘] / ⇧⌘[, ⌃⇥ / ⌃⇧⇥  next / previous tab
//   ⌃1…⌃8 / ⌃9               that tab / the last              ⌥⇧⌘] / ⌥⇧⌘[          move the tab right / left
//   ⌘W                       closes the tab (the pane with it when it's the last; a pinned tab stays)
//   ⌘R / ⌥⌘T                 rename the tab / close the other tabs
//   in the strip: click selects, double-click zooms, middle-click / × closes, drag reorders (onto
//   another pane: into its strip, or its edge splits it), right-click for the rest; on the empty
//   part a double-click opens a tab; the buttons on the right: new tab, split right, split down.

extension LmuxController {
    /// ⌘T / `lmux new-tab` / the strip's + / New Terminal Tab to Right: a new terminal tab in `pane`'s
    /// leaf, right after `after` (default: the shown tab), never among the pinned ones. It starts
    /// where a split would (`LmuxConfig.splitInherits`). `select: false` opens it behind.
    @discardableResult
    public func newTab(_ pane: Pane, after: Pane? = nil, command: String? = nil, program: String? = nil, select: Bool = true) -> Pane? {
        guard let ws = pane.workspace, let leaf = ws.root.find(pane) else { return nil }
        let from = after ?? leaf.shownTab ?? pane
        let cwd = (LmuxConfig.splitInherits() ? from.cwd : nil) ?? LmuxConfig.workingDirectory()
        let tab = makePane(cwd: cwd, initialInput: command.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }, command: program)
        let at = (leaf.tabs.firstIndex { $0 === from } ?? leaf.tabs.count - 1) + 1
        insert(tab, into: leaf, at: at, ws, select: select)
        return tab
    }

    /// Put `tab` (new, or moved from another pane) into `leaf` at `index` (kept on its side of the
    /// pinned tabs), shown and focused unless `select` is false.
    func insert(_ tab: Pane, into leaf: SplitNode, at index: Int, _ ws: Workspace, select: Bool) {
        let pc = leaf.pinnedCount
        let at = tab.pinned ? min(index, pc) : max(index, pc)
        leaf.tabs.insert(tab, at: min(max(at, 0), leaf.tabs.count))
        tab.surface.setOcclusion(visible: false)
        ws.structureChanged()
        if select {
            // Zoomed on another pane: the zoom ends, so the focused tab is on screen.
            if let z = ws.zoomedPane, ws.root.find(z) !== leaf { ws.zoomedPane = nil }
            showTab(tab, in: leaf, ws)
            ws.focusedPane = tab
        }
        if ws === model.selected {
            rebuildContent()
            focusCurrent()
        }
        scheduleSave()
    }

    /// Bring `tab` to the front of its leaf (and focus it there).
    public func selectTab(_ tab: Pane) {
        guard let ws = tab.workspace, let leaf = ws.root.find(tab) else { return }
        let changed = showTab(tab, in: leaf, ws)
        ws.focusedPane = tab
        if ws === model.selected {
            if changed { rebuildContent() }
            focusCurrent()
        }
        if changed { scheduleSave() }
    }

    /// ⇧⌘] / ⇧⌘[ (⌃⇥ / ⌃⇧⇥): the next / previous tab of the focused pane (wraps; nothing without tabs).
    public func selectTabRelative(_ delta: Int) {
        guard let cur = model.selected?.focusedPane, let leaf = cur.workspace?.root.find(cur), leaf.hasTabs,
              let i = leaf.tabs.firstIndex(where: { $0 === cur }) else { return }
        let n = leaf.tabs.count
        selectTab(leaf.tabs[((i + delta) % n + n) % n])
    }

    /// ⌃1…⌃8: that tab of the focused pane; ⌃9: the last one.
    public func selectTab(number: Int) {
        guard let cur = model.selected?.focusedPane, let leaf = cur.workspace?.root.find(cur) else { return }
        let i = number == 9 ? leaf.tabs.count - 1 : number - 1
        if leaf.tabs.indices.contains(i) { selectTab(leaf.tabs[i]) }
    }

    /// The model half of switching tabs: `tab` becomes the leaf's shown one (focus and zoom follow
    /// it off the old one), the old one stops rendering. The caller rebuilds the content. True if it changed.
    @discardableResult
    func showTab(_ tab: Pane, in leaf: SplitNode, _ ws: Workspace) -> Bool {
        guard let old = leaf.shownTab, old !== tab, leaf.tabs.contains(where: { $0 === tab }) else { return false }
        leaf.content = .pane(tab)
        if ws.focusedPane === old { ws.focusedPane = tab }
        if ws.zoomedPane === old { ws.zoomedPane = tab }
        old.surface.focusDidChange(false)
        old.surface.setOcclusion(visible: false)
        ws.structureChanged()
        return true
    }

    /// Closing one of several tabs (`closePane` for a leaf with tabs): the tab to its right shows
    /// (the left one for the last), the leaf stays. Closing a tab behind keeps the shown one.
    func closeTab(_ tab: Pane, in leaf: SplitNode) {
        guard let ws = tab.workspace, let i = leaf.tabs.firstIndex(where: { $0 === tab }) else { return }
        leaf.tabs.remove(at: i)
        if leaf.shownTab === tab {
            let next = leaf.tabs[min(i, leaf.tabs.count - 1)]
            leaf.content = .pane(next)
            if ws.focusedPane === tab { ws.focusedPane = next }
            if ws.zoomedPane === tab { ws.zoomedPane = next }
        }
        // Down to one tab with the strip off for one: no strip (it may still sit in the closed tab's view).
        if !leaf.hasStrip { leaf.strip.removeFromSuperview() }
        discard(tab)
        ws.structureChanged()
        if ws === model.selected {
            rebuildContent()
            focusCurrent()
        }
        scheduleSave()
    }

    /// Drag-to-reorder in the strip: `tab` moves to `index` among its leaf's tabs (on its side of the pinned ones).
    public func moveTab(_ tab: Pane, to index: Int) {
        guard let ws = tab.workspace, let leaf = ws.root.find(tab), let i = leaf.tabs.firstIndex(where: { $0 === tab }) else { return }
        var tabs = leaf.tabs
        tabs.remove(at: i)
        let pc = tabs.prefix { $0.pinned }.count
        let to = min(max(tab.pinned ? min(index, pc) : max(index, pc), 0), tabs.count)
        guard to != i else { return }
        tabs.insert(tab, at: to)
        leaf.tabs = tabs
        ws.structureChanged()
        leaf.strip.update()
        scheduleSave()
    }

    /// ⌥⇧⌘] / ⌥⇧⌘[: the focused tab one place right / left.
    public func moveFocusedTab(_ delta: Int) {
        guard let cur = model.selected?.focusedPane, let leaf = cur.workspace?.root.find(cur),
              let i = leaf.tabs.firstIndex(where: { $0 === cur }) else { return }
        moveTab(cur, to: i + delta)
    }

    /// × / middle-click / Close Tab: closes it, asking first (on that tab, brought to the front)
    /// when something other than an idle shell runs there, like ⌘W. A pinned tab doesn't close.
    public func requestCloseTab(_ tab: Pane) {
        if tab.pinned { NSSound.beep(); return }
        if runningProcess(tab) != nil { selectTab(tab) }
        requestClosePane(tab)
    }

    /// Close Other Tabs / to the Left / to the Right: the pinned ones stay. Idle shells close at once;
    /// when one of them runs something, one card on `anchor` asks first for all of them.
    public func requestCloseTabs(_ list: [Pane], anchor: Pane) {
        let list = list.filter { !$0.pinned && $0 !== anchor }
        guard !list.isEmpty else { return }
        let busy = list.compactMap { p in runningProcess(p).map { (p, $0) } }
        guard !busy.isEmpty else { list.forEach(closePane); return }
        selectTab(anchor)
        let names = Array(Set(busy.map(\.1))).sorted().joined(separator: ", ")
        showCard(anchor, message: Self.bold("Close \(list.count) \(list.count == 1 ? "tab" : "tabs")? ", names,
                                            busy.count == 1 ? " is still running." : " are still running."),
                 detail: busy.count == 1 ? "Closing terminates the process." : "Closing terminates the processes.",
                 confirmTitle: list.count == 1 ? "Close" : "Close \(list.count)",
                 onConfirm: { [weak self] in
                     guard let self else { return }
                     for p in list where p.workspace != nil { self.closePane(p) }
                 })
    }

    /// Pin Tab / Unpin Tab: pinned tabs gather at the front of the strip, in their order.
    public func togglePin(_ tab: Pane) {
        guard let ws = tab.workspace, let leaf = ws.root.find(tab) else { return }
        tab.pinned.toggle()
        leaf.tabs = leaf.tabs.filter(\.pinned) + leaf.tabs.filter { !$0.pinned }
        ws.structureChanged()
        if ws === model.selected { refreshTabStrips(ws) }
        scheduleSave()
    }

    /// Mark Tab as Unread / as Read: its badge (and the sidebar's count) on or off.
    public func setUnread(_ tab: Pane, _ on: Bool) {
        tab.unread = on ? max(tab.unread, 1) : 0
        refreshPaneChrome()
    }

    /// Double-click on a tab / Zoom Pane: that tab's pane fills the workspace, or the zoom ends.
    public func toggleZoom(for tab: Pane) {
        guard let ws = tab.workspace, ws.isSplit || ws.isZoomed else { return }
        selectTab(tab)
        toggleSplitZoom(ws)
    }

    // MARK: Moving tabs between panes

    /// Take `tab` out of its leaf without closing it (it moves): the leaf shows its next tab, or (its
    /// last tab) goes like a closed pane, or (the workspace's last pane) the workspace goes.
    func detach(_ tab: Pane) {
        guard let ws = tab.workspace, let leaf = ws.root.find(tab), let i = leaf.tabs.firstIndex(where: { $0 === tab }) else { return }
        // The zoom ends only if it was on this tab's pane (it goes, or shows another tab).
        if let z = ws.zoomedPane, ws.root.find(z) === leaf { ws.zoomedPane = nil }
        tab.surface.focusDidChange(false)
        tab.surface.setOcclusion(visible: false)
        tab.view.tabStrip = nil
        tab.view.removeFromSuperview()
        tab.workspace = nil
        if leaf.hasTabs {
            leaf.tabs.remove(at: i)
            if leaf.shownTab === tab { leaf.content = .pane(leaf.tabs[min(i, leaf.tabs.count - 1)]) }
            if ws.focusedPane === tab { ws.focusedPane = leaf.shownTab }
        } else if !removeLeaf(leaf, in: ws, leaving: tab) {
            // The workspace's only pane: the workspace goes, the pane lives on where it went.
            leaf.tabs = []
            ws.structureChanged()
            ws.focusedPane = nil
            ws.zoomedPane = nil
            model.workspaces.removeAll { $0 === ws }
            model.selection.remove(ws.id)
            if model.selection.count < 2 { model.selection = [] }
            if model.hoveredRowID == ws.id { model.hoveredRowID = nil }
            if model.selectionAnchorID == ws.id { model.selectionAnchorID = nil }
            if model.selectedID == ws.id { model.selectedID = nil }
            return
        }
        ws.structureChanged()
    }

    /// Show `ws` (or rebuild it if it's already shown) focused on `tab`, after a move.
    private func settle(_ ws: Workspace, on tab: Pane) {
        if ws !== model.selected { select(ws, focusing: tab) } else { rebuildContent(); focusCurrent() }
        scheduleSave()
    }

    /// A tab dropped on another pane's strip (or Move to Left / Right Pane, Move Tab): into the leaf
    /// holding `target`, at `index` (nil: the end), shown and focused.
    public func moveTab(_ tab: Pane, into target: Pane, at index: Int? = nil) {
        guard target !== tab, let ws = target.workspace, let leaf = ws.root.find(target) else { return }
        if leaf.tabs.contains(where: { $0 === tab }) {
            // Its own strip: a reorder.
            if let index, let i = leaf.tabs.firstIndex(where: { $0 === tab }) { moveTab(tab, to: index > i ? index - 1 : index) }
            selectTab(tab)
            return
        }
        // Index first: the target leaf is looked up again after the detach (a collapse may move it).
        let at = index ?? leaf.tabs.count
        detach(tab)
        guard let dest = ws.root.find(target) else { return }
        insert(tab, into: dest, at: at, ws, select: true)
        settle(ws, on: tab)
    }

    /// A tab dropped on an edge of the pane holding `target`: that pane splits, the tab on that side.
    public func moveTab(_ tab: Pane, splitting target: Pane, _ dir: SplitDirection) {
        guard target !== tab, let ws = target.workspace, ws.root.find(target) != nil else { return }
        detach(tab)
        guard let dest = ws.root.find(target) else { return }
        splitLeaf(dest, in: ws, dir, with: tab)
        settle(ws, on: tab)
    }

    /// Move Tab to New Workspace: the tab becomes a workspace of its own, right after its old one.
    public func moveTabToNewWorkspace(_ tab: Pane) {
        guard let src = tab.workspace, src.panes.count > 1 else { return }
        detach(tab)
        let ws = Workspace(id: UUID().uuidString, accent: nextAccent(), root: SplitNode(pane: tab))
        let i = model.workspaces.firstIndex { $0 === src }.map { $0 + 1 } ?? model.workspaces.count
        model.workspaces.insert(ws, at: i)
        select(ws, focusing: tab)
        scheduleSave()
    }

    /// Move Tab ▸ a workspace: into its focused pane, after the tab shown there.
    public func moveTab(_ tab: Pane, to ws: Workspace) {
        guard tab.workspace !== ws, let target = ws.focusedPane ?? ws.visiblePanes.first, let leaf = ws.root.find(target) else { return }
        moveTab(tab, into: target, at: (leaf.tabs.firstIndex { $0 === leaf.shownTab } ?? leaf.tabs.count - 1) + 1)
    }

    /// The pane on screen beside `tab`'s leaf to the left / right (its neighbour in the split tree), nil at the edge.
    func sidePane(of tab: Pane, left: Bool) -> Pane? {
        guard var node = tab.workspace?.root.find(tab) else { return nil }
        while let parent = node.parent {
            if case .split(.horizontal, let a, let b) = parent.content, (left ? b : a) === node {
                let side = (left ? a : b).visiblePanes
                return left ? side.last : side.first
            }
            node = parent
        }
        return nil
    }

    // MARK: The strip's context menu (cmux's items, in its order)

    func tabMenu(for tab: Pane) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let ws = tab.workspace, let leaf = ws.root.find(tab), let i = leaf.tabs.firstIndex(where: { $0 === tab }) else { return menu }
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [], enabled: Bool = true,
                 to m: NSMenu? = nil, _ run: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, run: run)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
            item.isEnabled = enabled
            (m ?? menu).addItem(item)
        }
        let tabs = leaf.tabs
        let closable = { (s: ArraySlice<Pane>) in s.contains { !$0.pinned && $0 !== tab } }
        add("Rename Tab…", "r", .command) { [weak self] in self?.promptRenamePane(tab) }
        if tab.titleState.isManual { add("Remove Custom Tab Name") { [weak self] in self?.renamePane(tab, to: nil) } }
        menu.addItem(.separator())
        add("Close Tab", "w", .command, enabled: !tab.pinned) { [weak self] in self?.requestCloseTab(tab) }
        add("Close Tabs to Left", enabled: closable(tabs[..<i])) { [weak self] in self?.requestCloseTabs(Array(tabs[..<i]), anchor: tab) }
        add("Close Tabs to Right", enabled: closable(tabs[(i + 1)...])) { [weak self] in
            self?.requestCloseTabs(Array(tabs[(i + 1)...]), anchor: tab)
        }
        add("Close Other Tabs", "t", [.command, .option], enabled: closable(tabs[...])) { [weak self] in
            self?.requestCloseTabs(tabs, anchor: tab)
        }
        let move = NSMenuItem(title: "Move Tab", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        add("Move Tab to New Workspace", enabled: ws.panes.count > 1, to: sub) { [weak self] in self?.moveTabToNewWorkspace(tab) }
        for other in model.workspaces where other !== ws {
            add(other.title, to: sub) { [weak self] in self?.moveTab(tab, to: other) }
        }
        move.submenu = sub
        move.isEnabled = ws.panes.count > 1 || model.workspaces.count > 1
        menu.addItem(move)
        let left = sidePane(of: tab, left: true), right = sidePane(of: tab, left: false)
        add("Move to Left Pane", enabled: left != nil) { [weak self] in if let left { self?.moveTab(tab, into: left) } }
        add("Move to Right Pane", enabled: right != nil) { [weak self] in if let right { self?.moveTab(tab, into: right) } }
        menu.addItem(.separator())
        add("New Terminal Tab to Right", "t", .command) { [weak self] in self?.newTab(tab, after: tab) }
        menu.addItem(.separator())
        if ws.isSplit || ws.isZoomed {
            add(ws.isZoomed ? "Exit Zoom" : "Zoom Pane") { [weak self] in self?.toggleZoom(for: tab) }
        }
        add(tab.pinned ? "Unpin Tab" : "Pin Tab") { [weak self] in self?.togglePin(tab) }
        if tab.unread > 0 {
            add("Mark Tab as Read") { [weak self] in self?.setUnread(tab, false) }
        } else {
            add("Mark Tab as Unread", enabled: !tab.isFocused) { [weak self] in self?.setUnread(tab, true) }
        }
        return menu
    }

    /// The strips of a workspace's leaves follow their tabs' titles and states (from `refreshHeaders`).
    func refreshTabStrips(_ ws: Workspace) {
        func walk(_ n: SplitNode) {
            switch n.content {
            case .pane:
                guard n.hasStrip else { return }
                let s = n.strip
                if s.controller == nil { s.controller = self }
                s.update()
            case .split(_, let a, let b): walk(a); walk(b)
            }
        }
        walk(ws.root)
    }

    // MARK: Dragging a tab out of its strip

    /// Where a tab dragged out of its strip would land: another strip at an index, or a pane (the
    /// middle: into its strip at the end; an edge, the outer quarter: a split on that side).
    enum TabDrop {
        case strip(Pane, Int)
        case pane(Pane)
        case split(Pane, SplitDirection)
    }

    /// The drop under `windowPoint` for `tab`, and the area to highlight (in the content view).
    func tabDrop(for tab: Pane, at windowPoint: NSPoint) -> (TabDrop, NSRect)? {
        guard let ws = model.selected, case let content = root.content,
              let hit = content.hitTest(content.superview?.convert(windowPoint, from: nil) ?? windowPoint) else { return nil }
        var v: NSView? = hit
        while let cur = v, !(cur is PaneView), !(cur is TabStripView) { v = cur.superview }
        if let strip = v as? TabStripView, let leaf = strip.node, let shown = leaf.shownTab, ws.root.find(shown) === leaf {
            let p = strip.convert(windowPoint, from: nil)
            let i = strip.insertionIndex(at: p.x)
            let x = strip.insertionX(i)
            let line = strip.convert(NSRect(x: x - 1, y: 4, width: 2, height: strip.bounds.height - 8), to: content)
            return (.strip(shown, i), line)
        }
        guard let pv = v as? PaneView, let pane = pv.pane, ws.root.find(pane) != nil else { return nil }
        let leaf = ws.root.find(pane)!
        // Its own pane: only an edge does something, and only when another tab stays behind.
        let own = leaf.tabs.contains { $0 === tab }
        guard let target = own ? leaf.tabs.first(where: { $0 !== tab }) : pane else { return nil }
        let area = pane.surface.frame
        let p = pv.convert(windowPoint, from: nil)
        let fx = (p.x - area.minX) / max(1, area.width), fy = (p.y - area.minY) / max(1, area.height)
        let edge: CGFloat = 0.25
        var r = area
        let drop: TabDrop
        // The view is flipped: y grows downward.
        if fx < edge { drop = .split(target, .left); r.size.width /= 2 }
        else if fx > 1 - edge { drop = .split(target, .right); r.origin.x += r.width / 2; r.size.width /= 2 }
        else if fy < edge { drop = .split(target, .up); r.size.height /= 2 }
        else if fy > 1 - edge { drop = .split(target, .down); r.origin.y += r.height / 2; r.size.height /= 2 }
        else if own { return nil }
        else { drop = .pane(target) }
        return (drop, pv.convert(r, to: content))
    }

    /// The drag left the strip: show where the tab would land (nil hides it).
    func showTabDrop(_ rect: NSRect?) {
        if rect == nil { tabDropPreview?.removeFromSuperview(); tabDropPreview = nil; return }
        let v = tabDropPreview ?? TabDropPreview()
        if v.superview !== root.content { root.content.addSubview(v) }
        v.frame = rect!
        tabDropPreview = v
    }

    func performTabDrop(_ tab: Pane, _ drop: TabDrop) {
        switch drop {
        case .strip(let target, let i): moveTab(tab, into: target, at: i)
        case .pane(let target): moveTab(tab, into: target)
        case .split(let target, let dir): moveTab(tab, splitting: target, dir)
        }
    }
}

/// Where a dragged tab will land: cmux's translucent accent placeholder.
final class TabDropPreview: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A context-menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// A leaf's tab strip, cmux's tab bar (Bonsplit's metrics): 30 pt high, each tab sized to its title
/// (48–220 pt) with a terminal icon, the shown one on a lighter fill with a 1.5 pt accent line on top
/// (gray when the pane isn't focused) and no bottom rule, × on the shown / hovered tab, a dot in the
/// ×'s place on a tab that needs you, a pin on a pinned one. New tab / split right / split down
/// buttons at the end; too many tabs scroll sideways. Drawn in `draw(_:)` (no subviews, no
/// timers): it redraws only when a tab's title, state or the hover changes.
@MainActor
public final class TabStripView: NSView {
    static let height: CGFloat = 30
    static let minTabWidth: CGFloat = 48
    static let maxTabWidth: CGFloat = 220
    private static let padX: CGFloat = 6
    private static let iconSize: CGFloat = 14
    private static let spacing: CGFloat = 6
    private static let slot: CGFloat = 16
    private static let indicator: CGFloat = 1.5
    static let font = NSFont.systemFont(ofSize: 11)
    // The buttons lane: Bonsplit's split buttons (12 pt symbols, 4 pt apart, 6 / 8 pt padding).
    private static let buttonWidth: CGFloat = 18
    private static let buttonGap: CGFloat = 4
    static var laneWidth: CGFloat { 6 + 3 * buttonWidth + 2 * buttonGap + 8 }

    weak var node: SplitNode?
    weak var controller: LmuxController?

    /// What a tab draws; compared so an unchanged refresh doesn't redraw.
    struct Item: Equatable {
        let id: String
        let title: String
        let agent: Bool
        /// The badge: it needs you, or an alert nobody has seen.
        let badge: Bool
        let pinned: Bool
        let width: CGFloat
    }
    private(set) var items: [Item] = []
    private(set) var selected = 0
    private var hovered: Int?
    private var hoveredButton: Int?
    /// The pane is focused (the accent line has its color).
    private(set) var focused = false
    /// The leaf's pane is zoomed (the shown tab gets the exit-zoom button).
    private(set) var zoomed = false
    /// The shown tab's mode badge ("bypass", "auto"), before the buttons: the strip is its header.
    private(set) var modeBadge: String?
    private(set) var background: NSColor = T.Colors.windowBackground.nsColor
    /// Sideways scroll of the tabs when they don't fit.
    private(set) var scroll: CGFloat = 0
    // A press: which tab, where, whether it began on the ×, and whether it became a drag.
    private var press: (index: Int, x: CGFloat, onClose: Bool, dragging: Bool)?
    /// The pressed tab itself (its index can change under a drag: another tab closing, a reorder).
    private weak var pressed: Pane?
    private var drop: LmuxController.TabDrop?

    init(node: SplitNode) {
        self.node = node
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        setAccessibilityRole(.tabGroup)
    }
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// Out of the window mid-drag (a workspace switch): no mouse-up comes, the drop is off.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, drop != nil else { return }
        controller?.showTabDrop(nil)
        drop = nil
    }

    /// Read the leaf's tabs again (titles, states, order).
    func update() {
        guard let node else { return }
        let tabs = node.tabs
        let shown = node.shownTab
        let new = tabs.map { p in
            // The pane's header text (`refreshHeaders`: split panes with the same title told apart).
            let header = p.view.header.label.stringValue
            let title = !header.isEmpty ? header : p.headerTitle.isEmpty ? "Terminal" : p.headerTitle
            let w = ceil((title as NSString).size(withAttributes: [.font: Self.font]).width)
            let full = Self.padX + Self.iconSize + Self.spacing + w + Self.spacing + Self.slot + Self.padX
            return Item(id: p.id, title: title, agent: p.runsClaude,
                        badge: (p.needsInput || p.unread > 0) && !(p === shown && p.isFocused), pinned: p.pinned,
                        width: min(Self.maxTabWidth, max(Self.minTabWidth, full)))
        }
        let sel = tabs.firstIndex { $0 === shown } ?? 0
        let bg = shown?.surface.terminalBackground ?? T.Colors.windowBackground.nsColor
        let f = shown?.isFocused ?? false
        let z = shown.map { $0.workspace?.zoomedPane === $0 } ?? false
        let mb = shown?.modeBadge
        adoptAppearance(on: shown?.surface.terminalBackground)
        if new != items || sel != selected || bg != background || f != focused || z != zoomed || mb != modeBadge {
            let moved = sel != selected || new != items || mb != modeBadge
            modeBadge = mb
            items = new
            selected = sel
            background = bg
            focused = f
            zoomed = z
            // A new selection or new widths: the shown tab back in view.
            if moved { revealSelected() }
            needsDisplay = true
        }
    }

    // MARK: Geometry

    private var tabsWidth: CGFloat { max(0, bounds.width - Self.laneWidth - badgeWidth) }
    private var badgeWidth: CGFloat { modeBadge.map { ModeBadge.size($0).width + 8 } ?? 0 }
    private var contentWidth: CGFloat { items.reduce(0) { $0 + $1.width } }

    func tabRect(_ i: Int) -> NSRect {
        let x = items.prefix(i).reduce(0) { $0 + $1.width } - scroll
        return NSRect(x: x, y: 0, width: items.indices.contains(i) ? items[i].width : 0, height: bounds.height)
    }

    func closeRect(_ i: Int) -> NSRect {
        let r = tabRect(i)
        return NSRect(x: r.maxX - Self.padX - Self.slot, y: (r.height - Self.slot) / 2, width: Self.slot, height: Self.slot)
    }

    /// The exit-zoom button of the shown tab of a zoomed pane, left of its ×.
    func zoomRect(_ i: Int) -> NSRect? {
        guard zoomed, i == selected else { return nil }
        let c = closeRect(i)
        return NSRect(x: c.minX - 2 - Self.slot, y: c.minY, width: Self.slot, height: Self.slot)
    }

    /// The buttons on the right: 0 new tab, 1 split right, 2 split down.
    func buttonRect(_ b: Int) -> NSRect {
        let x = bounds.width - Self.laneWidth + 6 + CGFloat(b) * (Self.buttonWidth + Self.buttonGap)
        return NSRect(x: x, y: 0, width: Self.buttonWidth, height: bounds.height)
    }

    func index(at p: NSPoint) -> Int? {
        guard p.x >= 0, p.x < tabsWidth else { return nil }
        return items.indices.first { tabRect($0).minX <= p.x && p.x < tabRect($0).maxX }
    }

    func button(at p: NSPoint) -> Int? { (0..<3).first { buttonRect($0).contains(p) } }

    /// Where a tab dropped at `x` goes: before the tab whose middle is right of `x`.
    func insertionIndex(at x: CGFloat) -> Int {
        items.indices.first { tabRect($0).midX > x } ?? items.count
    }

    func insertionX(_ i: Int) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        return i < items.count ? tabRect(i).minX : min(tabRect(items.count - 1).maxX, tabsWidth)
    }

    private func clampScroll() {
        scroll = min(max(0, scroll), max(0, contentWidth - tabsWidth))
    }

    /// The shown tab scrolled into view.
    private func revealSelected() {
        guard items.indices.contains(selected) else { clampScroll(); return }
        let r = tabRect(selected)
        if r.minX < 0 { scroll += r.minX } else if r.maxX > tabsWidth { scroll += r.maxX - tabsWidth }
        clampScroll()
    }

    public override func layout() {
        super.layout()
        revealSelected()
    }

    private func showsClose(_ i: Int) -> Bool { !items[i].pinned && (i == selected || i == hovered) }

    // MARK: Drawing

    private var isLight: Bool {
        guard let c = background.usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.5
    }

    private func shade(_ amount: CGFloat, alpha: CGFloat = 1) -> NSColor {
        guard let c = background.usingColorSpace(.sRGB) else { return background }
        let d = isLight ? -amount : amount
        return NSColor(srgbRed: min(1, max(0, c.redComponent + d)), green: min(1, max(0, c.greenComponent + d)),
                       blue: min(1, max(0, c.blueComponent + d)), alpha: alpha)
    }

    private func symbol(_ name: String, _ size: CGFloat, _ color: NSColor, in r: NSRect, weight: NSFont.Weight = .semibold) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.init(hierarchicalColor: color))) else { return }
        let s = img.size
        img.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
    }

    public override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        let separator = shade(isLight ? 0.12 : 0.16, alpha: isLight ? 0.26 : 0.36)
        let active = T.Colors.textPrimary.nsColor, inactive = T.Colors.textSecondary.nsColor
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: 0, width: tabsWidth, height: bounds.height).clip()
        for (i, item) in items.enumerated() {
            let r = tabRect(i)
            guard r.maxX > 0, r.minX < tabsWidth, r.intersects(dirtyRect) else { continue }
            let sel = i == selected
            if sel {
                shade(isLight ? 0.065 : 0.12).setFill()
                r.fill()
            } else if i == hovered {
                shade(isLight ? 0.03 : 0.07, alpha: 0.78).setFill()
                r.fill()
            }
            separator.setFill()
            NSRect(x: r.maxX - 1, y: 0, width: 1, height: r.height - (i + 1 == selected ? 1 : 0)).fill()
            let color = sel ? active : inactive
            symbol(item.agent ? "sparkle" : "terminal", 10, color,
                   in: NSRect(x: r.minX + Self.padX, y: (r.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize),
                   weight: .medium)
            let tx = r.minX + Self.padX + Self.iconSize + Self.spacing
            let right = (zoomRect(i)?.minX ?? closeRect(i).minX) - 2
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let h = ceil(Self.font.ascender - Self.font.descender) + 2
            (item.title as NSString).draw(in: NSRect(x: tx, y: (r.height - h) / 2, width: max(0, right - tx), height: h),
                                          withAttributes: [.font: Self.font, .foregroundColor: color, .paragraphStyle: para])
            if let z = zoomRect(i) { symbol("arrow.up.left.and.arrow.down.right", 9, inactive, in: z) }
            let c = closeRect(i)
            if showsClose(i) {
                symbol("xmark", 9, inactive, in: c)
            } else if item.pinned && (sel || i == hovered || !item.badge) {
                symbol("pin.fill", 9, inactive, in: c)
            } else if item.badge {
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.midX - 3, y: c.midY - 3, width: 6, height: 6)).fill()
            }
        }
        // The bottom rule, open under the shown tab; the accent line on its top edge.
        separator.setFill()
        let y = bounds.height - 1
        let sr = items.indices.contains(selected) ? tabRect(selected) : .zero
        NSRect(x: 0, y: y, width: max(0, sr.minX), height: 1).fill()
        NSRect(x: sr.maxX, y: y, width: max(0, tabsWidth - sr.maxX), height: 1).fill()
        if items.indices.contains(selected) {
            (focused ? NSColor.controlAccentColor : NSColor.systemGray).setFill()
            NSRect(x: sr.minX, y: 0, width: max(0, sr.width - 1), height: Self.indicator).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        separator.setFill()
        NSRect(x: tabsWidth, y: y, width: max(0, bounds.width - tabsWidth), height: 1).fill()
        if let b = modeBadge {
            let sz = ModeBadge.size(b)
            ModeBadge.draw(b, in: NSRect(x: tabsWidth + 4, y: (bounds.height - sz.height) / 2, width: sz.width, height: sz.height))
        }
        for (b, name) in ["terminal", "square.split.2x1", "square.split.1x2"].enumerated() {
            symbol(name, 12, b == hoveredButton ? active : inactive, in: buttonRect(b), weight: .regular)
        }
    }

    // MARK: Mouse (no timers: hover comes from a tracking area)

    private var tracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func setHovered(_ i: Int?, button b: Int?) {
        guard i != hovered || b != hoveredButton else { return }
        hovered = i
        hoveredButton = b
        needsDisplay = true
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setHovered(index(at: p), button: button(at: p))
    }
    public override func mouseExited(with event: NSEvent) { setHovered(nil, button: nil) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tab(_ i: Int) -> Pane? { node.flatMap { $0.tabs.indices.contains(i) ? $0.tabs[i] : nil } }

    public override func scrollWheel(with event: NSEvent) {
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard contentWidth > tabsWidth, d != 0 else { return super.scrollWheel(with: event) }
        scroll -= d * (event.hasPreciseScrollingDeltas ? 1 : 10)
        clampScroll()
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let b = button(at: p) { pressButton(b); return }
        guard let i = index(at: p) else {
            // The empty part: a click focuses the pane, a double-click opens a tab.
            guard let shown = node?.shownTab else { return }
            if event.clickCount == 2 { controller?.newTab(shown) } else { controller?.selectTab(shown) }
            return
        }
        if let z = zoomRect(i), z.contains(p), let t = tab(i) { controller?.toggleZoom(for: t); return }
        if event.clickCount == 2, let t = tab(i) { controller?.toggleZoom(for: t); return }
        let onClose = showsClose(i) && closeRect(i).insetBy(dx: -2, dy: -2).contains(p)
        // Selecting happens on the mouse-up (cmux's tap): selecting now would rebuild the pane views
        // and take this strip out of the window in the middle of the press (a drag would be lost).
        press = (i, p.x, onClose, false)
        pressed = tab(i)
    }

    func pressButton(_ b: Int) {
        guard let shown = node?.shownTab, let c = controller else { return }
        switch b {
        case 0: c.newTab(shown)
        case 1: c.split(shown, .right)
        default: c.split(shown, .down)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard var pr = press, !pr.onClose, let c = controller, let t = pressed,
              let at = node?.tabs.firstIndex(where: { $0 === t }) else { return }
        pr.index = at
        let p = convert(event.locationInWindow, from: nil)
        if !pr.dragging && abs(p.x - pr.x) < 4 && p.y >= 0 && p.y <= bounds.height { return }
        pr.dragging = true
        if bounds.insetBy(dx: 0, dy: -8).contains(p) {
            // In its own strip: a live reorder, the tab takes the slot under the pointer.
            drop = nil
            c.showTabDrop(nil)
            let to = items.indices.first { tabRect($0).maxX > p.x } ?? items.count - 1
            if to != pr.index {
                c.moveTab(t, to: to)
                if let n = node?.tabs.firstIndex(where: { $0 === t }) { pr.index = n }
            }
        } else {
            // Out of it: onto another strip, or a pane (its middle, or an edge to split it).
            let target = c.tabDrop(for: t, at: event.locationInWindow)
            drop = target?.0
            c.showTabDrop(target?.1)
        }
        press = pr
    }

    public override func mouseUp(with event: NSEvent) {
        defer { press = nil; pressed = nil; drop = nil }
        guard let pr = press, let t = pressed, let i = node?.tabs.firstIndex(where: { $0 === t }) else {
            controller?.showTabDrop(nil)
            return
        }
        if let d = drop {
            controller?.showTabDrop(nil)
            controller?.performTabDrop(t, d)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        // A click (no drag): select. A drag in the strip only reorders, as in cmux.
        guard pr.onClose else { if !pr.dragging { controller?.selectTab(t) }; return }
        if closeRect(i).insetBy(dx: -2, dy: -2).contains(p) { controller?.requestCloseTab(t) }
    }

    /// Middle-click closes a tab (as in browsers).
    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        middleClicked(at: convert(event.locationInWindow, from: nil))
    }

    func middleClicked(at p: NSPoint) {
        if let i = index(at: p), let t = tab(i), !t.pinned { controller?.requestCloseTab(t) }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(event.locationInWindow, from: nil)), let t = tab(i) else { return nil }
        return controller?.tabMenu(for: t)
    }
}
