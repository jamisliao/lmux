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
    /// 使用者最近一次在這個預覽裡按下並放開滑鼠的時間。頁面的 script、遮罩點擊或拖曳都不算。
    private var lastUserClick: Date?
    private var pendingClickLocation: NSPoint?
    var pendingShowURL: URL?
    var fileAccessDirectory: URL?
    /// 初次載入 HTML（或錯誤後等待重建）時鎖定的目錄；watcher 重載不得藉 symlink 逃出此目錄。
    var pinnedHTMLRoot: URL?
    /// 此預覽頁曾合法載入並提交過的本機 HTML 規範路徑對應的根目錄，用來驗證與恢復跨 scheme 歷史返回。
    var visitedHTMLRoots: [String: URL] = [:]
    private var clickMonitor: Any?
    /// 已經關閉（`close()`）：不再監看、不再回呼。
    public private(set) var isClosed = false

    public init(fileURL: URL) {
        self.fileURL = PreviewTarget.hasUnsafeScalar(fileURL.path)
            ? URL(fileURLWithPath: PreviewTarget.replacingUnsafeScalars(fileURL.path))
            : fileURL
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
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            self?.handleMonitorEvent(event)
            return event
        }
        show(fileURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }

    /// 載入 `file`：Markdown 走 scheme；HTML 驗證為合法一般檔案後從磁碟載入，只開放它所在的資料夾。
    public func show(_ file: URL) {
        show(file, fromWatcher: false)
    }

    func show(_ file: URL, fromWatcher: Bool) {
        let real = PreviewTarget.resolvingPath(file)
        if PreviewTarget.hasUnsafeScalar(file.path) {
            if !fromWatcher {
                watcher?.stop()
                watcher = nil
                fileAccessDirectory = nil
                pinnedHTMLRoot = nil
                pendingShowURL = nil
                webView.loadHTMLString(
                    MarkdownHTML.missingPage(path: PreviewTarget.replacingUnsafeScalars(file.path)),
                    baseURL: nil
                )
            }
            return
        }
        if PreviewTarget.isMarkdown(file) {
            guard !PreviewTarget.hasUnsafeScalar(real.path), PreviewTarget.isMarkdown(real) else {
                showFallbackHTML(MarkdownHTML.missingPage(path: file.path), for: file)
                return
            }
            let target = PreviewTarget.resolvingSymlinksAnywhere(file, resolved: real)
            fileAccessDirectory = nil
            pinnedHTMLRoot = nil
            let previewURL = PreviewSchemeHandler.url(for: target)
            pendingShowURL = previewURL
            webView.load(URLRequest(url: previewURL))
            return
        }
        let resolvedDir = real.deletingLastPathComponent()
        if fromWatcher {
            let root = pinnedHTMLRoot ?? fileAccessDirectory
            if let root, !Self.isInsideDirectory(real, directory: root) {
                showFallbackHTML(MarkdownHTML.missingPage(path: file.path), for: file, keepPinnedHTMLRoot: true)
                return
            }
        }
        guard !PreviewTarget.hasUnsafeScalar(real.path),
              PreviewTarget.isHTML(file), PreviewTarget.isHTML(real) else {
            if !fromWatcher, PreviewTarget.isHTML(file) { pinnedHTMLRoot = resolvedDir }
            showFallbackHTML(MarkdownHTML.missingPage(path: file.path), for: file, keepPinnedHTMLRoot: fromWatcher || PreviewTarget.isHTML(file))
            return
        }
        switch PreviewSchemeHandler.inspectRegularFile(real) {
        case .ok(let checked):
            let accessDir = checked.deletingLastPathComponent()
            let activeRoot = (fromWatcher ? pinnedHTMLRoot : nil) ?? accessDir
            if fromWatcher, let root = pinnedHTMLRoot, !Self.isInsideDirectory(checked, directory: root) {
                showFallbackHTML(MarkdownHTML.missingPage(path: file.path), for: file, keepPinnedHTMLRoot: true)
                return
            }
            let target = PreviewTarget.resolvingSymlinksAnywhere(file, resolved: checked)
            fileAccessDirectory = activeRoot
            if !fromWatcher || pinnedHTMLRoot == nil { pinnedHTMLRoot = activeRoot }
            pendingShowURL = target
            let readRoot = Self.readAccessDirectory(for: target, accessDir: accessDir, root: activeRoot)
            webView.loadFileURL(target, allowingReadAccessTo: readRoot)
        case .tooLarge:
            if !fromWatcher { pinnedHTMLRoot = resolvedDir }
            showFallbackHTML(
                MarkdownHTML.tooLargePage(path: file.path, maxMB: PreviewSchemeHandler.maxBytes / (1024 * 1024)),
                for: file,
                keepPinnedHTMLRoot: true
            )
        case .missing:
            if !fromWatcher { pinnedHTMLRoot = resolvedDir }
            showFallbackHTML(MarkdownHTML.missingPage(path: file.path), for: file, keepPinnedHTMLRoot: true)
        }
    }

    static func readAccessDirectory(for target: URL, accessDir: URL, root: URL) -> URL {
        let extraDepth = max(0, accessDir.pathComponents.count - root.pathComponents.count)
        var dir = target.deletingLastPathComponent()
        for _ in 0..<extraDepth {
            dir.deleteLastPathComponent()
        }
        return dir
    }

    private var isShowingFallbackPage: Bool {
        webView.url?.absoluteString.lowercased() == "about:blank"
    }

    private func showFallbackHTML(_ html: String, for file: URL, keepPinnedHTMLRoot: Bool = false) {
        fileAccessDirectory = nil
        if !keepPinnedHTMLRoot { pinnedHTMLRoot = nil }
        pendingShowURL = nil
        updateTrackedFile(file)
        webView.loadHTMLString(html, baseURL: nil)
    }

    func updateTrackedFile(_ file: URL) {
        guard !isClosed, !PreviewTarget.hasUnsafeScalar(file.path) else { return }
        if file.standardizedFileURL != fileURL.standardizedFileURL || watcher == nil {
            fileURL = file
            onFileChange?(file)
            watch(file)
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

    func handleMonitorEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            lastUserClick = nil
            pendingClickLocation = isUnoccludedWebViewEvent(event) ? event.locationInWindow : nil
        case .leftMouseUp:
            defer { pendingClickLocation = nil }
            guard let down = pendingClickLocation, isUnoccludedWebViewEvent(event) else {
                lastUserClick = nil
                return
            }
            let dx = event.locationInWindow.x - down.x
            let dy = event.locationInWindow.y - down.y
            lastUserClick = (dx * dx + dy * dy <= 36) ? Date() : nil
        case .scrollWheel, .keyDown:
            if event.window === window {
                pendingClickLocation = nil
                lastUserClick = nil
            }
        default:
            break
        }
    }

    private func isUnoccludedWebViewEvent(_ event: NSEvent) -> Bool {
        guard let window, event.window === window,
              let contentView = window.contentView else { return false }
        let local = webView.convert(event.locationInWindow, from: nil)
        guard webView.bounds.contains(local) else { return false }
        let hitPoint = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        return contentView.hitTest(hitPoint)?.isDescendant(of: webView) == true
    }

    private func watch(_ file: URL) {
        watcher?.stop()
        watcher = PreviewWatcher(file: file) { [weak self] in
            guard let self, !self.isClosed else { return }
            let real = PreviewTarget.resolvingPath(self.fileURL)
            if PreviewTarget.isMarkdown(self.fileURL) {
                if PreviewTarget.hasUnsafeScalar(real.path) || !PreviewTarget.isMarkdown(real) || self.isShowingFallbackPage {
                    self.show(self.fileURL, fromWatcher: true)
                } else {
                    self.webView.reload()
                }
                return
            }
            // HTML 僅在仍位於鎖定資料夾、為合法一般 HTML 且未超過大小限制時原地重整；否則走 show(_:fromWatcher:true) 阻擋或切換錯誤頁。
            let insidePinnedRoot = self.pinnedHTMLRoot.map { Self.isInsideDirectory(real, directory: $0) } ?? true
            if insidePinnedRoot,
               !PreviewTarget.hasUnsafeScalar(self.fileURL.path),
               !PreviewTarget.hasUnsafeScalar(real.path),
               PreviewTarget.isHTML(self.fileURL), PreviewTarget.isHTML(real),
               case .ok = PreviewSchemeHandler.inspectRegularFile(real),
               !self.isShowingFallbackPage {
                self.webView.reload()
            } else {
                self.show(self.fileURL, fromWatcher: true)
            }
        }
    }
}
