import Foundation
import Testing
@testable import LmuxTranscript

private func load(_ s: String) -> Transcript { Transcript(data: Data(s.utf8)) }
private func lines(_ t: Transcript) -> [String] { t.entries.map(\.raw) }
private func entry(_ t: Transcript, _ uuid: String) -> Transcript.Entry? { t.entries.first { $0.uuid == uuid } }

@Suite struct TurnListing {
    @Test func listsOnlyHumanPrompts() {
        let turns = load(Fixtures.basic).turns()
        #expect(turns.map(\.uuid) == ["u1", "u2", "u3"])
        #expect(turns.map(\.index) == [1, 2, 3])
        #expect(turns[0].firstLine == "first prompt")
        #expect(turns[0].timestamp == "T1")
        #expect(turns.allSatisfy { !$0.beforeCompaction })
    }

    @Test func finalReplyIsOriginalMarkdownOfLastTextMessage() {
        let turns = load(Fixtures.basic).turns()
        #expect(turns[0].assistantText == "# Result\n\nA long line that\nis hard wrapped.\n\n- item")
        #expect(turns[0].assistantUuid == "as4")
        #expect(turns[1].assistantText == "Second answer")
        #expect(turns[2].assistantText == "Third answer")
    }

    @Test func spanCoversToolResultsMetaAndNonPromptUsers() {
        let turns = load(Fixtures.basic).turns()
        #expect(turns[0].entryUuids == ["u1", "a1", "as1", "as2", "as3", "tr1", "as4", "as5", "s1", "meta1"])
        #expect(turns[1].entryUuids == ["u2", "as6", "bo", "tn", "int"])
    }

    @Test func originalMarkdownByAssistantUuid() throws {
        let t = load(Fixtures.basic)
        #expect(try t.originalMarkdown(forAssistantUuid: "as5") == "# Result\n\nA long line that\nis hard wrapped.\n\n- item")
        #expect(try t.originalMarkdown(forAssistantUuid: "as1") == "Let me check.")
        #expect(throws: Transcript.TranscriptError.self) { try t.originalMarkdown(forAssistantUuid: "u1") }
    }

    @Test func selectorByIndexUuidAndPrefix() throws {
        let t = load(Fixtures.basic)
        #expect(try t.turn(matching: "2").uuid == "u2")
        #expect(try t.turn(matching: "u3").uuid == "u3")
        #expect(throws: Transcript.TranscriptError.turnNotFound("9")) { try t.turn(matching: "9") }
    }

    @Test func compactedTurnsAreFlagged() {
        let turns = load(Fixtures.compacted).turns()
        #expect(turns.map(\.uuid) == ["u0", "u1", "u2"])
        #expect(turns.map(\.beforeCompaction) == [true, false, false])
        #expect(turns[0].entryUuids == ["u0", "as0"])
    }
}

@Suite struct Removal {
    @Test func removeMiddleRelinksNextPrompt() throws {
        let t = load(Fixtures.basic)
        let (out, plan) = try t.removingWithPlan(turnUuid: "u2")
        #expect(out.turns().map(\.uuid) == ["u1", "u3"])
        #expect(entry(out, "u3")?.parentUuid == "meta1")
        #expect(plan.relinked.map(\.uuid) == ["u3"])
        // Off-chain sidechain hanging off the removed span goes too.
        #expect(Set(plan.removedUuids) == ["u2", "as6", "sc1", "sc2", "bo", "tn", "int"])
        #expect(out.turns()[1].assistantText == "Third answer")
    }

    @Test func removeFirstRelinksToPreamble() throws {
        let out = try load(Fixtures.basic).removing(turnUuid: "u1")
        #expect(out.turns().map(\.uuid) == ["u2", "u3"])
        #expect(entry(out, "u2")?.parentUuid == "h1")
        let text = String(decoding: out.serialized(), as: UTF8.self)
        #expect(!text.contains("first prompt"))  // queue-operation and stale last-prompt dropped
        #expect(entry(out, "h1") != nil)
    }

    @Test func removeLastLeavesPreviousTurnAsLeaf() throws {
        let out = try load(Fixtures.basic).removing(turnUuid: "u3")
        #expect(out.turns().map(\.uuid) == ["u1", "u2"])
        #expect(out.turns()[1].assistantText == "Second answer")
        #expect(!lines(out).contains { $0.contains("\"leafUuid\":\"as7\"") })
        #expect(out.entries[out.leafIndex!].uuid == "int")
    }

    @Test func removeOnlyRemainingTurns() throws {
        var t = load(Fixtures.basic)
        for u in ["u2", "u1", "u3"] { t = try t.removing(turnUuid: u) }
        #expect(t.turns().isEmpty)
        #expect(lines(t).contains { $0.contains("weird-future-type") })
    }

    @Test func relinkTouchesOnlyParentUuidBytes() throws {
        let t = load(Fixtures.basic)
        let out = try t.removing(turnUuid: "u2")
        let before = entry(t, "u3")!.raw
        let after = entry(out, "u3")!.raw
        #expect(after == before.replacingOccurrences(of: #""parentUuid":"int""#, with: #""parentUuid":"meta1""#))
    }

    @Test func relinkToNullWhenFirstEntryHadNoParent() throws {
        let firstTwo = Fixtures.compacted.split(separator: "\n").suffix(4).joined(separator: "\n")
            .replacingOccurrences(of: #"{"parentUuid":"cs""#, with: #"{"parentUuid":null"#) + "\n"
        let out = try load(firstTwo).removing(turnUuid: "u1")
        #expect(entry(out, "u2")!.raw.contains(#""parentUuid":null"#))
        #expect(out.turns().map(\.uuid) == ["u2"])
    }

    @Test func untouchedLinesAndUnknownFieldsAreByteIdentical() throws {
        let t = load(Fixtures.basic)
        #expect(t.serialized() == Data(Fixtures.basic.utf8))
        let out = try t.removing(turnUuid: "u2")
        let kept = Set(lines(out))
        let original = lines(t)
        for l in original where l.contains("weird-future-type") || l.contains("futureField") || l.contains("\"uuid\":\"as5\"") {
            #expect(kept.contains(l))
        }
        #expect(String(decoding: out.serialized(), as: UTF8.self).hasSuffix("\n"))
    }

    /// Claude's generated title can be made of the forgotten prompt's words: titles written
    /// after it go, an earlier one and the user's own title stay.
    @Test func generatedTitlesAfterTheRemovedPromptGo() throws {
        let lines = Fixtures.basic.components(separatedBy: "\n")
        let u2 = try #require(lines.firstIndex { $0.contains(#""uuid":"u2""#) })
        var withTitles = lines
        withTitles.insert(#"{"type":"ai-title","aiTitle":"Third prompt about SECOND","sessionId":"S"}"#, at: u2 + 2)
        withTitles.insert(#"{"type":"custom-title","customTitle":"mine","sessionId":"S"}"#, at: u2 + 1)
        withTitles.insert(#"{"type":"ai-title","aiTitle":"First prompt title","sessionId":"S"}"#, at: u2)
        let out = String(decoding: try Transcript(data: Data(withTitles.joined(separator: "\n").utf8))
            .removing(turnUuid: "u2").serialized(), as: UTF8.self)
        #expect(out.contains("First prompt title") && out.contains(#""customTitle":"mine""#))
        #expect(!out.contains("SECOND"))
    }

    @Test func refusesBeforeCompaction() {
        let t = load(Fixtures.compacted)
        #expect(throws: Transcript.TranscriptError.self) { try t.removing(turnUuid: "u0") }
    }

    @Test func removesAfterCompaction() throws {
        let out = try load(Fixtures.compacted).removing(turnUuid: "u1")
        #expect(entry(out, "u2")?.parentUuid == "cs")
        #expect(out.turns().map(\.uuid) == ["u0", "u2"])
    }

    @Test func refusesOrphaningToolResult() {
        let t = load(Fixtures.crossTurnTool)
        #expect(throws: Transcript.TranscriptError.wouldOrphanToolResult("tuX")) { try t.removing(turnUuid: "u1") }
    }

    @Test func refusesUnknownTurn() {
        #expect(throws: Transcript.TranscriptError.turnNotFound("as4")) { try load(Fixtures.basic).removing(turnUuid: "as4") }
    }
}

@Suite struct Leaf {
    @Test func explicitLastPromptWinsOverFileOrder() {
        let s = Fixtures.basic + #"{"type":"last-prompt","leafUuid":"as4","explicit":true,"sessionId":"S"}"# + "\n"
        let t = load(s)
        #expect(t.turns().map(\.uuid) == ["u1"])
    }

    @Test func staleNonExplicitPointerYieldsToDescendant() {
        let s = Fixtures.basic + #"{"type":"last-prompt","leafUuid":"as4","sessionId":"S"}"# + "\n"
        #expect(load(s).turns().count == 3)
    }

    @Test func promptAfterARewindIsTheBranchBeforeThePointerCatchesUp() {
        #expect(load(Fixtures.rewoundThenPrompted).turns().map(\.uuid) == ["u1", "u2", "u4"])
        // …and still once the pointer is on the new branch.
        let caught = Fixtures.rewoundThenPrompted + #"{"type":"last-prompt","leafUuid":"as8","sessionId":"S"}"# + "\n"
        #expect(load(caught).turns().map(\.uuid) == ["u1", "u2", "u4"])
    }

    @Test func explicitPointerYieldsOnceTheChainGoesOn() {
        // An explicit pointer to the spot rewound to, then a new prompt there (Claude Code's loader
        // drops the pointer's explicitness at the next chain entry).
        let s = Fixtures.basic + #"{"type":"last-prompt","leafUuid":"int","explicit":true,"sessionId":"S"}"# + "\n"
            + Fixtures.rewoundThenPrompted.components(separatedBy: "\n").filter { $0.contains(#""uuid":"u4""#) || $0.contains(#""uuid":"as8""#) }
                .joined(separator: "\n") + "\n"
        #expect(load(s).turns().map(\.uuid) == ["u1", "u2", "u4"])
    }

    @Test func explicitPointerHoldsAgainstALateEntryOfTheBranchRewoundAway() {
        #expect(load(Fixtures.explicitThenStraggler).turns().map(\.uuid) == ["u1", "u2"])
    }
}

@Suite struct Writing {
    let dir: URL = TestTemp.dir("lmux")

    @Test func writesAtomicallyWithBackups() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        try Data(Fixtures.basic.utf8).write(to: url)

        let backup = try Transcript.load(url).removing(turnUuid: "u2").write(to: url)
        #expect(backup?.lastPathComponent == "s.jsonl.bak")
        #expect(try Data(contentsOf: backup!) == Data(Fixtures.basic.utf8))
        #expect(try Transcript.load(url).turns().map(\.uuid) == ["u1", "u3"])

        let backup2 = try Transcript.load(url).removing(turnUuid: "u3").write(to: url)
        #expect(backup2?.lastPathComponent == "s.jsonl.bak.2")
        #expect(try Data(contentsOf: backup!) == Data(Fixtures.basic.utf8))
    }

    @Test func refusesWhenFileChangedSinceLoad() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        try Data(Fixtures.basic.utf8).write(to: url)
        let edited = try Transcript.load(url).removing(turnUuid: "u2")
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"type":"last-prompt","leafUuid":"as7"}"#.utf8 + [10]))
        try h.close()
        #expect(throws: Transcript.TranscriptError.fileChangedSinceLoad(url.path)) { try edited.write(to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path + ".bak"))
    }

    /// A BOM and untouched lines survive surgery byte for byte; a file that isn't valid UTF-8
    /// is refused (decoding would replace bytes in lines lmux never touched).
    @Test func bomKeptAndInvalidUTF8Refused() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        let bom = Data([0xEF, 0xBB, 0xBF])
        try (bom + Data(Fixtures.basic.utf8)).write(to: url)
        _ = try Transcript.load(url).removing(turnUuid: "u3").write(to: url)
        let out = try Data(contentsOf: url)
        #expect(out.starts(with: bom))
        let expected = try Transcript(data: Data(Fixtures.basic.utf8)).removing(turnUuid: "u3").serialized()
        #expect(out == bom + expected)

        let bad = Fixtures.basic.replacingOccurrences(of: #""payload":{"a":1"#, with: #""payload":{"a":"@@""#)
        var bytes = Data(bad.utf8)
        let r = try #require(bytes.range(of: Data("@@".utf8)))
        bytes.replaceSubrange(r, with: [0xE2, 0x82])  // a truncated 3-byte sequence in an untouched line
        try bytes.write(to: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
        #expect(throws: Transcript.TranscriptError.notUTF8(url.path)) { try Transcript.load(url).removing(turnUuid: "u3").write(to: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }
}
