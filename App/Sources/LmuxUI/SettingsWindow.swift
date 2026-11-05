import AppKit
import LmuxHooks
import LmuxTerminal
import LmuxTokens
import Observation
import SwiftUI

private typealias T = LmuxTokens

// Settings (⌘,): a small native window with four toolbar tabs, System Settings style.
// About ten settings in all. Terminal ones (theme, font, size) write `~/.config/lmux/config`
// (Ghostty syntax, other lines kept) and reload every pane at once; the rest are lmux's own
// settings. Headless, the window is built but never shown.

/// A theme's colors, read from its Ghostty theme file (for the gallery's previews).
public struct ThemePalette: Equatable {
    public var background: NSColor
    public var foreground: NSColor
    public var ansi: [Int: NSColor]

    static var themeDirs: [URL] {
        var d: [URL] = []
        if let r = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] { d.append(URL(fileURLWithPath: r).appendingPathComponent("themes")) }
        if let r = Bundle.main.resourceURL { d.append(r.appendingPathComponent("ghostty/themes")) }
        return d
    }

    public static func load(_ name: String) -> ThemePalette? {
        guard let text = themeDirs.lazy.compactMap({ try? String(contentsOf: $0.appendingPathComponent(name), encoding: .utf8) }).first
        else { return nil }
        var bg: NSColor?, fg: NSColor?, ansi: [Int: NSColor] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "background": bg = color(parts[1])
            case "foreground": fg = color(parts[1])
            case "palette":
                let kv = parts[1].split(separator: "=", maxSplits: 1)
                if kv.count == 2, let i = Int(kv[0]), let c = color(String(kv[1])) { ansi[i] = c }
            default: break
            }
        }
        guard let bg, let fg else { return nil }
        return ThemePalette(background: bg, foreground: fg, ansi: ansi)
    }

    static func color(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// What the Settings window shows; every change goes straight to the controller.
@MainActor @Observable
public final class SettingsModel {
    @ObservationIgnored weak var controller: LmuxController?
    public var appearance: LmuxSettings.Appearance = .system
    public var lightTheme = "Nord Light"
    public var darkTheme = "Nord"
    /// The gallery shows the light or the dark themes.
    public var galleryDark = true
    public var sidebarMatch = false
    public var tabBarWithOneTab = true
    public var fontFamily = LmuxConfig.defaultFontFamily
    public var fallbacks: [String] = []
    public var fontSize: Double = 13
    public var fontQuery = ""
    public var sound = "Off"
    public var dockBadge = false
    public var unreadRing = true
    public var remindAfter = 3
    public var remindNotification = false
    public var warnBeforeQuit = true
    public var restoreScrollback = true
    public var allowExternalSend = false
    public var hooksInstalled = false
    /// Codex CLI: found on this Mac, lmux's hooks installed, and whether Codex trusted them.
    public var codexFound = false
    public var codexHooksInstalled = false
    public var codexTrust: CodexHookInstaller.Trust = .notInstalled
    public var cmuxFound = false
    @ObservationIgnored lazy var families: [String] = LmuxFonts.families()
    @ObservationIgnored var palettes: [String: ThemePalette] = [:]

    static let sounds = ["Off", "Default", "Glass", "Ping", "Pop", "Purr", "Tink", "Submarine", "Hero", "Funk"]

    init(controller: LmuxController) { self.controller = controller; reload() }

    /// Re-read everything (the window opens, the config changed elsewhere).
    func reload() {
        guard let c = controller else { return }
        appearance = c.settings.appearance
        let t = LmuxThemes.parse(LmuxThemes.current)
        lightTheme = t.light
        darkTheme = t.dark
        galleryDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        sidebarMatch = c.settings.sidebarMatchesTerminal
        tabBarWithOneTab = c.settings.tabBarWithOneTab
        let chain = LmuxConfig.fontFamilyChain()
        fontFamily = chain.first ?? (c.runtime.fontProfile == .korean ? LmuxConfig.defaultFontFamily : LmuxFonts.embedded)
        fallbacks = Array(chain.dropFirst())
        fontSize = c.fontSize
        sound = c.settings.notificationSound.map { $0 == "default" ? "Default" : $0 } ?? "Off"
        dockBadge = c.settings.dockBadge
        unreadRing = c.settings.unreadRing
        remindAfter = c.settings.remindAfterMinutes
        remindNotification = c.settings.remindNotification
        warnBeforeQuit = c.settings.warnBeforeQuit
        restoreScrollback = c.settings.restoreScrollback
        allowExternalSend = c.defaults.bool(forKey: "allowExternalSend")
        refreshHooks()
        cmuxFound = CmuxSources.current.exists
    }

    /// Hooks status for both agents (after an install / uninstall, and when the window opens).
    func refreshHooks() {
        hooksInstalled = HooksSetup.isInstalled(settingsPath: HooksSetup.settingsPath())
        codexHooksInstalled = CodexHooksSetup.isInstalled()
        codexFound = codexHooksInstalled || CodexHookInstaller.isInstalled()
        codexTrust = codexHooksInstalled ? CodexHooksSetup.trust() : .notInstalled
    }

    func palette(_ name: String) -> ThemePalette? {
        if let p = palettes[name] { return p }
        let p = ThemePalette.load(name)
        palettes[name] = p
        return p
    }

    // MARK: Changes

    func setAppearance(_ a: LmuxSettings.Appearance) {
        appearance = a
        controller?.setAppearance(a)
        if a != .system { galleryDark = a == .dark }
    }

    func chooseTheme(_ name: String) {
        if galleryDark { darkTheme = name } else { lightTheme = name }
        controller?.applyTheme(LmuxThemes.spec(light: lightTheme, dark: darkTheme))
    }

    func setSidebarMatch(_ on: Bool) { sidebarMatch = on; controller?.setSidebarMatchesTerminal(on) }
    func setTabBarWithOneTab(_ on: Bool) { tabBarWithOneTab = on; controller?.setTabBarWithOneTab(on) }

    func chooseFont(_ family: String) {
        fontFamily = family
        fallbacks.removeAll { $0 == family }
        controller?.applyFontChain([family] + fallbacks)
    }

    func addFallback(_ family: String) {
        guard family != fontFamily, !fallbacks.contains(family) else { return }
        fallbacks.append(family)
        controller?.applyFontChain([fontFamily] + fallbacks)
    }

    func removeFallback(_ family: String) {
        fallbacks.removeAll { $0 == family }
        controller?.applyFontChain([fontFamily] + fallbacks)
    }

    func setFontSize(_ size: Double) {
        let s = min(max(size.rounded(), 8), 32)
        guard s != fontSize else { return }
        fontSize = s
        controller?.setFontSize(s)
    }

    func setSound(_ s: String) {
        sound = s
        controller?.setNotificationSound(s == "Off" ? nil : s == "Default" ? "default" : s)
        if s != "Off", s != "Default", controller?.headless == false { NSSound(named: NSSound.Name(s))?.play() }
    }

    func setDockBadge(_ on: Bool) { dockBadge = on; controller?.settings.dockBadge = on; controller?.updateDockBadge() }
    func setUnreadRing(_ on: Bool) { unreadRing = on; controller?.settings.unreadRing = on; controller?.refreshPaneChrome() }
    func setRemindAfter(_ m: Int) { remindAfter = m; controller?.settings.remindAfterMinutes = m; controller?.updateAttention() }
    func setRemindNotification(_ on: Bool) { remindNotification = on; controller?.settings.remindNotification = on }
    func setWarnBeforeQuit(_ on: Bool) { warnBeforeQuit = on; controller?.settings.warnBeforeQuit = on }
    func setRestoreScrollback(_ on: Bool) { restoreScrollback = on; controller?.settings.restoreScrollback = on }
    func setAllowExternalSend(_ on: Bool) { allowExternalSend = on; controller?.defaults.set(on, forKey: "allowExternalSend") }

    var filteredFamilies: [String] {
        let q = fontQuery.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? families : families.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    /// The preview's font: the primary face with the fallbacks as its cascade (as the terminal draws).
    func previewFont(size: CGFloat) -> NSFont {
        let fallbackDescriptors = fallbacks.map { NSFontDescriptor(fontAttributes: [.family: $0]) }
        let d = NSFontDescriptor(fontAttributes: [.family: fontFamily == LmuxFonts.embedded ? "Menlo" : fontFamily])
            .addingAttributes([.cascadeList: fallbackDescriptors])
        return NSFont(descriptor: d, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension LmuxController {
    /// ⌘, (also Ghostty's `open_config`): the Settings window.
    @objc public func openSettings() {
        let w = settingsWindow ?? makeSettingsWindow()
        settingsWindow = w
        settingsModel?.reload()
        guard !headless else { return }
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    func makeSettingsWindow() -> NSWindow {
        let m = SettingsModel(controller: self)
        settingsModel = m
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = []
        for tab in SettingsTab.allCases {
            let vc = NSHostingController(rootView: SettingsTabView(tab: tab, model: m))
            vc.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: vc)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("lmux.settings")
        return w
    }

    // MARK: Writes the Settings window makes

    public func applyFontChain(_ chain: [String]) {
        do { try LmuxConfigFile().set("font-family", ["\"\""] + chain) } catch { NSLog("lmux: writing the config failed: %@", "\(error)") }
        reloadTerminalConfig()
    }

    public func setFontSize(_ size: Double) {
        do { try LmuxConfigFile().set("font-size", [size == size.rounded() ? "\(Int(size))" : "\(size)"]) } catch {
            NSLog("lmux: writing the config failed: %@", "\(error)")
        }
        reloadTerminalConfig()
    }

    public func setNotificationSound(_ s: String?) {
        settings.notificationSound = s
        notifier.sound = s
    }
}

enum SettingsTab: CaseIterable {
    case appearance, font, notifications, general
    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .font: return "Font"
        case .notifications: return "Notifications"
        case .general: return "General"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .font: return "textformat"
        case .notifications: return "bell.badge"
        case .general: return "gearshape"
        }
    }
    var height: CGFloat {
        switch self {
        case .appearance: return 650
        case .font: return 470
        case .notifications: return 330
        case .general: return 310
        }
    }
}

struct SettingsTabView: View {
    let tab: SettingsTab
    @Bindable var model: SettingsModel
    static let width: CGFloat = 640

    var body: some View {
        Group {
            switch tab {
            case .appearance: AppearanceTab(model: model)
            case .font: FontTab(model: model)
            case .notifications: NotificationsTab(model: model)
            case .general: GeneralTab(model: model)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.width, height: tab.height)
    }
}

// MARK: - Appearance

struct AppearanceTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                    Text("System").tag(LmuxSettings.Appearance.system)
                    Text("Light").tag(LmuxSettings.Appearance.light)
                    Text("Dark").tag(LmuxSettings.Appearance.dark)
                }
                .pickerStyle(.segmented)
                Toggle("Sidebar matches the terminal background", isOn: Binding(get: { model.sidebarMatch }, set: { model.setSidebarMatch($0) }))
                Toggle("Tab bar on panes with one tab", isOn: Binding(get: { model.tabBarWithOneTab }, set: { model.setTabBarWithOneTab($0) }))
            }
            Section {
                Picker("Theme for", selection: $model.galleryDark) {
                    Text("Light mode · \(model.lightTheme)").tag(false)
                    Text("Dark mode · \(model.darkTheme)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(ThemeCard.size.width), spacing: 12), count: 4), spacing: 12) {
                    ForEach(model.galleryDark ? LmuxThemes.dark : LmuxThemes.light, id: \.self) { name in
                        ThemeCard(name: name, palette: model.palette(name),
                                  selected: name == (model.galleryDark ? model.darkTheme : model.lightTheme)) {
                            model.chooseTheme(name)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            } header: {
                Text("Theme")
            } footer: {
                Text("lmux follows the appearance: light mode uses \(model.lightTheme), dark mode uses \(model.darkTheme).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

struct ThemeCard: View {
    let name: String
    let palette: ThemePalette?
    let selected: Bool
    let action: () -> Void
    static let size = CGSize(width: 128, height: 70)
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview
                    .frame(width: Self.size.width, height: Self.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? T.Colors.accent.color : Color.primary.opacity(hover ? 0.25 : 0.12),
                                          lineWidth: selected ? 2 : 1))
                    .padding(selected ? 0 : 0)
                Text(Self.displayName(name))
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(name)
        .accessibilityLabel("\(Self.displayName(name)) theme")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    static func displayName(_ n: String) -> String {
        n.replacingOccurrences(of: "iTerm2 ", with: "").replacingOccurrences(of: "TokyoNight", with: "Tokyo Night")
    }

    @ViewBuilder var preview: some View {
        if let p = palette {
            ZStack(alignment: .topLeading) {
                Color(nsColor: p.background)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in
                            Circle().fill(Color(nsColor: p.ansi[i] ?? p.foreground)).frame(width: 8, height: 8)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("❯").foregroundStyle(Color(nsColor: p.ansi[5] ?? p.foreground))
                        Text("claude").foregroundStyle(Color(nsColor: p.foreground))
                    }
                    HStack(spacing: 4) {
                        Text("⏺").foregroundStyle(Color(nsColor: p.ansi[2] ?? p.foreground))
                        Text("Done.").foregroundStyle(Color(nsColor: p.foreground).opacity(0.75))
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .padding(9)
            }
        } else {
            Color.secondary.opacity(0.1)
        }
    }
}

// MARK: - Font

struct FontTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Font") {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 6) {
                        TextField("Search fonts", text: $model.fontQuery)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search fonts")
                        List(model.filteredFamilies, id: \.self, selection: Binding(get: { model.fontFamily }, set: { if let f = $0 { model.chooseFont(f) } })) { f in
                            Text(f).font(.custom(f == LmuxFonts.embedded ? "Menlo" : f, size: 12.5)).lineLimit(1).tag(f)
                        }
                        .listStyle(.bordered(alternatesRowBackgrounds: false))
                        .frame(height: 150)
                        .accessibilityLabel("Font family")
                    }
                    .frame(width: 250)
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Size") {
                            Stepper(value: Binding(get: { model.fontSize }, set: { model.setFontSize($0) }), in: 8...32, step: 1) {
                                Text("\(Int(model.fontSize)) pt").monospacedDigit()
                            }
                            .accessibilityLabel("Font size")
                        }
                        Slider(value: Binding(get: { model.fontSize }, set: { model.setFontSize($0) }), in: 9...24, step: 1)
                            .accessibilityLabel("Font size")
                        Text("Fallbacks (for glyphs the font lacks, such as Nerd Font icons)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(model.fallbacks, id: \.self) { f in
                            HStack {
                                Text("+ \(f)").font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Button { model.removeFallback(f) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove fallback \(f)")
                            }
                        }
                        Menu("Add Fallback…") {
                            ForEach(model.families.filter { $0 != model.fontFamily && !model.fallbacks.contains($0) }, id: \.self) { f in
                                Button(f) { model.addFallback(f) }
                            }
                        }
                        .fixedSize()
                    }
                }
            }
            Section("Preview") {
                FontPreview(model: model)
            }
        }
    }
}

struct FontPreview: View {
    @Bindable var model: SettingsModel
    @Environment(\.colorScheme) private var scheme
    static let sample = "❯ claude \"한글 입력 테스트 — Hello, lmux 0Oo1lI {}[]\""
    static let icons = "\u{F07C}  \u{E725}  \u{F418}  \u{E0A0} main  \u{F00C} 14 passed"

    var body: some View {
        let p = model.palette(scheme == .dark ? model.darkTheme : model.lightTheme)
        let font = Font(model.previewFont(size: CGFloat(model.fontSize)))
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.sample).foregroundStyle(Color(nsColor: p?.foreground ?? .textColor))
            // Nerd Font icons only when a fallback can draw them (else they'd be boxes).
            if model.fallbacks.contains(where: { $0.localizedCaseInsensitiveContains("nerd") }) {
                Text(Self.icons).foregroundStyle(Color(nsColor: p?.ansi[2] ?? .systemGreen))
            }
            Text("⏺ Found it. createPartialRefund() never compares the amount.")
                .foregroundStyle(Color(nsColor: p?.foreground ?? .textColor).opacity(0.8))
        }
        .font(font)
        .lineLimit(1)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: p?.background ?? .textBackgroundColor)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Font preview")
    }
}

// MARK: - Notifications

struct NotificationsTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Sound", selection: Binding(get: { model.sound }, set: { model.setSound($0) })) {
                    ForEach(SettingsModel.sounds, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Unread count on the Dock icon", isOn: Binding(get: { model.dockBadge }, set: { model.setDockBadge($0) }))
                Toggle("Ring around a pane that needs you", isOn: Binding(get: { model.unreadRing }, set: { model.setUnreadRing($0) }))
            }
            Section {
                Picker("Remind me after", selection: Binding(get: { model.remindAfter }, set: { model.setRemindAfter($0) })) {
                    Text("Off").tag(0)
                    ForEach([2, 3, 5, 10, 15], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Remind again via notification", isOn: Binding(get: { model.remindNotification }, set: { model.setRemindNotification($0) }))
                    .disabled(model.remindAfter == 0)
            } footer: {
                Text("lmux notifies only for panes you aren’t looking at. A finished or waiting row you haven’t looked at gently breathes after the reminder delay.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @Bindable var model: SettingsModel

    private var codexStatus: String {
        guard model.codexHooksInstalled else { return "Not installed: rows can’t show what Codex is doing." }
        if case .needsReview = model.codexTrust {
            return "Installed. Codex asks once to trust them: choose “Trust all and continue”."
        }
        return "Installed: states, alerts and History work."
    }

    var body: some View {
        Form {
            Section {
                Toggle("Ask before quitting while something runs",
                       isOn: Binding(get: { model.warnBeforeQuit }, set: { model.setWarnBeforeQuit($0) }))
                Toggle(isOn: Binding(get: { model.restoreScrollback }, set: { model.setRestoreScrollback($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restore terminal output after relaunch")
                        Text("Shell panes show their last output again. Saved privately at quit, deleted once shown.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: Binding(get: { model.allowExternalSend }, set: { model.setAllowExternalSend($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow other apps to send input to lmux")
                        Text("Lets scripts like Raycast or Hammerspoon use `lmux send`. Leave off unless you need it.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        if model.hooksInstalled {
                            Button("Uninstall") { model.controller?.presentHooksSheet(install: false) }
                        }
                        Button(model.hooksInstalled ? "Update" : "Install") { model.controller?.presentHooksSheet(install: true) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code hooks")
                        Text(model.hooksInstalled ? "Installed: states, alerts and History work." : "Not installed: rows can’t show what Claude is doing.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if model.codexFound {
                    LabeledContent {
                        HStack {
                            if model.codexHooksInstalled {
                                Button("Uninstall") { model.controller?.presentHooksSheet(install: false, agent: .codex) }
                            }
                            Button(model.codexHooksInstalled ? "Update" : "Install") {
                                model.controller?.presentHooksSheet(install: true, agent: .codex)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Codex hooks")
                            Text(codexStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent {
                    Button("Import from cmux…") { model.controller?.presentCmuxImport() }
                        .disabled(!model.cmuxFound)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("cmux")
                        Text(model.cmuxFound ? "Bring over your theme, fonts, shortcuts and workspaces." : "No cmux setup found on this Mac.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Open config file") { model.controller?.openConfigFile() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .help(LmuxConfig.configFile.path)
                }
            } footer: {
                Text("Everything here is also plain text in \(abbreviateHome(LmuxConfig.configFile.path)) (Ghostty syntax).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
