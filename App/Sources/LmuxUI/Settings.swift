import AppKit
import LmuxTerminal

/// lmux's own app settings (not terminal keys, those live in `~/.config/lmux/config`), in
/// `<state dir>/settings.plist` (so headless runs with a temp state dir never touch the real ones).
@MainActor
public final class LmuxSettings {
    public enum Appearance: String, CaseIterable { case system, light, dark }

    let url: URL
    private var values: [String: Any]

    init(url: URL) {
        self.url = url
        let data = try? Data(contentsOf: url)
        values = data.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        } ?? [:]
        // Unreadable: kept aside (like layout.json) before the next change writes defaults over it.
        if let data, !data.isEmpty, values.isEmpty {
            let bad = url.path + ".bad-\(Int(Date().timeIntervalSince1970))"
            if FileManager.default.createFile(atPath: bad, contents: data, attributes: [.posixPermissions: 0o600]) {
                NSLog("lmux: settings.plist could not be read; kept as %@", (bad as NSString).lastPathComponent)
            }
        }
    }

    private func get(_ key: String) -> Any? { values[key] }
    private func put(_ key: String, _ value: Any?) {
        values[key] = value
        save()
    }
    private func save() {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Every value as it is now (Undo Import).
    var snapshot: [String: Any] { values }
    /// Undo Import: put back `before`'s value of each key the import changed (`before` -> `after`),
    /// only where it still has the imported value (a later change stays).
    func revert(from after: [String: Any], to before: [String: Any]) {
        func same(_ a: Any?, _ b: Any?) -> Bool {
            switch (a, b) {
            case (nil, nil): return true
            case let (a?, b?): return (a as AnyObject).isEqual(b)
            default: return false
            }
        }
        for key in Set(after.keys).union(before.keys) where !same(after[key], before[key]) && same(values[key], after[key]) {
            values[key] = before[key]
        }
        save()
    }

    public var appearance: Appearance {
        get { (get("appearance") as? String).flatMap(Appearance.init) ?? .system }
        set { put("appearance", newValue.rawValue) }
    }
    /// The sidebar takes the terminal's background instead of the translucent Nord surface.
    public var sidebarMatchesTerminal: Bool {
        get { get("sidebarMatchesTerminal") as? Bool ?? false }
        set { put("sidebarMatchesTerminal", newValue) }
    }
    /// Ask before quitting while something runs (Ghostty's confirm). Default on.
    public var warnBeforeQuit: Bool {
        get { get("warnBeforeQuit") as? Bool ?? true }
        set { put("warnBeforeQuit", newValue) }
    }
    /// Plain shell panes show their last output again after a relaunch (saved at quit, privately). Default on.
    public var restoreScrollback: Bool {
        get { get("restoreScrollback") as? Bool ?? true }
        set { put("restoreScrollback", newValue) }
    }
    /// System notification sound: nil = none (lmux's default), "default", or a sound name.
    public var notificationSound: String? {
        get { get("notificationSound") as? String }
        set { put("notificationSound", newValue) }
    }
    /// Every pane shows its tab bar, one tab or more (cmux's default); off: only with two or more tabs.
    public var tabBarWithOneTab: Bool {
        get { get("tabBarWithOneTab") as? Bool ?? true }
        set { put("tabBarWithOneTab", newValue) }
    }
    /// Unread count on the Dock icon. Default off.
    public var dockBadge: Bool {
        get { get("dockBadge") as? Bool ?? false }
        set { put("dockBadge", newValue) }
    }
    /// The ring around a pane with an unread alert. Default on.
    public var unreadRing: Bool {
        get { get("unreadRing") as? Bool ?? true }
        set { put("unreadRing", newValue) }
    }
    /// Remind (the row's glyph breathes) after a done / needs-input row goes unattended this
    /// many minutes; 0 = off. Default 3 (a saved value is kept).
    public var remindAfterMinutes: Int {
        get { get("remindAfterMinutes") as? Int ?? 3 }
        set { put("remindAfterMinutes", newValue) }
    }
    /// Also post a notification when a row starts breathing. Default off.
    public var remindNotification: Bool {
        get { get("remindNotification") as? Bool ?? false }
        set { put("remindNotification", newValue) }
    }
    /// lmux-only shortcuts the user changed: action id -> "cmd+shift+u".
    public var shortcuts: [String: String] {
        get { get("shortcuts") as? [String: String] ?? [:] }
        set { put("shortcuts", newValue) }
    }
    /// When the cmux import ran (nil: never), and whether the first-launch offer was made.
    public var cmuxImportedAt: Date? {
        get { get("cmuxImportedAt") as? Date }
        set { put("cmuxImportedAt", newValue) }
    }
    public var cmuxOffered: Bool {
        get { get("cmuxOffered") as? Bool ?? false }
        set { put("cmuxOffered", newValue) }
    }
}

/// "cmd+shift+u" -> (key equivalent, modifiers) for an NSMenuItem.
func parseShortcut(_ s: String) -> (String, NSEvent.ModifierFlags)? {
    var mods: NSEvent.ModifierFlags = []
    var key: String?
    for part in s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
        switch part {
        case "cmd", "command", "super": mods.insert(.command)
        case "shift": mods.insert(.shift)
        case "opt", "option", "alt": mods.insert(.option)
        case "ctrl", "control": mods.insert(.control)
        case "": key = "+"
        default: key = part
        }
    }
    guard var k = key else { return nil }
    let named: [String: Int] = ["←": NSLeftArrowFunctionKey, "→": NSRightArrowFunctionKey, "↑": NSUpArrowFunctionKey,
                                "↓": NSDownArrowFunctionKey, "left": NSLeftArrowFunctionKey, "right": NSRightArrowFunctionKey,
                                "up": NSUpArrowFunctionKey, "down": NSDownArrowFunctionKey]
    if let f = named[k], let u = UnicodeScalar(f) { k = String(Character(u)) }
    if k == "\r" || k == "enter" || k == "return" { k = "\r" }
    guard k.count == 1 else { return nil }
    return (k, mods)
}
