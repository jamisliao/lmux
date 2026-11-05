import AppKit
import ImageIO
import LmuxHooks
import LmuxSessions
import LmuxTokens
import UniformTypeIdentifiers
@testable import LmuxUI

// The hero video (App/scripts/readme.sh hero): the real app, headless and offscreen, the same
// pipeline as the README GIFs (Readme.swift), filmed like a screen recording. The fixture
// sessions are a developer's own lmux worktrees; `claude` in every pane is
// App/scripts/readme/claude replaying them, and every state change goes through the hooks Claude
// Code would send. Nothing calls a model.
//
//   lmux-apptest --hero DIR [--light]
//     DIR/frames/f00000.png ...   30 fps, 2400x1500: the window on a quiet desktop with a sliver
//                                 of menu bar, a pointer, a camera that eases in and out (a
//                                 seamless loop: the last frames cross-fade into the first)
//     DIR/readme/f00000.png ...   the first HERO_README_END s again, the window filling the frame
//     DIR/poster.png               the first frame
//     DIR/hero.png                 the app alone at 4/3 (assets/screenshots/hero-*.png)
//   HERO_PASS=clip lmux-apptest --hero DIR [--light]   (instead of the above)
//     DIR/clip/f00000.png ...     30 fps, 2000x1200: the README's × clip (assets/gifs/forget-x-*):
//                                 a 1000x600 pt window, held on the site pane, from Claude's
//                                 answer to the prompt gone, one caption (HeroCaptions)
//
// The story, about 27 s. Five workspaces, every sidebar state at once: a split with Claude Code
// and Codex side by side (Codex running; two tabs behind the Claude side, a Claude test run
// that finishes there and badges its tab, and a terminal), one running that turns ✓ (the bell ticks), one that
// needs input (badge, "Permission: Bash"), one failed ✗ with its reason, one done and left
// unattended (it breathes). A prompt is typed (a typo, fixed) into the split's Claude and it
// streams the answer while Codex keeps working; ⇧⌘↩ zooms the answer and back; ⇧⌘J jumps to the
// permission prompt, `1` approves; a click on "site" and a prompt meant for the release goes
// there by mistake ("Sent to site"), so hover, ×, Forget; ⌘4 and it goes where it belongs; the
// row is dragged to the top; ⇧⌘H, "ghostty", Enter resumes an old session; the camera pulls
// back to the whole window. The first ~9 s are also written without camera moves (readme/) for
// the README's animated WebP.
//
// Time is the film's, not the wall clock's: the script advances it explicitly, and the replayed
// `claude`s stream one line per step and count their timers in film ticks (fake_claude's
// stepped mode), so the pacing is the same in every run and in both themes.

let aBold = "\u{1b}[1m"

enum Hero {
    static let lmux = home + "/code/lmux", ime = home + "/code/lmux-ime", cmux = home + "/code/lmux-cmux",
                release = home + "/code/lmux-release", site = home + "/code/lmux-site"

    // 1. fix sidebar redraw: a split. Left: one turn done, the typed prompt streams back.
    static let redrawPrompt1 = "typing lags with 20 panes open, profile it"
    static let typed = "why does the sidebar redraw on evry k⌫⌫⌫⌫ery key?"
    static var typedText: String { applyBackspaces(typed) }
    static let redrawReply = "Repeated titles stop at the source now."
    static let redraw = LiveSession(id: "e1a0c3d2-7b4f-4e8a-9c21-3f5d6a7b8c01", cwd: lmux, turns: [
        FixtureTurn(prompt: redrawPrompt1, reply: "Every keystroke re-lays out the whole sidebar."),
    ], screens: [
        redrawPrompt1: [
            tool("Bash(scripts/profile.sh --panes 20 --keys 10k)"),
            result("p99 keystroke 31ms, 9812 sidebar layouts"), "",
            said("Every keystroke re-lays out the whole sidebar,"),
            "  even though nothing in it changed.", "",
            "\(aDim)✻ Worked for 41s\(aOff)",
        ].joined(separator: "\n"),
    ], replies: [[
        "match": "sidebar redraw", "working": "Percolating…", "pace": "9", "reply": redrawReply,
        "screen": [
            tool("Read(LmuxTerminal/SurfaceView.swift)"), result("Read 412 lines"), "",
            said("ghostty resends the title on every prompt"),
            "  redraw and SurfaceView forwards each one,",
            "  so every key re-lays out the row.", "",
            tool("Update(LmuxTerminal/SurfaceView.swift)"), result("Updated with 2 additions"),
            "      \(aRed)214 -  onTitle?(title)\(aOff)",
            "      \(aGreen)214 +  if title == last { return }\(aOff)",
            "      \(aGreen)215 +  last = title; onTitle?(title)\(aOff)", "",
            tool("Bash(swift test --filter TitleStorm)"),
            result("\(aGreen)✓\(aOff) 38 passed (0.41s)"), "",
            said(redrawReply),
            "  9812 layouts per 10k keys → 41.",
        ].joined(separator: "\n"),
    ]])

    // 1b. The split's right side: Codex, idle CPU before / after, streaming meanwhile (Codex
    // CLI 0.166's screen: "• Ran", "└", "• Working (12s • esc to interrupt)").
    static let benchPrompt = "idle cpu w/ 20 panes, before vs after"
    static var bench = LiveSession(id: "e1a0c3d2-7b4f-4e8a-9c21-3f5d6a7b8c02", cwd: lmux,
                                   turns: [FixtureTurn(prompt: benchPrompt, reply: nil)],
                                   screens: [benchPrompt: [
                                       "\(aBold)• Ran\(aOff) scripts/measure_idle.sh --panes 20",
                                       "  \(aDim)└\(aOff) before  2.9% cpu, 161 MB", "",
                                       "• Rebuilding with the fix for the after run.", "",
                                       "\(aBold)• Ran\(aOff) swift build -c release",
                                   ].joined(separator: "\n")], working: "Working")
    static let benchMore: [String] = [
        "  \(aDim)└\(aOff) Build complete! (38.2s)", "",
        "\(aBold)• Ran\(aOff) scripts/measure_idle.sh --panes 20",
        "  \(aDim)└\(aOff) after   0.4% cpu, 158 MB", "",
        "• 2.9% → 0.4% idle, memory about the same.",
    ]

    // 1c. Tabs behind the split's Claude: another Claude running the title-storm test (it
    // finishes behind, so its tab gets the badge) and a plain terminal.
    static let stormPrompt = "run the TitleStorm suite 20x, flag any flake"
    static let stormDone = "20 of 20 green, no flakes."
    static var storm = LiveSession(id: "e1a0c3d2-7b4f-4e8a-9c21-3f5d6a7b8c03", cwd: lmux, turns: [FixtureTurn(prompt: stormPrompt, reply: nil)],
                                   screens: [stormPrompt: tool("Bash(for i in $(seq 20); do swift test --filter TitleStorm; done)")],
                                   working: "Simmering…")

    // 2. korean ime jamo: running, finishes (✓) in the background.
    static let imePrompt = "first jamo doesn't show until the 2nd key, fix preedit"
    static var imeS = LiveSession(id: "a7b8c9d0-1e2f-4a3b-8c4d-5e6f7a8b9c01", cwd: ime, turns: [FixtureTurn(prompt: imePrompt, reply: nil)],
                                 screens: [imePrompt: [
                                     tool("Read(LmuxTerminal/SurfaceView+IME.swift)"), result("Read 188 lines"), "",
                                     said("setMarkedText drops a lone jamo when the range is"),
                                     "  empty. Keeping it as the preedit.", "",
                                     tool("Bash(App/scripts/imetest.sh)"),
                                 ].joined(separator: "\n")], working: "Noodling…")
    static let imeDone = "First jamo shows while composing; imetest passes."

    // 3. cmux import: asks for permission.
    static let cmuxPrompt = "import cmux workspaces on first launch, keep splits"
    static var cmuxS = LiveSession(id: "b2c3d4e5-6f7a-4b8c-9d0e-1f2a3b4c5d01", cwd: cmux, turns: [FixtureTurn(prompt: cmuxPrompt, reply: nil)],
                                  screens: [cmuxPrompt: [
                                      tool("Read(LmuxUI/CmuxImport.swift)"), result("Read 268 lines"), "",
                                      said("cmux's session file already has the split tree."),
                                      "  Checking its settings before mapping them:",
                                  ].joined(separator: "\n")], working: "Spelunking…")
    static let cmuxDialog = dialog("plutil -p ~/Library/Preferences/com.cmuxterm.app.plist",
                                   "Read cmux's settings (read-only)", always: "plutil -p")
        + "\n\n \(aDim)Esc to cancel · Tab to amend\(aOff)"
    static let cmuxApproved = [
        "", tool("Bash(plutil -p ~/Library/Preferences/com.cmuxterm.app.plist)"),
        result("23 keys, 9 have an lmux equivalent"), "",
        said("Mapping font, theme and shortcuts into one block"),
        "  of lmux's config, replaced on each import.",
    ].joined(separator: "\n")

    // 4. notarize v0.1: failed 12 minutes ago.
    static let relPrompt = "cut v0.1: bundle, sign, notarize, staple"
    static let resend = "retry notarize, staple"
    static let rel = LiveSession(id: "c3d4e5f6-7a8b-4c9d-8e0f-2a3b4c5d6e01", cwd: release, turns: [FixtureTurn(prompt: relPrompt, reply: "notarytool exited 65")],
                                 screens: [relPrompt: [
                                     tool("Bash(App/scripts/bundle.sh --release)"), result("Built lmux-0.1.zip"), "",
                                     "\(aRed)⏺\(aOff) Bash(xcrun notarytool submit lmux-0.1.zip --wait)",
                                     result("\(aRed)Error: HTTP status code: 401. Unable to authenticate.\(aOff)"),
                                     result("\(aRed)notarytool exited 65\(aOff)"),
                                 ].joined(separator: "\n")],
                                 replies: [[
                                     "match": "retry notarize", "working": "Brewing…", "pace": "6", "reply": "Accepted, stapled.",
                                     "screen": [
                                         said("The keychain profile expired; using the fresh one."), "",
                                         tool("Bash(xcrun notarytool submit lmux-0.1.zip -p lmux --wait)"),
                                         result("Submitting… id 7f3c2a91"),
                                         result("Accepted. Stapling…"),
                                     ].joined(separator: "\n"),
                                 ]])

    // 5. site: done a while ago, nobody looked (it breathes). The wrong prompt lands here.
    static let sitePrompt = "hero video under 2 MB per theme, keep text crisp"
    static let siteReply = "1.8 MB dark, 1.9 MB light at CRF 18."
    static let siteS = LiveSession(id: "d4e5f6a7-8b9c-4d0e-9f1a-3b4c5d6e7f01", cwd: site, turns: [FixtureTurn(prompt: sitePrompt, reply: siteReply)],
                                  screens: [sitePrompt: [
                                      tool("Bash(ffmpeg -i hero.mov -crf 18 hero.mp4)"), result("1.8 MB"), "",
                                      said(siteReply),
                                  ].joined(separator: "\n")],
                                  replies: [[
                                      "match": "retry notarize", "working": "Pondering…", "pace": "4",
                                      "reply": "Nothing to notarize here.",
                                      "screen": [
                                          said("This is the site repo, there's nothing to notarize"),
                                          "  here. Did you mean lmux-release?",
                                      ].joined(separator: "\n"),
                                  ]])

    /// The README clip's window (points): wider and lower than the film's, so the text is larger
    /// at the clip's width.
    static let clipWindow = NSSize(width: 1000, height: 600)

    /// Closed sessions for History ("ghostty" finds three of them).
    static func writeHistory() {
        let day: TimeInterval = 86400
        let past: [(String, String, String, String, String, TimeInterval)] = [
            ("f0e1d2c3-0000-4000-8000-00000000b001", lmux, "bump libghostty",
             "bump libghostty to latest ghostty tip, fix whatever breaks",
             "Bumped; two renamed C symbols, the rest built as-is.", 0.4),
            ("f0e1d2c3-0000-4000-8000-00000000b002", lmux, "D2Coding for Hangul",
             "hangul falls back to a system font in ghostty, bundle D2Coding",
             "D2Coding ships in Resources/Fonts and is the CJK fallback.", 3),
            ("f0e1d2c3-0000-4000-8000-00000000b003", lmux, "shell integration under login(1)",
             "panes start via login(1) so ghostty's shell integration loses ZDOTDIR",
             "The pane command sets ZDOTDIR again after login(1).", 8),
            ("f0e1d2c3-0000-4000-8000-00000000b004", lmux, "sidebar row spacing",
             "sidebar rows feel cramped", "Rows have 4pt more air.", 11),
            ("f0e1d2c3-0000-4000-8000-00000000b005", site, "favicon",
             "32px favicon from the icon", "favicon-32.png from icon.svg.", 16),
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

    /// "abc⌫d" -> "abd".
    static func applyBackspaces(_ s: String) -> String {
        var out = ""
        for ch in s { if ch == "⌫" { _ = out.popLast() } else { out.append(ch) } }
        return out
    }
}

// MARK: - Film: a screen recording of the live app

/// Writes f00000.png... at 30 fps as film time advances. Each frame is a fresh `snapshotImage`
/// of the app (2x), placed on a desktop the size of the video with a camera over it (zoom 1 shows
/// the whole window at 0.84; the closest zoom shows it 1:1, so text is never upscaled), plus the
/// pointer. The sidebar's Core Animation motion (spinners, the unattended breath) runs in the
/// render server, which a snapshot never sees, so before each frame its layers are set to where
/// those animations are at that film time (same period, curve and values as the app's).
@MainActor
final class Film {
    let c: LmuxController
    let dark: Bool
    let dir: URL
    let fps = 30.0
    static let W = 2400.0, H = 1500.0
    /// The window on the desktop at zoom 1 (canvas pixels per window pixel at 2x), and where.
    static let s0 = 0.84
    static let zMax = 1 / s0
    let win: CGRect
    /// Film time (s) and the frames written so far (frame n shows time n / fps).
    private(set) var t = 0.0
    private(set) var n = 0
    private(set) var first: CGImage?
    private var caps: [(label: String, from: Double, to: Double)] = []
    private var breathStart: [ObjectIdentifier: Double] = [:]
    private var fadeFrom = Double.infinity, fadeTo = Double.infinity
    private var desk: CGImage?
    /// HERO_PASS=clip: the README's × clip (clip/ only, while `clipOn`), not the film.
    static let clipPass = ProcessInfo.processInfo.environment["HERO_PASS"] == "clip"
    /// The clip's view (window points, bottom-left origin), its caption, and when it records.
    var clipRect = CGRect.zero
    var clipCaption: String?
    var clipOn = false
    private var cn = 0
    /// Film time the README's cut ends (HERO_README_END).
    let readmeEnd = Double(ProcessInfo.processInfo.environment["HERO_README_END"] ?? "") ?? 9.3

    // Camera: zoom and focus (canvas pixels, bottom-left origin), eased between keyframes.
    private var camFrom = (z: 1.0, f: CGPoint(x: W / 2, y: H / 2)), camTo = (z: 1.0, f: CGPoint(x: W / 2, y: H / 2))
    private var camT0 = 0.0, camDur = 0.0
    // Pointer (window points, bottom-left origin), on a gently curved, minimum-jerk path.
    private(set) var pointer = NSPoint(x: 760, y: 120)
    private var pFrom = NSPoint.zero, pTo = NSPoint.zero, pCtl = NSPoint.zero, pT0 = 0.0, pDur = 0.0, moving = false
    private var pressAt = -10.0
    /// What the pointer is over (set by the scene each frame): I-beam over terminal text.
    var ibeam = false

    init(_ c: LmuxController, dark: Bool, dir: URL) {
        self.c = c; self.dark = dark; self.dir = dir
        let size = c.window.contentView!.bounds.size
        let w = size.width * 2 * Film.s0, h = size.height * 2 * Film.s0
        win = CGRect(x: (Film.W - w) / 2, y: 100, width: w, height: h)
        let readme = dir.deletingLastPathComponent().appendingPathComponent(Film.clipPass ? "clip" : "readme")
        for d in Film.clipPass ? [readme] : [dir, readme] {
            try? FileManager.default.removeItem(at: d)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        desk = makeDesk()
    }

    // MARK: Direction

    func toCanvas(_ p: NSPoint) -> CGPoint {
        CGPoint(x: win.minX + p.x * 2 * Film.s0, y: win.minY + p.y * 2 * Film.s0)
    }

    /// Ease the camera to zoom `z` centered on window point `focus` (nil: the whole desktop).
    func camera(_ z: Double, _ focus: NSPoint?, over dur: Double = 1.1) {
        camFrom = camAt(t)
        // Only up and down: the window is never wider than the video, so the sidebar stays in view.
        camTo = (z, focus.map { CGPoint(x: Film.W / 2, y: toCanvas($0).y) } ?? CGPoint(x: Film.W / 2, y: Film.H / 2))
        camT0 = t; camDur = dur
    }

    /// Move the pointer to window point `to` over `dur` s (starts now; the scene lets time pass).
    func move(to: NSPoint, dur: Double) {
        pFrom = pointer; pTo = to; pT0 = t; pDur = max(dur, 1e-3); moving = true
        let dx = to.x - pointer.x, dy = to.y - pointer.y
        // A slight arc, bending the same way a wrist does (to the right of the direction of travel).
        pCtl = NSPoint(x: (pointer.x + to.x) / 2 + dy * 0.12, y: (pointer.y + to.y) / 2 - dx * 0.12)
    }

    func press() { pressAt = t }

    /// A keycap for the shortcut about to be pressed, shown from now for `lead` + 1 s.
    func keycap(_ label: String, lead: Double = 0.2) -> Double {
        caps.append((label, t, t + lead + 1.0))
        return lead
    }

    /// One frame's time passes: pointer and camera move, then the frame is rendered.
    func frame() {
        let time = Double(n) / fps
        updatePointer(time)
        render(time)
        t = Double(n) / fps
    }

    func fade(_ dur: Double) { fadeFrom = t; fadeTo = t + dur }

    func report() {
        print(String(format: "wrote %d frames (%.2fs at %.0f fps)", n, Double(n) / fps, fps))
    }

    private func updatePointer(_ time: Double) {
        guard moving else { return }
        let u = min(1, max(0, (time - pT0) / pDur))
        let e = u * u * u * (10 - 15 * u + 6 * u * u)  // minimum jerk
        let a = 1 - e
        pointer = NSPoint(x: a * a * pFrom.x + 2 * a * e * pCtl.x + e * e * pTo.x,
                          y: a * a * pFrom.y + 2 * a * e * pCtl.y + e * e * pTo.y)
        if u >= 1 { moving = false; pointer = pTo }
    }

    private func camAt(_ time: Double) -> (z: Double, f: CGPoint) {
        let u = camDur <= 0 ? 1 : min(1, max(0, (time - camT0) / camDur))
        let e = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
        let z = camFrom.z + (camTo.z - camFrom.z) * e
        var f = CGPoint(x: camFrom.f.x + (camTo.f.x - camFrom.f.x) * e, y: camFrom.f.y + (camTo.f.y - camFrom.f.y) * e)
        let hw = Film.W / (2 * z), hh = Film.H / (2 * z)
        f.x = min(max(f.x, hw), Film.W - hw)
        f.y = min(max(f.y, hh), Film.H - hh)
        return (z, f)
    }

    // MARK: Rendering

    private func render(_ time: Double) {
        setMotion(time)
        c.window.contentView?.needsDisplay = true
        guard let app = c.snapshotImage(scale: 2) else { return }
        if Film.clipPass {
            if clipOn { composeClip(app, time); cn += 1 }
            n += 1
            return
        }
        compose(app, time, cam: camAt(time), to: dir)
        // The README's cut: the same frames with the camera held on the window (1:1, filling the
        // frame), no zooms: an animated WebP of a moving camera is several times the size.
        if time < readmeEnd {
            compose(app, time, cam: (Film.zMax, CGPoint(x: win.midX, y: win.midY)),
                    to: dir.deletingLastPathComponent().appendingPathComponent("readme"))
        }
        n += 1
    }

    private func compose(_ app: CGImage, _ time: Double, cam: (z: Double, f: CGPoint), to dir: URL) {
        let W = Int(Film.W), H = Int(Film.H)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.translateBy(x: Film.W / 2, y: Film.H / 2)
        ctx.scaleBy(x: cam.z, y: cam.z)
        ctx.translateBy(x: -cam.f.x, y: -cam.f.y)
        if let desk { ctx.draw(desk, in: full) }
        // The window: a soft two-layer shadow, rounded corners, a hairline edge.
        let radius = 11 * 2 * Film.s0
        let shape = CGPath(roundedRect: win, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -36), blur: 90, color: NSColor(white: 0, alpha: dark ? 0.55 : 0.32).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor(white: dark ? 0.1 : 0.9, alpha: 1).cgColor); ctx.fillPath()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: NSColor(white: 0, alpha: dark ? 0.5 : 0.18).cgColor)
        ctx.addPath(shape); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.draw(app, in: win)
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: win.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.14).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        drawPointer(ctx, time, at: toCanvas(pointer), k: 2 * Film.s0 * 1.3)
        ctx.restoreGState()
        for cap in caps where time >= cap.from && time < cap.to {
            let alpha = min(1, (time - cap.from) / 0.12, (cap.to - time) / 0.3)
            if alpha > 0 { drawKeycap(ctx, cap.label, alpha: alpha) }
        }
        if time >= fadeFrom, let first {
            let p = min(1, (time - fadeFrom) / (fadeTo - fadeFrom))
            ctx.setAlpha(p * p * (3 - 2 * p))
            ctx.draw(first, in: full)
            ctx.setAlpha(1)
        }
        guard let frame = ctx.makeImage() else { return }
        if first == nil, dir == self.dir { first = frame }
        let url = dir.appendingPathComponent(String(format: "f%05d.png", n))
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, frame, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// A clip frame: `clipRect` of the app at 2x filling the frame (no camera moves), the
    /// pointer, the caption. The caption is a plain pill, no soft shadow: the WebP encoder drops
    /// small changes from frame to frame, so a blur's faint edge would ghost when it goes.
    private func composeClip(_ app: CGImage, _ time: Double) {
        let W = 2000, H = Int((2000 * clipRect.height / clipRect.width).rounded())
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let k = Double(W) / clipRect.width  // canvas pixels per window point
        ctx.interpolationQuality = .high
        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -clipRect.minX, y: -clipRect.minY)
        ctx.draw(app, in: CGRect(origin: .zero, size: c.window.contentView!.bounds.size))
        ctx.restoreGState()
        drawPointer(ctx, time, at: CGPoint(x: (pointer.x - clipRect.minX) * k, y: (pointer.y - clipRect.minY) * k), k: k * 1.3)
        if let text = clipCaption { drawCaption(ctx, text, cx: Double(W) / 2) }
        guard let frame = ctx.makeImage() else { return }
        let url = dir.deletingLastPathComponent().appendingPathComponent("clip").appendingPathComponent(String(format: "f%05d.png", cn))
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, frame, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// The clip's caption: a toast-like pill (LmuxTokens' elevated surface, primary text,
    /// hairline border), bottom center.
    private func drawCaption(_ ctx: CGContext, _ text: String, cx: Double) {
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let s = 2.0
        let C = LmuxTokens.Colors.self
        let font = NSFont.systemFont(ofSize: 18 * s, weight: .medium)
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: C.textPrimary.cgColor(dark: dark))!])
        let sz = str.size()
        let padX = 20 * s, padY = 8 * s
        let box = NSRect(x: (cx - sz.width / 2 - padX).rounded(), y: 14 * s,
                         width: (sz.width + 2 * padX).rounded(), height: (sz.height + 2 * padY).rounded())
        let r = LmuxTokens.Radius.toast * s
        let path = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
        NSColor(cgColor: C.elevatedBackground.cgColor(dark: dark))!.setFill()
        path.fill()
        NSColor(cgColor: C.border.cgColor(dark: dark))!.setStroke()
        path.lineWidth = 1 * s
        path.stroke()
        str.draw(at: NSPoint(x: box.minX + padX, y: box.minY + padY))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The macOS pointer (the system's own arrow / I-beam images), at screen size for the
    /// window's scale, a touch larger like recording apps draw it; it dips when it clicks.
    private func drawPointer(_ ctx: CGContext, _ time: Double, at p: CGPoint, k: Double) {
        let cursor = ibeam ? NSCursor.iBeam : NSCursor.arrow
        let img = cursor.image
        var rect = NSRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
        let dp = time - pressAt
        let dip = dp >= 0 && dp < 0.22 ? 1 - 0.16 * sin(.pi * dp / 0.22) : 1
        let w = img.size.width * k * dip, h = img.size.height * k * dip
        let hot = cursor.hotSpot  // from the top-left
        let r = CGRect(x: p.x - hot.x * k * dip, y: p.y - (img.size.height - hot.y) * k * dip, width: w, height: h)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor(white: 0, alpha: 0.3).cgColor)
        ctx.draw(cg, in: r)
        ctx.restoreGState()
    }

    /// The desktop: a quiet gradient and the top of the menu bar (lmux's own menus).
    private func makeDesk() -> CGImage? {
        let W = Int(Film.W), H = Int(Film.H)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sp = CGColorSpace(name: CGColorSpace.sRGB)!
        func col(_ hex: UInt32) -> CGColor {
            CGColor(colorSpace: sp, components: [CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255, CGFloat(hex & 255) / 255, 1])!
        }
        let (top, bottom, glowA, glowB): (UInt32, UInt32, UInt32, UInt32) = dark
            ? (0x1C2433, 0x0E1219, 0x2B3A55, 0x3A2C4A) : (0xDCE4EE, 0xBFCADB, 0xEEF2F8, 0xE6DCEB)
        let g = CGGradient(colorsSpace: sp, colors: [col(top), col(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: Film.H), end: CGPoint(x: Film.W * 0.3, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        for (c0, center, r) in [(glowA, CGPoint(x: Film.W * 0.18, y: Film.H * 0.85), Film.W * 0.55),
                                (glowB, CGPoint(x: Film.W * 0.9, y: Film.H * 0.1), Film.W * 0.5)] {
            let cc = col(c0)
            let rg = CGGradient(colorsSpace: sp, colors: [cc.copy(alpha: 0.55)!, cc.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(rg, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [])
        }
        // Menu bar.
        let mb = 44.0
        ctx.setFillColor(NSColor(white: dark ? 0.06 : 1, alpha: dark ? 0.45 : 0.42).cgColor)
        ctx.fill(CGRect(x: 0, y: Film.H - mb, width: Film.W, height: mb))
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        let fg = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.9 : 0.85)
        var x = 34.0
        let menus = ["lmux"] + (NSApp.mainMenu?.items.dropFirst().compactMap { $0.submenu?.title } ?? [])
        for (i, title) in menus.enumerated() where !title.isEmpty {
            let s = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 25, weight: i == 0 ? .bold : .medium),
                                                                   .foregroundColor: fg])
            s.draw(at: NSPoint(x: x, y: Film.H - mb + (mb - s.size().height) / 2))
            x += s.size().width + 36
        }
        var rx = Film.W - 34
        let clock = NSAttributedString(string: "Mon Nov 2  11:48 PM", attributes: [.font: NSFont.systemFont(ofSize: 25, weight: .medium),
                                                                                  .foregroundColor: fg])
        rx -= clock.size().width
        clock.draw(at: NSPoint(x: rx, y: Film.H - mb + (mb - clock.size().height) / 2))
        for name in ["switch.2", "magnifyingglass", "wifi", "battery.75percent"] {
            guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .medium)) else { continue }
            let tinted = NSImage(size: sym.size, flipped: false) { r in
                sym.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true
            }
            rx -= sym.size.width + 30
            tinted.draw(in: NSRect(x: rx, y: Film.H - mb + (mb - sym.size.height) / 2, width: sym.size.width, height: sym.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// The sidebar's spinners and breathing rows, posed at film time `time`.
    private func setMotion(_ time: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        c.root.sidebarHost.layoutSubtreeIfNeeded()
        func walk(_ v: NSView) {
            if let s = v as? Spinner.Arc, s.isSpinning {
                // One clockwise turn per spinnerPeriod (layer y points up: negative angle).
                let turn = (time / LmuxTokens.Motion.spinnerPeriod).truncatingRemainder(dividingBy: 1)
                s.arc.transform = CATransform3DMakeRotation(-2 * .pi * turn, 0, 0, 1)
            } else if String(reflecting: type(of: v)).hasPrefix("LmuxUI.Pulse<"),
                      let host = v.subviews.first, let glyph = host.layer,
                      let halo = v.layer?.sublayers?.first(where: { $0 !== glyph }) {
                if glyph.animation(forKey: "pulse") != nil {
                    // Attention.swift's breath: half a breath bright -> dim (ease in-out), then back;
                    // the glyph 1 -> 0.25, the halo opacity 1 -> 0 and scale 1 -> 0.55. Starts dim.
                    let start = breathStart[ObjectIdentifier(v)] ?? time
                    breathStart[ObjectIdentifier(v)] = start
                    let period = LmuxTokens.Motion.attentionBreath
                    let ph = ((time - start) / period + 0.5).truncatingRemainder(dividingBy: 1)
                    let half = ph < 0.5 ? ph * 2 : 2 - ph * 2
                    let e = easeInOut(half)
                    glyph.opacity = Float(1 - 0.75 * e)
                    halo.opacity = Float(1 - e)
                    halo.transform = CATransform3DMakeScale(1 - 0.45 * e, 1 - 0.45 * e, 1)
                } else {
                    breathStart[ObjectIdentifier(v)] = nil
                    glyph.opacity = 1
                    halo.opacity = 0
                }
            }
            v.subviews.forEach(walk)
        }
        walk(c.root.sidebarHost)
    }

    /// CAMediaTimingFunction(name: .easeInEaseOut), the cubic bezier (0.42, 0, 0.58, 1).
    private func easeInOut(_ x: Double) -> Double {
        var u = x
        for _ in 0..<8 {  // solve bx(u) = x (Newton)
            let bx = 3 * (1 - u) * (1 - u) * u * 0.42 + 3 * (1 - u) * u * u * 0.58 + u * u * u
            let d = 3 * (1 - u) * (1 - u) * 0.42 + 6 * (1 - u) * u * (0.58 - 0.42) + 3 * u * u * (1 - 0.58)
            if abs(d) < 1e-6 { break }
            u = min(1, max(0, u - (bx - x) / d))
        }
        return 3 * (1 - u) * u * u + u * u * u
    }

    /// A keycap pill, bottom center of the video: what was pressed, then it fades.
    private func drawKeycap(_ ctx: CGContext, _ label: String, alpha: Double) {
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        ctx.saveGState()
        ctx.setAlpha(alpha)
        let s = 2.0
        let font = NSFont.systemFont(ofSize: 17 * s, weight: .semibold)
        let fg = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.10, alpha: 1)
        let str = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: fg, .kern: 1.5 * s])
        let sz = str.size()
        let padX = 18 * s, padY = 9 * s
        let box = NSRect(x: Film.W / 2 - sz.width / 2 - padX, y: 36 * s, width: sz.width + 2 * padX, height: sz.height + 2 * padY)
        let path = NSBezierPath(roundedRect: box, xRadius: 10 * s, yRadius: 10 * s)
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * s), blur: 14 * s,
                      color: NSColor(white: 0, alpha: dark ? 0.55 : 0.2).cgColor)
        (dark ? NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 0.96)
              : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.97)).setFill()
        path.fill()
        ctx.setShadow(offset: .zero, blur: 0)
        (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.10)).setStroke()
        path.lineWidth = 1 * s
        path.stroke()
        str.draw(at: NSPoint(x: box.minX + padX, y: box.minY + padY))
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The README clip's caption. One place, for copy review.
enum HeroCaptions {
    static let forget = "Hit × and Claude forgets you ever asked."
}

// MARK: - Input

/// The replayed `claude` of session `s` (its pid file, see fake_claude.py's stepped mode).
func claudePID(_ s: LiveSession) -> pid_t? {
    let url = metaURL(s).deletingPathExtension().appendingPathExtension("pid")
    return (try? String(contentsOf: url, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// Every replayed `claude` that ever started (pid files under the projects dir).
func allClaudePIDs() -> [pid_t] {
    let fm = FileManager.default
    var out: [pid_t] = []
    for d in (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? [] {
        for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "pid" {
            if let p = (try? String(contentsOf: f, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                out.append(p)
            }
        }
    }
    return out
}

/// One key, through the window like a keyboard press (keyDown -> the pane's input path).
@MainActor
func heroKey(_ ch: Character, window: NSWindow) {
    let extra: [Character: (UInt16, Bool)] = [" ": (49, false), "?": (44, true), ",": (43, false), ".": (47, false),
                                              "'": (39, false), "-": (27, false), ":": (41, true), "⌫": (51, false)]
    guard let (code, shift) = KC.map[ch].map({ ($0, false) }) ?? extra[ch] else { return }
    let s = ch == "⌫" ? "\u{7f}" : String(ch)
    let ts = ProcessInfo.processInfo.systemUptime
    for t in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: ts,
                                 windowNumber: window.windowNumber, context: nil, characters: s,
                                 charactersIgnoringModifiers: s, isARepeat: false, keyCode: code)!
        dispatchKey(e, window: window)
    }
}

/// A person typing: ~60 ms a key with log-normal jitter, common pairs quicker, a beat at some
/// word starts, a pause before fixing a typo and quick backspaces. Seeded, so both themes type at
/// exactly the same moments.
struct Typist {
    var seed: UInt64 = 0x1F2E3D4C
    var prev: Character = " "
    mutating func next() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }
    mutating func gauss() -> Double { sqrt(-2 * log(max(next(), 1e-9))) * cos(2 * .pi * next()) }
    static let quick: Set<String> = ["th", "he", "in", "er", "an", "re", "on", "at", "en", "nd", "es", "or", "te", "ed", "is", "it", "ar", "st", "ou"]
    /// Delay before typing `ch` (seconds).
    mutating func delay(before ch: Character, speed: Double = 1) -> Double {
        defer { prev = ch }
        if ch == "⌫" { return prev == "⌫" ? 0.075 + 0.02 * next() : 0.26 + 0.08 * next() }
        var d = 0.058 * exp(0.33 * gauss())
        if Typist.quick.contains(String([prev, ch])) { d *= 0.65 }
        if prev == " " { d += next() < 0.2 ? 0.12 + 0.1 * next() : 0.02 * next() }
        if ch == "?" || ch == "," { d += 0.05 }
        return min(0.32, d) / speed
    }
}

// MARK: - The scene and the story

@MainActor
func runHero(_ out: URL, light: Bool) async -> Int32 {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let clip = Film.clipPass
    let c = makeReadmeController(size: clip ? Hero.clipWindow : readmeSize)
    NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
    // A fake clock for the unattended reminder (minutes pass in an instant), and the sidebar's
    // motion on even if this Mac has Reduce Motion set.
    var now = Date()
    c.attentionClock = { now }
    c.reduceMotionOverride = false
    c.updatePulseMotion()
    let first = c.model.selected!
    Hero.writeHistory()
    var bench = Hero.bench, ime = Hero.imeS, cmux = Hero.cmuxS, storm = Hero.storm
    for s in [Hero.redraw, bench, storm, ime, cmux, Hero.rel, Hero.siteS] { writeSession(s, ago: 1500) }
    // Stepped: every `claude` counts its timer in film ticks; answers stream as the film says.
    writeMeta(Hero.redraw, ["step": true])
    writeMeta(bench, ["step": true, "elapsed": 52, "tokens": 3400])
    writeMeta(storm, ["step": true, "elapsed": 40, "tokens": 1200])
    writeMeta(ime, ["step": true, "elapsed": 96, "tokens": 6100])
    writeMeta(cmux, ["step": true, "elapsed": 23, "tokens": 1900])
    writeMeta(Hero.rel, ["step": true])
    writeMeta(Hero.siteS, ["step": true])

    func ws(_ title: String, _ s: LiveSession) -> Workspace {
        let w = c.newWorkspace(cwd: s.cwd, command: "claude --resume \(s.id)", select: false)
        w.customTitle = title
        return w
    }
    // Each new one goes right after the selected (first) workspace: created last to first.
    let wSite = ws("site", Hero.siteS)
    let wRel = ws("notarize v0.1", Hero.rel)
    let wCmux = ws("cmux import", cmux)
    let wIme = ws("korean ime jamo", ime)
    let wRedraw = ws("fix sidebar redraw", Hero.redraw)
    c.closeWorkspace(first)
    let pL = wRedraw.panes[0], iP = wIme.panes[0], xP = wCmux.panes[0], rP = wRel.panes[0], sP = wSite.panes[0]
    let sh = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("split-bench.sh")
    try? "#!/bin/zsh -f\ncd '\(bench.cwd)'\ncodex resume \(bench.id)\nexec '\(paths.paneCommand ?? "/bin/zsh")'\n"
        .write(to: sh, atomically: true, encoding: .utf8)
    chmod(sh.path, 0o755)
    let pR = c.split(pL, .right, program: sh.path)!
    // The split's Claude has two tabs behind it (opened behind, so it stays shown and focused).
    let pS = c.newTab(pL, command: "claude --resume \(storm.id)", select: false)!
    _ = c.newTab(pL, after: pS, select: false)
    let all: [(Pane, LiveSession)] = [(pL, Hero.redraw), (pR, bench), (pS, storm), (iP, ime), (xP, cmux), (rP, Hero.rel), (sP, Hero.siteS)]
    let bound = await waitFor(20) { all.allSatisfy { $0.0.claudeSessionID == $0.1.id } }
    print(bound ? "all panes bound to their sessions" : "warning: not every pane bound")
    // Claude Code's own titles for each pane.
    for (p, title) in [(pL, "sidebar redraw"), (pR, "idle cpu before/after"), (pS, "title storm test"), (iP, "first jamo preedit"),
                       (xP, "cmux import"), (rP, "v0.1 release"), (sP, "hero video size")] {
        p.titleState = TitleState(title: title)
        c.titlesChanged(p)
    }

    // States, as Claude Code's hooks would report them. site finished a while ago and nobody
    // looked (3 minutes pass in an instant: it breathes); notarize failed 12 minutes ago.
    hookFor(c, sP, "UserPromptSubmit", Hero.siteS, ["prompt": Hero.sitePrompt])
    hookFor(c, sP, "Stop", Hero.siteS, ["last_assistant_message": Hero.siteReply])
    now = now.addingTimeInterval(3 * 60 + 5)
    hookFor(c, rP, "UserPromptSubmit", Hero.rel, ["prompt": Hero.relPrompt])
    hookFor(c, rP, "StopFailure", Hero.rel, ["error_type": "notarytool exited 65"])
    rP.lastAlertAt = Date().addingTimeInterval(-12 * 60 - 10)
    hookFor(c, pL, "UserPromptSubmit", Hero.redraw, ["prompt": Hero.redrawPrompt1])
    hookFor(c, pL, "Stop", Hero.redraw, ["last_assistant_message": "Every keystroke re-lays out the whole sidebar."])
    hookFor(c, pR, "UserPromptSubmit", bench, ["prompt": Hero.benchPrompt, "agent": "codex"])
    hookFor(c, pR, "PreToolUse", bench, ["tool_name": "Bash", "agent": "codex"])
    hookFor(c, pS, "UserPromptSubmit", storm, ["prompt": Hero.stormPrompt])
    hookFor(c, pS, "PreToolUse", storm, ["tool_name": "Bash"])
    hookFor(c, iP, "UserPromptSubmit", ime, ["prompt": Hero.imePrompt])
    hookFor(c, iP, "PreToolUse", ime, ["tool_name": "Bash"])
    hookFor(c, xP, "UserPromptSubmit", cmux, ["prompt": Hero.cmuxPrompt])
    hookFor(c, xP, "PreToolUse", cmux, ["tool_name": "Read"])
    c.model.clock = Date()

    // The opening: the split, the cursor in Claude's input box.
    c.select(wRedraw, focusing: pL)
    c.focus(pL)
    _ = await waitFor(10) { screenText(pL).contains("even though nothing") && screenText(pR).contains("Working") }
    await c.history.refresh()
    c.assumeAppActive = true
    c.updateAttention()
    func settle(_ ms: Int = 60) async {
        c.refreshPaneChrome()
        c.root.updateHeader()
        await sleepMs(ms)
    }
    await sleepMs(1500)
    await settle(300)
    if !clip { try? c.snapshotPNG(to: out.appendingPathComponent("hero.png"), scale: 4.0 / 3.0) }
    let film = Film(c, dark: !light, dir: out.appendingPathComponent("frames"))
    let rest = NSPoint(x: 700, y: 150)
    film.move(to: rest, dur: 0.001)

    // MARK: Per-frame plumbing
    let host = c.root.sidebarHost
    func rowHeight(_ w: Workspace) -> CGFloat {
        w.showsStateLine ? LmuxTokens.Layout.workspaceRowHeightDouble : LmuxTokens.Layout.workspaceRowHeightSingle
    }
    /// The workspace row under host point `hp`.
    func row(at hp: NSPoint) -> Workspace? {
        for (i, w) in c.model.workspaces.enumerated() {
            let ctr = rowPoint(c, i).y
            if abs(hp.y - ctr) <= rowHeight(w) / 2, hp.x > 8, hp.x < host.bounds.width - 8 { return w }
        }
        return nil
    }
    func rowCenter(_ w: Workspace, x: CGFloat = 92) -> NSPoint {
        let i = c.model.workspaces.firstIndex { $0 === w } ?? 0
        var p = rowPoint(c, i); p.x = x
        return host.convert(p, to: nil)
    }
    var lastHover = NSPoint(x: -1, y: -1)
    /// What the pointer is over: hover states follow it, as they would under a real mouse.
    func hoverAt(_ w: NSPoint) {
        guard w != lastHover else { return }
        lastHover = w
        let hp = host.convert(w, from: nil)
        let panes = c.model.selected?.panes ?? []
        if host.bounds.contains(hp) {
            c.model.hoveredRowID = row(at: hp)?.id
            panes.forEach { c.hideHoverActions($0) }
            film.ibeam = false
            return
        }
        c.model.hoveredRowID = nil
        var beam = false
        for p in panes {
            let sp = p.surface.convert(w, from: nil)
            if p.surface.bounds.contains(sp) {
                c.paneMouseMoved(p, sp)
                let ov = p.view.overlay
                let op = ov.convert(w, from: nil)
                let onChrome = [ov.turnBar?.frame, ov.card?.frame, ov.toast?.frame].contains { $0?.contains(op) == true }
                beam = !onChrome
            } else {
                c.hideHoverActions(p)
            }
        }
        film.ibeam = beam
    }
    var spinAt = -1.0
    /// `dt` seconds of film: per frame, the pointer moves and hovers, the `claude`s tick every
    /// 0.1 s, the app gets a moment to draw, then the frame.
    func run(_ dt: Double) async {
        let end = film.t + dt
        while Double(film.n) / film.fps < end - 1e-9 {
            let time = Double(film.n) / film.fps
            if time >= spinAt + 0.1 - 1e-9 {
                spinAt = time
                for pid in allClaudePIDs() { kill(pid, SIGUSR2) }
                await sleepMs(40)
            } else {
                await sleepMs(12)
            }
            film.frame()
            hoverAt(film.pointer)
        }
    }
    func moveTo(_ p: NSPoint, _ dur: Double, then hold: Double = 0) async {
        film.move(to: p, dur: dur)
        await run(dur + hold)
    }
    /// The next streamed line of `s` in `p`, then `hold` s of film.
    func step(_ s: LiveSession, _ p: Pane, hold: Double) async {
        let before = screenText(p)
        if let pid = claudePID(s) { kill(pid, SIGUSR1) }
        _ = await waitFor(2) { screenText(p) != before }
        await settle(40)
        await run(hold)
    }
    /// How long a streamed line stays before the next: tool calls run a while, results and text
    /// come quickly, a diff almost at once.
    func hold(_ line: String) -> Double {
        let plain = line.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
        if plain.isEmpty { return 0 }
        if plain.hasPrefix("⏺ ") && plain.contains("(") { return 0.34 }
        if plain.contains("⎿") { return 0.16 }
        if plain.hasPrefix("      ") { return 0.05 }
        return 0.08
    }
    var typist = Typist()
    /// Type `text` (⌫ = backspace) into Claude's input in `p`, like a person.
    func typeInto(_ p: Pane, _ text: String, speed: Double = 1.15) async {
        var buf = ""
        for ch in text {
            await run(typist.delay(before: ch, speed: speed))
            heroKey(ch, window: c.window)
            if ch == "⌫" { _ = buf.popLast() } else { buf.append(ch) }
            let want = "❯ " + buf
            _ = await waitFor(1) { screenText(p).components(separatedBy: "\n").contains { $0.hasPrefix(want) && $0.dropFirst(want.count).allSatisfy { $0 == " " } } }
            await sleepMs(10)
        }
    }
    func clickRow(_ w: Workspace) async {
        film.press()
        await run(0.06)
        await click(host, at: host.convert(rowCenter(w), from: nil))
        if c.model.selected !== w { c.select(w) }
        await settle(80)
    }
    func center(of v: NSView) -> NSPoint {
        let f = v.convert(v.bounds, to: nil)
        return NSPoint(x: f.midX, y: f.midY)
    }
    func paneFocus(_ p: Pane, dy: CGFloat = 0) -> NSPoint {
        let f = p.surface.convert(p.surface.bounds, to: nil)
        return NSPoint(x: f.midX, y: f.midY + dy)
    }
    func shiftCmdReturn() {
        let ts = ProcessInfo.processInfo.systemUptime
        for t in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [.command, .shift], timestamp: ts,
                                     windowNumber: c.window.windowNumber, context: nil, characters: "\r",
                                     charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            dispatchKey(e, window: c.window)
        }
        if (c.model.selected?.zoomedPane == nil) == zoomWanted { c.toggleSplitZoom() }
        zoomWanted.toggle()
    }
    var zoomWanted = true

    // MARK: The story

    // Overview: five workspaces in every state at once.
    await run(0.5)

    // 1. Into the split; a prompt typed (a typo, fixed) into the idle side.
    film.camera(1.12, NSPoint(x: 600, y: 470), over: 1.3)
    await run(0.4)
    await typeInto(pL, Hero.typed)
    await run(0.3)
    await type("\r", window: c.window)
    _ = await waitFor(2) { screenText(pL).contains("Percolating") }
    await settle(40)
    await run(0.4)
    film.camera(1.05, NSPoint(x: 560, y: 420), over: 1.4)
    let reply = Hero.redraw.replies[0]["screen"]!.components(separatedBy: "\n")
    var benchShown = bench.screens[Hero.benchPrompt]!
    for (i, line) in reply.enumerated() {
        await step(Hero.redraw, pL, hold: hold(line))
        // Meanwhile, the other side of the split keeps going.
        if [2, 5, 9, 13].contains(i) || i == reply.count - 1 {
            let k = [2: 0..<2, 5: 2..<3, 9: 3..<4, 13: 4..<5][i] ?? 5..<Hero.benchMore.count
            for l in Hero.benchMore[k] { benchShown += "\n" + l }
            bench.screens[Hero.benchPrompt] = benchShown
            if k.contains(5) { bench.working = nil }
            writeMeta(bench, ["step": true, "elapsed": 52, "tokens": 3400, "worked": "Worked for 1m 31s • 11:46 PM"])
            if Hero.benchMore[k].contains(where: { $0.contains("• Ran") }) {
                hookFor(c, pR, "PreToolUse", bench, ["tool_name": "Bash", "agent": "codex"])
            }
            if bench.working == nil {
                hookFor(c, pR, "Stop", bench, ["last_assistant_message": "2.9% → 0.4% idle.", "agent": "codex"])
            }
            await settle(30)
        }
        // …and korean ime jamo finishes in the background: ✓, the bell ticks.
        if i == 4 {
            ime.working = nil
            ime.screens[Hero.imePrompt]! += "\n" + result("\(aGreen)✓\(aOff) 14 checks passed") + "\n\n" + said(Hero.imeDone)
                + "\n\n\(aDim)✻ Worked for 2m 9s\(aOff)"
            writeMeta(ime, ["step": true])
            hookFor(c, iP, "PostToolUse", ime, ["tool_name": "Bash"])
            hookFor(c, iP, "Stop", ime, ["last_assistant_message": Hero.imeDone])
            c.model.clock = Date()
            await settle()
        }
        // …and the title-storm tab behind the split's Claude finishes: its tab gets the badge.
        if i == 7 {
            storm.working = nil
            storm.screens[Hero.stormPrompt]! += "\n" + result("20 runs, 760 passed") + "\n\n" + said(Hero.stormDone)
            writeMeta(storm, ["step": true])
            hookFor(c, pS, "PostToolUse", storm, ["tool_name": "Bash"])
            hookFor(c, pS, "Stop", storm, ["last_assistant_message": Hero.stormDone])
            await settle()
        }
        // …and cmux import needs input: ring, badge, "Permission: Bash".
        if i == 10 {
            cmux.working = nil
            cmux.dialog = Hero.cmuxDialog
            writeMeta(cmux, ["approved": Hero.cmuxApproved, "approved_working": "Spelunking…", "step": true,
                             "elapsed": 31, "tokens": 2300])
            _ = await waitFor(3) { screenText(xP).contains("Do you want to proceed") }
            hookFor(c, xP, "PreToolUse", cmux, ["tool_name": "Bash"])
            hookFor(c, xP, "PermissionRequest", cmux, ["tool_name": "Bash"])
            await settle()
        }
    }
    _ = await waitFor(2) { pL.agent.state != .running }
    await settle()
    await run(0.3)
    // ⇧⌘↩: the answer full width for a moment, then back to the split.
    film.camera(1.08, NSPoint(x: 700, y: 430), over: 0.9)
    await run(film.keycap("⇧⌘↩"))
    shiftCmdReturn()
    await settle(150)
    await run(0.7)
    await run(film.keycap("⇧⌘↩"))
    shiftCmdReturn()
    await settle(150)
    await run(0.3)

    print(String(format: "beat %.1fs: ", film.t) + "2. ⇧⌘J")
    // 2. ⇧⌘J: to the one waiting; `1` approves and it carries on.
    await run(film.keycap("⇧⌘J"))
    await cmd("j", shift: true, window: c.window)
    await settle(120)
    film.camera(1.12, paneFocus(xP, dy: 60), over: 1.0)
    await run(0.55)
    await run(film.keycap("1", lead: 0.18))
    await type("1", window: c.window)
    _ = await waitFor(3) { !screenText(xP).contains("Do you want to proceed") }
    await settle(40)
    await run(0.15)
    for line in Hero.cmuxApproved.components(separatedBy: "\n") {
        await step(cmux, xP, hold: hold(line))
    }
    await run(0.2)

    print(String(format: "beat %.1fs: ", film.t) + "3. A prompt")
    // 3. A prompt for the release goes to "site" by mistake: × takes it back.
    film.camera(1.0, nil, over: 1.2)
    await moveTo(rowCenter(wSite), 0.6, then: 0.1)
    await clickRow(wSite)
    film.camera(1.1, paneFocus(sP, dy: 120), over: 1.1)
    await moveTo(NSPoint(x: 760, y: 170), 0.45)
    await typeInto(sP, Hero.resend, speed: 1.3)
    await run(0.2)
    await type("\r", window: c.window)
    _ = await waitFor(2) { screenText(sP).contains("Pondering") }
    await settle(40)
    await run(0.35)
    for _ in Hero.siteS.replies[0]["screen"]!.components(separatedBy: "\n") {
        await step(Hero.siteS, sP, hold: 0.12)
    }
    _ = await waitFor(3) { sP.agent.state != .running }
    await settle()
    await run(0.3)
    // Hover the prompt: the turn's pill (⧉ ✎ ×); × → Forget.
    sP.hover.readAt = .distantPast
    _ = await c.loadTurns(sP)
    let map = c.screenMap(sP, maxAge: 0)
    if let h = map.map?.promptHeads().first(where: { $0.turn == 2 }) {
        let y = sP.surface.bounds.height - (map.rows[h.row].top + map.rowHeight / 2)
        let head = sP.surface.convert(NSPoint(x: 230, y: y), to: nil)
        if clip {
            // The clip starts here, held on the site pane: the prompt row, ✎ × and its tooltip,
            // the Remove card to come, Claude's answer, the input below.
            let pane = sP.surface.convert(sP.surface.bounds, to: nil)
            let ch = pane.width * Hero.clipWindow.height / Hero.clipWindow.width
            film.clipRect = CGRect(x: pane.minX, y: head.y - 65 - ch / 2, width: pane.width, height: ch)
            film.clipCaption = HeroCaptions.forget
            film.clipOn = true
            await run(0.4)  // the wrong prompt and Claude's answer, read at a glance
        }
        // (The clip's moves are a touch slower: it's watched at a glance, not followed.)
        await moveTo(head, clip ? 0.65 : 0.5, then: 0.25)
    }
    if let bar = sP.view.overlay.turnBar, !bar.isHidden {
        await moveTo(center(of: bar.remove), 0.35)
        bar.remove.mouseEntered(with: NSEvent())
        await run(clip ? 0.5 : 0.2)
        film.press()
        await run(0.08)
        bar.remove.mouseExited(with: NSEvent())
        bar.remove.performClick()
        await settle(80)
        await run(0.3)
    } else {
        print("warning: no turn pill on site's prompt")
    }
    if let card = sP.view.overlay.card {
        await moveTo(center(of: card.confirm), clip ? 0.5 : 0.4)
        card.confirm.mouseEntered(with: NSEvent())
        await run(clip ? 0.3 : 0.15)
        film.press()
        await run(0.08)
        card.confirm.performClick()
        // The clip cuts from the click to the prompt gone: in between lmux steps through Claude
        // Code's rewind menu, nothing to watch (the card closes, the transcript waits a moment).
        film.clipOn = false
        await settle(60)
        await run(0.25)
        _ = await waitFor(12) {
            let s = screenText(sP)
            return !s.contains(Hero.resend) && s.contains("accept edits") && !sP.busy
        }
        await settle(150)
        if clip {
            // The prompt gone, held long enough to see it's gone, and the clip ends (it loops
            // through a dip, hero.sh).
            film.clipOn = true
            await run(1.1)
            film.report()
            c.clearPendingUndo()
            c.shutdown()
            return 0
        }
        await run(0.25)
    } else {
        print("warning: no forget card")
    }

    print(String(format: "beat %.1fs: ", film.t) + "4. ⌘4")
    // 4. ⌘4: where it belongs.
    await moveTo(NSPoint(x: 760, y: 150), 0.4)
    await run(film.keycap("⌘4"))
    await cmd("4", window: c.window)
    await settle(120)
    film.camera(1.1, paneFocus(rP, dy: 120), over: 0.9)
    await run(0.2)
    await typeInto(rP, Hero.resend, speed: 1.6)
    await run(0.15)
    await type("\r", window: c.window)
    _ = await waitFor(2) { screenText(rP).contains("Brewing") }
    await settle(40)
    await run(0.35)
    // (Its last line never comes: notarytool is still waiting at the end.)
    for line in Hero.rel.replies[0]["screen"]!.components(separatedBy: "\n").dropLast() {
        await step(Hero.rel, rP, hold: hold(line))
    }
    await run(0.2)

    print(String(format: "beat %.1fs: ", film.t) + "Drag")
    // Drag: notarize v0.1 goes to the top of the list (it lifts and follows the pointer, the rows above slide down).
    film.camera(1.0, nil, over: 1.1)
    await moveTo(rowCenter(wRel), 0.55, then: 0.1)
    film.press()
    await run(0.1)
    let top = rowCenter(c.model.workspaces[0])
    film.move(to: NSPoint(x: top.x + 6, y: top.y + 14), dur: 0.55)
    let startY = rowCenter(wRel).y
    let pressAt = host.convert(film.pointer, from: nil)
    let pressY = host.isFlipped ? pressAt.y : host.bounds.height - pressAt.y
    let steps = Int(0.55 * film.fps)
    for k in 0..<steps {
        await run(1 / film.fps)
        let hp = host.convert(film.pointer, from: nil)
        let yTop = host.isFlipped ? hp.y : host.bounds.height - hp.y
        let others = c.model.workspaces.filter { $0 !== wRel }
        var idx = 0
        for (j, w) in others.enumerated() {
            let i = c.model.workspaces.firstIndex { $0 === w }!
            let ctr = rowPoint(c, i).y
            let cy = host.isFlipped ? ctr : host.bounds.height - ctr
            if yTop > cy { idx = j + 1 }
        }
        if k > 2 || film.pointer.y > startY + 8 { c.sidebarDragUpdate(wRel, dropIndex: idx, pointerY: yTop, translation: yTop - pressY) }
    }
    await run(0.25)
    print("drag: \(c.model.sidebarDrag.map { "\($0.dropIndex)" } ?? "none")")
    c.sidebarDragEnded()
    await settle(150)
    print("order after drag: \(c.model.workspaces.map(\.title))")
    await run(0.3)

    print(String(format: "beat %.1fs: ", film.t) + "5. ⇧⌘H")
    // 5. ⇧⌘H: "ghostty" finds old sessions; Enter resumes one in a new workspace.
    film.camera(1.06, NSPoint(x: 330, y: 300), over: 1.1)
    await run(film.keycap("⇧⌘H"))
    await cmd("h", shift: true, window: c.window)
    await settle(150)
    await run(0.2)
    var query = ""
    for ch in "ghostty" {
        await run(typist.delay(before: ch))
        heroKey(ch, window: c.window)
        query.append(ch)
        _ = await waitFor(1) { c.history.query == query }
        await settle(30)
    }
    _ = await waitFor(3) { c.history.query == "ghostty" && !c.history.items.isEmpty }
    await settle(150)
    await run(0.5)
    let before = Set(c.model.workspaces.map(\.id))
    await run(film.keycap("↩", lead: 0.15))
    await type("\r", window: c.window)
    if !(await waitFor(1) { c.model.workspaces.contains { !before.contains($0.id) } }) { c.history.resumeSelected() }
    var resumed: Pane?
    _ = await waitFor(8) {
        resumed = c.model.workspaces.first { !before.contains($0.id) }?.panes.first
        return resumed.map { screenText($0).contains("accept edits") } ?? false
    }
    await settle(150)
    await run(0.5)

    print(String(format: "beat %.1fs: ", film.t) + "The overview again")
    // The overview again: nobody looked at korean ime jamo for 3 minutes, it breathes too.
    now = now.addingTimeInterval(3 * 60 + 5)
    c.updateAttention()
    film.camera(1.0, nil, over: 1.4)
    await moveTo(rest, 0.9, then: 0.5)
    film.fade(0.7)
    await run(0.7)
    film.report()
    if let img = film.first, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
        try? png.write(to: out.appendingPathComponent("poster.png"))
    }
    print("states: ime=\(iP.agent.state) cmux=\(xP.agent.state) rel=\(rP.agent.state) bell=\(c.model.workspaces.reduce(0) { $0 + $1.unread }) "
          + "breathing=\(c.model.workspaces.filter { $0.unattendedSince != nil }.map(\.title)) history=\(c.history.items.count) "
          + "typed=\(screenText(pL).contains("❯ " + Hero.typedText)) resumed=\(resumed != nil)")
    c.clearPendingUndo()
    c.shutdown()
    return 0
}

/// `writeMeta` plus fake_claude's extra keys ("approved", "approved_working", "step", "elapsed", "tokens").
func writeMeta(_ s: LiveSession, _ extra: [String: Any]) {
    var m: [String: Any] = ["screens": s.screens, "replies": s.replies]
    if let d = s.dialog { m["dialog"] = d }
    if let w = s.working { m["working"] = w }
    for (k, v) in extra { m[k] = v }
    try? JSONSerialization.data(withJSONObject: m).write(to: metaURL(s))
}
