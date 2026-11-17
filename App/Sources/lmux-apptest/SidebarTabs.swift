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

    // ------------------------------------------------------------- Tab 子列的內容
    // @feature: sidebar-tab-tree.feature
    // @scenario: 分割出來的 tab 也列在同一層
    // @scenario: Tab 子列顯示 tab 的類型與標題
    // @scenario: Tab 子列顯示該 tab 自己的 agent 狀態
    // @scenario: 預覽 tab 的 Tab 子列沒有狀態圖示
    // @scenario: 只有 focused tab 的 Tab 子列有標示
    r.section = "tab tree: content"
    ws = await stageTabWorkspaces(c, [("S", 2)])
    let s = ws[0]
    let leftTabs = s.root.find(s.panes[0])!.tabs.map(\.id)
    let right = c.split(s.panes[0], .right)!
    _ = await waitFor(5) { right.surface!.foregroundPID > 0 }
    r.check("分割：左邊那格的 2 個 tab 依 tab 列順序，然後是右邊那格的 tab",
            s.tabItems(selected: true).map(\.id) == leftTabs + [right.id], "\(s.tabItems(selected: true).map(\.id))")

    ws = await stageTabWorkspaces(c, [("T", 4)])
    let t = ws[0]
    let idle = t.focusedPane!
    let others = t.panes.filter { $0 !== idle }
    let (run, done, need) = (others[0], others[1], others[2])
    run.titleState.title = "fix login"
    let doc = paths.stateDir.appendingPathComponent("design.md")
    try? "# design\n".write(to: doc, atomically: true, encoding: .utf8)
    let pv = c.newPreviewTab(doc, after: idle)!
    c.focus(idle)
    func item(_ p: Pane, selected: Bool = true) -> SidebarTabItem? { t.tabItems(selected: selected).first { $0.id == p.id } }
    r.check("終端機 tab：終端機類型，標題是任務名稱", item(run)?.isPreview == false && item(run)?.title == "fix login", item(run)?.title ?? "nil")
    r.check("預覽 tab：文件類型，標題是檔名", item(pv)?.isPreview == true && item(pv)?.title == "design.md", item(pv)?.title ?? "nil")

    // needHook：照 Step 1 查到的寫法。
    let needHook = hook("PermissionRequest", session: "s-need", #""tool_name":"Bash""#)
    let prompt = #""prompt":"hi""#
    _ = sendHook(pane: run.id, hook("SessionStart", session: "s-run"))
    _ = sendHook(pane: run.id, hook("UserPromptSubmit", session: "s-run", prompt))
    _ = sendHook(pane: done.id, hook("SessionStart", session: "s-done"))
    _ = sendHook(pane: done.id, hook("UserPromptSubmit", session: "s-done", prompt))
    _ = sendHook(pane: done.id, hook("Stop", session: "s-done"))
    _ = sendHook(pane: need.id, hook("SessionStart", session: "s-need"))
    _ = sendHook(pane: need.id, hook("UserPromptSubmit", session: "s-need", prompt))
    _ = sendHook(pane: need.id, needHook)
    _ = await waitFor(5) { run.agent.state == .running && done.agent.state == .done && need.needsInput }
    func isRunning(_ d: AgentDisplay?) -> Bool { if case .running = d { return true }; return false }
    func isDone(_ d: AgentDisplay?) -> Bool { if case .done = d { return true }; return false }
    func isNeedsInput(_ d: AgentDisplay?) -> Bool { if case .needsInput = d { return true }; return false }
    r.check("進行中的 tab：Tab 子列是進行中", isRunning(item(run)?.display), "\(String(describing: item(run)?.display))")
    r.check("完成的 tab：Tab 子列是完成", isDone(item(done)?.display), "\(String(describing: item(done)?.display))")
    r.check("等待回應的 tab：Tab 子列是等待回應", isNeedsInput(item(need)?.display), "\(String(describing: item(need)?.display))")
    r.check("閒置的 tab：沒有狀態", item(idle)?.display == .idle)
    r.check("預覽 tab：沒有狀態，也沒有未讀數", item(pv)?.display == .idle && item(pv)?.unread == 0)

    let marked = t.tabItems(selected: true).filter(\.focused).map(\.id)
    r.check("選取中的 workspace：只有 focused tab 的 Tab 子列有標示", marked == [idle.id], "\(marked)")
    r.check("…有標示的那一列不顯示未讀數", item(idle)?.unread == 0)
    r.check("沒選取的 workspace：Tab 子列都沒有標示", t.tabItems(selected: false).allSatisfy { !$0.focused })

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
