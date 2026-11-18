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
        let badLine = #"{"type":"assistant","corrupt": "#
        try (u1 + "\n" + aNoUsage + "\n" + a1 + "\n" + badLine + "\n").write(to: tmp, atomically: true, encoding: .utf8)

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
}
