import Foundation
import Testing
@testable import LmuxTranscript

/// The incremental reader behind hover and titles must agree with the full parser, read
/// only appended bytes on the append path, and start over when the file was rewritten.
@Suite struct TranscriptIndexTests {
    func temp(_ text: String) throws -> URL {
        let dir = TestTemp.dir("lmux-tidx")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    func append(_ s: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(s.utf8))
        try h.close()
    }

    /// Same turns as `Transcript.turns()`, replies loaded lazily from the file.
    func agrees(_ idx: TranscriptIndex, _ url: URL) throws -> Bool {
        let full = try Transcript.load(url).turns()
        let light = idx.turns
        guard full.count == light.count else { return false }
        for (f, l) in zip(full, light) {
            guard f.index == l.index, f.uuid == l.uuid, f.prompt == l.prompt, f.beforeCompaction == l.beforeCompaction,
                  f.assistantUuid == l.assistantUuid, (f.assistantText != nil) == l.hasReply,
                  try idx.reply(l) == f.assistantText else { return false }
        }
        return true
    }

    static let extras = #"{"type":"last-prompt","leafUuid":"as4","explicit":true,"sessionId":"S"}"# + "\n"

    @Test(arguments: [Fixtures.basic, Fixtures.compacted, Fixtures.crossTurnTool, Fixtures.basic + extras,
                      Fixtures.basic + #"{"type":"last-prompt","leafUuid":"as4","sessionId":"S"}"# + "\n",
                      Fixtures.rewoundThenPrompted, Fixtures.explicitThenStraggler,
                      Fixtures.basic + #"{"type":"last-prompt","leafUuid":"int","explicit":true,"sessionId":"S"}"# + "\n"
                          + #"{"parentUuid":"int","isSidechain":false,"type":"user","message":{"role":"user","content":"again"},"uuid":"u9","timestamp":"T11","turnOrigin":"human"}"# + "\n"])
    func agreesWithTheFullParser(_ text: String) throws {
        let url = try temp(text)
        let idx = TranscriptIndex(url: url)
        try idx.update()
        #expect(try agrees(idx, url))
    }

    @Test func appendedLinesOnlyAndPartialLinesWait() throws {
        let lines = Fixtures.basic.components(separatedBy: "\n").filter { !$0.isEmpty }
        let url = try temp("")
        let idx = TranscriptIndex(url: url)
        var written = 0
        for (i, line) in lines.enumerated() {
            // Write each line in two pieces: the first half alone is not a line yet.
            let half = line.utf8.count / 2
            let a = String(decoding: Array(line.utf8)[..<half], as: UTF8.self)
            let b = String(decoding: Array(line.utf8)[half...], as: UTF8.self) + "\n"
            try append(a, to: url)
            let before = idx.bytesParsed
            try idx.update()
            #expect(idx.bytesParsed == before, "a partial line is not parsed (line \(i))")
            try append(b, to: url)
            try idx.update()
            written += line.utf8.count + 1
            #expect(idx.bytesParsed == written, "only the appended line is parsed (line \(i))")
        }
        #expect(try agrees(idx, url))
        // Nothing new: nothing parsed.
        let before = idx.bytesParsed
        try idx.update()
        #expect(idx.bytesParsed == before)
        #expect(idx.fullReads == 1)
    }

    @Test func rewrittenFileIsReadAgain() throws {
        let url = try temp(Fixtures.basic)
        let idx = TranscriptIndex(url: url)
        try idx.update()
        #expect(idx.turns.count == 3)
        // Forget surgery writes a new file (atomic rename = new inode).
        let out = try Transcript.load(url).removing(turnUuid: "u2")
        try out.write(to: url)
        try idx.update()
        #expect(idx.fullReads == 2)
        #expect(idx.turns.map(\.uuid) == ["u1", "u3"])
        #expect(try agrees(idx, url))
        // Same size, same inode, different bytes in place: the tail fingerprint notices.
        var data = try Data(contentsOf: url)
        let r = try #require(data.range(of: Data("third prompt".utf8)))
        data.replaceSubrange(r, with: Data("THIRD PROMPT".utf8))
        let h = try FileHandle(forWritingTo: url)
        try h.write(contentsOf: data)
        try h.close()
        try idx.update()
        #expect(idx.turns.last?.prompt == "THIRD PROMPT")
    }

    @Test func titlesEditsAndPromptsAreKept() throws {
        let text = Fixtures.basic
            + #"{"type":"custom-title","customTitle":"my name","sessionId":"S"}"# + "\n"
            + #"{"type":"ai-title","aiTitle":"AI name","sessionId":"S"}"# + "\n"
        let url = try temp(text)
        let idx = TranscriptIndex(url: url)
        try idx.update()
        #expect(idx.customTitle == "my name" && idx.aiTitle == "AI name")
        #expect(idx.turns.first?.firstLine == "first prompt")
        #expect(try idx.fullPrompt(idx.turns[0]) == "first prompt\nsecond line")
    }

    // Forget offers to delete memory files a turn created: Write results say "type":"create".
    @Test func createdFilesPerTurn() throws {
        let c = Fixtures.common
        let mem = "/cfg/projects/-a/memory/apple.md"
        let text = """
        {"parentUuid":null,\(c),"type":"user","message":{"role":"user","content":"remember APPLE"},"uuid":"u1","timestamp":"T0","turnOrigin":"human"}
        {"parentUuid":"u1",\(c),"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"\(mem)"}}]},"uuid":"as1","timestamp":"T1"}
        {"parentUuid":"as1",\(c),"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"uuid":"tr1","timestamp":"T2","toolUseResult":{"type":"create","filePath":"\(mem)","content":"x"}}
        {"parentUuid":"tr1",\(c),"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/cfg/projects/-a/memory/MEMORY.md"}}]},"uuid":"as2","timestamp":"T3"}
        {"parentUuid":"as2",\(c),"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]},"uuid":"tr2","timestamp":"T4","toolUseResult":{"filePath":"/cfg/projects/-a/memory/MEMORY.md","oldString":"a","newString":"b"}}
        {"parentUuid":"tr2",\(c),"type":"user","message":{"role":"user","content":"next"},"uuid":"u2","timestamp":"T5","turnOrigin":"human"}

        """
        let url = try temp(text)
        let idx = TranscriptIndex(url: url)
        try idx.update()
        #expect(idx.turns.count == 2)
        #expect(idx.turns[0].editedFiles == [mem, "/cfg/projects/-a/memory/MEMORY.md"])
        #expect(idx.turns[0].createdFiles == [mem])
        #expect(idx.turns[1].createdFiles.isEmpty)
    }

    @Test func editedFilesPerTurn() throws {
        let c = Fixtures.common
        let text = """
        {"parentUuid":null,\(c),"type":"user","message":{"role":"user","content":"p1"},"uuid":"u1","timestamp":"T0","turnOrigin":"human"}
        {"parentUuid":"u1",\(c),"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/a/x.ts"}}]},"uuid":"as1","timestamp":"T1"}
        {"parentUuid":"as1",\(c),"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"uuid":"tr1","timestamp":"T2","toolUseResult":{}}
        {"parentUuid":"tr1",\(c),"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"NotebookEdit","input":{"notebook_path":"/a/n.ipynb"}}]},"uuid":"as2","timestamp":"T3"}

        """
        let url = try temp(text)
        let idx = TranscriptIndex(url: url)
        try idx.update()
        #expect(idx.turns.first?.editedFiles == ["/a/x.ts", "/a/n.ipynb"])
    }

    /// A long prompt is kept capped in memory; the full text comes from the file.
    @Test func longPromptsAreCapped() throws {
        let long = String(repeating: "가나다라 ", count: 5000)
        let c = Fixtures.common
        let escaped = String(decoding: try JSONSerialization.data(withJSONObject: [long]), as: UTF8.self).dropFirst().dropLast()
        let text = #"{"parentUuid":null,\#(c),"type":"user","message":{"role":"user","content":\#(escaped)},"uuid":"u1","turnOrigin":"human"}"# + "\n"
        let url = try temp(text)
        let idx = TranscriptIndex(url: url)
        try idx.update()
        let t = try #require(idx.turns.first)
        #expect(t.prompt.count <= TranscriptIndex.promptCap && t.promptIsTruncated)
        #expect(try idx.fullPrompt(t) == long)
    }
}
