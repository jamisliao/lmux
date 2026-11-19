import AppKit
import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

// MARK: - Right Inspector Backdrop (1:1 Apple Liquid Glass)

@MainActor
public final class RightInspectorBackdrop: NSView {
    let material = NSVisualEffectView()
    let tint = ColorView(T.Colors.rightSidebarTint.nsColor)
    let specular = ColorView(T.Colors.specularHighlight.nsColor)

    public var forceOpaque = false { didSet { update() } }
    public var isResizing = false { didSet { if isResizing != oldValue { update() } } }

    public var isOpaqueFallback: Bool {
        forceOpaque || isResizing || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        addSubview(material)
        addSubview(tint)
        addSubview(specular)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func update() {
        let opaque = isOpaqueFallback
        material.isHidden = opaque
        specular.isHidden = opaque
        tint.color = (opaque ? T.Colors.sidebarBackground : T.Colors.rightSidebarTint).nsColor
        specular.color = T.Colors.specularHighlight.nsColor
    }

    public override func layout() {
        super.layout()
        material.frame = bounds
        tint.frame = bounds
        specular.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: min(1, bounds.height))
    }
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
        if newWindow == nil && isDragging {
            isDragging = false
            onDragStateChange?(false)
        }
    }
}

// MARK: - Right Inspector View

public struct RightInspectorView<PreviewContent: View, DiffContent: View, TraceContent: View>: View {
    @Bindable var model: AppModel
    var onLeavePreview: (() -> Void)?
    @ViewBuilder let previewContent: () -> PreviewContent
    @ViewBuilder let diffContent: () -> DiffContent
    @ViewBuilder let traceContent: () -> TraceContent

    public init(
        model: AppModel,
        onLeavePreview: (() -> Void)? = nil,
        @ViewBuilder previewContent: @escaping () -> PreviewContent,
        @ViewBuilder diffContent: @escaping () -> DiffContent,
        @ViewBuilder traceContent: @escaping () -> TraceContent
    ) {
        self.model = model
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
            if model.inspectorTab == .preview && tab != .preview {
                onLeavePreview?()
            }
            model.inspectorTab = tab
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
            onLeavePreview: { [weak controller] in
                controller?.previewCoordinator.onLeavePreview()
            },
            previewContent: {
                InspectorPreviewPane(
                    coordinator: controller.previewCoordinator
                )
            },
            diffContent: {
                InspectorDiffView(
                    snapshot: controller.model.gitDiffService.snapshot,
                    onOpenPreview: { [weak controller] url in
                        if let sel = controller?.model.selected {
                            controller?.previewCoordinator.load(url: url, workspaceID: sel.id)
                            controller?.model.inspectorTab = .preview
                        }
                    }
                )
            },
            traceContent: {
                let disp = controller.model.telemetryStore?.display(for: model.selected?.focusedPane)
                    ?? PaneTelemetryDisplay(model: nil, turnCount: 0, contextUsedTokens: 0, contextLimitTokens: 200_000, inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, estimatedCostUSD: nil, contextPercent: 0, toolCalls: [], isActiveAgent: false)
                InspectorTraceView(display: disp)
            }
        )
    }
}
