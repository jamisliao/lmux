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

    // ------------------------------------------------------------- 存檔（這一段留在最後）
    // @feature: sidebar-tab-tree.feature
    // @scenario: 重開 lmux 後維持展開狀態
    r.section = "tab tree: save"
    let saved = await stageTabWorkspaces(c, [("A", 2), ("B", 2)])
    c.toggleTabsExpanded(saved[0])
    // 1 個終端機 tab 加 1 個預覽 tab：預覽 tab 不存，重開後只剩 1 個 tab，但展開狀態要留著。
    let mixed = c.newWorkspace(cwd: "/tmp", select: false)
    mixed.customTitle = "P"
    let note = paths.stateDir.appendingPathComponent("note.md")
    try? "# note\n".write(to: note, atomically: true, encoding: .utf8)
    _ = c.newPreviewTab(note, after: mixed.panes[0])
    c.toggleTabsExpanded(mixed)
    c.select(saved[0])
    let layout = c.snapshotLayout()
    let sa = layout.workspaces.first { $0.id == saved[0].id }
    let sb = layout.workspaces.first { $0.id == saved[1].id }
    let sp = layout.workspaces.first { $0.id == mixed.id }
    r.check("存檔：展開的 A 存 true，收合的 B 不存這個欄位", sa?.tabsExpanded == true && sb != nil && sb?.tabsExpanded == nil,
            "\(String(describing: sa?.tabsExpanded)) \(String(describing: sb?.tabsExpanded))")
    r.check("…有預覽 tab 的 P 展開時也存 true", mixed.showsTabChildren && sp?.tabsExpanded == true)
    let old = #"{"id":"w","accent":0,"root":{"pane":{"id":"p"}}}"#
    let decoded = try? JSONDecoder().decode(LayoutFile.WorkspaceState.self, from: Data(old.utf8))
    r.check("沒有這個欄位的舊檔讀得進來，視為收合", decoded != nil && decoded?.tabsExpanded == nil)
    let future = #"{"id":"w","accent":0,"someFutureKey":1,"root":{"pane":{"id":"p"}}}"#
    r.check("多了不認得的欄位也讀得進來（舊版 lmux 讀新檔的情況）",
            (try? JSONDecoder().decode(LayoutFile.WorkspaceState.self, from: Data(future.utf8))) != nil)
    c.saveNow()
    try? JSONSerialization.data(withJSONObject: ["a": saved[0].id, "b": saved[1].id, "p": mixed.id])
        .write(to: paths.stateDir.appendingPathComponent("sidebar-tabs-expect.json"))

    return finish(r, c)
}

@MainActor
func runSidebarTabsRestore() async -> Int32 {
    let r = Report()
    r.section = "tab tree: relaunch"
    guard let d = try? Data(contentsOf: paths.stateDir.appendingPathComponent("sidebar-tabs-expect.json")),
          let e = try? JSONSerialization.jsonObject(with: d) as? [String: String] else {
        print("FAIL  [tab tree: relaunch] no expectations from --sidebar-tabs"); return 1
    }
    let c = makeController()
    let a = c.model.workspaces.first { $0.id == e["a"] }
    let b = c.model.workspaces.first { $0.id == e["b"] }
    r.check("重開：A 與 B 都讀回來，各有 2 個 tab", a?.panes.count == 2 && b?.panes.count == 2,
            "\(String(describing: a?.panes.count)) \(String(describing: b?.panes.count))")
    r.check("…A 仍然展開", a?.showsTabChildren == true)
    r.check("…B 仍然收合", b?.tabsExpanded == false && b?.showsTabChildren == false)
    if let p = c.model.workspaces.first(where: { $0.id == e["p"] }) {
        r.check("…P 的預覽 tab 沒讀回來，剩 1 個 tab：沒有 Tab 子列，但展開狀態還在",
                p.panes.count == 1 && p.tabsExpanded && !p.showsTabChildren, "\(p.panes.count) \(p.tabsExpanded)")
        _ = c.newTab(p.panes[0], select: false)
        r.check("…P 再開 1 個 tab：直接是展開的", p.showsTabChildren)
    } else {
        r.check("…P 讀回來了", false)
    }
    return finish(r, c)
}
