import Foundation
import Testing
@testable import LmuxTranscript

@Suite struct CodexRolloutTests {
    func write(_ text: String, _ name: String = "rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-2fd9b2ca2250.jsonl") throws -> URL {
        let dir = TestTemp.dir("codex-rollout")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try Data((text + "\n").utf8).write(to: u)
        return u
    }

    /// A Codex ≤ 0.12x rollout: `user_message` / `agent_message` events (commentary, then the
    /// final answer), `thread_name_updated`, injected context as `response_item`s, two turns.
    static let older = [
        #"{"timestamp":"2026-04-27T06:58:53.456Z","type":"session_meta","payload":{"id":"019dcdbb-d98c-7fe3-92d9-3b1dccb82150","timestamp":"2026-04-27T06:58:53.456Z","cwd":"/Users/me/repo","originator":"codex_cli_rs","cli_version":"0.123.0","source":"cli","git":{"branch":"main"}}}"#,
        #"{"timestamp":"2026-04-27T06:58:53.524Z","type":"event_msg","payload":{"type":"thread_name_updated","thread_id":"019dcdbb-d98c-7fe3-92d9-3b1dccb82150","thread_name":"환불 금액 검증"}}"#,
        #"{"timestamp":"2026-04-27T06:58:53.600Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/Users/me/repo</cwd>\n</environment_context>"}]}}"#,
        #"{"timestamp":"2026-04-27T06:58:54.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"부분환불할 때 금액 검증이 빠져 있어. refund.ts 보고 고쳐줘"}]}}"#,
        #"{"timestamp":"2026-04-27T06:58:54.001Z","type":"event_msg","payload":{"type":"user_message","message":"부분환불할 때 금액 검증이 빠져 있어. refund.ts 보고 고쳐줘","images":[]}}"#,
        #"{"timestamp":"2026-04-27T06:58:56.000Z","type":"event_msg","payload":{"type":"agent_message","message":"refund.ts 읽는 중이에요.","phase":"commentary"}}"#,
        ###"{"timestamp":"2026-04-27T06:59:10.000Z","type":"event_msg","payload":{"type":"agent_message","message":"## 고쳤어요\n\n- `amount <= paid` 검사를 추가했어요.","phase":"final_answer"}}"###,
        ###"{"timestamp":"2026-04-27T06:59:10.100Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"## 고쳤어요\n\n- `amount <= paid` 검사를 추가했어요."}]}}"###,
        #"{"timestamp":"2026-04-27T07:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"테스트도 추가해줘","images":[]}}"#,
        #"{"timestamp":"2026-04-27T07:00:05.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Added `refund.test.ts`.","phase":"commentary"}}"#,
    ].joined(separator: "\n")

    @Test func currentFormat() throws {
        let r = CodexRollout(url: try write(CodexRollouts.readNote))
        #expect(try r.update())
        #expect(r.meta.id == "01a19afa-3664-79f1-b4d9-2fd9b2ca2250" && r.meta.cwd == "/Users/me/proj" && r.meta.cliVersion == "0.166.0")
        #expect(r.turns.count == 1)
        let t = try #require(r.turns.first)
        #expect(t.prompt == "Run `cat note.txt` and reply in markdown: a heading **Result** and the word it printed.")
        #expect(t.uuid == "01a19afa-368a-7b60-8685-019d8bfac4bf" && t.hasReply)
        #expect(try r.reply(t) == "# Result\n\nhello")
        // The interrupted session: no final answer, so its last commentary is the turn's reply.
        let i = CodexRollout(url: try write(CodexRollouts.createMade))
        try i.update()
        #expect(i.turns.count == 1 && i.turns[0].prompt.hasPrefix("Create a file named made.txt"))
        #expect(try i.reply(i.turns[0]) == "I\u{2019}ll create `made.txt` in the workspace with exactly `lmux`.")
    }

    @Test func olderFormat() throws {
        let r = CodexRollout(url: try write(Self.older))
        try r.update()
        #expect(r.threadName == "환불 금액 검증" && r.meta.gitBranch == "main")
        #expect(r.turns.map { $0.prompt } == ["부분환불할 때 금액 검증이 빠져 있어. refund.ts 보고 고쳐줘", "테스트도 추가해줘"])
        // The final answer wins over commentary; a turn with only commentary falls back to it.
        #expect(try r.reply(r.turns[0]) == "## 고쳤어요\n\n- `amount <= paid` 검사를 추가했어요.")
        #expect(try r.reply(r.turns[1]) == "Added `refund.test.ts`.")
        #expect(r.turns[0].uuid.hasPrefix("codex@"))
        let p = try CodexRollout.parse(r.url)
        #expect(p.turns.count == 2 && p.turns[0].assistantText == "## 고쳤어요\n\n- `amount <= paid` 검사를 추가했어요.")
        #expect(p.turns.map { $0.uuid } == r.turns.map { $0.uuid })
        #expect(p.firstTimestamp != nil && p.lastTimestamp! > p.firstTimestamp!)
    }

    /// A 20 MB single line: read in linear time (each chunk appended once, never the whole carry
    /// again), and with a cap below it, skipped without buffering while the lines around it parse.
    @Test func hugeLineIsLinearAndCapped() throws {
        let lines = CodexRollouts.readNote.split(separator: "\n").map(String.init)
        let huge = #"{"timestamp":"2026-11-02T15:37:40.000Z","type":"event_msg","payload":{"type":"agent_message","message":""#
            + String(repeating: "x", count: 20 << 20) + #"","phase":"commentary"}}"#
        let text = ([lines[0], huge] + lines.dropFirst()).joined(separator: "\n")
        let start = Date()
        let r = CodexRollout(url: try write(text))
        try r.update()
        let took = Date().timeIntervalSince(start)
        #expect(r.turns.count == 1 && r.meta.id == "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", "parsed")
        #expect(took < 5, "20 MB line read in \(took) s")

        let capped = CodexRollout(url: r.url)
        capped.maxLine = 1 << 20
        try capped.update()
        #expect(capped.turns.count == 1 && capped.bytesParsed == Data((text + "\n").utf8).count)
        #expect(try capped.reply(capped.turns[0]) == "# Result\n\nhello")

        // The over-long line still unfinished at the end of the file: dropped, then its rest skipped.
        let partial = r.url.deletingLastPathComponent().appendingPathComponent("rollout-2026-11-02T15-37-31-01a19afa-3664-79f1-b4d9-000000000001.jsonl")
        try Data((lines[0] + "\n" + String(huge.prefix(3 << 20))).utf8).write(to: partial)
        let p = CodexRollout(url: partial)
        p.maxLine = 1 << 20
        try p.update()
        let h = try FileHandle(forWritingTo: partial)
        try h.seekToEnd()
        try h.write(contentsOf: Data((String(huge.dropFirst(3 << 20)) + "\n" + lines.dropFirst().joined(separator: "\n") + "\n").utf8))
        try h.close()
        try p.update()
        #expect(p.fullReads == 1 && p.turns.count == 1, "appended across the skipped line")
    }

    @Test func subagentSessionsAreMarked() throws {
        let line = #"{"timestamp":"2026-04-23T07:35:09.610Z","type":"session_meta","payload":{"id":"019db943-9e26-7601-8a54-39162d0a2036","cwd":"/r","cli_version":"0.123.0","source":{"subagent":"review"}}}"#
        let p = try CodexRollout.parse(try write(line))
        #expect(p.meta.isSubagent && p.turns.isEmpty)
    }

    @Test func incrementalReadsOnlyAppendedBytes() throws {
        let lines = CodexRollouts.readNote.split(separator: "\n").map(String.init)
        let u = try write(lines.prefix(4).joined(separator: "\n"))
        let r = CodexRollout(url: u)
        try r.update()
        let first = r.bytesParsed
        #expect(r.turns.count == 1 && !r.turns[0].hasReply)
        let h = try FileHandle(forWritingTo: u)
        try h.seekToEnd()
        try h.write(contentsOf: Data((lines.dropFirst(4).joined(separator: "\n") + "\n").utf8))
        try h.close()
        #expect(try r.update())
        let size = (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as! NSNumber).intValue
        #expect(r.fullReads == 1 && r.bytesParsed == size)
        #expect(r.bytesParsed > first && r.turns.count == 1 && r.turns[0].hasReply)
        #expect(try r.update() == false)
        // Rewritten (not appended): read again from the start.
        try Data((Self.older + "\n").utf8).write(to: u)
        try r.update()
        #expect(r.fullReads == 2 && r.turns.count == 2)
    }

    @Test func longPromptsAreCappedAndReadBackWhole() throws {
        let long = String(repeating: "가나다라 ", count: 1200)
        let esc = String(decoding: try JSONSerialization.data(withJSONObject: [long]), as: UTF8.self).dropFirst().dropLast()
        let text = #"{"timestamp":"2026-04-27T07:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"#
            + esc + "}}"
        let r = CodexRollout(url: try write(text))
        try r.update()
        #expect(r.turns[0].promptIsTruncated && r.turns[0].prompt.count == TranscriptIndex.promptCap)
        #expect(try r.fullPrompt(r.turns[0]) == long)
    }

    @Test func threadNames() throws {
        let u = try write(CodexRollouts.sessionIndex + "\n" + #"{"id":"01a19af7-a41b-7be0-a747-28b261b34a33","thread_name":"made.txt 만들기","updated_at":"2026-11-02T07:00:00Z"}"#,
                          "session_index.jsonl")
        #expect(CodexThreadNames.name(of: "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", in: u) == "Read note.txt")
        // The newest line naming a session wins.
        #expect(CodexThreadNames.name(of: "01a19af7-a41b-7be0-a747-28b261b34a33", in: u) == "made.txt 만들기")
        #expect(CodexThreadNames.all(u)["01a19af7-a41b-7be0-a747-28b261b34a33"] == "made.txt 만들기")
        #expect(CodexThreadNames.name(of: "nope", in: u) == nil)
        // Across chunk boundaries (lines split between 64KB reads).
        var big = ""
        for i in 0..<3000 { big += #"{"id":"filler-\#(i)","thread_name":"filler \#(i) padding padding","updated_at":"x"}"# + "\n" }
        let b = try write(#"{"id":"first","thread_name":"the very first","updated_at":"x"}"# + "\n" + big + CodexRollouts.sessionIndex,
                          "session_index.jsonl")
        #expect(CodexThreadNames.name(of: "first", in: b) == "the very first")
        #expect(CodexThreadNames.name(of: "filler-1500", in: b) == "filler 1500 padding padding")
        #expect(CodexThreadNames.name(of: "01a19afa-3664-79f1-b4d9-2fd9b2ca2250", in: b) == "Read note.txt")
    }
}
