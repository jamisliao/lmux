import AppKit
import LmuxTerminal
import LmuxTranscript
@testable import LmuxUI

// How a rewind feels on the real Claude Code binary (App/scripts/e2etest.sh --bench): 26 turns,
// then ✎ and × on the last, the 3rd, 10th and 25th from the end, and ⌘Z
// after the reply and while Claude works, each LMUX_E2E_BENCH_RUNS times (default 10). For every
// run: the time from the click (or ⌘Z) to done, whether it backed out, and the frames sampled
// every 16ms meanwhile in which Claude's rewind menu was visible to the user (the pane not
// covered by lmux's frozen frame). The removed turns are sent again after each run.
// LMUX_E2E_FRAMES=DIR also writes each scenario's first run as PNG frames (not timed).

@MainActor
func benchSubmit(_ c: LmuxController, _ p: Pane, _ text: String) async -> Bool {
    let before = await c.loadTurns(p).count
    p.surface.sendText(text)
    _ = await waitFor(3) { inputText(p) == text }
    // Past Claude's paste window, so the Return is a Return.
    await sleepMs(250)
    for _ in 0..<4 {
        p.surface.sendKey(keyCode: 0x24, codepoint: 0x0D)
        let sent = await waitOnFile(p.transcriptPath ?? "", timeout: 4) { await c.loadTurns(p).count > before }
        if sent {
            let replied = await waitOnFile(p.transcriptPath ?? "", timeout: 30) {
                (await c.loadTurns(p)).last?.hasReply == true && p.agent.state != .running
            }
            return replied ? await waitFor(10) { inputText(p) == "" } : false
        }
    }
    return false
}

/// Samples the pane every 16ms while a rewind runs: how many samples showed the menu to the user.
@MainActor
final class MenuWatch {
    var samples = 0, visible = 0, frozen = 0
    private var timer: Timer?
    private var frames: (dir: URL, n: Int, c: LmuxController)?

    init(_ p: Pane, frames dir: URL? = nil, _ c: LmuxController) {
        if let dir { frames = (dir, 0, c); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let t = Timer(timeInterval: dir == nil ? 0.016 : 0.05, repeats: true) { [weak self, weak p] _ in
            MainActor.assumeIsolated {
                guard let self, let p else { return }
                self.samples += 1
                let covered = p.view.overlay.freezeShown
                if covered { self.frozen += 1 }
                if !covered, RewindMenu.read(rows(p)) != .closed { self.visible += 1 }
                if var f = self.frames, let img = f.c.snapshotImage(scale: 1) {
                    let rep = NSBitmapImageRep(cgImage: img)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: f.dir.appendingPathComponent(String(format: "f%04d.png", f.n)))
                    f.n += 1
                    self.frames = f
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
}

@MainActor
func runRewindBench() async -> Int32 {
    let r = Report()
    r.section = "bench"
    guard let cwd = env["LMUX_E2E_CWD"], let claude = env["LMUX_E2E_CLAUDE_CMD"] else {
        print("FAIL  [bench] LMUX_E2E_CWD / LMUX_E2E_CLAUDE_CMD not set"); return 1
    }
    let runs = max(1, Int(env["LMUX_E2E_BENCH_RUNS"] ?? "") ?? 10)
    let only = env["LMUX_E2E_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    let framesDir = env["LMUX_E2E_FRAMES"].map { URL(fileURLWithPath: $0) }
    let c = makeController()
    c.pasteboard = NSPasteboard(name: NSPasteboard.Name("lmux-e2e-\(getpid())"))
    let ws = c.newWorkspace(cwd: cwd)
    let p = ws.panes[0]
    for w in c.model.workspaces where w !== ws { c.closeWorkspace(w) }
    c.select(ws)
    _ = await waitFor(10) { rows(p).contains { $0.contains("%") } }
    p.surface.sendText("\(claude) --model claude-e2e-mock --permission-mode acceptEdits\n")
    let ready = await waitFor(40) { p.claudeSessionID != nil && inputText(p) != nil }
    r.check("claude started", ready)
    guard ready else { return finish(r, c) }

    let total = 26
    func word(_ i: Int) -> String { "turn \(String(format: "%02d", i)) of the bench" }
    func fill() async -> Bool {
        var turns = await c.loadTurns(p)
        while turns.count < total {
            guard await benchSubmit(c, p, word(turns.count + 1)) else { return false }
            turns = await c.loadTurns(p)
        }
        return turns.map(\.prompt) == (1...total).map(word)
    }
    let filled = await fill()
    let have = await c.loadTurns(p).map(\.prompt).joined(separator: " / ")
    r.check("\(total) turns", filled, have)

    struct Scenario { let name: String; let depth: Int; let mode: String }
    let scenarios = [Scenario(name: "edit-last", depth: 1, mode: "edit"), Scenario(name: "edit-3", depth: 3, mode: "edit"),
                     Scenario(name: "edit-10", depth: 10, mode: "edit"), Scenario(name: "edit-25", depth: 25, mode: "edit"),
                     Scenario(name: "remove-last", depth: 1, mode: "remove"), Scenario(name: "remove-3", depth: 3, mode: "remove"),
                     Scenario(name: "remove-10", depth: 10, mode: "remove"), Scenario(name: "remove-25", depth: 25, mode: "remove"),
                     Scenario(name: "undo-replied", depth: 1, mode: "undo"), Scenario(name: "undo-working", depth: 1, mode: "undo-working")]
    var summary: [String] = []
    for s in scenarios where only?.contains(s.name) ?? true {
        var times: [Double] = [], backOuts: [String] = [], visible = 0, leftovers = 0
        let first = framesDir == nil ? 1 : 0
        for run in first...runs {
            guard await fill() else {
                let have = await c.loadTurns(p).suffix(4).map { "\($0.index):\($0.prompt)\($0.hasReply ? "+r" : "")" }.joined(separator: " / ")
                r.check("\(s.name): refill", false, "turns=[\(have)] input=\(inputText(p) ?? "nil") log=\(c.actionLog.suffix(4).joined(separator: "; "))")
                dump(p, "refill failed")
                if let t = p.transcriptPath, let keep = env["LMUX_E2E_KEEP"] { try? FileManager.default.copyItem(atPath: t, toPath: keep) }
                break
            }
            let turns = await c.loadTurns(p)
            let target = turns[turns.count - s.depth]
            let watchDir = run == 0 ? framesDir?.appendingPathComponent(s.name) : nil
            var t0 = Date()
            var outcome: RewindOutcome = .failed("?")
            var watch: MenuWatch?
            switch s.mode {
            case "edit", "remove":
                watch = MenuWatch(p, frames: watchDir, c)
                t0 = Date()
                outcome = await c.rewind(p, turnUuid: target.uuid, mode: s.mode == "edit" ? .edit : .remove)
            default:
                // The prompt sent through the window (the undo toast's path), ⌘Z after the reply or while Claude works.
                // (The input is empty after the refill: Esc Esc there would open the rewind menu.)
                let text = s.mode == "undo" ? "quick one to undo" : "SLOW undo me"
                await submit(c, p, text)
                _ = await waitFor(5) { c.pendingUndo != nil }
                if s.mode == "undo" {
                    _ = await waitOnFile(p.transcriptPath ?? "", timeout: 5) {
                        (await c.loadTurns(p)).last?.hasReply == true && p.agent.state != .running
                    }
                } else {
                    _ = await waitFor(3) { p.agent.state == .running }
                }
                guard c.pendingUndo != nil else { backOuts.append("no undo toast"); continue }
                watch = MenuWatch(p, frames: watchDir, c)
                t0 = Date()
                await cmd("z", window: c.window)
                _ = await waitFor(2) { p.busy }
                _ = await waitFor(25) { !p.busy && c.pendingUndo == nil }
                outcome = c.actionLog.suffix(3).contains { $0.hasPrefix("rewind failed") } ? .failed("see log") : .done
            }
            let dt = Date().timeIntervalSince(t0)
            watch?.stop()
            let want = s.mode == "remove" ? "" : (s.mode.hasPrefix("undo") ? (s.mode == "undo" ? "quick one to undo" : "SLOW undo me") : target.prompt)
            let inputOK = await waitFor(2) { inputText(p) == want }
            let clean = RewindMenu.read(rows(p)) == .closed
                && !rows(p).contains { $0.contains("Enter to continue") || $0.contains("to the point before") }
            if !clean { leftovers += 1 }
            if outcome != .done || !inputOK {
                backOuts.append("run \(run): \(outcome) input=\(inputText(p) ?? "nil") log=\(c.actionLog.suffix(3).joined(separator: "; "))")
                dump(p, "\(s.name) run \(run)")
            }
            if run > 0 {
                times.append(dt)
                visible += watch?.visible ?? 0
            }
            print(String(format: "      %@ run %d: %.2fs %@ menu-visible=%d/%d frozen=%d",
                         s.name, run, dt, outcome == .done && inputOK ? "ok" : "BACKED OUT", watch?.visible ?? 0,
                         watch?.samples ?? 0, watch?.frozen ?? 0))
            // Back to an empty input for the refill.
            if inputText(p) != "" {
                await escEsc(c, p)
                _ = await waitFor(3) { inputText(p) == "" }
            }
            if s.mode.hasPrefix("undo") { await sleepMs(900) }
        }
        let sorted = times.sorted()
        let med = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let line = String(format: "%@: median %.2fs (min %.2f, max %.2f), back-outs %d/%d, menu-visible samples %d, leftovers %d",
                          s.name, med, sorted.first ?? 0, sorted.last ?? 0, backOuts.count, times.count, visible, leftovers)
        summary.append(line)
        for b in backOuts { print("      \(s.name) back-out: \(b)") }
        r.check(s.name, backOuts.isEmpty && leftovers == 0, line)
    }
    print("\nSUMMARY")
    for l in summary { print("  \(l)") }
    for _ in 0..<3 { p.surface.sendKey(keyCode: 0x08, codepoint: 0x63, control: true); await sleepMs(400) }
    _ = await waitFor(5) { p.claudeSessionID == nil }
    return finish(r, c)
}
