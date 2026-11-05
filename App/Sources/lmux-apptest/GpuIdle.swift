import AppKit
import IOSurface
@testable import LmuxUI

// `lmux-apptest --gpu-idle`: scripts/ghostty.patch lets an unfocused surface that hasn't drawn for
// 3 s release its swap chain and Metal queue (the layer keeps the frame on screen), and rebuild
// both on its next frame. Stressed here the ways a day of use reaches it: output into a released
// pane (visible or in another workspace), resize, zoom, split / close, occlusion, an appearance
// change, workspace switching, and hundreds of release / rebuild cycles. Every frame is read back
// from the layer's IOSurface: it must be the pane's size and show what was printed (red bands),
// never blank, black or stale. Memory must come back to the same level, and idle CPU stay ~0.

private let idleRelease = 3600  // ms: the patch's 3 s, plus a margin

/// Pane program: whatever is appended to `<LMUX_SINK_DIR>/<pane>.out` is printed in the pane.
private func tailProgram(_ dir: URL) -> String {
    let f = dir.appendingPathComponent("tail-pane.sh")
    try? """
    #!/bin/sh
    f="$LMUX_SINK_DIR/$LMUX_PANE_ID.out"
    : > "$f"
    stty -echo
    touch "$LMUX_SINK_DIR/$LMUX_PANE_ID.ready"
    exec tail -f "$f"
    """.write(to: f, atomically: true, encoding: .utf8)
    chmod(f.path, 0o755)
    return f.path
}

@MainActor
private func emit(_ p: Pane, _ text: String) {
    let f = sinks.dir.appendingPathComponent("\(p.id).out")
    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
}

/// One red band: 400 cells of spaces on a pure red background (wraps; the same area at any width).
@MainActor
private func band(_ p: Pane) { emit(p, "\u{1b}[48;2;255;0;0m" + String(repeating: " ", count: 400) + "\u{1b}[0m\r\n") }

/// The frame on screen: the layer's IOSurface (nil when the layer has none).
@MainActor
private func frame(_ p: Pane) -> IOSurfaceRef? {
    guard let contents = p.surface.layer?.contents else { return nil }
    return unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
}

/// The frame is the pane's size in pixels (a stale frame from before a resize isn't).
@MainActor
private func frameFits(_ p: Pane) -> Bool {
    guard let s = frame(p) else { return false }
    let px = p.surface.convertToBacking(p.surface.bounds).size
    return abs(CGFloat(IOSurfaceGetWidth(s)) - px.width) <= 2 && abs(CGFloat(IOSurfaceGetHeight(s)) - px.height) <= 2
}

private struct FrameStats { var red = 0, black = 0, total = 0; var distinct = 0 }

/// Count red-band pixels and pure-black pixels of the pane's frame, read from its IOSurface
/// (BGRA, as Ghostty's Metal renderer draws it).
@MainActor
private func stats(_ p: Pane) -> FrameStats? {
    guard let s = frame(p), IOSurfaceGetPixelFormat(s) == 0x42475241 /* 'BGRA' */ else { return nil }
    IOSurfaceLock(s, .readOnly, nil)
    defer { IOSurfaceUnlock(s, .readOnly, nil) }
    let w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), row = IOSurfaceGetBytesPerRow(s)
    let base = IOSurfaceGetBaseAddress(s).assumingMemoryBound(to: UInt8.self)
    var st = FrameStats(total: w * h)
    var seen = Set<UInt32>()
    for y in 0..<h {
        let line = base + y * row
        for x in 0..<w {
            let b = line[x * 4], g = line[x * 4 + 1], r = line[x * 4 + 2]
            if r > 200 && g < 60 && b < 60 { st.red += 1 }
            if r < 4 && g < 4 && b < 4 { st.black += 1 }
            if seen.count < 64 { seen.insert(UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)) }
        }
    }
    st.distinct = seen.count
    return st
}

/// Red band rows (each band is one cell tall, full width): red pixels over one band's worth.
@MainActor
private func bands(_ p: Pane, perBand: Int) -> Double {
    guard perBand > 0, let s = stats(p) else { return -1 }
    return Double(s.red) / Double(perBand)
}

private func mb(_ b: UInt64) -> Double { Double(b) / 1_048_576 }

private func cpuSeconds() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

@MainActor
func runGpuIdle() async -> Int32 {
    let r = Report()
    let c = makeController()
    let state = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!)
    let prog = tailProgram(state)
    // Nothing is focused (the window isn't key in headless runs, and the patch keeps the focused
    // surface's resources): every pane may release.
    func unfocusAll() { for p in c.model.workspaces.flatMap(\.panes) { p.surface.focusDidChange(false) } }

    // ------------------------------------------------------------ setup: two workspaces of 4 panes
    r.section = "gpu idle: setup"
    for w in c.model.workspaces { c.closeWorkspace(w) }  // (makes a fresh one; replaced below)
    let wsA = c.newWorkspace(program: prog)
    for w in c.model.workspaces where w !== wsA { c.closeWorkspace(w) }
    let a0 = wsA.panes[0]
    guard let a1 = c.split(a0, .right, program: prog), let a2 = c.split(a0, .down, program: prog),
          let a3 = c.split(a1, .down, program: prog) else { r.check("split", false); return finish(r, c) }
    let wsB = c.newWorkspace(select: false, program: prog)
    let b0 = wsB.panes[0]
    let visible = [a0, a1, a2, a3]
    var ready = true
    for p in visible + [b0] { ready = await sinks.waitReady(p.id) && ready }
    r.check("(setup) 5 panes running the output program", ready)
    unfocusAll()
    for p in visible { band(p) }
    _ = await waitFor(3) { visible.allSatisfy { (stats($0)?.red ?? 0) > 0 } }
    let perBand = visible.compactMap { stats($0)?.red }.min() ?? 0
    r.check("(setup) every visible pane drew its red band", perBand > 100 && visible.allSatisfy(frameFits), "\(perBand) px per band")

    // ------------------------------------------------------------ release really frees memory
    r.section = "gpu idle: release"
    await sleepMs(idleRelease)
    let kept = visible.map { stats($0)?.red ?? -1 }
    let idleMB = mb(footprint())
    r.check("idle 3 s: every visible pane keeps its frame on screen (the band, the right size)",
            kept.allSatisfy { $0 == perBand } && visible.allSatisfy(frameFits), "\(kept)")
    for p in visible { band(p) }
    let redrawn = await waitFor(3) { visible.allSatisfy { bands($0, perBand: perBand) >= 1.9 } }
    let activeMB = mb(footprint())
    r.check("output into an idle pane: drawn at once, in full (2 bands, the right size)", redrawn && visible.allSatisfy(frameFits),
            "\(visible.map { bands($0, perBand: perBand) })")
    await sleepMs(idleRelease)
    let idle2MB = mb(footprint())
    print(String(format: "      footprint: idle %.0fMB, drawing %.0fMB, idle again %.0fMB", idleMB, activeMB, idle2MB))
    r.check("released again after drawing: memory back near the idle level (within 15MB)", idle2MB < idleMB + 15,
            String(format: "idle %.0f -> %.0f MB", idleMB, idle2MB))

    // ------------------------------------------------------------ a background (hidden) pane
    r.section = "gpu idle: background"
    band(b0); band(b0); band(b0)
    await sleepMs(500)
    r.check("a pane in another workspace draws nothing while hidden (no frame, stale or new)",
            frame(b0) == nil || stats(b0)?.red == 0, "\(frame(b0).map { "\(IOSurfaceGetWidth($0))x\(IOSurfaceGetHeight($0)) red \(stats(b0)?.red ?? -1)" } ?? "none")")
    c.select(wsB); unfocusAll()
    r.check("shown: its frame has everything printed while hidden (3 bands), the right size",
            await waitFor(3) { bands(b0, perBand: perBand) >= 2.9 && frameFits(b0) }, "\(bands(b0, perBand: perBand))")
    await sleepMs(idleRelease)
    band(b0)
    r.check("…then idle-released while shown, and output after that: 4 bands",
            await waitFor(3) { bands(b0, perBand: perBand) >= 3.9 }, "\(bands(b0, perBand: perBand))")
    c.select(wsA); unfocusAll()
    r.check("back to the first workspace: its 4 panes show their 2 bands again",
            await waitFor(3) { visible.allSatisfy { bands($0, perBand: perBand) >= 1.9 && frameFits($0) } },
            "\(visible.map { bands($0, perBand: perBand) })")

    // ------------------------------------------------------------ resize while released
    r.section = "gpu idle: resize"
    await sleepMs(idleRelease)
    let f0 = c.window.frame
    c.window.setFrame(NSRect(x: f0.minX, y: f0.minY, width: f0.width - 240, height: f0.height - 160), display: true)
    c.window.contentView?.layoutSubtreeIfNeeded()
    r.check("window resized while every pane is released: each frame is redrawn at the new size, bands kept",
            await waitFor(3) { visible.allSatisfy { frameFits($0) && bands($0, perBand: perBand) >= 1.5 } },
            "\(visible.map { "\(frameFits($0)) \(bands($0, perBand: perBand))" })")
    await sleepMs(idleRelease)
    c.window.setFrame(f0, display: true)
    c.window.contentView?.layoutSubtreeIfNeeded()
    r.check("…and back", await waitFor(3) { visible.allSatisfy { frameFits($0) && bands($0, perBand: perBand) >= 1.5 } })

    // ------------------------------------------------------------ zoom / unzoom while released
    r.section = "gpu idle: zoom"
    await sleepMs(idleRelease)
    wsA.focusedPane = a3
    c.toggleSplitZoom(wsA); unfocusAll()
    r.check("zoom a released pane: its frame fills the zoomed size, bands kept",
            await waitFor(3) { wsA.zoomedPane === a3 && frameFits(a3) && bands(a3, perBand: perBand) >= 1.5 },
            "fits \(frameFits(a3)) bands \(bands(a3, perBand: perBand))")
    await sleepMs(idleRelease)
    band(a3)
    r.check("…idle while zoomed, then output: drawn", await waitFor(3) { bands(a3, perBand: perBand) >= 2.5 })
    c.toggleSplitZoom(wsA); unfocusAll()
    r.check("unzoom: all 4 panes back at their size, none blank",
            await waitFor(3) { !wsA.isZoomed && visible.allSatisfy { frameFits($0) && bands($0, perBand: perBand) >= 1.5 } },
            "\(visible.map { "\(frameFits($0)) \(bands($0, perBand: perBand))" })")

    // ------------------------------------------------------------ split / close while released
    r.section = "gpu idle: split"
    await sleepMs(idleRelease)
    guard let extra = c.split(a2, .right, program: prog) else { r.check("split", false); return finish(r, c) }
    unfocusAll()
    r.check("split a released pane: it is redrawn at its new size", await waitFor(3) { frameFits(a2) && bands(a2, perBand: perBand) >= 1.0 },
            "fits \(frameFits(a2))")
    await sleepMs(idleRelease)
    c.closePane(extra)
    unfocusAll()
    r.check("close the new pane while both are released: the old one fills its place again",
            await waitFor(3) { frameFits(a2) && bands(a2, perBand: perBand) >= 1.5 }, "fits \(frameFits(a2))")

    // ------------------------------------------------------------ occlusion (minimize, sleep, covered)
    r.section = "gpu idle: occlusion"
    await sleepMs(idleRelease)
    for round in 0..<5 {
        c.windowShownOverride = false
        c.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: c.window))
        if round == 2 { for p in visible { band(p) } }  // output while occluded
        await sleepMs(300)
        c.windowShownOverride = true
        c.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: c.window))
        unfocusAll()
        await sleepMs(round == 4 ? 0 : 300)
    }
    c.windowShownOverride = nil
    r.check("occluded / shown 5 times (output in between): every frame back, the right size, 3 bands",
            await waitFor(3) { visible.allSatisfy { frameFits($0) && bands($0, perBand: perBand) >= 2.5 } },
            "\(visible.map { "\(frameFits($0)) \(bands($0, perBand: perBand))" })")

    // ------------------------------------------------------------ appearance change while released
    r.section = "gpu idle: theme"
    await sleepMs(idleRelease)
    let darkBG = panePixels(c, a0)?.last
    NSApp.appearance = NSAppearance(named: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .aqua : .darkAqua)
    let changed = await waitFor(4) { panePixels(c, a0)?.last != darkBG && visible.allSatisfy { frameFits($0) && bands($0, perBand: perBand) >= 2.5 } }
    r.check("appearance flipped while released: every pane redraws in the other theme, bands kept", changed,
            "bg \(String(format: "%08x", darkBG ?? 0)) -> \(String(format: "%08x", panePixels(c, a0)?.last ?? 0))")
    NSApp.appearance = nil
    await sleepMs(1500)

    // ------------------------------------------------------------ workspace switching, output in between
    r.section = "gpu idle: switching"
    for i in 0..<60 {
        c.select(i % 2 == 0 ? wsB : wsA)
        if i % 7 == 0 { band(b0); band(a1) }
        await sleepMs(i % 10 == 9 ? idleRelease : 40)
    }
    // 12+ bands printed into a1 and b0: their screens are all red by now (the bands scroll).
    func redShare(_ p: Pane) -> Double { stats(p).map { Double($0.red) / Double(max(1, $0.total)) } ?? -1 }
    c.select(wsB); unfocusAll()
    let bFull = await waitFor(3) { frameFits(b0) && redShare(b0) > 0.6 }
    let bShare = redShare(b0)
    c.select(wsA); unfocusAll()
    r.check("60 switches (some after a release, output on the way): no crash, frames current (screens full of bands)",
            await waitFor(3) { visible.allSatisfy(frameFits) && redShare(a1) > 0.6 } && bFull,
            String(format: "a1 %.2f b0 %.2f red", redShare(a1), bShare))

    // ------------------------------------------------------------ never-shown workspaces (a restore at launch)
    r.section = "gpu idle: hidden"
    if env["LMUX_GPU_IDLE_SKIP_HIDDEN"] == nil {
    await sleepMs(idleRelease)
    let before = mb(footprint())
    var hidden: [Workspace] = []
    for _ in 0..<8 { hidden.append(c.newWorkspace(select: false, program: prog)) }
    for w in hidden { _ = await sinks.waitReady(w.panes[0].id); band(w.panes[0]) }
    await sleepMs(idleRelease)
    let framed = hidden.filter { frame($0.panes[0]) != nil }.count
    let held = mb(footprint())
    for w in hidden { w.panes[0].surface.layer?.contents = nil }
    await sleepMs(500)
    // A pane created hidden can keep the blank first frame that landed after it was hidden (the
    // default 800x600 pt size, never written): it costs nothing resident.
    r.check("8 workspaces opened in the background, never shown, released: under 3MB each",
            (held - before) / 8 < 3 && mb(footprint()) > held - 4,
            String(format: "%+.1fMB for 8 (%d hold a blank frame; %.1fMB without them)", held - before, framed, mb(footprint())))
    for w in hidden { c.closeWorkspace(w) }
    c.select(wsA); unfocusAll()
    }

    // ------------------------------------------------------------ open / close: no leak
    r.section = "gpu idle: open-close"
    var openClose: [Double] = []
    for _ in 0..<6 {
        let w = c.newWorkspace(program: prog)
        let q0 = w.panes[0]
        let qs = [q0] + [c.split(q0, .right, program: prog), c.split(q0, .down, program: prog)].compactMap { $0 }
        for q in qs { _ = await sinks.waitReady(q.id); band(q) }
        unfocusAll()
        _ = await waitFor(3) { qs.allSatisfy { (stats($0)?.red ?? 0) > 0 } }
        c.closeWorkspace(w)
        c.select(wsA)
        await sleepMs(300); unfocusAll()  // (focus can come back on the next turn)
        await sleepMs(idleRelease)
        let first = mb(footprint())
        await sleepMs(2000)
        openClose.append(min(first, mb(footprint())))
    }
    r.check("a workspace of 3 drawing panes opened and closed 6 times: memory flat after the 2nd (within 8MB)",
            (openClose.last ?? 0) - openClose[1] < 8, openClose.map { String(format: "%.0f", $0) }.joined(separator: " ") + " MB")

    // ------------------------------------------------------------ hundreds of cycles: no leak
    r.section = "gpu idle: cycles"
    for p in visible { emit(p, "\u{1b}[2J\u{1b}[H") }  // clear: the bands no longer scroll
    await sleepMs(idleRelease)
    var samples: [Double] = []
    let rounds = Int(env["LMUX_GPU_IDLE_ROUNDS"] ?? "") ?? 55
    var wrong = 0
    for i in 0..<rounds {
        for p in visible { emit(p, "\u{1b}[H" + (i % 2 == 0 ? "\u{1b}[48;2;255;0;0m" : "\u{1b}[48;2;0;0;255m") + String(repeating: " ", count: 400) + "\u{1b}[0m") }
        let drew = await waitFor(2) { visible.allSatisfy { (stats($0)?.red ?? 0) > 0 ? i % 2 == 0 : i % 2 == 1 } }
        if !drew || !visible.allSatisfy(frameFits) { wrong += 1 }
        await sleepMs(idleRelease)
        samples.append(mb(footprint()))
    }
    if env["LMUX_GPU_IDLE_DEBUG"] != nil { print("      samples: " + samples.map { String(format: "%.0f", $0) }.joined(separator: " ")) }
    let cycles = rounds * visible.count
    // The idle level steps between a few plateaus (the allocator's, ±15MB): a leak raises the floor.
    let early = samples.dropFirst(2).prefix(10).min() ?? 0, late = samples.suffix(10).min() ?? 0
    print(String(format: "      %d release / rebuild cycles: idle footprint floor %.1fMB (rounds 3-12) -> %.1fMB (last 10), min %.1f max %.1f",
                 cycles, early, late, samples.min() ?? 0, samples.max() ?? 0))
    r.check("\(cycles) release / rebuild cycles: every frame drawn right (a band of the new color each time)", wrong == 0,
            "\(wrong) rounds wrong")
    r.check("…and idle memory flat across them (no leak: the last 10 rounds' floor within 6MB of rounds 3-12)", late - early < 6,
            String(format: "%.1f -> %.1f MB", early, late))

    // ------------------------------------------------------------ idle CPU
    r.section = "gpu idle: cpu"
    await sleepMs(idleRelease)
    let t0 = cpuSeconds(), w0 = Date()
    await sleepMs(5000)
    let pct = (cpuSeconds() - t0) / Date().timeIntervalSince(w0) * 100
    r.check("all released, nothing printing: idle CPU under 1%", pct < 1, String(format: "%.2f%%", pct))
    return finish(r, c)
}
