import AppKit
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

/// Left sidebar header above the workspace list (30pt height),
/// containing section title "工作區" and filter pills/menu.
public struct WorkspaceFilterHeader: View {
    @Bindable var model: AppModel
    let controller: LmuxController?

    public init(model: AppModel, controller: LmuxController? = nil) {
        self.model = model
        self.controller = controller
    }

    public var body: some View {
        HStack(spacing: 4) {
            Text("工作區")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(T.Colors.textTertiary.color)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                ForEach(WorkspaceFilter.allCases, id: \.self) { filter in
                    Button(action: { model.workspaceFilter = filter }) {
                        if model.workspaceFilter == filter {
                            Label(filter.title, systemImage: "checkmark")
                        } else {
                            Text(filter.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: model.workspaceFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                    if model.workspaceFilter != .all {
                        Text(model.workspaceFilter.title)
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                }
                .foregroundStyle((model.workspaceFilter == .all ? T.Colors.textTertiary : T.Colors.statusRunningText).color)
                .padding(.horizontal, model.workspaceFilter == .all ? 5 : 6)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(model.workspaceFilter == .all ? Color.clear : T.Colors.statusRunningPill.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(model.workspaceFilter == .all ? Color.clear : T.Colors.statusRunningText.color.opacity(0.25), lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("篩選工作區")
            .accessibilityIdentifier("workspace-filter-menu")
        }
        .padding(.horizontal, T.Layout.rowInsetX + T.Layout.rowPaddingX)
        .frame(height: T.Layout.workspaceFilterHeaderHeight)
    }
}

/// Empty state when active workspaceFilter yields no matching workspaces.
public struct WorkspaceFilterEmptyView: View {
    public static let emptyMessage = "沒有符合篩選條件的工作區"
    public static let resetButtonTitle = "重置為全部"

    public static func resetFilter(model: AppModel) {
        model.workspaceFilter = .all
    }

    let onReset: () -> Void

    public init(model: AppModel) {
        self.onReset = { Self.resetFilter(model: model) }
    }

    public init(onReset: @escaping () -> Void) {
        self.onReset = onReset
    }

    public var body: some View {
        VStack(spacing: 8) {
            Text(Self.emptyMessage)
                .font(T.Typography.rowSubtitle.font)
                .foregroundStyle(T.Colors.textTertiary.color)
                .multilineTextAlignment(.center)
            Button(action: onReset) {
                Text(Self.resetButtonTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(T.Colors.accent.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(T.Colors.glassCard.color))
                    .overlay(Capsule().strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
