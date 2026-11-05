import AppKit
import GhosttyKit
import ImageIO
import IOSurface
import LmuxTerminal
import UniformTypeIdentifiers
@testable import LmuxUI

// `lmux-apptest --contrast`: text the renderer draws must stay readable whatever the theme pair
// (lmux's terminal theme x Claude Code's own theme). Static screens of Claude Code's real output
// (App/scripts/contrast/*.ans, captured from the real CLI, see capture.py there) plus ls / git /
// 256-color samples are shown in panes, every theme is applied in turn, and each run of text is
// measured from the pane's pixels (the IOSurface the renderer draws into): the WCAG ratio of its
// most-covered glyph pixel against the cell background. Headless, offscreen, no shell.
//
//   lmux-apptest --contrast              worst cases under lmux's defaults (assertions, < 30 s)
//   lmux-apptest --contrast-matrix DIR   every bundled theme x fixture, minimum-contrast off
//                                        (Ghostty's default) and lmux's: DIR/matrix.json + crops
//
// Env: LMUX_CONTRAST_DIR (the fixtures), GHOSTTY_RESOURCES_DIR (themes), LMUX_CONTRAST_FONT=korean.

struct ContrastFixture: Decodable {
    struct Run: Decodable { let row: Int; let cols: [Int]; let sgr: String; let kind: String; let text: String }
    let label: String
    let runs: [Run]
}

struct RunResult: Encodable {
    let fixture: String, theme: String, minimumContrast: String, kind: String, sgr: String, text: String
    let ratio: Double, fg: String, bg: String
    /// SGR attributes, without the components of 38/48 colors (`38;2;r;g;b`, `38;5;n`).
    var attributes: [Int] {
        let p = sgr.split(separator: ";").compactMap { Int($0) }
        var out: [Int] = [], i = 0
        while i < p.count {
            if p[i] == 38 || p[i] == 48 { out.append(p[i]); i += (i + 1 < p.count && p[i + 1] == 2) ? 5 : 3; continue }
            out.append(p[i]); i += 1
        }
        return out
    }
    var faint: Bool { attributes.contains(2) }
}

/// sRGB channel -> linear, for WCAG relative luminance.
let srgbToLinear: [Double] = (0..<256).map { c in
    let s = Double(c) / 255
    return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
}

func wcagRatio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
func hex(_ v: UInt32) -> String { String(format: "#%06x", v) }
func lum(_ v: UInt32) -> Double {
    0.2126 * srgbToLinear[Int(v >> 16 & 0xFF)] + 0.7152 * srgbToLinear[Int(v >> 8 & 0xFF)] + 0.0722 * srgbToLinear[Int(v & 0xFF)]
}

/// Ghostty's IOSurface is Display P3 (metal/Target.zig); sRGB theme colors are converted in its
/// shader. Pixels are read back as sRGB through this (cached per color).
@MainActor
enum P3 {
    static var cache: [UInt32: UInt32] = [:]
    static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!, srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static func srgb(_ v: UInt32) -> UInt32 {
        if let c = cache[v] { return c }
        let comps: [CGFloat] = [CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255, 1]
        let c = CGColor(colorSpace: p3, components: comps)!.converted(to: srgb, intent: .relativeColorimetric, options: nil)!
        let k = c.components!.prefix(3).map { UInt32(max(0, min(255, ($0 * 255).rounded()))) }
        let out = k[0] << 16 | k[1] << 8 | k[2]
        cache[v] = out
        return out
    }
}

/// The pixels of a pane as the renderer left them (BGRA8, Display P3), copied straight from its IOSurface.
struct PanePixels {
    let width: Int, height: Int, bpr: Int
    let bytes: [UInt8]
    init?(_ s: SurfaceView) {
        guard let contents = s.layer?.contents else { return nil }
        let surf = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        IOSurfaceLock(surf, .readOnly, nil)
        defer { IOSurfaceUnlock(surf, .readOnly, nil) }
        width = IOSurfaceGetWidth(surf); height = IOSurfaceGetHeight(surf); bpr = IOSurfaceGetBytesPerRow(surf)
        bytes = [UInt8](UnsafeRawBufferPointer(start: IOSurfaceGetBaseAddress(surf), count: bpr * height))
    }
    /// 0xRRGGBB at (x, y), top-left origin, as stored (Display P3).
    subscript(x x: Int, y y: Int) -> UInt32 {
        let i = y * bpr + x * 4
        return UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i])
    }
    /// The same pixel in sRGB.
    @MainActor func srgb(x: Int, y: Int) -> UInt32 { P3.srgb(self[x: x, y: y]) }

    @MainActor func cgImage(x: Int, y: Int, w: Int, h: Int) -> CGImage? {
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for yy in 0..<h { for xx in 0..<w {
            let v = P3.srgb(self[x: x + xx, y: y + yy]), i = (yy * w + xx) * 4
            out[i] = UInt8(v >> 16 & 0xFF); out[i + 1] = UInt8(v >> 8 & 0xFF); out[i + 2] = UInt8(v & 0xFF)
        } }
        guard let prov = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Grid geometry of a pane in its IOSurface's pixels (Ghostty: padding at the top left, unbalanced).
struct Grid {
    let x0: Int, y0: Int, cw: Int, ch: Int
    @MainActor init?(_ s: SurfaceView, _ p: PanePixels) {
        guard let size = s.surfaceSize, size.cell_width_px > 0 else { return nil }
        let scale = Double(p.width) / Double(max(1, s.bounds.width))
        cw = Int(size.cell_width_px); ch = Int(size.cell_height_px)
        x0 = Int((14 * scale).rounded(.down)); y0 = Int((10 * scale).rounded(.down))
    }
}

/// Measure every run of a fixture: per cell, background = the most common of its four corner
/// pixels, text = the pixel of highest contrast against it; a run's ratio is its best cell
/// (thin glyphs such as `.` never reach full coverage, the stems of the others do).
@MainActor
func measure(_ f: ContrastFixture, name: String, theme: String, mc: String, _ p: PanePixels, _ g: Grid) -> [RunResult] {
    var out: [RunResult] = []
    for run in f.runs {
        var best = (ratio: 0.0, fg: UInt32(0), bg: UInt32(0))
        for col in run.cols {
            let cx = g.x0 + col * g.cw, cy = g.y0 + run.row * g.ch
            guard cx + g.cw <= p.width, cy + g.ch <= p.height else { continue }
            let corners = [p.srgb(x: cx, y: cy), p.srgb(x: cx + g.cw - 1, y: cy), p.srgb(x: cx, y: cy + g.ch - 1),
                           p.srgb(x: cx + g.cw - 1, y: cy + g.ch - 1)]
            let bg = corners.max { a, b in corners.filter { $0 == a }.count < corners.filter { $0 == b }.count }!
            let lb = lum(bg)
            var cell = (ratio: 1.0, fg: bg)
            var seen = Set<UInt32>()
            for y in cy..<(cy + g.ch) { for x in cx..<(cx + g.cw) {
                let raw = p[x: x, y: y]
                guard seen.insert(raw).inserted else { continue }
                let c = P3.srgb(raw)
                let r = wcagRatio(lum(c), lb)
                if r > cell.ratio { cell = (r, c) }
            } }
            if cell.ratio > best.ratio { best = (cell.ratio, cell.fg, bg) }
        }
        out.append(RunResult(fixture: name, theme: theme, minimumContrast: mc, kind: run.kind, sgr: run.sgr,
                             text: run.text, ratio: (best.ratio * 100).rounded() / 100, fg: hex(best.fg), bg: hex(best.bg)))
    }
    return out
}

/// Within 2/255 per channel (the P3 round trip rounds).
func near(_ a: UInt32, _ b: UInt32) -> Bool {
    (0..<3).allSatisfy { (i: Int) -> Bool in
        let sh = UInt32(i * 8)
        let x = Int((a >> sh) & 0xFF), y = Int((b >> sh) & 0xFF)
        return abs(x - y) <= 2
    }
}

func themeBackground(_ theme: String) -> UInt32? {
    let dir = env["GHOSTTY_RESOURCES_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("themes") }
    guard let text = dir.flatMap({ try? String(contentsOf: $0.appendingPathComponent(theme), encoding: .utf8) }) else { return nil }
    for line in text.split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if kv.count == 2, kv[0] == "background" { return UInt32(kv[1].replacingOccurrences(of: "#", with: ""), radix: 16) }
    }
    return nil
}

@MainActor
final class ContrastBench {
    let c: LmuxController
    var fixtures: [(name: String, fixture: ContrastFixture, ws: Workspace)] = []
    let dir: URL

    init() {
        dir = URL(fileURLWithPath: env["LMUX_CONTRAST_DIR"] ?? "")
        let profile: LmuxConfig.FontProfile = env["LMUX_CONTRAST_FONT"] == "korean" ? .korean : .default
        guard let runtime = GhosttyRuntime(fontProfile: profile) else { print("runtime init failed"); _exit(2) }
        GhosttyRuntime.standardPasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lmux.contrast.\(getpid())"))
        c = LmuxController(runtime: runtime, paths: paths, headless: true)
        // Two Claude screens of 100 columns side by side: about 205 x 52 cells at 13pt.
        c.start(windowFrame: NSRect(x: 0, y: 0, width: 2000, height: 1000))
    }

    func load(_ names: [String]) async -> Bool {
        let scripts = URL(fileURLWithPath: env["TMPDIR"] ?? NSTemporaryDirectory())
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")),
                  let f = try? JSONDecoder().decode(ContrastFixture.self, from: data) else { print("no fixture \(name)"); return false }
            // The pane prints the static screen, says it's ready and waits (no shell).
            let sh = scripts.appendingPathComponent("contrast-\(name).sh")
            try? """
            #!/bin/sh
            stty -echo
            cat '\(dir.appendingPathComponent("\(name).ans").path)'
            touch "$LMUX_SINK_DIR/$LMUX_PANE_ID.ready"
            exec cat >/dev/null
            """.write(to: sh, atomically: true, encoding: .utf8)
            chmod(sh.path, 0o755)
            let ws = c.newWorkspace(select: true, program: sh.path)
            guard await sinks.waitReady(ws.panes[0].id, timeout: 15) else { print("pane for \(name) never ready"); return false }
            fixtures.append((name, f, ws))
        }
        return true
    }

    /// Apply `theme` (and `minimum-contrast = mc` unless nil: lmux's default applies) to every pane.
    func apply(theme: String, mc: String?) {
        c.runtime.reloadConfig(overrides: ["theme = \(theme)"] + (mc.map { ["minimum-contrast = \($0)"] } ?? []))
    }

    /// The selected pane's pixels once it shows `theme`'s background and two reads agree.
    func pixels(_ ws: Workspace, theme: String) async -> (PanePixels, Grid)? {
        if c.model.selected !== ws { c.select(ws) }
        let s = ws.panes[0].surface
        let want = themeBackground(theme)
        var last: PanePixels?
        var seen = "none"
        defer { _ = seen }
        let end = Date().addingTimeInterval(4)
        while Date() < end {
            await sleepMs(40)
            guard let p = PanePixels(s), p.width > 8 else { continue }
            if let want, !near(p.srgb(x: 2, y: 2), want) { last = nil; seen = hex(p.srgb(x: 2, y: 2)); continue }
            if let l = last, l.bytes == p.bytes, let g = Grid(s, p) { return (p, g) }
            last = p
        }
        print("      no stable frame: corner \(seen), want \(want.map(hex) ?? "?")")
        return nil
    }

    func measureAll(theme: String, mc: String?, label: String) async -> [RunResult]? {
        apply(theme: theme, mc: mc)
        var all: [RunResult] = []
        for (name, f, ws) in fixtures {
            guard let (p, g) = await pixels(ws, theme: theme) else { print("no frame: \(name) / \(theme)"); return nil }
            all += measure(f, name: name, theme: theme, mc: label, p, g)
        }
        return all
    }

    /// The content header's labels (they sit on the terminal's background): name, ratio, fg, bg.
    func header(theme: String, dark: Bool) async -> [(String, Double, String, String)] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        apply(theme: theme, mc: nil)
        guard let fx = fixtures.first, await pixels(fx.ws, theme: theme) != nil else { return [] }
        fx.ws.customTitle = "auth fix"
        fx.ws.panes[0].cwd = NSHomeDirectory() + "/code/acme-api"
        fx.ws.panes[0].branch = "main"
        await sleepMs(60)
        c.root.updateHeader()
        c.window.contentView?.layoutSubtreeIfNeeded()
        guard let img = c.snapshotImage(scale: 2) else { return [] }
        let W = img.width, H = img.height
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        guard let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        let h = c.root.header
        if let shots = env["LMUX_CONTRAST_SHOTS"], theme == "Dracula", !dark {
            // The header (and the sidebar's top) in a dark theme under a light macOS.
            let r = h.convert(h.bounds, to: nil)
            if let crop = img.cropping(to: CGRect(x: 0, y: H - Int(r.maxY * 2), width: min(W, Int(r.maxX * 2) / 2), height: Int(r.height * 2))),
               let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: shots).appendingPathComponent("header-dracula-light-appearance.png") as CFURL,
                                                          UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, crop, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        var out: [(String, Double, String, String)] = []
        for (name, l) in [("title", h.title), ("branch", h.branch), ("path", h.subtitle)] where !l.stringValue.isEmpty && !l.isHidden {
            let r = l.convert(l.bounds, to: nil)
            let x0 = Int(r.minX * 2), x1 = Int(r.maxX * 2), y0 = H - Int(r.maxY * 2), y1 = H - Int(r.minY * 2)
            var counts: [UInt32: Int] = [:]
            for y in max(0, y0)..<min(H, y1) { for x in max(0, x0)..<min(W, x1) {
                let i = (y * W + x) * 4
                counts[UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]), default: 0] += 1
            } }
            guard let bg = counts.max(by: { $0.value < $1.value })?.key else { continue }
            let fg = counts.keys.max { wcagRatio(lum($0), lum(bg)) < wcagRatio(lum($1), lum(bg)) } ?? bg
            out.append((name, (wcagRatio(lum(fg), lum(bg)) * 100).rounded() / 100, hex(fg), hex(bg)))
        }
        return out
    }

    func crop(_ name: String, theme: String, mc: String?, rows: Range<Int>, cols: Range<Int>, to url: URL) async {
        guard let fx = fixtures.first(where: { $0.name == name }) else { return }
        apply(theme: theme, mc: mc)
        guard let (p, g) = await pixels(fx.ws, theme: theme) else { return }
        let x = g.x0 + cols.lowerBound * g.cw - g.cw / 2, y = g.y0 + rows.lowerBound * g.ch - g.ch / 3
        let w = min(p.width - x, cols.count * g.cw + g.cw), h = min(p.height - y, rows.count * g.ch + g.ch * 2 / 3)
        guard let img = p.cgImage(x: max(0, x), y: max(0, y), w: w, h: h),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
}

let contrastFixtures = ["claude-dark", "claude-light", "claude-dark-ansi", "claude-light-ansi", "claude-markdown", "samples"]

// MARK: - Regression (apptest.sh)

/// Where it broke before lmux set `minimum-contrast`: Claude Code's default (dark) theme in light
/// terminals, its light theme in dark ones, both ANSI variants, and the ls / git / ANSI samples.
let contrastWorstThemes = ["Nord Light", "iTerm2 Solarized Light", "Gruvbox Light", "Everforest Light Med", "Nord",
                           "Catppuccin Mocha", "Dracula"]
/// lmux's `minimum-contrast` (GhosttyConfig.swift): no text below it.
let contrastFloor = 2.0

extension RunResult {
    /// Colors the app picks as a pair (fg and bg): its own choice, not the theme's.
    var setsBackground: Bool { attributes.contains { (40...48).contains($0) || (100...107).contains($0) } }
    var id: String { "\(fixture)|\(kind)|\(sgr)|\(text)" }
}

@MainActor
func runContrast() async -> Int32 {
    let r = Report()
    r.section = "contrast"
    let t0 = Date()
    let bench = ContrastBench()
    let c = bench.c
    guard await bench.load(contrastFixtures) else { r.check("fixtures load", false); return finish(r, c) }
    func show(_ x: [RunResult]) -> String {
        x.prefix(3).map { "\($0.fixture) \($0.kind) \"\($0.text.prefix(20))\" \($0.fg) on \($0.bg) \($0.ratio)" }.joined(separator: "; ")
    }
    // Hermetic: lmux's defaults, not the user's Ghostty config (apptest.sh: LMUX_IGNORE_GHOSTTY_CONFIG=1).
    var mcValue: Double = 0   // f64 in Ghostty's config
    let mcKey = "minimum-contrast"
    let mcNow: Double? = c.runtime.config.flatMap { ghostty_config_get($0, &mcValue, mcKey, UInt(mcKey.utf8.count)) ? mcValue : nil }
    r.check("hermetic: the user's Ghostty config is not read, minimum-contrast is lmux's \(contrastFloor)",
            env["LMUX_IGNORE_GHOSTTY_CONFIG"] == "1" && mcNow.map { abs($0 - contrastFloor) < 0.001 } == true, "\(mcNow.map { "\($0)" } ?? "nil")")
    // Ghostty's default (no minimum contrast): the user reports, Claude's code nearly invisible.
    guard let off = await bench.measureAll(theme: "Nord Light", mc: "1", label: "1") else {
        r.check("Nord Light frames rendered", false); return finish(r, c)
    }
    let plain = "38;2;248;248;242", inline = "38;2;177;185;249"
    func claudeDark(_ res: [RunResult], _ sgr: String) -> [RunResult] {
        res.filter { ($0.fixture == "claude-dark" && $0.kind == "code" || $0.fixture == "claude-markdown" && $0.kind == "markdown")
            && $0.sgr.hasSuffix(sgr) && !$0.faint }
    }
    let code = claudeDark(off, plain), inl = claudeDark(off, inline)
    r.check("without minimum-contrast, Claude's default theme in Nord Light: plain code \(code.first?.fg ?? "?") on \(code.first?.bg ?? "?") < 1.5:1",
            !code.isEmpty && code.allSatisfy { $0.ratio < 1.5 }, show(code.filter { $0.ratio >= 1.5 }))
    r.check("…and markdown inline code \(inl.first?.fg ?? "?") < 1.6:1 (\(inl.count) runs: prose, table, list, quote)",
            inl.count >= 8 && inl.allSatisfy { $0.ratio < 1.6 }, show(inl.filter { $0.ratio >= 1.6 }))
    for theme in contrastWorstThemes {
        guard let res = await bench.measureAll(theme: theme, mc: nil, label: "lmux") else {
            r.check("\(theme): frames rendered", false); continue
        }
        // Faint text is left out: Ghostty tests its contrast before applying the faint opacity.
        let bad = res.filter { !$0.faint && !$0.setsBackground && $0.ratio < contrastFloor }
        r.check("\(theme): no text below \(contrastFloor):1 (\(res.count) runs, min \(String(format: "%.2f", res.filter { !$0.faint }.map(\.ratio).min() ?? 0)))",
                bad.isEmpty, show(bad))
        if theme == "Nord Light" {
            let fixed = claudeDark(res, plain) + claudeDark(res, inline)
            r.check("…Claude's plain and inline code now read (>= 4.5:1, \(fixed.count) runs)",
                    fixed.count >= 20 && fixed.allSatisfy { $0.ratio >= 4.5 }, show(fixed.filter { $0.ratio < 4.5 }))
            // What already read keeps its color: git / ls (red, blue, magenta), Claude's light theme, its dim hint.
            let before = Dictionary(off.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let kept = res.filter { ($0.fixture == "samples" && ["git", "ls"].contains($0.kind)) || $0.fixture == "claude-light"
                || ($0.fixture == "claude-dark" && $0.kind == "hint") }
                .filter { (before[$0.id]?.ratio ?? 0) >= contrastFloor + 0.05 && !$0.faint }
            let moved = kept.filter { $0.fg != before[$0.id]?.fg }
            r.check("…colors already at >= \(contrastFloor):1 are untouched (\(kept.count) runs)", kept.count > 100 && moved.isEmpty, show(moved))
            // lmux's default light theme keeps git / ls in color (its green, yellow and cyan are
            // darkened to 2.2:1, Resources/themes/Nord Light): none of them is forced to black.
            func gitls(_ sgr: String) -> [RunResult] { res.filter { $0.fixture == "samples" && ["git", "ls"].contains($0.kind) && $0.sgr == sgr } }
            let hued = [("diff +", "32"), ("@@", "36"), ("commit", "33"), ("ls exec", "1;32"), ("ls link", "1;36"), ("ls -G sock", "32"), ("ls -G fifo", "33")]
                .flatMap { name, sgr in gitls(sgr).map { (name, $0) } }
            let lost = hued.filter { _, x in
                let v = UInt32(x.fg.dropFirst(), radix: 16) ?? 0
                let (r, g, b) = (Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF))
                return max(r, g, b) - min(r, g, b) < 24 || x.ratio < 2.1   // gray / black, or not the palette color
            }
            r.check("…git diff's green +, cyan @@, yellow commit and ls's green / cyan keep their hue (\(hued.count) runs, \(hued.first.map { "+ \($0.1.fg) \($0.1.ratio):1" } ?? "?"))",
                    hued.count >= 12 && lost.isEmpty, lost.prefix(3).map { "\($0.0) \($0.1.fg) \($0.1.ratio)" }.joined(separator: "; "))
        }
    }
    let dt = Date().timeIntervalSince(t0)
    r.check("ran in < 30 s", dt < 30, String(format: "%.1fs", dt))
    return finish(r, c)
}

// MARK: - Matrix (QA report)

@MainActor
func runContrastMatrix(_ out: URL) async -> Int32 {
    let r = Report()
    r.section = "contrast-matrix"
    let bench = ContrastBench()
    let c = bench.c
    guard await bench.load(contrastFixtures) else { r.check("fixtures load", false); return finish(r, c) }
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let values = (env["LMUX_CONTRAST_VALUES"] ?? "1,lmux").split(separator: ",").map(String.init)
    var all: [RunResult] = []
    for theme in LmuxThemes.all {
        for v in values {
            guard let res = await bench.measureAll(theme: theme, mc: v == "lmux" ? nil : v, label: v) else { continue }
            all += res
            let body = res.filter { !$0.faint }
            print(String(format: "%-24@ mc=%-4@ runs %4d  <3: %3d  <4.5: %3d  min %.2f", theme as NSString, v as NSString, res.count,
                         body.filter { $0.ratio < 3 }.count, body.filter { $0.ratio < 4.5 }.count, body.map(\.ratio).min() ?? 0))
        }
    }
    // lmux's chrome on the terminal background: the content header, every theme x appearance.
    var chrome: [[String: String]] = []
    for theme in LmuxThemes.all { for dark in [false, true] {
        for (name, ratio, fg, bg) in await bench.header(theme: theme, dark: dark) {
            chrome.append(["theme": theme, "appearance": dark ? "dark" : "light", "label": name, "ratio": "\(ratio)", "fg": fg, "bg": bg])
            if ratio < 4.5 { print("chrome  \(theme) / \(dark ? "dark" : "light") appearance: header \(name) \(fg) on \(bg) = \(ratio)") }
        }
    } }
    try? JSONSerialization.data(withJSONObject: chrome, options: [.prettyPrinted]).write(to: out.appendingPathComponent("chrome.json"))
    NSApp.appearance = nil
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(all).write(to: out.appendingPathComponent("matrix.json"))
    if let spec = env["LMUX_CONTRAST_CROPS"] {
        // name|theme|mc|row0-row1|col0-col1|file;...
        for item in spec.split(separator: ";") {
            let f = item.split(separator: "|").map(String.init)
            guard f.count == 6 else { continue }
            let rr = f[3].split(separator: "-").compactMap { Int($0) }, cc = f[4].split(separator: "-").compactMap { Int($0) }
            await bench.crop(f[0], theme: f[1], mc: f[2] == "lmux" ? nil : f[2], rows: rr[0]..<rr[1], cols: cc[0]..<cc[1],
                             to: out.appendingPathComponent(f[5]))
        }
    }
    print("wrote \(out.path)/matrix.json (\(all.count) runs)")
    return finish(r, c)
}

// MARK: - Cost (QA report)

/// `--contrast-cost`: the app's CPU time and its own GPU time (IOAccelerator AppUsage) while
/// idle and while a pane redraws Claude's screen nonstop, minimum-contrast off vs lmux's, interleaved.
@MainActor
func runContrastCost() async -> Int32 {
    let r = Report()
    r.section = "contrast-cost"
    let bench = ContrastBench()
    let c = bench.c
    let dir = bench.dir.appendingPathComponent("claude-dark.ans").path
    let sh = URL(fileURLWithPath: env["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent("contrast-busy.sh")
    try? "#!/bin/sh\nstty -echo\ntouch \"$LMUX_SINK_DIR/$LMUX_PANE_ID.ready\"\nwhile [ ! -e \"$LMUX_SINK_DIR/stop\" ]; do [ -e \"$LMUX_SINK_DIR/busy\" ] && cat '\(dir)' || sleep 0.05; done\nexec cat >/dev/null\n"
        .write(to: sh, atomically: true, encoding: .utf8)
    chmod(sh.path, 0o755)
    let ws = c.newWorkspace(select: true, program: sh.path)
    _ = await sinks.waitReady(ws.panes[0].id)
    func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    /// This process's GPU time (ns), summed over its Metal clients (IOAccelerator's AppUsage).
    func gpuNs() async -> Double {
        let out = await runProcess("/usr/sbin/ioreg", ["-l", "-w0", "-r", "-c", "AGXDeviceUserClient"]).out
        var total = 0.0, mine = false
        for line in out.split(separator: "\n") {
            if line.contains("\"IOUserClientCreator\"") { mine = line.contains("\"pid \(getpid()),") }
            guard mine, line.contains("accumulatedGPUTime") else { continue }
            for part in line.components(separatedBy: "\"accumulatedGPUTime\"=").dropFirst() {
                total += Double(part.prefix { $0.isNumber }) ?? 0
            }
        }
        return total
    }
    let busyFlag = sinks.dir.appendingPathComponent("busy")
    let secs = Double(env["LMUX_CONTRAST_COST_SECS"] ?? "6") ?? 6
    var acc: [String: [Double]] = [:]
    for round in 0..<3 {
        for busy in [false, true] {
            if busy { FileManager.default.createFile(atPath: busyFlag.path, contents: nil) } else { try? FileManager.default.removeItem(at: busyFlag) }
            for mc in (round % 2 == 0 ? ["1", "lmux"] : ["lmux", "1"]) {
                bench.apply(theme: "Nord Light", mc: mc == "lmux" ? nil : mc)
                await sleepMs(1500)
                let t0 = cpu(), g0 = await gpuNs(), w0 = Date()
                await sleepMs(Int(secs * 1000))
                let wall = Date().timeIntervalSince(w0)
                let pct = (cpu() - t0) / wall * 100, gpct = (await gpuNs() - g0) / 1e9 / wall * 100
                acc["\(busy ? "busy" : "idle") mc=\(mc) cpu", default: []].append(pct)
                acc["\(busy ? "busy" : "idle") mc=\(mc) gpu", default: []].append(gpct)
            }
        }
    }
    try? FileManager.default.removeItem(at: busyFlag)
    FileManager.default.createFile(atPath: sinks.dir.appendingPathComponent("stop").path, contents: nil)
    for k in acc.keys.sorted() {
        let v = acc[k]!
        print(String(format: "%-22@ mean %6.2f%%  runs %@", k as NSString, v.reduce(0, +) / Double(v.count),
                     v.map { String(format: "%.2f", $0) }.joined(separator: " ") as NSString))
    }
    return finish(r, c)
}
