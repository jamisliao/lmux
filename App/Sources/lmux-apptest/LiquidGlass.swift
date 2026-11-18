// @feature: liquid-glass-app.feature
// @scenario: Sidebar 背景在一般狀態顯示毛玻璃與頂部亮邊，並在系統開啟減少透明度時改用不透明實底
// @scenario: 拖曳調整面板或分割窗格期間暫停毛玻璃並在放開後恢復
// @scenario: 拖曳途中視窗失去焦點時自動解除拖曳降級並恢復毛玻璃
// @scenario: 選取中的 workspace 列、反白通知卡片與通知 bar 調整手把呈現立體玻璃細節

import AppKit
import LmuxTokens
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
        c.model.recordNotification(NotificationEntry(paneID: p0.id, workspaceID: ws.id, title: ws.title,
                                                     message: "Glass check ready", kind: "done", read: false))
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
    return finish(r, c)
}
