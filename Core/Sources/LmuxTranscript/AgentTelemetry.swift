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
    private static let claude1MRegex = try? NSRegularExpression(
        pattern: #"(?:opus|sonnet|haiku|fable|mythos)[-.](?:[5-9]|[1-9]\d)(?:$|[-\.@\[])"#
    )

    public static func contextLimit(for model: String?) -> Int {
        guard let model = model?.lowercased() else { return 200_000 }
        if model.contains("gpt-5") { return 272_000 }
        if model.contains("gemini-1.5-pro") || model.contains("gemini-2") || model.contains("gemini-3") || model.contains("gemini-4") {
            return 1_000_000
        }
        if model.contains("claude") {
            if model.contains("[1m]") || model.hasSuffix("-1m") || model.contains("-1m-") {
                return 1_000_000
            }
            if let re = claude1MRegex,
               re.firstMatch(in: model, range: NSRange(model.startIndex..., in: model)) != nil {
                return 1_000_000
            }
            return 200_000
        }
        return 200_000
    }

    private static func matchesVersion(_ model: String, prefix: String, versions: [String]) -> Bool {
        for v in versions {
            let needle = "\(prefix)-\(v)"
            guard let range = model.range(of: needle) else { continue }
            if range.upperBound == model.endIndex { return true }
            let next = model[range.upperBound]
            if next == "-" || next == "." || next == "@" || next == "[" || next == ":" {
                return true
            }
        }
        return false
    }

    public static func estimateCostUSD(
        model: String?,
        input: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int,
        cacheCreation5m: Int? = nil,
        cacheCreation1h: Int? = nil
    ) -> Double? {
        guard let m = model?.lowercased(), !m.isEmpty, m != "<synthetic>" else { return nil }
        // Rates per 1M tokens: (input, cacheWrite5m, cacheWrite1h, cacheRead, output)
        let (inputRate, write5mRate, write1hRate, readRate, outputRate): (Double, Double, Double, Double, Double)
        if m.contains("opus") {
            if matchesVersion(m, prefix: "opus", versions: ["5-5", "5.5"]) {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (4.0, 5.0, 8.0, 0.20, 20.0)
            } else if matchesVersion(m, prefix: "opus", versions: ["4-5", "4.5", "4-6", "4.6", "4-7", "4.7", "4-8", "4.8", "5", "5-0", "5.0"]) {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (5.0, 6.25, 10.0, 0.50, 25.0)
            } else {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (15.0, 18.75, 30.0, 1.50, 75.0)
            }
        } else if m.contains("haiku") {
            if matchesVersion(m, prefix: "haiku", versions: ["5-5", "5.5", "5", "5-0", "5.0"]) {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (0.10, 0.125, 0.20, 0.01, 0.50)
            } else if matchesVersion(m, prefix: "haiku", versions: ["4-5", "4.5", "4"]) {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (1.00, 1.25, 2.00, 0.10, 5.0)
            } else {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (0.80, 1.00, 1.60, 0.08, 4.0)
            }
        } else if m.contains("fable") {
            (inputRate, write5mRate, write1hRate, readRate, outputRate) = (8.0, 10.0, 16.0, 0.20, 40.0)
        } else if m.contains("mythos") {
            (inputRate, write5mRate, write1hRate, readRate, outputRate) = (10.0, 12.5, 20.0, 0.25, 50.0)
        } else if m.contains("sonnet") {
            if matchesVersion(m, prefix: "sonnet", versions: ["5-5", "5.5"]) {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (2.0, 2.50, 4.0, 0.10, 10.0)
            } else if matchesVersion(m, prefix: "sonnet", versions: ["5", "5-0", "5.0"]) {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (2.0, 2.50, 4.0, 0.20, 10.0)
            } else {
                (inputRate, write5mRate, write1hRate, readRate, outputRate) = (3.0, 3.75, 6.0, 0.30, 15.0)
            }
        } else if m.contains("claude") {
            (inputRate, write5mRate, write1hRate, readRate, outputRate) = (3.0, 3.75, 6.0, 0.30, 15.0)
        } else if m.contains("gpt-5") || m.contains("o3") || m.contains("o1") {
            (inputRate, write5mRate, write1hRate, readRate, outputRate) = (5.0, 5.0, 5.0, 1.25, 15.0)
        } else if m.contains("gpt-4") {
            (inputRate, write5mRate, write1hRate, readRate, outputRate) = (2.50, 2.50, 2.50, 1.25, 10.0)
        } else {
            (inputRate, write5mRate, write1hRate, readRate, outputRate) = (3.0, 3.75, 6.0, 0.30, 15.0)
        }

        let writeCost: Double
        if cacheCreation5m != nil || cacheCreation1h != nil {
            let c5 = max(0, cacheCreation5m ?? 0)
            let c1h = max(0, cacheCreation1h ?? 0)
            let unsplit = max(0, cacheCreation - c5 - c1h)
            writeCost = Double(c5 + unsplit) * write5mRate + Double(c1h) * write1hRate
        } else {
            writeCost = Double(cacheCreation) * write5mRate
        }

        let total = (Double(input) * inputRate +
                     writeCost +
                     Double(cacheRead) * readRate +
                     Double(output) * outputRate) / 1_000_000.0
        return total
    }
}
