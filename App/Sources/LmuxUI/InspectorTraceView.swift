import SwiftUI
import LmuxHooks
import LmuxTokens

private typealias T = LmuxTokens

public struct InspectorTraceView: View {
    public struct Presentation: Equatable {
        public var hasActiveAgent: Bool
        public var modelName: String
        public var turnCount: Int
        public var contextPercent: Double
        public var contextPercentText: String
        public var contextTokensText: String
        public var inputTokensText: String
        public var outputTokensText: String
        public var cacheTokensText: String
        public var costText: String
        public var toolCalls: [ToolCallEntry]
    }

    public let display: PaneTelemetryDisplay
    public init(display: PaneTelemetryDisplay) { self.display = display }

    public static func presentation(for display: PaneTelemetryDisplay) -> Presentation {
        let hasAgent = display.isActiveAgent || display.model != nil || display.contextUsedTokens > 0
        let model = display.model ?? "—"
        let percent = display.contextPercent
        let pctText = String(format: "%.1f%%", percent * 100)
        let usedK = formatTokens(display.contextUsedTokens)
        let limitK = formatTokens(display.contextLimitTokens)
        let inText = formatTokens(display.inputTokens)
        let outText = formatTokens(display.outputTokens)
        let cacheText = formatTokens(display.cacheReadTokens)
        let cost = display.estimatedCostUSD.map { String(format: "$%.4f", $0) } ?? "—"

        return Presentation(
            hasActiveAgent: hasAgent, modelName: model, turnCount: display.turnCount,
            contextPercent: percent, contextPercentText: pctText, contextTokensText: "\(usedK) / \(limitK)",
            inputTokensText: inText, outputTokensText: outText, cacheTokensText: cacheText,
            costText: cost, toolCalls: display.toolCalls
        )
    }

    public static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    public var body: some View {
        let pres = Self.presentation(for: display)
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                if !pres.hasActiveAgent {
                    emptyState
                } else {
                    contextCard(pres)
                    toolCallsCard(pres)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu").font(.system(size: 24, weight: .light)).foregroundColor(T.Colors.textTertiary.color)
            Text("— / 尚無作用中的 Agent").font(.system(size: 12.5, weight: .medium)).foregroundColor(T.Colors.textSecondary.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.Colors.glassCard.color))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [T.Colors.glassHighlightBorder.color, T.Colors.glassBorder.color], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75
                )
        )
    }

    private func contextCard(_ pres: Presentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(T.Colors.statusRunningText.color)
                Text("CONTEXT WINDOW")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(T.Colors.textSecondary.color)
                Spacer()
                Text(pres.contextPercentText)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundColor(T.Colors.statusRunningText.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(T.Colors.statusRunningPill.color)
                    .cornerRadius(4)
            }
            HStack(spacing: 6) {
                Text(pres.modelName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(T.Colors.textPrimary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if pres.turnCount > 0 {
                    Text("Turn #\(pres.turnCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(T.Colors.textTertiary.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(T.Colors.glassSurfaceRecessed.color))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.22))
                    Capsule()
                        .fill(LinearGradient(colors: [T.Colors.activePaneRing.color, T.Colors.workspaceAccents[0].color, T.Colors.workspaceAccents[2].color.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(pres.contextPercent))))
                }
            }.frame(height: 6)
            Text(pres.contextTokensText).font(.system(size: 10.5, design: .monospaced)).foregroundColor(T.Colors.textSecondary.color)
            Divider().overlay(T.Colors.glassBorder.color.opacity(0.5))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { metricItem("輸入 Input", pres.inputTokensText); metricItem("輸出 Output", pres.outputTokensText) }
                GridRow { metricItem("快取命中 Cache", pres.cacheTokensText, valueColor: T.Colors.diffAddedFg.color); metricItem("估計費用", pres.costText) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.Colors.glassCard.color))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [T.Colors.glassHighlightBorder.color, T.Colors.glassBorder.color], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75
                )
        )
    }

    private func metricItem(_ label: String, _ value: String, valueColor: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundColor(T.Colors.textTertiary.color)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(valueColor ?? T.Colors.textPrimary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.Colors.glassSurfaceRecessed.color.opacity(0.75)))
    }

    private func toolCallsCard(_ pres: Presentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundColor(T.Colors.statusRunningText.color)
                Text("最近執行的工具")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(T.Colors.textSecondary.color)
                Spacer()
                Text("即時串流")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(T.Colors.statusRunningText.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(T.Colors.statusRunningPill.color))
                Text("\(pres.toolCalls.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(T.Colors.textTertiary.color)
            }
            if pres.toolCalls.isEmpty {
                Text("尚無執行紀錄").font(.system(size: 11)).foregroundColor(T.Colors.textTertiary.color).padding(.vertical, 8)
            } else {
                ForEach(pres.toolCalls.reversed()) { toolCallRow($0) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.Colors.glassCard.color))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [T.Colors.glassHighlightBorder.color, T.Colors.glassBorder.color], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75
                )
        )
    }

    private func toolCallRow(_ call: ToolCallEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: categoryIcon(call.category)).font(.system(size: 9.5))
                .foregroundColor(categoryColor(call.category)).frame(width: 18, height: 18)
                .background(categoryColor(call.category).opacity(0.15)).cornerRadius(4)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.name).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(T.Colors.textPrimary.color)
                if let arg = call.argument, !arg.isEmpty {
                    Text(arg).font(.system(size: 9.5, design: .monospaced)).foregroundColor(T.Colors.textSecondary.color).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer()
            if call.status == .running {
                Text("執行中…").font(.system(size: 10, weight: .medium)).foregroundColor(T.Colors.stateNeedsInput.color)
            } else if let ms = call.durationMs {
                Text("\(ms)ms").font(.system(size: 10, design: .monospaced))
                    .foregroundColor(call.status == .failed ? T.Colors.stateFailed.color : T.Colors.textTertiary.color)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(T.Colors.glassCard.color))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5))
    }

    private func categoryIcon(_ category: ToolCategory) -> String {
        switch category {
        case .bash: return "terminal"
        case .read: return "book"
        case .edit: return "pencil"
        case .search: return "magnifyingglass"
        case .other: return "gearshape"
        }
    }

    private func categoryColor(_ category: ToolCategory) -> Color {
        switch category {
        case .bash: return T.Colors.stateDone.color
        case .read: return T.Colors.activePaneRing.color
        case .edit: return T.Colors.needsInputRing.color
        case .search: return T.Colors.workspaceAccents[2].color
        case .other: return T.Colors.textSecondary.color
        }
    }
}
