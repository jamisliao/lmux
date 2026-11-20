import AppKit
import SwiftUI
import WebKit
import GhosttyKit
import LmuxTerminal
import LmuxTokens

private typealias T = LmuxTokens

// MARK: - Workspace Preview Coordinator

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
              let resolved = PreviewTarget.resolve(url.path, cwd: nil) else { return }
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
        previewView?.webView.reload()
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

// MARK: - Preview Representable

struct PreviewRepresentable: NSViewRepresentable {
    let previewView: PreviewView

    func makeNSView(context: Context) -> NSView {
        previewView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Inspector Preview Pane

public struct InspectorPreviewPane: View {
    @Bindable var coordinator: WorkspacePreviewCoordinator
    let candidates: [URL]
    let workspaceCwd: String?
    var onSelectCandidate: ((URL) -> Void)?

    public init(
        coordinator: WorkspacePreviewCoordinator,
        candidates: [URL] = [],
        workspaceCwd: String? = nil,
        onSelectCandidate: ((URL) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.candidates = candidates
        self.workspaceCwd = workspaceCwd
        self.onSelectCandidate = onSelectCandidate
    }

    public var body: some View {
        VStack(spacing: 0) {
            browserBar
            if !candidates.isEmpty {
                candidateChipsBar
            }
            Divider()
                .overlay(T.Colors.glassBorder.color)

            if let pv = coordinator.previewView {
                PreviewRepresentable(previewView: pv)
                    .id(ObjectIdentifier(pv))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }

            Divider()
                .overlay(T.Colors.glassBorder.color)
            bottomStatusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browserBar: some View {
        HStack(spacing: 6) {
            Button {
                coordinator.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.canGoBack)
            .accessibilityLabel("上一頁")

            Button {
                coordinator.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.canGoForward)
            .accessibilityLabel("下一頁")

            Button {
                coordinator.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(coordinator.currentURL == nil)
            .accessibilityLabel("重新整理")

            if let url = coordinator.currentURL {
                Image(systemName: fileIconName(for: url))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(T.Colors.stateDone.color)
            }

            Text(displayPath(for: coordinator.currentURL))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(T.Colors.textPrimary.color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if coordinator.currentURL != nil {
                HStack(spacing: 3) {
                    Circle()
                        .fill(T.Colors.stateDone.color)
                        .frame(width: 5, height: 5)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(T.Colors.stateDone.color)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(T.Colors.glassSurfaceRecessed.color)
                )
            }

            Button {
                coordinator.openCurrentExternally()
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(coordinator.currentURL == nil)
            .accessibilityLabel("用外部程式開啟")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(T.Colors.glassSurfaceRecessed.color.opacity(0.3))
    }

    private var candidateChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(candidates, id: \.self) { candidate in
                    let isSelected = candidate.standardizedFileURL == coordinator.currentURL?.standardizedFileURL
                    Button {
                        onSelectCandidate?(candidate)
                    } label: {
                        Text(candidate.lastPathComponent)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isSelected ? T.Colors.glassCardSelected.color : T.Colors.glassSurfaceRecessed.color)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(isSelected ? T.Colors.glassHighlightBorder.color : Color.clear, lineWidth: 0.5)
                            )
                            .foregroundColor(isSelected ? T.Colors.textPrimary.color : T.Colors.textSecondary.color)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(height: 26)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(T.Colors.textTertiary.color)
            Text("尚無開啟的預覽檔案")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(T.Colors.textPrimary.color)
            Text("在終端機中 ⌘-點擊 支援的檔案\n或點擊上方變更候選檔快速開啟")
                .font(.system(size: 11))
                .foregroundColor(T.Colors.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var bottomStatusBar: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.system(size: 9))
            Text("WKWebView Pipeline (Metal)")
                .font(.system(size: 10))
            Spacer()
            Text("Auto-reload on save")
                .font(.system(size: 10))
        }
        .foregroundColor(T.Colors.textSecondary.color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(T.Colors.glassSurfaceRecessed.color.opacity(0.3))
    }

    private func fileIconName(for url: URL) -> String {
        switch PreviewTarget.kind(url) {
        case .markdown: return "doc.richtext"
        case .html: return "globe"
        case .text, nil: return "doc.text"
        }
    }

    private func displayPath(for url: URL?) -> String {
        guard let url else { return "無開啟預覽" }
        if let base = workspaceCwd, !base.isEmpty {
            let rootPath = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
            let filePath = url.resolvingSymlinksInPath().path
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            if filePath.hasPrefix(prefix) {
                return String(filePath.dropFirst(prefix.count))
            }
        }
        return url.lastPathComponent
    }
}
