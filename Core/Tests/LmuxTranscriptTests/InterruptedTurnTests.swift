import Foundation
import Testing
@testable import LmuxTranscript

/// Turns stopped with Esc, captured from the real Claude Code 2.1.280 CLI against a local mock
/// API (Fixtures/interrupted-*.jsonl, paths and attachment payloads trimmed):
/// - text / tool / image-*: Esc while the reply streamed or a tool ran. The chain ends with a
///   `[Request interrupted by user]` (or `… for tool use]`) user record; a tool gets a
///   "User rejected tool use" tool_result first. No Stop hook is sent.
/// - thinking / early-image: Esc before any reply text. Claude puts the prompt back into the
///   input box; the prompt record stays in the chain without a reply and without a marker.
/// - image-tool-followed: the interrupted turn, then another prompt answered normally.
@Suite struct InterruptedTurnTests {
    func fixture(_ name: String) throws -> URL {
        let src = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        let dir = TestTemp.dir("lmux-int")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.jsonl")
        try FileManager.default.copyItem(at: src, to: url)
        return url
    }

    static let marked: [(String, String)] = [
        ("interrupted-text", "TEXT please"), ("interrupted-tool", "TOOL please"),
        ("interrupted-image-text", "[Image #1] TEXT please"), ("interrupted-image-tool", "[Image #1] TOOL please"),
    ]

    @Test(arguments: marked)
    func interruptedTurnIsMarked(name: String, prompt: String) throws {
        let idx = TranscriptIndex(url: try fixture(name))
        try idx.update()
        let t = try #require(idx.turns.last)
        #expect(idx.turns.count == 1)
        #expect(t.firstLine == prompt)
        #expect(t.interrupted, "Esc's marker ends the turn: Claude is no longer working on it")
    }

    /// What lmux does after Esc: the index read while the reply streamed, then only the appended
    /// tail once the marker lands. The turn is running before and interrupted after.
    @Test(arguments: marked.map(\.0))
    func markerAppendedLaterIsSeenIncrementally(name: String) throws {
        let url = try fixture(name)
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let cut = try #require(lines.lastIndex { String(decoding: $0, as: UTF8.self).contains("[Request interrupted by user") })
        let head = lines[..<cut].map { Data($0) + Data([0x0A]) }.reduce(Data(), +)
        try head.write(to: url)
        let idx = TranscriptIndex(url: url)
        try idx.update()
        #expect(idx.turns.count == 1 && idx.turns.last?.interrupted == false)
        try data.write(to: url)
        try idx.update()
        #expect(idx.turns.count == 1 && idx.turns.last?.interrupted == true)
        #expect(idx.fullReads == 1 && idx.bytesParsed == data.count, "only the tail was read")
    }

    @Test(arguments: ["interrupted-thinking", "interrupted-early-image"])
    func esc_before_any_reply_leaves_an_unanswered_turn(name: String) throws {
        let idx = TranscriptIndex(url: try fixture(name))
        try idx.update()
        let t = try #require(idx.turns.last)
        #expect(idx.turns.count == 1 && !t.hasReply && !t.interrupted)
    }

    @Test func onlyTheInterruptedTurnIsMarked() throws {
        let idx = TranscriptIndex(url: try fixture("interrupted-image-tool-followed"))
        try idx.update()
        #expect(idx.turns.map(\.interrupted) == [true, false])
        #expect(idx.turns.map(\.firstLine) == ["[Image #1] TOOL please", "follow up"])
    }

    /// Forgetting removes the prompt, its image-source meta record, the partial reply, the
    /// tool_use and its rejected tool_result, and the interrupt marker; nothing of it is left.
    @Test(arguments: marked.map(\.0) + ["interrupted-thinking", "interrupted-early-image"])
    func forgetRemovesEverythingOfTheTurn(name: String) throws {
        let url = try fixture(name)
        let t = try Transcript.load(url)
        let turn = try #require(t.turns().first)
        let (out, plan) = try t.removingWithPlan(turnUuid: turn.uuid)
        try out.checkToolPairs()
        #expect(out.turns().isEmpty)
        let text = String(decoding: out.serialized(), as: UTF8.self)
        for gone in ["please", "Request interrupted", "partial answer", "Running it.", "sleep 30", "User rejected",
                     "\"type\":\"image\"", "[Image: source"] {
            #expect(!text.contains(gone), "\(gone) left after forgetting \(name)")
        }
        #expect(plan.removedUuids.contains(turn.uuid))
        // Every remaining chain entry still resolves to an existing parent.
        let uuids = Set(out.entries.compactMap(\.uuid))
        for e in out.entries where e.isChainNode { if let p = e.parentUuid { #expect(uuids.contains(p)) } }
    }

    @Test func forgetInterruptedTurnKeepsTheNextOne() throws {
        let url = try fixture("interrupted-image-tool-followed")
        let t = try Transcript.load(url)
        let first = try #require(t.turns().first)
        let (out, _) = try t.removingWithPlan(turnUuid: first.uuid)
        try out.checkToolPairs()
        let left = out.turns()
        #expect(left.map(\.prompt) == ["follow up"] && left.first?.assistantText == "Done.")
        let text = String(decoding: out.serialized(), as: UTF8.self)
        #expect(!text.contains("TOOL please") && !text.contains("Request interrupted") && !text.contains("User rejected"))
        // The index reads the rewritten file the same way.
        try out.write(to: url)
        let idx = TranscriptIndex(url: url)
        try idx.update()
        #expect(idx.turns.map(\.firstLine) == ["follow up"] && idx.turns.map(\.interrupted) == [false])
    }
}
