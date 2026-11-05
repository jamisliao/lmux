import AppKit
import LmuxTerminal

// Theme, font and appearance (set from the Settings window): theme and font write lmux's config
// (`~/.config/lmux/config`, Ghostty syntax) and reload it into every surface. Appearance and the
// sidebar look are lmux's own settings.

public enum LmuxThemes {
    /// Light / dark pairs from the bundled set (Resources/themes, Ghostty's theme files).
    public static let pairs: [(name: String, light: String, dark: String)] = [
        ("Nord", "Nord Light", "Nord"),
        ("Catppuccin", "Catppuccin Latte", "Catppuccin Mocha"),
        ("Tokyo Night", "TokyoNight Day", "TokyoNight"),
        ("Gruvbox", "Gruvbox Light", "Gruvbox Dark"),
        ("Solarized", "iTerm2 Solarized Light", "iTerm2 Solarized Dark"),
        ("One", "Atom One Light", "Atom One Dark"),
        ("Rosé Pine", "Rose Pine Dawn", "Rose Pine"),
        ("Kanagawa", "Kanagawa Lotus", "Kanagawa Wave"),
        ("Everforest", "Everforest Light Med", "Everforest Dark Med"),
        ("GitHub", "GitHub Light Default", "GitHub Dark Default"),
        ("Ayu", "Ayu Light", "Ayu"),
        ("Dracula", "Dracula", "Dracula"),
    ]
    public static let light = ["Nord Light", "Catppuccin Latte", "TokyoNight Day", "Gruvbox Light", "iTerm2 Solarized Light",
                               "Atom One Light", "Rose Pine Dawn", "Kanagawa Lotus", "Everforest Light Med",
                               "GitHub Light Default", "Ayu Light"]
    public static let dark = ["Nord", "Catppuccin Mocha", "Catppuccin Macchiato", "Catppuccin Frappe", "TokyoNight",
                              "TokyoNight Storm", "Dracula", "Gruvbox Dark", "iTerm2 Solarized Dark", "Atom One Dark",
                              "Rose Pine", "Kanagawa Wave", "Everforest Dark Med", "GitHub Dark Default", "Ayu"]
    /// Every bundled theme name.
    public static var all: [String] { Array(Set(light + dark)).sorted() }

    /// `theme = light:X,dark:Y` (or one theme for both).
    public static func spec(light: String, dark: String) -> String { light == dark ? light : "light:\(light),dark:\(dark)" }

    /// (light, dark) of a theme spec.
    public static func parse(_ spec: String) -> (light: String, dark: String) {
        var l: String?, d: String?
        for part in spec.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("light:") { l = String(t.dropFirst(6)) } else if t.hasPrefix("dark:") { d = String(t.dropFirst(5)) }
        }
        if l == nil, d == nil { return (spec, spec) }
        return (l ?? d!, d ?? l!)
    }

    public static var current: String { LmuxConfig.value(of: "theme") ?? LmuxConfig.defaultTheme }
}

public enum LmuxFonts {
    /// Ghostty's embedded default face (always available to the terminal, not installed).
    public static let embedded = "JetBrains Mono"

    /// Installed fixed-pitch families, plus the bundled D2Coding and Ghostty's embedded face.
    public static func families() -> [String] {
        LmuxConfig.registerBundledFonts()
        let fm = NSFontManager.shared
        var out = Set(fm.availableFontFamilies.filter { family in
            guard let members = fm.availableMembers(ofFontFamily: family) else { return false }
            return members.contains { m in
                guard m.count > 3, let traits = (m[3] as? NSNumber)?.uintValue else { return false }
                return NSFontTraitMask(rawValue: traits).contains(.fixedPitchFontMask)
            }
        })
        out.insert(LmuxConfig.defaultFontFamily)
        out.insert(embedded)
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The chain with `family` as the primary face; fallbacks (a Nerd Font, …) stay behind it.
    public static func chain(choosing family: String, current: [String]) -> [String] {
        [family] + current.dropFirst().filter { $0 != family }
    }
}

extension LmuxController {
    // MARK: Apply

    /// Write `theme` to lmux's config and reload every surface.
    public func applyTheme(_ spec: String) {
        do { try LmuxConfigFile().set("theme", [spec]) } catch { NSLog("lmux: writing the config failed: %@", "\(error)") }
        reloadTerminalConfig()
    }

    /// `font-family` primary, keeping the fallback chain (`font-family = ""` resets Ghostty's list first).
    public func applyFontFamily(_ family: String) {
        var current = LmuxConfig.fontFamilyChain()
        if current.isEmpty { current = [runtime.fontProfile == .korean ? LmuxConfig.defaultFontFamily : LmuxFonts.embedded] }
        let chain = LmuxFonts.chain(choosing: family, current: current)
        do { try LmuxConfigFile().set("font-family", ["\"\""] + chain) } catch { NSLog("lmux: writing the config failed: %@", "\(error)") }
        reloadTerminalConfig()
    }

    public var fontSize: Double { Double(LmuxConfig.value(of: "font-size") ?? "") ?? 13 }

    public func adjustFontSize(by delta: Double) {
        let size = min(max(fontSize + delta, 6), 48)
        do { try LmuxConfigFile().set("font-size", [size == size.rounded() ? "\(Int(size))" : "\(size)"]) } catch {
            NSLog("lmux: writing the config failed: %@", "\(error)")
        }
        reloadTerminalConfig()
    }

    /// Re-read lmux's config (after a menu change or the cmux import), every surface follows.
    public func reloadTerminalConfig() {
        configReloads += 1
        runtime.reloadConfig()
        afterConfigReload()
    }

    func afterConfigReload() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applySidebarLook()
                self.root.updateHeader()
                self.refreshPaneChrome()
                // Menu keys come from the Ghostty config: a `keybind` added or unbound since shows up now.
                self.buildMainMenu()
            }
        }
    }

    public func setAppearance(_ a: LmuxSettings.Appearance) {
        settings.appearance = a
        applyAppearance()
    }

    func applyAppearance() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        applySidebarLook()
    }

    /// The tab bar on panes with one tab (setting; cmux's "Tab bar visibility").
    public func setTabBarWithOneTab(_ on: Bool) {
        settings.tabBarWithOneTab = on
        SplitNode.stripWithOneTab = on
        rebuildContent()
        focusCurrent()
    }

    public func setSidebarMatchesTerminal(_ on: Bool) {
        settings.sidebarMatchesTerminal = on
        applySidebarLook()
    }

    func applySidebarLook() {
        let match = settings.sidebarMatchesTerminal
            ? (model.selected?.focusedPane?.surface.terminalBackground ?? runtime.background) : nil
        root?.sidebarBackdrop.matchColor = match
        // Rows and the titlebar buttons on the terminal's color read like the content header.
        root?.sidebarHost.adoptAppearance(on: match)
        root?.updateClusterAppearance()
    }
}
