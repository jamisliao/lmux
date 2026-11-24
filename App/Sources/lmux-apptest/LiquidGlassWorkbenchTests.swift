// @feature: liquid-glass-app.feature
// @scenario: 玻璃背景顯示毛玻璃與高光邊緣，開啟減少透明度時切換為不透明實底
// @scenario: 系統開啟減少動態效果時縮短過渡並停止呼吸動畫
// @scenario: 透過快捷鍵與標題列／狀態列控制右側 Inspector 展開、收合與分頁切換
// @scenario: 右側 Inspector 即時預覽支援檔案切換、重整與雙軌開啟
// @scenario: 切換不同 workspace 時右側 Inspector 與底部狀態列同步切換上下文
// @scenario: 拖曳調整左右側邊欄、分割線、通知 bar 或視窗縮放期間啟動拖曳降級
// @scenario: 拖曳途中視窗或應用程式失去焦點時自動清除拖曳降級

import AppKit
import Foundation
import GhosttyKit
import LmuxHooks
import LmuxTokens
import LmuxTranscript
@testable import LmuxNotificationBar
@testable import LmuxUI

private typealias T = LmuxTokens

@MainActor
func runLiquidGlassWorkbench() async -> Int32 {
    let r = Report()
    let c = makeController()
    let w = c.window!
    r.section = "liquid-glass-workbench"

    let sb = c.root.sidebarBackdrop
    let tb = c.root.titlebarBackdrop
    let rb = c.root.rightInspectorBackdrop
    let fb = c.root.footerBackdrop

    // 1. 全域毛玻璃 & Reduce Transparency（4 個面板 × Light/Dark）
    let app0 = NSApp.appearance
    defer { NSApp.appearance = app0 }
    for (named, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        NSApp.appearance = NSAppearance(named: named)
        c.root.layoutSubtreeIfNeeded()

        sb.forceOpaque = false; tb.forceOpaque = false; rb.forceOpaque = false; fb.forceOpaque = false
        c.root.setAllBackdropsResizing(false)

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let allIdle = !sb.isOpaqueFallback && !tb.isOpaqueFallback && !rb.isOpaqueFallback && !fb.isOpaqueFallback
            let allVisible = !sb.material.isHidden && !tb.material.isHidden && !rb.material.isHidden && !fb.material.isHidden
            r.check("[\(label)] 4 個 Backdrop 預設皆啟用系統毛玻璃與高光邊緣", allIdle && allVisible)
        } else {
            r.check("[\(label)] 系統開啟減少透明度時 4 個 Backdrop 皆維持不透明實底",
                    sb.isOpaqueFallback && tb.isOpaqueFallback && rb.isOpaqueFallback && fb.isOpaqueFallback)
        }

        sb.forceOpaque = true; tb.forceOpaque = true; rb.forceOpaque = true; fb.forceOpaque = true
        let allOpaque = sb.isOpaqueFallback && tb.isOpaqueFallback && rb.isOpaqueFallback && fb.isOpaqueFallback
        let allMaterialsHidden = sb.material.isHidden && tb.material.isHidden && rb.material.isHidden && fb.material.isHidden
        r.check("[\(label)] forceOpaque / 減少透明度時 4 個 Backdrop 全數切換為不透明實底", allOpaque && allMaterialsHidden)

        sb.forceOpaque = false; tb.forceOpaque = false; rb.forceOpaque = false; fb.forceOpaque = false
    }

    // F13: Controller.setAppearance(.dark/.light/.system) 與 setSidebarMatchesTerminal(true/false) 應同步全部 Host 與 Accessory 外觀，titlebar cluster 保持系統外觀 (nil)
    let savedSettingAppearance = c.settings.appearance
    let savedMatchSetting = c.settings.sidebarMatchesTerminal
    let probeAcc = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
    c.installSidebarAccessory(probeAcc, height: 30)
    defer { c.installSidebarAccessory(nil, height: 0) }
    c.setAppearance(.dark)
    c.setSidebarMatchesTerminal(true)
    let expectedMatchDark = c.root.sidebarHost.appearance?.name
    r.check("Controller.setAppearance(.dark) 與 setSidebarMatchesTerminal(true) 同步 Inspector/Footer/Filter/Accessory 外觀且保持 Titlebar cluster 為 nil",
            c.root.rightInspectorHost.appearance?.name == .darkAqua
            && c.root.footerHost.appearance?.name == .darkAqua
            && c.root.sidebarBackdrop.matchColor != nil
            && expectedMatchDark != nil
            && c.root.workspaceFilterHeaderHost.appearance?.name == expectedMatchDark
            && c.root.sidebarAccessory?.view.appearance?.name == expectedMatchDark
            && c.root.cluster.appearance == nil
            && c.root.centerChipHost.appearance == nil
            && c.root.rightClusterHost.appearance == nil,
            "match=\(String(describing: expectedMatchDark)) filter=\(String(describing: c.root.workspaceFilterHeaderHost.appearance?.name)) acc=\(String(describing: c.root.sidebarAccessory?.view.appearance?.name))")
    c.setAppearance(.light)
    r.check("Controller.setAppearance(.light) 切換為淺色並同步 Inspector/Footer 與側欄 match 外觀",
            c.root.rightInspectorHost.appearance?.name == .aqua
            && c.root.footerHost.appearance?.name == .aqua
            && c.root.workspaceFilterHeaderHost.appearance?.name == c.root.sidebarHost.appearance?.name
            && c.root.sidebarAccessory?.view.appearance?.name == c.root.sidebarHost.appearance?.name)
    c.setSidebarMatchesTerminal(false)
    c.setAppearance(.system)
    r.check("Controller.setSidebarMatchesTerminal(false) 與 setAppearance(.system) 重設全部 Host 與 Accessory 外觀為 nil",
            c.root.sidebarBackdrop.matchColor == nil
            && c.root.sidebarHost.appearance == nil
            && c.root.workspaceFilterHeaderHost.appearance == nil
            && c.root.sidebarAccessory?.view.appearance == nil
            && NSApp.appearance == nil
            && c.root.rightInspectorHost.appearance == nil
            && c.root.footerHost.appearance == nil)
    c.installSidebarAccessory(nil, height: 0)
    c.setSidebarMatchesTerminal(savedMatchSetting)
    c.setAppearance(savedSettingAppearance)

    // 2. Reduce Motion 停用呼吸與動畫（驗證實際掛載 Spinner/Pulse Core Animation 圖層與 model 狀態）
    let rmHome = c.model.selected ?? c.model.workspaces[0]
    let rmRun = c.newWorkspace(cwd: "/tmp", select: false)
    rmRun.customTitle = "rm-running"
    let rmDone = c.newWorkspace(cwd: "/tmp", select: false)
    rmDone.customTitle = "rm-done"
    defer {
        c.closeWorkspace(rmRun)
        c.closeWorkspace(rmDone)
        c.attentionClock = nil
        c.reduceMotionOverride = nil
        c.updatePulseMotion()
    }
    c.select(rmHome)
    let rmBaseTime = Date()
    c.attentionClock = { rmBaseTime }
    hookEvent(c, rmRun.panes[0], "SessionStart", session: "rm-run")
    hookEvent(c, rmRun.panes[0], "UserPromptSubmit", session: "rm-run", ["prompt": "x"])
    hookEvent(c, rmDone.panes[0], "SessionStart", session: "rm-done")
    hookEvent(c, rmDone.panes[0], "UserPromptSubmit", session: "rm-done", ["prompt": "x"])
    hookEvent(c, rmDone.panes[0], "Stop", session: "rm-done", ["last_assistant_message": "done"])
    _ = await waitFor(2) {
        if case .running = rmRun.display, rmDone.panes[0].attentionSince != nil { return true }
        return false
    }
    c.attentionClock = { rmBaseTime.addingTimeInterval(4 * 60) }
    c.updateAttention()

    c.reduceMotionOverride = false
    c.updatePulseMotion()
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    await sleepMs(100)
    let activeSpinners = spinningViews(c)
    let activePulses = pulsingViews(c)
    let activeHalos = animatedLayers(c, "halo").count
    r.check("預設開啟呼吸動態（Spinner/Pulse CAAnimation 運行中）",
            c.model.pulseMotion && !c.model.reduceMotion && activeSpinners >= 1 && activePulses >= 1 && activeHalos >= 1,
            "spinners=\(activeSpinners) pulses=\(activePulses) halos=\(activeHalos)")

    c.reduceMotionOverride = true
    c.updatePulseMotion()
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    await sleepMs(100)
    let stoppedSpinners = spinningViews(c)
    let stoppedPulses = pulsingViews(c)
    let stoppedHalos = animatedLayers(c, "halo").count
    r.check("開啟減少動態效果後停止呼吸與轉圈動畫並設 reduceMotion 為 true",
            c.model.reduceMotion && !c.model.pulseMotion && stoppedSpinners == 0 && stoppedPulses == 0 && stoppedHalos == 0,
            "spinners=\(stoppedSpinners) pulses=\(stoppedPulses) halos=\(stoppedHalos)")
    c.closeWorkspace(rmRun)
    c.closeWorkspace(rmDone)
    c.attentionClock = nil
    c.reduceMotionOverride = nil
    c.updatePulseMotion()

    // 3. 5 種調整目標拖曳大小 + 邊界鉗製 + 失焦復原 + 重啟拖曳 (透過真實 mouseDown/mouseDragged/mouseUp 驅動)
    c.root.layoutSubtreeIfNeeded()
    r.check("掛載的 4 個 Backdrop hitTest 皆回傳 nil 以透傳點擊/拖曳",
            sb.hitTest(NSPoint(x: 10, y: 10)) == nil
            && tb.hitTest(NSPoint(x: 10, y: 10)) == nil
            && rb.hitTest(NSPoint(x: 10, y: 10)) == nil
            && fb.hitTest(NSPoint(x: 10, y: 10)) == nil)

    // (a) 左側欄寬度手把（真實 mouseDown/mouseDragged/mouseUp 與 180...400 邊界鉗製）
    c.root.resizeHandle.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: c.root.resizeHandle.convert(NSPoint(x: 2, y: 20), to: nil), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 10, clickCount: 1, pressure: 1)!)
    r.check("左側欄手把 mouseDown 進入拖曳狀態並讓 4 個 Backdrop 同時 isResizing",
            c.root.resizeHandle.isDragging && sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing)
    let leftLowPt = c.root.convert(NSPoint(x: 100, y: 200), to: nil)
    c.root.resizeHandle.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: leftLowPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 11, clickCount: 1, pressure: 1)!)
    let leftClampedMin = c.model.sidebarWidth == T.Layout.sidebarWidthMin
    let leftHighPt = c.root.convert(NSPoint(x: 600, y: 200), to: nil)
    c.root.resizeHandle.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: leftHighPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 12, clickCount: 1, pressure: 1)!)
    let leftClampedMax = c.model.sidebarWidth == T.Layout.sidebarWidthMax
    c.root.resizeHandle.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: leftHighPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 13, clickCount: 1, pressure: 0)!)
    r.check("左側欄手把 mouseDragged 鉗製 180...400 並於 mouseUp 恢復毛玻璃",
            leftClampedMin && leftClampedMax && !c.root.resizeHandle.isDragging
            && !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)
    c.model.sidebarWidth = T.Layout.sidebarWidthDefault

    // (b) 右側 Inspector 寬度手把（真實 mouseDragged 與 240...min(max, 50% W) 邊界鉗製）
    let W = c.root.bounds.width
    c.root.rightInspectorHandle.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: c.root.rightInspectorHandle.convert(NSPoint(x: 2, y: 20), to: nil), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 14, clickCount: 1, pressure: 1)!)
    let inspLowPt = c.root.convert(NSPoint(x: W - 100, y: 200), to: nil)
    c.root.rightInspectorHandle.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: inspLowPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 15, clickCount: 1, pressure: 1)!)
    let inspClampedMin = c.model.inspectorWidth == T.Layout.rightInspectorWidthMin
    let inspHighPt = c.root.convert(NSPoint(x: W - 1800, y: 200), to: nil)
    c.root.rightInspectorHandle.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: inspHighPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 16, clickCount: 1, pressure: 1)!)
    let expectedDragMax = max(T.Layout.rightInspectorWidthMin, min(T.Layout.rightInspectorWidthMax, min(floor(W * 0.5), W - c.model.sidebarWidth - 120)))
    let inspClampedMax = c.model.inspectorWidth == expectedDragMax
    c.root.rightInspectorHandle.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: inspHighPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 17, clickCount: 1, pressure: 0)!)
    r.check("右側 Inspector 手把 mouseDragged 鉗製 240...50%視窗寬度 並於 mouseUp 恢復毛玻璃",
            inspClampedMin && inspClampedMax && !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)
    c.model.inspectorWidth = T.Layout.rightInspectorWidthDefault

    // (c) 通知 bar 高度調整（安裝 NotificationBarPlugin 並透過真實 BarLayout.updateDrag / endDrag 驅動）
    let barSuite = "dev.lmux.apptest.workbench.bar.\(UUID().uuidString)"
    let barDefaults = UserDefaults(suiteName: barSuite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: barSuite) }
    let dragBarLayout = NotificationBarPlugin.install(on: c, defaults: barDefaults)
    c.root.layoutSubtreeIfNeeded()
    let barSavedExtra = dragBarLayout.extra
    dragBarLayout.updateDrag(translationHeight: -40, maxExtra: 200, on: c)
    r.check("通知 bar 拖曳時 4 個 Backdrop 同時 isResizing",
            dragBarLayout.isDragging && dragBarLayout.extra == barSavedExtra + 40
            && sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing)
    dragBarLayout.endDrag(on: c)
    r.check("通知 bar 放開後 4 個 Backdrop 恢復",
            !dragBarLayout.isDragging && !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing
            && barDefaults.double(forKey: BarLayout.defaultsKey) == Double(barSavedExtra + 40))

    // (c2) 中央窗格分割線 SplitContainerView 8pt 間距、真實 mouseDragged 與 Controller.resizeSplit (水平 + 垂直)
    let splitBase = c.model.selected!.focusedPane!
    if let splitP2 = c.split(splitBase, .right), let splitNode = c.model.selected!.root.find(splitBase)?.parent,
       let splitContainer = c.splitView(for: splitNode) {
        _ = await sinks.waitReady(splitP2.id)
        c.root.layoutSubtreeIfNeeded()
        splitContainer.layoutSubtreeIfNeeded()
        let hGap = splitContainer.second.frame.minX - splitContainer.first.frame.maxX
        let divMid = splitContainer.divider.frame.midX
        r.check("水平分割採用 paneGap (8pt) 且 divider 置中對齊",
                abs(hGap - T.Layout.paneGap) < 1.0 && abs(divMid - (splitContainer.first.frame.maxX + T.Layout.paneGap / 2)) < 1.5,
                "gap=\(hGap) divMid=\(divMid)")

        let beforeDragRatio = splitNode.ratio
        splitContainer.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: splitContainer.convert(NSPoint(x: splitContainer.divider.frame.midX, y: splitContainer.bounds.midY), to: nil), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 18, clickCount: 1, pressure: 1)!)
        let dragMidPt = splitContainer.convert(NSPoint(x: splitContainer.bounds.width * 0.7, y: splitContainer.bounds.midY), to: nil)
        splitContainer.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: dragMidPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 19, clickCount: 1, pressure: 1)!)
        let afterDragRatio = splitNode.ratio
        let dragMinPt = splitContainer.convert(NSPoint(x: 5, y: splitContainer.bounds.midY), to: nil)
        splitContainer.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: dragMinPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 20, clickCount: 1, pressure: 1)!)
        let minSideActual = (max(1, splitContainer.bounds.width - T.Layout.paneGap) * splitNode.ratio)
        r.check("中央窗格分割線拖曳即時更新比例、鉗製 60pt 最小寬並讓 4 個 Backdrop isResizing",
                sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing
                && abs(afterDragRatio - beforeDragRatio) > 0.05
                && abs(minSideActual - 60) < 1.0)
        splitContainer.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: dragMinPt, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 21, clickCount: 1, pressure: 0)!)
        let ratioPreCmd = splitNode.ratio
        c.resizeSplit(splitBase, GHOSTTY_RESIZE_SPLIT_RIGHT, amount: 40)
        r.check("Controller.resizeSplit(.right) 調整分割比例且 mouseUp 已恢復毛玻璃",
                !sb.isResizing && splitNode.ratio > ratioPreCmd)
        c.closePane(splitP2)
    }
    if let splitDownP2 = c.split(splitBase, .down), let vNode = c.model.selected!.root.find(splitBase)?.parent,
       let vContainer = c.splitView(for: vNode) {
        _ = await sinks.waitReady(splitDownP2.id)
        c.root.layoutSubtreeIfNeeded()
        vContainer.layoutSubtreeIfNeeded()
        let vGap = vContainer.second.frame.minY - vContainer.first.frame.maxY
        let vRatio0 = vNode.ratio
        c.resizeSplit(splitBase, GHOSTTY_RESIZE_SPLIT_DOWN, amount: 30)
        r.check("垂直分割採用 paneGap (8pt) 且 Controller.resizeSplit(.down) 更新比例",
                abs(vGap - T.Layout.paneGap) < 1.0 && vNode.ratio > vRatio0,
                "vGap=\(vGap) before=\(vRatio0) after=\(vNode.ratio)")
        c.closePane(splitDownP2)
    }

    // (d) 視窗縮放 live resize
    NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: w)
    r.check("視窗開始縮放時 4 個 Backdrop 同時 isResizing",
            sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: w)
    r.check("視窗結束縮放後 4 個 Backdrop 恢復", !sb.isResizing)

    // (e) 拖曳中失焦與中斷安全復原（使用真實 mouseDown 觸發拖曳）
    c.root.rightInspectorHandle.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!)
    r.check("mouseDown 啟動右側手把拖曳與 Backdrop 降級",
            c.root.rightInspectorHandle.isDragging && rb.isResizing)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
    r.check("didResignKeyNotification 自動清除 4 個 Backdrop isResizing 與手把拖曳狀態",
            !c.root.rightInspectorHandle.isDragging && !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)

    c.root.rightInspectorHandle.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 1)!)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    r.check("didResignActiveNotification 自動清除 4 個 Backdrop isResizing 與手把拖曳狀態",
            !c.root.rightInspectorHandle.isDragging && !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)

    dragBarLayout.updateDrag(translationHeight: -20, maxExtra: 200, on: c)
    let barStartedDrag = dragBarLayout.isDragging && sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
    let barClearedOnResignKey = !dragBarLayout.isDragging && !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing
    dragBarLayout.updateDrag(translationHeight: -20, maxExtra: 200, on: c)
    let barRedraggedAfterKey = dragBarLayout.isDragging && sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    let barClearedOnResignActive = !dragBarLayout.isDragging && !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing
    dragBarLayout.updateDrag(translationHeight: -10, maxExtra: 200, on: c)
    let barRecoveredFinal = dragBarLayout.isDragging && sb.isResizing
    dragBarLayout.endDrag(on: c)
    r.check("通知 bar 拖曳中失焦（resignKey / resignActive）自動清除 isDragging 與 Backdrop 降級並可立刻重新拖曳",
            barStartedDrag && barClearedOnResignKey && barRedraggedAfterKey && barClearedOnResignActive && barRecoveredFinal && !dragBarLayout.isDragging && !sb.isResizing,
            "start=\(barStartedDrag) key=\(barClearedOnResignKey) redrag=\(barRedraggedAfterKey) active=\(barClearedOnResignActive) rec=\(barRecoveredFinal)")

    // 4. 即時 Socket Hook → Footer & Inspector 執行記錄串流 + 切換 Workspace 上下文同步
    let ws1 = c.model.selected!
    ws1.customTitle = "workbench-ws1"
    let p1 = ws1.focusedPane!
    p1.branch = "feat/workbench"

    let store = c.model.telemetryStore ?? AgentTelemetryStore()
    c.model.telemetryStore = store

    hookEvent(c, p1, "SessionStart", session: "wb-s1")
    hookEvent(c, p1, "UserPromptSubmit", session: "wb-s1", ["prompt": "run tests"])

    if let preTool = try? HookEvent(paneID: p1.id, payload: [
        "hook_event_name": "PreToolUse",
        "session_id": "wb-s1",
        "tool_name": "Bash",
        "tool_input": ["command": "swift test"],
        "tool_use_id": "call_wb_1"
    ]) {
        c.handleHook(preTool)
    }

    if let postTool = try? HookEvent(paneID: p1.id, payload: [
        "hook_event_name": "PostToolUse",
        "session_id": "wb-s1",
        "tool_name": "Bash",
        "tool_result": "tests passed",
        "tool_use_id": "call_wb_1"
    ]) {
        c.handleHook(postTool)
    }

    if let preTool2 = try? HookEvent(paneID: p1.id, payload: [
        "hook_event_name": "PreToolUse",
        "session_id": "wb-s1",
        "tool_name": "Edit",
        "tool_input": ["file_path": "Tokens.swift"],
        "tool_use_id": "call_wb_2"
    ]) {
        c.handleHook(preTool2)
    }

    if let failTool = try? HookEvent(paneID: p1.id, payload: [
        "hook_event_name": "PostToolUseFailure",
        "session_id": "wb-s1",
        "tool_name": "Edit",
        "error": "file missing",
        "tool_use_id": "call_wb_2"
    ]) {
        c.handleHook(failTool)
    }

    let d1 = store.display(for: p1)
    r.check("Hook 事件單次精確記錄入 ToolCallStream (無重複)",
            d1.turnCount == 1
            && d1.toolCalls.count == 2
            && d1.toolCalls[0].status == .succeeded
            && d1.toolCalls[1].status == .failed,
            "turns=\(d1.turnCount) calls=\(d1.toolCalls.map { "\($0.id):\($0.status)" })")

    let pres1 = WindowFooterView.presentation(telemetry: d1, git: c.model.gitDiffService.snapshot)
    r.check("WindowFooterView presentation 包含模型與最新 Tool",
            pres1.latestToolText == "✕ Edit")

    // 真實切換至 Workspace 2（非 Git 目錄，含可預覽檔且無預覽紀錄），驗證 gitDiffService、chipState 與 previewCoordinator 同步
    let fm = FileManager.default
    let nonGitWsDir = fm.temporaryDirectory.appendingPathComponent("wb-nongit-\(UUID().uuidString)")
    let gitWsPreview = fm.temporaryDirectory.appendingPathComponent("wb-preview-\(UUID().uuidString).md")
    defer {
        try? fm.removeItem(at: nonGitWsDir)
        try? fm.removeItem(at: gitWsPreview)
    }
    try? fm.createDirectory(at: nonGitWsDir, withIntermediateDirectories: true)
    try? "# Non-git\n".write(to: nonGitWsDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try? "# WS1 Preview\n".write(to: gitWsPreview, atomically: true, encoding: .utf8)

    c.select(ws1)
    c.openInInspectorPreview(gitWsPreview, workspace: ws1)
    r.check("Workspace 1 開啟預覽與標題列膠囊同步",
            c.root.chipState.workspace?.id == ws1.id && c.previewCoordinator.currentURL == gitWsPreview)

    let ws2 = c.newWorkspace(cwd: nonGitWsDir.path, select: true)
    ws2.customTitle = "workbench-empty"
    let p2 = ws2.focusedPane!
    p2.branch = nil
    c.model.gitDiffService.refresh(cwd: nonGitWsDir.path, immediate: true)
    _ = await waitFor(3) { !c.model.gitDiffService.isLoading && c.model.gitDiffService.snapshot.cwd == nonGitWsDir.path }

    let d2 = store.display(for: p2)
    let pres2 = WindowFooterView.presentation(telemetry: d2, git: c.model.gitDiffService.snapshot)
    r.check("切換 Workspace 2 後 gitDiffService、Footer 與 previewCoordinator 同步清空/切換",
            !c.model.gitDiffService.snapshot.isGitRepo
            && c.model.gitDiffService.snapshot.previewCandidates.first?.lastPathComponent == "README.md"
            && c.previewCoordinator.currentURL == nil
            && c.previewCoordinator.previewView == nil
            && pres2.gitBranchText == "—"
            && pres2.gitChangesText == "—"
            && pres2.contextPercentText == "—"
            && pres2.contextRatio == nil
            && pres2.latestToolText == nil)

    // 切回 Workspace 1，驗證狀態與預覽上下文復原；同時驗證背景 Workspace 2 Hook / 目錄事件不覆寫前景 gitDiffService
    c.select(ws1)
    let ws1SnapDir = fm.temporaryDirectory.appendingPathComponent("wb-ws1-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: ws1SnapDir) }
    try? fm.createDirectory(at: ws1SnapDir, withIntermediateDirectories: true)
    p1.cwd = ws1SnapDir.path
    c.model.gitDiffService.refresh(cwd: ws1SnapDir.path, immediate: true)
    _ = await waitFor(3) { !c.model.gitDiffService.isLoading && c.model.gitDiffService.snapshot.cwd == ws1SnapDir.path }

    // Trigger background workspace hook (.stop) and directory change while ws1 stays selected
    let bgOtherDir = fm.temporaryDirectory.appendingPathComponent("wb-bg-other-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: bgOtherDir) }
    try? fm.createDirectory(at: bgOtherDir, withIntermediateDirectories: true)
    c.paneDidChangeDirectory(p2, bgOtherDir.path)
    if let bgStop = try? HookEvent(paneID: p2.id, payload: [
        "hook_event_name": "Stop",
        "session_id": "wb-bg-session"
    ]) {
        c.handleHook(bgStop)
    }
    let bgSettled = await waitFor(2) {
        p2.cwd == bgOtherDir.path && p2.agent.state == .done && !c.model.gitDiffService.isLoading
    }

    r.check("切回 Workspace 1 後選中狀態、chipState、預覽 URL 與前景 gitDiffService 不受背景 workspace 干擾",
            bgSettled
            && p2.cwd == bgOtherDir.path
            && c.model.selected?.id == ws1.id
            && c.root.chipState.workspace?.id == ws1.id
            && c.previewCoordinator.currentURL == gitWsPreview
            && c.model.gitDiffService.snapshot.cwd == ws1SnapDir.path)

    // 同 workspace 內切換不同 cwd 的 split/tab 時，gitDiffService 同步刷新為新 focusedPane 的 cwd
    let ws1SecondDir = fm.temporaryDirectory.appendingPathComponent("wb-ws1-tab2-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: ws1SecondDir) }
    try? fm.createDirectory(at: ws1SecondDir, withIntermediateDirectories: true)
    if let p1b = c.newTab(p1) {
        _ = await sinks.waitReady(p1b.id)
        c.paneDidChangeDirectory(p1b, ws1SecondDir.path)
        let tabSwitched = await waitFor(3) {
            !c.model.gitDiffService.isLoading && c.model.gitDiffService.snapshot.cwd == ws1SecondDir.path
        }
        r.check("同 workspace 內新分頁目錄變更後 gitDiffService 更新為 p1b.cwd", tabSwitched,
                "actual=\(c.model.gitDiffService.snapshot.cwd ?? "nil") expected=\(ws1SecondDir.path)")
        c.selectTab(p1)
        let switchedBack = await waitFor(3) {
            !c.model.gitDiffService.isLoading && c.model.gitDiffService.snapshot.cwd == ws1SnapDir.path
        }
        r.check("selectTab 切回先前 tab 後 gitDiffService 刷新為 p1.cwd", switchedBack,
                "actual=\(c.model.gitDiffService.snapshot.cwd ?? "nil") expected=\(ws1SnapDir.path)")
        c.selectTab(p1b)
        let switchedForward = await waitFor(3) {
            !c.model.gitDiffService.isLoading && c.model.gitDiffService.snapshot.cwd == ws1SecondDir.path
        }
        r.check("selectTab 再次切換至不同 cwd 的 tab 時 gitDiffService 刷新為 p1b.cwd", switchedForward,
                "actual=\(c.model.gitDiffService.snapshot.cwd ?? "nil") expected=\(ws1SecondDir.path)")
        c.closePane(p1b)
    }

    // TabStripView overflow 時 + 按鈕保持可見且可點擊，ultra-narrow / scrolled / modeBadge hit-testing 正確
    if let overflowStrip = p1.view.tabStrip {
        let origFrame = overflowStrip.frame
        overflowStrip.frame = NSRect(x: 0, y: 0, width: 130, height: TabStripView.height)
        overflowStrip.layoutSubtreeIfNeeded()
        let overflowAdd = overflowStrip.newTabRect
        r.check("TabStripView overflow 時 + 按鈕仍位於可視區域並可命中，且 clip 區外 hit-test 回 nil",
                overflowAdd.maxX <= overflowStrip.bounds.width - TabStripView.laneWidth + 0.5
                && overflowStrip.button(at: NSPoint(x: overflowAdd.midX, y: overflowAdd.midY)) == 100
                && overflowStrip.index(at: NSPoint(x: overflowAdd.midX, y: overflowAdd.midY)) == nil)

        // ultra-narrow: tabsWidth < 22 時隱藏/不命中 + 按鈕 (button 100)
        overflowStrip.frame = NSRect(x: 0, y: 0, width: TabStripView.laneWidth + 16, height: TabStripView.height)
        overflowStrip.layoutSubtreeIfNeeded()
        let ultraAdd = overflowStrip.newTabRect
        r.check("TabStripView tabsWidth < 22 時 button(at:) 不命中 + 按鈕 (100)",
                ultraAdd.maxX > (overflowStrip.bounds.width - TabStripView.laneWidth)
                && overflowStrip.button(at: NSPoint(x: ultraAdd.midX, y: ultraAdd.midY)) == nil)

        // modeBadge + 多分頁 scrolled overflow hit-testing
        let prevMode = p1.permissionMode
        var extraTabs: [Pane] = []
        for _ in 0..<3 {
            if let t = c.newTab(p1) {
                _ = await sinks.waitReady(t.id)
                extraTabs.append(t)
            }
        }
        extraTabs.last?.permissionMode = "bypassPermissions"
        p1.permissionMode = "bypassPermissions"
        c.refreshTabStrips(ws1)
        if let scrolledStrip = extraTabs.last?.view.tabStrip ?? p1.view.tabStrip {
            let savedScrolledFrame = scrolledStrip.frame
            scrolledStrip.frame = NSRect(x: 0, y: 0, width: 280, height: TabStripView.height)
            scrolledStrip.needsLayout = true
            scrolledStrip.layoutSubtreeIfNeeded()
            let lastIdx = max(0, scrolledStrip.items.count - 1)
            let lastRect = scrolledStrip.tabRect(lastIdx)
            let hitTab = scrolledStrip.index(at: NSPoint(x: max(1, lastRect.minX + 10), y: scrolledStrip.bounds.midY))
            let badgeAreaX = scrolledStrip.bounds.width - TabStripView.laneWidth - 8
            r.check("TabStripView modeBadge + scrolled overflow hit-test 正確命中選中分頁、排除 badge 區並保留關閉鈕",
                    scrolledStrip.modeBadge == "bypass"
                    && hitTab == lastIdx
                    && scrolledStrip.index(at: NSPoint(x: badgeAreaX, y: scrolledStrip.bounds.midY)) == nil
                    && scrolledStrip.button(at: NSPoint(x: scrolledStrip.buttonRect(2).midX, y: scrolledStrip.bounds.midY)) == 2,
                    "badge=\(scrolledStrip.modeBadge ?? "nil") hitTab=\(String(describing: hitTab)) expected=\(lastIdx) lastRect=\(lastRect)")
            scrolledStrip.frame = savedScrolledFrame
            scrolledStrip.needsLayout = true
            scrolledStrip.layoutSubtreeIfNeeded()
        }
        for t in extraTabs { c.closePane(t) }
        p1.permissionMode = prevMode
        c.selectTab(p1)
        c.refreshTabStrips(ws1)

        overflowStrip.frame = origFrame
        overflowStrip.layoutSubtreeIfNeeded()
    } else {
        r.check("TabStripView overflow 時 + 按鈕仍位於可視區域並可命中", false)
    }

    // 窄視窗與極矮視窗邊界保護：effectiveSw 縮窄、120pt 精確臨界值、centerChipHost < 40 隱藏、還原恢復、與 ensureFocus()
    let origContentFrame = c.root.frame
    c.model.inspectorVisible = true
    c.model.inspectorWidth = 320
    c.model.sidebarVisible = true
    c.model.sidebarWidth = 260

    c.root.frame = NSRect(x: 0, y: 0, width: 300, height: 400) // W < sidebarWidth + 120 -> effectiveSw = 180
    c.root.layoutSubtreeIfNeeded()
    r.check("RootView W < sidebarWidth + 120 時依 effectiveSw 縮窄左欄並維持 120pt 中央畫布",
            abs(c.root.sidebarBackdrop.frame.width - 179) < 0.5
            && abs(c.root.content.frame.width - 120) < 0.5
            && c.root.rightInspectorHost.isHidden,
            "sb=\(c.root.sidebarBackdrop.frame.width) content=\(c.root.content.frame.width)")

    c.root.frame = NSRect(x: 0, y: 0, width: 699, height: 400) // 699 - 260 - 320 = 119 < 120
    c.root.layoutSubtreeIfNeeded()
    r.check("RootView W - effectiveSw - iw == 119 (< 120) 時隱藏 rightInspectorHost",
            c.root.rightInspectorHost.isHidden
            && abs(c.root.content.frame.width - 439) < 0.5,
            "hidden=\(c.root.rightInspectorHost.isHidden) content=\(c.root.content.frame.width)")

    c.root.frame = NSRect(x: 0, y: 0, width: 700, height: 400) // 700 - 260 - 320 = 120 >= 120
    c.root.layoutSubtreeIfNeeded()
    r.check("RootView W - effectiveSw - iw == 120 時顯示 rightInspectorHost 並維持 120pt 中央畫布",
            !c.root.rightInspectorHost.isHidden
            && abs(c.root.rightInspectorHost.frame.width - 320) < 0.5
            && abs(c.root.content.frame.width - 120) < 0.5,
            "hidden=\(c.root.rightInspectorHost.isHidden) rw=\(c.root.rightInspectorHost.frame.width) content=\(c.root.content.frame.width)")

    c.root.frame = NSRect(x: 0, y: 0, width: 600, height: 360) // 最小視窗尺寸
    c.root.layoutSubtreeIfNeeded()
    r.check("RootView 600x360 最小視窗尺寸自動收合 Inspector 並保留 Footer 與 340pt 中央畫布",
            c.root.rightInspectorHost.isHidden
            && !c.root.footerHost.isHidden
            && abs(c.root.content.frame.width - 340) < 0.5)

    c.root.frame = NSRect(x: 0, y: 0, width: 800, height: 119)
    c.root.layoutSubtreeIfNeeded()
    let footerHiddenAt119 = c.root.footerHost.isHidden
    c.root.frame = NSRect(x: 0, y: 0, width: 800, height: 120)
    c.root.layoutSubtreeIfNeeded()
    let footerShownAt120 = !c.root.footerHost.isHidden
    r.check("RootView footerHost 在 H=119 隱藏、H=120 顯示", footerHiddenAt119 && footerShownAt120)

    c.root.frame = NSRect(x: 0, y: 0, width: 240, height: 400) // maxChipW < 40 -> centerChipHost.isHidden
    c.root.layoutSubtreeIfNeeded()
    r.check("RootView maxChipW < 40 時自動隱藏 centerChipHost", c.root.centerChipHost.isHidden)

    c.root.frame = NSRect(x: 0, y: 0, width: 650, height: 110) // 650 - 260 - 320 = 70 < 120; H=110 < 120
    c.root.layoutSubtreeIfNeeded()
    r.check("RootView 窄/矮視窗自動隱藏 rightInspectorHost 與 footerHost 以保護中央畫布",
            c.root.rightInspectorHost.isHidden && c.root.footerHost.isHidden)

    c.root.frame = origContentFrame
    c.root.layoutSubtreeIfNeeded()
    r.check("RootView 視窗恢復寬度與高度後重新顯示 rightInspectorHost、footerHost 與 centerChipHost",
            !c.root.rightInspectorHost.isHidden
            && !c.root.footerHost.isHidden
            && !c.root.centerChipHost.isHidden
            && c.root.content.frame.width > 120)

    // ensureFocus() 在 Inspector 收合或窄窗隱藏時將焦點交還目前終端 pane
    c.openInInspectorPreview(gitWsPreview, workspace: ws1)
    c.root.layoutSubtreeIfNeeded()
    if let webView = c.previewCoordinator.previewView?.webView {
        w.makeFirstResponder(webView)
    }
    c.toggleInspector()
    c.root.layoutSubtreeIfNeeded()
    r.check("toggleInspector() 收合後 ensureFocus() 將焦點交還終端 pane",
            !c.model.inspectorVisible && firstResponderPane(c) === ws1.focusedPane)
    c.toggleInspector()
    c.root.layoutSubtreeIfNeeded()
    if let webView = c.previewCoordinator.previewView?.webView {
        w.makeFirstResponder(webView)
    }
    c.root.frame = NSRect(x: 0, y: 0, width: 699, height: 400)
    c.root.layoutSubtreeIfNeeded()
    c.ensureFocus()
    r.check("窄視窗隱藏 Inspector 時 ensureFocus() 將焦點交還終端 pane",
            c.root.rightInspectorHost.isHidden && firstResponderPane(c) === ws1.focusedPane)
    c.root.frame = origContentFrame
    c.root.layoutSubtreeIfNeeded()

    // 5. Inspector 即時預覽、掛載控制項互動與分頁切換導覽
    c.model.inspectorVisible = false
    c.showInspectorTab(.trace)
    r.check("showInspectorTab(.trace) 自動展開 Inspector 並切換至 trace 分頁",
            c.model.inspectorVisible && c.model.inspectorTab == .trace)

    c.showInspectorTab(.diff)
    r.check("showInspectorTab(.diff) 切換至 diff 分頁", c.model.inspectorTab == .diff)

    c.showInspectorTab(.preview)
    r.check("showInspectorTab(.preview) 切換至 preview 分頁", c.model.inspectorTab == .preview)

    // F14: 透過真實滑鼠點擊驗證掛載中的 WindowFooterView / RightInspectorView / TitlebarRightCluster UI 互動
    c.root.layoutSubtreeIfNeeded()
    c.root.footerHost.displayIfNeeded()
    await Task.yield()
    let footerBounds = c.root.footerHost.bounds
    c.model.inspectorTab = .diff
    await click(c.root.footerHost, at: NSPoint(x: footerBounds.midX, y: footerBounds.midY))
    let clickedFooterTrace = c.model.inspectorVisible && c.model.inspectorTab == .trace
    await click(c.root.footerHost, at: NSPoint(x: footerBounds.width - 18, y: footerBounds.midY))
    let clickedFooterCollapse = !c.model.inspectorVisible
    await click(c.root.footerHost, at: NSPoint(x: footerBounds.width - 18, y: footerBounds.midY))
    let clickedFooterExpand = c.model.inspectorVisible
    await click(c.root.footerHost, at: NSPoint(x: footerBounds.width - 105, y: footerBounds.midY))
    let clickedFooterPreview = c.model.inspectorTab == .preview
    r.check("點擊掛載的 WindowFooterView Context/預覽/收合按鈕可切換 Inspector 分頁與開關",
            clickedFooterTrace && clickedFooterCollapse && clickedFooterExpand && clickedFooterPreview,
            "trace=\(clickedFooterTrace) collapse=\(clickedFooterCollapse) expand=\(clickedFooterExpand) preview=\(clickedFooterPreview)")

    // F3 / F10: 切換至原本記錄過預覽檔、但檔案已在磁碟刪除的 workspace 時，應立即關閉前一個預覽並清除 currentURL/previewView
    let deletedWs2Preview = fm.temporaryDirectory.appendingPathComponent("wb-deleted-preview-\(UUID().uuidString).md")
    try? "# Will Delete\n".write(to: deletedWs2Preview, atomically: true, encoding: .utf8)
    c.select(ws1)
    c.openInInspectorPreview(gitWsPreview, workspace: ws1)
    c.openInInspectorPreview(deletedWs2Preview, workspace: ws2)
    try? fm.removeItem(at: deletedWs2Preview)
    c.select(ws2)
    r.check("切換至記憶預覽檔已被刪除的 workspace 時，previewCoordinator 不殘留舊 workspace 預覽",
            c.previewCoordinator.workspaceID == ws2.id
            && c.previewCoordinator.currentURL == nil
            && c.previewCoordinator.previewView == nil,
            "wsID=\(c.previewCoordinator.workspaceID ?? "nil") url=\(c.previewCoordinator.currentURL?.path ?? "nil")")
    c.model.inspectorPreviewURLByWorkspace.removeValue(forKey: ws2.id)
    c.select(ws1)

    c.root.rightInspectorHost.displayIfNeeded()
    await Task.yield()
    let inspBounds = c.root.rightInspectorHost.bounds
    let headerClickY = c.root.rightInspectorHost.isFlipped ? 19 : (inspBounds.height - 19)
    await click(c.root.rightInspectorHost, at: NSPoint(x: inspBounds.width * 0.5, y: headerClickY))
    let clickedDiff = c.model.inspectorTab == .diff
    await click(c.root.rightInspectorHost, at: NSPoint(x: inspBounds.width * 5.0 / 6.0, y: headerClickY))
    let clickedTrace = c.model.inspectorTab == .trace
    await click(c.root.rightInspectorHost, at: NSPoint(x: inspBounds.width / 6.0, y: headerClickY))
    let clickedPreview = c.model.inspectorTab == .preview
    r.check("點擊掛載的 rightInspectorHost 頂部分頁列可切換 Diff / Trace / Preview",
            clickedDiff && clickedTrace && clickedPreview,
            "diff=\(clickedDiff) trace=\(clickedTrace) preview=\(clickedPreview)")

    c.root.rightClusterHost.displayIfNeeded()
    await Task.yield()
    let rcBounds = c.root.rightClusterHost.bounds
    let rcPaneCountBefore = ws1.panes.count
    await click(c.root.rightClusterHost, at: NSPoint(x: T.Layout.titlebarButtonSize + 2 + T.Layout.titlebarButtonSize / 2, y: rcBounds.midY))
    let clickedSplitDown = ws1.panes.count == rcPaneCountBefore + 1
    if clickedSplitDown, let extraDown = ws1.focusedPane, extraDown !== p1 {
        c.closePane(extraDown)
    }
    r.check("點擊掛載的 rightClusterHost Split Down 按鈕會垂直分割窗格", clickedSplitDown,
            "before=\(rcPaneCountBefore) after=\(ws1.panes.count)")

    // F11: sidebarAccessoryMaxHeight、RootView 版面放置（不重疊 filter header 或 footer）與 followHeight 同步
    let wbSuiteName = "dev.lmux.apptest.lg-workbench"
    UserDefaults.standard.removePersistentDomain(forName: wbSuiteName)
    let wbDefaults = UserDefaults(suiteName: wbSuiteName)!
    let barLayout = NotificationBarPlugin.install(on: c, defaults: wbDefaults)
    barLayout.isCollapsed = false
    let maxAccessoryH = c.sidebarAccessoryMaxHeight
    let maxExtraForDrag = max(0, maxAccessoryH - NotificationBarPlugin.minHeight(pluginRows: 0))
    barLayout.updateDrag(translationHeight: -800, maxExtra: maxExtraForDrag, on: c)
    barLayout.endDrag(on: c)
    try? await Task.sleep(for: .milliseconds(30))
    c.root.layoutSubtreeIfNeeded()
    let accView = c.root.sidebarAccessory?.view
    let accFrame = accView?.frame ?? .zero
    let filterFrame = c.root.workspaceFilterHeaderHost.frame
    let footerFrame = c.root.footerHost.frame
    let expectedMaxAccessory = max(
        0,
        c.root.bounds.height
            - c.root.titlebarHeight
            - T.Layout.footerHeight
            - T.Layout.workspaceFilterHeaderHeight
            - RootView.sidebarListMinHeight
    )
    let followHeightBeforeToggle = c.root.sidebarAccessory?.height ?? -1
    barLayout.toggleCollapsed(on: c)
    try? await Task.sleep(for: .milliseconds(30))
    c.root.layoutSubtreeIfNeeded()
    let followHeightCollapsed = c.root.sidebarAccessory?.height ?? -1
    c.model.sidebarVisible = false
    c.root.layoutSubtreeIfNeeded()
    let hiddenWhenSidebarCollapsed = accView?.isHidden == true
    c.model.sidebarVisible = true
    c.root.layoutSubtreeIfNeeded()
    r.check("sidebarAccessoryMaxHeight、RootView 版面位置與 followHeight 不與 footer 或 filter header 重疊",
            abs(maxAccessoryH - expectedMaxAccessory) < 0.5
            && accFrame.minY >= filterFrame.maxY + RootView.sidebarListMinHeight - 0.5
            && accFrame.maxY <= footerFrame.minY + 0.5
            && followHeightBeforeToggle > followHeightCollapsed
            && hiddenWhenSidebarCollapsed,
            "maxAcc=\(maxAccessoryH) acc=\(accFrame) filterMaxY=\(filterFrame.maxY) footerMinY=\(footerFrame.minY) hBefore=\(followHeightBeforeToggle) hColl=\(followHeightCollapsed)")

    // 為 --liquid-glass-restore 預備寫入持久化狀態
    c.model.inspectorVisible = true
    c.model.inspectorWidth = 360
    c.model.inspectorTab = .diff
    c.saveNow()

    barLayout.extra = 45
    barLayout.isCollapsed = true
    barLayout.save()

    return finish(r, c)
}

@MainActor
func runLiquidGlassRestore() async -> Int32 {
    let r = Report()
    r.section = "liquid-glass-restore"

    let c = makeController()
    r.check("重開驗證：inspectorVisible 正確還原", c.model.inspectorVisible == true)
    r.check("重開驗證：inspectorWidth 還原為 360pt", abs(c.model.inspectorWidth - 360) < 0.5,
            "actual=\(c.model.inspectorWidth)")
    r.check("重開驗證：inspectorTab 還原為 .diff", c.model.inspectorTab == .diff)

    let suiteName = "dev.lmux.apptest.lg-workbench"
    let wbDefaults = UserDefaults(suiteName: suiteName)!
    let barLayout = NotificationBarPlugin.install(on: c, defaults: wbDefaults)
    r.check("重開驗證：BarLayout.isCollapsed 正確還原", barLayout.isCollapsed == true)
    r.check("重開驗證：BarLayout.extra 還原為 45pt", abs(barLayout.extra - 45) < 0.5,
            "actual=\(barLayout.extra)")
    barLayout.toggleCollapsed(on: c)
    r.check("重開驗證：toggleCollapsed(on:) 可展開已還原收合的通知 bar", !barLayout.isCollapsed)
    wbDefaults.removePersistentDomain(forName: suiteName)

    return finish(r, c)
}
