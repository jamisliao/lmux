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
    @ObservationIgnored var onRefreshTranscript: (@MainActor (Pane) -> Void)?

    public init() {}

    public func display(for pane: Pane?) -> PaneTelemetryDisplay {
        guard let pane else { return PaneTelemetryDisplay() }
        let snap = snapshotsByPane[pane.id] ?? AgentTelemetrySnapshot()
        let toolStream = pane.agent.toolStream
        let model = snap.model ?? (pane.agent.state == .idle ? nil : (pane.agentKind == .codex ? "codex" : "claude"))
        let turns = max(snap.turnCount, toolStream.turnCount)
        let isActive = pane.agent.state != .idle

        return PaneTelemetryDisplay(
            model: model,
            turnCount: turns,
            contextUsedTokens: snap.contextUsedTokens,
            contextLimitTokens: snap.contextLimitTokens,
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
