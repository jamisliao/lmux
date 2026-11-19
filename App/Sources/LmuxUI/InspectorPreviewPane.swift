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
    @ObservationIgnored
    public private(set) var previewView: PreviewView?
    public var onFileChange: ((URL) -> Void)?

    public var canGoBack: Bool { previewView?.webView.canGoBack ?? false }
    public var canGoForward: Bool { previewView?.webView.canGoForward ?? false }

    public init(window: NSWindow? = nil) {
        self.window = window
    }

    public func load(url: URL, workspaceID: String) {
        guard !PreviewTarget.hasUnsafeScalar(url.path) else { return }
        if self.workspaceID == workspaceID && self.currentURL == url && previewView != nil {
            return
        }
        closeCurrent()
        self.workspaceID = workspaceID
        self.currentURL = url
        let pv = PreviewView(fileURL: url)
        pv.openExternal = { [weak self] target in
            self?.openExternalTarget(target)
        }
        pv.onFileChange = { [weak self] newURL in
            self?.currentURL = newURL
            self?.onFileChange?(newURL)
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

    public func onLeavePreview() {
        // Leave preview callback hook
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
    var onSelectCandidate: ((URL) -> Void)?

    public init(
        coordinator: WorkspacePreviewCoordinator,
        candidates: [URL] = [],
        onSelectCandidate: ((URL) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.candidates = candidates
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

            Text(coordinator.currentURL?.lastPathComponent ?? "無開啟預覽")
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
                    Button {
                        onSelectCandidate?(candidate)
                    } label: {
                        Text(candidate.lastPathComponent)
                            .font(.system(size: 10, weight: .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(T.Colors.glassSurfaceRecessed.color)
                            )
                            .foregroundColor(T.Colors.textSecondary.color)
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
}
