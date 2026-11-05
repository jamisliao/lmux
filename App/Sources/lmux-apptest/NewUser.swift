// `lmux-apptest --newuser`: what a stranger hits in the first days, headless.
//
//   - every row of the README's shortcut table, typed with a real (isolated) zsh focused
//   - a `keybind` in the user's Ghostty config: picked up after a config reload, in the menu too
//   - closing the last workspace, 100 workspaces, a very long title, a Korean path with spaces,
//     a narrow window
//   - cmux leftovers that hold nothing to import, and a cmux window frame on a display that's gone
//
// apptest.sh runs it with panes on the isolated zsh (idle shells close without a confirmation),
// XDG_CONFIG_HOME on a temp dir (the "user's" Ghostty config) and a temp LMUX_STATE_DIR.

import AppKit
import LmuxHooks
import LmuxTerminal
@testable import LmuxUI

private let moreKeys: [Character: UInt16] = ["5": 23, "6": 22, "7": 26, "8": 28, "9": 25, ",": 43]

/// Any shortcut (⌃⌘S needs control, which `cmd` doesn't take).
@MainActor
func press(_ c: Character, _ mods: NSEvent.ModifierFlags, window: NSWindow) async {
    let ts = ProcessInfo.processInfo.systemUptime
    let s = String(c)
    let chars = mods.contains(.shift) ? s.uppercased() : s
    for t in [NSEvent.EventType.keyDown, .keyUp] {
        let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: mods, timestamp: ts,
                                 windowNumber: window.windowNumber, context: nil, characters: chars,
                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: KC.map[c] ?? moreKeys[c]!)!
        dispatchKey(e, window: window)
    }
    await sleepMs(150)
}

@MainActor
private func shellReady(_ p: Pane) async -> Bool {
    await waitFor(8) { p.surface.readText().contains("%") }
}

@MainActor
func runNewUser() async -> Int32 {
    let r = Report()
    let env = ProcessInfo.processInfo.environment
    let xdg = URL(fileURLWithPath: env["XDG_CONFIG_HOME"] ?? "", isDirectory: true)
    guard !xdg.path.isEmpty, xdg.path != NSHomeDirectory() + "/.config" else {
        print("lmux-apptest --newuser: set XDG_CONFIG_HOME to a temp dir (apptest.sh does)")
        return 2
    }
    let c = makeController()
    let w = c.window!
    c.assumeAppActive = true

    // ---------------------------------------------------------- README shortcut table
    r.section = "readme shortcuts"
    let ws1 = c.model.workspaces[0]
    _ = await shellReady(ws1.panes[0])
    r.check("a fresh start has one workspace, its shell focused", c.model.workspaces.count == 1 && firstResponderPane(c) === ws1.panes[0])
    await press("n", .command, window: w)
    r.check("⌘N: new workspace", c.model.workspaces.count == 2 && c.model.selected !== ws1)
    let ws2 = c.model.selected!
    _ = await shellReady(ws2.panes[0])
    await press("d", .command, window: w)
    r.check("⌘D: split right", ws2.panes.count == 2)
    _ = await shellReady(ws2.focusedPane!)
    await press("d", [.command, .shift], window: w)
    r.check("⇧⌘D: split down", ws2.panes.count == 3)
    let last = ws2.focusedPane!
    _ = await shellReady(last)
    await press("[", .command, window: w)
    r.check("⌘[: previous pane", ws2.focusedPane !== last && firstResponderPane(c) === ws2.focusedPane)
    await press("]", .command, window: w)
    r.check("⌘]: next pane", ws2.focusedPane === last)
    await press("w", .command, window: w)
    r.check("⌘W: closes the pane (idle shell: no question asked)", await waitFor(3) { ws2.panes.count == 2 }, "\(ws2.panes.count)")
    r.check("…and focus lands on a remaining pane of the workspace", firstResponderPane(c).map { p in ws2.panes.contains { $0 === p } } ?? false)
    await press("w", [.command, .shift], window: w)
    r.check("⇧⌘W: closes the workspace", await waitFor(3) { c.model.workspaces.count == 1 && c.model.selected === ws1 },
            "\(c.model.workspaces.count)")

    for _ in 0..<9 { c.newWorkspace() }
    _ = await shellReady(c.model.workspaces.last!.panes[0])
    c.select(ws1)
    for i in 1...8 {
        await press(Character("\(i)"), .command, window: w)
        if c.model.selected !== c.model.workspaces[i - 1] { r.check("⌘\(i) selects workspace \(i)", false); break }
        if i == 8 { r.check("⌘1–⌘8 select workspaces 1–8", true) }
    }
    await press("9", .command, window: w)
    r.check("⌘9: the last workspace (10th)", c.model.selected === c.model.workspaces.last)
    await press("]", [.command, .control], window: w)
    r.check("⌃⌘]: next workspace wraps to the first", c.model.selected === c.model.workspaces.first)
    await press("[", [.command, .control], window: w)
    r.check("⌃⌘[: previous workspace wraps to the last", c.model.selected === c.model.workspaces.last)
    await press("]", [.command, .shift], window: w)
    r.check("⇧⌘] is the pane's next tab (cmux), not a workspace: one tab here, nothing moves",
            c.model.selected === c.model.workspaces.last)

    let target = c.model.workspaces[3]
    let tp = target.panes[0]
    _ = sendHook(pane: tp.id, hook("UserPromptSubmit", session: "nu-1"))
    _ = sendHook(pane: tp.id, hook("PermissionRequest", session: "nu-1", #""tool_name":"Bash""#))
    _ = await waitFor(3) { tp.needsInput }
    await press("j", [.command, .shift], window: w)
    r.check("⇧⌘J: jumps to the agent that needs you", c.model.selected === target, c.model.selected?.title ?? "nil")
    let doneWS = c.model.workspaces[6]
    let dp = doneWS.panes[0]
    _ = sendHook(pane: dp.id, hook("UserPromptSubmit", session: "nu-2"))
    _ = sendHook(pane: dp.id, hook("Stop", session: "nu-2", #""last_assistant_message":"Done.""#))
    _ = await waitFor(3) { dp.unread > 0 }
    await press("u", [.command, .shift], window: w)
    r.check("⇧⌘U: jumps to the latest unread", c.model.selected === doneWS && dp.unread == 0, "unread=\(dp.unread)")
    await press("s", [.command, .control], window: w)
    r.check("⌃⌘S: hides the sidebar", !c.model.sidebarVisible)
    await press("s", [.command, .control], window: w)
    r.check("⌃⌘S again: shows it", c.model.sidebarVisible)
    await press("s", [.command, .control], window: w)
    let req = c.history.focusRequest
    await press("h", [.command, .shift], window: w)
    r.check("⇧⌘H: History search (brings a hidden sidebar back)", c.model.sidebarVisible && c.history.focusRequest == req + 1)
    c.focusCurrent()
    await press("f", .command, window: w)
    r.check("⌘F: find in scrollback", c.model.selected?.focusedPane?.view.overlay.findBar != nil)
    c.model.selected?.focusedPane?.view.overlay.findBar?.onClose?()
    c.focusCurrent()
    await press(",", .command, window: w)
    r.check("⌘,: Settings", c.settingsWindow != nil)

    // ---------------------------------------------------- a keybind in the user's Ghostty config
    r.section = "user keybind"
    let ghosttyDir = xdg.appendingPathComponent("ghostty", isDirectory: true)
    try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
    try? "keybind = super+t=new_window\nkeybind = super+shift+d=unbind\n"
        .write(to: ghosttyDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    c.reloadTerminalConfig()
    await sleepMs(300)
    c.focusCurrent()
    let n0 = c.model.workspaces.count
    await press("t", .command, window: w)
    r.check("after a config reload, the user's ⌘T = new_window opens a workspace", c.model.workspaces.count == n0 + 1)
    let menuNew = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "New Workspace" }
    r.check("…and the menu shows the user's key for New Workspace", menuNew?.keyEquivalent == "t",
            "menu: \(menuNew?.keyEquivalent ?? "nil")")
    let menuDown = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == "Split Down" }
    r.check("…an unbound ⇧⌘D loses its menu key", menuDown?.keyEquivalent == "", "menu: \(menuDown?.keyEquivalent ?? "nil")")
    let wsK = c.model.selected!
    _ = await shellReady(wsK.panes[0])
    await press("d", [.command, .shift], window: w)
    r.check("…and ⇧⌘D no longer splits", wsK.panes.count == 1, "\(wsK.panes.count)")
    await press("j", [.command, .shift], window: w)
    r.check("lmux's own shortcuts still work with a user config (⇧⌘J)", c.model.selected === target)
    try? FileManager.default.removeItem(at: ghosttyDir)
    c.reloadTerminalConfig()
    await sleepMs(300)

    // ---------------------------------------------------------------- edge cases
    r.section = "edge cases"
    for ws in c.model.workspaces.dropFirst() { c.closeWorkspace(ws) }
    let lone = c.model.workspaces[0]
    c.closeWorkspace(lone)
    r.check("closing the last workspace leaves one fresh workspace, selected and focused",
            c.model.workspaces.count == 1 && c.model.selected === c.model.workspaces[0] && c.model.workspaces[0] !== lone
            && firstResponderPane(c) === c.model.workspaces[0].panes[0])

    let base = URL(fileURLWithPath: c.paths.stateDir.path).appendingPathComponent("새 폴더 (1) — ünï", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let wsK2 = c.newWorkspace(cwd: base.path)
    let kp = wsK2.panes[0]
    _ = await shellReady(kp)
    kp.surface.sendText("echo \"PWD=$PWD\"\r")
    r.check("a Korean path with spaces opens as the shell's directory", await waitFor(3) { kp.surface.readText().contains("PWD=" + base.path) },
            String(kp.surface.readText().suffix(200)))
    let long = String(repeating: "아주 긴 워크스페이스 이름 very long title 🚀 ", count: 12)
    c.renameWorkspace(wsK2, to: long)
    let sidebarW = c.root.sidebarHost.frame.width
    c.root.layoutSubtreeIfNeeded()
    r.check("a 400-character title doesn't widen the sidebar", c.root.sidebarHost.frame.width == sidebarW,
            "\(sidebarW) -> \(c.root.sidebarHost.frame.width)")
    c.saveNow()
    let saved = (try? String(contentsOf: c.paths.layoutFile, encoding: .utf8)) ?? ""
    r.check("…and both round-trip through layout.json", saved.contains("새 폴더 (1)") && saved.contains("very long title"))

    w.setFrame(NSRect(x: 0, y: 0, width: 420, height: 260), display: false)
    c.root.layoutSubtreeIfNeeded()
    let pv = kp.view
    r.check("a narrow window still leaves the terminal a usable width", pv.frame.width >= 120 && pv.frame.height > 50,
            "\(pv.frame)")
    w.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)

    let t0 = Date()
    while c.model.workspaces.count < 100 { c.newWorkspace(select: false) }
    r.check("100 workspaces open", c.model.workspaces.count == 100, "\(Date().timeIntervalSince(t0))s")
    await press("9", .command, window: w)
    r.check("…⌘9 reaches the 100th", c.model.selected === c.model.workspaces.last)
    c.saveNow()
    let file = try? JSONDecoder().decode(LayoutFile.self, from: Data(contentsOf: c.paths.layoutFile))
    r.check("…and all 100 are saved for the next launch", file?.workspaces.count == 100, "\(file?.workspaces.count ?? -1)")
    for ws in c.model.workspaces.dropFirst() { c.closeWorkspace(ws) }

    // ------------------------------------------------- claude runs, but no hook ever comes
    r.section = "hooks hint"
    c.hooksHintDelay = 1.5
    c.claudeConfigCandidatesOverride = []   // never the real ~/.claude*
    let fakeDir = c.paths.stateDir.appendingPathComponent("fake bin", isDirectory: true)
    try? FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
    let fake = fakeDir.appendingPathComponent("claude")
    // A claude that titles the terminal and waits, sending no hook (hooks in another config dir).
    try? "#!/bin/sh\nprintf '\\033]0;✳ Claude Code\\007'\nread x\n".write(to: fake, atomically: true, encoding: .utf8)
    chmod(fake.path, 0o755)
    let hw = c.newWorkspace()
    let hp = hw.panes[0]
    _ = await shellReady(hp)
    hp.surface.sendText("'\(fake.path)'\r")
    r.check("a claude with no hook event for a while gets one hint card", await waitFor(8) { c.cardShown(hp) })
    let text = (hp.view.overlay.card?.message.stringValue ?? "") + " " + (hp.view.overlay.card?.detail.stringValue ?? "")
    r.check("…saying lmux isn't receiving hooks, and to install them in CLAUDE_CONFIG_DIR",
            text.contains("isn’t receiving Claude Code hooks") && text.contains("CLAUDE_CONFIG_DIR"), text)
    r.check("…and no check is left pending (nothing runs while the pane is idle)", hp.hooksHintCheck == nil)
    // Calm: it never takes the keyboard. ⏎ goes on to claude (the fake reads a line and exits).
    r.check("…with Dismiss and no key hints (⏎ / esc stay Claude's)",
            hp.view.overlay.card?.cancel.title == "Dismiss" && hp.view.overlay.card?.confirm.shortcut == nil
                && hp.surface.keyInterceptor == nil)
    c.window.makeFirstResponder(hp.surface)
    await type("\r", window: c.window)
    func claudeRuns() -> Bool {
        let fg = hp.surface.foregroundPID
        return fg > 0 && ClaudeProcess.isClaude(ClaudeProcess.representative(ofGroup: fg) ?? fg)
    }
    r.check("…⏎ goes to the terminal (claude read it and exited), the card stays",
            await waitFor(3) { !claudeRuns() } && c.cardShown(hp))
    hp.view.overlay.card?.cancel.performClick()
    c.considerHooksHint(hp)
    await sleepMs(2500)
    r.check("dismissed: never again for that pane", !c.cardShown(hp) && hp.hooksHintCheck == nil)
    // A pane whose claude sends hooks: no hint.
    let okw = c.newWorkspace()
    let okp = okw.panes[0]
    _ = await shellReady(okp)
    _ = sendHook(pane: okp.id, hook("SessionStart", session: "hint-ok"))
    _ = await waitFor(3) { okp.hooksHeard }
    okp.surface.sendText("'\(fake.path)'\r")
    await sleepMs(3500)
    r.check("a pane that sent a hook event never gets the hint (and arms no check)", !c.cardShown(okp) && okp.hooksHintCheck == nil)
    // Codex is not Claude Code: a codex sending no hooks gets no Claude hooks hint (it has its own notice).
    let codexFake = fakeDir.appendingPathComponent("codex")
    try? "#!/bin/sh\nprintf '\\033]0;codex\\007'\nread x\n".write(to: codexFake, atomically: true, encoding: .utf8)
    chmod(codexFake.path, 0o755)
    let cw = c.newWorkspace()
    let cp = cw.panes[0]
    _ = await shellReady(cp)
    cp.surface.sendText("'\(codexFake.path)'\r")
    await sleepMs(3500)
    r.check("a codex pane never gets the Claude hooks hint", !cp.hooksHinted && cp.hooksHintCheck == nil
            && !(cp.view.overlay.card?.message.stringValue ?? "").contains("Claude Code hooks"))
    c.closeWorkspace(cw)
    c.closeWorkspace(hw)
    c.closeWorkspace(okw)
    // Which hint: from where the hooks are and the config dir this claude uses.
    let cc = c.paths.stateDir.appendingPathComponent("cc", isDirectory: true)
    let ccSettings = cc.appendingPathComponent("settings.json").path
    let somePID: pid_t = 424242
    r.check("hooks not installed: install them", LmuxController.hooksHint(settingsPath: ccSettings, claudePID: somePID).kind == .notInstalled)
    if let plan = try? HookInstaller.planInstall(settingsPath: ccSettings, hookPath: "/x/lmux-hook") {
        try? HookInstaller.apply(plan, pristineDirectory: cc.appendingPathComponent("pristine"))
    }
    let other = LmuxController.hooksHint(settingsPath: ccSettings, claudePID: somePID)
    r.check("installed, but this claude keeps no session file there: it uses another CLAUDE_CONFIG_DIR, choose that folder",
            other.kind == .otherConfigDir && other.action == "Choose Folder…" && other.detail.contains("CLAUDE_CONFIG_DIR"), other.detail)
    try? FileManager.default.createDirectory(at: cc.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try? "{}".write(to: cc.appendingPathComponent("sessions/\(somePID).json"), atomically: true, encoding: .utf8)
    r.check("installed and this claude runs on that config dir: it started before the hooks, restart it",
            LmuxController.hooksHint(settingsPath: ccSettings, claudePID: somePID).kind == .startedBeforeInstall)
    // The claude's own config dir found (its session file): offer to install the hooks right there.
    let work = c.paths.stateDir.appendingPathComponent("cc-work", isDirectory: true)
    try? FileManager.default.createDirectory(at: work.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    try? "{}".write(to: work.appendingPathComponent("sessions/4243.json"), atomically: true, encoding: .utf8)
    let there = LmuxController.hooksHint(settingsPath: ccSettings, claudePID: 4243, candidates: [cc, work])
    r.check("…it runs on another dir lmux can see: Install There…, naming that dir",
            there.kind == .otherConfigDir && there.configDir?.lastPathComponent == "cc-work" && there.action == "Install There…"
                && there.detail.contains("cc-work") && there.detail.contains("CLAUDE_CONFIG_DIR"), there.detail)
    let notYet = LmuxController.hooksHint(settingsPath: work.appendingPathComponent("x/settings.json").path, claudePID: 4243,
                                          candidates: [work])
    r.check("…also when the default dir has no hooks at all", notYet.kind == .otherConfigDir && notYet.configDir != nil, notYet.detail)

    // ------------------------------------------------------- run straight from Downloads
    r.section = "first launch"
    let translocated = "/private/var/folders/x7/abc/T/AppTranslocation/0D2F-11AA/d/lmux.app/Contents/Resources/bin/lmux-hook"
    r.check("lmux opened where it was unzipped (App Translocation) doesn't install hooks into that temporary path",
            HooksSetup.runsFromTemporaryCopy(translocated))
    r.check("…from Applications (or a build dir) it does",
            !HooksSetup.runsFromTemporaryCopy("/Applications/lmux.app/Contents/Resources/bin/lmux-hook")
            && !HooksSetup.runsFromTemporaryCopy(c.paths.hookBinary ?? ""))

    // ------------------------------------------------------------------- cmux leftovers
    r.section = "cmux leftovers"
    let fm = FileManager.default
    let home = c.paths.stateDir.appendingPathComponent("cmux-broken", isDirectory: true)
    let src = CmuxSources(home: home)
    for u in src.allFiles { try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
    try? "{ \"app\": { \"appearance\": ".write(to: src.settingsFiles[0], atomically: true, encoding: .utf8)  // truncated
    try? "{\"windows\": [{\"tabManager\": {\"workspaces\": [".write(to: src.session, atomically: true, encoding: .utf8)
    try? "".write(to: src.ghosttyConfig, atomically: true, encoding: .utf8)
    try? Data("not a plist".utf8).write(to: src.defaultsPlist)
    let plan = CmuxImport.plan(src)
    r.check("broken / empty cmux files: nothing to import", CmuxImportPlan.Section.allCases.allSatisfy { !plan.has($0) })
    r.check("…so the first launch doesn't offer an import sheet with nothing in it", !c.shouldOfferCmuxImport(src))

    // A session whose only workspace is a browser, and one whose window sat on a display that's gone.
    let session = """
    {"windows": [{"frame": {"x": 9000, "y": 9000, "width": 1200, "height": 800},
      "tabManager": {"workspaces": [
        {"workspaceId": "web", "layout": {"pane": {"panelIds": ["b1"]}}, "panels": [{"id": "b1", "type": "browser"}]},
        {"workspaceId": "term", "currentDirectory": "/tmp", "layout": {"pane": {"panelIds": ["t1"]}},
         "panels": [{"id": "t1", "type": "terminal"}]}]}}]}
    """
    try? fm.removeItem(at: src.settingsFiles[0])
    try? session.write(to: src.session, atomically: true, encoding: .utf8)
    let plan2 = CmuxImport.plan(src)
    r.check("a browser-only cmux workspace is skipped, the terminal one comes along",
            plan2.workspaces.map(\.id) == ["cmux-term"], "\(plan2.workspaces.map(\.id))")
    r.check("cmux's window frame off every screen isn't applied (the window would vanish)",
            plan2.windowFrame.map { f in NSScreen.screens.contains { $0.frame.intersects(f) } } ?? true,
            "\(plan2.windowFrame.map { "\($0)" } ?? "nil") screens: \(NSScreen.screens.map(\.frame))")

    print("INFO  [harness] \(MouseQueue.environment)")
    print("\nRESULT: \(r.failed == 0 ? "PASS" : "FAIL") (\(r.passed)/\(r.passed + r.failed) checks passed)")
    return r.failed == 0 ? 0 : 1
}
