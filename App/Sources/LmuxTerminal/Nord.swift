// Nord color palette by Arctic Ice Studio & Sven Greb (MIT), https://www.nordtheme.com
// Exposed so app chrome (sidebar etc.) can match the default terminal theme.

import AppKit

public enum Nord {
    // Polar Night
    public static let nord0 = NSColor(hex: 0x2E3440)
    public static let nord1 = NSColor(hex: 0x3B4252)
    public static let nord2 = NSColor(hex: 0x434C5E)
    public static let nord3 = NSColor(hex: 0x4C566A)
    // Snow Storm
    public static let nord4 = NSColor(hex: 0xD8DEE9)
    public static let nord5 = NSColor(hex: 0xE5E9F0)
    public static let nord6 = NSColor(hex: 0xECEFF4)
    // Frost
    public static let nord7 = NSColor(hex: 0x8FBCBB)
    public static let nord8 = NSColor(hex: 0x88C0D0)
    public static let nord9 = NSColor(hex: 0x81A1C1)
    public static let nord10 = NSColor(hex: 0x5E81AC)
    // Aurora
    public static let nord11 = NSColor(hex: 0xBF616A)
    public static let nord12 = NSColor(hex: 0xD08770)
    public static let nord13 = NSColor(hex: 0xEBCB8B)
    public static let nord14 = NSColor(hex: 0xA3BE8C)
    public static let nord15 = NSColor(hex: 0xB48EAD)

    /// Terminal backgrounds of the bundled "Nord" / "Nord Light" Ghostty themes.
    public static let darkBackground = nord0
    public static let lightBackground = nord5
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
