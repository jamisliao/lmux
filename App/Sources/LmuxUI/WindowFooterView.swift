import AppKit
import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

// MARK: - Footer Backdrop (1:1 Apple Liquid Glass)

@MainActor
public final class FooterBackdrop: GlassBackdropView {
    public init(frame: NSRect = .zero) {
        super.init(
            frame: frame,
            materialStyle: .sidebar,
            translucentTint: T.Colors.footerBackground,
            opaqueTint: T.Colors.sidebarBackground
        )
    }

    public required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Footer Presentation Model

public struct FooterPresentation: Equatable {
    public let modelText: String
    public let latestToolText: String?
    public let latestToolArg: String?
    public let turnsText: String
    public let rendererText: String
    public let contextPercentText: String
    public let contextTokensText: String?
    public let contextRatio: Double?
    public let gitBranchText: String
    public let gitChangesText: String
    public let gitAddedText: String?
    public let gitDeletedText: String?

    public init(
        modelText: String,
        latestToolText: String? = nil,
        latestToolArg: String? = nil,
        turnsText: String,
        rendererText: String,
        contextPercentText: String,
        contextTokensText: String? = nil,
        contextRatio: Double?,
        gitBranchText: String,
        gitChangesText: String,
        gitAddedText: String? = nil,
        gitDeletedText: String? = nil
    ) {
        self.modelText = modelText
        self.latestToolText = latestToolText
        self.latestToolArg = latestToolArg
        self.turnsText = turnsText
        self.rendererText = rendererText
        self.contextPercentText = contextPercentText
        self.contextTokensText = contextTokensText
        self.contextRatio = contextRatio
        self.gitBranchText = gitBranchText
        self.gitChangesText = gitChangesText
        self.gitAddedText = gitAddedText
        self.gitDeletedText = gitDeletedText
    }
}

private struct FooterHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovered || configuration.isPressed ? T.Colors.glassCardHover.color : Color.clear)
                )
                .onHover { hovered = $0 }
        }
    }
}

// MARK: - Window Footer View

public struct WindowFooterView: View {
    @Bindable var model: AppModel
    var telemetry: PaneTelemetryDisplay?
    var git: GitDiffSnapshot?
    var onInspectTab: ((InspectorTab) -> Void)?
    var onToggleInspector: (() -> Void)?

    public init(
        model: AppModel,
        telemetry: PaneTelemetryDisplay? = nil,
        git: GitDiffSnapshot? = nil,
        onInspectTab: ((InspectorTab) -> Void)? = nil,
        onToggleInspector: (() -> Void)? = nil
    ) {
        self.model = model
        self.telemetry = telemetry
        self.git = git
        self.onInspectTab = onInspectTab
        self.onToggleInspector = onToggleInspector
    }

    public static func presentation(telemetry: PaneTelemetryDisplay?, git: GitDiffSnapshot?) -> FooterPresentation {
        let model = telemetry?.model ?? "—"
        let latestToolText: String?
        let latestToolArg: String?
        if let lastTool = telemetry?.toolCalls.last {
            let prefix = lastTool.status == .running ? "▶" : (lastTool.status == .failed ? "✕" : "✓")
            latestToolText = "\(prefix) \(lastTool.name)"
            latestToolArg = lastTool.argument?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            latestToolText = nil
            latestToolArg = nil
        }
        let turns: String
        if let t = telemetry, t.turnCount > 0 {
            turns = "Turn \(t.turnCount)"
        } else {
            turns = "—"
        }
        let renderer = "Metal"
        let percentText: String
        let tokensText: String?
        let ratio: Double?
        let hasTelemetry = telemetry.map { $0.isActiveAgent || $0.model != nil || $0.contextUsedTokens > 0 } ?? false
        if let t = telemetry, hasTelemetry, t.contextLimitTokens > 0 {
            let clamped = min(max(t.contextPercent, 0), 1)
            percentText = "\(Int((clamped * 100).rounded()))%"
            ratio = clamped
            tokensText = "\(InspectorTraceView.formatTokens(t.contextUsedTokens)) / \(InspectorTraceView.formatTokens(t.contextLimitTokens))"
        } else {
            percentText = "—"
            ratio = nil
            tokensText = nil
        }
        let isRepo = git?.isGitRepo == true
        let branch = (isRepo ? git?.branch : nil) ?? "—"
        let added = git?.totalAdded ?? 0
        let deleted = git?.totalDeleted ?? 0
        let changes = isRepo ? "+\(added) -\(deleted)" : "—"
        let addedText = isRepo ? "+\(added)" : nil
        let deletedText = isRepo ? "-\(deleted)" : nil

        return FooterPresentation(
            modelText: model,
            latestToolText: latestToolText,
            latestToolArg: (latestToolArg?.isEmpty == false) ? latestToolArg : nil,
            turnsText: turns,
            rendererText: renderer,
            contextPercentText: percentText,
            contextTokensText: tokensText,
            contextRatio: ratio,
            gitBranchText: branch,
            gitChangesText: changes,
            gitAddedText: addedText,
            gitDeletedText: deletedText
        )
    }

    public var body: some View {
        let telem = telemetry ?? model.telemetryStore?.display(for: model.selected?.focusedPane)
        let g = git ?? model.gitDiffService.snapshot
        let pres = Self.presentation(telemetry: telem, git: g)
        let agentActive = (telem?.isActiveAgent == true) || pres.modelText != "—"
        HStack(spacing: 8) {
            // Left: Agent capsule + Live tool chip + Renderer
            HStack(spacing: 6) {
                Button {
                    onInspectTab?(.trace)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(agentActive ? T.Colors.activePaneRing.color : T.Colors.textTertiary.color)
                            .frame(width: 6, height: 6)
                        Text(pres.modelText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(agentActive ? T.Colors.statusRunningText.color : T.Colors.textSecondary.color)
                            .lineLimit(1)
                        if pres.turnsText != "—" {
                            Text("· \(pres.turnsText)")
                                .font(.system(size: 9.5))
                                .foregroundColor(T.Colors.textTertiary.color)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(agentActive ? T.Colors.statusRunningPill.color : T.Colors.glassCard.color)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                agentActive ? T.Colors.statusRunningText.color.opacity(0.28) : T.Colors.glassBorder.color,
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("執行記錄：\(pres.modelText)")

                if let tool = pres.latestToolText {
                    Button {
                        onInspectTab?(.trace)
                    } label: {
                        HStack(spacing: 4) {
                            Text(tool)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(T.Colors.textPrimary.color)
                            if let arg = pres.latestToolArg {
                                Text(arg)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundColor(T.Colors.textTertiary.color)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 120, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(T.Colors.glassSurfaceRecessed.color)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(FooterHoverButtonStyle())
                    .accessibilityLabel("最近工具：\(tool)\(pres.latestToolArg.map { " \($0)" } ?? "")")
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(T.Colors.stateDone.color)
                        .frame(width: 5, height: 5)
                    Text(pres.rendererText)
                        .font(.system(size: 10))
                        .foregroundColor(T.Colors.textTertiary.color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Center: Context window gauge
            Button {
                onInspectTab?(.trace)
            } label: {
                HStack(spacing: 6) {
                    Text("Context")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(T.Colors.textTertiary.color)
                        .lineLimit(1)
                    if let tokens = pres.contextTokensText {
                        Text(tokens)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(T.Colors.textSecondary.color)
                            .lineLimit(1)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.gray.opacity(0.22))
                                .frame(height: 5)
                            if let ratio = pres.contextRatio {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [T.Colors.activePaneRing.color, T.Colors.workspaceAccents[0].color],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(0, min(geo.size.width * CGFloat(ratio), geo.size.width)), height: 5)
                            }
                        }
                    }
                    .frame(width: 64, height: 5)

                    Text(pres.contextPercentText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(T.Colors.textPrimary.color)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(T.Colors.glassSurfaceRecessed.color)
                        )
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(FooterHoverButtonStyle())
            .accessibilityLabel("Context 負載：\(pres.contextPercentText)")

            Spacer(minLength: 4)

            // Right: Git + Preview + Inspector toggle
            HStack(spacing: 6) {
                Button {
                    onInspectTab?(.diff)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text(pres.gitBranchText)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        if let added = pres.gitAddedText, let deleted = pres.gitDeletedText {
                            HStack(spacing: 3) {
                                Text(added).foregroundColor(T.Colors.diffAddedFg.color)
                                Text(deleted).foregroundColor(T.Colors.diffRemovedFg.color)
                            }
                            .font(.system(size: 9.5, design: .monospaced))
                            .lineLimit(1)
                        }
                    }
                    .foregroundColor(T.Colors.textSecondary.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FooterHoverButtonStyle())
                .accessibilityLabel("Git 變更：\(pres.gitBranchText)")

                Rectangle()
                    .fill(T.Colors.glassBorder.color)
                    .frame(width: 0.5, height: 12)

                Button {
                    onInspectTab?(.preview)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                        Text("即時預覽")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(T.Colors.textSecondary.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FooterHoverButtonStyle())
                .accessibilityLabel("即時預覽")

                Button {
                    if let onToggle = onToggleInspector {
                        onToggle()
                    } else {
                        model.inspectorVisible.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(model.inspectorVisible ? T.Colors.statusRunningText.color : T.Colors.textTertiary.color)
                        Text("⌥⌘B")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(T.Colors.textTertiary.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .fill(T.Colors.glassSurfaceRecessed.color)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                    .strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FooterHoverButtonStyle())
                .accessibilityLabel("切換右側欄 (⌥⌘B)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
    }
}
