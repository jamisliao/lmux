import Foundation
import LmuxHooks
import LmuxTranscript

public struct PaneTelemetryDisplay: Equatable {
    public var model: String?
    public var turnCount: Int
    public var contextUsedTokens: Int
    public var contextLimitTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var estimatedCostUSD: Double?
    public var contextPercent: Double
    public var toolCalls: [ToolCallEntry]
    public var isActiveAgent: Bool

    public init(model: String? = nil,
                turnCount: Int = 0,
                contextUsedTokens: Int = 0,
                contextLimitTokens: Int = 0,
                inputTokens: Int = 0,
                outputTokens: Int = 0,
                cacheReadTokens: Int = 0,
                estimatedCostUSD: Double? = nil,
                contextPercent: Double = 0,
                toolCalls: [ToolCallEntry] = [],
                isActiveAgent: Bool = false) {
        self.model = model
        self.turnCount = turnCount
        self.contextUsedTokens = contextUsedTokens
        self.contextLimitTokens = contextLimitTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.contextPercent = contextPercent
        self.toolCalls = toolCalls
        self.isActiveAgent = isActiveAgent
    }
}

@MainActor @Observable
public final class AgentTelemetryStore {
    private var snapshotsByPane: [String: AgentTelemetrySnapshot] = [:]

    public init() {}

    public func display(for pane: Pane?) -> PaneTelemetryDisplay {
        guard let pane else { return PaneTelemetryDisplay() }
        let snap = snapshotsByPane[pane.id] ?? AgentTelemetrySnapshot()
        let toolStream = pane.agent.toolStream
        let hasLiveAgent = pane.agent.state != .idle || pane.runsClaude || pane.codexReport != nil
        let model = snap.model ?? pane.hookModel ?? (hasLiveAgent ? (pane.agentKind == .codex ? "codex" : "claude") : nil)
        let contextLimit = snap.model != nil ? snap.contextLimitTokens : ModelPricing.contextLimit(for: model)
        let turns = max(snap.turnCount, toolStream.turnCount)
        let isActive = hasLiveAgent

        return PaneTelemetryDisplay(
            model: model,
            turnCount: turns,
            contextUsedTokens: snap.contextUsedTokens,
            contextLimitTokens: contextLimit,
            inputTokens: snap.inputTokens,
            outputTokens: snap.outputTokens,
            cacheReadTokens: snap.cacheReadTokens,
            estimatedCostUSD: snap.estimatedCostUSD,
            contextPercent: snap.contextPercent,
            toolCalls: toolStream.entries,
            isActiveAgent: isActive
        )
    }

    public func recordSnapshot(_ snapshot: AgentTelemetrySnapshot, for paneID: String) {
        snapshotsByPane[paneID] = snapshot
    }

    public func clear(paneID: String) {
        snapshotsByPane.removeValue(forKey: paneID)
    }
}
