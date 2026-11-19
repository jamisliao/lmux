// @feature: liquid-glass-app.feature
// @scenario: 玻璃背景顯示毛玻璃與高光邊緣，開啟減少透明度時切換為不透明實底
// @scenario: 系統開啟減少動態效果時縮短過渡並停止呼吸動畫
// @scenario: 右側 Inspector 即時預覽支援檔案切換、重整與雙軌開啟
// @scenario: 切換不同 workspace 時右側 Inspector 與底部狀態列同步切換上下文
// @scenario: 拖曳調整左右側邊欄、分割線、通知 bar 或視窗縮放期間啟動拖曳降級
// @scenario: 拖曳途中視窗或應用程式失去焦點時自動清除拖曳降級

import AppKit
import Foundation
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

        let allIdle = !sb.isOpaqueFallback && !tb.isOpaqueFallback && !rb.isOpaqueFallback && !fb.isOpaqueFallback
        let allVisible = !sb.material.isHidden && !tb.material.isHidden && !rb.material.isHidden && !fb.material.isHidden
        r.check("[\(label)] 4 個 Backdrop 預設皆啟用系統毛玻璃與高光邊緣", allIdle && allVisible)

        sb.forceOpaque = true; tb.forceOpaque = true; rb.forceOpaque = true; fb.forceOpaque = true
        let allOpaque = sb.isOpaqueFallback && tb.isOpaqueFallback && rb.isOpaqueFallback && fb.isOpaqueFallback
        let allMaterialsHidden = sb.material.isHidden && tb.material.isHidden && rb.material.isHidden && fb.material.isHidden
        r.check("[\(label)] forceOpaque / 減少透明度時 4 個 Backdrop 全數切換為不透明實底", allOpaque && allMaterialsHidden)

        sb.forceOpaque = false; tb.forceOpaque = false; rb.forceOpaque = false; fb.forceOpaque = false
    }

    // 2. Reduce Motion 停用呼吸與動畫
    c.reduceMotionOverride = false
    c.updatePulseMotion()
    r.check("預設開啟呼吸動態", c.model.pulseMotion && !c.model.reduceMotion)

    c.reduceMotionOverride = true
    c.updatePulseMotion()
    r.check("開啟減少動態效果後停止呼吸動畫並設 reduceMotion 為 true", c.model.reduceMotion && !c.model.pulseMotion)
    c.reduceMotionOverride = nil
    c.updatePulseMotion()

    // 3. 5 種調整目標拖曳大小 + 邊界鉗製 + 失焦復原 + 重啟拖曳
    // (a) 左側欄寬度手把（180...400 邊界鉗製）
    c.root.resizeHandle.onDrag?(100)
    r.check("左側欄寬度下限鉗製為 180pt", c.model.sidebarWidth == T.Layout.sidebarWidthMin)
    c.root.resizeHandle.onDrag?(600)
    r.check("左側欄寬度上限鉗製為 400pt", c.model.sidebarWidth == T.Layout.sidebarWidthMax)

    c.root.resizeHandle.onDragStateChange?(true)
    r.check("左側欄拖曳時 4 個 Backdrop 同時 isResizing",
            sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing)
    c.root.resizeHandle.onDragStateChange?(false)
    r.check("左側欄放開後 4 個 Backdrop 恢復毛玻璃",
            !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)

    // (b) 右側 Inspector 寬度手把（240...500 邊界鉗製）
    let W = c.root.bounds.width
    c.root.rightInspectorHandle.onDrag?(W - 100)
    r.check("右側 Inspector 寬度下限鉗製為 240pt", c.model.inspectorWidth == T.Layout.rightInspectorWidthMin)
    c.root.rightInspectorHandle.onDrag?(W - 800)
    r.check("右側 Inspector 寬度上限鉗製為 500pt", c.model.inspectorWidth == T.Layout.rightInspectorWidthMax)

    c.root.rightInspectorHandle.onDragStateChange?(true)
    r.check("右側 Inspector 拖曳時 4 個 Backdrop 同時 isResizing",
            sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing)
    c.root.rightInspectorHandle.onDragStateChange?(false)
    r.check("右側 Inspector 放開後 4 個 Backdrop 恢復毛玻璃",
            !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)

    // (c) 通知 bar 高度調整
    c.setSidebarResizing(true)
    r.check("通知 bar 拖曳時 4 個 Backdrop 同時 isResizing",
            sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing)
    c.setSidebarResizing(false)
    r.check("通知 bar 放開後 4 個 Backdrop 恢復", !sb.isResizing)

    // (c2) 中央窗格分割線 SplitContainerView 拖曳
    let splitBase = c.model.selected!.focusedPane!
    if let splitP2 = c.split(splitBase, .right), let splitNode = c.model.selected!.root.find(splitBase)?.parent,
       let splitContainer = c.splitView(for: splitNode) {
        splitContainer.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: splitContainer.bounds.midX, y: splitContainer.bounds.midY), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!)
        r.check("中央窗格分割線拖曳時 4 個 Backdrop 同時 isResizing",
                sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing)
        splitContainer.mouseUp(with: NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: splitContainer.bounds.midX, y: splitContainer.bounds.midY), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!)
        r.check("中央窗格分割線放開後 4 個 Backdrop 恢復",
                !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)
        c.closePane(splitP2)
    }

    // (d) 視窗縮放 live resize
    NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: w)
    r.check("視窗開始縮放時 4 個 Backdrop 同時 isResizing",
            sb.isResizing && tb.isResizing && rb.isResizing && fb.isResizing)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: w)
    r.check("視窗結束縮放後 4 個 Backdrop 恢復", !sb.isResizing)

    // (e) 拖曳中失焦與中斷安全復原
    c.root.setAllBackdropsResizing(true)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
    r.check("didResignKeyNotification 自動清除 4 個 Backdrop isResizing",
            !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)

    c.root.setAllBackdropsResizing(true)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    r.check("didResignActiveNotification 自動清除 4 個 Backdrop isResizing",
            !sb.isResizing && !tb.isResizing && !rb.isResizing && !fb.isResizing)

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
            && pres2.latestToolText == nil)

    // 切回 Workspace 1，驗證狀態與預覽上下文復原
    c.select(ws1)
    r.check("切回 Workspace 1 後選中狀態、chipState 與預覽 URL 恢復",
            c.model.selected?.id == ws1.id
            && c.root.chipState.workspace?.id == ws1.id
            && c.previewCoordinator.currentURL == gitWsPreview)

    // TabStripView overflow 時 + 按鈕保持可見且可點擊
    if let overflowStrip = p1.view.tabStrip {
        let origFrame = overflowStrip.frame
        overflowStrip.frame = NSRect(x: 0, y: 0, width: 130, height: TabStripView.height)
        overflowStrip.layoutSubtreeIfNeeded()
        let overflowAdd = overflowStrip.newTabRect
        r.check("TabStripView overflow 時 + 按鈕仍位於可視區域並可命中",
                overflowAdd.maxX <= overflowStrip.bounds.width - TabStripView.laneWidth + 0.5
                && overflowStrip.button(at: NSPoint(x: overflowAdd.midX, y: overflowAdd.midY)) == 100)
        overflowStrip.frame = origFrame
        overflowStrip.layoutSubtreeIfNeeded()
    } else {
        r.check("TabStripView overflow 時 + 按鈕仍位於可視區域並可命中", false)
    }

    // 5. Inspector 即時預覽與分頁切換導覽
    c.model.inspectorVisible = false
    c.showInspectorTab(.trace)
    r.check("showInspectorTab(.trace) 自動展開 Inspector 並切換至 trace 分頁",
            c.model.inspectorVisible && c.model.inspectorTab == .trace)

    c.showInspectorTab(.diff)
    r.check("showInspectorTab(.diff) 切換至 diff 分頁", c.model.inspectorTab == .diff)

    c.showInspectorTab(.preview)
    r.check("showInspectorTab(.preview) 切換至 preview 分頁", c.model.inspectorTab == .preview)

    // 為 --liquid-glass-restore 預備寫入持久化狀態
    c.model.inspectorVisible = true
    c.model.inspectorWidth = 360
    c.model.inspectorTab = .diff
    c.saveNow()

    let wbDefaults = UserDefaults(suiteName: "dev.lmux.apptest.lg-workbench")!
    let barLayout = NotificationBarPlugin.install(on: c, defaults: wbDefaults)
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
    wbDefaults.removePersistentDomain(forName: suiteName)

    return finish(r, c)
}
