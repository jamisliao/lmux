// 預覽 tab 在真的 WKWebView 裡的自我檢查（scheme、資料夾監看、導覽規則）。不需要 libghostty，
// 不顯示任何視窗（視窗放在螢幕外），單獨編譯執行：
//   beat/changes/md-html-preview/dev.sh webkit
// 每一項印 PASS 或 FAIL；最後一行是 `WEBKIT CHECK: ok` 或 `WEBKIT CHECK: FAILED (n)`。

import AppKit
import WebKit

@main
enum PreviewWebKitCheck {
    @MainActor static var failures = 0

    @MainActor static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  -- \(detail)")")
    }

    /// 最多等 `seconds` 秒，直到 `cond` 成立。
    @MainActor static func wait(_ seconds: Double = 5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    /// 在頁面裡執行 JavaScript，回傳結果（失敗回傳 nil）。
    @MainActor static func js(_ web: WKWebView, _ code: String) async -> Any? {
        try? await web.evaluateJavaScript(code)
    }

    /// 最多等 `seconds` 秒，直到頁面第一個 `<h1>` 的文字是 `text`。
    @MainActor static func waitH1(_ web: WKWebView, _ text: String, _ seconds: Double = 6) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let s = await js(web, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String,
               s == text { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// 測試用的資料夾：docs/a.md（圖片、連結）、docs/b.md、docs/img/flow.png、
    /// site/index.html（CSS、圖片、script、連到 c.md 與外部網址）、site/c.md、site/secret.txt。
    static func makeFixtures() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-webkit-check-\(getpid())")
        let docs = root.appendingPathComponent("docs"), site = root.appendingPathComponent("site")
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("img"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        // 1x1 的 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try? png.write(to: docs.appendingPathComponent("img/flow.png"))
        try? png.write(to: site.appendingPathComponent("logo.png"))
        try? "# A 文件\n\n![流程](img/flow.png)\n\n[下一篇](b.md)\n\n<script>document.title='pwned'</script>\n"
            .write(to: docs.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try? "# B 文件\n".write(to: docs.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try? "# C 文件\n".write(to: site.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        try? "body{background:rgb(1, 2, 3)}".write(to: site.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try? "secret".write(to: site.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try? """
        <html><head><link rel="stylesheet" href="style.css"></head><body><img src="logo.png">
        <a id="md" href="c.md">c</a><a id="web" href="https://example.com/x">web</a>
        <script>window.ran = true; window.prev = localStorage.getItem('k'); localStorage.setItem('k', 'v');</script>
        </body></html>
        """.write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return root
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let root = makeFixtures()
            await schemeChecks(root)
            await watcherChecks(root)
            try? FileManager.default.removeItem(at: root)
            print(failures == 0 ? "WEBKIT CHECK: ok" : "WEBKIT CHECK: FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("WEBKIT CHECK: FAILED (timeout)"); exit(2) }
        app.run()
    }

    /// 一個放在螢幕外、不會顯示的視窗，裡面放 `view`。
    @MainActor static func host(_ view: NSView) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 700),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false  // close() 不釋放，交給 ARC（否則會釋放兩次而當掉）
        view.frame = win.contentView!.bounds
        win.contentView!.addSubview(view)
        return win
    }

    // MARK: - PreviewSchemeHandler

    // @feature: preview-tab.feature
    // @scenario: Markdown 用相對路徑引用的圖片顯示出來
    @MainActor static func schemeChecks(_ root: URL) async {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: PreviewSchemeHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        let win = host(web)
        defer { win.close() }
        let a = root.appendingPathComponent("docs/a.md")
        let url = PreviewSchemeHandler.url(for: a)
        check("scheme 網址是 lmux-preview:///<路徑>", url.absoluteString == "lmux-preview://" + a.path, url.absoluteString)
        check("scheme 網址換回檔案", PreviewSchemeHandler.file(for: url)?.path == a.path)
        web.load(URLRequest(url: url))
        check("Markdown 經 scheme 轉成 HTML", await waitH1(web, "A 文件"))
        let img = await js(web, "(function(){var i=document.images[0]; return i ? (i.complete && i.naturalWidth) : -1})()")
        check("相對路徑的圖片載入成功", (img as? Int) == 1, "\(String(describing: img))")
        let href = await js(web, "document.querySelector('a').href")
        check("相對連結解析成同一個 scheme",
              (href as? String) == PreviewSchemeHandler.url(for: root.appendingPathComponent("docs/b.md")).absoluteString,
              "\(String(describing: href))")
        web.load(URLRequest(url: PreviewSchemeHandler.url(for: root.appendingPathComponent("docs/missing.md"))))
        var missing = false
        for _ in 0..<60 {
            if let s = await js(web, "document.body && document.body.innerText") as? String, s.contains("檔案已不存在") { missing = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("不存在的 Markdown 顯示「檔案已不存在」", missing)
    }

    // MARK: - PreviewWatcher

    // @feature: preview-tab.feature
    // @scenario: 檔案內容改變後，預覽自動更新
    // @scenario: 以「寫暫存檔再改名」方式存檔，預覽也會更新
    // @scenario: 預覽中的檔案被刪除
    @MainActor static func watcherChecks(_ root: URL) async {
        let file = root.appendingPathComponent("docs/watched.md")
        try? "# 0\n".write(to: file, atomically: false, encoding: .utf8)
        var calls = 0
        let watcher = PreviewWatcher(file: file) { calls += 1 }
        defer { watcher.stop() }
        try? await Task.sleep(for: .milliseconds(300))
        // 直接改寫（不換檔）
        var before = calls
        if let fh = try? FileHandle(forWritingTo: file) {
            fh.truncateFile(atOffset: 0)
            fh.write(Data("# 1\n".utf8))
            try? fh.close()
        }
        check("直接改寫檔案時通知", await wait { calls > before }, "calls=\(calls)")
        // 寫暫存檔再改名蓋掉（replaceItemAt）
        before = calls
        let tmp = root.appendingPathComponent("docs/.watched.md.tmp")
        try? "# 2\n".write(to: tmp, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
        check("寫暫存檔再改名蓋掉時通知", await wait { calls > before }, "calls=\(calls)")
        // Foundation 的 atomically 寫入（同樣是暫存檔再改名），第二次也要收到
        before = calls
        try? "# 3\n".write(to: file, atomically: true, encoding: .utf8)
        check("改名蓋掉之後再改，仍然通知", await wait { calls > before }, "calls=\(calls)")
        // 刪除
        before = calls
        try? FileManager.default.removeItem(at: file)
        check("檔案被刪除時通知", await wait { calls > before }, "calls=\(calls)")
        // 同資料夾的其他檔案改變：不通知
        try? await Task.sleep(for: .milliseconds(300))
        before = calls
        try? "x".write(to: root.appendingPathComponent("docs/other.md"), atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(800))
        check("同資料夾的其他檔案改變時不通知", calls == before, "calls=\(calls) before=\(before)")
    }
}
