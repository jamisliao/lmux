import AppKit
import ImageIO
import LmuxHooks
import LmuxSessions
import LmuxTerminal
import UniformTypeIdentifiers
@testable import LmuxUI

// README visuals (App/scripts/readme.sh): the real app, headless and offscreen, every frame
// rendered by `snapshotImage` exactly like the screenshots. Panes run zsh; `claude` in them is
// App/scripts/readme/claude, which replays fixture sessions and reports through the real
// lmux-hook, so sidebar states, rings, badges, forget and resume are lmux's own behavior.
// Nothing calls a model. The 2-Set IME is simulated with the NSTextInputClient calls the real
// one makes (see lmux-imetest). GIFs are encoded with ImageIO.
//
//   lmux-apptest --readme DIR         hero-{dark,light}.png, needs-input / history / forget / korean-ime .gif
//   lmux-apptest --readme-light DIR   light.gif: 10 workspaces, 20 panes, HUD = lmux.app's measured numbers

let readmeSize = NSSize(width: 1200, height: 750)

@MainActor
func makeReadmeController(size: NSSize = readmeSize) -> LmuxController {
    guard let runtime = GhosttyRuntime(fontProfile: .default) else { print("runtime init failed"); _exit(2) }
    GhosttyRuntime.standardPasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lmux.readme.\(getpid())"))
    let c = LmuxController(runtime: runtime, paths: paths, headless: true)
    c.buildMainMenu()
    c.history.helper = Bundle.main.executableURL
    c.start(windowFrame: NSRect(origin: .zero, size: size))
    NSApp.appearance = NSAppearance(named: .darkAqua)
    return c
}

// MARK: - Frames

/// Collects frames (PNG in memory) with their hold times; identical consecutive frames merge.
@MainActor
final class Recorder {
    let c: LmuxController
    let scale: CGFloat
    var frames: [(png: Data, delay: Double)] = []
    /// HUD lines, read right before the frame is rendered (so capture cost never counts).
    var hud: (() -> [String])?
    init(_ c: LmuxController, scale: CGFloat = 1) { self.c = c; self.scale = scale }

    func shot(_ hold: Double) {
        c.window.contentView?.needsDisplay = true
        let lines = hud?()
        guard var img = c.snapshotImage(scale: scale) else { return }
        if let lines { img = drawHUD(img, lines: lines) }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        if let last = frames.last, last.png == png { frames[frames.count - 1].delay += hold; return }
        frames.append((png, hold))
    }

    /// Frames every `every` seconds (GIF time) while `work` runs, for at least `min` seconds.
    func record(every: Double = 0.1, min: Double = 0, max: Double = 15, until done: () -> Bool) async {
        let start = Date()
        while Date().timeIntervalSince(start) < max {
            shot(every)
            await sleepMs(Int(every * 1000))
            if done() && Date().timeIntervalSince(start) >= min { break }
        }
    }

    func write(_ url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            guard let src = CGImageSourceCreateWithData(f.png as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let d = (f.delay * 100).rounded() / 100
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: d, kCGImagePropertyGIFUnclampedDelayTime: d]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let total = frames.reduce(0) { $0 + $1.delay }
        print(String(format: "wrote %@ (%d frames, %.1fs, %.2f MB)", url.lastPathComponent, frames.count, total,
                     Double(size) / 1_048_576))
    }
}

// MARK: - Fixture sessions

let home = NSHomeDirectory()
var projectsRoot: URL { URL(fileURLWithPath: env["LMUX_CLAUDE_PROJECTS"]!) }

struct LiveSession {
    var id: String
    var cwd: String
    var turns: [FixtureTurn]
    var screens: [String: String] = [:]
    var replies: [[String: String]] = []
    var dialog: String?
    var working: String?
}

let aGreen = "\u{1b}[32m", aRed = "\u{1b}[31m", aDim = "\u{1b}[2m", aOff = "\u{1b}[0m"
func tool(_ s: String) -> String { "\(aGreen)⏺\(aOff) \(s)" }
func said(_ s: String) -> String { "⏺ " + s }
func result(_ s: String) -> String { "  \(aDim)⎿\(aOff)  \(s)" }

func metaURL(_ s: LiveSession) -> URL {
    projectsRoot.appendingPathComponent(SessionIndex.projectDirectoryName(forCwd: s.cwd))
        .appendingPathComponent("\(s.id).json")
}

func writeMeta(_ s: LiveSession) {
    var m: [String: Any] = ["screens": s.screens, "replies": s.replies]
    if let d = s.dialog { m["dialog"] = d }
    if let w = s.working { m["working"] = w }
    try? JSONSerialization.data(withJSONObject: m).write(to: metaURL(s))
}

@discardableResult
func writeSession(_ s: LiveSession, ago: TimeInterval = 600) -> String {
    let dir = projectsRoot.appendingPathComponent(SessionIndex.projectDirectoryName(forCwd: s.cwd), isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("\(s.id).jsonl").path
    try? fixtureJSONL(session: s.id, cwd: s.cwd, turns: s.turns, start: Date().addingTimeInterval(-ago))
        .write(toFile: path, atomically: true, encoding: .utf8)
    writeMeta(s)
    return path
}

func dialog(_ cmd: String, _ why: String, always: String) -> String {
    """
     \u{1b}[1mBash command\(aOff)

       \(cmd)
       \(aDim)\(why)\(aOff)

     Do you want to proceed?
     \(aGreen)❯ 1. Yes\(aOff)
       2. Yes, and don't ask again for \(always)
       3. No, and tell Claude what to do differently (esc)
    """
}

enum Scene {
    static let api = home + "/code/acme-api", ios = home + "/code/acme-ios", web = home + "/code/acme-web",
                cli = home + "/code/acme-cli", app = home + "/code/acme-app"

    static let authPrompt1 = "the refresh endpoint sometimes issues two tokens, find the race and fix it"
    static let authPrompt2 = "add a regression test that fires two refreshes at once"
    static let auth1 = LiveSession(id: "5b0c1e9a-3f7d-4c21-9a8e-2d6f0b1c7a01", cwd: api, turns: [
        FixtureTurn(prompt: authPrompt1, reply: "Found it. Two requests with the same refresh token can both pass isRevoked() before either one revokes it.",
                    tools: [("Read", api + "/src/auth/refresh.ts"), ("Edit", api + "/src/auth/refresh.ts")]),
        FixtureTurn(prompt: authPrompt2, reply: "Added a race test. Two concurrent refreshes now get exactly one new pair.",
                    tools: [("Write", api + "/test/auth/refresh.race.test.ts")]),
    ], screens: [
        authPrompt1: [
            tool("Read(src/auth/refresh.ts)"), result("Read 88 lines"), "",
            said("Found it. Two requests with the same refresh token"),
            "  can both pass isRevoked() before either one revokes",
            "  it, so each gets a fresh pair. Revoke and issue now",
            "  run in one transaction, with the old row locked.", "",
            tool("Update(src/auth/refresh.ts)"), result("Updated with 5 additions and 2 removals"),
            "      \(aRed)38 -  if (await isRevoked(token)) throw …\(aOff)",
            "      \(aRed)39 -  await revoke(token)\(aOff)",
            "      \(aGreen)38 +  return db.transaction(async (tx) => {\(aOff)",
            "      \(aGreen)39 +    const row = await tx.lockToken(token)\(aOff)",
            "      \(aGreen)40 +    if (row.revokedAt) throw new Reused()\(aOff)",
        ].joined(separator: "\n"),
        authPrompt2: [
            tool("Write(test/auth/refresh.race.test.ts)"), result("Wrote 31 lines"), "",
            tool("Bash(pnpm vitest run refresh)"), result("\(aGreen)✓\(aOff) refresh.race.test.ts (3 tests) 184ms"), "",
            said("Added a race test. Two concurrent refreshes now"),
            "  get exactly one new pair; the loser gets a 409.",
        ].joined(separator: "\n"),
    ])

    static let authPrompt3 = "add the token_family migration and apply it"
    static var auth2: LiveSession {
        LiveSession(id: "5b0c1e9a-3f7d-4c21-9a8e-2d6f0b1c7a02", cwd: api, turns: [FixtureTurn(prompt: authPrompt3, reply: nil)],
                    screens: [authPrompt3: [
                        tool("Write(db/migrations/0042_token_family.sql)"), result("Wrote 9 lines"), "",
                        said("Migration is ready. Applying it to the local DB."),
                    ].joined(separator: "\n")],
                    dialog: dialog("pnpm db:migrate", "Apply 0042_token_family to the local database", always: "pnpm db:migrate"))
    }

    static let ciPrompt = "CI on macOS fails about one run in five, find out why"
    static let ci1 = LiveSession(id: "7d2e4a10-8b3c-4f5e-a1d2-3c4b5a6f7e01", cwd: ios, turns: [FixtureTurn(prompt: ciPrompt, reply: nil)],
                                 screens: [ciPrompt: [
                                     tool("Bash(gh run list --workflow ci-macos -L 20)"),
                                     result("4 of 20 runs failed, all in SessionStoreTests"), "",
                                     tool("Read(Tests/SessionStoreTests.swift)"), result("Read 212 lines"), "",
                                     said("The tests share one on-disk store and run in"),
                                     "  parallel. Running them alone to confirm:", "",
                                     tool("Bash(xcodebuild test -only-testing:SessionStoreTests)"),
                                     result("Testing started…"),
                                 ].joined(separator: "\n")], working: "Running…")
    static let ciPrompt2 = "while that runs, check if the simulators are stale"
    static var ci2: LiveSession {
        LiveSession(id: "7d2e4a10-8b3c-4f5e-a1d2-3c4b5a6f7e02", cwd: ios, turns: [FixtureTurn(prompt: ciPrompt2, reply: nil)],
                    screens: [ciPrompt2: [
                        tool("Bash(xcrun simctl list devices booted)"), result("iPhone 16 · booted 3 days ago"), "",
                        said("It's been up for days. A clean slate rules out"),
                        "  leftover state between runs.",
                    ].joined(separator: "\n")], working: "Thinking…")
    }

    static let readmePrompt = "tighten the quick start, it reads like a manual"
    static let wrongPrompt = "also bump the db pool size to 20"
    static let readmePrompt2 = "add a one-line install snippet under the title"
    static let readme1 = LiveSession(id: "9a4f6c21-0d1e-4b7a-8c3d-5e6f7a8b9c01", cwd: web, turns: [
        FixtureTurn(prompt: readmePrompt, reply: "Rewrote the quick start: three steps, one command each.",
                    tools: [("Read", web + "/README.md"), ("Edit", web + "/README.md")]),
    ], screens: [readmePrompt: [
        tool("Read(README.md)"), result("Read 164 lines"), "",
        tool("Update(README.md)"), result("Updated README.md with 9 additions and 23 removals"), "",
        said("Rewrote the quick start: three steps, one command each,"),
        "  and moved the config reference below it.",
    ].joined(separator: "\n")], replies: [
        ["match": "pool", "reply": "This repo is the marketing site, there's no database config here.",
         "screen": [tool("Search(pattern: \"pool\", path: \"src\")"), result("Found 0 files"), "",
                    said("This repo is the marketing site, there's no database"),
                    "  config here. Did you mean acme-api?"].joined(separator: "\n")],
        ["match": "install", "reply": "Added `brew install acme` right under the title.",
         "screen": [tool("Update(README.md)"), result("Updated README.md with 4 additions"), "",
                    said("Added `brew install acme` right under the title.")].joined(separator: "\n")],
    ])

    static let releasePrompt = "cut v0.1: tag, build, notarize"
    static let release1 = LiveSession(id: "2c8b9d0e-1f2a-4b3c-9d4e-5f6a7b8c9d01", cwd: cli, turns: [FixtureTurn(prompt: releasePrompt, reply: nil)],
                                      screens: [releasePrompt: [
                                          tool("Bash(git tag v0.1 && make release)"), result("Built Acme-0.1.zip"), "",
                                          "\(aRed)⏺\(aOff) Bash(xcrun notarytool submit Acme-0.1.zip --wait)",
                                          result("\(aRed)Error: notarytool exited 65\(aOff)"),
                                      ].joined(separator: "\n")])

    static let perfPrompt = "cold start got slow again, profile it"
    static let perf1 = LiveSession(id: "4e5f6a7b-8c9d-4e0f-a1b2-c3d4e5f6a701", cwd: app, turns: [FixtureTurn(prompt: perfPrompt, reply: nil)],
                                   screens: [perfPrompt: [
                                       tool("Task(Profile app launch)"), result("Running Instruments, App Launch template…"),
                                   ].joined(separator: "\n")], working: "Profiling…")

    static let koPrompt = "안녕하세요 배포 전에 확인할 것 정리해줘"
    static let ko1 = LiveSession(id: "6f7a8b9c-0d1e-4f2a-b3c4-d5e6f7a8b901", cwd: cli, turns: [], replies: [
        ["match": "배포", "reply": "배포 전 체크리스트예요.",
         "screen": [said("배포 전 체크리스트예요."), "  1. 버전 태그와 CHANGELOG", "  2. 공증(notarize)과 스테이플",
                    "  3. 릴리스 노트 초안"].joined(separator: "\n")],
    ])

    /// Closed sessions for History ("token" finds three of them).
    static func writeHistory() {
        let day: TimeInterval = 86400
        let past: [(String, String, String, String, String, TimeInterval)] = [
            ("1a2b3c4d-0000-4000-8000-00000000a001", api, "webhook retries",
             "webhook retries fire twice when the signing token expires mid-retry, make them idempotent",
             "Each delivery now carries an idempotency key; a retry with a refreshed token is a no-op.", 0.3),
            ("1a2b3c4d-0000-4000-8000-00000000a002", api, "rotate API keys",
             "write a script to rotate API keys without downtime, keep the old token valid for 24h",
             "scripts/rotate-keys.ts issues the new key, keeps the old token for 24h, then revokes it.", 2),
            ("1a2b3c4d-0000-4000-8000-00000000a003", web, "login redirect loop",
             "Safari gets stuck in a login redirect loop, I think the session token cookie is missing SameSite",
             "Right: the cookie had no SameSite, so Safari dropped it on the redirect. Set SameSite=Lax.", 6),
            ("1a2b3c4d-0000-4000-8000-00000000a004", api, "flaky rate limiter test",
             "the rate limiter test fails on CI only", "It depended on wall-clock time; it uses a fake clock now.", 9),
            ("1a2b3c4d-0000-4000-8000-00000000a005", web, "pricing page copy",
             "make the pricing page copy shorter", "Cut it to three lines per plan.", 15),
        ]
        for (id, cwd, title, prompt, reply, ago) in past {
            let dir = projectsRoot.appendingPathComponent(SessionIndex.projectDirectoryName(forCwd: cwd), isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(id).jsonl")
            try? fixtureJSONL(session: id, cwd: cwd, turns: [FixtureTurn(prompt: prompt, reply: reply)],
                              start: Date().addingTimeInterval(-ago * day), aiTitle: title)
                .write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago * day + 60)],
                                                   ofItemAtPath: url.path)
        }
    }
}

// MARK: - Driving

@MainActor
func hookFor(_ c: LmuxController, _ p: Pane, _ name: String, _ s: LiveSession, _ extra: [String: Any] = [:]) {
    hookEvent(c, p, name, session: s.id, transcript: nil, extra.merging(["cwd": s.cwd]) { $1 })
}

/// Keep recording (at most 1s) until the input label is back over Claude's input rule, so a
/// scene's long last frame is the settled screen.
@MainActor
func labelSettled(_ c: LmuxController, _ p: Pane, _ rec: Recorder) async {
    await rec.record(every: 0.12, max: 1.0) {
        let m = c.screenMap(p, maxAge: 0)
        return m.map?.inputRule.map { m.rows[$0].top } == p.view.overlay.inputRuleRow?.top && !p.view.overlay.inputLabel.isHidden
    }
}

/// Hover the head row of prompt `turn` (1-based) in `p`.
@MainActor
func hoverPrompt(_ c: LmuxController, _ p: Pane, turn: Int) async {
    p.hover.readAt = .distantPast
    _ = await c.loadTurns(p)
    let m = c.screenMap(p, maxAge: 0)
    if let h = m.map?.promptHeads().first(where: { $0.turn == turn }) {
        c.paneMouseMoved(p, NSPoint(x: 260, y: p.surface.bounds.height - (m.rows[h.row].top + m.rowHeight / 2)))
    }
    await sleepMs(150)
}

/// The simulated 2-Set IME typing `text` into `p`: per syllable, the preedit grows jamo by
/// jamo (setMarkedText) and is committed (insertText) when the next one starts, like the
/// real IME. `enterWhileComposing`: Enter arrives while the last syllable is still marked.
@MainActor
func imeType(_ p: Pane, _ text: String, rec: Recorder, enterWhileComposing: Bool) async {
    let none = NSRange(location: NSNotFound, length: 0)
    let s = p.surface
    let L = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    var pending: String?
    func commit(_ suffix: String = "") {
        guard let pnd = pending else { return }
        s.setMarkedText(pnd, selectedRange: NSRange(location: pnd.count, length: 0), replacementRange: none)
        s.insertText(pnd + suffix, replacementRange: none)
        pending = nil
    }
    for ch in text {
        let u = ch.unicodeScalars.first!.value
        if u >= 0xAC00, u <= 0xD7A3 {
            let i = Int(u - 0xAC00), l = i / 588, v = (i % 588) / 28, t = i % 28
            commit()
            var states = [String(L[l]), String(UnicodeScalar(UInt32(0xAC00 + (l * 21 + v) * 28))!)]
            if t > 0 { states.append(String(ch)) }
            for st in states {
                s.setMarkedText(st, selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
                pending = st
                rec.shot(0.07)
                await sleepMs(25)
            }
        } else if ch == " " {
            if pending != nil { commit(" ") } else { s.insertText(" ", replacementRange: none) }
            rec.shot(0.07)
        } else {
            commit()
            s.insertText(String(ch), replacementRange: none)
            rec.shot(0.07)
        }
    }
    if enterWhileComposing, let w = p.surface.window {
        // Enter with the last syllable still marked: the real IME commits it (setMarkedText(p)
        // insertText(p)) inside that Return's keyDown, then the Return itself goes through.
        commit()
        await type("\r", window: w)
    }
}

/// Type ASCII text into `p` the way a keyboard does without an IME (insertText per key).
@MainActor
func keyType(_ p: Pane, _ text: String, rec: Recorder, perFrame: Int = 2) async {
    var n = 0
    for ch in text {
        p.surface.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
        n += 1
        if n % perFrame == 0 { await sleepMs(30); rec.shot(0.08) }
    }
    await sleepMs(60)
    rec.shot(0.08)
}

@MainActor
func screenText(_ p: Pane) -> String { rows(p).joined(separator: "\n") }

/// The English fixture scene: five workspaces, seven panes, each pane zsh running the replayed
/// `claude`, states set by the hooks Claude Code would send.
struct SceneRefs {
    var wA, wB, wC, wD, wE: Workspace
    var aL, aR, bL, bR, cP, dP, eP: Pane
    var auth2, ci2: LiveSession
}

@MainActor
func buildScene(_ c: LmuxController) async -> SceneRefs {
    let first = c.model.selected!
    Scene.writeHistory()
    let tAuth1 = writeSession(Scene.auth1, ago: 1800)
    let auth2 = Scene.auth2
    _ = writeSession(auth2, ago: 900)
    let tCI = writeSession(Scene.ci1, ago: 1200)
    var ci2 = Scene.ci2
    ci2.working = "Thinking…"
    _ = writeSession(ci2, ago: 600)
    _ = writeSession(Scene.readme1, ago: 2400)
    _ = writeSession(Scene.release1, ago: 3600)
    _ = writeSession(Scene.perf1, ago: 1500)
    _ = (tAuth1, tCI)

    // Workspaces, in sidebar order. Every pane is zsh running the replayed `claude`.
    func ws(_ title: String, _ s: LiveSession) -> Workspace {
        let w = c.newWorkspace(cwd: s.cwd, command: "claude --resume \(s.id)", select: false)
        w.customTitle = title
        return w
    }
    // Each new one goes right after the selected (first) workspace: created last to first.
    let wE = ws("perf: cold start", Scene.perf1)
    let wD = ws("release v0.1", Scene.release1)
    let wC = ws("README polish", Scene.readme1)
    let wB = ws("fix flaky CI on macOS", Scene.ci1)
    let wA = ws("auth: refresh token race", Scene.auth1)
    c.closeWorkspace(first)
    let aL = wA.panes[0], bL = wB.panes[0], cP = wC.panes[0], dP = wD.panes[0], eP = wE.panes[0]
    // Splits: a script pane that starts the replay, then a shell.
    func splitWith(_ p: Pane, _ s: LiveSession) -> Pane {
        let sh = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("split-\(s.id.prefix(8)).sh")
        try? "#!/bin/zsh -f\ncd '\(s.cwd)'\nclaude --resume \(s.id)\nexec '\(paths.paneCommand ?? "/bin/zsh")'\n".write(to: sh, atomically: true, encoding: .utf8)
        chmod(sh.path, 0o755)
        return c.split(p, .right, program: sh.path)!
    }
    let aR = splitWith(aL, auth2)
    let bR = splitWith(bL, ci2)
    let all: [(Pane, LiveSession)] = [(aL, Scene.auth1), (aR, auth2), (bL, Scene.ci1), (bR, ci2), (cP, Scene.readme1),
                                      (dP, Scene.release1), (eP, Scene.perf1)]
    let bound = await waitFor(20) { all.allSatisfy { $0.0.claudeSessionID == $0.1.id } }
    print(bound ? "all panes bound to their sessions" : "warning: not every pane bound: "
          + all.map { "\($0.1.id.prefix(4))=\($0.0.claudeSessionID?.prefix(4) ?? "nil")" }.joined(separator: " "))
    for (p, title) in [(aL, "refresh token race"), (aR, "token_family migration"), (bL, "flaky SessionStoreTests"),
                       (bR, "stale simulators"), (cP, "quick start rewrite"), (dP, "v0.1 release"), (eP, "cold start profile")] {
        p.titleState = TitleState(title: title)
        c.titlesChanged(p)
    }

    // States, as Claude Code's hooks would report them.
    hookFor(c, aL, "UserPromptSubmit", Scene.auth1, ["prompt": Scene.authPrompt2])
    hookFor(c, aL, "Stop", Scene.auth1, ["last_assistant_message": "Added a race test."])
    hookFor(c, aR, "UserPromptSubmit", auth2, ["prompt": Scene.authPrompt3])
    hookFor(c, aR, "PreToolUse", auth2, ["tool_name": "Bash"])
    hookFor(c, aR, "PermissionRequest", auth2, ["tool_name": "Bash"])
    hookFor(c, bL, "UserPromptSubmit", Scene.ci1, ["prompt": Scene.ciPrompt])
    hookFor(c, bL, "PreToolUse", Scene.ci1, ["tool_name": "Bash"])
    hookFor(c, bR, "UserPromptSubmit", ci2, ["prompt": Scene.ciPrompt2])
    hookFor(c, bR, "PreToolUse", ci2, ["tool_name": "Bash"])
    hookFor(c, cP, "UserPromptSubmit", Scene.readme1, ["prompt": Scene.readmePrompt])
    hookFor(c, cP, "Stop", Scene.readme1, ["last_assistant_message": "Rewrote the quick start: three steps, one command each."])
    cP.lastAlertAt = Date().addingTimeInterval(-4 * 60 - 10)
    hookFor(c, dP, "UserPromptSubmit", Scene.release1, ["prompt": Scene.releasePrompt])
    hookFor(c, dP, "StopFailure", Scene.release1, ["error_type": "notarytool exited 65"])
    dP.lastAlertAt = Date().addingTimeInterval(-12 * 60 - 10)
    hookFor(c, eP, "UserPromptSubmit", Scene.perf1, ["prompt": Scene.perfPrompt])
    hookFor(c, eP, "PreToolUse", Scene.perf1, ["tool_name": "Task"])
    hookFor(c, eP, "SubagentStop", Scene.perf1, ["agent_id": "a1", "agent_type": "general-purpose"])
    c.model.clock = Date()
    return SceneRefs(wA: wA, wB: wB, wC: wC, wD: wD, wE: wE, aL: aL, aR: aR, bL: bL, bR: bR, cP: cP, dP: dP, eP: eP,
                     auth2: auth2, ci2: ci2)
}

@MainActor
func runReadme(_ out: URL) async -> Int32 {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let c = makeReadmeController()
    let sc = await buildScene(c)
    let (wA, wB, wC, aL, aR, bL, bR, cP) = (sc.wA, sc.wB, sc.wC, sc.aL, sc.aR, sc.bL, sc.bR, sc.cP)
    var auth2 = sc.auth2, ci2 = sc.ci2

    // ---- Hero: the auth workspace, prompt hovered, History searching "token".
    c.select(wA, focusing: aL)
    _ = await waitFor(8) { screenText(aR).contains("Do you want to proceed") && screenText(aL).contains("❯") }
    await c.history.refresh()
    await c.history.search("token")
    for (appearance, mode) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
        NSApp.appearance = NSAppearance(named: appearance)
        await sleepMs(1200)
        await hoverPrompt(c, aL, turn: 1)
        c.refreshInputLabel(aL)
        c.refreshPaneChrome()
        c.root.updateHeader()
        await sleepMs(300)
        do { try c.snapshotPNG(to: out.appendingPathComponent("hero-\(mode).png"), scale: 4.0 / 3.0) } catch { print("\(error)") }
        print("wrote hero-\(mode).png")
    }
    NSApp.appearance = NSAppearance(named: .darkAqua)
    await sleepMs(1200)
    c.hideHoverActions(aL)
    c.history.query = ""

    // ---- needs-input.gif: working in the CI workspace; its other pane and then the auth
    // workspace start needing input; ⇧⌘J goes to each.
    auth2.dialog = nil
    writeMeta(auth2)
    hookFor(c, aR, "UserPromptSubmit", auth2, ["prompt": Scene.authPrompt3])
    hookFor(c, aR, "PreToolUse", auth2, ["tool_name": "Bash"])
    c.select(wB, focusing: bL)
    for p in c.model.workspaces.flatMap(\.panes) { p.unread = 0 }
    c.refreshPaneChrome()
    await sleepMs(1600)
    var rec = Recorder(c)
    rec.shot(1.4)
    ci2.working = nil
    ci2.dialog = dialog("xcrun simctl erase all", "Reset every simulator to a clean state", always: "xcrun simctl erase")
    writeMeta(ci2)
    _ = await waitFor(3) { screenText(bR).contains("Do you want to proceed") }
    hookFor(c, bR, "PermissionRequest", ci2, ["tool_name": "Bash"])
    c.refreshPaneChrome()
    await sleepMs(500)
    rec.shot(1.8)
    auth2.dialog = Scene.auth2.dialog
    writeMeta(auth2)
    _ = await waitFor(3) { screenText(aR).contains("Do you want to proceed") }
    hookFor(c, aR, "PermissionRequest", auth2, ["tool_name": "Bash"])
    c.refreshPaneChrome()
    await sleepMs(500)
    rec.shot(2.0)
    c.assumeAppActive = true
    await cmd("j", shift: true, window: c.window)
    await sleepMs(400)
    rec.shot(2.2)
    await cmd("j", shift: true, window: c.window)
    await sleepMs(400)
    rec.shot(2.2)
    rec.write(out.appendingPathComponent("needs-input.gif"))

    // ---- history.gif: type "token", pick one, Enter resumes it in a new workspace.
    c.select(wA, focusing: aL)
    await sleepMs(500)
    rec = Recorder(c)
    rec.shot(1.0)
    for i in 1...5 {
        c.history.query = String("token".prefix(i))
        await sleepMs(i == 5 ? 450 : 120)
        rec.shot(i == 5 ? 1.6 : 0.12)
    }
    c.history.selection = 1
    await sleepMs(150)
    rec.shot(1.2)
    let before = Set(c.model.workspaces.map(\.id))
    c.history.resumeSelected()
    var resumed: Pane?
    await rec.record(every: 0.1, min: 1.5, max: 8) {
        resumed = c.model.workspaces.first { !before.contains($0.id) }?.panes.first
        return resumed.map { screenText($0).contains("accept edits") } ?? false
    }
    rec.shot(2.4)
    rec.write(out.appendingPathComponent("history.gif"))
    c.history.query = ""
    if let w = resumed?.workspace { c.closeWorkspace(w) }

    // ---- forget.gif: in README polish, a prompt meant for acme-api; × takes it back (Claude Code's rewind).
    c.select(wC, focusing: cP)
    await keyType(cP, Scene.wrongPrompt, rec: Recorder(c), perFrame: 40)
    await type("\r", window: c.window)
    _ = await waitFor(6) { screenText(cP).contains("Did you mean acme-api") && cP.agent.state != .running }
    c.clearPendingUndo()
    c.hideToast(cP)
    await sleepMs(3200)
    rec = Recorder(c)
    rec.shot(1.6)
    await hoverPrompt(c, cP, turn: 2)
    rec.shot(0.9)
    cP.view.overlay.turnBar?.remove.mouseEntered(with: NSEvent())
    cP.view.overlay.layoutSubtreeIfNeeded()
    rec.shot(1.5)
    cP.view.overlay.turnBar?.remove.mouseExited(with: NSEvent())
    cP.view.overlay.turnBar?.remove.performClick()
    await sleepMs(200)
    rec.shot(1.8)
    cP.view.overlay.card?.confirm.performClick()
    await rec.record(every: 0.1, min: 1.0, max: 12) {
        let s = screenText(cP)
        return !s.contains(Scene.wrongPrompt) && s.contains("accept edits") && !cP.busy
    }
    rec.shot(1.2)
    await sleepMs(1600)
    await keyType(cP, Scene.readmePrompt2, rec: rec, perFrame: 3)
    rec.shot(0.4)
    await type("\r", window: c.window)
    await rec.record(every: 0.12, min: 1.0, max: 6) { screenText(cP).contains("right under the title") }
    await labelSettled(c, cP, rec)
    rec.shot(2.6)
    rec.write(out.appendingPathComponent("forget.gif"))
    c.clearPendingUndo()
    c.hideToast(cP)

    // ---- korean-ime.gif: fast 2-Set typing, Enter while the last syllable is still composing.
    _ = writeSession(Scene.ko1)
    let wK = c.newWorkspace(cwd: Scene.cli, command: "claude --resume \(Scene.ko1.id)")
    wK.customTitle = "한글 입력"
    let kP = wK.panes[0]
    _ = await waitFor(8) { kP.claudeSessionID == Scene.ko1.id && screenText(kP).contains("accept edits") }
    kP.titleState = TitleState(title: "release checklist")
    c.titlesChanged(kP)
    c.focus(kP)
    await sleepMs(1700)
    rec = Recorder(c)
    rec.shot(1.0)
    await imeType(kP, Scene.koPrompt, rec: rec, enterWhileComposing: true)
    await rec.record(every: 0.12, min: 1.0, max: 6) { screenText(kP).contains("릴리스 노트") }
    await labelSettled(c, kP, rec)
    rec.shot(3.0)
    rec.write(out.appendingPathComponent("korean-ime.gif"))
    let typed = screenText(kP)
    print(typed.contains("❯ " + Scene.koPrompt) ? "korean: prompt arrived intact" : "warning: korean prompt not intact:\n" + typed)

    c.clearPendingUndo()
    c.shutdown()
    return 0
}

// MARK: - light.gif

/// This process's CPU time (user + system) and resident memory.
func processUsage() -> (cpu: Double, rss: Int) {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return (cpu, Int(info.resident_size))
}

/// The HUD: lmux's own numbers, drawn into the frame's bottom-right corner.
func drawHUD(_ img: CGImage, lines: [String]) -> CGImage {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    let big: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                                              .foregroundColor: NSColor.white]
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.8, alpha: 1)]
    let strs = lines.enumerated().map { NSAttributedString(string: $0.element, attributes: $0.offset == 0 ? big : small) }
    let tw = strs.map { $0.size().width }.max() ?? 0
    let th = strs.reduce(0) { $0 + $1.size().height + 3 }
    let box = NSRect(x: CGFloat(w) - tw - 44, y: 22, width: tw + 24, height: th + 16)
    NSColor(srgbRed: 0.18, green: 0.20, blue: 0.25, alpha: 0.92).setFill()
    NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
    NSColor(srgbRed: 0.53, green: 0.75, blue: 0.82, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: box.minX, y: box.minY, width: 3, height: box.height), xRadius: 1.5, yRadius: 1.5).fill()
    var y = box.maxY - 8
    for s in strs {
        y -= s.size().height
        s.draw(at: NSPoint(x: box.minX + 13, y: y))
        y -= 3
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage() ?? img
}

/// light.gif: the English scene grown to 10 workspaces x 2 panes, a calm tour through four of
/// them. The HUD shows the bundled lmux.app's own numbers, measured by App/scripts/readme.sh in a
/// separate headless run with the same layout (10 workspaces, 20 panes, idle shells): this harness
/// process is not lmux.app, so its memory is never shown. LMUX_README_APP_STATS="cpu=0.3 rss=157".
@MainActor
func runReadmeLight(_ out: URL) async -> Int32 {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var stats: [String: String] = [:]
    for kv in (env["LMUX_README_APP_STATS"] ?? "").split(separator: " ") {
        let p = kv.split(separator: "=", maxSplits: 1)
        if p.count == 2 { stats[String(p[0])] = String(p[1]) }
    }
    guard let cpu = stats["cpu"].flatMap(Double.init), let rss = stats["rss"].flatMap(Int.init) else {
        print("light.gif skipped: no lmux.app measurement (LMUX_README_APP_STATS)")
        return 1
    }
    let c = makeReadmeController()
    let sc = await buildScene(c)
    // Every workspace split in two, and five more workspaces after the last one: plain shells,
    // like the measured run. Each new one goes right after the selected one: created last to first.
    for p in [sc.cP, sc.dP, sc.eP] { _ = c.split(p, .right) }
    c.select(sc.wE, focusing: sc.eP)
    for (dir, title) in [("acme-data", "data: nightly export"), ("acme-site", "site: pricing page"),
                         ("acme-sdk", "SDK: retry policy"), ("acme-infra", "infra: terraform plan"),
                         ("acme-docs", "API reference")] {
        let w = c.newWorkspace(cwd: home + "/code/" + dir, select: false)
        w.customTitle = title
        _ = c.split(w.panes[0], .right)
    }
    for (p, t) in [(sc.aL, "refresh token race"), (sc.aR, "token_family migration"), (sc.bL, "flaky SessionStoreTests"),
                   (sc.bR, "stale simulators"), (sc.cP, "quick start rewrite"), (sc.dP, "v0.1 release"),
                   (sc.eP, "cold start profile")] {
        p.titleState = TitleState(title: t)
        c.titlesChanged(p)
    }
    let all = c.model.workspaces.flatMap(\.panes)
    _ = await waitFor(10) { all.allSatisfy { !screenText($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    let panes = all.count
    let rec = Recorder(c)
    rec.hud = {
        [String(format: "CPU %.1f%%   RSS %d MB", cpu, rss),
         "lmux.app · \(c.model.workspaces.count) workspaces · \(panes) panes · idle",
         "measured on lmux.app, same layout, idle shells"]
    }
    // A calm tour: four workspaces, each held long enough to read.
    for (w, f, hold) in [(sc.wA, sc.aL, 1.8), (sc.wB, sc.bL, 1.4), (sc.wD, sc.dP, 1.4), (sc.wE, sc.eP, 1.4), (sc.wA, sc.aL, 1.2)] {
        c.select(w, focusing: f)
        c.refreshPaneChrome()
        await sleepMs(700)
        rec.shot(hold)
    }
    rec.write(out.appendingPathComponent("light.gif"))
    print("light: \(c.model.workspaces.count) workspaces, \(panes) panes; HUD from lmux.app: CPU \(cpu)% RSS \(rss) MB; "
          + "harness RSS \(processUsage().rss / 1_048_576) MB (not shown)")
    c.shutdown()
    return 0
}
