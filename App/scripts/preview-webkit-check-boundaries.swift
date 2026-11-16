import AppKit
import WebKit

extension PreviewWebKitCheck {
    // MARK: - 沙盒邊界：資料夾前綴、子框架跳轉頂層、使用者點擊後 script 自己導覽

    // @feature: preview-tab.feature
    // @scenario: 沒有使用者點擊時，頁面自動跳轉網址不會開啟任何東西
    @MainActor static func boundaryChecks(_ root: URL) async {
        let fm = FileManager.default
        let dirA = root.appendingPathComponent("rootA", isDirectory: true)
        let evil = root.appendingPathComponent("rootA-evil", isDirectory: true)  // 名稱以 rootA 開頭，但是兄弟資料夾
        try? fm.createDirectory(at: dirA.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: evil, withIntermediateDirectories: true)
        let evilHTML = evil.appendingPathComponent("a.html")
        try? "<html><body><h1>EVIL</h1></body></html>".write(to: evilHTML, atomically: true, encoding: .utf8)
        let evilMD = evil.appendingPathComponent("secret.md")
        try? "# SECRET-MD\n".write(to: evilMD, atomically: true, encoding: .utf8)
        // 指向資料夾外的 symlink 放在自己的資料夾，不放進 rootA：rootA 要保持乾淨，才分得出「連結被擋」是因為前綴不同
        let linkDir = root.appendingPathComponent("linkDir", isDirectory: true)
        try? fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let link = linkDir.appendingPathComponent("link-evil.html")
        try? fm.createSymbolicLink(at: link, withDestinationURL: evilHTML)

        // isInsideDirectory 是換 root、watcher、連結與返回的沙盒判斷：前綴相同的兄弟資料夾不能算在內
        check("isInsideDirectory：資料夾自己與底下的路徑算在內",
              PreviewView.isInsideDirectory(dirA, directory: dirA)
              && PreviewView.isInsideDirectory(dirA.appendingPathComponent("sub/x.html"), directory: dirA))
        check("isInsideDirectory：名稱只是前綴相同的兄弟資料夾（rootA-evil）不算在內",
              !PreviewView.isInsideDirectory(evilHTML, directory: dirA))
        check("isInsideDirectory：指向資料夾外的 symlink 解開後不算在內",
              !PreviewView.isInsideDirectory(link, directory: linkDir))

        // 真的點連結：從 rootA/index.html 連到 ../rootA-evil/a.html 要被擋下
        let index = dirA.appendingPathComponent("index.html")
        try? "<html><body><h1>A-INDEX</h1><a id=\"go\" href=\"../rootA-evil/a.html\">go</a></body></html>"
            .write(to: index, atomically: true, encoding: .utf8)
        var external: [URL] = []
        let v = PreviewView(fileURL: index)
        v.openExternal = { external.append($0) }
        let win = host(v)
        defer { v.close(); win.close() }
        check("rootA/index.html 載入", await waitH1(v.webView, "A-INDEX"))
        _ = await js(v.webView, "document.getElementById('go').click(); true")
        try? await Task.sleep(for: .milliseconds(400))
        let h1 = await js(v.webView, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String
        check("連結指到前綴相同的兄弟資料夾（rootA-evil）被擋下，仍停在原頁",
              v.webView.url?.lastPathComponent == "index.html" && h1 == "A-INDEX", "\(v.webView.url?.absoluteString ?? "nil") h1=\(h1 ?? "nil")")

        // 使用者點過之後，script 自己導覽（navigationType 是 .other）不能借用這次點擊授權
        v.noteUserClick()
        _ = await js(v.webView, "window.open('https://example.com/open'); location.href = 'https://example.com/href'; true")
        try? await Task.sleep(for: .milliseconds(500))
        check("使用者點擊後，script 的 location.href／window.open 不會開外部網址或換頁",
              external.isEmpty && v.webView.url?.lastPathComponent == "index.html", "external=\(external) url=\(v.webView.url?.absoluteString ?? "nil")")

        // 子框架（sandbox srcdoc、data:）嘗試把頂層導到 lmux-preview、資料夾外的檔案、外部網址：頂層不動、不開外部網址
        let top = dirA.appendingPathComponent("top.html")
        try? """
        <html><body><h1>TOP</h1><script>
        const targets = ['lmux-preview://\(evilMD.path)', '\(evilHTML.absoluteString)', 'https://example.com/top'];
        for (const t of targets) {
          const f1 = document.createElement('iframe');
          f1.sandbox = 'allow-scripts allow-top-navigation';
          f1.srcdoc = '<script>top.location = ' + JSON.stringify(t) + '<\\/script>';
          document.body.append(f1);
          const f2 = document.createElement('iframe');
          f2.src = 'data:text/html,' + encodeURIComponent('<script>top.location = ' + JSON.stringify(t) + '</scr' + 'ipt>');
          document.body.append(f2);
        }
        </script></body></html>
        """.write(to: top, atomically: true, encoding: .utf8)
        v.show(top)
        let topLoaded = await waitH1(v.webView, "TOP")
        try? await Task.sleep(for: .milliseconds(1200))
        let topH1 = await js(v.webView, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String
        check("子框架（sandbox srcdoc、data:）把頂層導到 lmux-preview、資料夾外檔案、外部網址都被擋下",
              topLoaded && v.webView.url?.lastPathComponent == "top.html" && topH1 == "TOP" && external.isEmpty,
              "url=\(v.webView.url?.absoluteString ?? "nil") h1=\(topH1 ?? "nil") external=\(external)")
        await crossRootHistoryChecks(root)
        await symlinkEscapeChecks(root)
        await prewarmChecks(root)
    }

    // verify 第 4 輪的程式碼審查回報：資料夾裡指向外面的 symlink 會讓 <script src> 讀到資料夾外的檔案
    // （理由：loadFileURL 的讀取範圍只比路徑前綴）。2026-11-16 用審查者的重現程式、關掉任何防護跑了 5 次，
    // 都讀不到（全是 undefined），所以這裡不加防護，只把「讀不到」這個安全性質當回歸檢查：
    // 哪天 WebKit 改了行為而讀得到，這項會變紅。
    // @feature: preview-tab.feature
    // @scenario: HTML 讀得到同資料夾的 CSS 與圖片
    @MainActor static func symlinkEscapeChecks(_ root: URL) async {
        let fm = FileManager.default
        let base = root.appendingPathComponent("symscan", isDirectory: true)
        let outside = base.appendingPathComponent("outside"), site = base.appendingPathComponent("site")
        for d in [outside, site] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try? "window.OUTSIDE_SECRET = 'leaked'".write(to: outside.appendingPathComponent("s.js"), atomically: true, encoding: .utf8)
        try? "API_KEY=\"fake-value-1\"\nDB_PASS=\"fake-value-2\"\n".write(to: outside.appendingPathComponent("app.cfg"), atomically: true, encoding: .utf8)
        let page = site.appendingPathComponent("p.html")
        try? "window.OK = 1".write(to: site.appendingPathComponent("ok.js"), atomically: true, encoding: .utf8)
        try? "<html><body><h1>P</h1><script src=\"cfglnk.js\"></script><script src=\"lnk/s.js\"></script><script src=\"ok.js\"></script></body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        try? fm.createSymbolicLink(at: site.appendingPathComponent("lnk"), withDestinationURL: outside)
        try? fm.createSymbolicLink(at: site.appendingPathComponent("cfglnk.js"), withDestinationURL: outside.appendingPathComponent("app.cfg"))

        let v = PreviewView(fileURL: page)
        let win = host(v)
        defer { v.close(); win.close() }
        let loaded = await waitH1(v.webView, "P")
        try? await Task.sleep(for: .milliseconds(500))
        let leaked = await js(v.webView, "String(window.OUTSIDE_SECRET) + '|' + String(window.API_KEY) + '|' + String(window.DB_PASS)") as? String ?? "nil"
        // 正向對照：同資料夾的一般 <script src> 有執行；否則 script 整個沒載入時，「讀不到」也會綠
        let okRan = await js(v.webView, "window.OK === 1") as? Bool ?? false
        check("資料夾裡指向資料夾外的 symlink（目錄與檔案）：頁面的 <script src> 讀不到外面的檔案（同資料夾的 ok.js 有執行）",
              loaded && okRan && leaked == "undefined|undefined|undefined", "loaded=\(loaded) okRan=\(okRan) leaked=\(leaked)")

        // 對照組：資料夾內部的 symlink（指向同資料夾內的檔案）與 loop -> . 迴圈照常運作
        let clean = base.appendingPathComponent("clean", isDirectory: true)
        try? fm.createDirectory(at: clean, withIntermediateDirectories: true)
        try? "body { background: rgb(7, 8, 9); }".write(to: clean.appendingPathComponent("real.css"), atomically: true, encoding: .utf8)
        try? fm.createSymbolicLink(at: clean.appendingPathComponent("alias.css"), withDestinationURL: clean.appendingPathComponent("real.css"))
        try? fm.createSymbolicLink(at: clean.appendingPathComponent("loop"), withDestinationURL: clean)
        let cleanPage = clean.appendingPathComponent("c.html")
        try? "<html><head><link rel=\"stylesheet\" href=\"alias.css\"></head><body><h1>CLEAN</h1></body></html>"
            .write(to: cleanPage, atomically: true, encoding: .utf8)
        v.show(cleanPage)
        let cleanLoaded = await waitH1(v.webView, "CLEAN")
        try? await Task.sleep(for: .milliseconds(300))
        let bg = await js(v.webView, "getComputedStyle(document.body).backgroundColor") as? String
        check("資料夾內部的 symlink 與 loop -> . 照常運作，CSS 套用", cleanLoaded && bg == "rgb(7, 8, 9)", "loaded=\(cleanLoaded) bg=\(bg ?? "nil")")
    }

    @MainActor static func prewarmChecks(_ root: URL) async {
        let md = root.appendingPathComponent("docs/a.md")
        func firstH1Millis() async -> (Int, PreviewView, NSWindow) {
            let t0 = Date()
            let v = PreviewView(fileURL: md)
            let win = host(v)
            _ = await waitH1(v.webView, "A 文件")
            return (Int(Date().timeIntervalSince(t0) * 1000), v, win)
        }
        // 對照組：沒有備用的 WKWebView（冷啟動，要等 WebContent 程序啟動）
        let (cold, v1, w1) = await firstH1Millis()
        v1.close(); w1.close()
        // 預熱：先建備用的，等程序起來，再開預覽
        PreviewView.prewarm()
        check("prewarm() 之後有一個備用的 WKWebView", PreviewView.hasSpare)
        try? await Task.sleep(for: .milliseconds(2500))
        let (warm, v2, w2) = await firstH1Millis()
        defer { v2.close(); w2.close() }
        check("開預覽時用掉備用的 WKWebView", !PreviewView.hasSpare)
        // 時間會看機器負載，不放進會紅的檢查，只印出來；生命週期（建立、被取用）由上面的檢查驗證。
        print("INFO  預熱：冷啟動 \(cold) ms，預熱後 \(warm) ms")
        check("用備用的 WKWebView 開的預覽沒有多出 about:blank 歷史", v2.webView.backForwardList.backList.isEmpty,
              "backList=\(v2.webView.backForwardList.backList.map { $0.url.absoluteString })")
    }

    @MainActor static func crossRootHistoryChecks(_ root: URL) async {
        let fm = FileManager.default
        let rootX = root.appendingPathComponent("rootX"), rootY = root.appendingPathComponent("rootY")
        let hist = root.appendingPathComponent("docs-hist")
        for d in [rootX, rootY, hist] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try? fm.copyItem(at: root.appendingPathComponent("site/logo.png"), to: rootX.appendingPathComponent("pic.png"))
        let xl = rootX.appendingPathComponent("xl.html"), yy = rootY.appendingPathComponent("y.html")
        let histMD = hist.appendingPathComponent("hist.md")
        try? "<html><body><h1>XL</h1><img src=\"pic.png\"><a id=\"tomd\" href=\"m.md\">md</a></body></html>"
            .write(to: xl, atomically: true, encoding: .utf8)
        try? "<html><body><h1>YY</h1></body></html>".write(to: yy, atomically: true, encoding: .utf8)
        try? "# HIST\n\n[goX](../rootX/xl.html)\n".write(to: histMD, atomically: true, encoding: .utf8)
        try? "# HIST2\n\n[goY](../rootY/y.html)\n".write(to: rootX.appendingPathComponent("m.md"), atomically: true, encoding: .utf8)

        // 歷史：hist.md → xl.html(rootX) → m.md(rootX) → y.html(rootY)，連續返回兩次回到 rootX 的 xl.html：
        // （HTML 只能連到自己 root 內的 .md，所以 m.md 放在 rootX）
        // 走 visitedHTMLRoots 與非同步清快取的路徑，rootX 的圖片要重新讀得到
        let v = PreviewView(fileURL: histMD)
        let win = host(v)
        defer { v.close(); win.close() }
        var walked = await waitH1(v.webView, "HIST")
        _ = await js(v.webView, "document.querySelector('a[href=\"../rootX/xl.html\"]').click(); true")
        walked = await waitH1(v.webView, "XL") && walked
        _ = await js(v.webView, "document.getElementById('tomd').click(); true")
        walked = await waitH1(v.webView, "HIST2") && walked
        _ = await js(v.webView, "document.querySelector('a[href=\"../rootY/y.html\"]').click(); true")
        walked = await waitH1(v.webView, "YY") && walked
        v.webView.goBack()
        walked = await waitH1(v.webView, "HIST2") && walked
        v.webView.goBack()
        let backToX = await waitH1(v.webView, "XL")
        let picOK = await waitJS(v.webView, "(() => { const i = document.images[0]; return !!i && i.complete && i.naturalWidth > 0 })()") { ($0 as? Bool) == true }
        check("跨 root 連續返回：hist.md → xl.html(rootX) → m.md → y.html(rootY)，返回兩次回到 xl.html 且 rootX 的圖片重新讀得到",
              walked && backToX && picOK, "walked=\(walked) backToX=\(backToX) pic=\(picOK) url=\(v.webView.url?.absoluteString ?? "nil")")

        // 換 root 時清快取是非同步的：第一次 show(yy) 在等清快取時，第二次 show(y2)（同一個 root，不用清）立刻載入；
        // 之後第一次的 completion 才跑，必須因為 showGeneration 已變而被丟掉，最後停在第二次
        let y2 = rootY.appendingPathComponent("y2.html")
        try? "<html><body><h1>Y2</h1></body></html>".write(to: y2, atomically: true, encoding: .utf8)
        v.show(yy)
        v.show(y2)
        let lastWins = await waitH1(v.webView, "Y2")
        try? await Task.sleep(for: .milliseconds(800))
        let finalH1 = await js(v.webView, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String
        check("跨 root 清快取期間連續兩次 show()：舊的那次被丟掉，最後停在第二次",
              lastWins && finalH1 == "Y2" && v.fileURL.lastPathComponent == "y2.html", "h1=\(finalH1 ?? "nil") file=\(v.fileURL.lastPathComponent)")

        // 跨 root 返回的瞬間 close()：不當掉、不再載入
        v.show(histMD)
        var ready = await waitH1(v.webView, "HIST")
        _ = await js(v.webView, "document.querySelector('a[href=\"../rootX/xl.html\"]').click(); true")
        ready = await waitH1(v.webView, "XL") && ready
        _ = await js(v.webView, "document.getElementById('tomd').click(); true")
        ready = await waitH1(v.webView, "HIST2") && ready
        _ = await js(v.webView, "document.querySelector('a[href=\"../rootY/y.html\"]').click(); true")
        ready = await waitH1(v.webView, "YY") && ready
        v.webView.goBack()
        v.close()
        try? await Task.sleep(for: .milliseconds(800))
        check("跨 root 返回的瞬間 close()：已關閉且不再載入", ready && v.isClosed && !v.webView.isLoading, "ready=\(ready) closed=\(v.isClosed) loading=\(v.webView.isLoading)")
    }
}
