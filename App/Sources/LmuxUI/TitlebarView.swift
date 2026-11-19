import AppKit
import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

// MARK: - Titlebar Backdrop (1:1 Apple Liquid Glass)

@MainActor
final class TitlebarBackdrop: GlassBackdropView {
    init(frame: NSRect = .zero) {
        super.init(
            frame: frame,
            materialStyle: .titlebar,
            translucentTint: T.Colors.titlebarBackground,
            opaqueTint: T.Colors.sidebarBackground
        )
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Titlebar Center Chip

@MainActor
@Observable
public final class TitlebarChipState {
    public var availableWidth: CGFloat
    public var workspace: Workspace?
    public var modeBadge: String?

    public init(workspace: Workspace? = nil, availableWidth: CGFloat = 400, modeBadge: String? = nil) {
        self.workspace = workspace
        self.availableWidth = availableWidth
        self.modeBadge = modeBadge
    }
}

public struct TitlebarCenterChip: View {
    @Bindable var state: TitlebarChipState

    public init(model _: AppModel, state: TitlebarChipState) {
        self.state = state
    }

    public init(model _: AppModel, workspace: Workspace?, availableWidth: CGFloat = 400) {
        self.state = TitlebarChipState(workspace: workspace, availableWidth: availableWidth)
    }

    public static func computeChipLayout(
        availableWidth: CGFloat,
        title: String,
        branch: String?,
        path: String?
    ) -> (showBranch: Bool, showPath: Bool, chipWidth: CGFloat) {
        let hasBranch = branch != nil && !branch!.isEmpty
        let hasPath = path != nil && !path!.isEmpty

        let showBranch = hasBranch && availableWidth >= 220
        let showPath = hasPath && availableWidth >= 360

        // Estimate width needed: padding 20 + icon/dot 16 + title ~ 8/char + branch ~ 7/char + path ~ 6/char
        var estimated: CGFloat = 44 + CGFloat(title.count) * 8
        if showBranch, let b = branch { estimated += 20 + CGFloat(b.count) * 7 }
        if showPath, let p = path { estimated += 20 + CGFloat(p.count) * 6 }

        let chipWidth = min(estimated, max(60, availableWidth))
        return (showBranch, showPath, chipWidth)
    }

    public var body: some View {
        let workspace = state.workspace
        let title = workspace?.title ?? "lmux"
        let branch = workspace?.focusedPane?.branch
        let cwd = workspace?.focusedPane?.cwd
        let layout = Self.computeChipLayout(availableWidth: state.availableWidth, title: title, branch: branch, path: cwd)

        HStack(spacing: 6) {
            // State Dot
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)

            // Title
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(T.Colors.textPrimary.color)

            // Zoom icon
            if workspace?.isZoomed == true {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(T.Colors.activePaneRing.color)
            }

            // Agent autonomy mode badge (when active pane has no tab strip)
            if let badge = state.modeBadge, !badge.isEmpty {
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(T.Colors.textSecondary.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .strokeBorder(T.Colors.glassBorder.color, lineWidth: 1)
                    )
            }

            // Git Branch
            if layout.showBranch, let branch = branch, !branch.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10))
                    Text(branch)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(T.Colors.textSecondary.color)
            }

            // Working Directory Path
            if layout.showPath, let cwd = cwd, !cwd.isEmpty {
                Text(compactPath(abbreviateHome(cwd)))
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(T.Colors.textTertiary.color)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(T.Colors.glassCard.color)
                .overlay(
                    Capsule()
                        .stroke(T.Colors.glassHighlightBorder.color, lineWidth: 1)
                )
        )
        .frame(maxWidth: layout.chipWidth)
    }

    private var dotColor: Color {
        guard let p = state.workspace?.focusedPane else { return T.Colors.statusIdlePill.color }
        switch p.agent.state {
        case .running:
            return T.Colors.statusRunningText.color
        case .needsInput:
            return T.Colors.statusNeedsInputText.color
        case .done:
            return T.Colors.statusDoneText.color
        case .idle:
            return T.Colors.statusIdleText.color
        }
    }
}

// MARK: - Titlebar Right Cluster

public struct TitlebarRightCluster: View {
    let model: AppModel
    let controller: LmuxController

    public static let width: CGFloat = 3 * T.Layout.titlebarButtonSize + 16

    public static func actionSplitRight(controller: LmuxController) {
        if let p = controller.model.selected?.focusedPane { controller.split(p, .right) }
    }

    public static func actionSplitDown(controller: LmuxController) {
        if let p = controller.model.selected?.focusedPane { controller.split(p, .down) }
    }

    public static func actionToggleInspector(controller: LmuxController) {
        controller.toggleInspector()
    }

    public var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "rectangle.split.2x1", help: "Split Right (⌘D)") {
                Self.actionSplitRight(controller: controller)
            }
            IconButton(symbol: "rectangle.split.1x2", help: "Split Down (⇧⌘D)") {
                Self.actionSplitDown(controller: controller)
            }
            // Subtle 1pt separator
            Rectangle()
                .fill(T.Colors.separator.color)
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)
            // Inspector toggle button
            IconButton(
                symbol: "sidebar.right",
                help: "Toggle Inspector (⌥⌘B)",
                active: model.inspectorVisible
            ) {
                Self.actionToggleInspector(controller: controller)
            }
        }
        .frame(height: T.Layout.titlebarButtonSize)
    }
}
