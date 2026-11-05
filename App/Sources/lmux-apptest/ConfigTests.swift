import AppKit
import CryptoKit
import GhosttyKit
import LmuxTerminal
import LmuxTokens
import SwiftUI
@testable import LmuxUI

// `lmux-apptest --settings`: the Settings window (themes, font, notifications, general), lmux's
// config file and its live reload, and the cmux import from fixture cmux files (a temp HOME-like
// dir: cmux's real files are never read). apptest.sh points LMUX_CONFIG_FILE at a temp file.

@MainActor
func configFloat(_ cfg: ghostty_config_t?, _ key: String) -> Double? {
    guard let cfg else { return nil }
    var v: Float = 0
    return ghostty_config_get(cfg, &v, key, UInt(key.lengthOfBytes(using: .utf8))) ? Double(v) : nil
}

@MainActor
func configBackground(_ cfg: ghostty_config_t?) -> String? {
    guard let cfg else { return nil }
    var c = ghostty_config_color_s()
    let key = "background"
    guard ghostty_config_get(cfg, &c, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
    return String(format: "#%02x%02x%02x", c.r, c.g, c.b)
}

func hexOf(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB)!
    return String(format: "#%02x%02x%02x", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
}

func sha(_ url: URL) -> String {
    guard let d = try? Data(contentsOf: url) else { return "missing" }
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

/// A cmux setup in `home` (paths as cmux uses them under a real HOME).
func writeCmuxFixture(_ home: URL) -> (sid: String, files: [URL]) {
    let fm = FileManager.default
    let src = CmuxSources(home: home)
    for u in src.allFiles { try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
    try? """
    # cmux themes start
    theme = light:Nord Light,dark:Dracula
    # cmux themes end

    # 주 폰트: D2Coding. 뒤는 아이콘용 폴백.
    font-family = D2Coding
    font-family = Pravka Nerd Font Mono
    font-size = 15
    cursor-style = bar
    macos-titlebar-style = tabs
    keybind = super+k=clear_screen
    """.write(to: src.ghosttyConfig, atomically: true, encoding: .utf8)
    try? """
    {
      "$schema": "https://example.invalid/cmux-settings.schema.json", // a URL in a string stays
      "schemaVersion": 1,
      /* block comment */
      "app": { "appearance": "dark", "warnBeforeQuit": false, "minimalMode": true, },
      "sidebarAppearance": { "matchTerminalBackground": true },
      "notifications": { "sound": "Glass", "dockBadge": true, "unreadPaneRing": false, "paneFlash": false, },
      "shortcuts": { "bindings": { "toggleSidebar": "cmd+b", "splitRight": "cmd+opt+d", "browserBack": "cmd+[", }, },
      // "app": { "appearance": "system" },
    }
    """.write(to: src.settingsFiles[0], atomically: true, encoding: .utf8)
    try? #"{ "app": { "appearance": "light", "preferredEditor": "zed" } }"#.write(to: src.settingsFiles[1], atomically: true, encoding: .utf8)
    let sid = "0a1b2c3d-1111-4222-8333-444455556666"
    let custom = ##"{"entries":{"WS-2":{"customization":{"customTitle":{"value":{"_0":"build"}},"customColor":{"value":{"_0":"#C0392B"}}}}}}"##
    let geo = #"{"frame":{"x":40,"y":60,"width":1100,"height":700},"version":2}"#
    let plist: [String: Any] = ["appearanceMode": "light", "sidebarMatchTerminalBackground": 0,
                                "workspaceCustomizations.v2": Data(custom.utf8), "cmux.session.lastWindowGeometry.v2": Data(geo.utf8)]
    try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: src.defaultsPlist)
    func panel(_ id: String, _ dir: String, claude: Bool = false) -> [String: Any] {
        var t: [String: Any] = ["workingDirectory": dir]
        if claude { t["agent"] = ["kind": "claude", "sessionId": sid, "permissionMode": "auto"] }
        return ["id": id, "type": "terminal", "directory": dir, "title": "t-\(id)", "terminal": t]
    }
    let session: [String: Any] = ["version": 1, "windows": [[
        "frame": ["x": 0, "y": 0, "width": 900, "height": 600],
        "sidebar": ["isVisible": true, "width": 236],
        "tabManager": ["selectedWorkspaceIndex": 0, "workspaces": [
            ["workspaceId": "WS-1", "customTitle": "auth fix", "currentDirectory": "/tmp",
             "layout": ["type": "pane", "pane": ["panelIds": ["P1"], "selectedPanelId": "P1"]],
             "panels": [panel("P1", "/tmp", claude: true)]],
            ["workspaceId": "WS-2", "currentDirectory": "/usr", "customTitle": "build",
             "layout": ["type": "split", "split": ["orientation": "horizontal", "dividerPosition": 0.3,
                                                   "first": ["type": "pane", "pane": ["panelIds": ["P2"]]],
                                                   "second": ["type": "split", "split": ["orientation": "vertical",
                                                       "first": ["type": "pane", "pane": ["panelIds": ["P3"]]],
                                                       "second": ["type": "pane", "pane": ["panelIds": ["P4"]]]]]]],
             "panels": [panel("P2", "/usr"), panel("P3", "/usr/bin"), panel("P4", "/tmp")]],
            ["workspaceId": "WS-3", "currentDirectory": "/tmp",
             "layout": ["type": "pane", "pane": ["panelIds": ["P5"]]], "panels": [panel("P5", "/tmp")]],
        ]],
    ]]]
    try? JSONSerialization.data(withJSONObject: session).write(to: src.session)
    return (sid, src.allFiles)
}

@MainActor
func runSettings() async -> Int32 {
    let r = Report()
    let c = makeController()
    let cfgURL = LmuxConfig.configFile
    r.section = "config"
    r.check("lmux's config is the temp file (LMUX_CONFIG_FILE), never ~/.config/lmux", cfgURL.path.hasPrefix(paths.stateDir.deletingLastPathComponent().path)
            || !cfgURL.path.hasPrefix(NSHomeDirectory() + "/.config"), cfgURL.path)
    try? FileManager.default.removeItem(at: cfgURL)
    c.openConfigFile()
    let header = (try? String(contentsOf: cfgURL, encoding: .utf8)) ?? ""
    r.check("Open config file creates it with a helpful commented header (never blank)",
            header.hasPrefix("# lmux config") && header.contains("theme = light:Nord Light,dark:Nord"), header)
    try? (header + "cursor-style = bar\n# my note\n").write(to: cfgURL, atomically: true, encoding: .utf8)
    c.openConfigFile()
    r.check("…and leaves an existing file alone", ((try? String(contentsOf: cfgURL, encoding: .utf8)) ?? "").contains("# my note"))

    // ------------------------------------------------------------------ themes
    r.section = "themes"
    let themesDir = URL(fileURLWithPath: env["GHOSTTY_RESOURCES_DIR"]!).appendingPathComponent("themes")
    var unresolved: [String] = []
    for name in LmuxThemes.all {
        guard FileManager.default.fileExists(atPath: themesDir.appendingPathComponent(name).path), let pal = ThemePalette.load(name),
              let cfg = LmuxConfig.load(fontProfile: .korean, overrides: ["theme = \(name)"]) else { unresolved.append(name); continue }
        if ghostty_config_diagnostics_count(cfg) != 0 || configBackground(cfg) != hexOf(pal.background) { unresolved.append(name) }
        ghostty_config_free(cfg)
    }
    r.check("all \(LmuxThemes.all.count) bundled themes resolve in libghostty (background = the theme file's)", unresolved.isEmpty && LmuxThemes.all.count >= 20,
            "\(unresolved)")
    let bundleBytes = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Resources/themes").standardized, includingPropertiesForKeys: [.fileSizeKey]))?
        .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? -1
    print("INFO  [themes] \(LmuxThemes.all.count + 0) themes, \(bundleBytes) bytes")
    r.check("the bundled themes are well under 1MB", bundleBytes > 0 && bundleBytes < 100_000, "\(bundleBytes)")
    r.check("every light/dark pair names bundled themes", LmuxThemes.pairs.allSatisfy { LmuxThemes.all.contains($0.light) && LmuxThemes.all.contains($0.dark) })

    // ------------------------------------------------------------------ Settings window
    r.section = "settings window"
    c.openSettings()
    let sw = c.settingsWindow
    let tabs = (sw?.contentViewController as? NSTabViewController)?.tabViewItems.map(\.label) ?? []
    r.check("⌘, builds the Settings window: Appearance, Font, Notifications, General", tabs == ["Appearance", "Font", "Notifications", "General"], "\(tabs)")
    r.check("…headless: never shown, never key", sw?.isVisible == false && sw?.isKeyWindow == false && !NSApp.isActive)
    r.check("Settings… in the app menu opens it (⌘,)", (NSApp.mainMenu?.items.first?.submenu?.items.first { $0.title == "Settings…" })?.action
            == #selector(LmuxController.openSettings))
    guard let m = c.settingsModel else { r.check("settings model", false); return finish(r, c) }
    r.check("first open: the current theme is selected (Nord Light / Nord)", m.lightTheme == "Nord Light" && m.darkTheme == "Nord")
    let reloads0 = c.configReloads
    m.galleryDark = true
    m.chooseTheme("Dracula")
    m.galleryDark = false
    m.chooseTheme("Catppuccin Latte")
    let text1 = (try? String(contentsOf: cfgURL, encoding: .utf8)) ?? ""
    r.check("clicking theme cards writes theme = light:Catppuccin Latte,dark:Dracula", text1.contains("theme = light:Catppuccin Latte,dark:Dracula")
            && text1.components(separatedBy: "\ntheme =").count == 2, text1)
    r.check("…keeping the other lines and comments", text1.contains("cursor-style = bar") && text1.contains("# my note") && text1.hasPrefix("# lmux config"))
    r.check("…and reloads every pane (2 reloads)", c.configReloads == reloads0 + 2)
    m.galleryDark = true; m.chooseTheme("Dracula"); m.galleryDark = false; m.chooseTheme("Dracula")
    r.check("the new theme is live: libghostty's background is Dracula's", c.runtime.background.map(hexOf) == "#282a36"
            && configBackground(c.runtime.config) == "#282a36", c.runtime.background.map(hexOf) ?? "nil")
    let p1 = c.model.selected!.panes[0]
    _ = await waitFor(2) { p1.surface.terminalBackground.map(hexOf) == "#282a36" }
    r.check("…the open pane follows (CONFIG_CHANGE), no restart", p1.surface.terminalBackground.map(hexOf) == "#282a36",
            p1.surface.terminalBackground.map(hexOf) ?? "nil")
    m.chooseTheme("Nord Light"); m.galleryDark = true; m.chooseTheme("Nord")

    r.section = "font"
    let fams = LmuxFonts.families()
    let notFixed = fams.filter { f in
        guard f != LmuxFonts.embedded, let font = NSFontManager.shared.font(withFamily: f, traits: [], weight: 5, size: 12) else { return false }
        return !font.isFixedPitch && !font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            && !(NSFontManager.shared.availableMembers(ofFontFamily: f) ?? []).contains { (($0[3] as? NSNumber)?.uintValue ?? 0) & NSFontTraitMask.fixedPitchFontMask.rawValue != 0 }
    }
    r.check("the font list has only fixed-pitch families (\(fams.count)), plus D2Coding and JetBrains Mono",
            notFixed.isEmpty && fams.contains("D2Coding") && fams.contains("JetBrains Mono") && !fams.contains("Helvetica") && !fams.contains("Helvetica Neue"),
            "\(notFixed)")
    try? LmuxConfigFile().set("font-family", ["\"\"", "D2Coding", "Pravka Nerd Font Mono"])
    m.reload()
    r.check("the picker shows the chain: D2Coding + Pravka Nerd Font Mono", m.fontFamily == "D2Coding" && m.fallbacks == ["Pravka Nerd Font Mono"])
    let reloads1 = c.configReloads
    m.chooseFont("Menlo")
    r.check("choosing Menlo keeps the Nerd Font fallback", LmuxConfig.fontFamilyChain() == ["Menlo", "Pravka Nerd Font Mono"]
            && c.configReloads == reloads1 + 1, "\(LmuxConfig.fontFamilyChain())")
    m.addFallback("D2Coding")
    r.check("Add Fallback appends (D2Coding for Hangul)", LmuxConfig.fontFamilyChain() == ["Menlo", "Pravka Nerd Font Mono", "D2Coding"])
    m.removeFallback("Pravka Nerd Font Mono")
    r.check("…and − removes one", LmuxConfig.fontFamilyChain() == ["Menlo", "D2Coding"])
    r.check("the Hangul codepoint map stays (D2Coding for Hangul)", (LmuxConfig.load(fontProfile: .korean).map { _ in true } ?? false)
            && LmuxConfig.plan(fontProfile: .korean, userSets: { _ in true }).beforeUser.contains { $0.hasPrefix("font-codepoint-map = U+AC00-U+D7A3=D2Coding") })
    m.setFontSize(16)
    r.check("size 16 writes font-size = 16 and is live", ((try? String(contentsOf: cfgURL, encoding: .utf8)) ?? "").contains("font-size = 16")
            && configFloat(c.runtime.config, "font-size") == 16, "\(configFloat(c.runtime.config, "font-size") ?? -1)")
    r.check("the preview uses the font with its fallbacks as the cascade", m.previewFont(size: 13).fontDescriptor
        .object(forKey: .cascadeList).map { ($0 as? [NSFontDescriptor])?.count == 1 } ?? false)

    r.section = "settings"
    m.setAppearance(.dark)
    r.check("Appearance Dark sets the app's appearance", NSApp.appearance?.name == .darkAqua)
    m.setSidebarMatch(true)
    r.check("Sidebar matches the terminal background", c.root.sidebarBackdrop.matchColor != nil && c.root.sidebarBackdrop.material.isHidden)
    m.setSound("Glass"); m.setDockBadge(true); m.setUnreadRing(false); m.setWarnBeforeQuit(false)
    r.check("sound reaches the notifier", c.notifier.sound == "Glass")
    let relaunched = LmuxSettings(url: paths.stateDir.appendingPathComponent("settings.plist"))
    r.check("settings survive a relaunch (read back from the state dir)", relaunched.appearance == .dark && relaunched.sidebarMatchesTerminal
            && relaunched.notificationSound == "Glass" && relaunched.dockBadge && !relaunched.unreadRing && !relaunched.warnBeforeQuit)
    r.check("…as do theme and font (lmux's config)", LmuxThemes.current == "light:Nord Light,dark:Nord" && LmuxConfig.fontFamilyChain() == ["Menlo", "D2Coding"])
    r.check("Ask before quitting off: ⌘Q doesn't ask", c.shouldTerminate() == .terminateNow)
    m.setAppearance(.system)
    m.setSidebarMatch(false)
    m.setWarnBeforeQuit(true); m.setUnreadRing(true); m.setDockBadge(false); m.setSound("Off")
    r.check("Appearance System gives the system's back", NSApp.appearance == nil && c.root.sidebarBackdrop.matchColor == nil)

    // ------------------------------------------------------------------ cmux import
    r.section = "cmux import"
    r.check("JSONC: line and block comments, trailing commas, // inside strings", {
        let o = JSONC.parse(#"{ "a": "http://x//y", /* c */ "b": [1, 2,], // tail"# + "\n" + #""c": {"d": true,},}"#) as? [String: Any]
        return o?["a"] as? String == "http://x//y" && (o?["b"] as? [Int]) == [1, 2] && ((o?["c"] as? [String: Any])?["d"] as? Bool) == true
    }())
    let empty = paths.stateDir.appendingPathComponent("no-cmux-home", isDirectory: true)
    try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    r.check("no cmux on the machine: no first-launch offer", !c.shouldOfferCmuxImport(CmuxSources(home: empty)))
    r.check("…and this run never looks at the real cmux (LMUX_CMUX_HOME)", CmuxSources.current.home.path != NSHomeDirectory())
    let home = paths.stateDir.appendingPathComponent("cmux-home", isDirectory: true)
    let (sid, files) = writeCmuxFixture(home)
    let before = files.map(sha)
    let src = CmuxSources(home: home)
    r.check("cmux found: the first launch offers the import", c.shouldOfferCmuxImport(src))
    let plan = CmuxImport.plan(src)
    r.check("look: theme, D2Coding + Nerd Font fallback, 15pt, other keys", plan.configLines.contains("theme = light:Nord Light,dark:Dracula")
            && plan.configLines.contains("font-family = \"\"") && plan.configLines.contains("font-family = Pravka Nerd Font Mono")
            && plan.configLines.contains("font-size = 15") && plan.configLines.contains("cursor-style = bar")
            && !plan.configLines.contains { $0.hasPrefix("macos-titlebar-style") }, "\(plan.configLines)")
    r.check("app: settings.json wins over cmux.json and defaults (dark, quit without asking, match terminal)",
            plan.appearance == .dark && plan.warnBeforeQuit == false && plan.sidebarMatch == true)
    r.check("…window frame from lastWindowGeometry, sidebar width from the session", plan.windowFrame == NSRect(x: 40, y: 60, width: 1100, height: 700)
            && plan.sidebarWidth == 236 && plan.sidebarVisible == true)
    r.check("notifications: Glass, Dock badge, no pane ring", plan.sound == .some("Glass") && plan.dockBadge == true && plan.unreadRing == false)
    r.check("shortcuts: splitRight -> Ghostty keybind, toggleSidebar -> lmux's own, cmux's keybind kept",
            plan.keybinds.contains("keybind = super+alt+d=new_split:right") && plan.lmuxShortcuts["toggleSidebar"] == "cmd+b"
            && plan.keybinds.contains("keybind = super+k=clear_screen"), "\(plan.keybinds) \(plan.lmuxShortcuts)")
    r.check("workspaces: 3, with names, the red one's color, splits and cwd", plan.workspaces.map { $0.customTitle ?? "-" } == ["auth fix", "build", "-"]
            && plan.workspaces[1].accent == CmuxImport.nearestAccent("#C0392B") && plan.workspaces[1].root.axis == .horizontal
            && plan.workspaces[1].root.children?[1].axis == .vertical && abs((plan.workspaces[1].root.ratio ?? 0) - 0.3) < 0.001
            && plan.workspaces[1].root.children?[1].children?[0].pane?.cwd == "/usr/bin")
    r.check("…the Claude pane resumes its session", plan.workspaces[0].root.pane?.claudeSession == sid
            && plan.workspaces[0].root.pane?.resumeCommand == "claude --permission-mode auto --resume \(sid)")
    let ni = plan.notImported.joined(separator: " | ")
    r.check("not imported, listed: browser, SSH, the titlebar key, browserBack, minimalMode, paneFlash, preferredEditor",
            ni.contains("Browser") && ni.contains("SSH") && ni.contains("macos-titlebar-style") && ni.contains("browserBack")
            && ni.contains("app.minimalMode") && ni.contains("paneFlash") && ni.contains("app.preferredEditor"), ni)
    let vm = CmuxImportModel(plan: plan, firstLaunch: true)
    r.check("the sheet: every section checked, workspaces ON at first launch", vm.enabledSections == Set(CmuxImportPlan.Section.allCases))
    r.check("…from the menu after an import, workspaces start OFF", CmuxImportModel(plan: plan, firstLaunch: false).enabled[.workspaces] == false)

    await checkCmuxOneClick(r, c, src, cfgURL)

    let n0 = c.model.workspaces.count
    let date = Date(timeIntervalSince1970: 1_793_600_000)
    let result = c.importFromCmux(plan, sections: Set(CmuxImportPlan.Section.allCases), date: date)
    r.check("Import: one-line result", result.hasPrefix("Brought over") && result.contains("3 workspaces"), result)
    let cfg2 = (try? String(contentsOf: cfgURL, encoding: .utf8)) ?? ""
    r.check("…lmux's config gets one dated block, the user's lines kept", cfg2.contains("# Imported from cmux on 2026-11-0")
            && cfg2.contains("# cmux import start") && cfg2.contains("# my note") && cfg2.contains("keybind = super+alt+d=new_split:right"), cfg2)
    r.check("…and it's live: Dracula in dark, 15pt", configFloat(c.runtime.config, "font-size") == 15, "\(configFloat(c.runtime.config, "font-size") ?? -1)")
    let splitKey = c.keyEquivalent(forGhosttyAction: "new_split:right")
    let allItems: [NSMenuItem] = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
    let toggle: NSMenuItem? = allItems.first { $0.title == "Toggle Sidebar" }
    let splitOK = splitKey?.0 == "d" && splitKey?.1 == [.command, .option]
    let toggleOK = toggle?.keyEquivalent == "b" && toggle?.keyEquivalentModifierMask == [.command]
    r.check("…menus take the shortcuts: ⌥⌘D Split Right, ⌘B Toggle Sidebar", splitOK && toggleOK,
            "\(String(describing: splitKey)) \(toggle?.keyEquivalent ?? "nil")")
    r.check("…app and notification settings", c.settings.appearance == .dark && !c.settings.warnBeforeQuit && c.settings.sidebarMatchesTerminal
            && c.settings.notificationSound == "Glass" && c.settings.dockBadge && !c.settings.unreadRing && c.importedWindowFrame?.width == 1100
            && c.model.sidebarWidth == 236)
    let imported = c.model.workspaces.filter { $0.id.hasPrefix("cmux-") }
    r.check("…3 workspaces opened with their names and layouts", c.model.workspaces.count == n0 + 3 && imported.map(\.title).prefix(2) == ["auth fix", "build"]
            && imported[1].panes.count == 3 && imported[1].panes.map(\.cwd) == ["/usr", "/usr/bin", "/tmp"], imported.map(\.title).joined(separator: ","))
    let claudePane = imported[0].panes[0]
    let typed = await sinks.wait(claudePane.id, contains: "claude --permission-mode auto --resume \(sid)", timeout: 5)
    r.check("…the Claude pane resumes: claude --permission-mode auto --resume <id>", claudePane.claudeSessionID == sid && typed,
            sinks.text(claudePane.id))
    let cfgBytes = sha(cfgURL)
    let again = c.importFromCmux(plan, sections: Set(CmuxImportPlan.Section.allCases), date: date)
    r.check("importing again: no duplicate workspaces, the config byte-identical", c.model.workspaces.count == n0 + 3 && sha(cfgURL) == cfgBytes
            && (try? String(contentsOf: cfgURL, encoding: .utf8))?.components(separatedBy: "# cmux import start").count == 2, again)
    r.check("cmux's files are byte-identical afterwards", files.map(sha) == before)
    r.check("…and the first-launch offer is done", !c.shouldOfferCmuxImport(src))
    await checkCmuxReal(r, c)
    c.setAppearance(.system)
    return finish(r, c)
}

/// `--settings-shots D`: each Settings tab and the cmux import sheet, light and dark, offscreen.
@MainActor
func runSettingsShots(_ dir: URL) async -> Int32 {
    let c = makeController()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? LmuxConfigFile().set("font-family", ["\"\"", "D2Coding", "Pravka Nerd Font Mono"])
    c.openSettings()
    guard let m = c.settingsModel else { return 1 }
    func render<V: View>(_ view: V, _ name: String, dark: Bool) async {
        let v = NSHostingView(rootView: view)
        let holder = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        holder.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        holder.contentView = v
        v.layoutSubtreeIfNeeded()
        holder.setContentSize(v.fittingSize)
        v.layoutSubtreeIfNeeded()
        await sleepMs(500)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        m.galleryDark = dark
        for tab in SettingsTab.allCases {
            await render(SettingsShotFrame(tab: tab, model: m), "settings-\(tab.title.lowercased())", dark: dark)
        }
    }
    let home = paths.stateDir.appendingPathComponent("cmux-home", isDirectory: true)
    _ = writeCmuxFixture(home)
    let vm = CmuxImportModel(plan: CmuxImport.plan(CmuxSources(home: home)), firstLaunch: true)
    for dark in [false, true] {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        await render(CmuxImportView(model: vm), "cmux-import", dark: dark)
    }
    vm.choosing = true
    await render(CmuxImportView(model: vm), "cmux-import-choose", dark: false)
    vm.result = "Brought over theme and fonts, app settings, notifications, shortcuts and 3 workspaces."
    vm.canUndo = true
    await render(CmuxImportView(model: vm), "cmux-import-done", dark: false)
    NSApp.appearance = nil
    c.shutdown()
    return 0
}

/// A tab as the window shows it: the toolbar row of tabs (drawn here: headless can't capture the
/// real toolbar) over the tab's content.
struct SettingsShotFrame: View {
    let tab: SettingsTab
    let model: SettingsModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases, id: \.self) { t in
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 17))
                        Text(t.title).font(.system(size: 11))
                    }
                    .foregroundStyle(t == tab ? Color.accentColor : Color.secondary)
                    .frame(width: 84, height: 50)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t == tab ? Color.primary.opacity(0.07) : .clear))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            SettingsTabView(tab: tab, model: model)
        }
        .frame(width: SettingsTabView.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The sheet as the user meets it: one button (Return) brings everything over, Undo Import puts
/// lmux back (config bytes, settings, the workspaces it opened unless changed), "Choose what to
/// import…" narrows it down.
@MainActor
func checkCmuxOneClick(_ r: Report, _ c: LmuxController, _ src: CmuxSources, _ cfgURL: URL) async {
    func menuTitles() -> [String] { (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }.map(\.title) }
    // A first launch: only the empty shell lmux opened.
    c.closeWorkspaces(c.model.workspaces)
    let fresh = c.model.workspaces.first
    let cfg0 = sha(cfgURL), n0 = c.model.workspaces.count, sel0 = c.model.selectedID
    r.check("first launch: one untouched shell", n0 == 1 && fresh.map(c.isUntouchedFirst) == true)
    let appearance0 = c.settings.appearance, sound0 = c.settings.notificationSound, width0 = c.model.sidebarWidth
    c.presentCmuxImport(firstLaunch: true, from: src)
    guard let vm = c.cmuxImportModel else { r.check("the sheet's model exists", false); return }
    r.check("one click: everything lmux supports is on, the checkboxes folded away", vm.enabledSections == Set(CmuxImportPlan.Section.allCases) && !vm.choosing)
    r.check("…its one-line summary", vm.plan.headline.hasPrefix("Theme, font") && vm.plan.headline.hasSuffix("and 3 open workspaces")
            && vm.plan.headline.contains(" shortcuts"), vm.plan.headline)
    r.check("…no Undo before importing", !menuTitles().contains("Undo cmux Import") && !vm.canUndo)
    vm.onImport?()  // the primary button (Return)
    r.check("…the untouched first shell gives way: cmux's workspaces start at the top", c.model.workspaces.count == 3
            && c.model.workspaces.allSatisfy { $0.id.hasPrefix("cmux-") }, c.model.workspaces.map(\.id).joined(separator: ","))
    r.check("…Return: config, settings and 3 workspaces come over", (vm.result ?? "").hasPrefix("Brought over")
            && sha(cfgURL) != cfg0 && c.settings.appearance == .dark && c.settings.notificationSound == "Glass", vm.result ?? "-")
    r.check("…the confirmation: Undo Import, one line of what lmux doesn't have, a menu item",
            vm.canUndo && (vm.plan.notImportedLine ?? "").contains("more") && menuTitles().contains("Undo cmux Import"))
    let imported = c.model.workspaces.filter { $0.id.hasPrefix("cmux-") }
    if let mine = imported.last { c.renameWorkspace(mine, to: "mine now") }
    imported.first?.panes.first?.surface.pasteText("make test")  // used: typed in, nothing else changed
    let usedIDs = [imported.first?.id, imported.last?.id]
    vm.onUndo?()
    r.check("Undo: lmux's config back to its exact bytes, settings and sidebar back", sha(cfgURL) == cfg0 && c.settings.appearance == appearance0
            && c.settings.notificationSound == sound0 && c.model.sidebarWidth == width0 && c.settings.cmuxImportedAt == nil)
    r.check("…the first shell is back on top (same id), the untouched import closes, the renamed and the typed-in ones stay (and it says so)",
            c.model.workspaces.count == 3 && c.model.workspaces.first?.id == fresh?.id
            && usedIDs.allSatisfy { id in c.model.workspaces.contains { $0.id == id } }
            && (vm.result ?? "").contains("Kept 2 workspaces you used.") && c.model.selectedID == sel0, vm.result ?? "-")
    r.check("…Undo is gone (sheet and menu)", !vm.canUndo && !menuTitles().contains("Undo cmux Import") && c.undoCmuxImport() == "Nothing to undo.")
    c.model.workspaces.filter { $0.id.hasPrefix("cmux-") }.forEach { c.closeWorkspace($0) }
    c.model.workspaces.first?.panes.first?.surface.pasteText("ls")
    c.importFromCmux(CmuxImport.plan(src), sections: [.workspaces])
    r.check("a first shell the user typed in stays, the imports go below it", c.model.workspaces.count == 4 && c.model.workspaces.first?.id == fresh?.id)
    c.undoCmuxImport()
    r.check("…undo: just that shell again", c.model.workspaces.count == 1 && c.model.workspaces.first?.id == fresh?.id)

    // A workspace whose agent session changed since the import (a new claude in it) is in use: it stays.
    c.importFromCmux(CmuxImport.plan(src), sections: [.workspaces])
    let again = c.model.workspaces.filter { $0.id.hasPrefix("cmux-") }
    again.first?.panes.first?.claudeSessionID = UUID().uuidString.lowercased()
    let undone = c.undoCmuxImport()
    r.check("…a workspace with another agent session since the import stays open, the rest close",
            c.model.workspaces.count == 2 && c.model.workspaces.contains { $0.id == again.first?.id }
            && undone.contains("Kept 1 workspace you used."), undone)
    c.model.workspaces.filter { $0.id.hasPrefix("cmux-") }.forEach { c.closeWorkspace($0) }

    // Undo reverts only what the import touched: a setting, a config line and the sidebar changed
    // after it stay; the import's own block, settings and sidebar width go back.
    let cfgText0 = (try? String(contentsOf: cfgURL, encoding: .utf8)) ?? ""
    c.importFromCmux(CmuxImport.plan(src), sections: [.look, .app, .notifications])
    let blockIn = LmuxConfigFile().block(LmuxController.cmuxBlock) != nil
    c.settings.notificationSound = "Ping"   // changed after the import
    try? LmuxConfigFile().set("scrollback-limit", ["12345"])
    c.model.sidebarWidth = 333
    c.undoCmuxImport()
    let cfgText1 = (try? String(contentsOf: cfgURL, encoding: .utf8)) ?? ""
    r.check("Undo after later changes: the setting changed since stays, the import's own settings go back",
            c.settings.notificationSound == "Ping" && c.settings.appearance == appearance0,
            "sound \(c.settings.notificationSound ?? "nil") appearance \(c.settings.appearance)")
    r.check("…the import's config block goes, the line added since stays", blockIn && LmuxConfigFile().block(LmuxController.cmuxBlock) == nil
            && cfgText1.contains("scrollback-limit = 12345")
            && cfgText1.replacingOccurrences(of: "scrollback-limit = 12345\n", with: "") == cfgText0,
            cfgText1.split(separator: "\n").joined(separator: " | "))
    r.check("…the sidebar width set since stays", c.model.sidebarWidth == 333)
    try? LmuxConfigFile().set("scrollback-limit", [])
    c.settings.notificationSound = sound0
    c.model.sidebarWidth = width0

    c.presentCmuxImport(from: src)
    guard let vm2 = c.cmuxImportModel, vm2 !== vm else { r.check("the menu opens the same sheet", false); return }
    vm2.choosing = true
    vm2.enabled[.look] = false
    vm2.enabled[.shortcuts] = false
    vm2.enabled[.workspaces] = false
    vm2.onImport?()
    r.check("Choose what to import…: unchecked sections stay out (config untouched, no workspaces)",
            sha(cfgURL) == cfg0 && c.model.workspaces.count == n0 && c.settings.appearance == .dark, vm2.result ?? "-")
    vm2.onUndo?()
    r.check("…and undo that too", c.settings.appearance == appearance0 && c.cmuxUndo == nil)

    // cmux still running: its panes hold the sessions, so the import opens plain shells there.
    let realCheck = CmuxImport.cmuxRunning
    CmuxImport.cmuxRunning = { true }
    c.presentCmuxImport(firstLaunch: true, from: src)
    guard let vm3 = c.cmuxImportModel else { r.check("the sheet's model exists", false); return }
    r.check("cmux running: the sheet says to quit it first (or import without sessions)", vm3.cmuxRunning && vm3.enabled[.workspaces] == true)
    vm3.onImport?()
    let shells = c.model.workspaces.filter { $0.id.hasPrefix("cmux-") }.flatMap(\.panes)
    r.check("…import opens shells in those directories, no session resumed (nothing typed)",
            !shells.isEmpty && shells.allSatisfy { $0.claudeSessionID == nil && $0.resumeCommand == nil && $0.cwd != nil }
            && (vm3.result ?? "").contains("cmux is running"), vm3.result ?? "-")
    for p in shells { _ = await sinks.waitReady(p.id) }
    await sleepMs(300)
    let typed = String(decoding: shells.flatMap { sinks.bytes($0.id) }, as: UTF8.self)
    r.check("…no resume command reached any pane", !typed.contains("--resume"), typed)
    vm3.onUndo?()
    CmuxImport.cmuxRunning = { false }
    c.presentCmuxImport(firstLaunch: true, from: src)
    r.check("cmux not running: no warning", c.cmuxImportModel?.cmuxRunning == false)
    CmuxImport.cmuxRunning = realCheck
}
