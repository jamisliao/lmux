import AppKit
import WebKit

/// 預覽 tab 的內容（beat: preview-tab.feature）：一個 WKWebView，顯示 Markdown 檔（經
/// `PreviewSchemeHandler` 轉成 HTML）或 HTML 檔（原樣）。檔案改變時重新載入。
/// cookie 與 storage 只活在這個 view 裡（`nonPersistent`），關掉 tab 就清掉。
@MainActor
public final class PreviewView: NSView, WKNavigationDelegate {
    /// 目前顯示的檔案（點連結、返回上一頁時會換）。
    public private(set) var fileURL: URL
    public let webView: WKWebView
    /// 顯示的檔案換了（點連結、返回）：tab 標題跟著換。
    public var onFileChange: ((URL) -> Void)?
    /// 使用者點了 http(s) 連結：lmux 用終端機裡點連結的規則開啟。
    public var openExternal: ((URL) -> Void)?
    private var watcher: PreviewWatcher?
    /// 使用者最近一次在這個預覽裡按下滑鼠的時間。頁面的 script 自己觸發的點擊不算。
    private var lastUserClick: Date?
    private var clickMonitor: Any?
    /// 已經關閉（`close()`）：不再監看、不再回呼。
    public private(set) var isClosed = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: PreviewSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        addSubview(webView)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.window,
               self.webView.bounds.contains(self.webView.convert(event.locationInWindow, from: nil)) {
                self.lastUserClick = Date()
            }
            return event
        }
        show(fileURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }

    /// 載入 `file`：Markdown 走 scheme；HTML 從磁碟載入，只開放它所在的資料夾。
    public func show(_ file: URL) {
        if PreviewTarget.isMarkdown(file) {
            webView.load(URLRequest(url: PreviewSchemeHandler.url(for: file)))
        } else if FileManager.default.fileExists(atPath: file.path) {
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(MarkdownHTML.missingPage(path: file.path), baseURL: nil)
        }
    }

    /// 關閉預覽 tab 時呼叫：停止監看檔案、停止載入、移除滑鼠監看，之後不再回呼。
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        watcher?.stop()
        watcher = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        onFileChange = nil
        openExternal = nil
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    /// 使用者 1 秒內在預覽裡按過滑鼠才算，用掉就清掉：一次點擊最多開一個外部網址。
    func consumeUserClick() -> Bool {
        guard let t = lastUserClick, Date().timeIntervalSince(t) < 1 else { return false }
        lastUserClick = nil
        return true
    }

    /// 測試用：當作使用者剛在預覽裡按了一下滑鼠。
    func noteUserClick() { lastUserClick = Date() }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        preferences: WKWebpagePreferences,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if scheme == "http" || scheme == "https" {
            if mainFrame {
                // 使用者點了網頁連結：交給 lmux，跟終端機裡點連結一樣。script、meta refresh、表單
                // 想把預覽 tab 換成遠端網頁：一律擋掉。
                if action.navigationType == .linkActivated, consumeUserClick() { openExternal?(url) }
                decisionHandler(.cancel, preferences)
                return
            }
            decisionHandler(.allow, preferences)  // 頁面裡嵌入的網頁（例如影片）照常載入
            return
        }
        // lmux-preview 只能是整頁，不能被 iframe 嵌入（見 PreviewSchemeHandler 的安全說明）。
        if scheme == PreviewSchemeHandler.scheme, !mainFrame {
            decisionHandler(.cancel, preferences)
            return
        }
        // HTML 頁面連到 Markdown：改走 scheme（轉成 HTML）。Markdown 頁面連到 HTML：改從磁碟載入
        // （它的 script 在那裡執行，只讀得到它的資料夾）。
        if mainFrame, url.isFileURL, PreviewTarget.isMarkdown(url) {
            decisionHandler(.cancel, preferences)
            show(url)
            return
        }
        if mainFrame, let file = PreviewSchemeHandler.file(for: url), !PreviewTarget.isMarkdown(file) {
            decisionHandler(.cancel, preferences)
            if ["html", "htm"].contains(file.pathExtension.lowercased()) { show(file) }
            return
        }
        // 整頁只能是本機檔案、lmux-preview、或 lmux 自己產生的頁面（about:blank）。
        if mainFrame, !["file", PreviewSchemeHandler.scheme, "about"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            return
        }
        // Markdown 頁面不執行 JavaScript。
        if mainFrame { preferences.allowsContentJavaScript = scheme != PreviewSchemeHandler.scheme }
        decisionHandler(.allow, preferences)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let file = PreviewSchemeHandler.file(for: url) ?? (url.isFileURL ? url : nil)
        guard let file else { return }
        if file.standardizedFileURL != fileURL.standardizedFileURL || watcher == nil {
            fileURL = file
            onFileChange?(file)
            watch(file)
        }
    }

    private func watch(_ file: URL) {
        watcher?.stop()
        watcher = PreviewWatcher(file: file) { [weak self] in
            guard let self, !self.isClosed else { return }
            let exists = FileManager.default.fileExists(atPath: self.fileURL.path)
            if !exists, !PreviewTarget.isMarkdown(self.fileURL) {
                // HTML 被刪除：顯示「檔案已不存在」（Markdown 的這一頁由 scheme 自己回）。
                self.webView.loadHTMLString(MarkdownHTML.missingPage(path: self.fileURL.path), baseURL: nil)
            } else if self.webView.url?.scheme == "about" {
                // 正在顯示「檔案已不存在」，檔案又出現了：重新載入檔案本身。
                self.show(self.fileURL)
            } else {
                self.webView.reload()
            }
        }
    }
}
