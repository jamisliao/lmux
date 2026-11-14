import AppKit
import GhosttyKit
import LmuxTerminal
@testable import LmuxUI
import WebKit

// `lmux-apptest --preview`：預覽 tab 與 ⌘-click 的開啟選單（beat/changes/md-html-preview）。
// 開啟選單由 `LmuxController.openMenuTestHook` 回答，不會真的跳出；開啟檔案與網址由
// `GhosttyRuntime.openURL` 接住，不會真的打開任何東西。

struct PreviewFixtures {
    let root: URL
    let docs: URL
    let design: URL
}

@MainActor
final class PreviewExternalSpy {
    var urls: [URL] = []
}

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
func firstTerminalInChain(from start: NSResponder?) -> SurfaceView? {
    var cur = start
    while let r = cur {
        if let s = r as? SurfaceView { return s }
        cur = r.nextResponder
    }
    return nil
}

@MainActor
func validatedPasteTarget(from start: NSResponder?) -> NSResponder? {
    let item = NSMenuItem(title: "Paste", action: #selector(SurfaceView.paste(_:)), keyEquivalent: "v")
    var cur = start
    while let r = cur {
        if r.responds(to: #selector(SurfaceView.paste(_:))) {
            if let v = r as? NSMenuItemValidation, !v.validateMenuItem(item) { cur = r.nextResponder; continue }
            if let v = r as? NSUserInterfaceValidations, !v.validateUserInterfaceItem(item) { cur = r.nextResponder; continue }
            return r
        }
        cur = r.nextResponder
    }
    return nil
}

@MainActor
func waitBodyContains(_ web: WKWebView, _ needle: String, timeout: Double = 5) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if let text = try? await web.evaluateJavaScript("document.body && document.body.innerText") as? String,
           text.contains(needle) { return true }
        await sleepMs(50)
    }
    return false
}

@MainActor
func runPreview() async -> Int32 {
    let r = Report()
    let external = PreviewExternalSpy()
    GhosttyRuntime.openURL = { external.urls.append($0) }
    let c = makeController()
    // 測試用的檔案：<LMUX_STATE_DIR>/preview-fixtures/docs/{design.md, b.md, notes.txt}
    let root = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("preview-fixtures", isDirectory: true)
    let docs = root.appendingPathComponent("docs", isDirectory: true)
    try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try? "# Design\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n[b](b.md) [ext](https://example.com/y)\n"
        .write(to: docs.appendingPathComponent("design.md"), atomically: true, encoding: .utf8)
    try? "# B\n".write(to: docs.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    try? "notes\n".write(to: docs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let design = docs.appendingPathComponent("design.md").standardizedFileURL
    let fixtures = PreviewFixtures(root: root, docs: docs, design: design)

    // MARK: 建立預覽 tab（Task 20）
    // @feature: open-menu.feature
    // @scenario: 選「在新 tab 預覽」開出預覽 tab
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 的標題是檔名
    // @scenario: Markdown 顯示成排版後的樣子
    do {
        r.section = "preview-tab"
        let ws = c.newWorkspace(cwd: root.path)
        let a = ws.panes[0]
        a.cwd = root.path
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
            r.check("預覽 tab 的標題列支援雙擊重新命名", p.view.header.onDoubleClick != nil)
            p.view.header.onDoubleClick?()
            c.renamePane(p, to: "自訂預覽")
            r.check("預覽 tab 可手動改名，改名後顯示自訂標題", p.headerTitle == "自訂預覽", p.headerTitle)
            c.renamePane(p, to: nil)
            r.check("清除自訂標題後回復檔名", p.headerTitle == "design.md", p.headerTitle)
            let loaded = await waitFor(5) { p.preview?.webView.isLoading == false && p.preview?.webView.url != nil }
            let h1 = try? await p.preview?.webView.evaluateJavaScript("document.querySelector('h1').textContent")
            r.check("預覽 tab 顯示排版後的 Markdown", loaded && (h1 as? String) == "Design", "\(String(describing: h1))")
        }
    }

    // MARK: 預覽 tab 的焦點（Task 21）
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上
    // @scenario: 在預覽 tab 選取文字並按 ⌘C 會複製到剪貼簿
    // @scenario: 預覽 tab 上停用只對終端機有意義的功能
    do {
        r.section = "preview-focus"
        let (_, a, p) = previewSetup(c, dir: root, file: design)
        r.check("終端機 A sink 就緒", await sinks.waitReady(a.id))
        _ = await waitFor(5) { p.preview?.webView.isLoading == false && p.preview?.webView.url != nil }
        c.focus(p)
        let fr = c.window!.firstResponder
        r.check("預覽 tab 取得焦點：first responder 在它的 WKWebView 裡",
                (fr as? NSView)?.isDescendant(of: p.preview!.webView) == true, "\(String(describing: fr))")
        let reachesTerminalTab = firstTerminalInChain(from: fr) != nil
        let pasteTargetTab = validatedPasteTarget(from: fr)
        GhosttyRuntime.standardPasteboard.clearContents()
        GhosttyRuntime.standardPasteboard.setString("LMUX_PASTE_ISOLATED", forType: .string)
        let sinkBefore = sinks.bytes(a.id).count
        await type("ls\r", window: c.window!)
        await cmd("v", window: c.window!)
        let pasteTabToSurface = pasteTargetTab is SurfaceView
        _ = fr?.tryToPerform(#selector(SurfaceView.paste(_:)), with: nil)
        await sleepMs(150)
        let sinkAfter = sinks.bytes(a.id).count
        r.check("預覽 tab 是 focused tab 時，打字與 Paste 不會進到終端機",
                !reachesTerminalTab && !pasteTabToSurface && sinkAfter == sinkBefore,
                "reaches=\(reachesTerminalTab) target=\(String(describing: pasteTabToSurface ? pasteTargetTab : nil)) sink=\(sinkBefore)->\(sinkAfter)")
        _ = try? await p.preview!.webView.evaluateJavaScript("window.getSelection().selectAllChildren(document.querySelector('h1'))")
        let sel = try? await p.preview!.webView.evaluateJavaScript("window.getSelection().toString()") as? String
        let pb = NSPasteboard.general
        pb.clearContents()
        let copiedByMenu = c.window!.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil) == true
        let copied = await waitFor(2) { pb.string(forType: .string) == "Design" }
        r.check("預覽 tab 是 focused tab 時，copy: 複製的是預覽裡的文字",
                copiedByMenu && copied, "sel=\(String(describing: sel)) pb=\(pb.string(forType: .string) ?? "nil")")
        // 分割情境下終端機仍在視窗內，⌘V / Paste 仍不能貼進 A
        c.moveTab(p, splitting: a, .right)
        c.focus(p)
        let frSplit = c.window!.firstResponder
        let reachesTerminalSplit = firstTerminalInChain(from: frSplit) != nil
        let pasteTargetSplit = validatedPasteTarget(from: frSplit)
        GhosttyRuntime.standardPasteboard.clearContents()
        GhosttyRuntime.standardPasteboard.setString("LMUX_SPLIT_PASTE_ISOLATED", forType: .string)
        let sinkSplitBefore = sinks.bytes(a.id).count
        await cmd("v", window: c.window!)
        _ = frSplit?.tryToPerform(#selector(SurfaceView.paste(_:)), with: nil)
        await sleepMs(150)
        let sinkSplitAfter = sinks.bytes(a.id).count
        r.check("分割配置且預覽為焦點時，Paste 不會貼進並排的終端機",
                !reachesTerminalSplit && !(pasteTargetSplit is SurfaceView) && sinkSplitAfter == sinkSplitBefore,
                "reaches=\(reachesTerminalSplit) target=\(String(describing: pasteTargetSplit)) sink=\(sinkSplitBefore)->\(sinkSplitAfter)")
        c.focus(a)
        r.check("回到終端機 tab：first responder 是它的終端機",
                c.window!.firstResponder === a.surface && validatedPasteTarget(from: c.window!.firstResponder) === a.surface)
        await type("ls\r", window: c.window!)
        r.check("聚焦終端機 tab 後，打字確實寫入終端機 sink", await sinks.wait(a.id, contains: "ls"))
        // 正向對照：單行純文字貼上（不含會觸發 headless confirmReadClipboard 拒絕的 \r/\n）應確實送入終端機 sink
        GhosttyRuntime.standardPasteboard.clearContents()
        GhosttyRuntime.standardPasteboard.setString("LMUX_TERM_PASTE_ACTION", forType: .string)
        let pasteDeliveredByResponder = c.window!.firstResponder?.tryToPerform(#selector(SurfaceView.paste(_:)), with: nil) == true
        let gotActionPaste = await sinks.wait(a.id, contains: "LMUX_TERM_PASTE_ACTION")
        GhosttyRuntime.standardPasteboard.clearContents()
        GhosttyRuntime.standardPasteboard.setString("LMUX_TERM_CMD_V", forType: .string)
        await cmd("v", window: c.window!)
        let gotCmdVPaste = await sinks.wait(a.id, contains: "LMUX_TERM_CMD_V")
        r.check("聚焦終端機 tab 後，paste(_:) 與 ⌘V 確實貼入終端機 sink",
                pasteDeliveredByResponder && gotActionPaste && gotCmdVPaste,
                "tryToPerform=\(pasteDeliveredByResponder) action=\(gotActionPaste) cmdV=\(gotCmdVPaste)")
    }

    // MARK: 深淺色外觀切換
    // @feature: preview-tab.feature
    // @scenario: Markdown 預覽跟著 lmux 的外觀設定切換深淺色
    do {
        r.section = "preview-appearance"
        let (_, _, p) = previewSetup(c, dir: root, file: design)
        _ = await waitFor(5) { p.preview?.webView.isLoading == false && p.preview?.webView.url != nil }
        c.setAppearance(.dark)
        var isDark = false
        for _ in 0..<40 {
            let m = try? await p.preview?.webView.evaluateJavaScript("window.matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
            let bg = try? await p.preview?.webView.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor") as? String
            let fg = try? await p.preview?.webView.evaluateJavaScript("getComputedStyle(document.body).color") as? String
            if m == true, bg == "rgb(13, 17, 23)", fg == "rgb(230, 237, 243)" { isDark = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        r.check("lmux 切換成 Dark 時，預覽跟著變深色", isDark)
        c.setAppearance(.light)
        var isLight = false
        for _ in 0..<40 {
            let m = try? await p.preview?.webView.evaluateJavaScript("window.matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
            let bg = try? await p.preview?.webView.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor") as? String
            let fg = try? await p.preview?.webView.evaluateJavaScript("getComputedStyle(document.body).color") as? String
            if m == false, bg == "rgb(255, 255, 255)", fg == "rgb(36, 41, 47)" { isLight = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        r.check("lmux 切換成 Light 時，預覽跟著變淺色", isLight)
        c.setAppearance(.system)
    }

    await runPreviewInteractionChecks(r, c, fixtures, external: external)
    await runPreviewPersistenceChecks(r, c, fixtures)
    return finish(r, c)
}
