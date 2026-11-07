// lmux design tokens. Single source of truth for chrome colors, type, spacing and motion.
// Documented in design/TOKENS.md. No dependencies; compiles standalone:
//   swiftc -typecheck design/Tokens.swift
// Lives in the app's LmuxTokens module (App/Sources/LmuxTokens); design/Tokens.swift is a symlink.
//
// Nord palette by Arctic Ice Studio & Sven Greb (MIT), https://www.nordtheme.com
// Values marked "derived" are Nord hues darkened/lightened to pass WCAG AA on lmux surfaces.

import AppKit
import SwiftUI

public enum LmuxTokens {

    // MARK: - Raw palette

    /// The 16 Nord colors, as 0xRRGGBB.
    public enum Nord {
        public static let nord0: UInt32 = 0x2E3440  // Polar Night
        public static let nord1: UInt32 = 0x3B4252
        public static let nord2: UInt32 = 0x434C5E
        public static let nord3: UInt32 = 0x4C566A
        public static let nord4: UInt32 = 0xD8DEE9  // Snow Storm
        public static let nord5: UInt32 = 0xE5E9F0
        public static let nord6: UInt32 = 0xECEFF4
        public static let nord7: UInt32 = 0x8FBCBB  // Frost
        public static let nord8: UInt32 = 0x88C0D0
        public static let nord9: UInt32 = 0x81A1C1
        public static let nord10: UInt32 = 0x5E81AC
        public static let nord11: UInt32 = 0xBF616A  // Aurora
        public static let nord12: UInt32 = 0xD08770
        public static let nord13: UInt32 = 0xEBCB8B
        public static let nord14: UInt32 = 0xA3BE8C
        public static let nord15: UInt32 = 0xB48EAD
    }

    // MARK: - Dynamic color

    /// A light/dark pair. Use `.nsColor` in AppKit and `.color` in SwiftUI;
    /// both resolve against the view's effective appearance at draw time.
    public struct DynamicColor: Sendable {
        public let light: UInt32
        public let dark: UInt32
        public let lightAlpha: CGFloat
        public let darkAlpha: CGFloat

        public init(light: UInt32, dark: UInt32, alpha: CGFloat = 1) {
            self.init(light: light, dark: dark, lightAlpha: alpha, darkAlpha: alpha)
        }

        public init(light: UInt32, dark: UInt32, lightAlpha: CGFloat, darkAlpha: CGFloat) {
            self.light = light
            self.dark = dark
            self.lightAlpha = lightAlpha
            self.darkAlpha = darkAlpha
        }

        public init(_ both: UInt32, alpha: CGFloat = 1) {
            self.init(light: both, dark: both, alpha: alpha)
        }

        public var nsColor: NSColor {
            let c = self
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark ? LmuxTokens.srgb(c.dark, alpha: c.darkAlpha) : LmuxTokens.srgb(c.light, alpha: c.lightAlpha)
            }
        }

        public var color: Color { Color(nsColor: nsColor) }

        /// Resolved for one appearance (for layers, which don't resolve dynamic colors).
        public func cgColor(dark isDark: Bool) -> CGColor {
            (isDark ? LmuxTokens.srgb(dark, alpha: darkAlpha) : LmuxTokens.srgb(light, alpha: lightAlpha)).cgColor
        }

        public func opacity(_ alpha: CGFloat) -> DynamicColor {
            DynamicColor(light: light, dark: dark, alpha: alpha)
        }
    }

    static func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    /// The appearance whose text tokens read on `background`, for chrome drawn on the terminal's
    /// background (content header, input legend, a sidebar that matches the terminal): a dark theme
    /// under a light macOS, or the other way round, left textTertiary at 1.7-2.9:1. Picks the side
    /// where textTertiary has more contrast (5.1:1 or more on every bundled theme).
    public static func appearance(on background: NSColor) -> NSAppearance {
        guard let c = background.usingColorSpace(.sRGB) else { return NSAppearance(named: .aqua)! }
        func lum(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        func lum(_ hex: UInt32) -> CGFloat {
            lum(CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        func ratio(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        let bg = lum(c.redComponent, c.greenComponent, c.blueComponent)
        let dark = ratio(lum(Colors.textTertiary.dark), bg) > ratio(lum(Colors.textTertiary.light), bg)
        return NSAppearance(named: dark ? .darkAqua : .aqua)!
    }

    // MARK: - Semantic colors

    public enum Colors {
        // Surfaces
        /// Terminal + titlebar over the content column. Matches the Ghostty "Nord Light" / "Nord" backgrounds.
        public static let windowBackground = DynamicColor(light: Nord.nord5, dark: Nord.nord0)
        /// Sidebar + titlebar over the sidebar column. Light: paper (nord6). Dark: one step below nord0 (derived).
        /// Polish: now the OPAQUE fallback only (Reduce Transparency, inactive-window snapshots, tests).
        public static let sidebarBackground = DynamicColor(light: Nord.nord6, dark: 0x292E39)
        /// Polish: drawn over an NSVisualEffectView (.sidebar, .behindWindow, state .followsWindowActiveState)
        /// that spans the full sidebar height including the titlebar. Keeps the sidebar Nord while
        /// letting the desktop through a little. Raise alpha (max 0.92) if textTertiary measures < 4.5:1.
        public static let sidebarTint = DynamicColor(light: Nord.nord6, dark: 0x292E39, lightAlpha: 0.80, darkAlpha: 0.84)
        /// Toasts, the History search field. Light: derived, a hair above nord6.
        public static let elevatedBackground = DynamicColor(light: 0xF5F7FA, dark: Nord.nord1)
        /// Hairlines: sidebar edge, pane split, content header bottom, History panel top.
        /// Polish: translucent so it reads the same on the material and on the terminal; dark uses a
        /// darker (not lighter) line, which reads as an edge instead of a highlight.
        public static let separator = DynamicColor(light: Nord.nord0, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.32)
        /// Field and popover outlines. Polish: hairline-weight, used at 0.5–1px only.
        public static let border = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.14, darkAlpha: 0.10)

        // Sidebar rows
        /// Polish: hover and selection are neutral tints of the text color (Linear/Finder style).
        /// Text never changes color on selection, so every text token keeps its contrast.
        public static let rowHover = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.045, darkAlpha: 0.05)
        /// Selected workspace: a soft neutral pill, not a solid frost block.
        public static let rowSelected = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.075, darkAlpha: 0.085)
        /// Selected row while the window is not key.
        public static let rowSelectedInactive = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.05, darkAlpha: 0.055)
        /// The other rows of a multi-selection (⌘-click / ⇧-click): a step lighter than the active
        /// workspace's pill (`rowSelected`), so the one on screen stays clear (Finder's list convention).
        public static let rowSelectedSecondary = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.05, darkAlpha: 0.055)
        /// …while the window is not key (still under `rowSelectedInactive`).
        public static let rowSelectedSecondaryInactive = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.035, darkAlpha: 0.04)
        /// Deprecated by the polish pass (selection no longer changes text): aliases kept so call sites compile.
        public static let rowSelectedText = textPrimary
        public static let rowSelectedSecondaryText = textSecondary
        public static let rowSelectedNeedsInput = stateNeedsInput

        // Text (AA on sidebar, window and elevated backgrounds unless noted)
        public static let textPrimary = DynamicColor(light: Nord.nord0, dark: Nord.nord6)      // 10.8 / 11.8
        public static let textSecondary = DynamicColor(light: Nord.nord2, dark: 0xC4CBD7)      // 7.5 / 8.3
        /// Polish: nudged so it stays AA on the selected pill and on the translucent sidebar
        /// (light 4.9 worst-case material, 5.1 on the pill; dark 4.7 / 4.9, and 4.6 on elevated).
        public static let textTertiary = DynamicColor(light: 0x535D72, dark: 0xA7B0BF)
        /// Terminal foreground (Ghostty theme values), for chrome that imitates terminal text.
        public static let terminalForeground = DynamicColor(light: 0x414858, dark: Nord.nord4)

        // Accent (buttons, focus, links)
        /// Light: a step darker than #4C6E99 so "Resume" stays AA on a selected History row (4.9, was 4.3)
        /// and on the selected sidebar pill (4.6, was 4.0).
        public static let accent = DynamicColor(light: 0x46658E, dark: Nord.nord8)              // derived nord10 / nord8
        public static let onAccent = DynamicColor(light: Nord.nord6, dark: Nord.nord0)          // 5.2 / 6.2
        /// Unattended reminder: the soft halo that breathes behind the row's indicator (at its peak; 0 between).
        public static let attentionHalo = DynamicColor(light: 0x4C6E99, dark: Nord.nord8, lightAlpha: 0.30, darkAlpha: 0.34)

        // Agent state. Only "needs input" is loud; running is deliberately neutral.
        public static let stateRunning = textTertiary
        /// Polish: light darkened from #3F6C93 so the label stays AA on the selected pill (4.7 worst case).
        public static let stateNeedsInput = DynamicColor(light: 0x37628A, dark: Nord.nord8)
        public static let stateDone = DynamicColor(light: 0x5A7F43, dark: Nord.nord14)          // glyph >= 3:1
        public static let stateFailed = DynamicColor(light: 0xA9444E, dark: 0xD57780)           // glyph >= 3:1

        // Notifications
        /// Pane ring when an unfocused pane needs input. >= 3:1 against the terminal background.
        public static let notificationRing = DynamicColor(light: Nord.nord10, dark: Nord.nord8)
        public static let badgeBackground = stateNeedsInput
        public static let badgeText = onAccent
        /// Deprecated by the polish pass: the neutral pill no longer needs an inverted badge.
        public static let badgeOnSelectedBackground = badgeBackground
        public static let badgeOnSelectedText = badgeText

        // Terminal-adjacent chrome (polish)
        /// What Claude Code's prompt row should look like once OSC 11 answers with the real bg:
        /// the terminal bg moved ~4% toward the fg. Reference only; Claude Code paints it.
        public static let promptRowReference = DynamicColor(light: 0xDCE1E9, dark: 0x353B48)
        /// Hover tint lmux draws behind a hovered prompt row (connects text and the action pill).
        public static let promptRowHover = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.04, darkAlpha: 0.04)
        /// Icon-button hover fill (titlebar, hover actions).
        public static let controlHover = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.06, darkAlpha: 0.07)

        // Traffic-light-safe titlebar icons
        public static let titlebarIcon = textTertiary
        public static let titlebarIconHover = textPrimary
        /// Focus ring of the History search field: accent at 38%, 2.5pt outside a 1px border.
        public static let focusRing = DynamicColor(light: 0x4C6E99, dark: Nord.nord8, lightAlpha: 0.38, darkAlpha: 0.38)

        /// Per-workspace accent (R7, wrong-session guard). Assigned round-robin on creation,
        /// skipping colors already in use. nord8 is excluded (it's the selection + ring color).
        /// Every entry is >= 3:1 against `sidebarBackground`, `windowBackground`, `elevatedBackground` and the
        /// selected / hovered row pills.
        public static let workspaceAccents: [DynamicColor] = [
            DynamicColor(light: 0x3F8584, dark: Nord.nord7),   // teal
            DynamicColor(light: 0xB8673F, dark: Nord.nord12),  // orange
            DynamicColor(light: 0x8E5F87, dark: Nord.nord15),  // purple
            DynamicColor(light: 0x5A7F43, dark: Nord.nord14),  // green
            DynamicColor(light: 0xB1505A, dark: 0xD27580),     // red (dark: nord11 lightened, 3:1 on the selected pill)
            DynamicColor(light: 0x4A6E9C, dark: Nord.nord9),   // blue
            DynamicColor(light: 0x9C7A1E, dark: Nord.nord13),  // yellow
            DynamicColor(light: 0x5B657A, dark: Nord.nord4),   // slate
        ]
        public static let workspaceAccentNames = ["teal", "orange", "purple", "green", "red", "blue", "yellow", "slate"]
    }

    // MARK: - Typography

    public enum Typography {
        public struct Style: Sendable {
            public let size: CGFloat
            public let weight: NSFont.Weight
            public let lineHeight: CGFloat

            public var nsFont: NSFont { .systemFont(ofSize: size, weight: weight) }
            public var font: Font { .system(size: size, weight: Font.Weight(weight)) }
        }

        /// Titlebar workspace title.
        public static let windowTitle = Style(size: 13, weight: .semibold, lineHeight: 16)
        /// Sidebar row line 1. Polish: medium, not semibold (selection is the pill, not the weight).
        public static let rowTitle = Style(size: 13, weight: .medium, lineHeight: 16)
        /// Sidebar row line 2 (agent state / latest notification).
        public static let rowSubtitle = Style(size: 12, weight: .regular, lineHeight: 15)
        /// Sidebar row line 3 (`branch • ~/cwd`), History timestamps.
        public static let rowMeta = Style(size: 11, weight: .regular, lineHeight: 14)
        /// "History" panel header (only while searching).
        public static let sectionHeader = Style(size: 11, weight: .semibold, lineHeight: 14)
        /// History result title / snippet (polish).
        public static let historyTitle = Style(size: 12.5, weight: .medium, lineHeight: 16)
        public static let historySnippet = Style(size: 11.5, weight: .regular, lineHeight: 15)
        /// History footer placeholder and the search text.
        public static let field = Style(size: 12, weight: .regular, lineHeight: 15)
        /// Workspace legend on Claude's input rule (R7), polish: tertiary text, accent chip only.
        public static let inputLegend = Style(size: 10.5, weight: .medium, lineHeight: 13)
        /// Onboarding sheet.
        public static let sheetTitle = Style(size: 15, weight: .semibold, lineHeight: 20)
        public static let sheetBody = Style(size: 12.5, weight: .regular, lineHeight: 18)
        /// Pane header (only when split).
        public static let paneTitle = Style(size: 11, weight: .medium, lineHeight: 14)
        /// Toast, tooltips.
        public static let body = Style(size: 12, weight: .regular, lineHeight: 16)
        public static let bodyEmphasis = Style(size: 12, weight: .semibold, lineHeight: 16)
        /// Unread badge digits (monospaced digits recommended).
        public static let badge = Style(size: 10, weight: .bold, lineHeight: 12)

        /// Terminal fonts. Ghostty config always wins; these are first-launch defaults (R4).
        public static let terminalFontKorean = "D2Coding"
        public static let terminalFontDefault = "JetBrains Mono"
        /// Hangul fallback, always 2 cells.
        public static let terminalHangulFallback = "D2Coding"
        public static let terminalFontSize: CGFloat = 13
    }

    // MARK: - Spacing (4pt grid, plus 2 and 6 for optical tweaks)

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 6
        public static let m: CGFloat = 8
        public static let l: CGFloat = 12
        public static let xl: CGFloat = 16
        public static let xxl: CGFloat = 24
        public static let xxxl: CGFloat = 32
    }

    // MARK: - Radii

    public enum Radius {
        public static let badge: CGFloat = 999      // capsule
        public static let accentBar: CGFloat = 1.5
        public static let control: CGFloat = 6      // icon buttons, hover action buttons
        public static let row: CGFloat = 8          // sidebar row pill, History rows
        public static let field: CGFloat = 8        // History footer / search field
        public static let pane: CGFloat = 8         // ring corner (inner panes are square; ring is drawn inset)
        public static let accentChip: CGFloat = 2.5 // workspace color chip (8x8)
        public static let actionPill: CGFloat = 8   // hover action pill
        public static let toast: CGFloat = 10
        public static let popover: CGFloat = 10
        public static let sheet: CGFloat = 14
        public static let button: CGFloat = 7       // sheet buttons
    }

    // MARK: - Layout

    public enum Layout {
        /// Polish: 40 so the strip's midline (20) matches the traffic lights' center on macOS 26.
        /// Still center the cluster on the close button's measured midY at runtime (see POLISH.md 1).
        public static let titlebarHeight: CGFloat = 40
        /// Traffic lights occupy x 0..<trafficLightsInset; never place content there (full screen hides
        /// them until the pointer reveals the titlebar: the titlebar buttons use that space meanwhile).
        public static let trafficLightsInset: CGFloat = 78

        public static let sidebarWidthDefault: CGFloat = 248
        public static let sidebarWidthMin: CGFloat = 180
        public static let sidebarWidthMax: CGFloat = 360

        /// Horizontal inset of the row pill from the sidebar edges.
        public static let rowInsetX: CGFloat = 8
        /// Padding inside the row pill.
        public static let rowPaddingX: CGFloat = 8
        public static let rowPaddingY: CGFloat = 9
        /// Polish: rows are 1 or 2 lines. 9 + 16 + 9 = 34; 9 + 16 + 3 + 15 + 9 = 52.
        public static let workspaceRowHeightSingle: CGFloat = 34
        public static let workspaceRowHeightDouble: CGFloat = 52
        /// Between a row's title and its detail line.
        public static let rowLineGap: CGFloat = 3
        /// Deprecated (3-line row). Kept so old call sites compile; use the two above.
        public static let workspaceRowHeight: CGFloat = workspaceRowHeightDouble
        /// Gap between workspace rows, so adjacent pills (selected + hover) never touch.
        public static let rowGap: CGFloat = 4
        /// The hover × in a row's trailing slot: hit target (the glyph is 9pt).
        public static let rowCloseButtonSize: CGFloat = 20
        /// Leading workspace chip (R7) and the gap to the title. Line 2 indents to the title.
        public static let accentChipSize: CGFloat = 8
        public static let accentChipGap: CGFloat = 8
        /// History result row (title + snippet) and the footer field.
        public static let historyRowHeight: CGFloat = 44
        public static let historySearchHeight: CGFloat = 28
        /// Rows the History panel shows before it scrolls, and how many results it lists at most.
        public static let historyVisibleRows: Int = 6
        public static let historyMaxResults: Int = 200

        /// Deprecated: the gutter bar is replaced by the leading chip.
        public static let accentBarWidth: CGFloat = 3
        public static let accentBarX: CGFloat = 3
        public static let accentBarInsetY: CGFloat = 10

        public static let paneHeaderHeight: CGFloat = 24
        public static let paneHeaderPaddingX: CGFloat = 14
        public static let contentHeaderPaddingX: CGFloat = 16
        public static let splitDividerWidth: CGFloat = 1
        public static let ringWidth: CGFloat = 1.5
        public static let ringInset: CGFloat = 3

        public static let badgeHeight: CGFloat = 16
        public static let badgeMinWidth: CGFloat = 16
        public static let titlebarIconSize: CGFloat = 16
        public static let titlebarButtonSize: CGFloat = 26
        public static let hoverActionSize: CGFloat = 22
        /// Hover pill: 2 buttons 22x20 + 2pt padding = 50x24, placed this far after the prompt's last glyph.
        public static let hoverActionGap: CGFloat = 12
        /// The hovered turn's action pill: inset from the pane's right edge.
        public static let turnActionInset: CGFloat = 10
        public static let sheetWidth: CGFloat = 460
    }

    // MARK: - Motion (minimal: ring fade, spinner, toast, hover)

    public enum Motion {
        public static let hover: TimeInterval = 0.08
        public static let ringIn: TimeInterval = 0.18
        public static let ringOut: TimeInterval = 0.30
        public static let toastIn: TimeInterval = 0.16
        public static let toastOut: TimeInterval = 0.20
        public static let spinnerPeriod: TimeInterval = 1.0
        /// Selection pill moves/fades between rows; History panel grows up from the footer.
        public static let selection: TimeInterval = 0.12
        public static let historyExpand: TimeInterval = 0.16
        /// One breath of an unattended row (bright -> dim -> bright).
        public static let attentionBreath: TimeInterval = 1.6

        /// R7 timings.
        public static let undoSendWindow: TimeInterval = 3.0

        public static var standard: Animation { .easeOut(duration: ringIn) }
        public static var ringFadeIn: Animation { .easeOut(duration: ringIn) }
        public static var ringFadeOut: Animation { .easeIn(duration: ringOut) }
        public static var toast: Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: toastIn) }
        /// Sidebar drag-to-reorder: rows sliding out of the way, the dropped row settling, Esc's spring back.
        public static var reorder: Animation { .spring(response: 0.26, dampingFraction: 0.86) }

        public static var easeOutTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1) }
        /// Respect "Reduce motion": swap fades for instant changes and stop the spinner.
        @MainActor public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }
}

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight {
        case .ultraLight: self = .ultraLight
        case .thin: self = .thin
        case .light: self = .light
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        case .heavy: self = .heavy
        case .black: self = .black
        default: self = .regular
        }
    }
}
