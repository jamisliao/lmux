// Config loading adapted from Ghostty (https://github.com/ghostty-org/ghostty) at
// commit ff23824: macos/Sources/Ghostty/Ghostty.Config.swift (loadConfig).
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
// See THIRD_PARTY_NOTICES.md.

import CoreText
import Foundation
import GhosttyKit

public enum LmuxConfig {
    /// lmux's Korean default font (bundled), also used for the Hangul codepoint map.
    public static let defaultFontFamily = "D2Coding"

    /// Default theme, used when the user's Ghostty config does not set `theme`.
    public static let defaultTheme = "light:Nord Light,dark:Nord"

    /// Hangul ranges that always render with D2Coding unless the user maps them.
    public static let hangulRanges = [
        "U+1100-U+11FF", // Hangul Jamo
        "U+3130-U+318F", // Hangul Compatibility Jamo
        "U+A960-U+A97F", // Hangul Jamo Extended-A
        "U+AC00-U+D7A3", // Hangul Syllables
        "U+D7B0-U+D7FF", // Hangul Jamo Extended-B
    ]

    /// Which default font family lmux applies when the user's Ghostty config
    /// does not set `font-family`. Decided once (from the system language on
    /// first launch) and persisted, so a later language change does not
    /// silently switch fonts.
    public enum FontProfile: String {
        /// Korean system language: font-family = D2Coding.
        case korean
        /// Anything else: leave font-family unset (Ghostty's embedded JetBrains Mono).
        case `default`
    }

    public static let fontProfileDefaultsKey = "defaultFontProfile"

    /// Returns the persisted profile, or decides it from `preferredLanguage`
    /// (default: `Locale.preferredLanguages.first`) and persists it.
    public static func resolveFontProfile(
        defaults: UserDefaults = .standard,
        preferredLanguage: () -> String? = { Locale.preferredLanguages.first }
    ) -> FontProfile {
        if let raw = defaults.string(forKey: fontProfileDefaultsKey),
           let profile = FontProfile(rawValue: raw) {
            return profile
        }
        let lang = preferredLanguage()?.lowercased() ?? ""
        let profile: FontProfile = lang.hasPrefix("ko") ? .korean : .default
        defaults.set(profile.rawValue, forKey: fontProfileDefaultsKey)
        return profile
    }

    /// Config lines lmux injects around the user's Ghostty config.
    public struct Plan: Equatable {
        /// Loaded before the user's config (so the user's values win).
        public var beforeUser: [String]
        /// Loaded after the user's config (only for keys the user did not set).
        public var afterUser: [String]
    }

    /// Decide lmux's injected defaults. Precedence (later wins):
    ///   1. lmux defaults: theme (Nord), window padding, minimum contrast, Hangul -> D2Coding codepoint map
    ///   2. the user's Ghostty config
    ///   3. font-family = D2Coding, only for the Korean profile and only if
    ///      the user did not set font-family
    ///
    /// font-family goes last and conditionally because it is a repeatable key:
    /// loading it before the user's value would demote the user's font to a
    /// fallback. The codepoint map goes first because libghostty gives later
    /// entries priority, so a user mapping for the same ranges wins.
    public static func plan(fontProfile: FontProfile, userSets: (String) -> Bool) -> Plan {
        var before: [String] = []
        if !userSets("theme") {
            before.append("theme = \(defaultTheme)")
        }
        // Breathing room around the grid (the mockup's 14 x 10pt); user value wins.
        if !userSets("window-padding-x") { before.append("window-padding-x = 14") }
        if !userSets("window-padding-y") { before.append("window-padding-y = 10") }
        // Text the theme pair makes unreadable is drawn black or white instead: Claude Code's default
        // (dark) theme in a light terminal draws plain code #f8f8f2 and inline code #b1b9f9 on Nord
        // Light's #e5e9f0 (1.1 and 1.5:1). At 2, everything Claude's default theme draws is >= 2:1 on
        // every bundled light theme; the cost is 16 of 132 light-theme palette hues that are below 2:1
        // themselves (Nord Light's green / yellow / cyan, 1.9:1) going black. 2.5 would also blacken
        // Nord Light's blue and magenta (35 hues), 3 most of Nord / Everforest / Ayu Light's palettes.
        // Measured: `lmux-apptest --contrast-matrix`. User value wins.
        if !userSets("minimum-contrast") { before.append("minimum-contrast = 2") }
        // No dimming of unfocused splits: focus shows in the pane header and Ghostty's hollow
        // cursor (POLISH.md 9). The dim fill could also linger at a stale size. User value wins.
        if !userSets("unfocused-split-opacity") { before.append("unfocused-split-opacity = 1") }
        // ⇧⌘J is lmux's "next pane that needs input"; Ghostty's default binds it to
        // write_screen_file:paste. Unbound here, before the user's config, so a user binding still wins.
        before.append("keybind = super+shift+j=unbind")
        before += hangulRanges.map { "font-codepoint-map = \($0)=\(defaultFontFamily)" }
        var after: [String] = []
        if fontProfile == .korean && !userSets("font-family") {
            after.append("font-family = \(defaultFontFamily)")
        }
        return Plan(beforeUser: before, afterUser: after)
    }

    /// Load the user's Ghostty configuration exactly like Ghostty.app does
    /// (default files + recursive `config-file` includes) with lmux's defaults
    /// applied per `plan(fontProfile:userSets:)`.
    ///
    /// `simulatedUserConfig` lines are treated as if they were in the user's
    /// config file (used by tests).
    ///
    /// Order (later wins): lmux defaults, the Ghostty config files, lmux's own config
    /// (`configFile`, `~/.config/lmux/config`), then `overrides` (theme previews).
    public static func load(simulatedUserConfig: [String] = [], fontProfile: FontProfile? = nil,
                            overrides: [String] = []) -> ghostty_config_t? {
        registerBundledFonts()
        guard let cfg = ghostty_config_new() else { return nil }

        let plan = plan(fontProfile: fontProfile ?? resolveFontProfile()) {
            userConfigSetsKey($0, extra: simulatedUserConfig)
        }
        loadLines(cfg, plan.beforeUser, name: "defaults")
        if !ignoresGhosttyFiles { ghostty_config_load_default_files(cfg) }
        loadLines(cfg, simulatedUserConfig, name: "user")
        if FileManager.default.fileExists(atPath: configFile.path) { ghostty_config_load_file(cfg, configFile.path) }
        ghostty_config_load_recursive_files(cfg)
        loadLines(cfg, plan.afterUser, name: "font")
        loadLines(cfg, overrides, name: "preview")

        ghostty_config_finalize(cfg)

        let diagsCount = ghostty_config_diagnostics_count(cfg)
        for i in 0..<diagsCount {
            let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
            NSLog("lmux: ghostty config error: %@", String(cString: diag.message))
        }
        return cfg
    }

    private static func loadLines(_ cfg: ghostty_config_t, _ lines: [String], name: String) {
        guard !lines.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmux-\(name)-\(getpid()).ghostty")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        ghostty_config_load_file(cfg, url.path)
        try? FileManager.default.removeItem(at: url)
    }

    /// Register fonts shipped in the app bundle (D2Coding Regular + Bold, WOFF) for this
    /// process only, so users do not need them installed.
    /// Font files registered by `registerBundledFonts` (tests).
    public private(set) static var registeredFontFiles: [URL] = []

    public static func registerBundledFonts() {
        struct Once { static var done = false }
        guard !Once.done else { return }
        Once.done = true
        var dirs: [URL] = []
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("Fonts")) }
        if let env = ProcessInfo.processInfo.environment["LMUX_FONTS_DIR"] {
            dirs.append(URL(fileURLWithPath: env))
        }
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files where ["ttc", "ttf", "otf", "woff"].contains(url.pathExtension.lowercased()) {
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    registeredFontFiles.append(url)
                } else {
                    // Already-registered (e.g. also installed system-wide) is fine.
                    NSLog("lmux: font registration skipped for %@", url.lastPathComponent)
                }
            }
        }
    }

    /// lmux's own config (Ghostty syntax), loaded after Ghostty's files: what the Theme / Font
    /// menus and the cmux import write. `LMUX_CONFIG_FILE` points elsewhere (tests).
    public static var configFile: URL {
        if let f = ProcessInfo.processInfo.environment["LMUX_CONFIG_FILE"], !f.isEmpty { return URL(fileURLWithPath: f) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        return xdg.appendingPathComponent("lmux/config")
    }

    /// The `font-family` chain in effect (primary first, then fallbacks), from the same files
    /// lmux loads; an empty value resets the chain as in Ghostty. Empty: lmux's default.
    public static func fontFamilyChain(extra: [String] = []) -> [String] {
        var chain: [String] = []
        for line in configLines(extra: extra) where line.key == "font-family" {
            let v = line.value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if v.isEmpty { chain = [] } else if !chain.contains(v) { chain.append(v) }
        }
        return chain
    }

    /// The last value of `key` in the files lmux loads.
    public static func value(of key: String, extra: [String] = []) -> String? {
        configLines(extra: extra).last { $0.key == key }?.value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Ghostty's `working-directory` as a directory: an absolute path (`~/` expanded) that exists,
    /// otherwise home (`home`, `inherit`, unset, or a path that isn't there).
    public static func workingDirectory(extra: [String] = []) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard var v = value(of: "working-directory", extra: extra), v != "home", v != "inherit" else { return home }
        if v.hasPrefix("~/") { v = home + v.dropFirst() }
        var isDir: ObjCBool = false
        return v.hasPrefix("/") && FileManager.default.fileExists(atPath: v, isDirectory: &isDir) && isDir.boolValue ? v : home
    }

    /// A new workspace starts in the focused pane's directory only when the config asks for it:
    /// `working-directory = inherit`, or `window-` / `tab-inherit-working-directory = true` set
    /// explicitly. Ghostty's own default for those keys is true; lmux's is `working-directory`
    /// (else home), so ⌘N doesn't land in whatever repo the focused pane is in.
    public static func newWorkspaceInherits(extra: [String] = []) -> Bool {
        value(of: "working-directory", extra: extra) == "inherit"
            || value(of: "window-inherit-working-directory", extra: extra) == "true"
            || value(of: "tab-inherit-working-directory", extra: extra) == "true"
    }

    /// A split starts in its pane's directory unless `split-inherit-working-directory = false`.
    public static func splitInherits(extra: [String] = []) -> Bool {
        value(of: "split-inherit-working-directory", extra: extra) != "false"
    }

    /// `key = value` lines of the Ghostty config files then lmux's (comments dropped), in load order.
    static func configLines(extra: [String]) -> [(key: String, value: String)] {
        var files = defaultConfigFiles
        files.append(configFile)
        var out: [(String, String)] = []
        for text in files.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }) + [extra.joined(separator: "\n")] {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                out.append((line[..<eq].trimmingCharacters(in: .whitespaces), line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
            }
        }
        return out
    }

    /// `LMUX_IGNORE_GHOSTTY_CONFIG=1` (tests): the user's Ghostty config files are not read, so a
    /// run sees lmux's defaults and `LMUX_CONFIG_FILE` only (Ghostty finds Application Support
    /// through NSFileManager, which no HOME override reaches).
    static var ignoresGhosttyFiles: Bool { ProcessInfo.processInfo.environment["LMUX_IGNORE_GHOSTTY_CONFIG"] == "1" }

    /// The files Ghostty's `loadDefaultFiles` reads on macOS, in order.
    static var defaultConfigFiles: [URL] {
        if ignoresGhosttyFiles { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let appSupport = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [
            xdg.appendingPathComponent("ghostty/config"),
            xdg.appendingPathComponent("ghostty/config.ghostty"),
            appSupport.appendingPathComponent("config"),
            appSupport.appendingPathComponent("config.ghostty"),
        ]
    }

    /// True if the user's Ghostty config (including `config-file` includes) sets `key`.
    /// libghostty's C API cannot read back repeatable keys such as font-family,
    /// so we scan the same files Ghostty loads.
    static func userConfigSetsKey(_ key: String, extra: [String] = []) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var queue: [(URL?, String)] = [(nil, extra.joined(separator: "\n"))]
        queue += (defaultConfigFiles + [configFile]).compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map { (url, $0) }
        }
        var seen = Set<String>()
        while !queue.isEmpty {
            let (url, text) = queue.removeFirst()
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if k == key { return true }
                guard k == "config-file" else { continue }
                if v.hasPrefix("?") { v.removeFirst() }
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if v.hasPrefix("~/") { v = home.path + v.dropFirst() }
                let base = url?.deletingLastPathComponent() ?? home
                let include = v.hasPrefix("/") ? URL(fileURLWithPath: v) : base.appendingPathComponent(v)
                guard seen.insert(include.standardizedFileURL.path).inserted,
                      let s = try? String(contentsOf: include, encoding: .utf8) else { continue }
                queue.append((include, s))
            }
        }
        return false
    }
}
