import Foundation
import Testing
@testable import LmuxTranscript

/// Transcript.outline never buffers an unfinished line past its cap, and keeps offsets right.
@Suite struct OutlineCapTests {
    @Test func overlongLineIsSkippedButCounted() throws {
        let dir = TestTemp.dir("outline-cap")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("t.jsonl")
        let big = "{\"type\":\"user\",\"x\":\"" + String(repeating: "a", count: 300_000) + "\"}"
        let small = #"{"type":"user","uuid":"u2"}"#
        try Data((small + "\n" + big + "\n" + small + "\n").utf8).write(to: u)
        let o = try Transcript.outline(u, chunkSize: 4096, maxLine: 64 * 1024)
        #expect(o.lineLengths == [small.utf8.count, big.utf8.count, small.utf8.count])
        #expect(o.bytes == small.utf8.count * 2 + big.utf8.count + 3)
        #expect(o.transcript.entries.count == 3 && o.transcript.entries[1].object == nil
                && o.transcript.entries[2].object != nil)
        // Without the cap the same file parses all three.
        let full = try Transcript.outline(u, chunkSize: 4096)
        #expect(full.transcript.entries[1].object != nil && full.lineLengths == o.lineLengths)
    }
}
