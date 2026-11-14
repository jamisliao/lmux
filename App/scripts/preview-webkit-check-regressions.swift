import AppKit
import WebKit

extension PreviewWebKitCheck {
    // MARK: - 點擊監看與跨情境回歸驗證

    @MainActor static func regressionChecks(_ root: URL) async {
        let docs = root.appendingPathComponent("docs"), site = root.appendingPathComponent("site")
        var external: [URL] = []
        let clickHTML = site.appendingPathComponent("clicktest.html")
        try? """
        <html><body style="margin:0"><a id="ext" href="https://example.com/click"
          style="position:fixed;left:0;top:0;width:100vw;height:100vh;display:block">go</a></body></html>
        """.write(to: clickHTML, atomically: true, encoding: .utf8)
        let v = PreviewView(fileURL: clickHTML)
        v.openExternal = { external.append($0) }
        let win = host(v)
        defer { v.close(); win.close() }
        check("clicktest.html 載入", await wait { v.webView.url?.lastPathComponent == "clicktest.html" && !v.webView.isLoading })

        external.removeAll()
        sendMouseDrag(from: NSPoint(x: 450, y: 350), to: NSPoint(x: 452, y: 351), in: win)
        _ = await js(v.webView, "document.getElementById('ext').click(); true")
        check("clickMonitor：未遮擋且無拖曳的真實點擊觸發 openExternal",
              await wait { external == [URL(string: "https://example.com/click")!] }, "\(external)")

        external.removeAll()
        let blocker = NSView(frame: win.contentView!.bounds)
        win.contentView!.addSubview(blocker)
        sendMouseDrag(from: NSPoint(x: 450, y: 350), to: NSPoint(x: 450, y: 350), in: win)
        _ = await js(v.webView, "document.getElementById('ext').click(); true")
        try? await Task.sleep(for: .milliseconds(200))
        check("clickMonitor：點擊被上方遮罩攔截時不觸發 openExternal", external.isEmpty, "\(external)")
        blocker.removeFromSuperview()

        external.removeAll()
        sendMouseDrag(from: NSPoint(x: 450, y: 350), to: NSPoint(x: 470, y: 350), in: win)
        _ = await js(v.webView, "document.getElementById('ext').click(); true")
        try? await Task.sleep(for: .milliseconds(200))
        check("clickMonitor：拖曳超過 6pt 不算點擊，不觸發 openExternal", external.isEmpty, "\(external)")

        external.removeAll()
        let fullFrame = v.frame
        v.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        v.layoutSubtreeIfNeeded()
        sendMouseDrag(from: NSPoint(x: 600, y: 500), to: NSPoint(x: 600, y: 500), in: win)
        _ = await js(v.webView, "document.getElementById('ext').click(); true")
        try? await Task.sleep(for: .milliseconds(200))
        check("clickMonitor：點擊在 webView 範圍外時不觸發 openExternal", external.isEmpty, "\(external)")
        v.frame = fullFrame
        v.layoutSubtreeIfNeeded()

        external.removeAll()
        sendMouseDrag(from: NSPoint(x: 450, y: 350), to: NSPoint(x: 450, y: 350), in: win)
        if let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0
        ) { pumpEvents([key]) }
        _ = await js(v.webView, "document.getElementById('ext').click(); true")
        try? await Task.sleep(for: .milliseconds(200))
        check("clickMonitor：點擊後按鍵會清除 lastUserClick", external.isEmpty, "\(external)")

        await symlinkAndFlowRegressions(root, docs: docs, site: site, v: v)
        await subdirectoryHTMLRegressions(root, site: site, v: v)
    }

    @MainActor static func symlinkAndFlowRegressions(_ root: URL, docs: URL, site: URL, v: PreviewView) async {
        // F2: 含控制/雙向字元的 symlink 指向正常檔，scheme 拒收且 show 不汙染 fileURL
        let bidiSym = docs.appendingPathComponent("bad\u{202E}sym.md")
        try? FileManager.default.createSymbolicLink(at: bidiSym, withDestinationURL: docs.appendingPathComponent("a.md"))
        check("F2: PreviewSchemeHandler 拒收含 U+202E 的 symlink 檔名",
              PreviewSchemeHandler.response(for: bidiSym) == nil)
        let trackedBefore = v.fileURL
        v.show(bidiSym)
        let bidiFallback = await waitBody(v.webView, contains: "檔案已不存在")
        check("F2: PreviewView.show 不把含 U+202E 的路徑寫入 fileURL",
              bidiFallback && !PreviewTarget.hasUnsafeScalar(v.fileURL.path),
              "tracked=\(v.fileURL.path) before=\(trackedBefore.path)")

        // F1 + F5: 父目錄是 symlink 時，開啟 HTML 指向真實路徑，且尚未存在的檔案在 symlink 目錄內重建也能監看恢復
        let symSite = root.appendingPathComponent("symsite")
        try? FileManager.default.createSymbolicLink(at: symSite, withDestinationURL: site)
        v.show(symSite.appendingPathComponent("index.html"))
        _ = await wait { v.webView.url?.isFileURL == true && !v.webView.isLoading }
        let resolvedSite = site.resolvingSymlinksInPath().path
        check("F1: 經 symlink 父目錄開啟 HTML 時，fileURL 解開至真實路徑",
              v.fileURL.path.hasPrefix(resolvedSite), v.fileURL.path)

        let delayedName = "delayed-in-sym.html"
        v.show(symSite.appendingPathComponent(delayedName))
        check("F5: symlink 父目錄內尚未存在的 HTML 先顯示「檔案已不存在」",
              await waitBody(v.webView, contains: "檔案已不存在"))
        try? "<html><body><h1>DelayedOK</h1></body></html>"
            .write(to: site.appendingPathComponent(delayedName), atomically: true, encoding: .utf8)
        check("F5: 於 symlink 父目錄建立檔案後，watcher 自動重載顯示", await waitH1(v.webView, "DelayedOK"))

        // F3: HTML 被刪除並改為指向資料夾外 HTML 的 symlink，watcher 不得擴大授權或載入外部機密
        let boxDir = root.appendingPathComponent("box")
        let outsideDir = root.appendingPathComponent("outside-html")
        try? FileManager.default.createDirectory(at: boxDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let boxedHTML = boxDir.appendingPathComponent("watch.html")
        let outsideHTML = outsideDir.appendingPathComponent("secret.html")
        try? "<html><body><h1>BoxOK</h1></body></html>".write(to: boxedHTML, atomically: true, encoding: .utf8)
        try? "<html><body><h1>OUTSIDE-SECRET</h1></body></html>".write(to: outsideHTML, atomically: true, encoding: .utf8)
        v.show(boxedHTML)
        check("F3: box/watch.html 初始載入", await waitH1(v.webView, "BoxOK"))
        try? FileManager.default.removeItem(at: boxedHTML)
        _ = await waitBody(v.webView, contains: "檔案已不存在")
        try? FileManager.default.createSymbolicLink(at: boxedHTML, withDestinationURL: outsideHTML)
        try? await Task.sleep(for: .milliseconds(600))
        check("F3: 刪除後以資料夾外 symlink 重建，watcher 不得載入外部 secret.html",
              await waitBody(v.webView, contains: "檔案已不存在", excluding: "OUTSIDE-SECRET"))

        // F4 + S2: Markdown -> HTML -> Markdown 後連續 goBack 與 goForward
        let flowDir = root.appendingPathComponent("flow")
        try? FileManager.default.createDirectory(at: flowDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? "body { color: rgb(4, 5, 6); }".write(to: flowDir.appendingPathComponent("flow.css"), atomically: true, encoding: .utf8)
        try? "# FlowA\n\n[go html](page.html)\n".write(to: flowDir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try? "<html><head><link rel=\"stylesheet\" href=\"flow.css\"></head><body><h1>FlowHTML</h1><a id=\"sub\" href=\"sub/child.html\">sub</a><a id=\"b\" href=\"b.md\">to b</a><script>window.flowRan = true;</script></body></html>"
            .write(to: flowDir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try? "<html><head><link rel=\"stylesheet\" href=\"../flow.css\"></head><body><h1>FlowChild</h1><a id=\"b\" href=\"../b.md\">to b</a></body></html>"
            .write(to: flowDir.appendingPathComponent("sub/child.html"), atomically: true, encoding: .utf8)
        try? "# FlowB\n".write(to: flowDir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        v.show(flowDir.appendingPathComponent("a.md"))
        check("F4/S2: 開啟 flow/a.md", await waitH1(v.webView, "FlowA"))
        _ = await js(v.webView, "document.querySelector('a').click(); true")
        check("F4/S2: 從 a.md 點進 page.html", await waitH1(v.webView, "FlowHTML") && (v.webView.url?.isFileURL == true))
        _ = await js(v.webView, "document.getElementById('b').click(); true")
        check("F4/S2: 從 page.html 點進 b.md", await waitH1(v.webView, "FlowB") && v.webView.url?.scheme == PreviewSchemeHandler.scheme)

        v.webView.goBack()
        let backToHTML = await waitH1(v.webView, "FlowHTML")
        let htmlColor = await js(v.webView, "getComputedStyle(document.body).color") as? String ?? ""
        let htmlJS = await js(v.webView, "window.flowRan === true") as? Bool ?? false
        check("F4/S2: 從 b.md goBack() 回到 page.html 且樣式、JS 與 forward 歷史皆有效",
              backToHTML && htmlColor == "rgb(4, 5, 6)" && htmlJS && v.webView.canGoForward,
              "back=\(backToHTML) color=\(htmlColor) js=\(htmlJS) canFwd=\(v.webView.canGoForward)")

        v.webView.goForward()
        check("F4/S2: goForward() 前進回 b.md", await waitH1(v.webView, "FlowB"))
        v.webView.goBack()
        _ = await waitH1(v.webView, "FlowHTML")
        v.webView.goBack()
        check("F4/S2: 再一次 goBack() 回到 a.md 且追蹤檔名為 a.md",
              await waitH1(v.webView, "FlowA") && v.fileURL.lastPathComponent == "a.md", v.fileURL.path)

        // 統一 Markdown -> file:// missing.html / huge.html 錯誤處理
        let mdLinks = flowDir.appendingPathComponent("filelinks.md")
        let missingSub = flowDir.appendingPathComponent("notyet.html")
        try? "# FileLinks\n\n[miss](\(missingSub.absoluteString)) [huge](\(site.appendingPathComponent("huge.html").absoluteString))\n"
            .write(to: mdLinks, atomically: true, encoding: .utf8)
        v.show(mdLinks)
        check("載入 filelinks.md", await waitH1(v.webView, "FileLinks"))
        _ = await js(v.webView, "document.querySelector('a').click(); true")
        check("Markdown 點 file:// 不存在的 .html 一樣顯示「檔案已不存在」並更新追蹤",
              await waitBody(v.webView, contains: "檔案已不存在") && v.fileURL.lastPathComponent == "notyet.html",
              "url=\(v.webView.url?.absoluteString ?? "nil") file=\(v.fileURL.path)")
        v.show(mdLinks)
        _ = await waitH1(v.webView, "FileLinks")
        _ = await js(v.webView, "document.querySelectorAll('a')[1].click(); true")
        check("Markdown 點 file:// 超限 .html 顯示大小上限提示並更新追蹤",
              await waitBody(v.webView, contains: "超過") && v.fileURL.lastPathComponent == "huge.html",
              "url=\(v.webView.url?.absoluteString ?? "nil") file=\(v.fileURL.path)")
    }

    @MainActor static func subdirectoryHTMLRegressions(_ root: URL, site: URL, v: PreviewView) async {
        // W1 回歸：從 site/index.html 進子資料夾 site/sub/child.html，不應縮窄 fileAccessDirectory，
        // 上層連結 ../index.html、../style.css、goBack()、cross-scheme 返回與 watcher 重建都要正常運作。
        let subDir = site.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let childHTML = subDir.appendingPathComponent("child.html")
        try? """
        <html><head><link rel="stylesheet" href="../style.css"></head><body>
        <h1>ChildPage</h1>
        <a id="up" href="../index.html">up</a>
        <a id="escape" href="../../other/probe.html">escape</a>
        </body></html>
        """.write(to: childHTML, atomically: true, encoding: .utf8)

        v.show(site.appendingPathComponent("index.html"))
        check("子目錄回歸：開啟 site/index.html", await waitH1(v.webView, "SiteHome"))
        _ = await js(v.webView, "document.getElementById('sub').click(); true")
        let enteredSub = await waitH1(v.webView, "ChildPage")
        let subCSS = await js(v.webView, "getComputedStyle(document.body).backgroundColor") as? String ?? ""
        check("子目錄回歸：點進 sub/child.html 且載入上層 CSS", enteredSub && subCSS == "rgb(1, 2, 3)", subCSS)

        _ = await js(v.webView, "document.getElementById('escape').click(); true")
        try? await Task.sleep(for: .milliseconds(250))
        check("子目錄回歸：從 sub/child.html 跳出根目錄 ../../other/probe.html 仍被阻擋",
              v.webView.url?.lastPathComponent == "child.html")

        _ = await js(v.webView, "document.getElementById('up').click(); true")
        check("子目錄回歸：從 sub/child.html 點 ../index.html 順利返回上層首頁", await waitH1(v.webView, "SiteHome"))

        v.webView.goBack()
        check("子目錄回歸：從首頁 goBack() 回到 sub/child.html", await waitH1(v.webView, "ChildPage"))
        v.webView.goBack()
        check("子目錄回歸：再 goBack() 回到 site/index.html", await waitH1(v.webView, "SiteHome"))

        // watcher 在子資料夾頁面刪除後重建：應保留根目錄讀取權限（可套用 ../style.css）
        v.show(site.appendingPathComponent("index.html"))
        _ = await waitH1(v.webView, "SiteHome")
        _ = await js(v.webView, "document.getElementById('sub').click(); true")
        _ = await waitH1(v.webView, "ChildPage")
        try? FileManager.default.removeItem(at: childHTML)
        _ = await waitBody(v.webView, contains: "檔案已不存在")
        try? "<html><head><link rel=\"stylesheet\" href=\"../style.css\"></head><body><h1>ChildRebuilt</h1></body></html>"
            .write(to: childHTML, atomically: true, encoding: .utf8)
        let rebuilt = await waitH1(v.webView, "ChildRebuilt")
        let rebuiltCSS = await js(v.webView, "getComputedStyle(document.body).backgroundColor") as? String ?? ""
        check("子目錄回歸：sub/child.html 重建後 watcher 重載仍保有上層 style.css 讀取權限",
              rebuilt && rebuiltCSS == "rgb(1, 2, 3)", "rebuilt=\(rebuilt) css=\(rebuiltCSS)")

        // 跨 scheme 多層子目錄返回：flow/a.md -> page.html -> sub/child.html -> b.md -> goBack() -> sub/child.html -> goBack() -> page.html
        let flowDir = root.appendingPathComponent("flow")
        v.show(flowDir.appendingPathComponent("a.md"))
        _ = await waitH1(v.webView, "FlowA")
        _ = await js(v.webView, "document.querySelector('a').click(); true")
        _ = await waitH1(v.webView, "FlowHTML")
        _ = await js(v.webView, "document.getElementById('sub').click(); true")
        _ = await waitH1(v.webView, "FlowChild")
        _ = await js(v.webView, "document.getElementById('b').click(); true")
        _ = await waitH1(v.webView, "FlowB")
        v.webView.goBack()
        let backToFlowChild = await waitH1(v.webView, "FlowChild")
        v.webView.goBack()
        let backToFlowPage = await waitH1(v.webView, "FlowHTML")
        check("子目錄回歸：b.md -> goBack() 回 sub/child.html 再 goBack() 回上層 page.html 成功",
              backToFlowChild && backToFlowPage, "child=\(backToFlowChild) page=\(backToFlowPage)")

        // W-Dim4: 跨 scheme 返回時子目錄 HTML 暫時缺失，重建後仍保留上層 root 授權
        let flowChild = flowDir.appendingPathComponent("sub/child.html")
        _ = await js(v.webView, "document.getElementById('sub').click(); true")
        _ = await waitH1(v.webView, "FlowChild")
        _ = await js(v.webView, "document.getElementById('b').click(); true")
        _ = await waitH1(v.webView, "FlowB")
        try? FileManager.default.removeItem(at: flowChild)
        v.webView.goBack()
        _ = await waitBody(v.webView, contains: "檔案已不存在")
        try? "<html><head><link rel=\"stylesheet\" href=\"../flow.css\"></head><body><h1>FlowChildRestored</h1></body></html>"
            .write(to: flowChild, atomically: true, encoding: .utf8)
        let flowChildRestored = await waitH1(v.webView, "FlowChildRestored")
        let flowChildColor = await js(v.webView, "getComputedStyle(document.body).color") as? String ?? ""
        check("子目錄回歸：跨 scheme 返回缺失的 sub/child.html 後重建，仍保留上層 flow.css 權限",
              flowChildRestored && flowChildColor == "rgb(4, 5, 6)", "restored=\(flowChildRestored) color=\(flowChildColor)")

        // W-Dim4: WebContent 終止重載子目錄 HTML 時保留上層 root 授權
        v.show(site.appendingPathComponent("index.html"))
        _ = await waitH1(v.webView, "SiteHome")
        _ = await js(v.webView, "document.getElementById('sub').click(); true")
        _ = await waitH1(v.webView, "ChildRebuilt")
        v.webViewWebContentProcessDidTerminate(v.webView)
        let terminatedReloadOK = await waitH1(v.webView, "ChildRebuilt")
        let terminatedCSS = await js(v.webView, "getComputedStyle(document.body).backgroundColor") as? String ?? ""
        check("子目錄回歸：WebContent 重啟重載 sub/child.html 仍保有上層 style.css 權限",
              terminatedReloadOK && terminatedCSS == "rgb(1, 2, 3)", "ok=\(terminatedReloadOK) css=\(terminatedCSS)")

        // W-Dim4: 初始開啟指到資料夾外非 HTML 的 symlink，root 釘在檔案本身資料夾而非外部目標資料夾
        let badOut = site.appendingPathComponent("bad-out.html")
        try? FileManager.default.removeItem(at: badOut)
        try? FileManager.default.createSymbolicLink(at: badOut, withDestinationURL: root.appendingPathComponent("other/secret.txt"))
        v.show(badOut)
        _ = await waitBody(v.webView, contains: "檔案已不存在")
        try? FileManager.default.removeItem(at: badOut)
        try? FileManager.default.createSymbolicLink(at: badOut, withDestinationURL: root.appendingPathComponent("other/probe.html"))
        try? await Task.sleep(for: .milliseconds(500))
        let stillMissing = await waitBody(v.webView, contains: "檔案已不存在")
        let probeScripts = await js(v.webView, "document.scripts.length") as? Int ?? -1
        check("安全回歸：初始外指非 HTML symlink 不將 root 錯釘到外部資料夾",
              stillMissing && probeScripts == 0 && v.webView.url?.lastPathComponent != "probe.html",
              "missing=\(stillMissing) scripts=\(probeScripts) url=\(v.webView.url?.lastPathComponent ?? "nil")")
    }
}
