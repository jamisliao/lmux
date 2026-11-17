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

/// `ws` 的第 k 列 Tab 子列的中心點（sidebar host 座標）。要先展開。
@MainActor
func tabChildPoint(_ c: LmuxController, _ ws: Workspace, _ k: Int) -> NSPoint {
    let L = LmuxTokens.Layout.self
    let host = c.root.sidebarHost
    let i = c.model.workspaces.firstIndex { $0 === ws } ?? 0
    let row = rowPoint(c, i)
    let h = ws.showsStateLine ? L.workspaceRowHeightDouble : L.workspaceRowHeightSingle
    let down = h / 2 + L.rowGap + CGFloat(k) * (L.tabChildRowHeight + L.rowGap) + L.tabChildRowHeight / 2
    return NSPoint(x: row.x, y: host.isFlipped ? row.y + down : row.y - down)
}

/// `ws` 的第 k 列 Tab 子列中間一塊的像素（標題的位置），用來比較「有沒有變」。
@MainActor
func tabChildPixels(_ c: LmuxController, _ ws: Workspace, _ k: Int) -> Data? {
    let p = tabChildPoint(c, ws, k)
    return sidebarPixels(c, NSRect(x: p.x - 40, y: p.y - 8, width: 80, height: 16))
}

/// `ws` 的展開箭頭的範圍（sidebar host 座標）：workspace 列左邊的留白，垂直對齊第 1 行。
@MainActor
func disclosureRect(_ c: LmuxController, _ ws: Workspace) -> NSRect {
    let L = LmuxTokens.Layout.self
    let host = c.root.sidebarHost
    let i = c.model.workspaces.firstIndex { $0 === ws } ?? 0
    let two = ws.showsStateLine
    let h = two ? L.workspaceRowHeightDouble : L.workspaceRowHeightSingle
    let s = L.tabDisclosureSize
    let center = rowPoint(c, i).y
    let fromTop = (host.isFlipped ? center : host.bounds.height - center) - h / 2
        + WorkspaceRow.closeTop(two) + (L.rowCloseButtonSize - s) / 2
    let y = host.isFlipped ? fromTop : host.bounds.height - fromTop - s
    return NSRect(x: WorkspaceRow.disclosureLeading, y: y, width: s, height: s)
}

/// 設了 LMUX_TABTREE_SHOTS（`dev.sh shots` 會設）時，把 sidebar 現在的樣子存成 <name>.png，給人看。
/// sidebar 的底色是另一個 view 畫的，所以圖的背景是透明的。
@MainActor
func saveSidebarShot(_ c: LmuxController, _ name: String) {
    guard let dir = env["LMUX_TABTREE_SHOTS"], !dir.isEmpty else { return }
    let host = c.root.sidebarHost
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
}

@MainActor
func runSidebarTabs() async -> Int32 {
    let r = Report()
    let c = makeController()
    let host = c.root.sidebarHost
    /// 等 sidebar 重新排版。
    func settle() async { host.layoutSubtreeIfNeeded(); await sleepMs(300) }

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

    // ------------------------------------------------------------- 點 Tab 子列
    // @feature: sidebar-tab-tree.feature
    // @scenario: 點 Tab 子列切換到另一個 workspace 的 tab
    r.section = "tab tree: click"
    ws = await stageTabWorkspaces(c, [("A", 1), ("B", 2)])
    let wb = ws[1]
    let t1 = wb.focusedPane!
    let t2 = wb.panes.first { $0 !== t1 }!
    c.toggleTabsExpanded(wb)
    await settle()
    r.check("佈置：A 是選取中的 workspace，B 的 T1 顯示在最前面、T2 被蓋住",
            c.model.selected === ws[0] && wb.root.find(t2)?.shownTab === t1)
    let k2 = wb.panes.firstIndex { $0 === t2 }!
    await click(host, at: tabChildPoint(c, wb, k2))
    _ = await waitFor(2) { c.model.selected === wb && wb.focusedPane === t2 }
    r.check("點 T2 的 Tab 子列：B 成為選取中的 workspace", c.model.selected === wb, c.model.selected?.title ?? "nil")
    r.check("…T2 顯示在它那一格的最前面，並成為 focused tab", wb.root.find(t2)?.shownTab === t2 && wb.focusedPane === t2)
    r.check("…鍵盤焦點也在 T2", firstResponderPane(c) === t2)
    let k1 = wb.panes.firstIndex { $0 === t1 }!
    await click(host, at: tabChildPoint(c, wb, k1))
    _ = await waitFor(2) { wb.focusedPane === t1 }
    r.check("再點 T1 的 Tab 子列：T1 回到最前面", wb.root.find(t1)?.shownTab === t1 && wb.focusedPane === t1)

    // workspace 列的位置：展開的在下面時不受影響；展開的在上面時往下移一組的高度。
    await click(host, at: rowPoint(c, 0))
    _ = await waitFor(2) { c.model.selected === ws[0] }
    r.check("B 展開時，B 上面的 A 的 workspace 列位置不變，還點得到", c.model.selected === ws[0])
    ws = await stageTabWorkspaces(c, [("A", 2), ("B", 1)])
    c.toggleTabsExpanded(ws[0])
    await settle()
    await click(host, at: rowPoint(c, 1))
    _ = await waitFor(2) { c.model.selected === ws[1] }
    r.check("A 展開時，A 下面的 B 的 workspace 列還點得到", c.model.selected === ws[1], c.model.selected?.title ?? "nil")

    // 多選時點 Tab 子列：和點 workspace 列一樣，多選結束。
    let ma = ws[0]
    c.select(ma)
    c.setSelection([ma.id, ws[1].id], anchor: ma.id)
    await settle()
    let other = ma.panes.first { $0 !== ma.focusedPane }!
    r.check("佈置：A 與 B 都在多選裡，A 是選取中的 workspace", c.model.isMultiSelection && c.model.selected === ma)
    await click(host, at: tabChildPoint(c, ma, ma.panes.firstIndex { $0 === other }!))
    _ = await waitFor(2) { ma.focusedPane === other }
    r.check("多選時點選取中 workspace 的 Tab 子列：切到那個 tab，多選結束",
            ma.focusedPane === other && !c.model.isMultiSelection, "\(c.model.selection.count)")

    // 放大某一格時點另一格的 tab：先取消放大。
    ws = await stageTabWorkspaces(c, [("Z", 1)])
    let z = ws[0]
    let zLeft = z.panes[0]
    let zRight = c.split(zLeft, .right)!
    _ = await waitFor(5) { zRight.surface!.foregroundPID > 0 }
    c.focus(zLeft)
    c.toggleZoom(for: zLeft)
    c.toggleTabsExpanded(z)
    await settle()
    r.check("佈置：Z 放大左邊那一格", z.zoomedPane === zLeft)
    await click(host, at: tabChildPoint(c, z, z.panes.firstIndex { $0 === zRight }!))
    _ = await waitFor(2) { z.focusedPane === zRight }
    r.check("放大時點另一格的 Tab 子列：取消放大，那個 tab 成為 focused tab", z.zoomedPane == nil && z.focusedPane === zRight)

    // ------------------------------------------------------------- 畫出來的樣子
    // @feature: sidebar-tab-tree.feature
    // @scenario: Tab 子列顯示 tab 的類型與標題
    // @scenario: Tab 子列顯示該 tab 自己的 agent 狀態
    // @scenario: 預覽 tab 的 Tab 子列沒有狀態圖示
    // @scenario: 只有 focused tab 的 Tab 子列有標示
    r.section = "tab tree: render"
    let anyPane = z.panes[0]
    /// 把一列 Tab 子列畫到畫面外，回傳像素。
    func shot(preview: Bool, _ display: AgentDisplay, focused: Bool = false) -> Data? {
        let item = SidebarTabItem(id: anyPane.id, title: "x", isPreview: preview, display: display, waiting: false,
                                  unread: 0, focused: focused, closable: true)
        return renderBytes(SidebarTabChildRow(item: item, pane: anyPane, hover: false, controller: c),
                           size: NSSize(width: 240, height: LmuxTokens.Layout.tabChildRowHeight), dark: false)
    }
    let plain = shot(preview: false, .idle)
    r.check("完成的終端機 tab 畫出來與閒置的不同（有 ✓）", plain != nil && shot(preview: false, .done(nil)) != plain)
    r.check("等待回應的終端機 tab 畫出來與閒置的不同", shot(preview: false, .needsInput(nil)) != plain)
    r.check("預覽 tab 的類型圖示與終端機 tab 的不同", shot(preview: true, .idle) != plain)
    r.check("預覽 tab 不畫狀態圖示（給它完成狀態，畫出來仍與閒置相同）", shot(preview: true, .done(nil)) == shot(preview: true, .idle))
    r.check("有標示的那一列畫出來與沒有標示的不同", shot(preview: false, .idle, focused: true) != plain)

    ws = await stageTabWorkspaces(c, [("A", 2), ("B", 2)])
    c.toggleTabsExpanded(ws[0])
    c.toggleTabsExpanded(ws[1])
    await settle()
    let fb = ws[1].panes.firstIndex { $0 === ws[1].focusedPane }!
    let whileA = tabChildPixels(c, ws[1], fb)
    c.select(ws[1])
    await settle()
    r.check("A 與 B 都展開：B 被選取後，B 的 focused tab 那一列才有標示（那一列的畫面變了）",
            whileA != nil && tabChildPixels(c, ws[1], fb) != whileA)

    // ------------------------------------------------------------- 拖曳排序
    // @feature: sidebar-tab-tree.feature
    // @scenario: 拖曳已展開的 workspace 時 Tab 子列跟著移動
    // @scenario: 拖 Tab 子列不會移動 workspace
    r.section = "tab tree: drag"
    // 一組的高度不同時（workspace 列 34 + 2 列 Tab 子列各 26 + 間距 4 = 94），位移照高度算。
    let geo = SidebarDragGeometry(order: ["a", "b", "c"], moving: ["a"],
                                  frames: ["a": CGRect(x: 0, y: 0, width: 200, height: 94),
                                           "b": CGRect(x: 0, y: 98, width: 200, height: 34),
                                           "c": CGRect(x: 0, y: 136, width: 200, height: 34)], gap: 4)
    let shifts = geo.offsets(grabbed: "a", dropIndex: 2)
    r.check("位移：展開的 A 拖到最後，B 與 C 各往上移 A 整組的高度加間距", shifts["b"] == -98 && shifts["c"] == -98, "\(shifts)")

    func order() -> String { c.model.workspaces.map(\.title).joined() }
    ws = await stageTabWorkspaces(c, [("A", 2), ("B", 1), ("C", 1)])
    let ga = ws[0]
    c.toggleTabsExpanded(ga)
    await settle()
    // design 的未查證第 2 項：sidebar 量每一組的 frame 時，有沒有把 Tab 子列算進去。
    let L = LmuxTokens.Layout.self
    let groupHeight = (ga.showsStateLine ? L.workspaceRowHeightDouble : L.workspaceRowHeightSingle)
        + 2 * (L.tabChildRowHeight + L.rowGap)
    let measured = host.rootView.rowFrames.frames[ga.id]?.height ?? 0
    r.check("sidebar 量到的 A 那一組的高度包含 2 列 Tab 子列（拖曳的位移用這個高度算）",
            abs(measured - groupHeight) < 1, "\(measured) vs \(groupHeight)")
    // 「往下」在 host 座標裡是哪個方向：第 1 列到第 2 列的方向。
    let step = rowPoint(c, 1).y - rowPoint(c, 0).y
    let below = NSPoint(x: rowPoint(c, 2).x, y: rowPoint(c, 2).y + (step > 0 ? 400 : -400))
    await dragRow(host, from: tabChildPoint(c, ga, 0), to: below)
    await sleepMs(400)
    r.check("拖 A 的 Tab 子列：順序不變", order() == "ABC" && c.model.sidebarDrag == nil, order())
    await dragRow(host, from: rowPoint(c, 0), to: below)
    _ = await waitFor(2) { order() != "ABC" }
    r.check("拖 A 的 workspace 列到 C 的下方：順序變成 B、C、A", order() == "BCA", order())
    r.check("…A 仍然展開，有 2 列 Tab 子列", ga.showsTabChildren && ga.tabItems(selected: true).count == 2)
    host.layoutSubtreeIfNeeded()
    await sleepMs(300)
    let last = ga.panes.first { $0 !== ga.focusedPane }!
    await click(host, at: tabChildPoint(c, ga, ga.panes.firstIndex { $0 === last }!))
    _ = await waitFor(2) { ga.focusedPane === last }
    r.check("…Tab 子列跟著 A 到新位置，還點得到", ga.focusedPane === last)

    // ------------------------------------------------------------- 展開箭頭
    // @feature: sidebar-tab-tree.feature
    // @scenario: 有多個 tab 的 workspace 可以展開與收合
    // @scenario: 只有 1 個 tab 的 workspace 沒有展開箭頭
    // @scenario: 點展開箭頭不切換 workspace
    // @scenario: 展開時 workspace 列照常顯示整體狀態
    r.section = "tab tree: disclosure"
    func clickDisclosure(_ w: Workspace) async {
        let f = disclosureRect(c, w)
        await click(host, at: NSPoint(x: f.midX, y: f.midY))
        await settle()
    }
    ws = await stageTabWorkspaces(c, [("A", 1)])
    let noArrow = sidebarPixels(c, disclosureRect(c, ws[0]))
    _ = c.newTab(ws[0].panes[0], select: false)
    await settle()
    r.check("開出第 2 個 tab 後，workspace 列左邊畫出展開箭頭（同一個位置的像素變了）",
            noArrow != nil && sidebarPixels(c, disclosureRect(c, ws[0])) != noArrow)

    ws = await stageTabWorkspaces(c, [("A", 3), ("B", 1), ("C", 2)])
    let (da, db, dc) = (ws[0], ws[1], ws[2])
    await clickDisclosure(da)
    r.check("點 A 的展開箭頭：展開", da.showsTabChildren)
    var reached: [String] = []
    for k in 0..<3 {
        await click(host, at: tabChildPoint(c, da, k))
        _ = await waitFor(2) { da.focusedPane === da.panes[k] }
        if da.focusedPane === da.panes[k] { reached.append(da.panes[k].id) }
    }
    r.check("…下方有 3 列 Tab 子列，每一列都點得到", reached == da.panes.map(\.id), "\(reached.count)")
    await clickDisclosure(da)
    r.check("再點一次：收合", !da.showsTabChildren)
    let focusedBefore = da.focusedPane
    await click(host, at: rowPoint(c, 1))
    _ = await waitFor(2) { c.model.selected === db }
    r.check("…Tab 子列消失：B 的 workspace 列回到 A 的正下方", c.model.selected === db && da.focusedPane === focusedBefore)

    await clickDisclosure(db)
    r.check("只有 1 個 tab 的 B：點同一個位置不會展開", !db.tabsExpanded && !db.showsTabChildren)

    c.select(da)
    await settle()
    let keyboard = firstResponderPane(c)
    await clickDisclosure(dc)
    r.check("A 是選取中的 workspace 時點 C 的展開箭頭：C 展開", dc.showsTabChildren)
    r.check("…A 仍然是選取中的 workspace", c.model.selected === da, c.model.selected?.title ?? "nil")
    r.check("…鍵盤焦點沒有被箭頭拿走", keyboard != nil && firstResponderPane(c) === keyboard)

    // 進行中的 tab：收合時只有 workspace 列轉圈；展開後 workspace 列照常轉圈，那個 tab 的 Tab 子列也轉圈。
    ws = await stageTabWorkspaces(c, [("R", 2)])
    let rw = ws[0]
    let runner = rw.panes.first { $0 !== rw.focusedPane }!
    _ = sendHook(pane: runner.id, hook("SessionStart", session: "s-spin"))
    _ = sendHook(pane: runner.id, hook("UserPromptSubmit", session: "s-spin", #""prompt":"hi""#))
    _ = await waitFor(5) { runner.agent.state == .running }
    await settle()
    let spinsCollapsed = spinningViews(c)
    r.check("收合：workspace 列有 1 個轉圈圖示", spinsCollapsed == 1, "\(spinsCollapsed)")
    await clickDisclosure(rw)
    r.check("展開：workspace 列照常轉圈，進行中的 tab 的 Tab 子列也轉圈（共 2 個）", spinningViews(c) == 2, "\(spinningViews(c))")

    // ------------------------------------------------------------- 截圖（給人看；不是檢查）
    if env["LMUX_TABTREE_SHOTS"] != nil {
        ws = await stageTabWorkspaces(c, [("alpha", 3), ("beta", 1), ("gamma", 2), ("delta", 2)])
        let appearance0 = NSApp.appearance
        for (name, dark) in [("light", false), ("dark", true)] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            ws[0].tabsExpanded = false
            c.select(ws[0]); c.setSelection([], anchor: ws[0].id); c.model.hoveredRowID = nil
            await settle()
            saveSidebarShot(c, "1-collapsed-selected-\(name)")       // 選取中的列：箭頭壓在底色左緣上嗎
            c.model.hoveredRowID = ws[2].id
            await settle()
            saveSidebarShot(c, "2-collapsed-hover-\(name)")          // 滑鼠在另一列上
            c.model.hoveredRowID = nil
            c.setSelection([ws[0].id, ws[2].id], anchor: ws[0].id)
            await settle()
            saveSidebarShot(c, "3-collapsed-multiselect-\(name)")    // 多選
            c.setSelection([], anchor: ws[0].id)
            ws[0].tabsExpanded = true
            ws[3].tabsExpanded = true
            await settle()
            saveSidebarShot(c, "4-expanded-\(name)")                 // 展開：縮排、列高、標示
        }
        NSApp.appearance = appearance0
        ws[3].tabsExpanded = false
    }

    // ------------------------------------------------------------- 從 Tab 子列關閉
    // @feature: sidebar-tab-tree.feature
    // @scenario: 從 Tab 子列關閉 tab
    // @scenario: 釘選的 tab 的 Tab 子列沒有關閉按鈕
    // @scenario: 關閉還有程式在跑的終端機 tab 會先詢問
    r.section = "tab tree: close"
    /// 把滑鼠放到 `p` 的 Tab 子列上，點關閉按鈕的位置（列的最右邊那一格）。
    func clickTabClose(_ w: Workspace, _ p: Pane) async {
        c.model.hoveredTabRowID = p.id
        host.layoutSubtreeIfNeeded()
        await sleepMs(150)
        let k = w.panes.firstIndex { $0 === p } ?? 0
        let x = host.bounds.width - WorkspaceRow.closeTrailing - LmuxTokens.Layout.rowCloseButtonSize / 2
        await click(host, at: NSPoint(x: x, y: tabChildPoint(c, w, k).y))
        c.model.hoveredTabRowID = nil
        await sleepMs(150)
    }
    ws = await stageTabWorkspaces(c, [("A", 3)])
    let ca = ws[0]
    c.toggleTabsExpanded(ca)
    host.layoutSubtreeIfNeeded()
    await sleepMs(300)
    let victim = ca.panes.first { $0 !== ca.focusedPane }!
    await clickTabClose(ca, victim)
    _ = await waitFor(3) { ca.panes.count == 2 }
    r.check("點閒置 tab 的關閉按鈕：這個 tab 關閉", ca.panes.count == 2 && !ca.panes.contains { $0 === victim })
    r.check("…下方剩 2 列 Tab 子列", ca.showsTabChildren && ca.tabItems(selected: true).count == 2)

    let pinned = ca.panes.first { $0 !== ca.focusedPane }!
    c.togglePin(pinned)
    r.check("釘選的 tab：Tab 子列沒有關閉按鈕", ca.tabItems(selected: true).first { $0.id == pinned.id }?.closable == false)
    await clickTabClose(ca, pinned)
    await sleepMs(300)
    r.check("…點那個位置不會關閉它", ca.panes.count == 2 && ca.panes.contains { $0 === pinned })
    r.check("…那一下點到的是列本身（沒有按鈕接走）：它成為 focused tab", ca.focusedPane === pinned)

    let busyScript = paths.stateDir.appendingPathComponent("busy.sh")
    try? "#!/bin/sh\nexec /bin/sleep 600\n".write(to: busyScript, atomically: true, encoding: .utf8)
    chmod(busyScript.path, 0o755)
    ws = await stageTabWorkspaces(c, [("A", 1), ("B", 1)])
    let cb = ws[1]
    let busy = c.newTab(cb.panes[0], program: busyScript.path, select: false)!
    _ = await waitFor(10) { busy.surface!.foregroundPID > 0 && c.runningProcess(busy) == "sleep" }
    c.toggleTabsExpanded(cb)
    host.layoutSubtreeIfNeeded()
    await sleepMs(300)
    r.check("佈置：A 是選取中的 workspace，B 的 T 還有程式在跑、被蓋住",
            c.model.selected === ws[0] && c.runningProcess(busy) == "sleep" && cb.root.find(busy)?.shownTab !== busy)
    await clickTabClose(cb, busy)
    _ = await waitFor(3) { c.cardShown(busy) }
    r.check("點 T 的關閉按鈕：B 成為選取中的 workspace，T 成為 focused tab", c.model.selected === cb && cb.focusedPane === busy)
    r.check("…T 上出現是否關閉的詢問", c.cardShown(busy))
    r.check("…T 還沒關閉", cb.panes.contains { $0 === busy } && cb.panes.count == 2)
    busy.view.overlay.card?.confirm.performClick()
    _ = await waitFor(3) { cb.panes.count == 1 }
    r.check("確認之後：T 關閉，B 剩 1 個 tab，展開箭頭與 Tab 子列消失",
            cb.panes.count == 1 && !cb.showsTabDisclosure && !cb.showsTabChildren)

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
