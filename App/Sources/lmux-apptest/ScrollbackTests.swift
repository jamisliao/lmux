import AppKit
import LmuxTerminal
import LmuxTranscript
@testable import LmuxUI

// `lmux-apptest --scrollback` then `--scrollback-restore` (same state dir): terminal output across
// a relaunch. Real isolated zsh panes with Ghostty's shell integration (GHOSTTY_RESOURCES_DIR with
// shell-integration/, so "at a prompt" is known).

private let agentSession = "8e1f0c2a-0000-4000-8000-00000000cafe"

@MainActor
private func shellReady(_ p: Pane) async -> Bool {
    await waitFor(10) { p.surface.readText().contains("%") && !p.surface.needsConfirmQuit }
}

@MainActor
private func fileMode(_ url: URL) -> mode_t? { PrivateFile.mode(of: url.path) }

@MainActor
func runScrollback() async -> Int32 {
    let r = Report()
    r.section = "scrollback"
    guard (env["LMUX_PANE_COMMAND"] ?? "").hasSuffix("pane-shell") else {
        print("lmux-apptest --scrollback: LMUX_PANE_COMMAND must be isolated-shell.sh's pane-shell")
        return 2
    }
    let c = makeController()
    let dir = c.scrollbackDir
    // The plain shell pane: 2,500 numbered lines, then a red line, then the prompt.
    let a = c.model.selected!.panes[0]
    r.check("a plain shell pane reaches its prompt (shell integration: nothing running)", await shellReady(a))
    a.surface.sendText("seq 1 2500 | sed 's/^/line-/'; printf '\\033[31mRED-MARK\\033[0m\\n'\r")
    r.check("…and prints 2,500 lines and a red one", await waitFor(10) { a.surface.readText().contains("RED-MARK\n") })
    _ = await waitFor(3) { !a.surface.needsConfirmQuit }

    // An agent pane lmux will resume: saves nothing.
    let bws = c.newWorkspace()
    let b = bws.panes[0]
    _ = await shellReady(b)
    b.surface.sendText("echo AGENT-OUTPUT\r")
    _ = await waitFor(5) { b.surface.readText().contains("AGENT-OUTPUT\n") }
    b.claudeSessionID = agentSession
    b.resumeCommand = "claude --resume \(agentSession)"

    // A full-screen program on the alternate screen (vim / less / a TUI): saves nothing.
    let alt = FileManager.default.temporaryDirectory.appendingPathComponent("lmux-alt-\(getpid()).sh")
    try? "#!/bin/sh\nprintf '\\033[?1049hALT-SCREEN-TEXT'\nexec sleep 600\n".write(to: alt, atomically: true, encoding: .utf8)
    chmod(alt.path, 0o755)
    defer { try? FileManager.default.removeItem(at: alt) }
    let cws = c.newWorkspace()
    let cp = cws.panes[0]
    _ = await shellReady(cp)
    cp.surface.sendText("'\(alt.path)'\r")
    _ = await waitFor(5) { cp.surface.readText().contains("ALT-SCREEN-TEXT") }
    // A shell left on the alternate screen (a program died without leaving it): saves nothing either.
    let dws = c.newWorkspace()
    let dp = dws.panes[0]
    _ = await shellReady(dp)
    dp.surface.sendText("printf '\\033[?1049h'; echo ALT-SHELL-TEXT\r")
    _ = await waitFor(5) { dp.surface.readText().contains("ALT-SHELL-TEXT\n") }
    await sleepMs(300)
    // Two more plain panes the restore run damages on purpose (corrupt / escapes).
    let ews = c.newWorkspace(), fws = c.newWorkspace()
    let e = ews.panes[0], f = fws.panes[0]
    for (p, word) in [(e, "E-OUTPUT"), (f, "F-OUTPUT")] {
        _ = await shellReady(p)
        p.surface.sendText("echo \(word)\r")
        _ = await waitFor(5) { p.surface.readText().contains(word + "\n") }
    }
    // Load for the quit-time measurement: 20 more plain panes with 2,000 lines each (the first one
    // 11,000: only its last 2,000 rows are read).
    var load: [Pane] = []
    for _ in 0..<20 {
        let p = c.newWorkspace(select: false).panes[0]
        load.append(p)
    }
    for (i, p) in load.enumerated() {
        _ = await shellReady(p)
        p.surface.sendText(i == 0 ? "seq 7001 9000 | sed 's/^/load-line-/'; seq 1 7000; seq 1 2000 | sed 's/^/load-line-/'\r"
                                  : "seq 1 2000 | sed 's/^/load-line-/'; printf '\\033[32mGREEN\\033[0m\\n'\r")
    }
    _ = await waitFor(20) { load.allSatisfy { $0.surface.readText(viewportOnly: false).contains("load-line-2000\n") && !$0.surface.needsConfirmQuit } }
    _ = await waitFor(5) { load.dropFirst().allSatisfy { $0.surface.readText().contains("GREEN\n") } }
    _ = await waitFor(5) { [a, b, e, f].allSatisfy { !$0.surface.needsConfirmQuit } }
    await sleepMs(300)

    // Settings > General: both toggles.
    let suite = "dev.lmux.apptest.scrollback.\(getpid())"
    c.defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    c.allowExternalSendAtLaunch = false
    let m = SettingsModel(controller: c)
    r.check("Settings: “Restore terminal output after relaunch” is on by default, “Allow other apps…” off",
            m.restoreScrollback && c.settings.restoreScrollback && !m.allowExternalSend && !c.allowExternalSend)
    m.setAllowExternalSend(true)
    let sendOn = c.allowExternalSend && c.defaults.bool(forKey: "allowExternalSend")
    m.setAllowExternalSend(false)
    r.check("…“Allow other apps to send input to lmux” is the allowExternalSend default (read at each send)",
            sendOn && !c.allowExternalSend)
    m.setRestoreScrollback(false)
    r.check("…turning restore off is saved in lmux's settings", !c.settings.restoreScrollback)

    // Turned off: quitting writes nothing.
    c.saveScrollback()
    r.check("turned off (Settings > General): quitting writes nothing", !FileManager.default.fileExists(atPath: dir.path))
    c.settings.restoreScrollback = true

    // What ⌘Q does: timed.
    let t0 = CACurrentMediaTime()
    c.saveScrollback()
    let saveMs = (CACurrentMediaTime() - t0) * 1000
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let sizes = files.map { (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.size] as? Int) ?? 0 }
    print(String(format: "      quit save: %d panes, %d files, %.1f ms, %d KB total, largest %d KB", c.model.workspaces.flatMap(\.panes).count,
                 files.count, saveMs, sizes.reduce(0, +) / 1024, (sizes.max() ?? 0) / 1024))
    r.check("the state dir's scrollback/ is private (0700)", fileMode(dir) == 0o700, String(fileMode(dir) ?? 0, radix: 8))
    let aFile = dir.appendingPathComponent(a.id)
    let saved = (try? String(contentsOf: aFile, encoding: .utf8)) ?? ""
    r.check("the plain shell pane saved its output, private (0600)", !saved.isEmpty && fileMode(aFile) == 0o600,
            String(fileMode(aFile) ?? 0, radix: 8))
    let lines = saved.split(separator: "\n", omittingEmptySubsequences: false)
    r.check("…its last 2,000 lines at most (the oldest dropped), ≤ 512 KB",
            lines.count <= 2000 && saved.contains("line-2500") && !saved.contains("line-100\n") && saved.utf8.count <= 512 * 1024,
            "\(lines.count) lines, \(saved.utf8.count) bytes")
    r.check("…as plain text (no escapes)", saved.contains("RED-MARK\n") && !saved.contains("\u{1b}"),
            String(saved.suffix(120)).debugDescription)
    r.check("the agent pane lmux resumes saved nothing", !files.contains(b.id))
    r.check("the pane in a full-screen program (alternate screen) saved nothing", !files.contains(cp.id))
    r.check("a shell left on the alternate screen saved nothing", !files.contains(dp.id))
    func savedText(_ p: Pane) -> String { (try? String(contentsOf: dir.appendingPathComponent(p.id), encoding: .utf8)) ?? "" }
    r.check("every loaded pane saved, hidden ones (never shown) too",
            load.allSatisfy { files.contains($0.id) } && load.dropFirst().allSatisfy { savedText($0).contains("load-line-2000\nGREEN\n") },
            "\(files.count) files; " + String(savedText(load[1]).prefix(80)).debugDescription)
    let big = savedText(load[0])
    r.check("a pane with 11,000 rows saves only its last 2,000", big.contains("load-line-2000")
            && !big.contains("load-line-7001") && big.split(separator: "\n").count <= 2000, "\(big.split(separator: "\n").count) lines")
    r.check("quit save of 20 panes × 2,000 lines stays under 1 s", saveMs < 1000, String(format: "%.0f ms", saveMs))
    let exp: [String: String] = ["a": a.id, "b": b.id, "c": cp.id, "e": e.id, "f": f.id,
                                 "load": load.map(\.id).joined(separator: ",")]
    try? JSONSerialization.data(withJSONObject: exp)
        .write(to: URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("scrollback-expect.json"))
    // The quit itself (finish → shutdown) saves again; the restore run reads that.
    return finish(r, c)
}

@MainActor
func runScrollbackRestore() async -> Int32 {
    let r = Report()
    r.section = "scrollback restore"
    let state = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!)
    guard let d = try? Data(contentsOf: state.appendingPathComponent("scrollback-expect.json")),
          let exp = try? JSONSerialization.jsonObject(with: d) as? [String: String],
          let aID = exp["a"], let bID = exp["b"], let cID = exp["c"], let eID = exp["e"], let fID = exp["f"] else {
        print("FAIL  [scrollback restore] no expectations from the --scrollback run")
        return 1
    }
    let dir = state.appendingPathComponent("scrollback")
    // Damaged on purpose: not UTF-8, and escapes that would set the title / write the clipboard.
    try? FileManager.default.removeItem(at: dir.appendingPathComponent(eID))
    try? PrivateFile.create(dir.appendingPathComponent(eID), Data([0x45, 0xff, 0xfe, 0x00, 0x41]), mode: 0o600)
    try? FileManager.default.removeItem(at: dir.appendingPathComponent(fID))
    try? PrivateFile.create(dir.appendingPathComponent(fID),
                            Data("SAFE\u{1b}]0;PWNED-TITLE\u{07}-TEXT\u{1b}]52;c;cHduZWQ=\u{07}\u{1b}[2J\u{1b}[31mRED\n".utf8), mode: 0o600)
    let t0 = CACurrentMediaTime()
    let c = makeController()
    let startMs = (CACurrentMediaTime() - t0) * 1000
    print(String(format: "      launch with restore: %d panes in %.0f ms", c.model.workspaces.flatMap(\.panes).count, startMs))
    r.check("the files are removed once restored", !FileManager.default.fileExists(atPath: dir.path))
    guard let a = c.pane(id: aID), let b = c.pane(id: bID), let cp = c.pane(id: cID),
          let e = c.pane(id: eID), let f = c.pane(id: fID) else {
        r.check("every pane came back", false)
        return finish(r, c)
    }
    let divider = "— restored from your last session —"
    func all(_ p: Pane) -> String { p.surface.readText(viewportOnly: false) }
    let shown = await waitFor(10) {
        let s = all(a)
        guard let d = s.range(of: divider) else { return false }
        return s[d.upperBound...].contains("%")
    }
    let s = all(a)
    let red = s.range(of: "RED-MARK"), div = s.range(of: divider), last = s.range(of: "line-2500")
    r.check("the old output shows above the divider, then a new prompt", shown && red != nil && div != nil && last != nil
            && last!.lowerBound < red!.lowerBound && red!.upperBound <= div!.lowerBound, String(s.suffix(300)).debugDescription)
    r.check("…only its last 2,000 lines", !s.contains("line-100\n") && s.contains("line-1000\n"))
    a.surface.sendText("echo AFTER-$((40+2))\r")
    r.check("…and the new shell works as usual below it", await waitFor(5) { all(a).contains("AFTER-42\n") }, String(all(a).suffix(200)).debugDescription)
    r.check("…the old output isn't in the shell's history (printed, never typed)",
            !(((try? String(contentsOfFile: env["HISTFILE"] ?? "/nonexistent", encoding: .utf8)) ?? "").contains("line-2499")))
    await sleepMs(300)
    r.check("the agent pane shows no old output (it resumes its session instead)", !all(b).contains("AGENT-OUTPUT") && !all(b).contains(divider))
    r.check("the full-screen program's pane shows no old output", !all(cp).contains("ALT-SCREEN-TEXT") && !all(cp).contains(divider))
    r.check("a file that isn't UTF-8 is ignored (no crash, nothing printed)", !all(e).contains(divider) && !all(e).contains("E-OUTPUT"))
    let fs = all(f)
    r.check("escapes in a saved file are dropped: text only (no title, no clipboard, no clear)",
            fs.contains("SAFE-TEXTRED") && !fs.contains("PWNED") && f.surface.title != "PWNED-TITLE"
                && !(GhosttyRuntime.standardPasteboard.string(forType: .string) ?? "").contains("pwned"),
            String(fs.prefix(200)).debugDescription)
    let load = (exp["load"] ?? "").split(separator: ",").compactMap { c.pane(id: String($0)) }
    let loaded = await waitFor(10) { load.allSatisfy { all($0).contains("load-line-2000") && all($0).contains(divider) } }
    r.check("all 20 loaded panes' output is back", loaded && load.count == 20, "\(load.count) loaded panes")
    return finish(r, c)
}

