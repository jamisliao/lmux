import AppKit
import WebKit

extension PreviewWebKitCheck {
    // MARK: - PreviewView

    // @feature: preview-tab.feature
    // @scenario: Markdown 顯示成排版後的樣子
    // @scenario: Markdown 裡的 HTML 標籤顯示成文字，不執行
    // @scenario: HTML 讀得到同資料夾的 CSS 與圖片
    // @scenario: HTML 從網路載入的 script 正常執行
    // @scenario: 重新開啟預覽時，不保留上一次的 cookie 與 storage
    // @scenario: 點相對路徑的 .md 連結，在同一個預覽 tab 換頁
    // @scenario: 在預覽裡用觸控板兩指往右滑，回到上一頁
    // @scenario: 點網址連結，照終端機裡點連結的規則處理
    // @scenario: 檔案內容改變後，預覽自動更新
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
        check("啟用雙指滑動返回上一頁手勢", v.webView.allowsBackForwardNavigationGestures)
        let h1ID = await js(v.webView, "document.querySelector('h1')?.id") as? String
        check("S8: Markdown 標題產生可用於錨點的 id", h1ID == "a-文件", h1ID ?? "nil")
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
        let countAfterFirstClick = external.count
        _ = await js(v.webView, "document.getElementById('web').click()")
        try? await Task.sleep(for: .milliseconds(300))
        check("consumeUserClick() 用完即清空：同一輪不能再開第二次外部網址", external.count == countAfterFirstClick, "\(external)")
        v.noteUserClick()
        try? await Task.sleep(for: .milliseconds(1100))
        _ = await js(v.webView, "document.getElementById('web').click()")
        try? await Task.sleep(for: .milliseconds(300))
        check("consumeUserClick() 超過 1 秒後失效", external.count == countAfterFirstClick, "\(external)")

        // HTML 連到同資料夾的 Markdown：改走 scheme
        _ = await js(v.webView, "document.getElementById('md').click()")
        check("HTML 連到的 Markdown 經 scheme 顯示", await waitH1(v.webView, "C 文件"))
        check("HTML 連到的 Markdown 用 lmux-preview scheme", v.webView.url?.scheme == PreviewSchemeHandler.scheme, v.webView.url?.absoluteString ?? "nil")

        // Markdown 連到 .html（切去 loadFileURL 並執行 JS）、連到非預覽檔（.txt 被取消）、缺失 .html（追蹤 fileURL 與監看）、HTML 攔截 data:/about:srcdoc/customscheme:
        let docsDir = root.appendingPathComponent("docs")
        let subHTML = docsDir.appendingPathComponent("sub.html")
        let noteTXT = docsDir.appendingPathComponent("note.txt")
        let missingHTML = docsDir.appendingPathComponent("missing.html")
        let navMD = docsDir.appendingPathComponent("nav.md")
        try? "<html><body><h1>SubHTML</h1><a id=\"custom\" href=\"customscheme://foo\">c</a><script>window.subRan = true;</script></body></html>"
            .write(to: subHTML, atomically: true, encoding: .utf8)
        try? "note".write(to: noteTXT, atomically: true, encoding: .utf8)
        try? "# Nav\n\n[sub](sub.html) [txt](note.txt) [gone](missing.html)\n".write(to: navMD, atomically: true, encoding: .utf8)
        v.show(navMD)
        check("開啟 nav.md", await waitH1(v.webView, "Nav"))
        _ = await js(v.webView, "document.querySelector('a[href=\"note.txt\"]').click()")
        try? await Task.sleep(for: .milliseconds(400))
        check("Markdown 點非預覽檔（.txt）取消導覽",
              v.webView.url?.lastPathComponent == "nav.md" && v.fileURL.lastPathComponent == "nav.md",
              "\(v.webView.url?.absoluteString ?? "nil") \(v.fileURL)")
        _ = await js(v.webView, "document.querySelector('a[href=\"sub.html\"]').click()")
        let subURLOK = await wait { v.webView.url?.scheme == "file" && v.webView.url?.lastPathComponent == "sub.html" && !v.webView.isLoading }
        let subH1OK = await waitH1(v.webView, "SubHTML")
        let subRanOK = await js(v.webView, "window.subRan === true") as? Bool == true
        check("Markdown 點 .html 轉成 file:// 載入並執行 JS", subURLOK && subH1OK && subRanOK)
        let extBefore = external.count
        _ = await js(v.webView, "location.href = 'data:text/html,<h1>hijack</h1>'")
        _ = await js(v.webView, "location.href = 'about:srcdoc'")
        _ = await js(v.webView, "document.getElementById('custom').click()")
        try? await Task.sleep(for: .milliseconds(400))
        check("HTML 主框架不能導覽到 data:、about:srcdoc 或 custom scheme",
              v.webView.url?.lastPathComponent == "sub.html" && external.count == extBefore,
              "\(v.webView.url?.absoluteString ?? "nil")")

        v.show(navMD)
        _ = await waitH1(v.webView, "Nav")
        _ = await js(v.webView, "document.querySelector('a[href=\"missing.html\"]').click()")
        let missingHtmlPage = await waitBody(v.webView, contains: "檔案已不存在", also: missingHTML.path)
        check("Markdown 點不存在的 .html 顯示「檔案已不存在」且更新追蹤為 missing.html",
              missingHtmlPage && v.fileURL.standardizedFileURL == missingHTML.standardizedFileURL && changes.last == "missing.html",
              "\(v.fileURL) \(changes)")
        try? await Task.sleep(for: .milliseconds(300))
        try? "# Nav Changed\n".write(to: navMD, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(700))
        let stillMissing = (await js(v.webView, "document.body && document.body.innerText") as? String ?? "").contains("檔案已不存在")
        check("切換到缺失 HTML 後，舊的 nav.md 變更不會覆寫錯頁", stillMissing)
        try? "<html><body><h1>Recovered HTML</h1></body></html>".write(to: missingHTML, atomically: true, encoding: .utf8)
        check("缺失 HTML 建立後自動重載顯示內容", await waitH1(v.webView, "Recovered HTML"))

        await storageAndReloadChecks(root, v: v, index: index)
    }

    @MainActor static func storageAndReloadChecks(_ root: URL, v: PreviewView, index: URL) async {
        // 另一個 PreviewView 不共享 cookie 與 storage
        let testCookie = HTTPCookie(properties: [
            .domain: "example.com",
            .path: "/",
            .name: "lmux_session",
            .value: "secret",
        ])!
        await v.webView.configuration.websiteDataStore.httpCookieStore.setCookie(testCookie)
        let v1Cookies = await v.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        _ = await js(v.webView, "sessionStorage.setItem('sk', 'sv')")
        let v2 = PreviewView(fileURL: index)
        let win2 = host(v2)
        _ = await wait { v2.webView.url?.lastPathComponent == "index.html" && !v2.webView.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let prev2 = await js(v2.webView, "window.prev")
        let s2 = await js(v2.webView, "sessionStorage.getItem('sk')")
        let v2Cookies = await v2.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        // S23: 關閉預覽 tab 之後再開同一個 HTML，也不得保留 localStorage / cookie
        _ = await js(v2.webView, "localStorage.setItem('k', 'after-close'); localStorage.setItem('afterCloseKey', 'after-close')")
        await v2.webView.configuration.websiteDataStore.httpCookieStore.setCookie(testCookie)
        v2.close()
        win2.close()
        let v3 = PreviewView(fileURL: index)
        let win3 = host(v3)
        defer { v3.close(); win3.close() }
        _ = await wait { v3.webView.url?.lastPathComponent == "index.html" && !v3.webView.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let prev3Window = await js(v3.webView, "window.prev")
        let prev3Other = await js(v3.webView, "localStorage.getItem('afterCloseKey')")
        let v3Cookies = await v3.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        check("預覽使用非持久性 data store", !v.webView.configuration.websiteDataStore.isPersistent)
        check("新的預覽讀不到上一個預覽存的 localStorage / sessionStorage",
              (prev2 == nil || prev2 is NSNull) && (s2 == nil || s2 is NSNull), "\(String(describing: prev2)) \(String(describing: s2))")
        check("關閉預覽後重開同一個 HTML，仍讀不到上一次的 localStorage 與 cookie",
              (prev3Window == nil || prev3Window is NSNull) && (prev3Other == nil || prev3Other is NSNull) && v3Cookies.isEmpty,
              "prev3Window=\(String(describing: prev3Window)) prev3Other=\(String(describing: prev3Other)) cookies=\(v3Cookies.count)")
        check("新的預覽讀不到上一個預覽存的 cookie",
              v1Cookies.contains { $0.name == "lmux_session" } && v2Cookies.isEmpty,
              "v1=\(v1Cookies.count) v2=\(v2Cookies.count)")

        // HTML 載入外部（http://127.0.0.1）script 正常執行
        let srv = startLocalServer()
        defer { srv.stop() }
        let remoteHTML = root.appendingPathComponent("site/remote.html")
        try? "<html><head><script src=\"http://127.0.0.1:\(srv.port)/lib.js\"></script></head><body>ok</body></html>"
            .write(to: remoteHTML, atomically: true, encoding: .utf8)
        v.show(remoteHTML)
        _ = await wait { v.webView.url?.lastPathComponent == "remote.html" && !v.webView.isLoading }
        let remoteRan = await waitJS(v.webView, "window.remoteRan === true") { ($0 as? Bool) == true }
        check("HTML 從網路載入的 script 正常執行", remoteRan)

        // 超過 2 MB 的 Markdown 不會卡死，顯示超過大小提示
        let huge = root.appendingPathComponent("docs/huge.md")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: huge) {
            try? fh.truncate(atOffset: UInt64(PreviewSchemeHandler.maxMarkdownBytes + 4096))
            try? fh.close()
        }
        v.show(huge)
        check("超過 2 MB 的 Markdown 顯示大小上限提示", await waitBody(v.webView, contains: "檔案太大，無法預覽"))

        // 自動更新與刪除
        let w = root.appendingPathComponent("docs/live.md")
        try? "# 版本一\n".write(to: w, atomically: true, encoding: .utf8)
        v.show(w)
        check("開啟 live.md", await waitH1(v.webView, "版本一"))
        try? await Task.sleep(for: .milliseconds(300))
        try? "# 版本二\n".write(to: w, atomically: true, encoding: .utf8)
        check("檔案改寫後自動顯示新內容", await waitH1(v.webView, "版本二"))
        try? FileManager.default.removeItem(at: w)
        check("檔案被刪除後顯示「檔案已不存在」與完整路徑",
              await waitBody(v.webView, contains: "檔案已不存在", also: w.path))
        try? "# 版本三\n".write(to: w, atomically: true, encoding: .utf8)
        check("檔案重新出現後，預覽恢復顯示檔案", await waitH1(v.webView, "版本三"))

        // HTML 檔的自動更新、刪除與重建復原
        let liveHTML = root.appendingPathComponent("site/live.html")
        try? "<html><body><h1>HTML1</h1></body></html>".write(to: liveHTML, atomically: true, encoding: .utf8)
        v.show(liveHTML)
        check("開啟 live.html", await waitH1(v.webView, "HTML1"))
        try? await Task.sleep(for: .milliseconds(300))
        try? "<html><body><h1>HTML2</h1></body></html>".write(to: liveHTML, atomically: true, encoding: .utf8)
        check("HTML 改寫後自動顯示新內容", await waitH1(v.webView, "HTML2"))
        try? FileManager.default.removeItem(at: liveHTML)
        check("HTML 被刪除後顯示「檔案已不存在」與完整路徑",
              await waitBody(v.webView, contains: "檔案已不存在", also: liveHTML.path))
        try? "<html><body><h1>HTML3</h1></body></html>".write(to: liveHTML, atomically: true, encoding: .utf8)
        check("HTML 重建後恢復顯示內容", await waitH1(v.webView, "HTML3"))

        // 關閉：不再監看檔案
        v.close()
        check("close() 之後是關閉狀態", v.isClosed)
        try? "# 版本四\n".write(to: w, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(1200))
        let after = await js(v.webView, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String
        check("close() 之後檔案改變不再重新載入", after != "版本四", after ?? "nil")
    }
}
