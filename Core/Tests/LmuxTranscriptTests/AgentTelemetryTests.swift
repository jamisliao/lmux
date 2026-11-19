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
        let badLine = #"{"type":"assistant","corrupt": "#
        try (u1 + "\n" + aNoUsage + "\n" + a1 + "\n" + a1SecondBlock + "\n" + aSidechain + "\n" + badLine + "\n").write(to: tmp, atomically: true, encoding: .utf8)

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
        XCTAssertEqual(rollout.telemetry.outputTokens, 550)

        let whole = try CodexRollout.parse(tmp)
        XCTAssertEqual(whole.telemetry.model, "o3")
        XCTAssertEqual(whole.telemetry.turnCount, 2)
    }
}
