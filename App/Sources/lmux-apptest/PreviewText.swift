import AppKit
import GhosttyKit
import LmuxTerminal
@testable import LmuxUI
import UniformTypeIdentifiers
import WebKit

/// 純文字檔的預覽（beat/changes/plain-text-preview）：⌘-click 跳出開啟選單、開出預覽 tab、外觀、自動更新、
/// 頁內連結、`.sh`／`.command` 選「用預設 app 開」仍被擋。選單由 `openMenuTestHook` 回答，提示由 `UntrustedURLAlert.testHook` 回答。
@MainActor
func runPreviewTextChecks(_ r: Report, _ c: LmuxController, _ fx: PreviewFixtures, external: PreviewExternalSpy) async {
    // @feature: plain-text-preview.feature
    // @scenario: ⌘-click 純文字檔的路徑跳出開啟選單
    // @scenario: macOS 不認為是純文字、或被排除的檔案，照原本流程
    // @scenario: 路徑帶行號時，從檔案開頭顯示
    // @scenario: 純文字檔以等寬字型原樣顯示
    // @scenario: 有執行權限的 shell script 只顯示，不執行
    // @scenario: 純文字預覽跟著 lmux 的外觀設定切換深淺色
    // @scenario: 純文字檔內容改變後，預覽自動更新
    // @scenario: 預覽中的純文字檔被刪除
    // @scenario: shell script 選「用預設 app 開」仍被安全規則擋下
    // @scenario: Markdown 預覽裡連到純文字檔的連結不換頁
    r.section = "preview-text"
    let root = fx.root.appendingPathComponent("text-fixtures", isDirectory: true)
    let textPaths = ["notes/todo.txt", "scripts/deploy.sh", "scripts/run.command", "config/app.yaml", "config/app.yml",
                     "data/result.json", "logs/run.log", "tools/check.py"]
    let otherPaths = ["docs/intro.rtf", "assets/logo.svg", "web/app.ts", "config/.env"]
    for path in textPaths + otherPaths {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "x\n".write(to: url, atomically: true, encoding: .utf8)
    }
    let sh = root.appendingPathComponent("scripts/deploy.sh")
    let ran = root.appendingPathComponent("scripts/deploy-ran")
    try? "#!/bin/sh\ntouch '\(ran.path)'\necho '<b>done</b>'\n".write(to: sh, atomically: true, encoding: .utf8)
    _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
    let yaml = root.appendingPathComponent("config/app.yaml")
    try? (1...80).map { "line \($0): value" }.joined(separator: "\n").write(to: yaml, atomically: true, encoding: .utf8)
    let guide = root.appendingPathComponent("docs/guide.md")
    try? "# Guide\n\n[設定](../config/app.yml)\n".write(to: guide, atomically: true, encoding: .utf8)
    await sleepMs(500)  // 先建好檔案再開預覽：避免監看收到建檔事件而重新載入

    var asked: [URL] = []
    var answer: LmuxController.OpenChoice?
    var prompts: [UntrustedURLPrompt] = []
    LmuxController.openMenuTestHook = { asked.append($0); return answer }
    UntrustedURLAlert.testHook = { prompts.append($0); return false }
    defer {
        LmuxController.openMenuTestHook = nil
        UntrustedURLAlert.testHook = nil
    }
    let ws = c.newWorkspace(cwd: root.path)
    let a = ws.panes[0]
    a.cwd = root.path
    c.focus(a)
    func click(_ value: String) {
        c.openTerminalLink(value, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, pane: a, view: a.surface)
    }
    /// 同一個值：經過 openTerminalLink，與直接走原本流程（GhosttyRuntime.openTerminalURL），開啟的東西與詢問都一樣。
    func sameAsBefore(_ value: String) -> Bool {
        external.urls.removeAll(); prompts.removeAll()
        GhosttyRuntime.openTerminalURL(value, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: a.surface?.window)
        let before = (external.urls, prompts)
        external.urls.removeAll(); prompts.removeAll()
        click(value)
        return external.urls == before.0 && prompts == before.1
    }
    func real(_ u: URL) -> String { u.resolvingSymlinksInPath().path }
    func uti(_ path: String) -> String { UTType(filenameExtension: (path as NSString).pathExtension)?.identifier ?? "nil" }

    // 判斷：純文字檔跳出選單，其他照原本流程
    answer = nil
    for path in textPaths {
        asked.removeAll()
        click(path)
        r.check("⌘-click \(path)：跳出開啟選單", asked.map(real) == [real(root.appendingPathComponent(path))], "\(asked) UTType=\(uti(path))")
    }
    for path in otherPaths {
        asked.removeAll()
        r.check("⌘-click \(path)：不跳出開啟選單，照原本流程",
                sameAsBefore(root.appendingPathComponent(path).path) && asked.isEmpty, "\(asked) UTType=\(uti(path))")
    }

    // 在新 tab 預覽 shell script：原樣顯示、不執行
    answer = .preview
    click("scripts/deploy.sh")
    let p = ws.root.find(a)?.tabs.first { $0.preview?.fileURL.lastPathComponent == "deploy.sh" }
    r.check("在新 tab 預覽：開出 deploy.sh 的預覽 tab", p != nil && ws.focusedPane === p)
    r.check("預覽 tab 的標題是檔名", p?.headerTitle == "deploy.sh", p?.headerTitle ?? "nil")
    let shown = await waitPreviewJS(
        p?.preview?.webView,
        "Boolean(document.body?.innerText.includes(\"echo '<b>done</b>'\")) && document.querySelectorAll('b').length === 0"
    )
    r.check("預覽 tab 原樣顯示 shell script 的內容", shown)
    r.check("預覽 shell script 時沒有執行它", !FileManager.default.fileExists(atPath: ran.path))

    // lmux 的外觀設定 → 純文字預覽（背景與文字顏色，同 Markdown 的 preview-appearance）
    c.setAppearance(.dark)
    let dark = await waitPreviewJS(p?.preview?.webView,
        "getComputedStyle(document.documentElement).backgroundColor === 'rgb(13, 17, 23)' && getComputedStyle(document.body).color === 'rgb(230, 237, 243)'")
    r.check("lmux 切換成 Dark 時，純文字預覽跟著變深色", dark)
    c.setAppearance(.light)
    let light = await waitPreviewJS(p?.preview?.webView,
        "getComputedStyle(document.documentElement).backgroundColor === 'rgb(255, 255, 255)' && getComputedStyle(document.body).color === 'rgb(36, 41, 47)'")
    r.check("lmux 切換成 Light 時，純文字預覽跟著變淺色", light)
    c.setAppearance(.system)

    // 路徑帶行號：從檔案開頭顯示
    asked.removeAll()
    click("config/app.yaml:42")
    r.check("路徑帶行號：去掉行號後跳出開啟選單", asked.map(real) == [real(yaml)], "\(asked)")
    let py = ws.root.find(a)?.tabs.first { $0.preview?.fileURL.lastPathComponent == "app.yaml" }
    let atTop = await waitPreviewJS(
        py?.preview?.webView,
        "Boolean(document.body?.innerText.includes('line 42: value')) && window.scrollY === 0"
    )
    r.check("路徑帶行號：預覽從檔案開頭顯示", atTop)

    // 自動更新與刪除
    await sleepMs(300)
    try? ((1...80).map { "line \($0): value" } + ["debug: true"]).joined(separator: "\n").write(to: yaml, atomically: true, encoding: .utf8)
    r.check("純文字檔改寫後預覽 tab 自動更新",
            await waitPreviewJS(py?.preview?.webView, "Boolean(document.body?.innerText.includes('debug: true'))"))
    try? FileManager.default.removeItem(at: yaml)
    r.check("純文字檔被刪除後顯示「檔案已不存在」，預覽 tab 仍然留著",
            await waitPreviewJS(py?.preview?.webView, "Boolean(document.body?.innerText.includes('檔案已不存在'))")
                && ws.panes.contains { $0 === py })

    // Markdown 預覽裡連到純文字檔：不換頁、不開新 tab
    let (gws, _, gp) = previewSetup(c, dir: root, file: guide)
    _ = await waitPreviewJS(gp.preview?.webView, "Boolean(document.querySelector('h1'))")
    let gCount = gws.panes.count
    gp.preview!.noteUserClick()
    _ = try? await gp.preview!.webView.evaluateJavaScript("document.querySelector('a').click()")
    await sleepMs(500)
    r.check("Markdown 預覽點純文字檔連結：不換頁、不開新 tab",
            gp.headerTitle == "guide.md" && gws.panes.count == gCount, "\(gp.headerTitle) \(gws.panes.count)")
    c.closeWorkspace(gws)

    // 用預設 app 開 shell script（.sh、.command）：被既有的 script 規則擋下，和不經選單時一樣
    answer = .defaultApp
    c.focus(a)
    for path in ["scripts/deploy.sh", "scripts/run.command"] {
        let abs = root.appendingPathComponent(path).path
        external.urls.removeAll(); prompts.removeAll()
        GhosttyRuntime.openTerminalURL(abs, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: a.surface?.window)
        let direct = prompts
        let tabCount = ws.panes.count
        external.urls.removeAll(); prompts.removeAll()
        click(path)
        var unsafe = false
        if case .block(reason: .unsafeFile, display: _)? = prompts.first { unsafe = true }
        r.check("\(path) 選「用預設 app 開」：以 script 規則擋下，和不經選單時相同，沒有交給系統開啟",
                unsafe && prompts == direct && external.urls.isEmpty, "\(prompts) direct=\(direct) \(external.urls)")
        r.check("\(path) 選「用預設 app 開」：沒有開出預覽 tab", ws.panes.count == tabCount, "\(ws.panes.count)")
    }
    r.check("shell script 沒有被執行", !FileManager.default.fileExists(atPath: ran.path))
    c.closeWorkspace(ws)
}
