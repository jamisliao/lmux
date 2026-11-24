// @feature: liquid-glass-app.feature
// @scenario: 標題列置中顯示目前 workspace 資訊膠囊與快速操作按鈕
// @scenario: 左側 workspace 卡片顯示彩色識別條與狀態藥丸並保留多選與排序
// @scenario: 中央終端窗格顯示圓角卡片、玻璃外框與 Pane Tab Strip
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
    } else {
        r.check("SidebarBackdrop: Reduce Transparency engages opaque fallback",
                bd.isOpaqueFallback && bd.material.isHidden && bd.specular.isHidden)
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

    // Exact threshold 43 (>42) stays expanded and maxExtra clamps; <=42 auto-collapses
    let baseBarH = NotificationBarPlugin.minHeight(pluginRows: 0)
    barLayout.extra = 20
    barLayout.endDrag(on: c)
    barLayout.updateDrag(translationHeight: (baseBarH + 20) - 43, maxExtra: 200, on: c)
    r.check("BarLayout totalHeight == 43 stays expanded", !barLayout.isCollapsed)
    barLayout.endDrag(on: c)
    barLayout.updateDrag(translationHeight: -500, maxExtra: 200, on: c)
    r.check("BarLayout clamps extra to maxExtra (200)", barLayout.extra == 200 && !barLayout.isCollapsed)
    barLayout.endDrag(on: c)

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

    // Key equivalents via window.performKeyEquivalent (distinct timestamp per event so SurfaceView.lastPerformKeyEvent doesn't intercept a repeat of the same NSEvent)
    var keySeqTime = ProcessInfo.processInfo.systemUptime
    func makeKeyEvent(key: String, chars: String, mods: NSEvent.ModifierFlags, keyCode: UInt16 = 11) -> NSEvent {
        keySeqTime += 0.01
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                                timestamp: keySeqTime, windowNumber: w.windowNumber,
                                context: nil, characters: chars, charactersIgnoringModifiers: key,
                                isARepeat: false, keyCode: keyCode)!
    }

    // ⌥⌘B toggles inspector
    let prevInsp = c.model.inspectorVisible
    let optCmdBHandled = w.performKeyEquivalent(with: makeKeyEvent(key: "b", chars: "∫", mods: [.command, .option], keyCode: 11))
    let inspAfterToggle = c.model.inspectorVisible
    _ = w.performKeyEquivalent(with: makeKeyEvent(key: "b", chars: "∫", mods: [.command, .option], keyCode: 11)) // restore
    r.check("⌥⌘B via performKeyEquivalent toggles inspectorVisible and restores",
            optCmdBHandled && inspAfterToggle == !prevInsp && c.model.inspectorVisible == prevInsp)

    // ⌃⌘S toggles sidebar
    let prevSide = c.model.sidebarVisible
    let ctrlCmdSHandled = w.performKeyEquivalent(with: makeKeyEvent(key: "s", chars: "\u{13}", mods: [.command, .control], keyCode: 1))
    let sideAfterCtrlCmdS = c.model.sidebarVisible
    _ = w.performKeyEquivalent(with: makeKeyEvent(key: "s", chars: "\u{13}", mods: [.command, .control], keyCode: 1)) // restore
    r.check("⌃⌘S via performKeyEquivalent toggles sidebarVisible and restores",
            ctrlCmdSHandled && sideAfterCtrlCmdS == !prevSide && c.model.sidebarVisible == prevSide)

    // ⌘B toggles sidebar when not in NSText (even with Caps Lock active)
    let curSide = c.model.sidebarVisible
    let cmdBHandled = w.performKeyEquivalent(with: makeKeyEvent(key: "b", chars: "b", mods: .command, keyCode: 11))
    r.check("⌘B via performKeyEquivalent toggles sidebarVisible",
            cmdBHandled && c.model.sidebarVisible == !curSide)
    let cmdBCapsHandled = w.performKeyEquivalent(with: makeKeyEvent(key: "b", chars: "b", mods: [.command, .capsLock], keyCode: 11))
    r.check("⌘B works even when Caps Lock modifier is active",
            cmdBCapsHandled && c.model.sidebarVisible == curSide)

    // TitlebarCenterChip.dotColor distinguishes .failed and nil states
    r.check("TitlebarCenterChip.dotColor maps .failed to diffRemovedFg and nil to statusIdleText",
            TitlebarCenterChip.dotColor(for: .failed(nil)) == LmuxTokens.Colors.diffRemovedFg
            && TitlebarCenterChip.dotColor(for: nil) == LmuxTokens.Colors.statusIdleText)

    // ⌘B does not steal key when firstResponder is NSText
    let dummyTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
    w.contentView?.addSubview(dummyTextView)
    w.makeFirstResponder(dummyTextView)
    let sideBeforeInText = c.model.sidebarVisible
    _ = w.performKeyEquivalent(with: makeKeyEvent(key: "b", chars: "b", mods: .command, keyCode: 11))
    r.check("⌘B does not toggle sidebar when firstResponder is NSText",
            c.model.sidebarVisible == sideBeforeInText)
    dummyTextView.removeFromSuperview()
    c.focusCurrent()

    // 6. TitlebarBackdrop (mounted), TitlebarCenterChip layout and TitlebarRightCluster / TitlebarCluster actions
    let tb = c.root.titlebarBackdrop
    tb.forceOpaque = false
    tb.isResizing = false
    c.root.layoutSubtreeIfNeeded()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        r.check("TitlebarBackdrop: translucent material and specular edge shown when idle",
                !tb.isOpaqueFallback && !tb.material.isHidden && !tb.specular.isHidden && tb.specular.frame.height == 1)
    } else {
        r.check("TitlebarBackdrop: Reduce Transparency engages opaque fallback",
                tb.isOpaqueFallback && tb.material.isHidden && tb.specular.isHidden)
    }
    tb.forceOpaque = true
    r.check("TitlebarBackdrop: forceOpaque hides material and specular edge",
            tb.isOpaqueFallback && tb.material.isHidden && tb.specular.isHidden)
    tb.forceOpaque = false
    tb.isResizing = true
    r.check("TitlebarBackdrop: isResizing engages opaque fallback",
            tb.isOpaqueFallback && tb.material.isHidden && tb.specular.isHidden)
    tb.isResizing = false
    r.check("TitlebarBackdrop: hitTest returns nil to allow window drag",
            tb.hitTest(NSPoint(x: tb.bounds.midX, y: tb.bounds.midY)) == nil)

    c.root.layoutSubtreeIfNeeded()
    if let wsTitle = c.model.selected {
        wsTitle.customTitle = "lmux-app"
        c.root.updateHeader()
        c.root.layoutSubtreeIfNeeded()
        c.root.centerChipHost.displayIfNeeded()
        await Task.yield()
        r.check("RootView mounts titlebar cluster, centerChipHost, and rightClusterHost with non-zero centered frames",
                !c.root.cluster.frame.isEmpty
                && !c.root.centerChipHost.frame.isEmpty
                && !c.root.rightClusterHost.frame.isEmpty
                && c.root.chipState.workspace?.title == "lmux-app")

        // F4 regression: empty ContentHeaderView double-click routes to TitlebarDragView zoom instead of promptRename,
        // while double-clicking mounted TitlebarCenterChip triggers promptRename.
        var renamePromptCount = 0
        c.renamePromptTap = { _ in renamePromptCount += 1 }
        defer { c.renamePromptTap = nil }
        let zoomBeforeHeaderDbl = w.isZoomed
        let dblAction = TitlebarDragView.titlebarDoubleClickAction(.standard)
        let headerPt = c.root.header.convert(NSPoint(x: c.root.header.title.frame.midX, y: c.root.header.bounds.midY), to: nil)
        let dblEv = NSEvent.mouseEvent(with: .leftMouseDown, location: headerPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 77, clickCount: 2, pressure: 1)!
        c.root.header.mouseDown(with: dblEv)
        let countAfterHeaderDbl = renamePromptCount
        let chipWinPt = c.root.centerChipHost.convert(NSPoint(x: c.root.centerChipHost.bounds.midX, y: c.root.centerChipHost.bounds.midY), to: nil)
        for clickCnt in [1, 2] {
            for evType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let chipEv = NSEvent.mouseEvent(
                    with: evType,
                    location: chipWinPt,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber,
                    context: nil,
                    eventNumber: 78 + clickCnt,
                    clickCount: clickCnt,
                    pressure: evType == .leftMouseUp ? 0 : 1
                )!
                if let delivered = SyntheticEvents.roundTrip(chipEv, mask: [.leftMouseDown, .leftMouseUp], drop: MouseQueue.simulateDrop) {
                    w.sendEvent(delivered)
                } else {
                    w.sendEvent(chipEv)
                }
                await sleepMs(20)
            }
        }
        await sleepMs(80)
        if w.isZoomed != zoomBeforeHeaderDbl && (dblAction == "Maximize" || dblAction == "Fill") {
            w.performZoom(nil)
        } else if w.isMiniaturized {
            w.deminiaturize(nil)
        }
        r.check("ContentHeaderView invisible title double-click no longer traps clicks and mounted TitlebarCenterChip double-click triggers rename",
                countAfterHeaderDbl == 0 && renamePromptCount == 1,
                "headerCount=\(countAfterHeaderDbl) chipCount=\(renamePromptCount)")

        let savedTitleForChip = c.model.selected?.customTitle
        c.model.selected?.customTitle = "hi"
        c.root.updateHeader()
        c.root.layoutSubtreeIfNeeded()
        c.root.centerChipHost.displayIfNeeded()
        await Task.yield()
        let chipFrameInSuper = c.root.centerChipHost.frame
        let leftMarginInSuper = NSPoint(x: chipFrameInSuper.minX + 2, y: chipFrameInSuper.midY)
        let centerPillInSuper = NSPoint(x: chipFrameInSuper.midX, y: chipFrameInSuper.midY)
        let marginPassesThrough = c.root.centerChipHost.hitTest(leftMarginInSuper) == nil
        let centerHitsChip = c.root.centerChipHost.hitTest(centerPillInSuper) != nil
        c.model.selected?.customTitle = savedTitleForChip
        c.root.updateHeader()
        r.check("TitlebarCenterChip passes clicks through transparent outer margins while catching hits on the capsule",
                marginPassesThrough && centerHitsChip,
                "marginNil=\(marginPassesThrough) centerHit=\(centerHitsChip) pillW=\(c.root.chipState.renderedPillWidth) frameW=\(chipFrameInSuper.width)")
    }
    let wide = TitlebarCenterChip.computeChipLayout(availableWidth: 500, title: "lmux", branch: "main", path: "~/src/lmux")
    r.check("computeChipLayout: wide window shows title, branch, and path",
            wide.showBranch && wide.showPath && wide.chipWidth <= 500)

    let med = TitlebarCenterChip.computeChipLayout(availableWidth: 280, title: "lmux", branch: "feat/preview", path: "~/src/lmux")
    r.check("computeChipLayout: medium window shows branch and hides path",
            med.showBranch && !med.showPath && med.chipWidth <= 280)

    let narrow = TitlebarCenterChip.computeChipLayout(availableWidth: 150, title: "lmux-long-title", branch: "feat/preview", path: "~/src/lmux")
    r.check("computeChipLayout: narrow window hides branch and path to prevent overlap",
            !narrow.showBranch && !narrow.showPath && narrow.chipWidth <= 150)

    let edge219 = TitlebarCenterChip.computeChipLayout(availableWidth: 219, title: "lmux", branch: "main", path: "~/src/lmux")
    let edge220 = TitlebarCenterChip.computeChipLayout(availableWidth: 220, title: "lmux", branch: "main", path: "~/src/lmux")
    let edge359 = TitlebarCenterChip.computeChipLayout(availableWidth: 359, title: "lmux", branch: "main", path: "~/src/lmux")
    let edge360 = TitlebarCenterChip.computeChipLayout(availableWidth: 360, title: "lmux", branch: "main", path: "~/src/lmux")
    r.check("computeChipLayout: exact 220/360 thresholds toggle branch and path",
            !edge219.showBranch && !edge219.showPath
            && edge220.showBranch && !edge220.showPath
            && edge359.showBranch && !edge359.showPath
            && edge360.showBranch && edge360.showPath)

    // TitlebarRightCluster actions
    let prevPanes = c.model.selected?.panes.count ?? 1
    TitlebarRightCluster.actionSplitRight(controller: c)
    r.check("TitlebarRightCluster.actionSplitRight splits right",
            (c.model.selected?.panes.count ?? 0) == prevPanes + 1)

    let downStartCount = c.model.selected?.panes.count ?? 1
    let splitDownPreFocused = c.model.selected?.focusedPane
    TitlebarRightCluster.actionSplitDown(controller: c)
    let splitDownNewPane = c.model.selected?.focusedPane
    r.check("TitlebarRightCluster.actionSplitDown splits down and moves focus",
            (c.model.selected?.panes.count ?? 0) == downStartCount + 1
            && splitDownNewPane != nil && splitDownNewPane !== splitDownPreFocused)
    if let downPane = splitDownNewPane, downPane !== splitDownPreFocused {
        c.closePane(downPane)
    }

    let prevInsp2 = c.model.inspectorVisible
    TitlebarRightCluster.actionToggleInspector(controller: c)
    r.check("TitlebarRightCluster.actionToggleInspector toggles inspector",
            c.model.inspectorVisible == !prevInsp2)
    TitlebarRightCluster.actionToggleInspector(controller: c) // restore
    c.root.cluster.displayIfNeeded()
    await Task.yield()
    let sidebarBeforeToggle = c.model.sidebarVisible
    let activeBeforeToggle = TitlebarCluster.isSidebarToggleActive(model: c.model)
    await click(c.root.cluster, at: NSPoint(x: LmuxTokens.Layout.titlebarButtonSize / 2, y: c.root.cluster.bounds.midY))
    let sidebarAfterClick = c.model.sidebarVisible
    let activeAfterToggle = TitlebarCluster.isSidebarToggleActive(model: c.model)
    await click(c.root.cluster, at: NSPoint(x: LmuxTokens.Layout.titlebarButtonSize / 2, y: c.root.cluster.bounds.midY))
    r.check("TitlebarCluster mounted sidebar button click toggles sidebarVisible and updates active highlight",
            sidebarBeforeToggle
            && activeBeforeToggle == sidebarBeforeToggle
            && sidebarAfterClick == !sidebarBeforeToggle
            && activeAfterToggle == !sidebarBeforeToggle
            && c.model.sidebarVisible == sidebarBeforeToggle)

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

    let wsDone = c.newWorkspace()
    wsDone.customTitle = "ws-done"
    wsDone.panes[0].agent = .restoredDone
    let wsFail = c.newWorkspace()
    wsFail.customTitle = "ws-failed"
    wsFail.panes[0].agent = .restoredDone
    wsFail.panes[0].failed = true

    c.model.workspaceFilter = .active
    r.check("WorkspaceFilter .active matches running and excludes idle, done, and failed",
            c.model.filteredWorkspaces.contains(where: { $0.id == wsRun.id }) &&
            !c.model.filteredWorkspaces.contains(where: { $0.id == wsIdle.id }) &&
            !c.model.filteredWorkspaces.contains(where: { $0.id == wsDone.id }) &&
            !c.model.filteredWorkspaces.contains(where: { $0.id == wsFail.id }))

    c.model.workspaceFilter = .needsInput
    r.check("WorkspaceFilter .needsInput matches needsInput and excludes running, done, and failed",
            c.model.filteredWorkspaces.contains(where: { $0.id == wsNeed.id }) &&
            !c.model.filteredWorkspaces.contains(where: { $0.id == wsRun.id }) &&
            !c.model.filteredWorkspaces.contains(where: { $0.id == wsDone.id }) &&
            !c.model.filteredWorkspaces.contains(where: { $0.id == wsFail.id }))
    c.closeWorkspace(wsDone)
    c.closeWorkspace(wsFail)

    // (a2) 篩選中 ⇧-click 的範圍只含看得到的列；切換篩選時清除多選（verify F2）
    let prevSelected = c.model.selected
    let wsRun2 = c.newWorkspace()
    wsRun2.customTitle = "ws-running-2"
    wsRun2.focusedPane?.agent.handle(HookEvent(paneID: wsRun2.focusedPane!.id, name: HookEvent.Kind.userPromptSubmit.rawValue), focused: true)
    var preBash2 = HookEvent(paneID: wsRun2.focusedPane!.id, name: HookEvent.Kind.preToolUse.rawValue)
    preBash2.toolName = "Bash"; preBash2.toolArgument = "swift test"
    wsRun2.focusedPane?.agent.handle(preBash2, focused: true)
    c.model.workspaceFilter = .active
    let allIDs = c.model.workspaces.map(\.id)
    let visibleIDs = Set(c.model.filteredWorkspaces.map(\.id))
    let ends = [allIDs.firstIndex(of: wsRun.id) ?? 0, allIDs.firstIndex(of: wsRun2.id) ?? 0].sorted()
    let hiddenBetween = allIDs[ends[0]...ends[1]].filter { !visibleIDs.contains($0) }
    c.clickRow(wsRun, modifiers: [])
    c.clickRow(wsRun2, modifiers: .shift)
    r.check("篩選中 ⇧-click 範圍選取不含被篩選隱藏的 workspace",
            !hiddenBetween.isEmpty && c.model.selection == [wsRun.id, wsRun2.id],
            "hiddenBetween=\(hiddenBetween.count) selection=\(c.model.selection.count)")
    c.model.workspaceFilter = .needsInput
    r.check("切換篩選時清除多選，不留下看不見的已選列", c.model.selection.isEmpty,
            "selection=\(c.model.selection.count)")
    c.closeWorkspace(wsRun2)
    if let prevSelected { c.clickRow(prevSelected, modifiers: []) }

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

    // Mounted WorkspaceFilterHeader control & menu items / accessibility element
    c.root.layoutSubtreeIfNeeded()
    c.root.workspaceFilterHeaderHost.layoutSubtreeIfNeeded()
    c.root.workspaceFilterHeaderHost.displayIfNeeded()
    await Task.yield()
    func findSubview(in view: NSView, where pred: (NSView) -> Bool) -> NSView? {
        if pred(view) { return view }
        for sub in view.subviews {
            if let hit = findSubview(in: sub, where: pred) { return hit }
        }
        return nil
    }
    func findAXNode(in node: AnyObject, depth: Int = 0, matching: (AnyObject) -> Bool) -> AnyObject? {
        guard depth < 12 else { return nil }
        if matching(node) { return node }
        let children: [Any] = node.accessibilityChildren?() ?? []
        for child in children {
            if let hit = findAXNode(in: child as AnyObject, depth: depth + 1, matching: matching) { return hit }
        }
        return nil
    }
    func nonEmpty(_ s: String?) -> String? { s?.isEmpty == false ? s : nil }
    let filterHost = c.root.workspaceFilterHeaderHost
    let filterPopUp = findSubview(in: filterHost) { $0 is NSPopUpButton } as? NSPopUpButton
    let filterAllWidth = (findSubview(in: filterHost) { ($0 as? NSControl) != nil || "\(type(of: $0))".contains("PlatformView") })?.frame.width ?? 0
    var filterUIOK = false
    var filterUIDetail = "subdirs=\(filterHost.subviews.map { "\(type(of: $0))" }) axChildren=\((filterHost.accessibilityChildren() ?? []).count)"
    if let popUp = filterPopUp, let menu = popUp.menu {
        if menu.items.isEmpty {
            menu.delegate?.menuNeedsUpdate?(menu)
            if menu.items.isEmpty { menu.update() }
        }
        let titles = menu.items.map(\.title)
        c.model.workspaceFilter = .active
        filterHost.layoutSubtreeIfNeeded()
        filterHost.displayIfNeeded()
        await Task.yield()
        let activeWidth = popUp.frame.width
        c.model.workspaceFilter = .all
        filterHost.layoutSubtreeIfNeeded()
        filterHost.displayIfNeeded()
        await Task.yield()
        if let activeIdx = menu.items.firstIndex(where: { $0.title == WorkspaceFilter.active.title }) {
            menu.performActionForItem(at: activeIdx)
            let becameActive = c.model.workspaceFilter == .active
            if let allIdx = menu.items.firstIndex(where: { $0.title == WorkspaceFilter.all.title }) {
                menu.performActionForItem(at: allIdx)
            } else {
                c.model.workspaceFilter = .all
            }
            filterUIOK = becameActive && titles.contains(WorkspaceFilter.needsInput.title) && activeWidth > filterAllWidth
            filterUIDetail = "popUp titles=\(titles) becameActive=\(becameActive) widths=(\(filterAllWidth)->\(activeWidth))"
        } else {
            let ident = nonEmpty(popUp.accessibilityIdentifier()) ?? nonEmpty(popUp.superview?.accessibilityIdentifier()) ?? "-"
            filterUIOK = popUp.isEnabled && !popUp.frame.isEmpty && activeWidth > filterAllWidth + 8
            filterUIDetail = "popUp empty-lazy-menu id=\(ident) enabled=\(popUp.isEnabled) frame=\(popUp.frame) widths=(\(filterAllWidth)->\(activeWidth))"
        }
    } else if let filterView = findSubview(in: filterHost, where: { $0.accessibilityIdentifier() == "workspace-filter-menu" }) {
        c.model.workspaceFilter = .active
        filterHost.layoutSubtreeIfNeeded()
        filterHost.displayIfNeeded()
        await Task.yield()
        let activeWidth = filterView.frame.width
        c.model.workspaceFilter = .all
        filterUIOK = !filterView.frame.isEmpty && !filterHost.frame.isEmpty && activeWidth > filterAllWidth + 8
        filterUIDetail = "view frame=\(filterView.frame) widths=(\(filterAllWidth)->\(activeWidth))"
    } else if let axNode = findAXNode(in: filterHost, matching: { el in
        let ident = nonEmpty(el.accessibilityIdentifier?())
        let help = nonEmpty(el.accessibilityHelp?())
        let role = el.accessibilityRole?()
        return ident == "workspace-filter-menu" || help == "篩選工作區"
            || role == .menuButton || role == .popUpButton
    }) {
        let axFrame = (axNode as? NSAccessibilityElementProtocol)?.accessibilityFrame() ?? .zero
        let hostScreen = w.convertToScreen(filterHost.convert(filterHost.bounds, to: nil))
        let role = axNode.accessibilityRole?()?.rawValue ?? "?"
        let ident = nonEmpty(axNode.accessibilityIdentifier?()) ?? "?"
        c.model.workspaceFilter = .active
        filterHost.layoutSubtreeIfNeeded()
        filterHost.displayIfNeeded()
        await Task.yield()
        let activeNode = findAXNode(in: filterHost, matching: { el in
            let title = nonEmpty(el.accessibilityTitle?())
            let label = nonEmpty(el.accessibilityLabel?())
            let wid = nonEmpty(el.accessibilityIdentifier?())
            return title?.contains(WorkspaceFilter.active.title) == true
                || label?.contains(WorkspaceFilter.active.title) == true
                || wid == "workspace-filter-menu"
        })
        let activeWidth = (activeNode as? NSAccessibilityElementProtocol)?.accessibilityFrame().width ?? 0
        c.model.workspaceFilter = .all
        filterHost.displayIfNeeded()
        filterUIOK = axFrame.width > 0 && axFrame.height > 0 && hostScreen.intersects(axFrame) && activeWidth > axFrame.width + 8
        filterUIDetail = "role=\(role) id=\(ident) axFrame=\(axFrame) activeWidth=\(activeWidth)"
    } else {
        let axDump = (filterHost.accessibilityChildren() ?? []).prefix(6).map { child -> String in
            let obj = child as AnyObject
            let r = obj.accessibilityRole?()?.rawValue ?? "?"
            let i = nonEmpty(obj.accessibilityIdentifier?()) ?? "-"
            let t = nonEmpty(obj.accessibilityTitle?()) ?? nonEmpty(obj.accessibilityLabel?()) ?? "-"
            return "\(r)(id=\(i),t=\(t))"
        }
        filterUIDetail += " dump=\(axDump)"
    }
    r.check("Mounted WorkspaceFilterHeader realizes interactive filter menu control", filterUIOK, filterUIDetail)

    // (c) TabDisclosureButton hit rect x: 1..<15 vs AccentStripe x: >=16 safe inset
    r.check("TabDisclosureButton hit target x: 1..<15 does not overlap AccentStripe at x >= 16",
            WorkspaceRow.disclosureLeading + LmuxTokens.Layout.tabDisclosureSize <=
            LmuxTokens.Layout.rowInsetX + LmuxTokens.Layout.rowPaddingX)

    // (c2) Mounted sidebar row double-click rename (unmodified clickCount == 2 vs Cmd-double-click) & real mounted drag-reorder + unread NotificationBar
    c.root.layoutSubtreeIfNeeded()
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    c.root.sidebarHost.displayIfNeeded()
    _ = await waitFor(2) { c.root.sidebarHost.rootView.rowFrames.frames.count == c.model.workspaces.count }
    await sleepMs(100)
    var rowRenameCount = 0
    c.renamePromptTap = { _ in rowRenameCount += 1 }
    let dblPt = c.root.sidebarHost.convert(rowPoint(c, 0), to: nil)
    for clickNum in [1, 2] {
        for evType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let ev = NSEvent.mouseEvent(with: evType, location: dblPt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 20 + clickNum, clickCount: clickNum, pressure: evType == .leftMouseDown ? 1 : 0) {
                if let delivered = SyntheticEvents.roundTrip(ev, mask: [.leftMouseDown, .leftMouseUp], drop: MouseQueue.simulateDrop) {
                    w.sendEvent(delivered)
                } else {
                    w.sendEvent(ev)
                }
            }
            await sleepMs(20)
        }
    }
    await sleepMs(80)
    let plainDblRenamed = rowRenameCount == 1
    rowRenameCount = 0
    for clickNum in [1, 2] {
        for evType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let ev = NSEvent.mouseEvent(with: evType, location: dblPt, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 30 + clickNum, clickCount: clickNum, pressure: evType == .leftMouseDown ? 1 : 0) {
                if let delivered = SyntheticEvents.roundTrip(ev, mask: [.leftMouseDown, .leftMouseUp], drop: MouseQueue.simulateDrop) {
                    w.sendEvent(delivered)
                } else {
                    w.sendEvent(ev)
                }
            }
            await sleepMs(20)
        }
    }
    await sleepMs(80)
    c.renamePromptTap = nil
    r.check("WorkspaceRow inline double-click triggers rename while Cmd+double-click does not",
            plainDblRenamed && rowRenameCount == 0,
            "plain=\(plainDblRenamed) cmdCount=\(rowRenameCount)")

    let orderBeforeDrag = c.model.workspaces.map(\.id)
    if c.model.workspaces.count >= 2 {
        await click(c.root.sidebarHost, at: rowPoint(c, 0), dragTo: NSPoint(x: rowPoint(c, 1).x, y: rowPoint(c, 1).y + 400))
        _ = await waitFor(2) { c.model.workspaces.map(\.id) != orderBeforeDrag }
    }
    let orderAfterDrag = c.model.workspaces.map(\.id)
    r.check("Mounted WorkspaceFilterHeader sits above sidebarHost and dragging workspace row reorders workspaces",
            c.root.workspaceFilterHeaderHost.frame.maxY <= c.root.sidebarHost.frame.minY + 0.5
            && c.model.workspaces.count >= 2
            && orderAfterDrag.last == orderBeforeDrag.first,
            "headerMaxY=\(c.root.workspaceFilterHeaderHost.frame.maxY) sidebarMinY=\(c.root.sidebarHost.frame.minY) reordered=\(orderAfterDrag != orderBeforeDrag)")
    if c.model.workspaces.count >= 2, let bgPane = c.model.workspaces.first(where: { $0 !== c.model.selected })?.panes.first {
        c.notify(text: "Build finished", title: "CI", paneID: bgPane.id)
    }
    r.check("NotificationBar tracks unread notification count for background workspace",
            c.model.unreadNotifications >= 1 && !c.model.notifications.isEmpty,
            "unread=\(c.model.unreadNotifications) total=\(c.model.notifications.count)")

    // (d) Status pill text & token mapping
    r.check("WorkspaceStatusPill text reflects states",
            WorkspaceStatusPill.statusText(for: .running(nil)) == "⚡ 執行中" &&
            WorkspaceStatusPill.statusText(for: .needsInput(nil)) == "🔔 需要確認" &&
            WorkspaceStatusPill.statusText(for: .done(nil)) == "✓ 完成")

    // 8. History search capsule & result row styling + mounted frame above NotificationBar
    r.check("HistorySection search field uses glassSurfaceRecessed, glassBorder, and focusRing",
            HistorySection.searchFieldFillColor(focused: true, hover: false) == LmuxTokens.Colors.glassSurfaceRecessed &&
            HistorySection.searchFieldFillColor(focused: false, hover: true) == LmuxTokens.Colors.glassCardHover &&
            HistorySection.searchFieldBorderColor(focused: true) == LmuxTokens.Colors.focusRing &&
            HistorySection.searchFieldBorderColor(focused: false) == LmuxTokens.Colors.glassBorder)
    r.check("HistoryRow shows glassBorder only when selected",
            HistoryRow.showsGlassBorder(selected: true) && !HistoryRow.showsGlassBorder(selected: false))

    let histProjDir = c.history.projectsRoot.appendingPathComponent("proj-w3", isDirectory: true)
    try? FileManager.default.createDirectory(at: histProjDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: histProjDir) }
    let histFile = histProjDir.appendingPathComponent("sess-w3-\(UUID().uuidString).jsonl")
    let histJSONL = #"{"type":"user","uuid":"u1","sessionId":"sess-w3","timestamp":"2026-11-23T00:00:00Z","cwd":"/tmp","message":{"role":"user","content":"hello history"}}"# + "\n"
        + #"{"type":"assistant","uuid":"u2","parentUuid":"u1","sessionId":"sess-w3","timestamp":"2026-11-23T00:00:01Z","cwd":"/tmp","message":{"id":"m1","role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"ok"}]}}"# + "\n"
    try? histJSONL.write(to: histFile, atomically: true, encoding: .utf8)
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        c.history.refreshNow { cont.resume() }
    }
    c.root.layoutSubtreeIfNeeded()
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    c.root.sidebarHost.displayIfNeeded()
    await Task.yield()
    var historyFieldAboveBar = false
    var historyLayoutDetail = "missing field or accessory"
    if let barView = c.root.sidebarAccessory?.view {
        let barRect = barView.frame
        if let fieldView = findSubview(in: c.root.sidebarHost, where: {
            $0.accessibilityIdentifier() == "history-search-field" || (($0 as? NSTextField)?.isEditable == true)
        }) {
            let fieldRect = c.root.convert(fieldView.bounds, from: fieldView)
            historyFieldAboveBar = !fieldRect.isEmpty && fieldRect.maxY <= barRect.minY + 0.5 && barRect.minY >= c.root.sidebarHost.frame.maxY - 0.5
            historyLayoutDetail = "fieldMaxY=\(fieldRect.maxY) barMinY=\(barRect.minY) sidebarHostMaxY=\(c.root.sidebarHost.frame.maxY)"
        } else if let axField = findAXNode(in: c.root.sidebarHost, matching: {
            nonEmpty($0.accessibilityIdentifier?()) == "history-search-field"
        }) {
            let fieldScreen = (axField as? NSAccessibilityElementProtocol)?.accessibilityFrame() ?? .zero
            let barScreen = w.convertToScreen(barView.convert(barView.bounds, to: nil))
            historyFieldAboveBar = !fieldScreen.isEmpty && fieldScreen.minY >= barScreen.maxY - 0.5
            historyLayoutDetail = "axFieldMinY=\(fieldScreen.minY) barMaxY=\(barScreen.maxY)"
        }
    }
    r.check("Mounted HistorySection search field renders inside sidebarHost strictly above NotificationBar",
            c.history.totalCount >= 1 && historyFieldAboveBar,
            "total=\(c.history.totalCount) \(historyLayoutDetail)")

    // 9. PaneView 10pt rounded cards with subtle glassBorder (no outer blue ring) vs RingView amber ring (live split & focus switch)
    let splitBase = wsIdle.panes[0]
    if let splitSecond = c.split(splitBase, .right) {
        _ = await sinks.waitReady(splitSecond.id)
        c.focus(splitSecond)
        c.root.layoutSubtreeIfNeeded()
        r.check("PaneView split leaves both have TabStripView, 10pt cornerRadius, and subtle 0.5pt glassBorder",
                splitBase.view.tabStrip != nil && splitSecond.view.tabStrip != nil
                && splitSecond.view.layer?.cornerRadius == LmuxTokens.Layout.paneCornerRadius
                && splitSecond.view.layer?.borderWidth == 0.5
                && splitBase.view.layer?.borderWidth == 0.5
                && splitSecond.isFocused && !splitBase.isFocused)
        c.closePane(splitSecond)
    }
    let testPane = wsIdle.panes[0]
    let paneView = testPane.view
    r.check("PaneView cornerRadius is 10pt (paneCornerRadius)",
            paneView.layer?.cornerRadius == LmuxTokens.Layout.paneCornerRadius)
    paneView.isFocused = true
    r.check("PaneView focused uses subtle glassBorder (0.5pt, no outer blue ring)",
            PaneView.borderColor(isFocused: true) == LmuxTokens.Colors.glassBorder &&
            PaneView.borderWidth(isFocused: true) == 0.5)
    paneView.isFocused = false
    r.check("PaneView unfocused has glassBorder (0.5pt)",
            PaneView.borderColor(isFocused: false) == LmuxTokens.Colors.glassBorder &&
            PaneView.borderWidth(isFocused: false) == 0.5)
    r.check("RingView uses amber needsInputRing color (distinct from blue activePaneRing)",
            RingView.strokeColor == LmuxTokens.Colors.needsInputRing &&
            RingView.strokeColor != LmuxTokens.Colors.activePaneRing)

    // 10a-1. Mounted RightInspectorBackdrop & RightInspectorResizeHandle
    let inspectorBackdrop = c.root.rightInspectorBackdrop
    inspectorBackdrop.forceOpaque = false
    inspectorBackdrop.isResizing = false
    c.root.layoutSubtreeIfNeeded()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        r.check("RightInspectorBackdrop: translucent material and specular edge shown when idle",
                !inspectorBackdrop.material.isHidden && !inspectorBackdrop.specular.isHidden)
    } else {
        r.check("RightInspectorBackdrop: Reduce Transparency engages opaque fallback",
                inspectorBackdrop.material.isHidden && inspectorBackdrop.specular.isHidden && inspectorBackdrop.isOpaqueFallback)
    }
    inspectorBackdrop.forceOpaque = true
    r.check("RightInspectorBackdrop: forceOpaque engages opaque fallback",
            inspectorBackdrop.material.isHidden && inspectorBackdrop.specular.isHidden && inspectorBackdrop.isOpaqueFallback)
    inspectorBackdrop.forceOpaque = false
    inspectorBackdrop.isResizing = true
    r.check("RightInspectorBackdrop: isResizing engages opaque fallback",
            inspectorBackdrop.material.isHidden && inspectorBackdrop.specular.isHidden && inspectorBackdrop.isOpaqueFallback)
    inspectorBackdrop.isResizing = false
    r.check("RightInspectorBackdrop: hitTest returns nil to allow drag pass-through",
            inspectorBackdrop.hitTest(NSPoint(x: inspectorBackdrop.bounds.midX, y: inspectorBackdrop.bounds.midY)) == nil)

    let inspectorHandle = c.root.rightInspectorHandle
    let dummyEv = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    inspectorHandle.mouseDown(with: dummyEv)
    r.check("RightInspectorResizeHandle: mouseDown sets isDragging and backdrop isResizing",
            inspectorHandle.isDragging && inspectorBackdrop.isResizing)
    // viewWillMove(toWindow: nil) resets isDragging and backdrop blur
    inspectorHandle.viewWillMove(toWindow: nil)
    r.check("RightInspectorResizeHandle: viewWillMove(toWindow: nil) resets isDragging and backdrop blur",
            !inspectorHandle.isDragging && !inspectorBackdrop.isResizing)

    // 11a-1. Mounted FooterBackdrop & WindowFooterView presentation
    let footerBackdrop = c.root.footerBackdrop
    footerBackdrop.forceOpaque = false
    footerBackdrop.isResizing = false
    c.root.layoutSubtreeIfNeeded()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        r.check("FooterBackdrop: translucent material and top border shown when idle",
                !footerBackdrop.material.isHidden && !footerBackdrop.specular.isHidden)
    } else {
        r.check("FooterBackdrop: Reduce Transparency engages opaque fallback",
                footerBackdrop.material.isHidden && footerBackdrop.specular.isHidden && footerBackdrop.isOpaqueFallback)
    }
    footerBackdrop.forceOpaque = true
    r.check("FooterBackdrop: forceOpaque engages opaque fallback",
            footerBackdrop.material.isHidden && footerBackdrop.specular.isHidden && footerBackdrop.isOpaqueFallback)
    footerBackdrop.forceOpaque = false
    footerBackdrop.isResizing = true
    r.check("FooterBackdrop: isResizing engages opaque fallback",
            footerBackdrop.material.isHidden && footerBackdrop.specular.isHidden && footerBackdrop.isOpaqueFallback)
    footerBackdrop.isResizing = false
    r.check("FooterBackdrop: hitTest returns nil to allow interaction pass-through",
            footerBackdrop.hitTest(NSPoint(x: footerBackdrop.bounds.midX, y: footerBackdrop.bounds.midY)) == nil)

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
            activePres.latestToolArg == "swift test" &&
            activePres.turnsText == "Turn 3" && activePres.rendererText == "Metal" &&
            activePres.contextPercentText == "65%" && activePres.contextTokensText == "65.0k / 100.0k" && activePres.contextRatio == 0.65 &&
            activePres.gitBranchText == "feat/preview" && activePres.gitChangesText == "+42 -10" &&
            activePres.gitAddedText == "+42" && activePres.gitDeletedText == "-10")

    c.closeWorkspace(wsRun)

    return finish(r, c)
}
