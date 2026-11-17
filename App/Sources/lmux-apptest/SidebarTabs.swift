import AppKit
import LmuxTokens
import SwiftUI
@testable import LmuxUI

// `lmux-apptest --sidebar-tabs`／`--sidebar-tabs-restore`：在 sidebar 展開 workspace 的 tab
// （beat: sidebar-tab-tree.feature）。pane 跑隔離的 zsh，headless。

/// 開出 spec 列的 workspace（閒置的 shell），每個共有 tabs 個終端機 tab（都在同一格）。
/// 原有的 workspace 全部關掉；第 1 個是選取中的 workspace。
@MainActor
func stageTabWorkspaces(_ c: LmuxController, _ spec: [(title: String, tabs: Int)]) async -> [Workspace] {
    let old = c.model.workspaces
    var made: [Workspace] = []
    for s in spec {
        let ws = c.newWorkspace(cwd: "/tmp", select: false)
        ws.customTitle = s.title
        for _ in 1..<max(1, s.tabs) { _ = c.newTab(ws.panes[0], select: false) }
        made.append(ws)
    }
    for o in old { c.closeWorkspace(o) }
    c.model.workspaces = made
    c.select(made[0])
    c.model.selection = []
    c.model.hoveredRowID = nil
    _ = await waitFor(10) {
        made.flatMap(\.panes).allSatisfy { $0.surface!.foregroundPID > 0 && c.runningProcess($0) == nil }
    }
    c.root.sidebarHost.layoutSubtreeIfNeeded()
    await sleepMs(200)
    return made
}

@MainActor
func runSidebarTabs() async -> Int32 {
    let r = Report()
    let c = makeController()

    // ------------------------------------------------------------- 佈置
    r.section = "tab tree: setup"
    let staged = await stageTabWorkspaces(c, [("A", 3), ("B", 1)])
    r.check("佈置：A 有 3 個 tab、B 有 1 個，A 是選取中的 workspace",
            staged[0].panes.count == 3 && staged[1].panes.count == 1 && c.model.selected === staged[0],
            "\(staged.map { $0.panes.count })")

    // ------------------------------------------------------------- 展開狀態
    // @feature: sidebar-tab-tree.feature
    // @scenario: 只有 1 個 tab 的 workspace 沒有展開箭頭
    // @scenario: 開出第 2 個 tab 時預設收合
    // @scenario: tab 數回到 2 個以上時回到原本的展開狀態
    r.section = "tab tree: state"
    var ws = await stageTabWorkspaces(c, [("A", 1)])
    let a = ws[0]
    r.check("只有 1 個 tab：沒有展開箭頭，也沒有 Tab 子列", !a.showsTabDisclosure && !a.showsTabChildren)
    c.toggleTabsExpanded(a)
    r.check("…展開狀態設成展開，仍然沒有 Tab 子列", a.tabsExpanded && !a.showsTabChildren)
    c.toggleTabsExpanded(a)

    let second = c.newTab(a.panes[0], select: false)!
    r.check("開出第 2 個 tab：有展開箭頭，預設收合", a.showsTabDisclosure && !a.tabsExpanded && !a.showsTabChildren)
    c.toggleTabsExpanded(a)
    r.check("切換一次：展開", a.showsTabChildren)
    c.toggleTabsExpanded(a)
    r.check("再切換一次：收合", !a.showsTabChildren)

    c.toggleTabsExpanded(a)
    c.closePane(second)
    r.check("展開後關到剩 1 個 tab：展開箭頭與 Tab 子列都消失", !a.showsTabDisclosure && !a.showsTabChildren)
    _ = c.newTab(a.panes[0], select: false)
    r.check("…再開 1 個 tab：回到展開", a.showsTabDisclosure && a.showsTabChildren && a.panes.count == 2)

    return finish(r, c)
}

@MainActor
func runSidebarTabsRestore() async -> Int32 {
    let r = Report()
    r.section = "tab tree: relaunch"
    let c = makeController()
    r.check("重開：有 workspace 讀回來", !c.model.workspaces.isEmpty)
    return finish(r, c)
}
