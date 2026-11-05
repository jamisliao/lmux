import Foundation

/// Synthetic transcripts modeled on Claude Code 2.1.x jsonl (compact JSON, one entry per
/// line, one assistant entry per content block, attachments in the chain).
enum Fixtures {
    static let common = #""isSidechain":false,"userType":"external","cwd":"/tmp/p","sessionId":"S","version":"2.1.280""#

    /// Three turns: u1 (thinking + tool use + multi-block final reply), u2 (with a legacy
    /// inline sidechain and non-prompt user entries), u3 (sdk prompt).
    static let basic = """
    {"type":"queue-operation","operation":"enqueue","timestamp":"T0","sessionId":"S","content":"first prompt\\nsecond line"}
    {"parentUuid":null,\(common),"type":"attachment","attachment":{"type":"hook_success"},"uuid":"h1","timestamp":"T0"}
    {"parentUuid":"h1",\(common),"promptId":"p1","type":"user","message":{"role":"user","content":"first prompt\\nsecond line"},"uuid":"u1","timestamp":"T1","turnOrigin":"human","origin":{"kind":"human"},"futureField":{"x":[1,2.50,"\\u00e9"]}}
    {"parentUuid":"u1",\(common),"type":"attachment","attachment":{"type":"environment"},"uuid":"a1","timestamp":"T1"}
    {"type":"last-prompt","lastPrompt":"first prompt","leafUuid":"a1","sessionId":"S"}
    {"parentUuid":"a1",\(common),"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"sig"}]},"uuid":"as1","timestamp":"T2"}
    {"parentUuid":"as1",\(common),"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Let me check."}]},"uuid":"as2","timestamp":"T2"}
    {"parentUuid":"as2",\(common),"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]},"uuid":"as3","timestamp":"T2"}
    {"parentUuid":"as3",\(common),"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"a.txt"}]},"uuid":"tr1","timestamp":"T3","toolUseResult":{"stdout":"a.txt"},"sourceToolAssistantUUID":"as3"}
    {"parentUuid":"tr1",\(common),"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"# Result\\n\\nA long line that\\nis hard wrapped."}]},"uuid":"as4","timestamp":"T4"}
    {"parentUuid":"as4",\(common),"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"- item"}]},"uuid":"as5","timestamp":"T4"}
    {"parentUuid":"as5",\(common),"type":"system","subtype":"stop_hook_summary","uuid":"s1","timestamp":"T5"}
    {"type":"weird-future-type","payload":{"a":1,  "spaced" : true}}
    {"parentUuid":"s1",\(common),"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill"}]},"uuid":"meta1","timestamp":"T5"}
    {"parentUuid":"meta1",\(common),"type":"user","message":{"role":"user","content":"second prompt"},"uuid":"u2","timestamp":"T6","turnOrigin":"human"}
    {"parentUuid":"u2",\(common),"type":"assistant","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Second answer"}]},"uuid":"as6","timestamp":"T7"}
    {"parentUuid":"as6","isSidechain":true,"sessionId":"S","type":"user","message":{"role":"user","content":"sub task"},"uuid":"sc1","timestamp":"T7"}
    {"parentUuid":"sc1","isSidechain":true,"sessionId":"S","type":"assistant","message":{"id":"m9","role":"assistant","content":[{"type":"text","text":"sub done"}]},"uuid":"sc2","timestamp":"T7"}
    {"parentUuid":"as6",\(common),"type":"user","message":{"role":"user","content":"<bash-stdout>x</bash-stdout><bash-stderr></bash-stderr>"},"uuid":"bo","timestamp":"T8","turnOrigin":"human"}
    {"parentUuid":"bo",\(common),"type":"user","message":{"role":"user","content":"<task-notification>\\ndone</task-notification>"},"uuid":"tn","timestamp":"T8","turnOrigin":"task_notification"}
    {"parentUuid":"tn",\(common),"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"int","timestamp":"T8"}
    {"parentUuid":"int",\(common),"type":"user","message":{"role":"user","content":"third prompt"},"uuid":"u3","timestamp":"T9","turnOrigin":"sdk"}
    {"parentUuid":"u3",\(common),"type":"assistant","message":{"id":"m4","role":"assistant","content":[{"type":"text","text":"Third answer"}]},"uuid":"as7","timestamp":"T10"}
    {"type":"last-prompt","lastPrompt":"third prompt","leafUuid":"as7","sessionId":"S"}

    """

    /// `basic` after a rewind to before u3 (Claude Code's own, in the running process) and a new
    /// prompt u4 on that spot, before Claude re-appended its `last-prompt` (still as7, on u3's branch).
    static let rewoundThenPrompted = basic + """
    {"parentUuid":"int",\(common),"type":"user","message":{"role":"user","content":"fourth prompt"},"uuid":"u4","timestamp":"T11","turnOrigin":"human"}
    {"parentUuid":"u4",\(common),"type":"assistant","message":{"id":"m5","role":"assistant","content":[{"type":"text","text":"Fourth answer"}]},"uuid":"as8","timestamp":"T12"}

    """

    /// `basic` rewound to before u3 (an explicit pointer to that spot), then a late entry of the
    /// branch rewound away (after as7), and no new prompt yet.
    static let explicitThenStraggler = basic + """
    {"type":"last-prompt","leafUuid":"int","explicit":true,"sessionId":"S"}
    {"parentUuid":"as7",\(common),"type":"system","subtype":"stop_hook_summary","uuid":"s9","timestamp":"T11"}

    """

    /// One turn before a compaction boundary (u0), two after (u1, u2).
    static let compacted = """
    {"parentUuid":null,\(common),"type":"user","message":{"role":"user","content":"old prompt"},"uuid":"u0","timestamp":"T0","turnOrigin":"human"}
    {"parentUuid":"u0",\(common),"type":"assistant","message":{"id":"m0","role":"assistant","content":[{"type":"text","text":"old answer"}]},"uuid":"as0","timestamp":"T1"}
    {"parentUuid":null,"logicalParentUuid":"as0",\(common),"type":"system","subtype":"compact_boundary","content":"Conversation compacted","uuid":"c0","timestamp":"T2"}
    {"parentUuid":"c0",\(common),"type":"user","message":{"role":"user","content":"This session is being continued..."},"isCompactSummary":true,"isVisibleInTranscriptOnly":true,"uuid":"cs","timestamp":"T2","turnOrigin":"human"}
    {"parentUuid":"cs",\(common),"type":"user","message":{"role":"user","content":"new prompt"},"uuid":"u1","timestamp":"T3","turnOrigin":"human"}
    {"parentUuid":"u1",\(common),"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"new answer"}]},"uuid":"as1","timestamp":"T4"}
    {"parentUuid":"as1",\(common),"type":"user","message":{"role":"user","content":"last prompt"},"uuid":"u2","timestamp":"T5","turnOrigin":"human"}
    {"parentUuid":"u2",\(common),"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"last answer"}]},"uuid":"as2","timestamp":"T6"}

    """

    /// A tool_use in turn 1 whose tool_result lands in turn 2 (e.g. interrupted, then
    /// the next prompt arrives before the result is recorded).
    static let crossTurnTool = """
    {"parentUuid":null,\(common),"type":"user","message":{"role":"user","content":"p1"},"uuid":"u1","timestamp":"T0","turnOrigin":"human"}
    {"parentUuid":"u1",\(common),"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"tuX","name":"Bash","input":{}}]},"uuid":"as1","timestamp":"T1"}
    {"parentUuid":"as1",\(common),"type":"user","message":{"role":"user","content":"p2"},"uuid":"u2","timestamp":"T2","turnOrigin":"human"}
    {"parentUuid":"u2",\(common),"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tuX","content":"late"}]},"uuid":"tr","timestamp":"T3","toolUseResult":{}}

    """
}
