import AppKit

// Sidebar selection and closing (Finder conventions): a plain click selects one row, ⌘-click
// toggles a row, ⇧-click selects the range from the anchor. The active workspace (on screen) is
// the last clicked row. The row × (on hover), ⌘W / ⇧⌘W and the row menu close the selection
// when the row is part of it, otherwise just that row; busy panes ask once for all of them.

extension LmuxController {
    /// A click on a sidebar row. Control-click is the context menu, not a selection change.
    public func clickRow(_ ws: Workspace, modifiers: NSEvent.ModifierFlags) {
        guard model.workspaces.contains(where: { $0 === ws }) else { return }
        let m = modifiers.intersection([.command, .shift, .control])
        if m.contains(.control) { return }
        let ids = model.workspaces.map(\.id)
        var sel = model.isMultiSelection ? model.selection : Set([model.selectedID].compactMap { $0 })
        if m.contains(.shift), let anchor = model.selectionAnchorID ?? model.selectedID,
           let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: ws.id) {
            select(ws)
            setSelection(Set(ids[min(a, b)...max(a, b)]), anchor: anchor)
            sidebarEscapeArmed = true
        } else if m.contains(.command) {
            if sel.contains(ws.id) {
                guard sel.count > 1 else { return }  // the last selected row stays selected
                sel.remove(ws.id)
                if ws.id == model.selectedID, let i = ids.firstIndex(of: ws.id),
                   let next = ids[(i + 1)...].first(where: sel.contains) ?? ids[..<i].last(where: sel.contains),
                   let w = model.workspaces.first(where: { $0.id == next }) {
                    select(w)  // the active one moves to the nearest selected row
                }
                setSelection(sel, anchor: model.selectedID)
            } else {
                sel.insert(ws.id)
                select(ws)
                setSelection(sel, anchor: ws.id)
            }
            sidebarEscapeArmed = true
        } else {
            select(ws)
            setSelection([], anchor: ws.id)
        }
    }

    func setSelection(_ ids: Set<String>, anchor: String?) {
        let wasMulti = model.isMultiSelection
        model.selection = ids.count > 1 ? ids : []
        model.selectionAnchorID = anchor
        if model.isMultiSelection || wasMulti {
            let n = model.isMultiSelection ? model.selection.count : 1
            announceSelection(n == 1 ? "1 workspace selected" : "\(n) workspaces selected")
        }
    }

    /// Esc: back to just the active workspace.
    public func clearMultiSelection() {
        guard model.isMultiSelection else { return }
        setSelection([], anchor: model.selectedID)
    }

    private func announceSelection(_ text: String) {
        lastSelectionAnnouncement = text
        NSAccessibility.post(element: window as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Esc right after ⌘/⇧-clicking rows clears the multi-selection (the keyboard stays in the
    /// pane otherwise). Any other key disarms it and goes to the terminal as usual. Esc also
    /// cancels a sidebar drag-to-reorder in progress, whether or not that flag is armed.
    func handleSidebarKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 0x35, model.sidebarDrag != nil, model.sidebarVisible {
            cancelSidebarDrag()
            return true
        }
        guard sidebarEscapeArmed else { return false }
        sidebarEscapeArmed = false
        guard event.keyCode == 0x35, model.isMultiSelection,
              event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
              !(model.selected?.focusedPane.map(cardShown) ?? false) else { return false }
        clearMultiSelection()
        return true
    }

    /// The Close Pane shortcut (⌘W) with a multi-selection: close the selected workspaces.
    func handleCloseSelectionKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, model.isMultiSelection, let item = closePaneMenuItem,
              !item.keyEquivalent.isEmpty,
              event.charactersIgnoringModifiers == item.keyEquivalent,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == item.keyEquivalentModifierMask
        else { return false }
        menuClosePane(item)
        return true
    }

    /// What closing from `ws`'s row (×, menu) closes: the whole selection when the row is in a
    /// multi-selection, else just that row.
    public func closeTargets(for ws: Workspace) -> [Workspace] {
        model.isMultiSelection && model.selection.contains(ws.id) ? model.selectedWorkspaces : [ws]
    }

    public func closeTitle(count n: Int) -> String { n > 1 ? "Close \(n) Workspaces" : "Close Workspace" }

    /// The row ×: closes the row (or the selection it is part of), asking first if anything runs.
    public func closeFromRow(_ ws: Workspace) {
        requestCloseWorkspaces(closeTargets(for: ws))
    }

    /// Close workspaces; when any pane runs something other than an idle shell, one confirmation
    /// (the ⌘W card, on the visible pane) names each busy workspace and its process.
    public func requestCloseWorkspaces(_ list: [Workspace]) {
        let list = list.filter { w in model.workspaces.contains { $0 === w } }
        guard !list.isEmpty else { return }
        let busy = list.compactMap { w -> (Workspace, String)? in
            w.panes.lazy.compactMap { self.runningProcess($0) }.first.map { (w, $0) }
        }
        guard !busy.isEmpty, let host = model.selected?.focusedPane ?? list[0].focusedPane else {
            closeWorkspaces(list)
            return
        }
        let message: NSAttributedString
        if list.count == 1 {
            message = Self.bold("Close “\(list[0].title)”? ", busy[0].1, " is still running.")
        } else {
            let m = NSMutableAttributedString(attributedString: Self.bold("Close \(list.count) workspaces? ", "", ""))
            for (i, (w, proc)) in busy.enumerated() {
                m.append(Self.bold((i == 0 ? "" : ", ") + "“\(w.title)” is running ", proc, ""))
            }
            m.append(Self.bold(".", "", ""))
            message = m
        }
        let detail = busy.count == 1 ? "Closing terminates the process." : "Closing terminates the processes."
        showCard(host, message: message, detail: detail, confirmTitle: list.count == 1 ? "Close" : "Close \(list.count)",
                 onConfirm: { [weak self] in self?.closeWorkspaces(list) })
    }

    /// Close several workspaces at once. If the active one goes, the next row below that stays
    /// (else the one above) becomes active; closing every workspace leaves a fresh one.
    public func closeWorkspaces(_ list: [Workspace]) {
        let ids = Set(list.map(\.id))
        let all = model.workspaces
        if let sel = model.selectedID, ids.contains(sel), let i = all.firstIndex(where: { $0.id == sel }),
           let next = all[(i + 1)...].first(where: { !ids.contains($0.id) }) ?? all[..<i].last(where: { !ids.contains($0.id) }) {
            select(next)
        }
        for w in list { closeWorkspace(w) }
    }

    /// The row's context menu (Control-click / right-click): nil is a separator.
    public func rowMenu(for ws: Workspace) -> [(title: String, run: () -> Void)?] {
        let targets = closeTargets(for: ws)
        var items: [(title: String, run: () -> Void)?] = [
            (closeTitle(count: targets.count), { [weak self] in self?.requestCloseWorkspaces(targets) }),
        ]
        if targets.count == 1 { items.append(("Rename Workspace…", { [weak self] in self?.promptRename(ws) })) }
        items.append(nil)
        items.append(("Clear Status", { [weak self] in self?.clearStatus(for: ws) }))
        return items
    }
}

extension LmuxController: NSMenuItemValidation {
    /// Close titles follow the selection ("Close 3 Workspaces"); Zoom Split's title tracks
    /// whether the selected workspace is currently zoomed.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let n = model.isMultiSelection ? model.selection.count : 1
        if item.action == #selector(menuCloseWorkspace(_:)) { item.title = closeTitle(count: n) }
        if item.action == #selector(menuClosePane(_:)) {
            item.title = n > 1 ? closeTitle(count: n) : focusedLeafHasTabs ? "Close Tab" : "Close Pane"
        }
        if item.action == #selector(menuToggleSplitZoom(_:)) { item.title = model.selected?.isZoomed == true ? "Unzoom Split" : "Zoom Split" }
        return true
    }
}
