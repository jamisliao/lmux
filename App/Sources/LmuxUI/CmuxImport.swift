import AppKit
import LmuxHooks
import LmuxTerminal
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

// "Bring over your cmux setup": everything cmux has that lmux has an equivalent for, read from
// cmux's files (never written): its Ghostty config, settings.json / cmux.json (JSONC), its
// defaults (the plist, read as a file) and its session (open workspaces). Terminal keys and
// shortcuts go into one block of lmux's config, replaced on every import (idempotent); app and
// notification settings into lmux's settings; workspaces open once (by cmux id, never twice).

/// Where cmux keeps things. `LMUX_CMUX_HOME` points at a HOME-like fixture (tests).
public struct CmuxSources {
    public let home: URL
    public init(home: URL) { self.home = home }

    public static var current: CmuxSources {
        if let h = ProcessInfo.processInfo.environment["LMUX_CMUX_HOME"], !h.isEmpty { return CmuxSources(home: URL(fileURLWithPath: h)) }
        return CmuxSources(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var ghosttyConfig: URL { home.appendingPathComponent("Library/Application Support/com.cmuxterm.app/config.ghostty") }
    /// In precedence order (settings.json wins over cmux.json).
    public var settingsFiles: [URL] { [home.appendingPathComponent(".config/cmux/settings.json"), home.appendingPathComponent(".config/cmux/cmux.json")] }
    public var defaultsPlist: URL { home.appendingPathComponent("Library/Preferences/com.cmuxterm.app.plist") }
    public var session: URL { home.appendingPathComponent("Library/Application Support/cmux/session-com.cmuxterm.app.json") }

    public var allFiles: [URL] { [ghosttyConfig, defaultsPlist, session] + settingsFiles }
    public var exists: Bool { allFiles.contains { FileManager.default.fileExists(atPath: $0.path) } }
}

/// JSON with comments and trailing commas (cmux's settings files).
public enum JSONC {
    public static func strip(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        var inString = false
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i) < s.endIndex ? s[s.index(after: i)] : nil
            if inString {
                out.append(c)
                if c == "\\", let n = next { out.append(n); i = s.index(i, offsetBy: 2); continue }
                if c == "\"" { inString = false }
                i = s.index(after: i)
                continue
            }
            if c == "\"" { inString = true; out.append(c); i = s.index(after: i); continue }
            if c == "/", next == "/" {
                while i < s.endIndex, s[i] != "\n" { i = s.index(after: i) }
                continue
            }
            if c == "/", next == "*" {
                i = s.index(i, offsetBy: 2)
                while i < s.endIndex, !(s[i] == "*" && s.index(after: i) < s.endIndex && s[s.index(after: i)] == "/") { i = s.index(after: i) }
                if i < s.endIndex { i = s.index(i, offsetBy: 2) }
                continue
            }
            out.append(c)
            i = s.index(after: i)
        }
        // Trailing commas: `,` followed (after whitespace) by `}` or `]`, outside strings.
        var res = ""
        inString = false
        let chars = Array(out)
        var k = 0
        while k < chars.count {
            let c = chars[k]
            if inString {
                res.append(c)
                if c == "\\", k + 1 < chars.count { res.append(chars[k + 1]); k += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true; res.append(c)
            } else if c == "," {
                var j = k + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { k += 1; continue }
                res.append(c)
            } else {
                res.append(c)
            }
            k += 1
        }
        return res
    }

    public static func parse(_ s: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(strip(s).utf8), options: [.fragmentsAllowed])
    }
}

/// What an import would bring, per section, and what lmux can't take.
public struct CmuxImportPlan {
    public enum Section: String, CaseIterable, Identifiable {
        case look = "Terminal look", app = "App", notifications = "Notifications", shortcuts = "Keyboard shortcuts",
             workspaces = "Open workspaces"
        public var id: String { rawValue }
    }

    /// Lines for lmux's config (theme, fonts, size, other Ghostty keys).
    public var configLines: [String] = []
    /// `keybind = …` lines for Ghostty actions.
    public var keybinds: [String] = []
    /// lmux's own shortcuts (action id -> "cmd+shift+u").
    public var lmuxShortcuts: [String: String] = [:]
    public var appearance: LmuxSettings.Appearance?
    public var warnBeforeQuit: Bool?
    public var windowFrame: NSRect?
    public var sidebarWidth: CGFloat?
    public var sidebarVisible: Bool?
    public var sidebarMatch: Bool?
    /// cmux's tab bar visibility: "always" (true) or "multiple-tabs".
    public var tabBarWithOneTab: Bool?
    /// .some(nil) = sound off.
    public var sound: String??
    public var dockBadge: Bool?
    public var unreadRing: Bool?
    public var workspaces: [LayoutFile.WorkspaceState] = []
    /// The workspace cmux had selected (lmux id), selected after the import.
    public var selectedWorkspace: String?
    /// One line per section for the sheet.
    public var summary: [Section: [String]] = [:]
    public var notImported: [String] = []
    /// Keyboard shortcuts found (cmux's own and Ghostty `keybind` lines).
    public var shortcutCount = 0

    public func has(_ s: Section) -> Bool { !(summary[s] ?? []).isEmpty }

    /// One line for the sheet: "Theme, font, app settings, 12 shortcuts and 5 open workspaces".
    public var headline: String {
        var parts: [String] = []
        if has(.look) {
            let keys = configLines.compactMap { $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) }
            if keys.contains("theme") { parts.append("theme") }
            if configLines.contains(where: { $0.hasPrefix("font-family = ") && $0 != "font-family = \"\"" }) || keys.contains("font-size") { parts.append("font") }
            let other = keys.filter { !["theme", "font-family", "font-size"].contains($0) }.count
            if other > 0 { parts.append("\(other) Ghostty \(other == 1 ? "setting" : "settings")") }
        }
        if has(.app) { parts.append("app settings") }
        if has(.notifications) { parts.append("notification settings") }
        if has(.shortcuts) { parts.append("\(shortcutCount) \(shortcutCount == 1 ? "shortcut" : "shortcuts")") }
        if has(.workspaces) { parts.append("\(workspaces.count) open \(workspaces.count == 1 ? "workspace" : "workspaces")") }
        let line = parts.count <= 1 ? parts.joined() : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// The not-imported list in one line ("Browser panes, SSH and remote workspaces and 7 more").
    public var notImportedLine: String? {
        guard !notImported.isEmpty else { return nil }
        let shown = notImported.prefix(2).map { $0.replacingOccurrences(of: " and the browser’s settings", with: "") }
        let rest = notImported.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }
}

/// What an import changed, to put back (Undo cmux Import): lmux's config file bytes, its settings,
/// the sidebar and window, and the workspaces it opened (closed again only if left as they came).
struct CmuxImportUndo {
    let config: Data?
    /// lmux's config's cmux block before (header included; nil: none).
    let configBlock: [String]?
    let settings: [String: Any]
    let sidebarWidth: CGFloat
    let sidebarVisible: Bool
    let frame: NSRect?
    let selectedID: String?
    /// The same, right after the import: Undo puts back only what still has the imported value.
    var configAfter: Data?
    var settingsAfter: [String: Any] = [:]
    var sidebarWidthAfter: CGFloat = 0
    var sidebarVisibleAfter = true
    var frameAfter: NSRect?
    /// The workspaces it opened: pane ids, title, and each pane's agent session as it came.
    var workspaces: [(id: String, panes: [String], title: String?, sessions: [String?])] = []
    /// lmux's untouched first workspace, closed so the imported ones start at the top.
    var initial: (id: String, accent: Int, cwd: String?)?
}

public enum CmuxImport {
    /// cmux is running: its panes still hold their Claude / Codex sessions, so the import opens
    /// shells in those directories without resuming them (two apps on one session). Fixture runs
    /// (`LMUX_CMUX_HOME`) never look at the real cmux; tests set this.
    @MainActor public static var cmuxRunning: () -> Bool = {
        if let h = ProcessInfo.processInfo.environment["LMUX_CMUX_HOME"], !h.isEmpty { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").isEmpty
    }

    /// `n` without its agent session: a plain shell in the same directory.
    static func withoutSessions(_ n: LayoutFile.NodeState) -> LayoutFile.NodeState {
        var n = n
        func strip(_ p: LayoutFile.PaneState) -> LayoutFile.PaneState {
            var p = p
            p.claudeSession = nil; p.agent = nil; p.resumeCommand = nil; p.resumeEnvironment = nil; p.transcriptPath = nil
            return p
        }
        n.pane = n.pane.map(strip)
        n.tabs = n.tabs?.map(strip)
        n.children = n.children?.map(withoutSessions)
        return n
    }

    /// Ghostty keys lmux ignores (window chrome, platform, quick terminal, updates).
    static let unsupportedPrefixes = ["macos-", "gtk-", "linux-", "x11-", "quick-terminal-", "auto-update", "window-decoration",
                                      "window-theme", "window-save-state", "window-step-resize", "window-new-tab-position",
                                      "window-titlebar", "window-show-tab-bar", "window-colorspace", "initial-window", "title",
                                      "class", "app-notifications", "fullscreen", "background-opacity", "background-blur",
                                      "resize-overlay", "undo-timeout", "bell-features", "split-divider-color", "custom-shader"]

    /// cmux shortcut -> Ghostty action lmux's menus take their key from.
    static let ghosttyActions: [String: String] = [
        "newTab": "new_window", "newSurface": "new_tab", "splitRight": "new_split:right", "splitDown": "new_split:down",
        "closeTab": "close_surface", "closeWorkspace": "close_window",
        "focusLeft": "goto_split:left", "focusRight": "goto_split:right", "focusUp": "goto_split:up", "focusDown": "goto_split:down",
        "nextSurface": "next_tab", "prevSurface": "previous_tab", "find": "start_search",
        "findNext": "navigate_search:next", "findPrevious": "navigate_search:previous", "reloadConfiguration": "reload_config",
        "openSettings": "open_config",
    ]
    /// cmux shortcut -> lmux's own menu actions.
    static let lmuxActions: [String: String] = [
        "jumpToUnread": "jumpToUnread", "toggleSidebar": "toggleSidebar", "renameWorkspace": "renameWorkspace",
        "showNotifications": "showNotifications", "renameTab": "renameTab", "closeOtherTabsInPane": "closeOtherTabs",
        "moveSurfaceLeft": "moveTabLeft", "moveSurfaceRight": "moveTabRight",
        "nextSidebarTab": "nextWorkspace", "prevSidebarTab": "previousWorkspace",
    ]
    /// cmux features lmux doesn't have.
    static let notInLmux = ["Browser panes and the browser’s settings", "SSH and remote workspaces", "Custom commands and automation",
                            "Command palette", "Telemetry setting", "Sidebar extras (ports, pull requests, logs, progress)",
                            "Pane flash", "Right sidebar (files)", "Custom sidebar tint"]

    /// cmux "cmd+shift+w" -> Ghostty "super+shift+w".
    static func ghosttyTrigger(_ s: String) -> String? {
        var parts: [String] = []
        for p in s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            switch p {
            case "cmd", "command": parts.append("super")
            case "opt", "option", "alt": parts.append("alt")
            case "ctrl", "control": parts.append("ctrl")
            case "shift": parts.append("shift")
            case "←": parts.append("arrow_left")
            case "→": parts.append("arrow_right")
            case "↑": parts.append("arrow_up")
            case "↓": parts.append("arrow_down")
            case "\r", "enter", "return": parts.append("enter")
            case "": parts.append("plus")
            default:
                guard p.count == 1 || ["tab", "space", "escape", "backspace"].contains(p) else { return nil }
                parts.append(p)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "+")
    }

    static func readJSONSettings(_ src: CmuxSources) -> [String: Any] {
        // settings.json wins: merge cmux.json first, then settings.json over it (per leaf).
        var merged: [String: Any] = [:]
        func merge(_ a: [String: Any], into b: inout [String: Any]) {
            for (k, v) in a {
                if let d = v as? [String: Any], var e = b[k] as? [String: Any] { merge(d, into: &e); b[k] = e } else { b[k] = v }
            }
        }
        for url in src.settingsFiles.reversed() {
            if let t = try? String(contentsOf: url, encoding: .utf8), let o = JSONC.parse(t) as? [String: Any] { merge(o, into: &merged) }
        }
        return merged
    }

    static func readDefaults(_ src: CmuxSources) -> [String: Any] {
        guard let d = try? Data(contentsOf: src.defaultsPlist),
              let o = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return [:] }
        return o
    }

    static func jsonBlob(_ v: Any?) -> Any? {
        if let d = v as? Data { return try? JSONSerialization.jsonObject(with: d) }
        if let s = v as? String { return try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
        return v
    }

    static func rect(_ v: Any?) -> NSRect? {
        guard let f = v as? [String: Any], let w = (f["width"] as? NSNumber)?.doubleValue, let h = (f["height"] as? NSNumber)?.doubleValue,
              w > 100, h > 100 else { return nil }
        return NSRect(x: (f["x"] as? NSNumber)?.doubleValue ?? 0, y: (f["y"] as? NSNumber)?.doubleValue ?? 0, width: w, height: h)
    }

    /// The lmux accent closest to a cmux workspace color.
    static func nearestAccent(_ hex: String) -> Int? {
        guard let c = ThemePalette.color(hex)?.usingColorSpace(.sRGB) else { return nil }
        var best: (Int, CGFloat)?
        for (i, a) in T.Colors.workspaceAccents.enumerated() {
            for v in [a.light, a.dark] {
                let r = CGFloat(v >> 16 & 0xFF) / 255, g = CGFloat(v >> 8 & 0xFF) / 255, b = CGFloat(v & 0xFF) / 255
                let d = pow(r - c.redComponent, 2) + pow(g - c.greenComponent, 2) + pow(b - c.blueComponent, 2)
                if best == nil || d < best!.1 { best = (i, d) }
            }
        }
        return best?.0
    }

    /// Read everything (no writes anywhere).
    public static func plan(_ src: CmuxSources) -> CmuxImportPlan {
        var p = CmuxImportPlan()
        let json = readJSONSettings(src)
        let defaults = readDefaults(src)
        var notImported = notInLmux

        // 1. Terminal look: cmux's Ghostty config.
        if let text = try? String(contentsOf: src.ghosttyConfig, encoding: .utf8) {
            var fonts: [String] = [], other: [String] = []
            var theme: String?, size: String?
            var lines: [String] = []
            var fontReset = false
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if key == "keybind" { p.keybinds.append("keybind = \(value)"); p.shortcutCount += 1; continue }
                if unsupportedPrefixes.contains(where: { key.hasPrefix($0) }) { notImported.append("Ghostty key “\(key)” (no lmux equivalent)"); continue }
                switch key {
                case "font-family":
                    if !fontReset { lines.append("font-family = \"\""); fontReset = true }
                    let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !v.isEmpty { fonts.append(v) }
                case "theme": theme = value
                case "font-size": size = value
                case "config-file":
                    var v = value
                    let optional = v.hasPrefix("?")
                    if optional { v.removeFirst() }
                    v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !v.hasPrefix("/") && !v.hasPrefix("~") { v = src.ghosttyConfig.deletingLastPathComponent().appendingPathComponent(v).path }
                    value = (optional ? "?" : "") + "\"\(v)\""
                    other.append(key)
                default: other.append(key)
                }
                lines.append("\(key) = \(value)")
            }
            p.configLines = lines
            var look: [String] = []
            if let theme { look.append("Theme: \(theme.replacingOccurrences(of: ",", with: ", "))") }
            if !fonts.isEmpty {
                look.append("Font: " + fonts[0] + (fonts.count > 1 ? " + " + fonts.dropFirst().joined(separator: ", ") + " (fallback)" : ""))
            }
            if let size { look.append("Font size: \(size) pt") }
            if !other.isEmpty { look.append("\(other.count) more Ghostty \(other.count == 1 ? "setting" : "settings") (\(Array(Set(other)).sorted().prefix(4).joined(separator: ", ")))") }
            p.summary[.look] = look
        }

        // 2. App.
        var app: [String] = []
        let appJSON = json["app"] as? [String: Any] ?? [:]
        if let a = (appJSON["appearance"] as? String) ?? (defaults["appearanceMode"] as? String),
           let mode = LmuxSettings.Appearance(rawValue: a.lowercased()) {
            p.appearance = mode
            app.append("Appearance: \(mode.rawValue.capitalized)")
        }
        if let w = (appJSON["warnBeforeQuit"] as? Bool) ?? (defaults["warnBeforeQuitShortcut"] as? NSNumber)?.boolValue {
            p.warnBeforeQuit = w
            app.append(w ? "Ask before quitting" : "Quit without asking")
        }
        let session = (try? Data(contentsOf: src.session)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let windows = session?["windows"] as? [[String: Any]] ?? []
        let window = windows.first
        let geometry = jsonBlob(defaults["cmux.session.lastWindowGeometry.v2"]) as? [String: Any]
        // A frame on a display that's no longer connected would put lmux's window off screen.
        if let f = rect(geometry?["frame"]) ?? rect(window?["frame"]),
           NSScreen.screens.isEmpty || NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) {
            p.windowFrame = f
            app.append("Window: \(Int(f.width)) × \(Int(f.height))")
        }
        if let sb = window?["sidebar"] as? [String: Any] {
            if let w = (sb["width"] as? NSNumber)?.doubleValue {
                p.sidebarWidth = min(max(CGFloat(w), T.Layout.sidebarWidthMin), T.Layout.sidebarWidthMax)
            }
            p.sidebarVisible = sb["isVisible"] as? Bool
            if p.sidebarWidth != nil || p.sidebarVisible != nil {
                app.append("Sidebar: " + [p.sidebarVisible == false ? "hidden" : "shown", p.sidebarWidth.map { "\(Int($0)) pt wide" }]
                    .compactMap { $0 }.joined(separator: ", "))
            }
        }
        if let m = ((json["sidebarAppearance"] as? [String: Any])?["matchTerminalBackground"] as? Bool)
            ?? (defaults["sidebarMatchTerminalBackground"] as? NSNumber)?.boolValue {
            p.sidebarMatch = m
            app.append(m ? "Sidebar matches the terminal background" : "Translucent sidebar")
        }
        if let v = (appJSON["tabBarVisibility"] as? String) ?? (defaults["paneTabBarVisibility"] as? String),
           v == "always" || v == "multiple-tabs" {
            p.tabBarWithOneTab = v == "always"
            app.append(v == "always" ? "Tab bar on every pane" : "Tab bar only with two or more tabs")
        }
        p.summary[.app] = app

        // 3. Notifications.
        var notes: [String] = []
        let nj = json["notifications"] as? [String: Any] ?? [:]
        if let s = nj["sound"] as? String {
            let off = s.isEmpty || s.lowercased() == "none" || s.lowercased() == "off"
            p.sound = .some(off ? nil : s.lowercased() == "default" ? "default" : s)
            notes.append(off ? "Sound: off" : "Sound: \(s)")
        }
        if let b = nj["dockBadge"] as? Bool { p.dockBadge = b; notes.append(b ? "Dock badge" : "No Dock badge") }
        if let r = nj["unreadPaneRing"] as? Bool { p.unreadRing = r; notes.append(r ? "Pane ring" : "No pane ring") }
        for k in ["paneFlash", "command", "customSoundFilePath", "showInMenuBar"] where nj[k] != nil {
            notImported.append("Notification setting “\(k)”")
        }
        p.summary[.notifications] = notes

        // 4. Shortcuts (only the ones the user wrote in settings.json / cmux.json).
        var keys: [String] = []
        let bindings = ((json["shortcuts"] as? [String: Any])?["bindings"] as? [String: Any]) ?? [:]
        for (action, v) in bindings.sorted(by: { $0.key < $1.key }) {
            guard let s = v as? String else { continue }
            if let g = ghosttyActions[action], let trig = ghosttyTrigger(s) {
                p.keybinds.append("keybind = \(trig)=\(g)")
                keys.append("\(action): \(s)")
            } else if action == "selectWorkspaceByNumber", let trig = ghosttyTrigger(s), let last = trig.last, last.isNumber {
                let mods = trig.dropLast()
                for i in 1...8 { p.keybinds.append("keybind = \(mods)\(i)=goto_tab:\(i)") }
                keys.append("\(action): \(s)")
            } else if let id = lmuxActions[action], parseShortcut(s) != nil {
                p.lmuxShortcuts[id] = s
                keys.append("\(action): \(s)")
            } else {
                notImported.append("Shortcut “\(action)” (no lmux equivalent)")
            }
        }
        p.shortcutCount += keys.count
        let ghosttyKeybinds = p.keybinds.count - keys.count
        if !keys.isEmpty || ghosttyKeybinds > 0 {
            p.summary[.shortcuts] = keys.isEmpty ? ["\(p.keybinds.count) Ghostty keybinds"] : keys
        }

        // 5. Open workspaces (every cmux window's, in order; lmux has one window).
        let custom = ((jsonBlob(defaults["workspaceCustomizations.v2"]) as? [String: Any])?["entries"] as? [String: Any]) ?? [:]
        var claude = 0, codex = 0
        // What a workspace loses on the way (panes lmux has no kind for).
        var droppedPanes: [String: Int] = [:], otherAgents: [String: Int] = [:], emptyWorkspaces = 0
        var all: [(ws: [String: Any], selected: Bool)] = []
        for (n, win) in windows.enumerated() {
            let tm = win["tabManager"] as? [String: Any] ?? [:]
            let sel = (tm["selectedWorkspaceIndex"] as? NSNumber)?.intValue
            for (k, w) in (tm["workspaces"] as? [[String: Any]] ?? []).enumerated() { all.append((w, n == 0 && k == sel)) }
        }
        for (i, (w, wasSelected)) in all.enumerated() {
            let wid = (w["workspaceId"] as? String) ?? (w["stableId"] as? String) ?? UUID().uuidString
            let panels = Dictionary((w["panels"] as? [[String: Any]] ?? []).compactMap { p -> (String, [String: Any])? in
                (p["id"] as? String).map { ($0, p) }
            }, uniquingKeysWith: { a, _ in a })
            let cwd = w["currentDirectory"] as? String
            func pane(_ id: String?) -> LayoutFile.PaneState? {
                guard let id, let panel = panels[id], (panel["type"] as? String ?? "terminal") == "terminal" else { return nil }
                let term = panel["terminal"] as? [String: Any] ?? [:]
                let agent = term["agent"] as? [String: Any]
                if let kind = agent?["kind"] as? String, kind != "claude", kind != "codex" { otherAgents[kind, default: 0] += 1 }
                let dir = (panel["directory"] as? String) ?? (term["workingDirectory"] as? String) ?? cwd
                var session: String?, resume: String?, kind: String?, env: [String: String]?
                let sid = (agent?["sessionId"] as? String).flatMap { ClaudeCommand.isSessionID($0) ? $0 : nil }
                if agent?["kind"] as? String == "claude", let sid {
                    session = sid
                    let mode = (agent?["permissionMode"] as? String).flatMap { $0.allSatisfy { $0.isLetter } ? $0 : nil }
                    resume = "claude" + (mode.map { " --permission-mode \($0)" } ?? "") + " --resume \(sid)"
                    claude += 1
                } else if agent?["kind"] as? String == "codex", let sid {
                    // cmux records Codex panes the same way (kind "codex", the launch argv it captured).
                    let launch = agent?["launchCommand"] as? [String: Any]
                    session = sid
                    kind = AgentKind.codex.rawValue
                    resume = CodexCommand.resume(argv: launch?["arguments"] as? [String], sessionID: sid, environment: [:])
                    env = (launch?["environment"] as? [String: String])?.filter { HookClient.replayable($0.key) }
                    if env?.isEmpty == true { env = nil }
                    codex += 1
                }
                return LayoutFile.PaneState(id: "cmux-" + id, cwd: dir, title: panel["title"] as? String, claudeSession: session,
                                            agent: kind, resumeCommand: resume, resumeEnvironment: env, transcriptPath: nil,
                                            titleState: nil, titleSession: nil,
                                            pinned: panel["isPinned"] as? Bool == true ? true : nil)
            }
            func node(_ l: [String: Any]) -> LayoutFile.NodeState? {
                if let leaf = l["pane"] as? [String: Any] {
                    let ids = leaf["panelIds"] as? [String] ?? []
                    let sel = leaf["selectedPanelId"] as? String
                    let terminals = ids.filter { (panels[$0]?["type"] as? String ?? "terminal") == "terminal" && panels[$0] != nil }
                    for id in ids where panels[id] != nil && !terminals.contains(id) {
                        droppedPanes[(panels[id]?["type"] as? String) ?? "unknown", default: 0] += 1
                    }
                    // The pane's terminals come over as its tabs, the one that was showing in front.
                    let tabs = terminals.compactMap { id in pane(id).map { (id, $0) } }
                    guard !tabs.isEmpty else { return nil }
                    let shown = tabs.firstIndex { $0.0 == sel } ?? 0
                    if tabs.count == 1 { return LayoutFile.NodeState(pane: tabs[0].1) }
                    return LayoutFile.NodeState(pane: tabs[shown].1, tabs: tabs.map(\.1), selectedTab: shown)
                }
                let s = l["split"] as? [String: Any] ?? l
                let kids = [s["first"], s["second"]].compactMap { $0 as? [String: Any] } + ((s["children"] as? [[String: Any]]) ?? [])
                let built = kids.compactMap(node)
                if built.count == 1 { return built[0] }
                guard built.count >= 2 else { return nil }
                let o = ((s["orientation"] as? String) ?? (s["direction"] as? String) ?? (s["axis"] as? String) ?? "horizontal").lowercased()
                let axis: SplitAxis = o.hasPrefix("v") || o == "down" || o == "column" ? .vertical : .horizontal
                let ratio = (s["dividerPosition"] as? NSNumber ?? s["ratio"] as? NSNumber)?.doubleValue
                return LayoutFile.NodeState(pane: nil, axis: axis, ratio: ratio, children: Array(built.prefix(2)))
            }
            guard let layout = w["layout"] as? [String: Any], let root = node(layout) else { emptyWorkspaces += 1; continue }
            var title = (w["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var hex = w["customColor"] as? String
            for key in [wid, w["stableId"] as? String].compactMap({ $0 }) {
                guard let e = (custom[key] as? [String: Any])?["customization"] as? [String: Any] else { continue }
                if hex == nil, let v = ((e["customColor"] as? [String: Any])?["value"] as? [String: Any])?["_0"] as? String { hex = v }
                if title == nil, let v = ((e["customTitle"] as? [String: Any])?["value"] as? [String: Any])?["_0"] as? String, !v.isEmpty { title = v }
            }
            let accent = hex.flatMap(nearestAccent) ?? i % T.Colors.workspaceAccents.count
            func has(_ n: LayoutFile.NodeState, _ id: String) -> Bool {
                n.leafPanes.contains { $0.id == id } || (n.children ?? []).contains { has($0, id) }
            }
            let focused = (w["focusedPanelId"] as? String).map { "cmux-" + $0 }.flatMap { has(root, $0) ? $0 : nil }
            p.workspaces.append(LayoutFile.WorkspaceState(id: "cmux-" + wid, customTitle: title, accent: accent, focusedPane: focused, root: root))
            if wasSelected { p.selectedWorkspace = "cmux-" + wid }
        }
        let kindNames = ["browser": "browser", "markdown": "Markdown"]
        for (kind, n) in droppedPanes.sorted(by: { $0.key < $1.key }) {
            notImported.append("\(n) \(kindNames[kind] ?? kind) \(n == 1 ? "pane" : "panes") in open workspaces (the split closes up around \(n == 1 ? "it" : "them"))")
        }
        for (kind, n) in otherAgents.sorted(by: { $0.key < $1.key }) {
            notImported.append("\(n) \(kind) \(n == 1 ? "session" : "sessions") (opens as a shell in \(n == 1 ? "its" : "their") folder; lmux resumes Claude Code and Codex)")
        }
        if emptyWorkspaces > 0 { notImported.append("\(emptyWorkspaces) \(emptyWorkspaces == 1 ? "workspace" : "workspaces") with no terminal") }
        if !p.workspaces.isEmpty {
            p.summary[.workspaces] = ["\(p.workspaces.count) workspaces" + (claude > 0 ? ", \(claude) Claude Code \(claude == 1 ? "session resumes" : "sessions resume")" : "")
                                      + (codex > 0 ? ", \(codex) Codex \(codex == 1 ? "session resumes" : "sessions resume")" : "")]
        }

        // Customized cmux settings with no lmux equivalent.
        let mapped: Set<String> = ["app.appearance", "app.warnBeforeQuit", "sidebarAppearance.matchTerminalBackground",
                                   "notifications.sound", "notifications.dockBadge", "notifications.unreadPaneRing",
                                   "notifications.paneFlash", "notifications.command", "notifications.customSoundFilePath",
                                   "notifications.showInMenuBar"]
        for (section, v) in json where !["$schema", "schemaVersion", "shortcuts"].contains(section) {
            for k in (v as? [String: Any])?.keys.sorted() ?? [] where !mapped.contains("\(section).\(k)") {
                notImported.append("Setting “\(section).\(k)”")
            }
        }
        p.notImported = notImported
        return p
    }
}

// MARK: - Applying

extension LmuxController {
    static let cmuxBlock = "cmux import"

    /// First launch (not headless): cmux is on this Mac and was never offered.
    public func shouldOfferCmuxImport(_ src: CmuxSources = .current) -> Bool {
        // Leftover / broken cmux files with nothing lmux can take: no sheet with only a disabled Import.
        src.exists && !settings.cmuxOffered && settings.cmuxImportedAt == nil
            && CmuxImportPlan.Section.allCases.contains(where: CmuxImport.plan(src).has)
    }

    /// Show the import sheet on first launch when cmux is there; then `next` (the hooks offer).
    public func offerCmuxImportIfNeeded(then next: @escaping () -> Void) {
        guard !headless, shouldOfferCmuxImport() else { next(); return }
        presentWhenWindowIsUp { c in
            c.settings.cmuxOffered = true
            c.presentCmuxImport(firstLaunch: true, then: next)
        }
    }

    @objc func menuImportFromCmux(_ s: Any?) { presentCmuxImport() }
    @objc func menuUndoCmuxImport(_ s: Any?) { undoCmuxImport() }

    public func presentCmuxImport(firstLaunch: Bool = false, from src: CmuxSources = .current, then next: (() -> Void)? = nil) {
        let plan = CmuxImport.plan(src)
        let vm = CmuxImportModel(plan: plan, firstLaunch: firstLaunch || settings.cmuxImportedAt == nil)
        vm.cmuxRunning = CmuxImport.cmuxRunning() && plan.workspaces.contains { CmuxImport.withoutSessions($0.root) != $0.root }
        cmuxImportModel = vm
        vm.onImport = { [weak self, weak vm] in
            guard let self, let vm else { return }
            vm.result = self.importFromCmux(plan, sections: vm.enabledSections)
            vm.canUndo = self.cmuxUndo != nil
        }
        vm.onUndo = { [weak self, weak vm] in
            guard let self, let vm else { return }
            vm.result = self.undoCmuxImport()
            vm.canUndo = false
        }
        guard !headless else { return }
        let vc = NSHostingController(rootView: CmuxImportView(model: vm))
        vc.sizingOptions = .preferredContentSize
        let sheet = NSWindow(contentViewController: vc)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.backgroundColor = T.Colors.elevatedBackground.nsColor
        sheet.setAccessibilityLabel("Bring over your cmux setup")
        vm.onClose = { [weak self, weak sheet] in
            guard let self, let sheet else { return }
            self.window.endSheet(sheet)
        }
        let present = { [weak self] in
            guard let self else { return }
            self.window.beginSheet(sheet) { [weak self] _ in self?.focusCurrent(); next?() }
        }
        if let s = window.attachedSheet { window.endSheet(s) }
        present()
    }

    /// Apply the chosen sections; returns the one-line result. Safe to run again: the config block
    /// is replaced and workspaces already open (by cmux id) are skipped.
    @discardableResult
    public func importFromCmux(_ plan: CmuxImportPlan, sections: Set<CmuxImportPlan.Section>, date: Date = Date()) -> String {
        var undo = CmuxImportUndo(config: try? Data(contentsOf: LmuxConfig.configFile),
                                  configBlock: LmuxConfigFile().rawBlock(Self.cmuxBlock), settings: settings.snapshot,
                                  sidebarWidth: model.sidebarWidth, sidebarVisible: model.sidebarVisible,
                                  frame: headless ? importedWindowFrame : window.frame, selectedID: model.selectedID)
        var done: [String] = []
        var block: [String] = []
        if sections.contains(.look) { block += plan.configLines }
        if sections.contains(.shortcuts) { block += plan.keybinds }
        let day = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withFullDate])
        if !block.isEmpty {
            do {
                try LmuxConfigFile().setBlock(Self.cmuxBlock, header: ["Imported from cmux on \(day) (Import from cmux…). Importing again replaces this block."],
                                              lines: block)
            } catch { return "Couldn’t write \(abbreviateHome(LmuxConfig.configFile.path)): \(error.localizedDescription)" }
            reloadTerminalConfig()
        }
        if sections.contains(.look), plan.has(.look) { done.append("theme and fonts") }
        if sections.contains(.app), plan.has(.app) {
            if let a = plan.appearance { settings.appearance = a; applyAppearance() }
            if let w = plan.warnBeforeQuit { settings.warnBeforeQuit = w }
            if let f = plan.windowFrame {
                importedWindowFrame = f
                if !headless { window.setFrame(f, display: true) }
            }
            if let w = plan.sidebarWidth { model.sidebarWidth = w }
            if let v = plan.sidebarVisible, v != model.sidebarVisible { toggleSidebar() }
            if let m = plan.sidebarMatch { setSidebarMatchesTerminal(m) }
            if let t = plan.tabBarWithOneTab { setTabBarWithOneTab(t) }
            root.needsLayout = true
            done.append("app settings")
        }
        if sections.contains(.notifications), plan.has(.notifications) {
            if let s = plan.sound { setNotificationSound(s) }
            if let b = plan.dockBadge { settings.dockBadge = b; updateDockBadge() }
            if let r = plan.unreadRing { settings.unreadRing = r }
            done.append("notifications")
        }
        if sections.contains(.shortcuts), plan.has(.shortcuts) {
            settings.shortcuts = settings.shortcuts.merging(plan.lmuxShortcuts) { $1 }
            done.append("shortcuts")
        }
        if sections.contains(.shortcuts) || sections.contains(.look) { buildMainMenu() }
        var sessionsLeft = false
        if sections.contains(.workspaces) {
            let resume = !CmuxImport.cmuxRunning()
            let initial = model.workspaces.count == 1 ? model.workspaces.first.flatMap { isUntouchedFirst($0) ? $0 : nil } : nil
            let open = Set(model.workspaces.map(\.id))
            var opened = 0
            for w in plan.workspaces where !open.contains(w.id) {
                let state = resume ? w.root : CmuxImport.withoutSessions(w.root)
                if state != w.root { sessionsLeft = true }
                guard let root = buildNode(state) else { continue }
                let ws = Workspace(id: w.id, accent: w.accent, root: root)
                ws.customTitle = w.customTitle
                if let f = w.focusedPane, let p = ws.panes.first(where: { $0.id == f }) { ws.focusedPane = p }
                model.workspaces.append(ws)
                undo.workspaces.append((ws.id, ws.panes.map(\.id), ws.customTitle, ws.panes.map(\.claudeSessionID)))
                opened += 1
            }
            if opened > 0, let w = initial {
                undo.initial = (w.id, w.accent, w.panes.first?.cwd)
                closeWorkspace(w)
            }
            if opened > 0, let id = plan.selectedWorkspace, let ws = model.workspaces.first(where: { $0.id == id }) { select(ws) }
            if opened > 0 { done.append("\(opened) \(opened == 1 ? "workspace" : "workspaces")") }
            scheduleSave()
        }
        settings.cmuxImportedAt = date
        undo.configAfter = try? Data(contentsOf: LmuxConfig.configFile)
        undo.settingsAfter = settings.snapshot
        undo.sidebarWidthAfter = model.sidebarWidth
        undo.sidebarVisibleAfter = model.sidebarVisible
        undo.frameAfter = headless ? importedWindowFrame : window.frame
        if !done.isEmpty { cmuxUndo = undo }
        buildMainMenu()
        refreshPaneChrome()
        settingsModel?.reload()
        return done.isEmpty ? "Nothing new to bring over."
            : "Brought over " + listJoined(done) + (sessionsLeft ? " (without their Claude / Codex sessions: cmux is running)." : ".")
    }

    /// Put back what the last import changed and nothing else: lmux's config file (its bytes from
    /// before when untouched since, else just the import's block), the settings it changed that still
    /// have the imported value, sidebar and window unless changed since; close the workspaces it
    /// opened unless they were used since (typed in, split, closed pane, renamed, another session or
    /// program): those stay. Returns the one-line result.
    @discardableResult
    public func undoCmuxImport() -> String {
        guard let u = cmuxUndo else { return "Nothing to undo." }
        cmuxUndo = nil
        let url = LmuxConfig.configFile
        if (try? Data(contentsOf: url)) == u.configAfter {
            if let data = u.config {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            try? LmuxConfigFile().replaceBlock(Self.cmuxBlock, with: u.configBlock)  // edited since: only the import's block
        }
        reloadTerminalConfig()
        settings.revert(from: u.settingsAfter, to: u.settings)
        applyAppearance()
        notifier.sound = settings.notificationSound
        updateDockBadge()
        if model.sidebarWidth == u.sidebarWidthAfter { model.sidebarWidth = u.sidebarWidth }
        if model.sidebarVisible == u.sidebarVisibleAfter, u.sidebarVisible != model.sidebarVisible { toggleSidebar() }
        if (headless ? importedWindowFrame : window.frame) == u.frameAfter {
            importedWindowFrame = nil
            if !headless, let f = u.frame { window.setFrame(f, display: true) }
        }
        if let i = u.initial, !model.workspaces.contains(where: { $0.id == i.id }) {
            let pane = makePane(cwd: i.cwd)
            pane.startedPlain = true
            pane.surface.setOcclusion(visible: false)
            model.workspaces.insert(Workspace(id: i.id, accent: i.accent, root: SplitNode(pane: pane)), at: 0)
        }
        var untouched: [Workspace] = [], kept = 0
        for w in u.workspaces {
            guard let ws = model.workspaces.first(where: { $0.id == w.id }) else { continue }
            // Untouched: as it came, never typed in, the same agent session, and nothing but its shell
            // (the pane's first process, or an idle shell) or the agent the import resumed in the foreground.
            func onlyItsOwn(_ p: Pane) -> Bool {
                let fg = p.surface.foregroundPID
                return p.runsClaude || runningProcess(p) == nil || (fg > 0 && getsid(fg) == fg)
            }
            let same = ws.panes.map(\.id) == w.panes && ws.customTitle == w.title && ws.panes.map(\.claudeSessionID) == w.sessions
                && ws.panes.allSatisfy { !$0.surface.hadUserInput && onlyItsOwn($0) }
            if same { untouched.append(ws) } else { kept += 1 }
        }
        if let id = u.selectedID, let ws = model.workspaces.first(where: { $0.id == id }) { select(ws) }
        closeWorkspaces(untouched)
        buildMainMenu()
        root.needsLayout = true
        refreshPaneChrome()
        settingsModel?.reload()
        scheduleSave()
        return "Undid the import." + (kept > 0 ? " Kept \(kept) \(kept == 1 ? "workspace" : "workspaces") you used." : "")
    }

    /// The shell lmux opened at launch, as it came: one pane, never typed in, not renamed, no Claude.
    func isUntouchedFirst(_ ws: Workspace) -> Bool {
        guard !ws.id.hasPrefix("cmux-"), ws.customTitle == nil, ws.panes.count == 1, let p = ws.panes.first else { return false }
        return p.startedPlain && !p.surface.hadUserInput && p.claudeSessionID == nil
    }

    func listJoined(_ a: [String]) -> String {
        a.count <= 1 ? a.joined() : a.dropLast().joined(separator: ", ") + " and " + a.last!
    }
}

// MARK: - The sheet

@MainActor @Observable
public final class CmuxImportModel {
    public let plan: CmuxImportPlan
    public var enabled: [CmuxImportPlan.Section: Bool] = [:]
    /// "Choose what to import…": the per-section checkboxes.
    public var choosing = false
    public var showNotImported = false
    public var result: String?
    /// The import changed something and it is not undone yet.
    public var canUndo = false
    /// cmux is running and the workspaces have agent sessions: they come over as plain shells.
    public var cmuxRunning = false
    @ObservationIgnored var onImport: (() -> Void)?
    @ObservationIgnored var onUndo: (() -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?

    init(plan: CmuxImportPlan, firstLaunch: Bool) {
        self.plan = plan
        for s in CmuxImportPlan.Section.allCases where plan.has(s) {
            enabled[s] = s == .workspaces ? firstLaunch : true
        }
    }

    var enabledSections: Set<CmuxImportPlan.Section> { Set(enabled.filter(\.value).map(\.key)) }
}

/// One primary button brings everything over (Return); "Choose what to import…" reveals the
/// sections. After: what came over, one line of what lmux doesn't have, Undo Import until closed.
struct CmuxImportView: View {
    @Bindable var model: CmuxImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let r = model.result { done(r) } else { offer }
        }
        .padding(22)
        .frame(width: 440)
        .background(T.Colors.elevatedBackground.color)
    }

    private var offer: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Text("Bring over your cmux setup")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(T.Colors.textPrimary.color)
                Text("lmux found cmux on this Mac: \(model.plan.headline.prefix(1).lowercased() + model.plan.headline.dropFirst()). cmux itself isn’t changed.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(T.Colors.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.choosing { sections }
            if model.cmuxRunning, model.enabled[.workspaces] == true {
                Label("Quit cmux first to bring sessions over (or import without sessions).", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(T.Colors.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { model.onImport?() } label: {
                Text("Bring over my cmux setup").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(model.enabledSections.isEmpty)
            HStack {
                if !model.choosing {
                    Button("Choose what to import…") { model.choosing = true }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                Spacer()
                Button("Not Now") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CmuxImportPlan.Section.allCases.filter { model.plan.has($0) }) { s in
                Toggle(isOn: Binding(get: { model.enabled[s] ?? false }, set: { model.enabled[s] = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s == .workspaces ? "Open my cmux workspaces" : s.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(T.Colors.textPrimary.color)
                        Text((model.plan.summary[s] ?? []).joined(separator: " · "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(T.Colors.textSecondary.color)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.Colors.rowHover.color))
    }

    private func done(_ r: String) -> some View {
        Group {
            Label(r, systemImage: model.canUndo ? "checkmark.circle.fill" : "arrow.uturn.backward.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(T.Colors.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
            if model.canUndo, let line = model.plan.notImportedLine {
                DisclosureGroup(isExpanded: $model.showNotImported) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.plan.notImported, id: \.self) { Text("· " + $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                } label: {
                    Text("lmux doesn’t have: \(line)")
                        .lineLimit(2)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(T.Colors.textSecondary.color)
            }
            HStack {
                if model.canUndo { Button("Undo Import") { model.onUndo?() } }
                Spacer()
                Button("Done") { model.onClose?() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The sheet's one big button: lmux's accent, filled (prominent even when the window isn't key).
private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(T.DynamicColor(light: 0xFFFFFF, dark: T.Nord.nord0).color)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.Colors.accent.color))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}
