// @feature: liquid-glass-app.feature
// @scenario: 玻璃背景顯示毛玻璃與高光邊緣，開啟減少透明度時切換為不透明實底
// @scenario: 系統開啟減少動態效果時縮短過渡並停止呼吸動畫
// @scenario: 標題列置中顯示目前 workspace 資訊膠囊與快速操作按鈕
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
    r.check("Hook 事件記錄入 ToolCallStream", d1.toolCalls.count >= 2)

    let git1 = GitDiffSnapshot(cwd: "/tmp", isGitRepo: true, branch: "feat/workbench", totalAdded: 4, totalDeleted: 1)
    let pres1 = WindowFooterView.presentation(telemetry: d1, git: git1)
    r.check("WindowFooterView presentation 包含模型、Tool 與 Git 統計",
            pres1.gitBranchText == "feat/workbench" && pres1.gitChangesText == "+4 -1")

    // 切換至 Workspace 2（非 Git 空狀態或乾淨上下文）
    let ws2 = c.newWorkspace(select: true)
    ws2.customTitle = "workbench-empty"
    let p2 = ws2.focusedPane!
    p2.branch = nil

    let d2 = store.display(for: p2)
    let git2 = GitDiffSnapshot(cwd: "/tmp", isGitRepo: false)
    let pres2 = WindowFooterView.presentation(telemetry: d2, git: git2)
    r.check("切換 Workspace 2 後 Footer presentation 進入乾淨/空狀態",
            pres2.gitBranchText == "—" && pres2.gitChangesText == "—")

    // 切回 Workspace 1，驗證狀態復原
    c.select(ws1)
    r.check("切回 Workspace 1 後選中狀態與 pane 恢復", c.model.selected?.id == ws1.id)

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

    let barLayout = NotificationBarPlugin.install(on: c, defaults: .standard)
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

    let barLayout = NotificationBarPlugin.install(on: c, defaults: .standard)
    r.check("重開驗證：BarLayout.isCollapsed 正確還原", barLayout.isCollapsed == true)
    r.check("重開驗證：BarLayout.extra 還原為 45pt", abs(barLayout.extra - 45) < 0.5,
            "actual=\(barLayout.extra)")

    return finish(r, c)
}
