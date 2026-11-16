// 預覽 tab 在真的 WKWebView 裡的自我檢查（scheme、資料夾監看、導覽規則）。不需要 libghostty，
// 不顯示任何視窗（視窗放在螢幕外），單獨編譯執行：
//   swiftc -parse-as-library -o /tmp/preview-webkit-check \
//     App/Sources/LmuxUI/{PreviewTarget,MarkdownHTML,PreviewScheme,PreviewWatcher,PreviewView,PreviewViewNavigation}.swift \
//     App/scripts/preview-webkit-check*.swift && /tmp/preview-webkit-check
// （或直接執行 beat/changes/archive/2026-11-16-md-html-preview/dev.sh webkit）
// 每一項印 PASS 或 FAIL；最後一行是 `WEBKIT CHECK: ok` 或 `WEBKIT CHECK: FAILED (n)`。

import AppKit
import Darwin
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

    @MainActor static func waitJS(_ web: WKWebView, _ code: String, _ seconds: Double = 6,
                                  where pred: (Any?) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if pred(await js(web, code)) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @MainActor static func waitBody(_ web: WKWebView, contains: String, also: String? = nil, excluding: String? = nil) async -> Bool {
        await waitJS(web, "document.body && document.body.innerText") { val in
            guard let s = val as? String, s.contains(contains) else { return false }
            if let also, !s.contains(also) { return false }
            return excluding.map { !s.contains($0) } ?? true
        }
    }

    @MainActor static func pumpEvents(_ events: [NSEvent]) {
        for ev in events { NSApp.postEvent(ev, atStart: false) }
        while let ev = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
            NSApp.sendEvent(ev)
        }
    }

    @MainActor static func sendMouseDrag(from: NSPoint, to: NSPoint, in targetWin: NSWindow) {
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: from, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: targetWin.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: to, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: targetWin.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        )!
        pumpEvents([down, up])
    }

    /// 測試用的資料夾：docs/a.md（圖片、連結）、docs/b.md、docs/img/flow.png、
    /// site/index.html（CSS、圖片、script、連到 c.md 與外部網址）、site/c.md、site/secret.txt。
    static func makeFixtures() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-webkit-check-\(getpid())")
        let docs = root.appendingPathComponent("docs"), site = root.appendingPathComponent("site")
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("img"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
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
        <html><head><link rel="stylesheet" href="style.css"></head><body><h1>SiteHome</h1><img src="logo.png">
        <a id="md" href="c.md">c</a><a id="web" href="https://example.com/x">web</a><a id="sub" href="sub/child.html">sub</a>
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
            await viewChecks(root)
            await securityChecks(root)
            await regressionChecks(root)
            await boundaryChecks(root)
            await textSchemeChecks(root)
            await textViewChecks(root)
            try? FileManager.default.removeItem(at: root)
            print(failures == 0 ? "WEBKIT CHECK: ok" : "WEBKIT CHECK: FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        // 預覽檢查變多（含純文字檔），整體時限放寬到 240 秒；失敗時每項最多等 6 秒，120 秒會在印出 FAIL 前就逾時。
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { print("WEBKIT CHECK: FAILED (timeout)"); exit(2) }
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

    final class MockSchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var receivedResponse = false
        var receivedData = Data()
        var finished = false
        var failedError: Error?
        init(request: URLRequest) { self.request = request }
        func didReceive(_ response: URLResponse) { receivedResponse = true }
        func didReceive(_ data: Data) { receivedData.append(data) }
        func didFinish() { finished = true }
        func didFailWithError(_ error: Error) { failedError = error }
    }

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

        let docs = root.appendingPathComponent("docs")
        let svg = docs.appendingPathComponent("img/vector.svg")
        let txt = docs.appendingPathComponent("img/plain.txt")
        let zeroPng = docs.appendingPathComponent("img/zero.png")
        let hugePng = docs.appendingPathComponent("img/huge.png")
        try? "<svg xmlns=\"http://www.w3.org/2000/svg\"><script>window.svgRan=true</script></svg>"
            .write(to: svg, atomically: true, encoding: .utf8)
        try? "plain".write(to: txt, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: zeroPng, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        FileManager.default.createFile(atPath: hugePng.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: hugePng) {
            try? fh.truncate(atOffset: UInt64(PreviewSchemeHandler.maxBytes + 4096))
            try? fh.close()
        }
        check("scheme 拒收 SVG", PreviewSchemeHandler.response(for: svg) == nil)
        check("scheme 拒收非圖片（.txt）", PreviewSchemeHandler.response(for: txt) == nil)
        check("scheme 拒收指向 /dev/zero 的圖片 symlink", PreviewSchemeHandler.response(for: zeroPng) == nil)
        check("scheme 拒收超過上限的圖片", PreviewSchemeHandler.response(for: hugePng) == nil)
        let badImgMD = docs.appendingPathComponent("badimg.md")
        try? "# BadImg\n\n![s](img/vector.svg) ![t](img/plain.txt) ![z](img/zero.png) ![h](img/huge.png)\n"
            .write(to: badImgMD, atomically: true, encoding: .utf8)
        web.load(URLRequest(url: PreviewSchemeHandler.url(for: badImgMD)))
        check("badimg 載入", await waitH1(web, "BadImg"))
        _ = await wait { !web.isLoading }
        try? await Task.sleep(for: .milliseconds(250))
        let zeroWidths = await js(web, "Array.from(document.images).filter(i => i.complete && i.naturalWidth === 0).length")
        check("Markdown 裡的 SVG / 非圖片 / 裝置 / 超限圖片皆無法載入", (zeroWidths as? Int) == 4, "\(String(describing: zeroWidths))")

        web.load(URLRequest(url: PreviewSchemeHandler.url(for: root.appendingPathComponent("docs/missing.md"))))
        check("不存在的 Markdown 顯示「檔案已不存在」", await waitBody(web, contains: "檔案已不存在"))
    }

    // MARK: - PreviewWatcher

    // @feature: preview-tab.feature
    // @scenario: 檔案內容改變後，預覽自動更新
    // @scenario: 以「寫暫存檔再改名」方式存檔，預覽也會更新
    @MainActor static func watcherChecks(_ root: URL) async {
        let file = root.appendingPathComponent("docs/watched.md")
        try? "# 0\n".write(to: file, atomically: false, encoding: .utf8)
        var calls = 0
        let watcher = PreviewWatcher(file: file) { calls += 1 }
        defer { watcher.stop() }
        try? await Task.sleep(for: .milliseconds(300))
        var before = calls
        if let fh = try? FileHandle(forWritingTo: file) {
            fh.truncateFile(atOffset: 0)
            fh.write(Data("# 1\n".utf8))
            try? fh.close()
        }
        check("直接改寫檔案時通知", await wait { calls > before }, "calls=\(calls)")
        before = calls
        let tmp = root.appendingPathComponent("docs/.watched.md.tmp")
        try? "# 2\n".write(to: tmp, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
        check("寫暫存檔再改名蓋掉時通知", await wait { calls > before }, "calls=\(calls)")
        before = calls
        try? "# 3\n".write(to: file, atomically: true, encoding: .utf8)
        check("改名蓋掉之後再改，仍然通知", await wait { calls > before }, "calls=\(calls)")
        before = calls
        try? FileManager.default.removeItem(at: file)
        check("檔案被刪除時通知", await wait { calls > before }, "calls=\(calls)")
        try? await Task.sleep(for: .milliseconds(300))
        before = calls
        try? "x".write(to: root.appendingPathComponent("docs/other.md"), atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(800))
        check("同資料夾的其他檔案改變時不通知", calls == before, "calls=\(calls) before=\(before)")

        // S2: 大小寫不敏感磁碟上，以不同大小寫路徑監看仍能收到變更通知
        let docsDir = root.appendingPathComponent("docs")
        let caseSensitive = (try? docsDir.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
        if !caseSensitive {
            let realCaseFile = docsDir.appendingPathComponent("CaseWatch.md")
            let wrongCaseFile = docsDir.appendingPathComponent("casewatch.md")
            try? "# Case0\n".write(to: realCaseFile, atomically: true, encoding: .utf8)
            var caseCalls = 0
            let caseWatcher = PreviewWatcher(file: wrongCaseFile) { caseCalls += 1 }
            defer { caseWatcher.stop() }
            try? await Task.sleep(for: .milliseconds(300))
            let beforeCase = caseCalls
            try? "# Case1\n".write(to: realCaseFile, atomically: true, encoding: .utf8)
            check("S2: 路徑大小寫與磁碟不同時 watcher 仍能通知", await wait { caseCalls > beforeCase }, "calls=\(caseCalls) before=\(beforeCase)")
        } else {
            print("SKIP  S2: 這個磁碟區分大小寫，「路徑大小寫與磁碟不同」的 watcher 檢查不適用")
        }
    }

    /// 本機 loopback 測試伺服器：回傳一個會設 `window.remoteRan = true` 的 script。
    static func startLocalServer() -> (port: UInt16, stop: () -> Void) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        _ = Darwin.listen(fd, 8)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        DispatchQueue.global().async {
            let body = Data("window.remoteRan = true;\n".utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/javascript; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            let payload = Data(head.utf8) + body
            while true {
                let c = Darwin.accept(fd, nil, nil)
                if c < 0 { break }
                var buf = [UInt8](repeating: 0, count: 1024)
                _ = Darwin.read(c, &buf, buf.count)
                payload.withUnsafeBytes { p in
                    if let base = p.baseAddress { _ = Darwin.write(c, base, payload.count) }
                }
                Darwin.close(c)
            }
        }
        return (port, { Darwin.close(fd) })
    }
}
