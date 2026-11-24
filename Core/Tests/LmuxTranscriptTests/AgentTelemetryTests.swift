// @feature: liquid-glass-app.feature
// @scenario: 增量解析 Claude 與 Codex 對話紀錄取得模型、Turn 與 Token 用量
// @scenario: 對話紀錄缺少用量欄位或格式損毀行時安全降級不拋錯
import XCTest
@testable import LmuxTranscript

final class AgentTelemetryTests: XCTestCase {
    func testClaudeIncrementalTelemetryExtractsAppendOnlyAndClampsInvalidUsage() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let u1 = #"{"type":"user","uuid":"u1","parentUuid":null,"turnOrigin":"human","message":{"role":"user","content":"hi"}}"#
        let aNoUsage = #"{"type":"assistant","uuid":"a0","parentUuid":"u1","message":{"id":"m0","role":"assistant","model":"claude-sonnet-4-20250514","content":[{"type":"text","text":"..."}]}}"#
        let a1 = #"{"type":"assistant","uuid":"a1","parentUuid":"a0","message":{"id":"m1","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":2000,"output_tokens":300},"content":[{"type":"text","text":"hello"}]}}"#
        let a1SecondBlock = #"{"type":"assistant","uuid":"a1b","parentUuid":"a1","message":{"id":"m1","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":2000,"output_tokens":300},"content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}]}}"#
        let aSidechain = #"{"type":"assistant","uuid":"as1","parentUuid":"a1b","isSidechain":true,"message":{"id":"ms1","role":"assistant","model":"claude-haiku-3-5","usage":{"input_tokens":9000,"output_tokens":999},"content":[{"type":"text","text":"side"}]}}"#
        let uSidechain = #"{"type":"user","uuid":"us1","parentUuid":"as1","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}"#
        let badLine = #"{"type":"assistant","corrupt": "#
        try (u1 + "\n" + aNoUsage + "\n" + a1 + "\n" + a1SecondBlock + "\n" + aSidechain + "\n" + uSidechain + "\n" + badLine + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let idx = TranscriptIndex(url: tmp)
        _ = try idx.update()
        XCTAssertEqual(idx.fullReads, 1)
        XCTAssertEqual(idx.telemetry.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(idx.telemetry.turnCount, 1)
        XCTAssertEqual(idx.telemetry.contextUsedTokens, 3500)
        XCTAssertEqual(idx.telemetry.cacheReadTokens, 2000)
        XCTAssertEqual(idx.telemetry.outputTokens, 300)
        XCTAssertEqual(idx.telemetry.contextLimitTokens, 200_000)
        XCTAssertNotNil(idx.telemetry.estimatedCostUSD)
        XCTAssertEqual(idx.telemetry.estimatedCostUSD ?? -1, 0.009975, accuracy: 0.000001)

        let firstParsed = idx.bytesParsed
        let u2 = #"{"type":"user","uuid":"u2","parentUuid":"a1","turnOrigin":"human","message":{"role":"user","content":"next"}}"#
        let a2 = #"{"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"id":"m2","role":"assistant","model":"claude-opus-4-1","usage":{"input_tokens":-50,"cache_creation_input_tokens":100,"cache_read_input_tokens":4000,"output_tokens":200},"content":[{"type":"text","text":"done"}]}}"#
        let h = try FileHandle(forUpdating: tmp)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data((u2 + "\n" + a2 + "\n").utf8))

        _ = try idx.update()
        XCTAssertEqual(idx.fullReads, 1)
        XCTAssertGreaterThan(idx.bytesParsed, firstParsed)
        XCTAssertEqual(idx.telemetry.model, "claude-opus-4-1")
        XCTAssertEqual(idx.telemetry.turnCount, 2)
        XCTAssertEqual(idx.telemetry.contextUsedTokens, 4100)
        XCTAssertEqual(idx.telemetry.inputTokens, 0)
        XCTAssertEqual(idx.telemetry.outputTokens, 500)

        // Streaming update for same msgID replaces previous output_tokens/cost instead of double counting
        let a2Stream = #"{"type":"assistant","uuid":"a2b","parentUuid":"a2","message":{"id":"m2","role":"assistant","model":"claude-opus-4-1","usage":{"input_tokens":0,"cache_creation_input_tokens":100,"cache_read_input_tokens":4000,"output_tokens":350},"content":[{"type":"text","text":"done updated"}]}}"#
        let hStream = try FileHandle(forUpdating: tmp)
        defer { try? hStream.close() }
        try hStream.seekToEnd()
        try hStream.write(contentsOf: Data((a2Stream + "\n").utf8))
        _ = try idx.update()
        XCTAssertEqual(idx.fullReads, 1)
        XCTAssertEqual(idx.telemetry.outputTokens, 650)

        // Transcript rewrite/truncation triggers full re-read and resets accumulated totals
        let uReset = #"{"type":"user","uuid":"ur1","parentUuid":null,"turnOrigin":"human","message":{"role":"user","content":"fresh"}}"#
        let aReset = #"{"type":"assistant","uuid":"ar1","parentUuid":"ur1","message":{"id":"mr1","role":"assistant","model":"claude-sonnet-4-6[1m]","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"text","text":"reset"}]}}"#
        try (uReset + "\n" + aReset + "\n").write(to: tmp, atomically: true, encoding: .utf8)
        _ = try idx.update()
        XCTAssertEqual(idx.fullReads, 2)
        XCTAssertEqual(idx.telemetry.turnCount, 1)
        XCTAssertEqual(idx.telemetry.outputTokens, 50)
        XCTAssertEqual(idx.telemetry.contextLimitTokens, 1_000_000)
    }

    func testModelPricingLimitsCostsAndContextPercentEdgeCases() throws {
        XCTAssertEqual(ModelPricing.contextLimit(for: nil), 200_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "gpt-5.3-codex"), 272_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "gemini-1.5-pro"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "gemini-2.5-pro"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "claude-sonnet-4-6[1m]"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "claude-sonnet-4-6"), 200_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "claude-opus-5-5"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "claude-sonnet-5-5"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "claude-haiku-5-5"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "claude-fable-5-2"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "claude-mythos-5-1"), 1_000_000)
        XCTAssertEqual(ModelPricing.contextLimit(for: "claude-opus-4-8"), 200_000)

        XCTAssertNil(ModelPricing.estimateCostUSD(model: nil, input: 100, output: 100))
        XCTAssertNil(ModelPricing.estimateCostUSD(model: "<synthetic>", input: 100, output: 100))
        XCTAssertEqual(ModelPricing.estimateCostUSD(model: "claude-3-5-haiku", input: 1_000_000, output: 1_000_000) ?? -1, 4.80, accuracy: 0.0001)
        XCTAssertEqual(ModelPricing.estimateCostUSD(model: "claude-opus-5-5", input: 6, cacheCreation: 44_456, cacheRead: 124_646, output: 1_351, cacheCreation5m: 0, cacheCreation1h: 44_456) ?? -1, 0.4076212, accuracy: 0.0000001)
        XCTAssertEqual(ModelPricing.estimateCostUSD(model: "claude-sonnet-5-5", input: 10_152, cacheCreation: 899_651, cacheRead: 63_972_819, output: 133_965, cacheCreation5m: 0, cacheCreation1h: 899_651) ?? -1, 11.3558399, accuracy: 0.000001)
        XCTAssertEqual(ModelPricing.estimateCostUSD(model: "claude-opus-4-6", input: 1_000_000, cacheCreation: 0, cacheRead: 1_000_000, output: 1_000_000) ?? -1, 30.50, accuracy: 0.0001)
        XCTAssertEqual(ModelPricing.estimateCostUSD(model: "claude-haiku-5-5", input: 1_070, output: 20) ?? -1, 0.000117, accuracy: 0.000001)
        XCTAssertEqual(ModelPricing.estimateCostUSD(model: "gpt-4o", input: 1_000_000, output: 1_000_000) ?? -1, 12.50, accuracy: 0.0001)

        // Synthetic assistant entries must not overwrite valid model or reset contextUsedTokens
        let synTmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: synTmp) }
        let sUser = #"{"type":"user","uuid":"su1","parentUuid":null,"turnOrigin":"human","message":{"role":"user","content":"hi"}}"#
        let sReal = #"{"type":"assistant","uuid":"sa1","parentUuid":"su1","message":{"id":"sm1","role":"assistant","model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1873,"cache_read_input_tokens":526986,"output_tokens":393,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1873}},"content":[{"type":"text","text":"ok"}]}}"#
        let sSyn = #"{"type":"assistant","uuid":"sa2","parentUuid":"sa1","message":{"id":"sm2","role":"assistant","model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"local"}]}}"#
        try (sUser + "\n" + sReal + "\n" + sSyn + "\n").write(to: synTmp, atomically: true, encoding: .utf8)
        let synIdx = TranscriptIndex(url: synTmp)
        _ = try synIdx.update()
        XCTAssertEqual(synIdx.telemetry.model, "claude-opus-5-5")
        XCTAssertEqual(synIdx.telemetry.contextLimitTokens, 1_000_000)
        XCTAssertEqual(synIdx.telemetry.contextUsedTokens, 528_861)
        XCTAssertEqual(synIdx.telemetry.contextPercent, 0.528861, accuracy: 0.000001)

        let zeroLimit = AgentTelemetrySnapshot(contextUsedTokens: 500, contextLimitTokens: 0)
        XCTAssertEqual(zeroLimit.contextPercent, 0.0)
    }

    func testCodexRolloutParsesTokenCountIncrementallyAndViaStaticParse() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let meta = #"{"timestamp":"2026-11-18T00:00:00Z","type":"session_meta","payload":{"id":"s1","cwd":"/tmp","model":"gpt-5.3-codex"}}"#
        let u1 = #"{"timestamp":"2026-11-18T00:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"fix bug"}}"#
        let tok1 = #"{"timestamp":"2026-11-18T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":272000,"last_token_usage":{"input_tokens":12000,"cached_input_tokens":8000,"output_tokens":450}}}}"#
        let bad = #"{"type":"event_msg","broken": "#
        try (meta + "\n" + u1 + "\n" + tok1 + "\n" + bad + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let rollout = CodexRollout(url: tmp)
        _ = try rollout.update()
        XCTAssertEqual(rollout.fullReads, 1)
        XCTAssertEqual(rollout.telemetry.model, "gpt-5.3-codex")
        XCTAssertEqual(rollout.telemetry.turnCount, 1)
        XCTAssertEqual(rollout.telemetry.contextUsedTokens, 12000)
        XCTAssertEqual(rollout.telemetry.cacheReadTokens, 8000)
        XCTAssertEqual(rollout.telemetry.contextLimitTokens, 272_000)
        XCTAssertEqual(rollout.telemetry.estimatedCostUSD ?? -1, 0.03675, accuracy: 0.000001)

        // Same-model turn_context must NOT clobber authoritative model_context_window (272_000 -> heuristic 200_000)
        let sameCtx = #"{"timestamp":"2026-11-18T00:00:02.500Z","type":"turn_context","payload":{"model":"gpt-5.3-codex"}}"#
        let hSame = try FileHandle(forUpdating: tmp)
        defer { try? hSame.close() }
        try hSame.seekToEnd()
        try hSame.write(contentsOf: Data((sameCtx + "\n").utf8))
        _ = try rollout.update()
        XCTAssertEqual(rollout.telemetry.model, "gpt-5.3-codex")
        XCTAssertEqual(rollout.telemetry.contextLimitTokens, 272_000)

        let firstBytes = rollout.bytesParsed
        let ctx = #"{"timestamp":"2026-11-18T00:00:03Z","type":"turn_context","payload":{"model":"o3"}}"#
        let u2 = #"{"timestamp":"2026-11-18T00:00:04Z","type":"event_msg","payload":{"type":"user_message","message":"again"}}"#
        let tok2 = #"{"timestamp":"2026-11-18T00:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":200000,"last_token_usage":{"input_tokens":-10,"cached_input_tokens":5000,"output_tokens":100}}}}"#
        let h = try FileHandle(forUpdating: tmp)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data((ctx + "\n" + u2 + "\n" + tok2 + "\n").utf8))

        _ = try rollout.update()
        XCTAssertEqual(rollout.fullReads, 1)
        XCTAssertGreaterThan(rollout.bytesParsed, firstBytes)
        XCTAssertEqual(rollout.telemetry.model, "o3")
        XCTAssertEqual(rollout.telemetry.turnCount, 2)
        XCTAssertEqual(rollout.telemetry.contextUsedTokens, 0)
        XCTAssertEqual(rollout.telemetry.inputTokens, 0)
        XCTAssertEqual(rollout.telemetry.outputTokens, 550)
        XCTAssertEqual(rollout.telemetry.contextLimitTokens, 200_000)

        // Zero/invalid model_context_window must preserve previous valid contextLimitTokens
        let tokZeroWindow = #"{"timestamp":"2026-11-18T00:00:06Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":0,"last_token_usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":10}}}}"#
        let hZero = try FileHandle(forUpdating: tmp)
        defer { try? hZero.close() }
        try hZero.seekToEnd()
        try hZero.write(contentsOf: Data((tokZeroWindow + "\n").utf8))
        _ = try rollout.update()
        XCTAssertEqual(rollout.telemetry.contextLimitTokens, 200_000)

        let whole = try CodexRollout.parse(tmp)
        XCTAssertEqual(whole.telemetry.model, "o3")
        XCTAssertEqual(whole.telemetry.turnCount, 2)
        XCTAssertEqual(whole.telemetry.contextLimitTokens, 200_000)
    }
}
