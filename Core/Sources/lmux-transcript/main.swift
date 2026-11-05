import Foundation
import LmuxTranscript

let usage = """
usage:
  lmux-transcript turns <file>
  lmux-transcript copy <file> <turn-index|uuid>
  lmux-transcript forget <file> <turn-index|uuid> [--dry-run]
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func oneLine(_ s: String, max: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ")
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}

var args = Array(CommandLine.arguments.dropFirst())
let dryRun = args.contains("--dry-run")
args.removeAll { $0 == "--dry-run" }
guard args.count >= 2 else { fail(usage) }
let url = URL(fileURLWithPath: args[1])

do {
    let transcript = try Transcript.load(url)
    switch (args[0], args.count) {
    case ("turns", 2):
        for t in transcript.turns() {
            let flag = t.beforeCompaction ? " [compacted]" : ""
            print("\(t.index)\t\(t.uuid)\t\(t.timestamp ?? "-")\(flag)")
            print("  > \(oneLine(t.firstLine, max: 100))")
            print("  < \(oneLine(t.assistantText ?? "(no text reply)", max: 100))")
        }
    case ("copy", 3):
        let t = try transcript.turn(matching: args[2])
        guard let md = t.assistantText else { fail("turn \(t.index) has no text reply") }
        print(md)
    case ("forget", 3):
        let t = try transcript.turn(matching: args[2])
        let (updated, plan) = try transcript.removingWithPlan(turnUuid: t.uuid)
        print("turn \(t.index) \(t.uuid): \(oneLine(t.firstLine, max: 80))")
        print("remove \(plan.removedUuids.count) entries")
        for r in plan.relinked { print("relink \(r.uuid) -> parent \(r.newParent ?? "null")") }
        if dryRun {
            print("(dry run, nothing written)")
        } else {
            let backup = try updated.write(to: url)
            print("wrote \(url.path)" + (backup.map { " (backup: \($0.path))" } ?? ""))
        }
    default:
        fail(usage)
    }
} catch {
    fail("error: \(error)")
}
