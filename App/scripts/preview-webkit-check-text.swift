import AppKit
import WebKit

// 純文字檔的預覽（beat/changes/plain-text-preview）在真的 WKWebView 裡的檢查。
// 由 preview-webkit-check.swift 的 main 呼叫；固定資料夾在 makeFixtures 建的 root 底下的 text/。
extension PreviewWebKitCheck {
    // @feature: plain-text-preview.feature
    // @scenario: 純文字檔以等寬字型原樣顯示
    @MainActor static func textSchemeChecks(_ root: URL) async {
        let dir = root.appendingPathComponent("text")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = dir.appendingPathComponent("app.yaml")
        try? "name: <one>\n".write(to: yaml, atomically: true, encoding: .utf8)
        let page = PreviewSchemeHandler.response(for: yaml, mainDocument: true)
        let html = page.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        check("scheme 回應純文字檔：text/html 頁面", page?.mime == "text/html", page?.mime ?? "nil")
        check("scheme 回應純文字檔：內容放進 <pre class=\"plain\"> 並跳脫",
              html.contains("<pre class=\"plain\"><code>name: &lt;one&gt;\n</code></pre>"), String(html.suffix(200)))
        check("scheme 不把純文字檔當子資源回應（直接呼叫）", PreviewSchemeHandler.response(for: yaml) == nil)
        let alias = dir.appendingPathComponent("alias.txt")
        try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("docs/a.md"))
        check("scheme 不回應指向 Markdown 的 .txt symlink", PreviewSchemeHandler.response(for: alias, mainDocument: true) == nil)

        // 經過 webView(_:start:)：整頁才回應，Markdown 頁面引用時拒絕（驗證 mainDocument 的判斷有接上）。
        let handler = PreviewSchemeHandler()
        let web = WKWebView(frame: .zero)
        var sub = URLRequest(url: PreviewSchemeHandler.url(for: yaml))
        sub.mainDocumentURL = PreviewSchemeHandler.url(for: root.appendingPathComponent("docs/a.md"))
        let subTask = MockSchemeTask(request: sub)
        handler.webView(web, start: subTask)
        check("Markdown 頁面引用純文字檔（子資源）時 scheme 拒絕", subTask.failedError != nil && !subTask.receivedResponse)
        var main = URLRequest(url: PreviewSchemeHandler.url(for: yaml))
        main.mainDocumentURL = PreviewSchemeHandler.url(for: yaml)
        let mainTask = MockSchemeTask(request: main)
        handler.webView(web, start: mainTask)
        check("純文字檔當整頁時 scheme 回應", mainTask.finished && mainTask.failedError == nil
              && String(decoding: mainTask.receivedData, as: UTF8.self).contains("name: &lt;one&gt;"))
    }

    // @feature: plain-text-preview.feature
    // @scenario: 純文字檔以等寬字型原樣顯示
    // @scenario: 有執行權限的 shell script 只顯示，不執行
    // @scenario: 純文字預覽跟著 lmux 的外觀設定切換深淺色
    // @scenario: 很長的一行自動換行
    // @scenario: 內容有不是 UTF-8 的位元組
    // @scenario: 檔案超過大小上限
    // @scenario: Markdown 預覽裡連到純文字檔的連結不換頁
    @MainActor static func textViewChecks(_ root: URL) async {
        // 先建好全部的檔案再開預覽：剛建立的檔案若馬上開啟，監看可能收到建檔事件而重新載入上一頁，檢查會偶發失敗。
        let dir = root.appendingPathComponent("text-view")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = dir.appendingPathComponent("deploy.sh")
        let ran = dir.appendingPathComponent("deploy-ran")
        try? "#!/bin/sh\ntouch '\(ran.path)'\necho '<b>done</b>'\n".write(to: sh, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
        let log = dir.appendingPathComponent("run.log")
        try? (String(repeating: "x", count: 4000) + "\n").write(to: log, atomically: true, encoding: .utf8)
        let bad = dir.appendingPathComponent("bad.log")
        try? (Data("前段 ".utf8) + Data([0xFF, 0xFE]) + Data(" 後段".utf8)).write(to: bad)
        let huge = dir.appendingPathComponent("huge.log")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: huge) {
            try? fh.truncate(atOffset: UInt64(PreviewSchemeHandler.maxMarkdownBytes + 4096))
            try? fh.close()
        }
        let locked = dir.appendingPathComponent("locked.log")
        try? "locked\n".write(to: locked, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let empty = dir.appendingPathComponent("empty.txt")
        try? "".write(to: empty, atomically: true, encoding: .utf8)
        let big = dir.appendingPathComponent("big.log")
        try? ((0..<38_000).map { "line \($0) 0123456789 abcdefghij" }.joined(separator: "\n") + "\nEND-OF-BIG")
            .write(to: big, atomically: true, encoding: .utf8)
        let cjk = dir.appendingPathComponent("設定 檔.yaml")
        try? "cjk: ok\n".write(to: cjk, atomically: true, encoding: .utf8)
        let aliasMD = dir.appendingPathComponent("alias-md.txt")
        try? FileManager.default.createSymbolicLink(at: aliasMD, withDestinationURL: root.appendingPathComponent("docs/a.md"))
        let guide = dir.appendingPathComponent("guide.md")
        try? "# Guide\n\n[設定](run.log)\n".write(to: guide, atomically: true, encoding: .utf8)
        let secret = dir.appendingPathComponent("secret.json")
        try? "TOP-SECRET\n".write(to: secret, atomically: true, encoding: .utf8)
        let gate = dir.appendingPathComponent("gate.html")
        try? "<html><body><h1>Gate</h1></body></html>".write(to: gate, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(500))

        var changes: [String] = []
        let v = PreviewView(fileURL: sh)
        v.onFileChange = { changes.append($0.lastPathComponent) }
        let win = host(v)
        defer { v.close(); win.close() }

        // 原樣顯示、不執行
        check("純文字檔顯示原文", await waitBody(v.webView, contains: "echo '<b>done</b>'"))
        check("純文字檔走 lmux-preview scheme", v.webView.url?.scheme == PreviewSchemeHandler.scheme, v.webView.url?.absoluteString ?? "nil")
        let bold = await js(v.webView, "document.querySelectorAll('b').length")
        check("內容裡的 <b> 沒有變成粗體元素", (bold as? Int) == 0, "\(String(describing: bold))")
        let font = await js(v.webView, "getComputedStyle(document.querySelector('pre.plain code')).fontFamily")
        check("純文字以等寬字型顯示", (font as? String)?.contains("monospace") == true, "\(String(describing: font))")
        check("純文字頁的標題是檔名", v.webView.title == "deploy.sh", v.webView.title ?? "nil")
        check("開啟時通知檔案（deploy.sh）", changes.last == "deploy.sh", "\(changes)")
        try? await Task.sleep(for: .milliseconds(300))
        check("有執行權限的 shell script 沒有被執行", !FileManager.default.fileExists(atPath: ran.path))
        _ = await js(v.webView, "document.body.insertAdjacentHTML('beforeend', '<img src=\"nope.png\" onerror=\"document.title=\\'jsran\\'\">')")
        try? await Task.sleep(for: .milliseconds(500))
        check("純文字頁面的 script（onerror）不會執行", v.webView.title != "jsran", v.webView.title ?? "nil")

        // 深淺色（lmux 的外觀設定經 NSApp.appearance 傳到 WKWebView；這裡直接設定 WKWebView，端對端在 apptest）
        v.webView.appearance = NSAppearance(named: .darkAqua)
        check("深色外觀：純文字預覽用深色背景與淺色文字",
              await waitJS(v.webView, "getComputedStyle(document.documentElement).backgroundColor + '|' + getComputedStyle(document.body).color") {
                  ($0 as? String) == "rgb(13, 17, 23)|rgb(230, 237, 243)" })
        v.webView.appearance = NSAppearance(named: .aqua)
        check("淺色外觀：純文字預覽用淺色背景與深色文字",
              await waitJS(v.webView, "getComputedStyle(document.documentElement).backgroundColor + '|' + getComputedStyle(document.body).color") {
                  ($0 as? String) == "rgb(255, 255, 255)|rgb(36, 41, 47)" })

        // 很長的一行：<pre> 本身與整頁都沒有橫向捲動
        v.show(log)
        check("開啟 run.log", await waitBody(v.webView, contains: "xxxxxxxx"))
        let fits = await js(v.webView, """
            (() => { const p = document.querySelector('pre.plain'), d = document.documentElement;
              return !!p && p.scrollWidth <= p.clientWidth && d.scrollWidth <= d.clientWidth
                && getComputedStyle(p).whiteSpace === 'pre-wrap' })()
            """)
        check("很長的一行自動換行，<pre> 與整頁都沒有橫向捲動", (fits as? Bool) == true, "\(String(describing: fits))")

        // 編碼、大小上限、讀不了、空檔案、接近上限的檔案
        v.show(bad)
        check("不是 UTF-8 的位元組顯示成替代字元，其他內容照常", await waitBody(v.webView, contains: "前段 \u{FFFD}\u{FFFD} 後段"))
        v.show(huge)
        check("超過大小上限的純文字檔顯示提示與完整路徑", await waitBody(v.webView, contains: "檔案太大，無法預覽", also: huge.path))
        v.show(locked)
        check("讀不了的純文字檔顯示「無法讀取檔案」，不說「已不存在」",
              await waitBody(v.webView, contains: "無法讀取檔案", also: locked.path, excluding: "檔案已不存在"))
        v.show(empty)
        let emptyOK = await waitJS(v.webView, "(() => { const p = document.querySelector('pre.plain'); return !!p && p.innerText === '' })()") {
            ($0 as? Bool) == true }
        let emptyBody = await js(v.webView, "document.body ? document.body.innerText : 'nil'") as? String ?? "nil"
        check("空的純文字檔顯示空白頁面，不是錯誤頁", emptyOK,
              "url=\(v.webView.url?.lastPathComponent ?? "nil") body=\(emptyBody.prefix(60))")
        let t0 = Date()
        v.show(big)
        let bigOK = await waitBody(v.webView, contains: "END-OF-BIG")
        let secs = Date().timeIntervalSince(t0)
        check("接近上限（約 1.3 MB）的純文字檔 5 秒內顯示", bigOK && secs < 5, String(format: "%.2f 秒", secs))

        // 中文與空格的檔名（scheme 以「請求網址 == 主文件網址」判斷整頁，要經得起百分比編碼）
        v.show(cjk)
        check("中文與空格檔名的純文字檔顯示", await waitBody(v.webView, contains: "cjk: ok"), v.webView.url?.absoluteString ?? "nil")

        // 種類不同的 symlink：.txt 指向 Markdown 時不顯示
        v.show(aliasMD)
        check("指向 Markdown 的 .txt symlink 顯示「檔案已不存在」", await waitBody(v.webView, contains: "檔案已不存在", excluding: "A 文件"))

        // 連結與導覽：Markdown 連到純文字檔不換頁；HTML 不能把主框架導到純文字檔
        v.show(guide)
        check("開啟 guide.md", await waitH1(v.webView, "Guide"))
        v.noteUserClick()
        _ = await js(v.webView, "document.querySelector('a').click()")
        try? await Task.sleep(for: .milliseconds(400))
        check("Markdown 點純文字檔連結不換頁",
              v.webView.url?.lastPathComponent == "guide.md" && v.fileURL.lastPathComponent == "guide.md",
              "\(v.webView.url?.absoluteString ?? "nil") \(v.fileURL)")
        v.show(gate)
        check("開啟 gate.html", await waitH1(v.webView, "Gate"))
        _ = await js(v.webView, "window.top.location = 'lmux-preview://\(secret.path)'; true")
        try? await Task.sleep(for: .milliseconds(400))
        let gateText = await js(v.webView, "document.body && document.body.innerText") as? String ?? ""
        check("HTML 頁面不能把主框架導到 lmux-preview 的純文字檔",
              v.webView.url?.lastPathComponent == "gate.html" && !gateText.contains("TOP-SECRET"),
              v.webView.url?.absoluteString ?? "nil")
    }

    // @feature: plain-text-preview.feature
    // @scenario: 純文字檔內容改變後，預覽自動更新
    // @scenario: 預覽中的純文字檔被刪除
    @MainActor static func textWatchChecks(_ root: URL) async {
        let dir = root.appendingPathComponent("text-watch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = dir.appendingPathComponent("live.yaml")
        try? "name: one\n".write(to: yaml, atomically: true, encoding: .utf8)
        let hidden = dir.appendingPathComponent("hidden-secret")
        try? "TOP-SECRET\n".write(to: hidden, atomically: true, encoding: .utf8)
        let tail = dir.appendingPathComponent("tail.log")
        try? (1...400).map { "line \($0)" }.joined(separator: "\n").write(to: tail, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(500))
        let v = PreviewView(fileURL: yaml)
        let win = host(v)
        defer { v.close(); win.close() }
        check("開啟 live.yaml", await waitBody(v.webView, contains: "name: one"))
        try? await Task.sleep(for: .milliseconds(300))
        try? "name: one\ndebug: true\n".write(to: yaml, atomically: true, encoding: .utf8)
        check("純文字檔改寫後自動顯示新內容", await waitBody(v.webView, contains: "debug: true"))
        try? FileManager.default.removeItem(at: yaml)
        check("純文字檔被刪除後顯示「檔案已不存在」與完整路徑", await waitBody(v.webView, contains: "檔案已不存在", also: yaml.path))
        try? "name: two\n".write(to: yaml, atomically: true, encoding: .utf8)
        check("純文字檔重新出現後恢復顯示", await waitBody(v.webView, contains: "name: two"))

        // 換成指向「沒有副檔名」檔案的 symlink：種類變了，不顯示目標內容
        try? await Task.sleep(for: .milliseconds(300))
        try? FileManager.default.removeItem(at: yaml)
        try? FileManager.default.createSymbolicLink(at: yaml, withDestinationURL: hidden)
        check("監看中把檔案換成指向無副檔名檔案的 symlink：顯示「檔案已不存在」",
              await waitBody(v.webView, contains: "檔案已不存在", excluding: "TOP-SECRET"))

        // 自動更新後捲動位置不變（plan 階段實測：重新載入保留 scrollY；改用重新 show 會跳回 0）
        v.show(tail)
        _ = await waitBody(v.webView, contains: "line 400")
        _ = await js(v.webView, "window.scrollTo(0, document.documentElement.scrollHeight)")
        try? await Task.sleep(for: .milliseconds(300))
        let before = await js(v.webView, "window.scrollY") as? Double ?? -1
        try? ((1...400).map { "line \($0)" } + ["line 401"]).joined(separator: "\n").write(to: tail, atomically: true, encoding: .utf8)
        _ = await waitBody(v.webView, contains: "line 401")
        try? await Task.sleep(for: .milliseconds(300))
        let after = await js(v.webView, "window.scrollY") as? Double ?? -1
        check("自動更新後捲動位置不變，不跳回開頭", before > 0 && after == before, "before=\(before) after=\(after)")
    }
}
