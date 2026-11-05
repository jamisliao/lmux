import AppKit
import LmuxHooks
import LmuxSessions
import SwiftUI
@testable import LmuxUI

// The polish pass's reference scene (design/POLISH.md, previews/polish-*.png), staged with the
// real app: the same workspaces, states, split, hover and History as the mockup. Rendered
// offscreen by `--screenshots` (polish-*.png) and on screen by `--real-window` (CI).

enum PolishFixture {
    static let prompt = "the refund check ignores partial amounts. fix refund.ts"
    static let prompt2 = "add a partial_amount column to refunds with a migration"
    static let left = """
    ❯ \(prompt)

    ⏺ Read(src/payments/refund.ts)
      ⎿  Read 142 lines

    ⏺ Found it. createPartialRefund() never compares the amount
      with what's left, so a refunded order can be refunded again.

    ⏺ Update(src/payments/refund.ts)
      ⎿  Updated src/payments/refund.ts with 5 additions

    ⏺ Bash(pnpm vitest run refund)
      ⎿  ✓ refund.test.ts (14 tests) 212ms

    ✻ Simmering… (8s · ↑ 1.4k tokens · esc to interrupt)

    """
    static let right = """
    ❯ \(prompt2)

    ⏺ Write(db/migrations/0042_refund_partial.sql)
      ⎿  Wrote 7 lines to db/migrations/0042_refund_partial.sql

    ⏺ Migration written. Applying it to the local DB.

     Bash command

       pnpm db:migrate --to 0042
       Apply the refunds.partial_amount migration

     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for pnpm db:migrate
       3. No, and tell Claude what to do differently (esc)

    """

    /// Closed sessions for History (English, so "refund" finds three).
    static func writeHistory(root: URL, cwd: String) {
        let dir = root.appendingPathComponent(SessionIndex.projectDirectoryName(forCwd: cwd), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day: TimeInterval = 86400
        let sessions: [(String, String, String, String, TimeInterval)] = [
            ("9a1f0c2a-0000-4000-8000-000000000001", "Webhook retry cleanup",
             "clean up the webhook retry logic. a duplicate refund event arrives twice and must be idempotent", "Added an idempotency key table.", 0.02),
            ("9a1f0c2a-0000-4000-8000-000000000002", "Refund CSV export",
             "write a script that can export partial refund rows as CSV for finance", "Created scripts/export_refunds.ts.", 5),
            ("9a1f0c2a-0000-4000-8000-000000000003", "PG settlement diff",
             "look at the PG settlement diff", "Refund fees are off on 3 orders. settle.ts rounds too early.", 14),
            ("9a1f0c2a-0000-4000-8000-000000000004", "README tone pass",
             "polish the README sentences", "Matched the tone.", 30),
        ]
        for (id, title, prompt, reply, ago) in sessions {
            let url = dir.appendingPathComponent("\(id).jsonl")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try? fixtureJSONL(session: id, cwd: cwd, turns: [FixtureTurn(prompt: prompt, reply: reply)],
                              start: Date().addingTimeInterval(-ago * day), aiTitle: title)
                .write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago * day + 60)], ofItemAtPath: url.path)
        }
    }
}

struct PolishScene {
    let ws: Workspace
    let left: Pane
    let right: Pane
}

/// Replace every workspace with the mockup's: payments refactor (split, needs input), README
/// polish (needs input, 2 unread), flaky IME test (running), bench script (done 4m), release 0.1
/// (failed 12m), lmux and Home (plain shells).
@MainActor
func stagePolishScene(_ c: LmuxController, fx: URL) async -> PolishScene {
    try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
    let work = fx.appendingPathComponent("payments", isDirectory: true)
    let lmuxDir = fx.appendingPathComponent("lmux", isDirectory: true)
    for d in [work, lmuxDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    PolishFixture.writeHistory(root: c.history.projectsRoot, cwd: work.path)
    let s1 = fx.appendingPathComponent("polish-1.jsonl").path
    let s2 = fx.appendingPathComponent("polish-2.jsonl").path
    try? fixtureJSONL(session: "polish-1", cwd: work.path, turns: [FixtureTurn(prompt: PolishFixture.prompt, reply: "Found it.")])
        .write(toFile: s1, atomically: true, encoding: .utf8)
    try? fixtureJSONL(session: "polish-2", cwd: work.path, turns: [FixtureTurn(prompt: PolishFixture.prompt2, reply: nil)])
        .write(toFile: s2, atomically: true, encoding: .utf8)
    let leftSh = ScreenFixture.script(PolishFixture.left, input: "also add a test for the zero-amount case", dir: fx, name: "polish-left")
    let rightSh = ScreenFixture.script(PolishFixture.right, input: nil, dir: fx, name: "polish-right")

    let old = c.model.workspaces
    let pw = c.newWorkspace(cwd: work.path, program: leftSh)
    pw.customTitle = "payments refactor"
    for w in old { c.closeWorkspace(w) }
    let pl = pw.panes[0]
    let pr = c.split(pl, .right, program: rightSh)!
    hookEvent(c, pl, "SessionStart", session: "polish-1", transcript: s1, ["source": "startup"])
    hookEvent(c, pr, "SessionStart", session: "polish-2", transcript: s2, ["source": "startup"])
    hookEvent(c, pl, "UserPromptSubmit", session: "polish-1", ["prompt": PolishFixture.prompt])
    hookEvent(c, pl, "PreToolUse", session: "polish-1", ["tool_name": "Bash", "tool_input": ["command": "pnpm vitest run refund"]])
    hookEvent(c, pr, "UserPromptSubmit", session: "polish-2", ["prompt": PolishFixture.prompt2])
    hookEvent(c, pr, "Notification", session: "polish-2", ["message": "Allow pnpm db:migrate?", "notification_type": "permission_prompt"])
    pl.titleState = TitleState(title: "refund validation")
    pr.titleState = TitleState(title: "refunds migration")

    func row(_ title: String, cwd: String, _ events: [(String, [String: Any])]) -> Workspace {
        let w = c.newWorkspace(cwd: cwd, select: false)
        if !title.isEmpty { w.customTitle = title }
        let p = w.panes[0]
        hookEvent(c, p, "SessionStart", session: "polish-\(title)")
        for (name, extra) in events { hookEvent(c, p, name, session: "polish-\(title)", extra) }
        return w
    }
    // Each new workspace goes right after the selected one: made bottom-up.
    _ = c.newWorkspace(cwd: NSHomeDirectory(), select: false)
    _ = c.newWorkspace(cwd: lmuxDir.path, select: false)
    let release = row("release 0.1", cwd: work.path, [("UserPromptSubmit", ["prompt": "x"]),
        ("StopFailure", ["error_type": "notarytool exited 65"])])
    release.panes[0].lastAlertAt = Date().addingTimeInterval(-12 * 60 - 5)
    let bench = row("bench script", cwd: work.path, [("UserPromptSubmit", ["prompt": "x"]),
        ("Stop", ["last_assistant_message": "RSS table is ready"])])
    bench.panes[0].lastAlertAt = Date().addingTimeInterval(-4 * 60 - 5)
    _ = row("flaky IME test", cwd: work.path, [("UserPromptSubmit", ["prompt": "x"]),
        ("PreToolUse", ["tool_name": "Bash", "tool_input": ["command": "swift test --filter IME"]])])
    let readme = row("README polish", cwd: work.path, [("UserPromptSubmit", ["prompt": "x"]),
        ("Notification", ["message": "Which tone for the intro?", "notification_type": "elicitation_dialog"])])
    readme.panes[0].unread = 2
    for w in c.model.workspaces where w !== readme { for p in w.panes { p.unread = 0 } }
    c.model.clock = Date()
    c.select(pw, focusing: pl)
    _ = await waitFor(8) { rows(pl).contains { $0.contains("accept edits") } && rows(pr).contains { $0.contains("1. Yes") } }
    // The header as in the mockup (the fixture dir is a temp path without git).
    pl.cwd = NSHomeDirectory() + "/work/payments"
    pl.branch = "feat/refund-guard"
    c.titlesChanged(pl); c.titlesChanged(pr)
    c.refreshPaneChrome()
    await c.history.refresh()
    _ = await c.loadTurns(pl)
    return PolishScene(ws: pw, left: pl, right: pr)
}

/// Hover the left pane's prompt (✎ × and the band) and show the × explanation.
@MainActor
func polishHoverPrompt(_ c: LmuxController, _ s: PolishScene) async {
    let pl = s.left
    pl.hover.readAt = .distantPast
    let m = c.screenMap(pl, maxAge: 0)
    if let h = m.map?.promptHeads().first {
        c.paneMouseMoved(pl, NSPoint(x: 200, y: pl.surface.bounds.height - (m.rows[h.row].top + m.rowHeight / 2)))
    }
    await sleepMs(150)
    pl.view.overlay.showTip("Remove this message and everything after it")
    c.refreshInputLabel(pl)
}

/// The onboarding sheet's view on its own (headless can't present sheets), composited over the
/// window snapshot where the sheet would hang from the titlebar, with a soft shadow.
@MainActor
func polishOnboardingPNG(_ c: LmuxController, to url: URL, scale: CGFloat = 2) {
    let v = NSHostingView(rootView: HooksSheetView(install: true, diff: "", settingsPath: NSHomeDirectory() + "/.claude/settings.json",
                                                   cancelTitle: "Not Now", done: { _ in }))
    v.appearance = NSApp.appearance
    let size = v.fittingSize
    v.frame = NSRect(origin: .zero, size: size)
    let holder = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    holder.appearance = NSApp.appearance
    holder.contentView = v
    v.layoutSubtreeIfNeeded()
    guard let base = c.snapshotImage(scale: scale), let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    let W = base.width, H = base.height
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let sheet = rep.cgImage else { return }
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
    ctx.scaleBy(x: scale, y: scale)
    let content = c.root.bounds
    let r = CGRect(x: (content.width - size.width) / 2, y: content.height - c.root.titlebarHeight - 6 - size.height,
                   width: size.width, height: size.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.clip()
    ctx.draw(sheet, in: r)
    ctx.restoreGState()
    guard let out = ctx.makeImage() else { return }
    let png = NSBitmapImageRep(cgImage: out)
    try? png.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path)")
}

/// `--screenshots`: polish-light (History collapsed, prompt hover), polish-dark (History search),
/// polish-onboarding (first launch: one Home row, the hooks sheet).
@MainActor
func shootPolish(_ c: LmuxController, _ dir: URL, fx: URL) async {
    let s = await stagePolishScene(c, fx: fx)
    func one(_ name: String, dark: Bool, _ prepare: () async -> Void) async {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await sleepMs(1200)
        await prepare()
        c.root.updateHeader()
        c.window.contentView?.needsDisplay = true
        await sleepMs(400)
        let out = dir.appendingPathComponent("\(name).png")
        do { try c.snapshotPNG(to: out); print("wrote \(out.path)") } catch { print("snapshot failed: \(error)") }
    }
    for dark in [false, true] {
        await one("polish-light-hover" + (dark ? "-dark" : ""), dark: dark) {
            c.history.query = ""
            await polishHoverPrompt(c, s)
        }
        await one("polish-search" + (dark ? "-dark" : "-light"), dark: dark) {
            c.hideHoverActions(s.left)
            await c.history.search("refund")
        }
    }
    c.history.query = ""
    // First launch: one Home row, no history, the sheet.
    let home = c.newWorkspace(cwd: NSHomeDirectory())
    for w in c.model.workspaces where w !== home { c.closeWorkspace(w) }
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await sleepMs(1500)
        c.root.updateHeader()
        c.window.contentView?.needsDisplay = true
        await sleepMs(300)
        polishOnboardingPNG(c, to: dir.appendingPathComponent("polish-onboarding" + (dark ? "-dark" : "-light") + ".png"))
    }
}
