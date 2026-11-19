// @feature: liquid-glass-app.feature
// @scenario: 標題列置中顯示目前 workspace 資訊膠囊與快速操作按鈕
// @scenario: 左側 workspace 卡片顯示彩色識別條與狀態藥丸並保留多選與排序
// @scenario: 中央終端窗格顯示圓角卡片、焦點光環與 Pane Tab Strip
// @scenario: 透過快捷鍵與標題列／狀態列控制右側 Inspector 展開、收合與分頁切換

import AppKit
import LmuxTokens
import LmuxHooks
@testable import LmuxNotificationBar
@testable import LmuxUI

@MainActor
func runLiquidGlass() async -> Int32 {
    let r = Report()
    let c = makeController()
    let w = c.window!
    r.section = "liquid-glass"

    func mouseEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 200, y: 200),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: w.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    // 1. SidebarBackdrop 一般毛玻璃 + 1pt 頂部亮邊 vs 不透明實底與跟隨終端機底色
    let bd = c.root.sidebarBackdrop
    let savedForceOpaque = bd.forceOpaque
    let savedMatch = bd.matchColor
    bd.matchColor = nil
    bd.forceOpaque = false
    bd.isResizing = false
    c.root.layoutSubtreeIfNeeded()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        r.check("SidebarBackdrop: translucent material and 1pt top specular edge shown when idle",
                !bd.isOpaqueFallback && !bd.material.isHidden && !bd.specular.isHidden && bd.specular.frame.height == 1)
    }
    bd.forceOpaque = true
    var expectedOpaque: NSColor?
    var actualTint: NSColor?
    bd.effectiveAppearance.performAsCurrentDrawingAppearance {
        expectedOpaque = LmuxTokens.Colors.sidebarBackground.nsColor.usingColorSpace(.sRGB)
        actualTint = bd.tint.color.usingColorSpace(.sRGB)
    }
    r.check("SidebarBackdrop: opaque fallback hides NSVisualEffectView, specular edge, and uses sidebarBackground",
            bd.isOpaqueFallback && bd.material.isHidden && bd.specular.isHidden &&
            expectedOpaque != nil && actualTint == expectedOpaque)
    bd.forceOpaque = false
    bd.matchColor = .black
    r.check("SidebarBackdrop: terminal matchColor hides NSVisualEffectView, specular edge, and applies matchColor",
            bd.material.isHidden && bd.specular.isHidden && bd.tint.color == NSColor.black)
    bd.matchColor = nil

    // 2. 四種拖曳調整大小目標期間暫停毛玻璃並在放開後恢復
    // (a) sidebar 寬度手把
    c.root.resizeHandle.mouseDown(with: mouseEvent(.leftMouseDown))
    r.check("SidebarResizeHandle mouseDown pauses blur (isResizing == true)",
            bd.isResizing && bd.isOpaqueFallback && bd.material.isHidden && bd.specular.isHidden)
    c.root.resizeHandle.mouseUp(with: mouseEvent(.leftMouseUp))
    r.check("SidebarResizeHandle mouseUp restores blur (isResizing == false)", !bd.isResizing)

    // (b) 窗格分割線（含移出視窗清理）
    if let ws = c.model.selected, let p0 = ws.focusedPane {
        let pSplit = c.split(p0, .right)
        if let sv = c.splitView(for: ws.root) {
            sv.mouseDown(with: mouseEvent(.leftMouseDown))
            r.check("SplitContainerView divider mouseDown pauses blur",
                    bd.isResizing && bd.isOpaqueFallback && bd.material.isHidden)
            sv.mouseUp(with: mouseEvent(.leftMouseUp))
            r.check("SplitContainerView divider mouseUp restores blur", !bd.isResizing)
            sv.mouseDown(with: mouseEvent(.leftMouseDown))
            sv.removeFromSuperview()
            r.check("SplitContainerView removed mid-drag clears isResizing", !bd.isResizing)
        } else {
            r.check("SplitContainerView created for split workspace", false)
        }
        if let pSplit { c.closePane(pSplit) }
    }

    // (c) 通知 bar 高度手把（安裝 NotificationBarPlugin 並透過獨立 UserDefaults suite 驅動實際 BarLayout）
    let suiteName = "dev.lmux.apptest.liquid-glass.\(UUID().uuidString)"
    let testDefaults = UserDefaults(suiteName: suiteName)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let barLayout = NotificationBarPlugin.install(on: c, defaults: testDefaults)
    c.root.layoutSubtreeIfNeeded()
    let savedExtra = barLayout.extra
    barLayout.updateDrag(translationHeight: -40, maxExtra: 200, on: c)
    r.check("BarResizeHandle / BarLayout drag pauses blur and increases bar height",
            barLayout.isDragging && c.isSidebarResizing && bd.isOpaqueFallback && barLayout.extra == savedExtra + 40)
    barLayout.endDrag(on: c)
    r.check("BarResizeHandle / BarLayout endDrag restores blur and writes scoped defaults",
            !barLayout.isDragging && !c.isSidebarResizing && !bd.isResizing &&
            testDefaults.double(forKey: BarLayout.defaultsKey) == Double(savedExtra + 40))

    // Task 11b: BarLayout collapse threshold, toggleCollapsed, auto-collapse on drag, and upward expand
    r.check("BarLayout.collapseDragThreshold is 42", BarLayout.collapseDragThreshold == 42)
    r.check("BarLayout initially not collapsed", !barLayout.isCollapsed)
    barLayout.toggleCollapsed(on: c)
    r.check("BarLayout toggleCollapsed collapses bar and writes isCollapsed defaults",
            barLayout.isCollapsed && testDefaults.bool(forKey: BarLayout.collapsedDefaultsKey))
    barLayout.toggleCollapsed(on: c)
    r.check("BarLayout toggleCollapsed restores expanded state and original extra",
            !barLayout.isCollapsed && barLayout.extra == savedExtra + 40 &&
            !testDefaults.bool(forKey: BarLayout.collapsedDefaultsKey))

    // Downward drag to total height <= 42 triggers auto-collapse
    barLayout.updateDrag(translationHeight: 300, maxExtra: 200, on: c)
    r.check("BarLayout dragging down past threshold triggers auto-collapse", barLayout.isCollapsed)
    barLayout.endDrag(on: c)
    r.check("BarLayout endDrag preserves collapsed state in defaults",
            testDefaults.bool(forKey: BarLayout.collapsedDefaultsKey))

    // Upward drag from collapsed state immediately expands
    barLayout.updateDrag(translationHeight: -20, maxExtra: 200, on: c)
    r.check("BarLayout dragging upward from collapsed state immediately un-collapses",
            !barLayout.isCollapsed && barLayout.extra > 0)
    barLayout.endDrag(on: c)

    // (d) 視窗邊緣縮放（willStartLiveResize -> didEndLiveResize）
    NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: w)
    r.check("Window willStartLiveResize pauses blur",
            bd.isResizing && bd.isOpaqueFallback && bd.material.isHidden)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: w)
    r.check("Window didEndLiveResize restores blur", !bd.isResizing)

    // 3. 拖曳途中視窗或應用程式失去焦點時自動解除拖曳降級與 BarLayout.isDragging（並可再次拖曳）
    barLayout.updateDrag(translationHeight: -10, maxExtra: 200, on: c)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
    r.check("Window didResignKey mid-drag clears isResizing and BarLayout.isDragging",
            !bd.isResizing && !barLayout.isDragging)

    barLayout.updateDrag(translationHeight: -10, maxExtra: 200, on: c)
    r.check("Subsequent BarLayout drag after interruption re-engages isResizing",
            barLayout.isDragging && c.isSidebarResizing)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    r.check("App didResignActive mid-drag clears isResizing and BarLayout.isDragging",
            !bd.isResizing && !barLayout.isDragging)

    // 4. 選取中的 workspace 列、反白通知卡片與通知 bar 調整手把呈現立體玻璃細節
    if let ws = c.model.selected, let p0 = ws.focusedPane {
        ws.customTitle = "lmux-app"
        p0.branch = "feat/liquid-glass"
        let entry = NotificationEntry(paneID: p0.id, workspaceID: ws.id, title: ws.title,
                                      message: "Glass check ready", kind: "done", read: false)
        c.model.recordNotification(entry)
        let wsName = workspaceName(entry, in: c.model)
        r.check("NotificationCard workspace line includes branch when present",
                NotificationCard.cardWorkspaceText(entry, in: c.model) == "\(wsName) · feat/liquid-glass",
                "actual=\(NotificationCard.cardWorkspaceText(entry, in: c.model)) expected=\(wsName) · feat/liquid-glass")
    }
    r.check("Notification recorded and WorkspaceRowContent & HistoryRow show glassBorder only when selected",
            !c.model.notifications.isEmpty &&
            WorkspaceRowContent.showsGlassBorder(selected: true, inSelection: false) &&
            WorkspaceRowContent.showsGlassBorder(selected: false, inSelection: true) &&
            !WorkspaceRowContent.showsGlassBorder(selected: false, inSelection: false) &&
            HistoryRow.showsGlassBorder(selected: true) &&
            !HistoryRow.showsGlassBorder(selected: false))
    r.check("NotificationCard shows glassBorder when highlighted or hovered, and BarResizeHandle pill highlights when active",
            NotificationCard.showsGlassBorder(highlighted: true, hover: false) &&
            NotificationCard.showsGlassBorder(highlighted: false, hover: true) &&
            !NotificationCard.showsGlassBorder(highlighted: false, hover: false) &&
            NotificationBarPlugin.handleHeight == 6 &&
            BarResizeHandle.pillColor(hover: false, isDragging: false).lightAlpha <
                BarResizeHandle.pillColor(hover: true, isDragging: false).lightAlpha &&
            BarResizeHandle.pillColor(hover: false, isDragging: false).darkAlpha <
                BarResizeHandle.pillColor(hover: false, isDragging: true).darkAlpha)

    bd.matchColor = savedMatch
    bd.forceOpaque = savedForceOpaque

    // 5. Shortcuts ⌘B / ⌃⌘S / ⌥⌘B and toggleInspector()
    let initInspectorVisible = c.model.inspectorVisible

    // toggleInspector()
    c.toggleInspector()
    r.check("c.toggleInspector() toggles inspectorVisible", c.model.inspectorVisible == !initInspectorVisible)
    c.toggleInspector()
    r.check("c.toggleInspector() toggles back", c.model.inspectorVisible == initInspectorVisible)

    // View Menu items
    let viewMenu = NSApp.mainMenu?.items.first(where: { $0.title == "View" || $0.submenu?.title == "View" })?.submenu
    let toggleSidebarItem = viewMenu?.items.first(where: { $0.identifier?.rawValue == "toggleSidebar" })
    let toggleInspectorItem = viewMenu?.items.first(where: { $0.identifier?.rawValue == "toggleInspector" })
    r.check("View menu has Toggle Sidebar with ⌃⌘S",
            toggleSidebarItem != nil && toggleSidebarItem?.keyEquivalent == "s" &&
            toggleSidebarItem?.keyEquivalentModifierMask == [.command, .control])
    r.check("View menu has Toggle Inspector with ⌥⌘B",
            toggleInspectorItem != nil && toggleInspectorItem?.keyEquivalent == "b" &&
            toggleInspectorItem?.keyEquivalentModifierMask == [.command, .option])

    // Key equivalents via window.performKeyEquivalent
    func makeKeyEvent(key: String, chars: String, mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: key,
                         isARepeat: false, keyCode: 11)!
    }

    let cmdB = makeKeyEvent(key: "b", chars: "b", mods: .command)
    let optCmdB = makeKeyEvent(key: "b", chars: "∫", mods: [.command, .option])
    let ctrlCmdS = makeKeyEvent(key: "s", chars: "\u{13}", mods: [.command, .control])

    // ⌥⌘B toggles inspector
    let prevInsp = c.model.inspectorVisible
    let optCmdBHandled = w.performKeyEquivalent(with: optCmdB)
    r.check("⌥⌘B via performKeyEquivalent toggles inspectorVisible",
            optCmdBHandled && c.model.inspectorVisible == !prevInsp)
    _ = w.performKeyEquivalent(with: optCmdB) // restore

    // ⌃⌘S toggles sidebar
    let prevSide = c.model.sidebarVisible
    let ctrlCmdSHandled = w.performKeyEquivalent(with: ctrlCmdS)
    r.check("⌃⌘S via performKeyEquivalent toggles sidebarVisible",
            ctrlCmdSHandled && c.model.sidebarVisible == !prevSide)
    _ = w.performKeyEquivalent(with: ctrlCmdS) // restore

    // ⌘B toggles sidebar when not in NSText
    let curSide = c.model.sidebarVisible
    let cmdBHandled = w.performKeyEquivalent(with: cmdB)
    r.check("⌘B via performKeyEquivalent toggles sidebarVisible",
            cmdBHandled && c.model.sidebarVisible == !curSide)
    _ = w.performKeyEquivalent(with: cmdB) // restore

    // ⌘B does not steal key when firstResponder is NSText
    let dummyTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    w.contentView?.addSubview(dummyTextView)
    w.makeFirstResponder(dummyTextView)
    let sideBeforeInText = c.model.sidebarVisible
    _ = w.performKeyEquivalent(with: cmdB)
    r.check("⌘B does not toggle sidebar when firstResponder is NSText",
            c.model.sidebarVisible == sideBeforeInText)
    dummyTextView.removeFromSuperview()
    c.focusCurrent()

    // 6. TitlebarBackdrop, TitlebarCenterChip layout and TitlebarRightCluster actions
    let tb = TitlebarBackdrop(frame: NSRect(x: 0, y: 0, width: 800, height: 44))
    tb.layout()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        r.check("TitlebarBackdrop: translucent material and specular edge shown when idle",
                !tb.isOpaqueFallback && !tb.material.isHidden && !tb.specular.isHidden && tb.specular.frame.height == 1)
    }
    tb.forceOpaque = true
    r.check("TitlebarBackdrop: forceOpaque hides material and specular edge",
            tb.isOpaqueFallback && tb.material.isHidden && tb.specular.isHidden)
    tb.forceOpaque = false
    tb.isResizing = true
    r.check("TitlebarBackdrop: isResizing engages opaque fallback",
            tb.isOpaqueFallback && tb.material.isHidden && tb.specular.isHidden)
    r.check("TitlebarBackdrop: hitTest returns nil to allow window drag",
            tb.hitTest(NSPoint(x: 100, y: 20)) == nil)

    // TitlebarCenterChip layout computation
    let wide = TitlebarCenterChip.computeChipLayout(availableWidth: 500, title: "lmux", branch: "main", path: "~/src/lmux")
    r.check("computeChipLayout: wide window shows title, branch, and path",
            wide.showBranch && wide.showPath && wide.chipWidth <= 500)

    let med = TitlebarCenterChip.computeChipLayout(availableWidth: 280, title: "lmux", branch: "feat/preview", path: "~/src/lmux")
    r.check("computeChipLayout: medium window shows branch and hides path",
            med.showBranch && !med.showPath && med.chipWidth <= 280)

    let narrow = TitlebarCenterChip.computeChipLayout(availableWidth: 150, title: "lmux-long-title", branch: "feat/preview", path: "~/src/lmux")
    r.check("computeChipLayout: narrow window hides branch and path to prevent overlap",
            !narrow.showBranch && !narrow.showPath && narrow.chipWidth <= 150)

    // TitlebarRightCluster actions
    let prevPanes = c.model.selected?.panes.count ?? 1
    TitlebarRightCluster.actionSplitRight(controller: c)
    r.check("TitlebarRightCluster.actionSplitRight splits right",
            (c.model.selected?.panes.count ?? 0) == prevPanes + 1)

    let prevInsp2 = c.model.inspectorVisible
    TitlebarRightCluster.actionToggleInspector(controller: c)
    r.check("TitlebarRightCluster.actionToggleInspector toggles inspector",
            c.model.inspectorVisible == !prevInsp2)
    TitlebarRightCluster.actionToggleInspector(controller: c) // restore

    // 7. WorkspaceFilter, WorkspaceFilterHeader, WorkspaceRowContent Glass Cards
    let wsIdle = c.model.workspaces[0]
    let wsRun = c.newWorkspace()
    wsRun.customTitle = "ws-running"
    wsRun.focusedPane?.agent.handle(HookEvent(paneID: wsRun.focusedPane!.id, name: HookEvent.Kind.userPromptSubmit.rawValue), focused: true)
    var preBash = HookEvent(paneID: wsRun.focusedPane!.id, name: HookEvent.Kind.preToolUse.rawValue)
    preBash.toolName = "Bash"; preBash.toolArgument = "swift test"
    wsRun.focusedPane?.agent.handle(preBash, focused: true)

    let wsNeed = c.newWorkspace()
    wsNeed.customTitle = "ws-needs-input"
    var ask = HookEvent(paneID: wsNeed.focusedPane!.id, name: HookEvent.Kind.preToolUse.rawValue)
    ask.toolName = "AskUserQuestion"
    wsNeed.focusedPane?.agent.handle(ask, focused: true)

    // (a) WorkspaceFilter matching & filteredWorkspaces
    c.model.workspaceFilter = .all
    r.check("WorkspaceFilter .all matches all workspaces",
            c.model.filteredWorkspaces.count == c.model.workspaces.count)

    c.model.workspaceFilter = .active
    r.check("WorkspaceFilter .active matches running workspace",
            c.model.filteredWorkspaces.contains(where: { $0.id == wsRun.id }) &&
            !c.model.filteredWorkspaces.contains(where: { $0.id == wsIdle.id }))

    c.model.workspaceFilter = .needsInput
    r.check("WorkspaceFilter .needsInput matches needsInput workspace",
            c.model.filteredWorkspaces.contains(where: { $0.id == wsNeed.id }) &&
            !c.model.filteredWorkspaces.contains(where: { $0.id == wsRun.id }))

    // (b) Empty state when filter has no matches
    c.closeWorkspace(wsNeed)
    r.check("WorkspaceFilter .needsInput empty when no matching workspaces",
            c.model.filteredWorkspaces.isEmpty)
    r.check("WorkspaceFilterEmptyView shows empty message and reset button title",
            WorkspaceFilterEmptyView.emptyMessage == "沒有符合篩選條件的工作區" &&
            WorkspaceFilterEmptyView.resetButtonTitle == "重置為全部")
    WorkspaceFilterEmptyView.resetFilter(model: c.model)
    r.check("WorkspaceFilterEmptyView resetFilter restores .all",
            c.model.workspaceFilter == .all && !c.model.filteredWorkspaces.isEmpty)

    // (c) TabDisclosureButton hit rect x: 1..<15 vs AccentStripe x: >=16 safe inset
    r.check("TabDisclosureButton hit target x: 1..<15 does not overlap AccentStripe at x >= 16",
            WorkspaceRow.disclosureLeading + LmuxTokens.Layout.tabDisclosureSize <=
            LmuxTokens.Layout.rowInsetX + LmuxTokens.Layout.rowPaddingX)

    // (d) Status pill text & token mapping
    r.check("WorkspaceStatusPill text reflects states",
            WorkspaceStatusPill.statusText(for: .running(nil)) == "⚡ 執行中" &&
            WorkspaceStatusPill.statusText(for: .needsInput(nil)) == "🔔 需要確認" &&
            WorkspaceStatusPill.statusText(for: .done(nil)) == "✓ 測試通過")

    // 8. History search capsule & result row styling
    r.check("HistorySection search field uses glassSurfaceRecessed, glassBorder, and focusRing",
            HistorySection.searchFieldFillColor(focused: true, hover: false) == LmuxTokens.Colors.glassSurfaceRecessed &&
            HistorySection.searchFieldFillColor(focused: false, hover: true) == LmuxTokens.Colors.glassCardHover &&
            HistorySection.searchFieldBorderColor(focused: true) == LmuxTokens.Colors.focusRing &&
            HistorySection.searchFieldBorderColor(focused: false) == LmuxTokens.Colors.glassBorder)
    r.check("HistoryRow shows glassBorder only when selected",
            HistoryRow.showsGlassBorder(selected: true) && !HistoryRow.showsGlassBorder(selected: false))

    // 9. PaneView 10pt rounded cards & activePaneRing vs RingView amber ring
    let testPane = wsIdle.panes[0]
    let paneView = testPane.view
    r.check("PaneView cornerRadius is 10pt (paneCornerRadius)",
            paneView.layer?.cornerRadius == LmuxTokens.Layout.paneCornerRadius)
    paneView.isFocused = true
    r.check("PaneView focused has activePaneRing border (1.5pt)",
            PaneView.borderColor(isFocused: true) == LmuxTokens.Colors.activePaneRing &&
            PaneView.borderWidth(isFocused: true) == 1.5)
    paneView.isFocused = false
    r.check("PaneView unfocused has glassBorder (0.5pt)",
            PaneView.borderColor(isFocused: false) == LmuxTokens.Colors.glassBorder &&
            PaneView.borderWidth(isFocused: false) == 0.5)
    r.check("RingView uses amber stateNeedsInput color (distinct from blue activePaneRing)",
            RingView.strokeColor == LmuxTokens.Colors.stateNeedsInput &&
            RingView.strokeColor != LmuxTokens.Colors.activePaneRing)

    // 10a-1. RightInspectorBackdrop & RightInspectorResizeHandle
    let inspectorBackdrop = RightInspectorBackdrop(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
    r.check("RightInspectorBackdrop: translucent material and specular edge shown when idle",
            !inspectorBackdrop.material.isHidden && !inspectorBackdrop.specular.isHidden)
    inspectorBackdrop.forceOpaque = true
    r.check("RightInspectorBackdrop: forceOpaque engages opaque fallback",
            inspectorBackdrop.material.isHidden && inspectorBackdrop.specular.isHidden && inspectorBackdrop.isOpaqueFallback)
    inspectorBackdrop.forceOpaque = false
    inspectorBackdrop.isResizing = true
    r.check("RightInspectorBackdrop: isResizing engages opaque fallback",
            inspectorBackdrop.material.isHidden && inspectorBackdrop.specular.isHidden && inspectorBackdrop.isOpaqueFallback)
    inspectorBackdrop.isResizing = false
    r.check("RightInspectorBackdrop: hitTest returns nil to allow drag pass-through",
            inspectorBackdrop.hitTest(NSPoint(x: 10, y: 10)) == nil)

    let inspectorHandle = RightInspectorResizeHandle(frame: NSRect(x: 0, y: 0, width: 5, height: 600))
    var dragNotified = false
    inspectorHandle.onDragStateChange = { active in dragNotified = active }
    let dummyEv = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    inspectorHandle.mouseDown(with: dummyEv)
    r.check("RightInspectorResizeHandle: mouseDown sets isDragging",
            inspectorHandle.isDragging && dragNotified)
    // viewWillMove(toWindow: nil) resets isDragging
    inspectorHandle.viewWillMove(toWindow: nil)
    r.check("RightInspectorResizeHandle: viewWillMove(toWindow: nil) resets isDragging",
            !inspectorHandle.isDragging && !dragNotified)

    // 11a-1. FooterBackdrop & WindowFooterView presentation
    let footerBackdrop = FooterBackdrop(frame: NSRect(x: 0, y: 0, width: 800, height: 32))
    r.check("FooterBackdrop: translucent material and top border shown when idle",
            !footerBackdrop.material.isHidden && !footerBackdrop.specular.isHidden)
    footerBackdrop.forceOpaque = true
    r.check("FooterBackdrop: forceOpaque engages opaque fallback",
            footerBackdrop.material.isHidden && footerBackdrop.specular.isHidden && footerBackdrop.isOpaqueFallback)
    footerBackdrop.forceOpaque = false
    footerBackdrop.isResizing = true
    r.check("FooterBackdrop: isResizing engages opaque fallback",
            footerBackdrop.material.isHidden && footerBackdrop.specular.isHidden && footerBackdrop.isOpaqueFallback)
    footerBackdrop.isResizing = false
    r.check("FooterBackdrop: hitTest returns nil to allow interaction pass-through",
            footerBackdrop.hitTest(NSPoint(x: 10, y: 10)) == nil)

    let emptyPres = WindowFooterView.presentation(telemetry: nil, git: nil)
    r.check("WindowFooterView: empty presentation has placeholders and honest Metal renderer",
            emptyPres.modelText == "—" && emptyPres.turnsText == "—" && emptyPres.rendererText == "Metal" &&
            emptyPres.contextPercentText == "—" && emptyPres.contextRatio == nil &&
            emptyPres.gitBranchText == "—" && emptyPres.gitChangesText == "—")

    let dummyTelem = PaneTelemetryDisplay(
        model: "gpt-5-4",
        turnCount: 3,
        contextUsedTokens: 65_000,
        contextLimitTokens: 100_000,
        contextPercent: 0.65,
        toolCalls: [
            ToolCallEntry(id: "t1", name: "Bash", category: .bash, argument: "swift test", status: .succeeded, startedAtNanos: 0)
        ],
        isActiveAgent: true
    )
    let dummyGit = GitDiffSnapshot(
        cwd: "/tmp/repo",
        isGitRepo: true,
        branch: "feat/preview",
        totalAdded: 42,
        totalDeleted: 10
    )
    let activePres = WindowFooterView.presentation(telemetry: dummyTelem, git: dummyGit)
    r.check("WindowFooterView: active presentation shows model, latest tool, turns, 0.0...1.0 context percent, git branch and diff stats",
            activePres.modelText == "gpt-5-4" && activePres.latestToolText == "✓ Bash" &&
            activePres.turnsText == "Turn 3" && activePres.rendererText == "Metal" &&
            activePres.contextPercentText == "65%" && activePres.contextRatio == 0.65 &&
            activePres.gitBranchText == "feat/preview" && activePres.gitChangesText == "+42 -10")

    c.closeWorkspace(wsRun)

    return finish(r, c)
}
