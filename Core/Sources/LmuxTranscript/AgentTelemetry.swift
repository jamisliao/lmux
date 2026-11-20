import Foundation

public struct AgentTelemetrySnapshot: Sendable, Equatable {
    public var model: String?
    public var turnCount: Int
    public var contextUsedTokens: Int
    public var contextLimitTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var estimatedCostUSD: Double?
    public var contextPercent: Double {
        guard contextLimitTokens > 0 else { return 0.0 }
        return Double(contextUsedTokens) / Double(contextLimitTokens)
    }
    public var updatedAt: Date?

    public init(
        model: String? = nil,
        turnCount: Int = 0,
        contextUsedTokens: Int = 0,
        contextLimitTokens: Int = 200_000,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        estimatedCostUSD: Double? = nil,
        updatedAt: Date? = nil
    ) {
        self.model = model
        self.turnCount = turnCount
        self.contextUsedTokens = contextUsedTokens
        self.contextLimitTokens = contextLimitTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.updatedAt = updatedAt
    }
}

public enum ModelPricing: Sendable {
    public static func contextLimit(for model: String?) -> Int {
        guard let model = model?.lowercased() else { return 200_000 }
        if model.contains("gpt-5") { return 272_000 }
        if model.contains("gemini-1.5-pro") || model.contains("gemini-2") { return 1_000_000 }
        if model.contains("claude") {
            return (model.contains("[1m]") || model.hasSuffix("-1m") || model.contains("-1m-")) ? 1_000_000 : 200_000
        }
        return 200_000
    }

    public static func estimateCostUSD(
        model: String?,
        input: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int
    ) -> Double? {
        guard let m = model?.lowercased() else { return nil }
        let (inputRate, writeRate, readRate, outputRate): (Double, Double, Double, Double)
        if m.contains("opus") {
            (inputRate, writeRate, readRate, outputRate) = (15.0, 18.75, 1.50, 75.0)
        } else if m.contains("haiku") {
            (inputRate, writeRate, readRate, outputRate) = (0.80, 1.00, 0.08, 4.0)
        } else if m.contains("sonnet") || m.contains("claude") {
            (inputRate, writeRate, readRate, outputRate) = (3.0, 3.75, 0.30, 15.0)
        } else if m.contains("gpt-5") || m.contains("o3") || m.contains("o1") {
            (inputRate, writeRate, readRate, outputRate) = (5.0, 5.0, 1.25, 15.0)
        } else if m.contains("gpt-4") {
            (inputRate, writeRate, readRate, outputRate) = (2.50, 2.50, 1.25, 10.0)
        } else {
            (inputRate, writeRate, readRate, outputRate) = (3.0, 3.75, 0.30, 15.0)
        }
        let total = (Double(input) * inputRate +
                     Double(cacheCreation) * writeRate +
                     Double(cacheRead) * readRate +
                     Double(output) * outputRate) / 1_000_000.0
        return total
    }
}
