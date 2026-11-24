import AppKit
import GhosttyKit
import LmuxTerminal
import Observation
import WebKit

/// Per-workspace controller for the Right Inspector live preview `WKWebView`, navigation
/// history (`canGoBack`/`canGoForward`), and safe external link routing.
@MainActor
@Observable
public final class WorkspacePreviewCoordinator {
    public weak var window: NSWindow?
    public private(set) var workspaceID: String?
    public private(set) var currentURL: URL?
    public private(set) var previewView: PreviewView?
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public var onFileChange: ((URL) -> Void)?

    @ObservationIgnored
    private var backObserver: NSKeyValueObservation?
    @ObservationIgnored
    private var forwardObserver: NSKeyValueObservation?

    public init(window: NSWindow? = nil) {
        self.window = window
    }

    public func load(url: URL, workspaceID: String) {
        guard url.isFileURL,
              !PreviewTarget.hasUnsafeScalar(url.path),
              let resolved = PreviewTarget.resolve(url.path, cwd: nil) else {
            if self.workspaceID != workspaceID {
                closeCurrent()
                self.workspaceID = workspaceID
            }
            return
        }
        if self.workspaceID == workspaceID, let existing = previewView {
            if self.currentURL == resolved { return }
            self.currentURL = resolved
            existing.show(resolved)
            return
        }
        closeCurrent()
        self.workspaceID = workspaceID
        self.currentURL = resolved
        let pv = PreviewView(fileURL: resolved)
        pv.openExternal = { [weak self] target in
            self?.openExternalTarget(target)
        }
        pv.onFileChange = { [weak self] newURL in
            self?.currentURL = newURL
            self?.onFileChange?(newURL)
        }
        backObserver = pv.webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
            MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
        }
        forwardObserver = pv.webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
            MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
        }
        self.previewView = pv
    }

    public func switchWorkspace(to newID: String?, targetURL: URL? = nil) {
        if workspaceID != newID || previewView == nil {
            closeCurrent()
            self.workspaceID = newID
            if let targetURL, let newID {
                load(url: targetURL, workspaceID: newID)
            }
        }
    }

    public func reset() {
        closeCurrent()
        workspaceID = nil
        currentURL = nil
    }

    public func closeCurrent() {
        backObserver?.invalidate()
        backObserver = nil
        forwardObserver?.invalidate()
        forwardObserver = nil
        canGoBack = false
        canGoForward = false
        currentURL = nil
        previewView?.close()
        previewView = nil
    }

    public func goBack() {
        previewView?.webView.goBack()
    }

    public func goForward() {
        previewView?.webView.goForward()
    }

    public func reload() {
        previewView?.reload()
    }

    public func openCurrentExternally() {
        guard let currentURL else { return }
        openExternalTarget(currentURL)
    }

    func openExternalTarget(_ url: URL) {
        let target = url.isFileURL ? url.path : url.absoluteString
        GhosttyRuntime.openTerminalURL(
            target,
            kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
            window: window
        )
    }
}
