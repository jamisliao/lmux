import AppKit
import GhosttyKit
import LmuxTerminal
@testable import LmuxUI
import WebKit

/// 預覽 tab 的存檔、移動／關閉／新 tab、hit-test 與重開還原檢查。
@MainActor
func runPreviewPersistenceChecks(_ r: Report, _ c: LmuxController, _ fx: PreviewFixtures) async {
    let docs = fx.docs
    let design = fx.design

    // MARK: 存檔不存預覽 tab（Task 27）
    // @feature: preview-tab.feature
    // @scenario: 重開 lmux 不還原預覽 tab
    do {
        r.section = "preview-restore"
        let (ws, a, p) = previewSetup(c, dir: fx.root, file: design)
        let wsComplex = c.newWorkspace(cwd: fx.root.path)
        let c0 = wsComplex.panes[0]
        let c1 = c.newTab(c0)!
        let cp = c.newPreviewTab(design, after: c0)!  // 左側 tab 依序為 [c0, cp, c1]
        let rp = c.newPreviewTab(docs.appendingPathComponent("b.md"), after: cp)!
        c.moveTab(rp, splitting: c0, .right)  // 左側 leaf [c0, cp, c1]，右側僅預覽 [rp]
        c.focus(cp)  // 明確讓左側 leaf 目前顯示預覽 tab cp
        c.focus(rp)
        c.toggleZoom(for: rp)  // wsComplex.zoomedPane === rp && wsComplex.focusedPane === rp

        let wsReindex = c.newWorkspace(cwd: fx.root.path)
        let d0 = wsReindex.panes[0]
        let d1 = c.newTab(d0)!
        let dp = c.newPreviewTab(design, after: d0)!  // [d0, dp, d1]
        c.focus(d1)  // 目前顯示終端機 d1（原本索引 2，去掉 dp 後應重算為 1）

        let wsMixedFocus = c.newWorkspace(cwd: fx.root.path)
        let m0 = wsMixedFocus.panes[0]
        let mp = c.newPreviewTab(design, after: m0)!  // 同一個 leaf [m0, mp]
        c.focus(mp)  // 焦點落在預覽 tab mp 上，存檔應退回同 leaf 留下的終端機 m0

        let lone = c.newPreviewTab(docs.appendingPathComponent("b.md"), after: a)!
        c.moveTabToNewWorkspace(lone)
        let loneWS = lone.workspace!
        c.select(loneWS)  // 讓「只有預覽 tab 的 workspace」是選取中的 workspace
        let layout = c.snapshotLayout()
        let ids = layout.workspaces.first { $0.id == ws.id }.map { layoutPaneIDs($0.root) } ?? []
        r.check("存檔時不存預覽 tab，留下終端機 tab", !ids.contains(p.id) && ids.contains(a.id), "\(ids)")
        if let snapComplex = layout.workspaces.first(where: { $0.id == wsComplex.id }) {
            r.check("只有預覽的分割被收斂成單邊", snapComplex.root.children == nil)
            r.check("顯示中的預覽 tab 被略過後，selectedTab 回退為 0（[c0, c1]）",
                    snapComplex.root.leafPanes.map(\.id) == [c0.id, c1.id] && snapComplex.root.selectedTab == 0,
                    "\(snapComplex.root.leafPanes.map(\.id)) sel=\(String(describing: snapComplex.root.selectedTab))")
            r.check("聚焦或放大的預覽 tab 不存進 focusedPane / zoomedPane",
                    snapComplex.focusedPane == nil && snapComplex.zoomedPane == nil,
                    "focused=\(snapComplex.focusedPane ?? "nil") zoomed=\(snapComplex.zoomedPane ?? "nil")")
        } else {
            r.check("複雜分支預覽收斂測試 workspace 有被保存", false)
        }
        if let snapReindex = layout.workspaces.first(where: { $0.id == wsReindex.id }) {
            r.check("預覽在前的多 tab 重算 selectedTab（[d0, dp, d1] 顯示 d1 → selectedTab == 1）",
                    snapReindex.root.leafPanes.map(\.id) == [d0.id, d1.id] && snapReindex.root.selectedTab == 1,
                    "\(snapReindex.root.leafPanes.map(\.id)) sel=\(String(describing: snapReindex.root.selectedTab))")
        } else {
            r.check("重算索引測試 workspace 有被保存", false)
        }
        if let snapMixed = layout.workspaces.first(where: { $0.id == wsMixedFocus.id }) {
            r.check("同格內焦點在預覽 tab 時，focusedPane 退回同格留下的終端機（S6）",
                    snapMixed.focusedPane == m0.id,
                    "focused=\(snapMixed.focusedPane ?? "nil") expected=\(m0.id)")
        } else {
            r.check("同格焦點退回測試 workspace 有被保存", false)
        }
        r.check("只有預覽 tab 的 workspace 不存", !layout.workspaces.contains { $0.id == loneWS.id })
        r.check("選取中的 workspace 沒存時，selected 改指向存下來的 workspace",
                layout.workspaces.contains { $0.id == layout.selected }, layout.selected ?? "nil")
        c.saveNow()
        let expect: [String: String] = [
            "ws": ws.id, "a": a.id, "p": p.id, "lone": loneWS.id,
            "wsComplex": wsComplex.id, "c0": c0.id, "c1": c1.id, "cp": cp.id, "rp": rp.id,
            "wsReindex": wsReindex.id, "d0": d0.id, "d1": d1.id, "dp": dp.id,
            "wsMixedFocus": wsMixedFocus.id, "m0": m0.id, "mp": mp.id,
        ]
        try? JSONSerialization.data(withJSONObject: expect)
            .write(to: URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("preview-expect.json"))
    }

    // MARK: 移動、分割、關閉、開新 tab（Task 28）
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 可以像終端機 tab 一樣移動與分割
    // @scenario: 關閉預覽 tab 後，相鄰 tab 成為 focused tab
    // @scenario: 在預覽 tab 上開新 tab，新的終端機從檔案所在資料夾開始
    do {
        r.section = "preview-move"
        let (ws, a, p) = previewSetup(c, dir: fx.root, file: design)
        let fileBefore = p.preview!.fileURL
        if let leaf = ws.root.find(a) {
            c.moveTab(p, into: a, at: 0)
            r.check("預覽 tab 可在同一個 tab strip 拖拉調換順序", leaf.tabs.map(\.id) == [p.id, a.id],
                    "\(leaf.tabs.map(\.id))")
        }
        c.moveTab(p, splitting: a, .right)
        r.check("預覽 tab 拖到右側分割後與 A 並排", ws.isSplit && ws.visiblePanes.contains { $0 === p } && ws.visiblePanes.contains { $0 === a })
        r.check("移動後仍顯示原本的檔案", p.preview!.fileURL == fileBefore)
        c.focus(p)
        let t = c.newTab(p)
        r.check("在預覽 tab 上開新 tab：新的終端機從檔案所在資料夾開始",
                t?.surface != nil && t?.cwd == docs.standardizedFileURL.path, "\(t?.cwd ?? "nil")")
        if let t { c.closePane(t) }
        c.closePane(p)
        r.check("關閉預覽 tab 後它消失", !ws.panes.contains { $0 === p })
        r.check("關閉預覽 tab 後 A 成為 focused tab", ws.focusedPane === a)
        r.check("關閉預覽 tab 時釋放它的預覽（停止監看與載入）", p.preview?.isClosed == true)
        @MainActor
        func createAndCloseDisposablePreview() -> () -> AnyObject? {
            guard let extra = c.newPreviewTab(design, after: a) else { return { nil } }
            weak let weakPreview = extra.preview
            c.closePane(extra)
            return { weakPreview }
        }
        let getWeakPreview = createAndCloseDisposablePreview()
        r.check("關閉預覽 tab 後 PreviewView 物件從記憶體釋放（S19）",
                await waitFor(2) { getWeakPreview() == nil })
    }

    // MARK: 預覽 clickMonitor 與 PaneView / ConfirmCard 遮擋真實檢查（FF5）
    do {
        r.section = "preview-click-hit"
        let prevOpenURL = GhosttyRuntime.openURL
        var opened: [URL] = []
        GhosttyRuntime.openURL = { opened.append($0) }
        defer { GhosttyRuntime.openURL = prevOpenURL }
        let prevOneTabBar = c.settings.tabBarWithOneTab
        c.setTabBarWithOneTab(false)
        defer { c.setTabBarWithOneTab(prevOneTabBar) }

        let clickHTML = docs.appendingPathComponent("clickhit.html")
        try? "<html><body><a id=\"ext\" href=\"https://example.com/apptest\">go</a></body></html>"
            .write(to: clickHTML, atomically: true, encoding: .utf8)
        let (ws, a, p) = previewSetup(c, dir: fx.root, file: clickHTML)
        defer { c.closeWorkspace(ws) }
        c.moveTab(p, splitting: a, .right)
        c.focus(p)
        c.window!.layoutIfNeeded()
        _ = await waitFor(5) { p.preview?.webView.url?.lastPathComponent == "clickhit.html" && p.preview?.webView.isLoading == false }
        c.window!.layoutIfNeeded()

        @MainActor func sendClick(windowPoint: NSPoint) {
            let win = c.window!
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0
            )!
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
            while let ev = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                NSApp.sendEvent(ev)
            }
        }

        let web = p.preview!.webView
        let webCenter = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
        let hdr = p.view.header
        r.check("分割後的預覽 pane 顯示 header 且具高度", !hdr.isHidden && hdr.bounds.height > 0, "\(hdr.bounds)")

        // 1) 正例：split + header 偏移 + RingView / 空 PaneOverlayView 下，點擊 webView 內應觸發 openURL
        opened.removeAll()
        sendClick(windowPoint: webCenter)
        _ = try? await web.evaluateJavaScript("document.getElementById('ext').click(); true")
        let hitOK = await waitFor(3) { opened == [URL(string: "https://example.com/apptest")!] }
        r.check("split + header 下在 webView 內真實點擊會觸發 openExternal", hitOK, "\(opened)")

        // 2) 反例：點擊在 PaneHeader 上不觸發 openURL
        opened.removeAll()
        let hdrCenter = hdr.convert(NSPoint(x: hdr.bounds.midX, y: hdr.bounds.midY), to: nil)
        sendClick(windowPoint: hdrCenter)
        _ = try? await web.evaluateJavaScript("document.getElementById('ext').click(); true")
        try? await Task.sleep(for: .milliseconds(200))
        r.check("點擊在 PaneHeader 上不會觸發預覽外部連結", opened.isEmpty, "\(opened)")

        // 3) 反例：顯示 ConfirmCard 時點擊卡片上方不會觸發底下預覽外部連結
        let readyA = await waitFor(5) { a.surface?.foregroundPID ?? 0 > 0 }
        r.check("終端機 pane 已就緒可執行 sleep", readyA)
        a.surface?.sendText("sleep 30\n")
        let busy = await waitFor(5) { c.runningProcess(a) != nil }
        r.check("sleep 30 正在執行", busy)
        c.focus(p)
        c.requestCloseWorkspaces([ws])
        _ = await waitFor(3) { p.view.overlay.card != nil }
        p.view.overlay.layoutSubtreeIfNeeded()
        if let card = p.view.overlay.card {
            opened.removeAll()
            let cardCenter = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
            sendClick(windowPoint: cardCenter)
            _ = try? await web.evaluateJavaScript("document.getElementById('ext').click(); true")
            try? await Task.sleep(for: .milliseconds(200))
            r.check("點擊 ConfirmCard 遮罩區域不會觸發底下預覽外部連結", opened.isEmpty, "\(opened)")
        } else {
            r.check("ConfirmCard 已顯示在預覽 pane 上", false)
        }
    }
}

// @feature: preview-tab.feature
// @scenario: 重開 lmux 不還原預覽 tab
@MainActor
func runPreviewRestore() async -> Int32 {
    let r = Report()
    r.section = "preview-relaunch"
    let expectURL = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("preview-expect.json")
    guard let data = try? Data(contentsOf: expectURL),
          let e = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let wsID = e["ws"], let aID = e["a"], let pID = e["p"], let loneID = e["lone"],
          let wsComplexID = e["wsComplex"], let c0ID = e["c0"], let c1ID = e["c1"],
          let cpID = e["cp"], let rpID = e["rp"],
          let wsReindexID = e["wsReindex"], let d0ID = e["d0"], let d1ID = e["d1"], let dpID = e["dp"] else {
        print("FAIL  [preview-relaunch] missing expectations from --preview")
        return 1
    }
    let c = makeController()
    r.check("重開後保留含終端機的 workspace，且不還原只有預覽 tab 的 workspace",
            c.model.workspaces.contains { $0.id == wsID } && !c.model.workspaces.contains { $0.id == loneID })
    r.check("重開後終端機 tab 回來，預覽 tab 沒有回來",
            c.pane(id: aID) != nil && c.pane(id: pID) == nil)
    if let complex = c.model.workspaces.first(where: { $0.id == wsComplexID }) {
        r.check("重開後僅預覽的一側分割收斂成未分割，且沒有 zoomedPane",
                !complex.isSplit && complex.zoomedPane == nil)
        r.check("重開後 [c0, c1] 回來、預覽 tab 不在且 shownTab 回退為 c0",
                c.pane(id: c0ID) != nil && c.pane(id: c1ID) != nil
                    && c.pane(id: cpID) == nil && c.pane(id: rpID) == nil
                    && complex.root.shownTab?.id == c0ID,
                "\(complex.root.shownTab?.id ?? "nil")")
    } else {
        r.check("重開後複雜分支 workspace 存在", false)
    }
    if let reindex = c.model.workspaces.first(where: { $0.id == wsReindexID }) {
        r.check("重開後 [d0, d1] 回來、dp 不在且 shownTab 仍維持 d1",
                c.pane(id: d0ID) != nil && c.pane(id: d1ID) != nil
                    && c.pane(id: dpID) == nil
                    && reindex.root.shownTab?.id == d1ID,
                "\(reindex.root.shownTab?.id ?? "nil")")
    } else {
        r.check("重開後重算索引 workspace 存在", false)
    }
    if let wsMixedID = e["wsMixedFocus"], let m0ID = e["m0"], let mpID = e["mp"] {
        if let mixed = c.model.workspaces.first(where: { $0.id == wsMixedID }) {
            r.check("重開後同格原本聚焦在預覽 tab 的，焦點回到終端機 m0（S6）",
                    c.pane(id: m0ID) != nil && c.pane(id: mpID) == nil && mixed.focusedPane?.id == m0ID,
                    "focused=\(mixed.focusedPane?.id ?? "nil")")
        } else {
            r.check("重開後同格焦點退回 workspace 存在", false)
        }
    }
    r.check("重開後選取的 workspace 不是被略過的預覽 workspace",
            c.model.selected != nil && c.model.selected?.id != loneID)
    return finish(r, c)
}
