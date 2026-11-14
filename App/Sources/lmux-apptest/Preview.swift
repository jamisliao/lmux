import AppKit
import GhosttyKit
import LmuxTerminal
@testable import LmuxUI

// `lmux-apptest --preview`：預覽 tab 與 ⌘-click 的開啟選單（beat/changes/md-html-preview）。
// 開啟選單由 `LmuxController.openMenuTestHook` 回答，不會真的跳出；開啟檔案與網址由
// `GhosttyRuntime.openURL` 接住，不會真的打開任何東西。

/// 一個新的 workspace：終端機 tab A（目前目錄是 `dir`），A 右邊是 `file` 的預覽 tab P。
@MainActor
func previewSetup(_ c: LmuxController, dir: URL, file: URL) -> (ws: Workspace, a: Pane, p: Pane) {
    let ws = c.newWorkspace(cwd: dir.path)
    let a = ws.panes[0]
    a.cwd = dir.path  // 測試用的 shell 不回報目前目錄（OSC 7）：直接設定
    let p = c.newPreviewTab(file, after: a)!
    return (ws, a, p)
}

/// layout.json 一個節點底下所有 tab 的 id。
func layoutPaneIDs(_ n: LayoutFile.NodeState) -> [String] {
    if let children = n.children { return children.flatMap(layoutPaneIDs) }
    return n.leafPanes.map(\.id)
}

@MainActor
func runPreview() async -> Int32 {
    let r = Report()
    var opened: [URL] = []
    GhosttyRuntime.openURL = { opened.append($0) }
    let c = makeController()
    // 測試用的檔案：<LMUX_STATE_DIR>/preview-fixtures/docs/{design.md, b.md, notes.txt}
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("preview-fixtures", isDirectory: true)
    let docs = fx.appendingPathComponent("docs", isDirectory: true)
    try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try? "# Design\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n[b](b.md)\n"
        .write(to: docs.appendingPathComponent("design.md"), atomically: true, encoding: .utf8)
    try? "# B\n".write(to: docs.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    try? "notes\n".write(to: docs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let design = docs.appendingPathComponent("design.md").standardizedFileURL

    // MARK: 建立預覽 tab（Task 20）
    // @feature: open-menu.feature
    // @scenario: 選「在新 tab 預覽」開出預覽 tab
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 的標題是檔名
    do {
        r.section = "preview-tab"
        let ws = c.newWorkspace(cwd: fx.path)
        let a = ws.panes[0]
        a.cwd = fx.path
        let b = c.newTab(a)!
        c.focus(a)
        let p = c.newPreviewTab(design, after: a)
        r.check("新 tab 預覽：開出沒有終端機的預覽 tab", p?.preview != nil && p?.surface == nil)
        if let p {
            r.check("預覽 tab 插在 A 與 B 之間", ws.root.find(a)?.tabs.map(\.id) == [a.id, p.id, b.id],
                    "\(ws.root.find(a)?.tabs.map(\.id) ?? [])")
            r.check("預覽 tab 成為 focused tab", ws.focusedPane === p)
            r.check("預覽 tab 的標題是檔名", p.headerTitle == "design.md", p.headerTitle)
            r.check("預覽 tab 的目前目錄是檔案所在資料夾", p.cwd == docs.standardizedFileURL.path, p.cwd ?? "nil")
            r.check("預覽 tab 顯示這個檔案", p.preview?.fileURL.standardizedFileURL == design)
            r.check("c.pane(id:) 找得到預覽 tab", c.pane(id: p.id) === p)
            let loaded = await waitFor(5) { p.preview?.webView.isLoading == false && p.preview?.webView.url != nil }
            let h1 = try? await p.preview?.webView.evaluateJavaScript("document.querySelector('h1').textContent")
            r.check("預覽 tab 顯示排版後的 Markdown", loaded && (h1 as? String) == "Design", "\(String(describing: h1))")
        }
    }

    // MARK: 預覽 tab 的焦點（Task 21）
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上
    do {
        r.section = "preview-focus"
        let (_, a, p) = previewSetup(c, dir: fx, file: design)
        c.focus(p)
        let fr = c.window!.firstResponder
        r.check("預覽 tab 取得焦點：first responder 在它的 WKWebView 裡",
                (fr as? NSView)?.isDescendant(of: p.preview!.webView) == true, "\(String(describing: fr))")
        var chain: NSResponder? = fr
        var reachesTerminal = false
        while let x = chain {
            if x is SurfaceView { reachesTerminal = true }
            chain = x.nextResponder
        }
        r.check("預覽 tab 是 focused tab 時，打字與 Paste 不會進到終端機", !reachesTerminal)
        c.focus(a)
        r.check("回到終端機 tab：first responder 是它的終端機", c.window!.firstResponder === a.surface)
    }

    // MARK: 開啟選單（Task 22）
    // @feature: open-menu.feature
    // @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單
    // @scenario: 路徑後面帶行號時，去掉行號再判斷
    // @scenario: OSC 8 連結指向本機的可預覽檔案時也跳出開啟選單
    // @scenario: 不是存在的可預覽檔案時，照原本流程
    // @scenario: shell 沒回報目前目錄時，相對路徑照原本流程
    // @scenario: 選「在新 tab 預覽」開出預覽 tab
    // @scenario: 選單的其他項目
    // @scenario: 不選任何項目就關掉選單
    do {
        r.section = "open-menu"
        var asked: [URL] = []
        var answer: LmuxController.OpenChoice?
        var revealed: [URL] = []
        var prompts: [UntrustedURLPrompt] = []
        LmuxController.openMenuTestHook = { asked.append($0); return answer }
        LmuxController.revealInFinder = { revealed.append($0) }
        UntrustedURLAlert.testHook = { prompts.append($0); return false }
        defer {
            LmuxController.openMenuTestHook = nil
            UntrustedURLAlert.testHook = nil
        }
        let ws = c.newWorkspace(cwd: fx.path)
        let a = ws.panes[0]
        a.cwd = fx.path
        let b = c.newTab(a)!
        c.focus(a)
        func click(_ value: String, _ kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN) {
            c.openTerminalLink(value, kind: kind, pane: a, view: a.surface)
        }
        /// 同一個值：經過 openTerminalLink，與直接走原本流程（GhosttyRuntime.openTerminalURL），開啟的東西與詢問都一樣。
        func sameAsBefore(_ value: String, _ kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN) -> Bool {
            opened.removeAll(); prompts.removeAll()
            GhosttyRuntime.openTerminalURL(value, kind: kind, window: a.surface?.window)
            let before = (opened, prompts)
            opened.removeAll(); prompts.removeAll()
            click(value, kind)
            return opened == before.0 && prompts == before.1
        }
        func real(_ u: URL) -> String { u.resolvingSymlinksInPath().path }

        // 選單本身
        let menu = LmuxController.makeOpenMenu(design, target: nil)
        r.check("選單第 1 列是完整路徑，不能點", menu.items.first?.title == design.path && menu.items.first?.isEnabled == false,
                menu.items.first?.title ?? "nil")
        r.check("選單項目依序是 在新 tab 預覽、用預設 app 開、在 Finder 顯示、複製路徑",
                menu.items.dropFirst(2).map(\.title) == ["在新 tab 預覽", "用預設 app 開", "在 Finder 顯示", "複製路徑"],
                "\(menu.items.map(\.title))")
        let longPath = "/" + String(repeating: "abcdefgh/", count: 15) + "design.md"
        r.check("太長的路徑省略資料夾中間，檔名完整保留",
                LmuxController.shortPath(longPath).hasSuffix("/design.md") && LmuxController.shortPath(longPath).count <= 90,
                LmuxController.shortPath(longPath))

        // 跳出選單；關掉選單
        answer = nil
        c.window!.makeFirstResponder(nil)
        opened.removeAll()
        click("docs/design.md")
        r.check("⌘-click 可預覽檔案的路徑：跳出開啟選單，問的是這個檔案", asked == [design], "\(asked)")
        r.check("關掉選單：沒有開出預覽 tab，也沒有開啟任何東西",
                ws.panes.count == 2 && opened.isEmpty && revealed.isEmpty, "\(ws.panes.count) \(opened) \(revealed)")
        r.check("關掉選單：焦點回到終端機", c.window!.firstResponder === a.surface)
        asked.removeAll()
        click("docs/design.md:12")
        r.check("路徑帶行號：去掉行號後仍跳出選單", asked == [design], "\(asked)")
        asked.removeAll()
        click(design.absoluteString, GHOSTTY_ACTION_OPEN_URL_KIND_OSC8)
        r.check("OSC 8 的 file:// 連結：跳出選單", asked == [design], "\(asked)")

        // 照原本流程
        asked.removeAll()
        r.check("不是可預覽檔案：照原本流程開啟",
                sameAsBefore(docs.appendingPathComponent("notes.txt").path) && opened.count == 1, "\(opened)")
        r.check("檔案不存在：照原本流程", sameAsBefore("docs/missing.md"))
        r.check("網址：照原本流程開啟",
                sameAsBefore("https://example.com/readme.md") && opened == [URL(string: "https://example.com/readme.md")!],
                "\(opened)")
        a.cwd = nil
        r.check("shell 沒回報目前目錄：相對路徑照原本流程", sameAsBefore("docs/design.md"))
        a.cwd = fx.path
        r.check("設定檔類（text）的連結：照原本流程", sameAsBefore(design.path, GHOSTTY_ACTION_OPEN_URL_KIND_TEXT))
        r.check("照原本流程的這幾種都沒有跳出選單", asked.isEmpty, "\(asked)")

        // 選單項目
        answer = .defaultApp; opened.removeAll()
        click("docs/design.md")
        r.check("用預設 app 開：交給系統開這個檔案", opened.map(real) == [real(design)], "\(opened)")
        answer = .finder
        click("docs/design.md")
        r.check("在 Finder 顯示：交給 Finder 選取這個檔案", revealed == [design], "\(revealed)")
        answer = .copyPath
        click("docs/design.md")
        r.check("複製路徑：剪貼簿是完整路徑", GhosttyRuntime.standardPasteboard.string(forType: .string) == design.path,
                GhosttyRuntime.standardPasteboard.string(forType: .string) ?? "nil")
        r.check("其他項目都不開出預覽 tab", ws.panes.count == 2, "\(ws.panes.count)")
        answer = .preview
        click("docs/design.md")
        let leaf = ws.root.find(a)
        let p = leaf?.tabs.first { $0.preview != nil }
        r.check("在新 tab 預覽：插在 A 與 B 之間", leaf?.tabs.map(\.id) == [a.id, p?.id ?? "-", b.id],
                "\(leaf?.tabs.map(\.id) ?? [])")
        r.check("在新 tab 預覽：成為 focused tab", p != nil && ws.focusedPane === p)
    }

    // MARK: Ghostty 的 OPEN_URL 走開啟選單（Task 23）
    // @feature: open-menu.feature
    // @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單
    do {
        r.section = "open-url-action"
        var asked: [URL] = []
        LmuxController.openMenuTestHook = { asked.append($0); return nil }
        defer { LmuxController.openMenuTestHook = nil }
        let ws = c.newWorkspace(cwd: fx.path)
        let a = ws.panes[0]
        a.cwd = fx.path
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        let handled: Bool? = "docs/design.md".withCString { ptr in
            action.action.open_url = ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: ptr,
                                                               len: UInt(strlen(ptr)))
            return c.runtime.actionHandler?(ghostty_target_s(), action, a.surface)
        }
        r.check("Ghostty 的 OPEN_URL 由 lmux 處理", handled == true, "\(String(describing: handled))")
        r.check("Ghostty 的 OPEN_URL 跳出開啟選單", await waitFor(3) { asked == [design] }, "\(asked)")
    }

    // MARK: 預覽裡換頁與點網址（Task 24）
    // @feature: preview-tab.feature
    // @scenario: 點相對路徑的 .md 連結，在同一個預覽 tab 換頁
    // @scenario: 點網址連結，照終端機裡點連結的規則處理
    // @scenario: 預覽中的檔案被刪除
    do {
        r.section = "preview-links"
        let gone = docs.appendingPathComponent("gone.md")
        try? "# Gone\n".write(to: gone, atomically: true, encoding: .utf8)
        let (ws, _, p) = previewSetup(c, dir: fx, file: design)
        _ = await waitFor(5) { p.preview?.webView.isLoading == false }
        let count = ws.panes.count
        p.preview!.show(docs.appendingPathComponent("b.md"))
        r.check("預覽換頁後 tab 標題跟著換成 b.md", await waitFor(5) { p.headerTitle == "b.md" }, p.headerTitle)
        r.check("預覽換頁時沒有開出新的 tab", ws.panes.count == count, "\(ws.panes.count)")
        p.preview!.webView.goBack()
        r.check("返回上一頁後 tab 標題改回 design.md", await waitFor(5) { p.headerTitle == "design.md" }, p.headerTitle)
        opened.removeAll()
        p.preview!.openExternal?(URL(string: "https://example.com/y")!)
        r.check("預覽裡點網址：照終端機點連結的規則開啟", opened == [URL(string: "https://example.com/y")!], "\(opened)")
        p.preview!.show(gone)
        _ = await waitFor(5) { p.headerTitle == "gone.md" }
        try? FileManager.default.removeItem(at: gone)
        try? await Task.sleep(for: .milliseconds(800))
        r.check("檔案被刪除後，預覽 tab 仍然留著", ws.panes.contains { $0 === p })
    }

    // MARK: 預覽 tab 上的選單項目（Task 25）
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 上停用只對終端機有意義的功能
    do {
        r.section = "preview-menu"
        let (_, a, p) = previewSetup(c, dir: fx, file: design)
        func enabled(_ action: Selector) -> Bool {
            c.validateMenuItem(NSMenuItem(title: "x", action: action, keyEquivalent: ""))
        }
        c.focus(p)
        let off: [(String, Selector)] = [
            ("Find…", #selector(LmuxController.menuFind(_:))),
            ("Find Next", #selector(LmuxController.menuFindNext(_:))),
            ("Find Previous", #selector(LmuxController.menuFindPrevious(_:))),
            ("Undo Send", #selector(LmuxController.menuUndoSend(_:))),
            ("Copy Original Reply", #selector(LmuxController.menuCopyOriginal(_:))),
            ("Ghostty 的字級／Clear Screen", #selector(LmuxController.menuGhosttyBinding(_:))),
        ]
        for (name, sel) in off { r.check("預覽 tab 上停用 \(name)", !enabled(sel)) }
        r.check("預覽 tab 上 Close Pane 仍可用", enabled(#selector(LmuxController.menuClosePane(_:))))
        r.check("預覽 tab 上 Move Tab Right 仍可用", enabled(#selector(LmuxController.menuMoveTabRight(_:))))
        r.check("預覽 tab 上 Split Right 仍可用", enabled(#selector(LmuxController.menuSplitRight(_:))))
        c.focus(a)
        r.check("回到終端機 tab：Find… 可用", enabled(#selector(LmuxController.menuFind(_:))))
    }

    // MARK: CLI（Task 26）
    // @feature: preview-tab.feature
    // @scenario: CLI 指定預覽 tab 時回傳錯誤
    do {
        r.section = "preview-cli"
        let (_, a, p) = previewSetup(c, dir: fx, file: design)
        r.check("lmux send 指定預覽 tab：回傳不是終端機", c.send(text: "x", toPane: p.id) == .notTerminal)
        let reply = c.handleControl(["cmd": "send", "pane": p.id, "text": "x"])
        r.check("CLI 的 send 錯誤訊息說明不是終端機", (reply["error"] as? String) == "not a terminal: \(p.id)", "\(reply)")
        let list = c.handleControl(["cmd": "list"])
        let ids = ((list["workspaces"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["panes"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["id"] as? String }
        r.check("lmux list 不列出預覽 tab，仍列出終端機 tab", !ids.contains(p.id) && ids.contains(a.id), "\(ids)")
    }

    // MARK: 存檔不存預覽 tab（Task 27）
    // @feature: preview-tab.feature
    // @scenario: 重開 lmux 不還原預覽 tab
    do {
        r.section = "preview-restore"
        let (ws, a, p) = previewSetup(c, dir: fx, file: design)
        let lone = c.newPreviewTab(docs.appendingPathComponent("b.md"), after: a)!
        c.moveTabToNewWorkspace(lone)
        let loneWS = lone.workspace!
        c.select(loneWS)  // 讓「只有預覽 tab 的 workspace」是選取中的 workspace
        let layout = c.snapshotLayout()
        let ids = layout.workspaces.first { $0.id == ws.id }.map { layoutPaneIDs($0.root) } ?? []
        r.check("存檔時不存預覽 tab，留下終端機 tab", !ids.contains(p.id) && ids.contains(a.id), "\(ids)")
        r.check("只有預覽 tab 的 workspace 不存", !layout.workspaces.contains { $0.id == loneWS.id })
        r.check("選取中的 workspace 沒存時，selected 改指向存下來的 workspace",
                layout.workspaces.contains { $0.id == layout.selected }, layout.selected ?? "nil")
    }

    // 新的檢查段落加在這一行上面（tasks.md 的 Task 21-28）
    return finish(r, c)
}
