import AppKit
import WebKit

extension PreviewWebKitCheck {
    // MARK: - 安全與沙盒邊界

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
        let probeMD = docs.appendingPathComponent("a.md").path
        let probeHTML = other.appendingPathComponent("probe.html")
        try? "<html><body><script>parent.postMessage('TOP-SECRET', '*');</script></body></html>"
            .write(to: probeHTML, atomically: true, encoding: .utf8)

        // 惡意 HTML：用 iframe 嵌入 lmux-preview（含帶 script 的 probe.html 與 docs/a.md）、直接 fetch lmux-preview、用 <img> 載入 lmux-preview
        try? """
        <html><body><img id="probe" src="lmux-preview://\(flow)"><script>
        window.leak = 'none'; window.direct = 'none'; window.mdLeak = 'none';
        window.addEventListener('message', e => { window.leak = String(e.data); });
        const fHtml = document.createElement('iframe'); fHtml.src = 'lmux-preview://\(probeHTML.path)'; document.body.append(fHtml);
        const fMd = document.createElement('iframe');
        fMd.onload = () => { try { window.mdLeak = fMd.contentDocument?.body?.innerText || 'loaded'; } catch (e) { window.mdLeak = 'cross-origin'; } };
        fMd.src = 'lmux-preview://\(probeMD)'; document.body.append(fMd);
        fetch('lmux-preview://\(secret.path)').then(r => r.text()).then(t => { window.direct = t }).catch(e => { window.direct = 'blocked' });
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
        try? await Task.sleep(for: .seconds(1))
        let leak = await js(v.webView, "window.leak") as? String ?? "nil"
        check("HTML iframe 載入 lmux-preview .html 不執行也讀不到 SECRET", leak == "none", leak)
        let mdLeak = await js(v.webView, "window.mdLeak") as? String ?? "nil"
        check("HTML iframe 無法載入 lmux-preview .md（被導覽決策擋下）", !mdLeak.contains("A 文件") && mdLeak != "loaded", mdLeak)
        let handler = PreviewSchemeHandler()
        for target in [secret, docs.appendingPathComponent("a.md"), docs.appendingPathComponent("img/flow.png"), docs.appendingPathComponent("img/vector.svg")] {
            var req = URLRequest(url: PreviewSchemeHandler.url(for: target))
            req.mainDocumentURL = site.appendingPathComponent("evil.html")
            let task = MockSchemeTask(request: req)
            handler.webView(v.webView, start: task)
            check("PreviewSchemeHandler 拒絕 mainDocumentURL=file:// 請求 \(target.lastPathComponent)",
                  task.failedError != nil && !task.receivedResponse && !task.finished)
        }
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
        check("指向 /dev/zero 的 .md symlink 不讀，顯示「檔案已不存在」",
              await waitBody(v.webView, contains: "檔案已不存在"))

        // FF3: symlink 指向不允許的副檔名 / SVG（PreviewSchemeHandler + PreviewView）
        let evilPNG = docs.appendingPathComponent("img/evil.png")
        try? FileManager.default.createSymbolicLink(at: evilPNG, withDestinationURL: docs.appendingPathComponent("img/vector.svg"))
        check("PreviewSchemeHandler 拒收 .png -> .svg symlink", PreviewSchemeHandler.response(for: evilPNG) == nil)
        let evilMD = docs.appendingPathComponent("evil-link.md")
        try? FileManager.default.createSymbolicLink(at: evilMD, withDestinationURL: secret)
        check("PreviewSchemeHandler 拒收 .md -> .txt symlink", PreviewSchemeHandler.response(for: evilMD) == nil)
        try? "# SymImg\n\n![bad](img/evil.png)\n".write(to: docs.appendingPathComponent("symimg.md"), atomically: true, encoding: .utf8)
        v.show(docs.appendingPathComponent("symimg.md"))
        check("symimg.md 載入", await waitH1(v.webView, "SymImg"))
        let symNaturalWidth = await js(v.webView, "document.querySelector('img') && document.querySelector('img').naturalWidth")
        check("Markdown 裡的 .png -> .svg symlink 圖片 naturalWidth === 0", (symNaturalWidth as? Int) == 0, "\(String(describing: symNaturalWidth))")
        v.show(evilMD)
        check("指向 .txt 的 .md symlink 不洩漏內容，顯示「檔案已不存在」",
              await waitBody(v.webView, contains: "檔案已不存在", excluding: "TOP-SECRET"))

        let evilHTML = site.appendingPathComponent("evil-link.html")
        try? FileManager.default.createSymbolicLink(at: evilHTML, withDestinationURL: secret)
        v.show(evilHTML)
        check("指向 .txt 的 .html symlink 不顯示內容，顯示「檔案已不存在」",
              await waitBody(v.webView, contains: "檔案已不存在", excluding: "TOP-SECRET"))

        // FF2: /dev/zero、資料夾、超大 .html 在 PreviewView.show 與 watcher 下都安全處理
        let zeroHTML = site.appendingPathComponent("zero.html")
        try? FileManager.default.createSymbolicLink(at: zeroHTML, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        v.show(zeroHTML)
        check("指向 /dev/zero 的 .html symlink 不卡住，顯示「檔案已不存在」",
              await waitBody(v.webView, contains: "檔案已不存在"))

        let dirHTML = site.appendingPathComponent("dir.html")
        try? FileManager.default.createDirectory(at: dirHTML, withIntermediateDirectories: true)
        v.show(dirHTML)
        check(".html 資料夾顯示「檔案已不存在」", await waitBody(v.webView, contains: "檔案已不存在"))

        let hugeHTML = site.appendingPathComponent("huge.html")
        FileManager.default.createFile(atPath: hugeHTML.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: hugeHTML) {
            try? fh.truncate(atOffset: UInt64(PreviewSchemeHandler.maxBytes + 1024))
            try? fh.close()
        }
        v.show(hugeHTML)
        check("超過上限的 .html 顯示大小上限提示", await waitBody(v.webView, contains: "超過"))

        await frameBoundaryChecks(site: site, other: other, v: v, probeHTML: probeHTML)
    }

    @MainActor static func frameBoundaryChecks(site: URL, other: URL, v: PreviewView, probeHTML: URL) async {
        let watchEvil = site.appendingPathComponent("watch-evil.html")
        try? "<html><body><h1>WatchOK</h1></body></html>".write(to: watchEvil, atomically: true, encoding: .utf8)
        let vWatch = PreviewView(fileURL: watchEvil)
        let watchWin = host(vWatch)
        defer { watchWin.close(); vWatch.close() }
        check("watch-evil.html 初始顯示", await waitH1(vWatch.webView, "WatchOK"))
        try? FileManager.default.removeItem(at: watchEvil)
        try? FileManager.default.createSymbolicLink(at: watchEvil, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        check("watcher 偵測到 .html 被換成 /dev/zero symlink 時切換為「檔案已不存在」",
              await waitBody(vWatch.webView, contains: "檔案已不存在"))

        // FF1 & FF6: 本機 HTML 主框架跳轉到 lmux-preview://、其他資料夾、或 .txt/.svg/missing.html 全數擋下
        let otherMD = other.appendingPathComponent("secret.md")
        try? "# SECRET-MD\n".write(to: otherMD, atomically: true, encoding: .utf8)
        try? "<svg xmlns='http://www.w3.org/2000/svg'><script>window.svgRan=true</script></svg>"
            .write(to: site.appendingPathComponent("vector.svg"), atomically: true, encoding: .utf8)
        let navGuardHTML = site.appendingPathComponent("nav-guard.html")
        try? "<html><body><h1>Guard</h1></body></html>".write(to: navGuardHTML, atomically: true, encoding: .utf8)
        v.show(navGuardHTML)
        check("nav-guard.html 載入", await waitH1(v.webView, "Guard"))
        for (label, jsURL) in [
            ("HTML window.top.location 跳 lmux-preview .html 被擋", "lmux-preview://\(probeHTML.path)"),
            ("HTML window.top.location 跳 lmux-preview .md 被擋", "lmux-preview://\(otherMD.path)"),
            ("HTML 跳其他資料夾 file:// secret.md 被擋", otherMD.absoluteString),
            ("HTML 跳其他資料夾 file:// probe.html 被擋", probeHTML.absoluteString),
            ("HTML 跳同資料夾 secret.txt 被擋", "secret.txt"),
            ("HTML 跳同資料夾 vector.svg 被擋", "vector.svg"),
            ("HTML 跳同資料夾 missing.html 被擋", "missing.html")
        ] {
            _ = await js(v.webView, "window.top.location = '\(jsURL)'; true")
            try? await Task.sleep(for: .milliseconds(250))
            let stays = await wait { v.webView.url?.lastPathComponent == "nav-guard.html" && !v.webView.isLoading }
            let h1 = await js(v.webView, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String
            check(label, stays && h1 == "Guard", "\(v.webView.url?.absoluteString ?? "nil") h1=\(h1 ?? "nil")")
        }

        // FF8: !mainFrame iframe allowlist（同資料夾 .html 放行，其他資料夾 .html、.md、沙盒內 iframe 嘗試開本機 .html、custom scheme、mailto 被擋）
        let localOK = site.appendingPathComponent("local-ok.html")
        try? "<html><body><p>LOCAL-SECRET</p><script>window.top.postMessage('LOCAL-OK', '*');</script></body></html>"
            .write(to: localOK, atomically: true, encoding: .utf8)
        try? "<html><body><script>parent.postMessage('SUB-MD', '*');</script></body></html>"
            .write(to: site.appendingPathComponent("c.html"), atomically: true, encoding: .utf8)
        let subframesHTML = site.appendingPathComponent("subframes.html")
        try? """
        <html><body><h1>Subframes</h1><script>
        window.msgs = [];
        window.addEventListener('message', e => { window.msgs.push(String(e.data)); });
        for (const src of ['customscheme://foo', 'mailto:a@b.com', 'tel:12345', '\(probeHTML.absoluteString)', 'c.md', 'local-ok.html']) {
          const f = document.createElement('iframe');
          f.src = src;
          document.body.append(f);
        }
        const sandboxed = document.createElement('iframe');
        sandboxed.sandbox = 'allow-scripts';
        sandboxed.srcdoc = '<iframe src="\(localOK.absoluteString)"></iframe><script>setTimeout(()=>window.top.postMessage("SANDBOX-DONE","*"), 300)<\\/script>';
        document.body.append(sandboxed);
        </script></body></html>
        """.write(to: subframesHTML, atomically: true, encoding: .utf8)
        v.show(subframesHTML)
        check("subframes.html 載入", await waitH1(v.webView, "Subframes"))
        let okMsgArrived = await waitJS(v.webView, "window.msgs && window.msgs.join(',')") {
            let s = $0 as? String ?? ""
            return s.contains("LOCAL-OK") && s.contains("SANDBOX-DONE")
        }
        try? await Task.sleep(for: .milliseconds(400))
        let msgs = (await js(v.webView, "window.msgs && window.msgs.join(',')") as? String ?? "").split(separator: ",").map(String.init)
        let mdFrameText = await js(v.webView, """
        (() => {
          const fs = Array.from(document.querySelectorAll('iframe'));
          const f = fs.find(x => (x.getAttribute('src') || '') === 'c.md');
          try { return f && f.contentDocument && f.contentDocument.body ? f.contentDocument.body.innerText : ''; } catch (e) { return 'blocked'; }
        })()
        """) as? String ?? ""
        let localFrameText = await js(v.webView, """
        (() => {
          const fs = Array.from(document.querySelectorAll('iframe'));
          const f = fs.find(x => (x.getAttribute('src') || '') === 'local-ok.html');
          if (!f) return 'missing';
          try {
            if (!f.contentDocument || !f.contentDocument.body) return 'blocked';
            return f.contentDocument.body.innerText;
          } catch (e) { return 'blocked'; }
        })()
        """) as? String ?? ""
        check("iframe allowlist：只放行同資料夾 local-ok.html，擋下 other/probe.html、c.md 與沙盒內嵌 local-ok",
              okMsgArrived && msgs.filter { $0 == "LOCAL-OK" }.count == 1 && !msgs.contains("SUB-MD") && !msgs.contains("TOP-SECRET") && !mdFrameText.contains("C 文件"),
              "msgs=\(msgs) mdFrame=\(mdFrameText)")
        check("file:// 同資料夾 iframe 跨源隔離（無法讀取 local-ok.html DOM）",
              localFrameText == "blocked", "localFrame=\(localFrameText)")
    }
}
