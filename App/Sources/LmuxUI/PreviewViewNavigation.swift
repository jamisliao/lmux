import AppKit
import WebKit

/// `PreviewView` 的導覽與安全邊界規則（從 `PreviewView.swift` 拆出）：控制主框架／iframe 導覽、
/// 歷史返回（含跨 `lmux-preview://` 與 `file://`）、資料夾沙盒限制與 WebContent 重啟恢復。
@MainActor
extension PreviewView {
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
        if !mainFrame {
            decisionHandler(isAllowedSubframe(url: url, scheme: scheme, action: action) ? .allow : .cancel, preferences)
            return
        }

        let isProgrammaticShow = consumePendingShow(matching: url)
        let sourceScheme = Self.sourceScheme(of: action)
        let currentScheme = webView.url?.scheme?.lowercased()

        // 整頁只能是本機檔案、lmux-preview、或 lmux 自己產生的空白錯誤頁（about:blank）；
        // 只有本機 HTML 檔案執行 JavaScript；Markdown 與純文字檔（lmux-preview）與錯誤頁（about:blank）皆不執行。
        if url.absoluteString.lowercased() == "about:blank" {
            preferences.allowsContentJavaScript = false
            decisionHandler(.allow, preferences)
            return
        }
        if url.isFileURL {
            handleFileMainFrameNavigation(
                url,
                isProgrammaticShow: isProgrammaticShow,
                isNewWindow: action.targetFrame == nil,
                sourceScheme: sourceScheme,
                navigationType: action.navigationType,
                preferences: preferences,
                decisionHandler: decisionHandler
            )
            return
        }
        if scheme == PreviewSchemeHandler.scheme {
            // 只允許 Swift 主動載入、Markdown 頁面內連結/重整或歷史上一頁，禁止本機 HTML 主動跳轉到 lmux-preview://。
            // 純文字檔更嚴：頁面內的連結也不接受（下方 isText 分支）。
            let fromPreview = sourceScheme == PreviewSchemeHandler.scheme
                && (currentScheme == nil || currentScheme == PreviewSchemeHandler.scheme)
            let isReload = action.navigationType == .reload && currentScheme == PreviewSchemeHandler.scheme
            guard isProgrammaticShow || fromPreview || isReload || action.navigationType == .backForward,
                  let file = PreviewSchemeHandler.file(for: url) else {
                decisionHandler(.cancel, preferences)
                return
            }
            let real = PreviewTarget.resolvingPath(file)
            guard !PreviewTarget.hasUnsafeScalar(file.path),
                  !PreviewTarget.hasUnsafeScalar(real.path) else {
                decisionHandler(.cancel, preferences)
                return
            }
            if PreviewTarget.isText(file) {
                // 純文字檔只在 Swift 主動載入（開啟選單、監看、WebContent 重啟）、重新整理、上一頁／下一頁時顯示；
                // 頁面裡連到純文字檔的連結不換頁（beat: plain-text-preview.feature）。
                guard isProgrammaticShow || isReload || action.navigationType == .backForward,
                      PreviewTarget.kind(real) == .text else {
                    decisionHandler(.cancel, preferences)
                    return
                }
                preferences.allowsContentJavaScript = false
                activeNavigationURL = url
                decisionHandler(.allow, preferences)
                return
            }
            if !PreviewTarget.isMarkdown(file) {
                decisionHandler(.cancel, preferences)
                openHTMLFromPreview(file, real: real)
                return
            }
            guard PreviewTarget.isMarkdown(real) else {
                decisionHandler(.cancel, preferences)
                return
            }
            if action.targetFrame == nil {
                decisionHandler(.cancel, preferences)
                show(file)
                return
            }
            preferences.allowsContentJavaScript = false
            activeNavigationURL = url
            decisionHandler(.allow, preferences)
            return
        }
        decisionHandler(.cancel, preferences)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        activeNavigationURL = nil
        guard let url = webView.url else { return }
        if url.scheme?.lowercased() == PreviewSchemeHandler.scheme {
            // 透過瀏覽歷史返回 Markdown 時，清掉之前 HTML 留下的資料夾授權狀態。
            fileAccessDirectory = nil
            pinnedHTMLRoot = nil
        } else if url.isFileURL {
            let real = PreviewTarget.resolvingPath(url)
            if case .ok(let checked) = PreviewSchemeHandler.inspectRegularFile(real) {
                let dir = checked.deletingLastPathComponent()
                let canonical = PreviewTarget.canonicalPath(checked.path)
                // 保留此 HTML 工作階段最初鎖定的根目錄，不在進入子資料夾後縮窄或於跨 scheme 歷史返回時遺失上層根目錄。
                let root = fileAccessDirectory ?? pinnedHTMLRoot ?? visitedHTMLRoots[canonical] ?? dir
                fileAccessDirectory = root
                if pinnedHTMLRoot == nil { pinnedHTMLRoot = root }
                visitedHTMLRoots[canonical] = root
            }
        }
        let file = PreviewSchemeHandler.file(for: url) ?? (url.isFileURL ? url : nil)
        guard let file, !PreviewTarget.hasUnsafeScalar(file.path) else { return }
        updateTrackedFile(file)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error, committed: false)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error, committed: true)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        show(fileURL, preserveRoot: true)
    }

    func consumePendingShow(matching url: URL) -> Bool {
        guard let pending = pendingShowURL else { return false }
        if pending == url || (pending.isFileURL && url.isFileURL && pending.standardizedFileURL == url.standardizedFileURL) {
            pendingShowURL = nil
            return true
        }
        return false
    }

    static func isInsideDirectory(_ candidate: URL, directory: URL) -> Bool {
        let basePath = PreviewTarget.canonicalPath(PreviewTarget.resolvingPath(directory).path)
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetPath = PreviewTarget.canonicalPath(PreviewTarget.resolvingPath(candidate).path)
        return targetPath == basePath || targetPath.hasPrefix(prefix)
    }

    func isAllowedFileHTML(_ url: URL) -> Bool {
        guard url.isFileURL,
              let root = fileAccessDirectory ?? pinnedHTMLRoot ?? (webView.url?.isFileURL == true ? fileURL.deletingLastPathComponent() : nil) else {
            return false
        }
        let real = PreviewTarget.resolvingPath(url)
        guard !PreviewTarget.hasUnsafeScalar(url.path),
              !PreviewTarget.hasUnsafeScalar(real.path),
              Self.isInsideDirectory(real, directory: root),
              PreviewTarget.isHTML(url), PreviewTarget.isHTML(real),
              case .ok = PreviewSchemeHandler.inspectRegularFile(real) else {
            return false
        }
        return true
    }

    static func sourceScheme(of action: WKNavigationAction) -> String? {
        // WebKit 的 WKFrameInfo.request 在導覽剛發起時可能為 nil（標頭誤標 nonnull），不能直接存取避免 Swift 橋接陷阱。
        let frame = (action as NSObject).value(forKey: "sourceFrame") as? WKFrameInfo
        if let req = frame?.value(forKey: "request") as? NSURLRequest,
           let s = req.url?.scheme?.lowercased(), !s.isEmpty {
            return s
        }
        if let proto = frame?.securityOrigin.`protocol`, !proto.isEmpty {
            return proto.lowercased()
        }
        return nil
    }

    func isAllowedSubframe(url: URL, scheme: String, action: WKNavigationAction) -> Bool {
        if ["about", "blob", "data"].contains(scheme) { return true }
        guard url.isFileURL else { return false }
        guard Self.sourceScheme(of: action) == "file", webView.url?.isFileURL == true else { return false }
        return isAllowedFileHTML(url)
    }

    private func openHTMLFromPreview(_ url: URL, real: URL) {
        guard PreviewTarget.isHTML(url), PreviewTarget.isHTML(real) else { return }
        show(url)
    }

    private func isHistoryFileURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let list = webView.backForwardList
        let items = list.backList + list.forwardList + (list.currentItem.map { [$0] } ?? [])
        return items.contains { $0.url.isFileURL && $0.url.standardizedFileURL == standardized }
    }

    func handleFileMainFrameNavigation(
        _ url: URL,
        isProgrammaticShow: Bool,
        isNewWindow: Bool,
        sourceScheme: String?,
        navigationType: WKNavigationType,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        if isProgrammaticShow, isAllowedFileHTML(url) {
            preferences.allowsContentJavaScript = true
            activeNavigationURL = url
            decisionHandler(.allow, preferences)
            return
        }
        let isBackForward = navigationType == .backForward
        // WKWebView 觸發 back/forward 時，會先將 `webView.url` 切到目標 URL 才呼叫 `decidePolicyFor`；
        // 因此不可用 `webView.url` 判定來源為 file://，避免從 Markdown 返回 HTML 時誤用空的 `fileAccessDirectory` 擋掉。
        let fromFile = (!isBackForward && webView.url?.isFileURL == true) || sourceScheme == "file"
        let fromPreview = sourceScheme == PreviewSchemeHandler.scheme
            || (!isBackForward && webView.url?.scheme?.lowercased() == PreviewSchemeHandler.scheme)
        guard fromFile || fromPreview || (isBackForward && isHistoryFileURL(url)) else {
            decisionHandler(.cancel, preferences)
            return
        }
        let real = PreviewTarget.resolvingPath(url)
        guard !PreviewTarget.hasUnsafeScalar(url.path), !PreviewTarget.hasUnsafeScalar(real.path) else {
            decisionHandler(.cancel, preferences)
            return
        }
        if fromFile && !isBackForward {
            guard let root = fileAccessDirectory ?? pinnedHTMLRoot, Self.isInsideDirectory(real, directory: root) else {
                decisionHandler(.cancel, preferences)
                return
            }
        }
        if PreviewTarget.isMarkdown(url) {
            decisionHandler(.cancel, preferences)
            if PreviewTarget.isMarkdown(real) { show(url) }
            return
        }
        if fromPreview && !isBackForward {
            decisionHandler(.cancel, preferences)
            openHTMLFromPreview(url, real: real)
            return
        }
        if isBackForward {
            guard PreviewTarget.isHTML(url), PreviewTarget.isHTML(real),
                  case .ok(let checked) = PreviewSchemeHandler.inspectRegularFile(real) else {
                decisionHandler(.cancel, preferences)
                if PreviewTarget.isHTML(url), PreviewTarget.isHTML(real) {
                    let allowedMissing = (fileAccessDirectory ?? pinnedHTMLRoot)
                        .map { Self.isInsideDirectory(real, directory: $0) }
                        ?? (visitedHTMLRoots[PreviewTarget.canonicalPath(real.path)] != nil)
                    if allowedMissing { show(url, preserveRoot: true) }
                }
                return
            }
            let canonical = PreviewTarget.canonicalPath(checked.path)
            if let root = fileAccessDirectory ?? pinnedHTMLRoot {
                if !Self.isInsideDirectory(checked, directory: root) {
                    decisionHandler(.cancel, preferences)
                    return
                }
            } else if let visitedRoot = visitedHTMLRoots[canonical] {
                clearCacheIfSwitchingHTMLRoot(to: visitedRoot) { [weak self] in
                    guard let self, !self.isClosed else {
                        decisionHandler(.cancel, preferences)
                        return
                    }
                    preferences.allowsContentJavaScript = true
                    self.activeNavigationURL = url
                    decisionHandler(.allow, preferences)
                }
                return
            } else {
                decisionHandler(.cancel, preferences)
                return
            }
            preferences.allowsContentJavaScript = true
            activeNavigationURL = url
            decisionHandler(.allow, preferences)
            return
        }
        guard isAllowedFileHTML(url) else {
            decisionHandler(.cancel, preferences)
            return
        }
        // `target="_blank"`（targetFrame == nil）在沒有 WKUIDelegate 時 `.allow` 會被忽略；改由原預覽開出。
        if isNewWindow {
            decisionHandler(.cancel, preferences)
            show(url, preserveRoot: true)
            return
        }
        preferences.allowsContentJavaScript = true
        activeNavigationURL = url
        decisionHandler(.allow, preferences)
    }
}
