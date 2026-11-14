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

    // 新的檢查段落加在這一行上面（tasks.md 的 Task 21-28）
    return finish(r, c)
}
