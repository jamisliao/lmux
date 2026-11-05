import AppKit
import GhosttyKit
import LmuxTerminal

// Main menu. Shortcuts that Ghostty also binds (new_split, close_surface,
// goto_tab, ...) take their key equivalent from the user's Ghostty config, so
// a `keybind = ...` remap shows up (and an unbind removes it). When a terminal
// has focus, libghostty handles those keys first and calls back through the
// action handler; the menu covers everything else.
//
// lmux-only shortcuts:
//   ⇧⌘U   jump to the latest unread (same as ⌥-clicking the bell; a click opens the notification list)
//   ⌘⇧J   jump to the next session that needs input (cycles)
//   ⌃⌘S   toggle sidebar
//   ⌥⌘C   copy the last Claude reply as original markdown
//   ⌘Z    undo send (while the toast is up; Ghostty's `undo` binding routes here too)
//   Tabs in a pane take cmux's keys: Ghostty's tab actions are the pane's tabs (new_tab ⌘T,
//   next_tab / previous_tab ⇧⌘] / ⇧⌘[ and ⌃⇥ / ⌃⇧⇥), ⌃1…⌃9 select one, ⌥⇧⌘] / ⌥⇧⌘[ move it, ⌘R renames
//   it, ⌥⌘T closes the others; workspaces switch with ⌃⌘] / ⌃⌘[ (and ⌘1…⌘9, Ghostty's goto_tab).
// Ghostty's own, surfaced in the menus: ⌘F find (⌘G / ⇧⌘G next / previous, esc closes),
// Secure Keyboard Entry (app menu; also Ghostty's `toggle_secure_input`).

extension LmuxController {
    public func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About lmux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(openSettings), ghostty: "open_config", fallback: (",", .command))
        add(appMenu, "Import from cmux…", #selector(menuImportFromCmux(_:)))
        if cmuxUndo != nil { add(appMenu, "Undo cmux Import", #selector(menuUndoCmuxImport(_:))) }
        appMenu.addItem(.separator())
        add(appMenu, "Install Claude Code Hooks…", #selector(installHooksMenu(_:)))
        add(appMenu, "Uninstall Claude Code Hooks…", #selector(uninstallHooksMenu(_:)))
        add(appMenu, "Install Codex Hooks…", #selector(installCodexHooksMenu(_:)))
        add(appMenu, "Uninstall Codex Hooks…", #selector(uninstallCodexHooksMenu(_:)))
        appMenu.addItem(.separator())
        secureInputMenuItem = add(appMenu, "Secure Keyboard Entry", #selector(menuToggleSecureInput(_:)))
        secureInputMenuItem?.state = secureKeyboardEntry ? .on : .off
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide lmux", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit lmux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "Workspace")
        add(file, "New Workspace", #selector(menuNewWorkspace(_:)), ghostty: "new_window", fallback: ("n", .command))
        add(file, "New Tab", #selector(menuNewTab(_:)), ghostty: "new_tab", fallback: ("t", .command))
        add(file, "Split Right", #selector(menuSplitRight(_:)), ghostty: "new_split:right", fallback: ("d", .command))
        add(file, "Split Down", #selector(menuSplitDown(_:)), ghostty: "new_split:down", fallback: ("d", [.command, .shift]))
        file.addItem(.separator())
        closePaneMenuItem = add(file, "Close Pane", #selector(menuClosePane(_:)), ghostty: "close_surface", fallback: ("w", .command))
        add(file, "Close Other Tabs", #selector(menuCloseOtherTabs(_:)), fallback: ("t", [.command, .option]), id: "closeOtherTabs")
        add(file, "Close Workspace", #selector(menuCloseWorkspace(_:)), ghostty: "close_window", fallback: ("w", [.command, .shift]))
        add(file, "Rename Tab…", #selector(menuRenameTab(_:)), fallback: ("r", .command), id: "renameTab")
        add(file, "Rename Workspace…", #selector(menuRename(_:)), id: "renameWorkspace")
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        add(edit, "Undo Send", #selector(menuUndoSend(_:)), fallback: ("z", .command))
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy", action: #selector(SurfaceView.copy(_:)), keyEquivalent: "c")
        add(edit, "Copy Original Reply", #selector(menuCopyOriginal(_:)), fallback: ("c", [.command, .option]))
        edit.addItem(withTitle: "Paste", action: #selector(SurfaceView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        add(edit, "Find…", #selector(menuFind(_:)), ghostty: "start_search", fallback: ("f", .command))
        add(edit, "Find Next", #selector(menuFindNext(_:)), ghostty: "navigate_search:next", fallback: ("g", .command))
        add(edit, "Find Previous", #selector(menuFindPrevious(_:)), ghostty: "navigate_search:previous",
            fallback: ("g", [.command, .shift]))
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        add(view, "Toggle Sidebar", #selector(menuToggleSidebar(_:)), fallback: ("s", [.command, .control]), id: "toggleSidebar")
        add(view, "Search History", #selector(menuSearchHistory(_:)), fallback: ("h", [.command, .shift]))
        view.addItem(.separator())
        splitZoomMenuItem = add(view, "Zoom Split", #selector(menuToggleSplitZoom(_:)), ghostty: "toggle_split_zoom",
                                fallback: ("\r", [.command, .shift]), id: "toggleSplitZoom")
        view.addItem(.separator())
        // Ghostty's own bindings (they act on the focused pane; the keys come from its config).
        for (title, action) in [("Increase Font Size", "increase_font_size:1"), ("Decrease Font Size", "decrease_font_size:1"),
                                ("Reset Font Size", "reset_font_size"), ("Clear Screen", "clear_screen")] {
            let item = add(view, title, #selector(menuGhosttyBinding(_:)), ghostty: action)
            item.representedObject = action
        }
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        view.addItem(.separator())
        add(view, "Jump to Latest Unread", #selector(menuLatestUnread(_:)), fallback: ("u", [.command, .shift]), id: "jumpToUnread")
        add(view, "Show Notifications", #selector(menuShowNotifications(_:)), id: "showNotifications")
        add(view, "Jump to Agent That Needs You", #selector(menuNextNeedsInput(_:)), fallback: ("j", [.command, .shift]))
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        add(win, "Next Pane", #selector(menuNextPane(_:)), ghostty: "goto_split:next", fallback: ("]", .command))
        add(win, "Previous Pane", #selector(menuPreviousPane(_:)), ghostty: "goto_split:previous", fallback: ("[", .command))
        add(win, "Next Tab", #selector(menuNextTab(_:)), ghostty: "next_tab", fallback: ("]", [.command, .shift]))
        add(win, "Previous Tab", #selector(menuPreviousTab(_:)), ghostty: "previous_tab", fallback: ("[", [.command, .shift]))
        add(win, "Move Tab Right", #selector(menuMoveTabRight(_:)), fallback: ("]", [.command, .shift, .option]), id: "moveTabRight")
        add(win, "Move Tab Left", #selector(menuMoveTabLeft(_:)), fallback: ("[", [.command, .shift, .option]), id: "moveTabLeft")
        add(win, "Next Workspace", #selector(menuNextWorkspace(_:)), fallback: ("]", [.command, .control]), id: "nextWorkspace")
        add(win, "Previous Workspace", #selector(menuPreviousWorkspace(_:)), fallback: ("[", [.command, .control]), id: "previousWorkspace")
        win.addItem(.separator())
        for i in 1...9 {
            let item = add(win, i == 9 ? "Select Last Tab" : "Select Tab \(i)", #selector(menuSelectTab(_:)), fallback: ("\(i)", .control))
            item.tag = i
        }
        win.addItem(.separator())
        for i in 1...9 {
            let action = i == 9 ? "last_tab" : "goto_tab:\(i)"
            let item = add(win, i == 9 ? "Select Last Workspace" : "Select Workspace \(i)",
                           #selector(menuSelectWorkspace(_:)), ghostty: action, fallback: ("\(i)", .command))
            item.tag = i
        }
        win.addItem(.separator())
        win.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = win
        main.addItem(windowItem)
        NSApp.windowsMenu = win

        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        // macOS adds its own search field to this menu automatically.
        add(help, "Keyboard Shortcuts", #selector(menuKeyboardShortcuts(_:)))
        add(help, "Report an Issue…", #selector(menuReportIssue(_:)))
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, ghostty action: String? = nil,
                     fallback: (String, NSEvent.ModifierFlags)? = nil, id: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        if let id, let s = settings.shortcuts[id], let (key, mods) = parseShortcut(s) {
            // An lmux-only shortcut the user changed (imported from cmux).
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        } else if let action {
            // Ghostty's binding wins; no binding (user unbound it) means no shortcut.
            if let (key, mods) = keyEquivalent(forGhosttyAction: action) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = mods
            }
        } else if let (key, mods) = fallback {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mods
        }
        // AppKit matches a shifted letter by its uppercase form (⇧⌘J arrives as "J").
        if item.keyEquivalentModifierMask.contains(.shift), item.keyEquivalent.count == 1,
           item.keyEquivalent.first!.isLetter {
            item.keyEquivalent = item.keyEquivalent.uppercased()
        }
        menu.addItem(item)
        return item
    }

    /// Key equivalent for a Ghostty keybind action, from the loaded config.
    func keyEquivalent(forGhosttyAction action: String) -> (String, NSEvent.ModifierFlags)? {
        guard let cfg = runtime.config else { return nil }
        let t = ghostty_config_trigger(cfg, action, UInt(action.lengthOfBytes(using: .utf8)))
        var mods: NSEvent.ModifierFlags = []
        if t.mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { mods.insert(.shift) }
        if t.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { mods.insert(.control) }
        if t.mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { mods.insert(.option) }
        if t.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { mods.insert(.command) }
        switch t.tag {
        case GHOSTTY_TRIGGER_UNICODE:
            guard t.key.unicode != 0, let s = UnicodeScalar(t.key.unicode) else { return nil }
            return (String(Character(s)).lowercased(), mods)
        case GHOSTTY_TRIGGER_PHYSICAL:
            let k = t.key.physical
            if k.rawValue >= GHOSTTY_KEY_DIGIT_0.rawValue && k.rawValue <= GHOSTTY_KEY_DIGIT_9.rawValue {
                return (String(k.rawValue - GHOSTTY_KEY_DIGIT_0.rawValue), mods)
            }
            if k.rawValue >= GHOSTTY_KEY_A.rawValue && k.rawValue <= GHOSTTY_KEY_Z.rawValue,
               let s = UnicodeScalar(UInt32(97) + k.rawValue - GHOSTTY_KEY_A.rawValue) {
                return (String(Character(s)), mods)
            }
            let named: [UInt32: Int] = [
                GHOSTTY_KEY_ARROW_UP.rawValue: NSUpArrowFunctionKey,
                GHOSTTY_KEY_ARROW_DOWN.rawValue: NSDownArrowFunctionKey,
                GHOSTTY_KEY_ARROW_LEFT.rawValue: NSLeftArrowFunctionKey,
                GHOSTTY_KEY_ARROW_RIGHT.rawValue: NSRightArrowFunctionKey,
            ]
            if let fk = named[k.rawValue], let s = UnicodeScalar(fk) { return (String(Character(s)), mods) }
            if k == GHOSTTY_KEY_BRACKET_LEFT { return ("[", mods) }
            if k == GHOSTTY_KEY_BRACKET_RIGHT { return ("]", mods) }
            if k == GHOSTTY_KEY_ENTER { return ("\r", mods) }
            return nil
        default:
            return nil
        }
    }

    private var focusedPane: Pane? { model.selected?.focusedPane }

    /// A Ghostty binding action (the item's representedObject) on the focused pane.
    @objc func menuGhosttyBinding(_ s: Any?) {
        guard let action = (s as? NSMenuItem)?.representedObject as? String else { return }
        // Font size or Clear Screen would redraw a pane lmux is reading to drive Claude's rewind.
        guard focusedPane?.surface.inputHeld != true else { NSSound.beep(); return }
        _ = focusedPane?.surface.performBindingAction(action)
    }

    @objc func menuNewWorkspace(_ s: Any?) {
        newWorkspace()
        if !headless, !window.isVisible || window.isMiniaturized { reopenWindow() }
    }
    @objc func menuNewTab(_ s: Any?) { if let p = focusedPane { newTab(p) } }
    @objc func menuNextTab(_ s: Any?) { selectTabRelative(1) }
    @objc func menuPreviousTab(_ s: Any?) { selectTabRelative(-1) }
    @objc func menuMoveTabRight(_ s: Any?) { moveFocusedTab(1) }
    @objc func menuMoveTabLeft(_ s: Any?) { moveFocusedTab(-1) }
    @objc func menuSelectTab(_ s: Any?) { if let tag = (s as? NSMenuItem)?.tag { selectTab(number: tag) } }
    @objc func menuRenameTab(_ s: Any?) { if let p = focusedPane { promptRenamePane(p) } }
    @objc func menuCloseOtherTabs(_ s: Any?) {
        guard let p = focusedPane, let leaf = p.workspace?.root.find(p) else { return }
        requestCloseTabs(leaf.tabs, anchor: p)
    }
    /// The focused pane is one of several tabs (⌘W says "Close Tab").
    var focusedLeafHasTabs: Bool { focusedPane.flatMap { $0.workspace?.root.find($0) }?.hasTabs ?? false }
    @objc func menuSplitRight(_ s: Any?) { if let p = focusedPane { split(p, .right) } }
    @objc func menuSplitDown(_ s: Any?) { if let p = focusedPane { split(p, .down) } }
    @objc func menuClosePane(_ s: Any?) {
        if model.isMultiSelection { requestCloseWorkspaces(model.selectedWorkspaces) } else if let p = focusedPane { requestClosePane(p) }
    }
    @objc func menuCloseWorkspace(_ s: Any?) { requestCloseWorkspaces(model.selectedWorkspaces) }
    @objc func menuRename(_ s: Any?) { if let w = model.selected { promptRename(w) } }
    @objc func menuToggleSidebar(_ s: Any?) { toggleSidebar() }
    @objc func menuToggleSplitZoom(_ s: Any?) { toggleSplitZoom() }
    @objc func menuSearchHistory(_ s: Any?) { searchHistory() }

    /// ⇧⌘H: the History field takes the keyboard (the sidebar comes back if hidden).
    public func searchHistory() {
        if !model.sidebarVisible { toggleSidebar() }
        history.focusRequest += 1
        history.start()
        // SwiftUI applies a focus request only in the key window (and not before a sidebar that was
        // hidden is laid out): once it is, hand the same field the keyboard through AppKit too.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !(self.window.firstResponder is NSText) else { return }
                self.root.layoutSubtreeIfNeeded()
                if let field = Self.editableTextField(in: self.root.sidebarHost) { self.window.makeFirstResponder(field) }
            }
        }
    }

    /// The History search field: the sidebar's only editable text field.
    static func editableTextField(in view: NSView) -> NSTextField? {
        if let f = view as? NSTextField, f.isEditable, !f.isHidden { return f }
        for v in view.subviews { if let f = editableTextField(in: v) { return f } }
        return nil
    }
    @objc func menuLatestUnread(_ s: Any?) { jumpToLatestUnread() }
    @objc func menuShowNotifications(_ s: Any?) { bellClicked(modifiers: []) }
    @objc func menuNextNeedsInput(_ s: Any?) { jumpToNextNeedsInput() }
    @objc func menuNextPane(_ s: Any?) { moveFocus(.next) }
    @objc func menuPreviousPane(_ s: Any?) { moveFocus(.previous) }
    @objc func menuNextWorkspace(_ s: Any?) { selectRelative(1) }
    @objc func menuPreviousWorkspace(_ s: Any?) { selectRelative(-1) }
    @objc func menuSelectWorkspace(_ s: Any?) {
        guard let tag = (s as? NSMenuItem)?.tag else { return }
        selectWorkspace(at: tag == 9 ? model.workspaces.count - 1 : tag - 1)
    }

    @objc func menuKeyboardShortcuts(_ s: Any?) {
        guard !headless else { return }
        NSWorkspace.shared.open(URL(string: "https://github.com/sooftware/lmux#usage")!)
    }
    @objc func menuReportIssue(_ s: Any?) {
        guard !headless else { return }
        NSWorkspace.shared.open(URL(string: "https://github.com/sooftware/lmux/issues/new/choose")!)
    }
}
