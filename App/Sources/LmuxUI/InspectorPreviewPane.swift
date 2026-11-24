import AppKit
import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

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
    let workspaceCwd: String?
    private let resolvedBasePath: String?

    public init(
        coordinator: WorkspacePreviewCoordinator,
        workspaceCwd: String? = nil
    ) {
        self.coordinator = coordinator
        self.workspaceCwd = workspaceCwd
        self.resolvedBasePath = workspaceCwd.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
    }

    public var body: some View {
        VStack(spacing: 10) {
            browserBar
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(T.Colors.glassCard.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [T.Colors.glassHighlightBorder.color, T.Colors.glassBorder.color],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Group {
                if let pv = coordinator.previewView {
                    PreviewRepresentable(previewView: pv)
                        .id(ObjectIdentifier(pv))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(T.Colors.glassCard.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            bottomStatusBar
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browserBar: some View {
        HStack(spacing: 6) {
            Button {
                coordinator.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.canGoBack)
            .accessibilityLabel("上一頁")

            Button {
                coordinator.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.canGoForward)
            .accessibilityLabel("下一頁")

            Button {
                coordinator.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(coordinator.currentURL == nil)
            .accessibilityLabel("重新整理")

            HStack(spacing: 5) {
                if let url = coordinator.currentURL {
                    Image(systemName: fileIconName(for: url))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(T.Colors.stateDone.color)
                }

                Text(displayPath(for: coordinator.currentURL))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(T.Colors.textSecondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if coordinator.currentURL != nil {
                    Text("LIVE")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(T.Colors.diffAddedFg.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(T.Colors.statusDonePill.color))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(T.Colors.glassSurfaceRecessed.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)
            )

            Button {
                coordinator.openCurrentExternally()
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(coordinator.currentURL == nil)
            .accessibilityLabel("用外部程式開啟")
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(T.Colors.textTertiary.color)
            Text("尚無開啟的預覽檔案")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(T.Colors.textPrimary.color)
            Text("在終端機中 ⌘-點擊 支援的檔案\n或從「變更 (Diff)」點選檔案開啟預覽")
                .font(.system(size: 11))
                .foregroundColor(T.Colors.textSecondary.color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 4) {
            Text("WKWebView Pipeline (Metal)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(T.Colors.textTertiary.color)
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(T.Colors.stateDone.color)
                    .frame(width: 5, height: 5)
                Text("Auto-reload on save")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(T.Colors.stateDone.color)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 18)
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
        if let rootPath = resolvedBasePath {
            let filePath = url.standardizedFileURL.path
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            if filePath.hasPrefix(prefix) {
                return String(filePath.dropFirst(prefix.count))
            }
        }
        return url.lastPathComponent
    }
}
