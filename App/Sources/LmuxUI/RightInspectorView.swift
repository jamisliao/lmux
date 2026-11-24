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

// MARK: - Vertical Resize Handle (Shared)

@MainActor
public final class VerticalResizeHandle: NSView {
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

public typealias RightInspectorResizeHandle = VerticalResizeHandle

// MARK: - Right Inspector View

public struct RightInspectorView<PreviewContent: View, DiffContent: View, TraceContent: View, AskContent: View>: View {
    @Bindable var model: AppModel
    var onSelectTab: ((InspectorTab) -> Void)?
    var onLeavePreview: (() -> Void)?
    @ViewBuilder let previewContent: () -> PreviewContent
    @ViewBuilder let diffContent: () -> DiffContent
    @ViewBuilder let traceContent: () -> TraceContent
    @ViewBuilder let askContent: () -> AskContent

    public init(
        model: AppModel,
        onSelectTab: ((InspectorTab) -> Void)? = nil,
        onLeavePreview: (() -> Void)? = nil,
        @ViewBuilder previewContent: @escaping () -> PreviewContent,
        @ViewBuilder diffContent: @escaping () -> DiffContent,
        @ViewBuilder traceContent: @escaping () -> TraceContent,
        @ViewBuilder askContent: @escaping () -> AskContent
    ) {
        self.model = model
        self.onSelectTab = onSelectTab
        self.onLeavePreview = onLeavePreview
        self.previewContent = previewContent
        self.diffContent = diffContent
        self.traceContent = traceContent
        self.askContent = askContent
    }

    public static func visibleTabs(hasAsk: Bool) -> [InspectorTab] {
        hasAsk ? [.ask, .preview, .diff, .trace] : [.preview, .diff, .trace]
    }

    public static func tabLabel(_ tab: InspectorTab, compact: Bool) -> String {
        switch tab {
        case .ask: return "待確認"
        case .preview: return compact ? "預覽" : "即時預覽"
        case .diff: return compact ? "Diff" : "變更 (Diff)"
        case .trace: return compact ? "記錄" : "執行記錄"
        }
    }

    private var activeAskSession: AskSession? {
        guard let paneID = model.selected?.focusedPane?.id else { return nil }
        return model.askStore.activeSession(for: paneID)
    }

    private var hasAsk: Bool { activeAskSession != nil }
    private var compactTabs: Bool { hasAsk || model.inspectorWidth < 340 }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
                .overlay(T.Colors.glassBorder.color)

            ZStack {
                switch model.inspectorTab {
                case .ask:
                    if hasAsk {
                        askContent()
                    } else {
                        nonAskFallbackContent
                    }
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

    @ViewBuilder
    private var nonAskFallbackContent: some View {
        switch model.lastNonAskInspectorTab {
        case .diff: diffContent()
        case .trace: traceContent()
        case .preview, .ask: previewContent()
        }
    }

    private var headerBar: some View {
        let tabs = Self.visibleTabs(hasAsk: hasAsk)
        let unanswered = activeAskSession.map { max(0, $0.spec.questions.count - $0.answeredCount) } ?? 0
        return HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                tabButton(
                    tab,
                    label: Self.tabLabel(tab, compact: compactTabs),
                    icon: iconName(for: tab),
                    badgeCount: tab == .ask ? unanswered : 0,
                    compactMode: hasAsk
                )
            }
        }
        .padding(2.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(T.Colors.glassCard.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)
        )
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private func iconName(for tab: InspectorTab) -> String {
        switch tab {
        case .ask: return "questionmark.bubble"
        case .preview: return "eye"
        case .diff: return "doc.badge.plus"
        case .trace: return "list.bullet.rectangle"
        }
    }

    @ViewBuilder
    private func tabButton(
        _ tab: InspectorTab,
        label: String,
        icon: String,
        badgeCount: Int = 0,
        compactMode: Bool = false
    ) -> some View {
        let isSelected = model.inspectorTab == tab
        Button {
            if let onSelectTab {
                onSelectTab(tab)
            } else {
                let wasPreview = model.inspectorTab == .preview
                if tab != .ask {
                    model.lastNonAskInspectorTab = tab
                    model.inspectorAutoOpenedByAsk = false
                }
                model.inspectorTab = tab
                if wasPreview && tab != .preview {
                    onLeavePreview?()
                }
            }
        } label: {
            HStack(spacing: 4) {
                if !compactMode || isSelected {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(T.Colors.accent.color.opacity(0.22)))
                        .foregroundColor(T.Colors.accent.color)
                }
            }
            .padding(.horizontal, compactMode ? 4 : 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? T.Colors.glassSurfaceRecessed.color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: isSelected
                                ? [T.Colors.glassHighlightBorder.color, T.Colors.glassBorder.color]
                                : [.clear, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            .foregroundColor(isSelected ? T.Colors.textPrimary.color : T.Colors.textSecondary.color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

public extension RightInspectorView where AskContent == EmptyView {
    init(
        model: AppModel,
        onSelectTab: ((InspectorTab) -> Void)? = nil,
        onLeavePreview: (() -> Void)? = nil,
        @ViewBuilder previewContent: @escaping () -> PreviewContent,
        @ViewBuilder diffContent: @escaping () -> DiffContent,
        @ViewBuilder traceContent: @escaping () -> TraceContent
    ) {
        self.init(
            model: model,
            onSelectTab: onSelectTab,
            onLeavePreview: onLeavePreview,
            previewContent: previewContent,
            diffContent: diffContent,
            traceContent: traceContent,
            askContent: { EmptyView() }
        )
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
                controller?.focusCurrent()
            },
            previewContent: { [weak controller] in
                if let controller {
                    InspectorPreviewPane(
                        coordinator: controller.previewCoordinator,
                        workspaceCwd: model.gitDiffService.snapshot.repoRoot ?? model.gitDiffService.snapshot.cwd ?? model.selected?.focusedPane?.cwd
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
            },
            askContent: { [weak controller] in
                if let paneID = model.selected?.focusedPane?.id,
                   let session = model.askStore.activeSession(for: paneID) {
                    InspectorAskView(
                        session: session,
                        queueCount: model.askStore.pendingCount(for: paneID),
                        onOpenPreview: { [weak controller] url in
                            if let sel = controller?.model.selected {
                                controller?.openInInspectorPreview(url, workspace: sel)
                            }
                        },
                        onSubmit: { [weak controller] in
                            guard let controller else { return }
                            _ = controller.model.askStore.submit(sessionID: session.id)
                            controller.focusCurrent()
                        },
                        onCancel: { [weak controller] in
                            guard let controller else { return }
                            controller.model.askStore.cancel(sessionID: session.id)
                            controller.focusCurrent()
                        }
                    )
                    .id(session.id)
                }
            }
        )
    }
}
