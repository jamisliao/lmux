// @feature: inspector-ask-panel.feature
// @scenario: 從 Claude 與 Codex 對話紀錄本機抽取 Session 上下文補充
// @scenario: 對話紀錄缺少、含損毀行或合成佔位訊息時安全降級產生上下文補充
import XCTest
@testable import LmuxTranscript

final class TranscriptContextExtractorTests: XCTestCase {
    func testClaudeExtractionFiltersSyntheticAndCollectsGoalRecentTurnsAndFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lines = [
            #"{"type":"custom-title","customTitle":"修補驗證流程"}"#,
            #"{"type":"user","uuid":"u1","parentUuid":null,"turnOrigin":"human","message":{"role":"user","content":"請重構 AuthService 並補測試"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/repo/Auth.swift"}},{"type":"text","text":"已完成 AuthService 重構。"}]}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","turnOrigin":"human","message":{"role":"user","content":"下一步要處理逾時重試嗎？"}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u2","message":{"id":"m2","role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"Local synthetic notice"}]}}"#,
            #"{"type":"assistant","corrupt":"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let idx = TranscriptIndex(url: tmp)
        _ = try idx.update()
        let summary = TranscriptContextExtractor.extract(title: idx.customTitle ?? idx.aiTitle, turns: idx.turns)

        XCTAssertEqual(summary.sessionTitle, "修補驗證流程")
        XCTAssertEqual(summary.initialGoal, "請重構 AuthService 並補測試")
        XCTAssertEqual(summary.touchedFiles, ["/repo/Auth.swift"])
        XCTAssertEqual(summary.recentTurns.count, 1)
        XCTAssertEqual(summary.recentTurns.first?.promptSummary, "下一步要處理逾時重試嗎？")
        XCTAssertNil(summary.recentTurns.first?.replySummary)
    }

    func testCodexRolloutExtractsPatchAndFunctionCallFilesAndEmptyFallback() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let lines = [
            #"{"timestamp":"2026-11-24T01:00:00Z","type":"session_meta","payload":{"id":"c1","cwd":"/repo","model":"gpt-5.4"}}"#,
            #"{"timestamp":"2026-11-24T01:00:01Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_name":"Codex 修復"}}"#,
            #"{"timestamp":"2026-11-24T01:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"修改 Router.swift"}}"#,
            #"{"timestamp":"2026-11-24T01:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /repo/Router.swift\n@@\n-old\n+new\n*** Add File: /repo/Helper.swift\n+let x = 1\n*** End Patch"}}"#,
            #"{"timestamp":"2026-11-24T01:00:03.500Z","type":"response_item","payload":{"type":"function_call","name":"write_file","arguments":"{\"file_path\":\"/repo/Config.swift\"}"}}"#,
            #"{"timestamp":"2026-11-24T01:00:04Z","type":"event_msg","payload":{"type":"agent_message","message":"已更新 Router 與 Helper。"}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: tmp, atomically: true, encoding: .utf8)

        let rollout = CodexRollout(url: tmp)
        _ = try rollout.update()
        let summary = TranscriptContextExtractor.extract(title: rollout.threadName, turns: rollout.turns)

        XCTAssertEqual(summary.sessionTitle, "Codex 修復")
        XCTAssertEqual(summary.initialGoal, "修改 Router.swift")
        XCTAssertEqual(summary.touchedFiles, ["/repo/Router.swift", "/repo/Helper.swift", "/repo/Config.swift"])
        XCTAssertEqual(TranscriptContextExtractor.extract(title: nil, turns: []).recentTurns, [])
    }
}
