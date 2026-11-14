import Foundation
import UniformTypeIdentifiers
import WebKit

/// 提供 `lmux-preview:///<絕對路徑>` 給預覽 tab（beat: preview-tab.feature）：Markdown 檔回傳
/// `MarkdownHTML` 轉好的頁面，圖片原樣回傳（Markdown 頁面用相對路徑引用的圖片）。
///
/// 安全：這個 scheme 給得出任何路徑的檔案，所以
/// - 只回應「主頁面也是 lmux-preview」的請求。HTML 頁面（file://）用 iframe、script、img、fetch
///   要這個 scheme 時一律拒絕，否則它能讀任意本機檔案再送上網路（2026-11-13 實測過 iframe 可以）。
/// - Markdown 以外只給圖片，而且不給 SVG（SVG 可以帶 script）。
/// - 只讀一般檔案、最多 `maxBytes`：`/dev/zero` 或指向它的 symlink 不會讓主執行緒卡住。
/// - 這個 scheme 的頁面不執行 JavaScript（`PreviewView` 關掉，頁面也帶 CSP）。
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lmux-preview"
    /// 一個請求最多讀多少位元組（Markdown 與圖片）。
    static let maxBytes = 20 * 1024 * 1024

    /// 檔案對應的 `lmux-preview:///<路徑>`。
    static func url(for file: URL) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = ""
        c.path = file.path
        return c.url ?? file
    }

    /// `lmux-preview:` 網址代表的檔案；其他網址回傳 nil。
    static func file(for url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        return URL(fileURLWithPath: url.path)
    }

    /// Markdown 頁面可以載入的其他檔案：圖片，SVG 除外。
    static func isServableImage(_ file: URL) -> Bool {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// 一般檔案、而且不超過 `maxBytes` 才讀；資料夾、裝置檔（`/dev/zero`）、指向它們的 symlink 都回傳 nil。
    static func readRegularFile(_ file: URL) -> Data? {
        let real = file.resolvingSymlinksInPath()
        guard let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maxBytes else { return nil }
        return try? Data(contentsOf: real)
    }

    /// 這個 scheme 對 `file` 的回應：內容與 MIME type；不給的檔案回傳 nil。
    static func response(for file: URL) -> (data: Data, mime: String)? {
        if PreviewTarget.isMarkdown(file) {
            guard let data = readRegularFile(file) else {
                return (Data(MarkdownHTML.missingPage(path: file.path).utf8), "text/html")
            }
            let text = String(decoding: data, as: UTF8.self)
            return (Data(MarkdownHTML.page(text, title: file.lastPathComponent).utf8), "text/html")
        }
        guard isServableImage(file), let data = readRegularFile(file) else { return nil }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (data, mime)
    }

    // ponytail: 在主執行緒轉換；504 KB 的 Markdown 約 0.19 秒（2026-11-13 實測，-O build）。
    // 真的卡到再改成背景執行緒，並且不回應已經 stop 的 task。
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.file(for: url),
              task.request.mainDocumentURL?.scheme == Self.scheme,
              let (data, mime) = Self.response(for: file) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let charset = mime.hasPrefix("text/") ? "utf-8" : nil
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: charset))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
