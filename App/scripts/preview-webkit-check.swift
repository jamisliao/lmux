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
            await viewChecks(root)
            await securityChecks(root)
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

    // MARK: - PreviewView

    // @feature: preview-tab.feature
    // @scenario: Markdown 顯示成排版後的樣子
    // @scenario: Markdown 裡的 HTML 標籤顯示成文字，不執行
    // @scenario: HTML 讀得到同資料夾的 CSS 與圖片
    // @scenario: 重新開啟預覽時，不保留上一次的 cookie 與 storage
    // @scenario: 點相對路徑的 .md 連結，在同一個預覽 tab 換頁
    // @scenario: 點網址連結，照終端機裡點連結的規則處理
    // @scenario: 預覽中的檔案被刪除
    @MainActor static func viewChecks(_ root: URL) async {
        let a = root.appendingPathComponent("docs/a.md")
        var changes: [String] = []
        var external: [URL] = []
        let v = PreviewView(fileURL: a)
        v.onFileChange = { changes.append($0.lastPathComponent) }
        v.openExternal = { external.append($0) }
        let win = host(v)
        defer { win.close() }

        // Markdown
        check("Markdown 頁面顯示出來", await waitH1(v.webView, "A 文件"))
        check("Markdown 頁面走 lmux-preview scheme", v.webView.url?.scheme == PreviewSchemeHandler.scheme, v.webView.url?.absoluteString ?? "nil")
        check("Markdown 裡的 <script> 沒有執行", v.webView.title != "pwned", v.webView.title ?? "nil")
        check("開啟時通知檔案（a.md）", changes.last == "a.md", "\(changes)")

        // Markdown 頁面的 script 不會執行：插入一個帶 onerror 的圖片，onerror 不應該跑
        _ = await js(v.webView, "document.body.insertAdjacentHTML('beforeend', '<img src=\"nope.png\" onerror=\"document.title=\\'jsran\\'\">')")
        try? await Task.sleep(for: .milliseconds(500))
        check("Markdown 頁面裡的 script（onerror）不會執行", v.webView.title != "jsran", v.webView.title ?? "nil")

        // 換頁與返回：真的點頁面上的 b.md 連結
        _ = await js(v.webView, "document.querySelector('a').click()")
        check("點 b.md 連結後換到 b.md", await waitH1(v.webView, "B 文件"))
        check("換頁後 fileURL 與通知是 b.md", v.fileURL.lastPathComponent == "b.md" && changes.last == "b.md", "\(v.fileURL) \(changes)")
        v.webView.goBack()
        check("返回上一頁回到 a.md", await waitH1(v.webView, "A 文件"))
        check("返回後 fileURL 與通知是 a.md", v.fileURL.lastPathComponent == "a.md" && changes.last == "a.md", "\(v.fileURL) \(changes)")

        // HTML
        let index = root.appendingPathComponent("site/index.html")
        v.show(index)
        _ = await wait { v.webView.url?.lastPathComponent == "index.html" && !v.webView.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let bg = await js(v.webView, "getComputedStyle(document.body).backgroundColor")
        check("HTML 套用同資料夾的 CSS", (bg as? String) == "rgb(1, 2, 3)", "\(String(describing: bg))")
        let logo = await js(v.webView, "document.images[0].complete && document.images[0].naturalWidth")
        check("HTML 顯示同資料夾的圖片", (logo as? Int) == 1, "\(String(describing: logo))")
        let ran = await js(v.webView, "window.ran === true")
        check("HTML 的 script 有執行", (ran as? Bool) == true, "\(String(describing: ran))")
        let prev = await js(v.webView, "window.prev")
        check("第一次開啟時 storage 是空的", prev == nil || prev is NSNull, "\(String(describing: prev))")
        let fetched = try? await v.webView.callAsyncJavaScript(
            "try { const r = await fetch('secret.txt'); return await r.text() } catch (e) { return 'blocked' }",
            contentWorld: .page)
        check("HTML 的 script 讀不到同資料夾的其他檔案", (fetched as? String) == "blocked", "\(String(describing: fetched))")

        // 頁面的 script 自己點外部連結（使用者沒有點）：不開
        _ = await js(v.webView, "document.getElementById('web').click()")
        try? await Task.sleep(for: .milliseconds(500))
        check("script 自己點 https 連結時不開任何東西", external.isEmpty, "\(external)")
        // 使用者點了外部連結：交給 openExternal，頁面不變
        v.noteUserClick()
        _ = await js(v.webView, "document.getElementById('web').click()")
        check("使用者點 https 連結交給 openExternal", await wait { external.last?.absoluteString == "https://example.com/x" }, "\(external)")
        try? await Task.sleep(for: .milliseconds(300))
        check("點 https 連結後頁面不變", v.webView.url?.lastPathComponent == "index.html", v.webView.url?.absoluteString ?? "nil")

        // HTML 連到同資料夾的 Markdown：改走 scheme
        _ = await js(v.webView, "document.getElementById('md').click()")
        check("HTML 連到的 Markdown 經 scheme 顯示", await waitH1(v.webView, "C 文件"))
        check("HTML 連到的 Markdown 用 lmux-preview scheme", v.webView.url?.scheme == PreviewSchemeHandler.scheme, v.webView.url?.absoluteString ?? "nil")

        // 另一個 PreviewView 不共享 storage
        let v2 = PreviewView(fileURL: index)
        let win2 = host(v2)
        defer { win2.close() }
        _ = await wait { v2.webView.url?.lastPathComponent == "index.html" && !v2.webView.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let prev2 = await js(v2.webView, "window.prev")
        check("新的預覽讀不到上一個預覽存的 storage", prev2 == nil || prev2 is NSNull, "\(String(describing: prev2))")

        // 自動更新與刪除
        let w = root.appendingPathComponent("docs/live.md")
        try? "# 版本一\n".write(to: w, atomically: true, encoding: .utf8)
        v.show(w)
        check("開啟 live.md", await waitH1(v.webView, "版本一"))
        try? await Task.sleep(for: .milliseconds(300))
        try? "# 版本二\n".write(to: w, atomically: true, encoding: .utf8)
        check("檔案改寫後自動顯示新內容", await waitH1(v.webView, "版本二"))
        try? FileManager.default.removeItem(at: w)
        var gone = false
        for _ in 0..<60 {
            if let s = await js(v.webView, "document.body && document.body.innerText") as? String,
               s.contains("檔案已不存在"), s.contains(w.path) { gone = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("檔案被刪除後顯示「檔案已不存在」與完整路徑", gone)
        try? "# 版本三\n".write(to: w, atomically: true, encoding: .utf8)
        check("檔案重新出現後，預覽恢復顯示檔案", await waitH1(v.webView, "版本三"))

        // 關閉：不再監看檔案
        v.close()
        check("close() 之後是關閉狀態", v.isClosed)
        try? "# 版本四\n".write(to: w, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(1200))
        let after = await js(v.webView, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String
        check("close() 之後檔案改變不再重新載入", after != "版本四", after ?? "nil")
    }

    // MARK: - 安全

    // @feature: preview-tab.feature
    // @scenario: Markdown 裡的 HTML 標籤顯示成文字，不執行
    // @scenario: 點網址連結，照終端機裡點連結的規則處理
    @MainActor static func securityChecks(_ root: URL) async {
        let site = root.appendingPathComponent("site"), docs = root.appendingPathComponent("docs")
        let other = root.appendingPathComponent("other")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let secret = other.appendingPathComponent("secret.txt")
        try? "TOP-SECRET".write(to: secret, atomically: true, encoding: .utf8)
        let flow = docs.appendingPathComponent("img/flow.png").path
        // 惡意 HTML：用 iframe 嵌入 lmux-preview、直接 fetch lmux-preview、用 <img> 載入 lmux-preview
        try? """
        <html><body><img id="probe" src="lmux-preview://\(flow)"><script>
        window.leak = 'none'; window.direct = 'none';
        if (location.protocol === 'file:') {
          window.addEventListener('message', e => { window.leak = String(e.data); });
          const f = document.createElement('iframe'); f.src = 'lmux-preview://' + location.pathname; document.body.append(f);
          fetch('lmux-preview://\(secret.path)').then(r => r.text()).then(t => { window.direct = t }).catch(e => { window.direct = 'blocked' });
        } else {
          fetch('lmux-preview://\(secret.path)').then(r => r.text()).then(t => parent.postMessage(t, '*')).catch(e => parent.postMessage('blocked', '*'));
        }
        </script></body></html>
        """.write(to: site.appendingPathComponent("evil.html"), atomically: true, encoding: .utf8)
        try? "<html><head><meta http-equiv=\"refresh\" content=\"0;url=https://example.com/phish\"></head><body>r</body></html>"
            .write(to: site.appendingPathComponent("refresh.html"), atomically: true, encoding: .utf8)
        try? "# Zero\n\n![z](/dev/zero)\n".write(to: docs.appendingPathComponent("zero.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("link.md"),
                                                    withDestinationURL: URL(fileURLWithPath: "/dev/zero"))

        var external: [URL] = []
        let v = PreviewView(fileURL: site.appendingPathComponent("evil.html"))
        v.openExternal = { external.append($0) }
        let win = host(v)
        defer { win.close() }
        _ = await wait { v.webView.url?.lastPathComponent == "evil.html" && !v.webView.isLoading }
        try? await Task.sleep(for: .seconds(2))
        let leak = await js(v.webView, "window.leak") as? String ?? "nil"
        check("HTML 頁面用 iframe 讀不到其他資料夾的檔案", !leak.contains("TOP-SECRET"), leak)
        let direct = await js(v.webView, "window.direct") as? String ?? "nil"
        check("HTML 頁面直接 fetch lmux-preview 讀不到檔案", direct == "blocked", direct)
        let probe = await js(v.webView, "document.getElementById('probe').naturalWidth")
        check("HTML 頁面用 <img> 載入 lmux-preview 會失敗", (probe as? Int) == 0, "\(String(describing: probe))")

        v.show(site.appendingPathComponent("refresh.html"))
        _ = await wait { v.webView.url?.lastPathComponent == "refresh.html" && !v.webView.isLoading }
        try? await Task.sleep(for: .milliseconds(1500))
        check("meta refresh 不會把預覽換成網頁", v.webView.url?.lastPathComponent == "refresh.html" && external.isEmpty,
              "\(v.webView.url?.absoluteString ?? "nil") \(external)")

        v.show(docs.appendingPathComponent("zero.md"))
        check("Markdown 引用 /dev/zero 不會卡住", await waitH1(v.webView, "Zero"))
        v.show(docs.appendingPathComponent("link.md"))
        var linkMissing = false
        for _ in 0..<60 {
            if let s = await js(v.webView, "document.body && document.body.innerText") as? String, s.contains("檔案已不存在") { linkMissing = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("指向 /dev/zero 的 .md symlink 不讀，顯示「檔案已不存在」", linkMissing)
    }
}
