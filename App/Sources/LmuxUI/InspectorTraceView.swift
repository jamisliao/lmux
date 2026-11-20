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
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.Colors.windowBackground.color.opacity(0.2))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Image(systemName: "cpu").font(.system(size: 26, weight: .light)).foregroundColor(T.Colors.textTertiary.color)
            Text("— / 尚無作用中的 Agent").font(.system(size: 12, weight: .medium)).foregroundColor(T.Colors.textSecondary.color)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func contextCard(_ pres: Presentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Context Window").font(.system(size: 12, weight: .semibold)).foregroundColor(T.Colors.textPrimary.color)
                Spacer()
                Text(pres.contextPercentText).font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(T.Colors.activePaneRing.color).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(T.Colors.glassSurfaceRecessed.color).cornerRadius(4)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(T.Colors.glassSurfaceRecessed.color)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [T.Colors.activePaneRing.color, T.Colors.workspaceAccents[2].color.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(pres.contextPercent))))
                }
            }.frame(height: 6)
            Text(pres.contextTokensText).font(.system(size: 10.5, design: .monospaced)).foregroundColor(T.Colors.textSecondary.color)
            Divider().overlay(T.Colors.glassBorder.color.opacity(0.5))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { metricItem("輸入 Input", pres.inputTokensText); metricItem("輸出 Output", pres.outputTokensText) }
                GridRow { metricItem("快取命中 Cache", pres.cacheTokensText); metricItem("估計費用", pres.costText) }
            }
        }
        .padding(10).background(T.Colors.glassSurfaceRecessed.color.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.Colors.glassHighlightBorder.color, lineWidth: 0.5)).cornerRadius(8)
    }

    private func metricItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundColor(T.Colors.textTertiary.color)
            Text(value).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(T.Colors.textPrimary.color)
        }
    }

    private func toolCallsCard(_ pres: Presentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近執行的工具").font(.system(size: 12, weight: .semibold)).foregroundColor(T.Colors.textPrimary.color)
                Spacer()
                Text("\(pres.toolCalls.count)").font(.system(size: 10, weight: .medium)).foregroundColor(T.Colors.textTertiary.color)
            }
            if pres.toolCalls.isEmpty {
                Text("尚無執行紀錄").font(.system(size: 11)).foregroundColor(T.Colors.textTertiary.color).padding(.vertical, 8)
            } else {
                ForEach(pres.toolCalls.reversed()) { toolCallRow($0) }
            }
        }
        .padding(10).background(T.Colors.glassSurfaceRecessed.color.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.Colors.glassHighlightBorder.color, lineWidth: 0.5)).cornerRadius(8)
    }

    private func toolCallRow(_ call: ToolCallEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: categoryIcon(call.category)).font(.system(size: 10))
                .foregroundColor(categoryColor(call.category)).frame(width: 20, height: 20)
                .background(categoryColor(call.category).opacity(0.15)).cornerRadius(4)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.name).font(.system(size: 11, weight: .semibold)).foregroundColor(T.Colors.textPrimary.color)
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
        .padding(6).background(T.Colors.glassCardSelected.color.opacity(0.2)).cornerRadius(6)
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
