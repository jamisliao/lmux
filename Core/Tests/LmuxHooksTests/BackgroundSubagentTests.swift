import Foundation
import Testing
@testable import LmuxHooks

/// Background subagents: a main-agent Stop whose `background_tasks` lists subagents pauses the turn.
/// Entry fields per https://code.claude.com/docs/en/hooks (Stop input): id, type, status, description.
@Suite struct BackgroundSubagentTests {
    /// A main-agent Stop with `background_tasks`: `subagents` as type "subagent", `shells` as type "shell".
    func mainStop(subagents: [String] = [], shells: [String] = []) -> String {
        let entries: [String] = subagents.map { #"{"id":"\#($0)","type":"subagent","status":"running","description":"research"}"# }
            + shells.map { #"{"id":"\#($0)","type":"shell","status":"running","description":"npm run dev"}"# }
        return Payloads.json("Stop", #""stop_hook_active":false,"last_assistant_message":"Turn over.","background_tasks":["#
            + entries.joined(separator: ",") + "]")
    }

    @Test func parsesBackgroundSubagentIDs() throws {
        // No field (older Claude Code, Codex): nil, so the old behavior stays.
        #expect(try event(Payloads.stop).backgroundSubagentIDs == nil)
        #expect(try event(Payloads.json("Stop", #""background_tasks":"oops""#)).backgroundSubagentIDs == nil)
        #expect(try event(mainStop()).backgroundSubagentIDs == [String]())
        // Only type "subagent" with a non-empty id counts; shells, monitors and malformed entries don't.
        let mixed = Payloads.json("Stop", #""background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"x"},{"id":"b1","type":"shell","status":"running","description":"npm run dev"},{"id":"m1","type":"monitor","status":"running","description":"m"},{"type":"subagent","status":"running"},{"id":"","type":"subagent"},"junk",{"id":"a2","type":"subagent","status":"running","description":"y"}]"#)
        #expect(try event(mixed).backgroundSubagentIDs == ["a1", "a2"])
        #expect(try event(mainStop(subagents: ["a"], shells: ["s"])).backgroundSubagentIDs == ["a"])
    }
}
