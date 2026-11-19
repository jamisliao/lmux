import AppKit
import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

// MARK: - Right Inspector Backdrop (1:1 Apple Liquid Glass)

@MainActor
public final class RightInspectorBackdrop: GlassBackdropView {
    public init(frame: NSRect = .zero) {
        super.init(
            frame: frame,
            materialStyle: .sidebar,
            translucentTint: T.Colors.rightSidebarTint,
            opaqueTint: T.Colors.sidebarBackground
        )
    }

    public required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Right Inspector Resize Handle

@MainActor
public final class RightInspectorResizeHandle: NSView {
    public var onDrag: ((CGFloat) -> Void)?
    public var onDragStateChange: ((Bool) -> Void)?
    public private(set) var isDragging = false

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    public override func mouseDown(with event: NSEvent) {
        isDragging = true
        onDragStateChange?(true)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isDragging, let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil).x)
    }

    public override func mouseUp(with event: NSEvent) {
        isDragging = false
        onDragStateChange?(false)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { cancelDragIfNeeded() }
    }

    public func cancelDragIfNeeded() {
        if isDragging {
            isDragging = false
            onDragStateChange?(false)
        }
    }
}

// MARK: - Right Inspector View

public struct RightInspectorView<PreviewContent: View, DiffContent: View, TraceContent: View>: View {
    @Bindable var model: AppModel
    var onSelectTab: ((InspectorTab) -> Void)?
    var onLeavePreview: (() -> Void)?
    @ViewBuilder let previewContent: () -> PreviewContent
    @ViewBuilder let diffContent: () -> DiffContent
    @ViewBuilder let traceContent: () -> TraceContent

    public init(
        model: AppModel,
        onSelectTab: ((InspectorTab) -> Void)? = nil,
        onLeavePreview: (() -> Void)? = nil,
        @ViewBuilder previewContent: @escaping () -> PreviewContent,
        @ViewBuilder diffContent: @escaping () -> DiffContent,
        @ViewBuilder traceContent: @escaping () -> TraceContent
    ) {
        self.model = model
        self.onSelectTab = onSelectTab
        self.onLeavePreview = onLeavePreview
        self.previewContent = previewContent
        self.diffContent = diffContent
        self.traceContent = traceContent
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
                .overlay(T.Colors.glassBorder.color)

            ZStack {
                switch model.inspectorTab {
                case .preview:
                    previewContent()
                case .diff:
                    diffContent()
                case .trace:
                    traceContent()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerBar: some View {
        HStack(spacing: 4) {
            tabButton(.preview, label: "即時預覽", icon: "eye")
            tabButton(.diff, label: "變更 (Diff)", icon: "doc.badge.plus")
            tabButton(.trace, label: "執行記錄", icon: "list.bullet.rectangle")
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(T.Colors.glassSurfaceRecessed.color.opacity(0.4))
    }

    @ViewBuilder
    private func tabButton(_ tab: InspectorTab, label: String, icon: String) -> some View {
        let isSelected = model.inspectorTab == tab
        Button {
            if let onSelectTab {
                onSelectTab(tab)
            } else {
                let wasPreview = model.inspectorTab == .preview
                model.inspectorTab = tab
                if wasPreview && tab != .preview {
                    onLeavePreview?()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? T.Colors.glassCardSelected.color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? T.Colors.glassBorder.color : Color.clear, lineWidth: 0.5)
            )
            .foregroundColor(isSelected ? T.Colors.textPrimary.color : T.Colors.textSecondary.color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Inspector Container View

public struct InspectorContainerView: View {
    @Bindable var model: AppModel
    let controller: LmuxController

    public init(model: AppModel, controller: LmuxController) {
        self.model = model
        self.controller = controller
    }

    public var body: some View {
        RightInspectorView(
            model: model,
            onSelectTab: { [weak controller] tab in
                controller?.showInspectorTab(tab)
            },
            onLeavePreview: { [weak controller] in
                controller?.previewCoordinator.onLeavePreview()
                controller?.focusCurrent()
            },
            previewContent: { [weak controller] in
                if let controller {
                    InspectorPreviewPane(
                        coordinator: controller.previewCoordinator,
                        candidates: model.gitDiffService.snapshot.previewCandidates,
                        onSelectCandidate: { [weak controller] url in
                            controller?.openInInspectorPreview(url)
                        }
                    )
                }
            },
            diffContent: { [weak controller] in
                InspectorDiffView(
                    snapshot: model.gitDiffService.snapshot,
                    onOpenPreview: { [weak controller] url in
                        if let sel = controller?.model.selected {
                            controller?.openInInspectorPreview(url, workspace: sel)
                        }
                    }
                )
            },
            traceContent: { [weak controller] in
                let disp = controller?.model.telemetryStore?.display(for: model.selected?.focusedPane)
                    ?? PaneTelemetryDisplay(model: nil, turnCount: 0, contextUsedTokens: 0, contextLimitTokens: 200_000, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, estimatedCostUSD: nil, contextPercent: 0, toolCalls: [], isActiveAgent: false)
                InspectorTraceView(display: disp)
            }
        )
    }
}
