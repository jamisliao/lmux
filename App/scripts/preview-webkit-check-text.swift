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
}
