import AppKit
import IOSurface
import LmuxTerminal
import LmuxTokens

private typealias T = LmuxTokens

// In-pane overlays (AppKit, SF font, never in the terminal grid): the hover actions of a
// Claude turn (⧉ ✎ × in one pill over a faint band), the "sending to" label at Claude's
// input, confirm cards (edit, remove, ⌘W) and the undo-send toast. Everything
// draws in `draw(_:)` so offscreen snapshots capture it, and nothing here runs unless
// the pane runs Claude Code or a card is up.

/// A small button drawn by hand: SF Symbol and/or title, optional shortcut hint.
final class OverlayButton: NSView {
    enum Style { case icon, chip, secondary, primary }
    var symbol: String?
    var title: String?
    var shortcut: String?
    let style: Style
    var action: (() -> Void)?
    /// Pointer entered (true) / left (false): the × explains itself beside the bar.
    var onHover: ((Bool) -> Void)?
    /// Turn index this button acts on (hover actions).
    var turn = 0
    /// An icon button that reads a step stronger than its neighbors (the turn pill's ×).
    var prominent = false
    private var hovering = false { didSet { needsDisplay = true } }
    var isHovering: Bool { hovering }

    init(symbol: String? = nil, title: String? = nil, shortcut: String? = nil, style: Style, help: String? = nil,
         action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.shortcut = shortcut
        self.style = style
        self.action = action
        super.init(frame: .zero)
        toolTip = help
        setAccessibilityRole(.button)
        setAccessibilityLabel(help ?? title)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var titleFont: NSFont { .systemFont(ofSize: 12, weight: style == .primary ? .semibold : .regular) }
    private var hintFont: NSFont { .systemFont(ofSize: 10.5, weight: .medium) }

    var fittingWidth: CGFloat {
        if style == .icon { return T.Layout.hoverActionSize }
        var w: CGFloat = 10
        if symbol != nil { w += 14 + (title == nil ? 0 : 5) }
        if let t = title { w += ceil((t as NSString).size(withAttributes: [.font: titleFont]).width) }
        if let s = shortcut { w += 8 + ceil((s as NSString).size(withAttributes: [.font: hintFont]).width) + 8 }
        return w + 10
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovering = false; onHover?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    func performClick() { action?() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: T.Radius.control, yRadius: T.Radius.control)
        let fg: NSColor
        switch style {
        case .icon:
            if hovering { T.Colors.controlHover.nsColor.setFill(); path.fill() }
            fg = (hovering ? T.Colors.textPrimary : prominent ? T.Colors.textSecondary : T.Colors.textTertiary).nsColor
        case .chip, .secondary:
            T.Colors.elevatedBackground.nsColor.setFill(); path.fill()
            if hovering { T.Colors.rowHover.nsColor.setFill(); path.fill() }
            T.Colors.border.nsColor.setStroke(); path.lineWidth = 1; path.stroke()
            fg = T.Colors.textPrimary.nsColor
        case .primary:
            T.Colors.accent.nsColor.setFill(); path.fill()
            fg = T.Colors.onAccent.nsColor
        }
        var x: CGFloat = style == .icon ? 0 : 10
        if let sym = symbol, let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: style == .icon ? 12 : 11,
                                           weight: style == .icon ? (prominent ? .semibold : .medium) : .semibold)) {
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect)
                fg.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let s = tinted.size
            let ix = style == .icon ? (bounds.width - s.width) / 2 : x + (14 - s.width) / 2
            tinted.draw(in: NSRect(x: ix, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            x += 14 + 5
        }
        if let t = title {
            let a: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: fg]
            let sz = (t as NSString).size(withAttributes: a)
            (t as NSString).draw(at: NSPoint(x: x, y: (bounds.height - sz.height) / 2), withAttributes: a)
            x += ceil(sz.width) + 8
        }
        if let s = shortcut {
            let color = style == .primary ? fg.withAlphaComponent(0.75) : T.Colors.textTertiary.nsColor
            let a: [NSAttributedString.Key: Any] = [.font: hintFont, .foregroundColor: color]
            let sz = (s as NSString).size(withAttributes: a)
            let box = NSRect(x: x - 2, y: (bounds.height - sz.height - 2) / 2, width: sz.width + 8, height: sz.height + 2)
            if style != .primary {
                let bp = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
                T.Colors.border.nsColor.setStroke(); bp.lineWidth = 1; bp.stroke()
            }
            (s as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 1), withAttributes: a)
        }
    }

    override var isFlipped: Bool { false }
}

/// Rounded elevated panel with a 1pt border and an optional accent bar on the left.
class PanelView: FlippedView {
    var accentColor: NSColor?
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: T.Radius.popover, yRadius: T.Radius.popover)
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.offsetBy(dx: 0, dy: 1.5).insetBy(dx: 1, dy: 1),
                     xRadius: T.Radius.popover, yRadius: T.Radius.popover).fill()
        T.Colors.elevatedBackground.nsColor.setFill()
        path.fill()
        T.Colors.border.nsColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        if let a = accentColor {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            a.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The hovered turn's actions (POLISH.md 7): ⧉ Copy original (when the turn has a reply), ✎ Edit &
/// resend, × Remove, 22×20 buttons in one pill at the turn block's top right. × reads a step stronger.
final class TurnActionBar: FlippedView {
    var turn = 0
    let copy: OverlayButton
    let edit: OverlayButton
    let remove: OverlayButton
    /// The pill is (logically) up; it fades out over `Motion` before it is hidden.
    private(set) var shown = false
    var hasCopy = true { didSet { copy.isHidden = !hasCopy; needsLayout = true } }
    /// ✎ and × (they drive Claude Code's rewind): off for Codex turns and ! shell commands, which get ⧉ only.
    var editable = true { didSet { updateRewindButtons() } }
    /// × too: off on the conversation's first turn (removing it would leave nothing), ✎ stays.
    var removable = true { didSet { updateRewindButtons() } }
    private func updateRewindButtons() {
        edit.isHidden = !editable
        remove.isHidden = !(editable && removable)
        needsLayout = true
    }
    /// The reply ⧉ copies is Codex's (its tooltip).
    var codex = false {
        didSet {
            copy.toolTip = "Copy original: \(codex ? "Codex" : "Claude")’s reply as markdown (⌥⌘C)"
            copy.setAccessibilityLabel(copy.toolTip)
        }
    }
    private var buttons: [OverlayButton] { (hasCopy ? [copy] : []) + (editable ? [edit] : []) + (editable && removable ? [remove] : []) }
    init(onCopy: @escaping () -> Void, onEdit: @escaping () -> Void, onRemove: @escaping () -> Void) {
        copy = OverlayButton(symbol: "doc.on.doc", style: .icon, help: "Copy original: Claude’s reply as markdown (⌥⌘C)", action: onCopy)
        edit = OverlayButton(symbol: "pencil", style: .icon, help: "Edit & resend: rewind to this message and put it back in the input",
                             action: onEdit)
        remove = OverlayButton(symbol: "xmark", style: .icon, help: "Remove: rewind Claude to before this message",
                               action: onRemove)
        remove.prominent = true
        super.init(frame: .zero)
        isHidden = true
        alphaValue = 0
        for b in [copy, edit, remove] { addSubview(b) }
    }
    required init?(coder: NSCoder) { fatalError() }
    static let buttonSize = NSSize(width: T.Layout.hoverActionSize, height: 20)
    var size: NSSize {
        let n = CGFloat(buttons.count)
        return NSSize(width: n * Self.buttonSize.width + (n + 1) * 2, height: Self.buttonSize.height + 4)
    }
    override func layout() {
        super.layout()
        let b = Self.buttonSize
        var x: CGFloat = 2
        for v in buttons {
            v.frame = NSRect(x: x, y: 2, width: b.width, height: b.height)
            x += b.width + 2
        }
    }

    /// Fade in / out (120ms; instant with Reduce Motion). Moving between rows of the same turn,
    /// or to another turn, never fades: only the frame changes.
    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        if on { isHidden = false }
        let target: CGFloat = on ? 1 : 0
        guard !T.Motion.reduceMotion else { alphaValue = target; isHidden = !on; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = T.Motion.selection
            self.animator().alphaValue = target
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if let self, !self.shown { self.isHidden = true } }
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: T.Radius.actionPill, yRadius: T.Radius.actionPill)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        shadow.shadowColor = dark ? NSColor.black.withAlphaComponent(0.35) : NSColor(srgbRed: 0x2E / 255.0, green: 0x34 / 255.0, blue: 0x40 / 255.0, alpha: 0.12)
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowBlurRadius = 18
        shadow.set()
        T.Colors.elevatedBackground.nsColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        T.Colors.border.nsColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// The workspace legend on Claude's input rule (R7, POLISH.md 8): 6×6 accent chip and the title
/// in tertiary text, on the terminal background so the rule seems to pass behind it.
final class InputLabelView: NSView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var accent: NSColor = .clear { didSet { if accent != oldValue { needsDisplay = true } } }
    var background: NSColor = .clear { didSet { if background != oldValue { needsDisplay = true } } }
    static let maxCharacters = 28
    private var font: NSFont { T.Typography.inputLegend.nsFont }
    var shownText: String { text.count > Self.maxCharacters ? String(text.prefix(Self.maxCharacters - 1)) + "…" : text }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var fittingWidth: CGFloat { 6 + 6 + 5 + ceil((shownText as NSString).size(withAttributes: [.font: font]).width) + 6 }
    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: (bounds.height - 6) / 2, width: 6, height: 6), xRadius: 2, yRadius: 2).fill()
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: T.Colors.textTertiary.nsColor]
        let sz = (shownText as NSString).size(withAttributes: a)
        (shownText as NSString).draw(at: NSPoint(x: 17, y: (bounds.height - sz.height) / 2), withAttributes: a)
    }
}

/// A small elevated label (the × explanation), like the mockup's `.tip`.
final class TipView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    private let font = NSFont.systemFont(ofSize: 11)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var naturalSize: NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16, height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        T.Colors.elevatedBackground.nsColor.setFill()
        path.fill()
        T.Colors.border.nsColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: T.Colors.textPrimary.nsColor]
        let sz = (text as NSString).size(withAttributes: a)
        (text as NSString).draw(at: NSPoint(x: 8, y: (bounds.height - sz.height) / 2), withAttributes: a)
    }
}

/// The URL of the link under the pointer, in the pane's bottom-left corner; it moves to the
/// bottom-right while the pointer is over it. Adapted from Ghostty (ff23824)
/// `macos/Sources/Helpers/URLHoverBanner.swift` and `UntrustedURL.swift` (`displayString`),
/// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors, MIT (THIRD_PARTY_NOTICES.md).
final class LinkBanner: NSView {
    private(set) var text = ""
    private(set) var onRight = false
    private let font = NSFont.systemFont(ofSize: 12)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What is shown for `url`: invisible / line-breaking / bidi characters made visible as
    /// `\u{…}` (as Ghostty's UntrustedURL.displayString), so a link can't disguise its target.
    static func displayString(_ url: String) -> String {
        var out = ""
        for u in url.unicodeScalars {
            switch u.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069,
                 0x2028...0x2029, 0x2060, 0xFEFF:
                out += "\\u{\(String(u.value, radix: 16, uppercase: true))}"
            default:
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    func show(_ url: String?, pointer: NSPoint?, in container: NSRect) {
        guard let url else { isHidden = true; return }
        text = Self.displayString(url)
        let h: CGFloat = 22
        let w = min(ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16, max(80, container.width - 40))
        let left = NSRect(x: 0, y: container.height - h, width: w, height: h)
        onRight = pointer.map { left.insetBy(dx: -4, dy: -4).contains($0) } ?? false
        frame = onRight ? left.offsetBy(dx: container.width - w, dy: 0) : left
        isHidden = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Flush with the pane's bottom corner, rounded on the inner top corner only: a rounded
        // rect that runs past the outer edges, clipped to the bounds.
        let r: CGFloat = 8, b = bounds
        let shape = onRight ? NSRect(x: 0.5, y: 0.5, width: b.width + r, height: b.height + r)
                            : NSRect(x: -r, y: 0.5, width: b.width + r - 0.5, height: b.height + r)
        let path = NSBezierPath(roundedRect: shape, xRadius: r, yRadius: r)
        T.Colors.elevatedBackground.nsColor.setFill()
        path.fill()
        T.Colors.border.nsColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: T.Colors.textSecondary.nsColor, .paragraphStyle: para]
        let th = ceil(font.ascender - font.descender)
        (text as NSString).draw(in: NSRect(x: 8, y: (b.height - th) / 2, width: b.width - 16, height: th), withAttributes: a)
    }
}

/// A confirm card: message, detail, Cancel (esc) and a primary button (⏎).
final class ConfirmCard: PanelView {
    let message = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let cancel: OverlayButton
    let confirm: OverlayButton
    init(message: NSAttributedString, detail: String, confirmTitle: String, accent: NSColor?,
         onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        cancel = OverlayButton(title: "Cancel", shortcut: "esc", style: .secondary, action: onCancel)
        confirm = OverlayButton(symbol: nil, title: confirmTitle, shortcut: "⏎", style: .primary, action: onConfirm)
        super.init(frame: .zero)
        accentColor = accent
        self.message.attributedStringValue = message
        self.message.isSelectable = false
        self.detail.stringValue = detail
        self.detail.font = .systemFont(ofSize: 11)
        self.detail.textColor = T.Colors.textTertiary.nsColor
        self.detail.isSelectable = false
        for v in [self.message, self.detail, cancel, confirm] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Card width that shows everything on one line without truncation.
    var naturalWidth: CGFloat {
        let m = ceil(message.attributedStringValue.size().width) + 4
        let d = ceil((detail.stringValue as NSString).size(withAttributes: [.font: detail.font!]).width) + 4
        return 16 + max(m, d) + 12 + buttonsWidth + 12
    }

    func height(forWidth w: CGFloat) -> CGFloat {
        let textW = w - 16 - buttonsWidth - 12 - 12
        let mh = message.attributedStringValue.boundingRect(with: NSSize(width: textW, height: 400),
                                                             options: [.usesLineFragmentOrigin]).height
        let dh = detail.stringValue.isEmpty ? 0 : (detail.stringValue as NSString).boundingRect(
            with: NSSize(width: textW, height: 400), options: [.usesLineFragmentOrigin],
            attributes: [.font: detail.font!]).height + 2
        return max(48, ceil(mh + dh) + 22)
    }
    private var buttonsWidth: CGFloat { cancel.fittingWidth + 8 + confirm.fittingWidth }

    override func layout() {
        super.layout()
        let bh: CGFloat = 26
        let cw = confirm.fittingWidth, xw = cancel.fittingWidth
        confirm.frame = NSRect(x: bounds.width - 12 - cw, y: (bounds.height - bh) / 2, width: cw, height: bh)
        cancel.frame = NSRect(x: confirm.frame.minX - 8 - xw, y: (bounds.height - bh) / 2, width: xw, height: bh)
        let textW = cancel.frame.minX - 12 - 16
        let mh = ceil(message.attributedStringValue.boundingRect(with: NSSize(width: textW, height: 400),
                                                                options: [.usesLineFragmentOrigin]).height) + 2
        let dh = detail.stringValue.isEmpty ? 0 : ceil((detail.stringValue as NSString).boundingRect(
            with: NSSize(width: textW, height: 400), options: [.usesLineFragmentOrigin],
            attributes: [.font: detail.font!]).height) + 2
        let top = (bounds.height - mh - dh) / 2
        message.frame = NSRect(x: 16, y: top, width: textW, height: mh)
        detail.frame = NSRect(x: 16, y: top + mh, width: textW, height: dh)
    }
}

/// "✓ Sent to ● title  2s  Undo ⌘Z" with a line draining over 3s (R7); also used for
/// short inline notes (no button, no line).
final class ToastView: PanelView {
    var text = NSAttributedString() { didSet { needsDisplay = true } }
    var symbol: String? = "checkmark"
    var symbolColor: NSColor = T.Colors.stateDone.nsColor
    var countdown: String? { didSet { if countdown != oldValue { needsDisplay = true } } }
    /// The line drains over the undo window: Core Animation runs it (the render server, not a
    /// timer in the app). nil = no line.
    private var drain: (start: Date, duration: TimeInterval)?
    /// 1 -> 0 over the undo window; nil = no line.
    var progress: CGFloat? {
        drain.map { CGFloat(max(0, min(1, 1 - Date().timeIntervalSince($0.start) / $0.duration))) }
    }
    private let lineClip = CALayer()
    private let line = CALayer()
    let button: OverlayButton?

    init(button: OverlayButton?) {
        self.button = button
        super.init(frame: .zero)
        wantsLayer = true
        if let button { addSubview(button) }
    }

    func startDrain(duration: TimeInterval) {
        drain = (Date(), duration)
        guard let layer else { return }
        lineClip.masksToBounds = true
        lineClip.cornerRadius = T.Radius.toast
        line.backgroundColor = T.Colors.accent.nsColor.cgColor
        line.anchorPoint = CGPoint(x: 0, y: 0.5)
        lineClip.addSublayer(line)
        layer.addSublayer(lineClip)
        placeLine()
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = 1
        a.toValue = 0
        a.duration = duration
        line.transform = CATransform3DMakeScale(0, 1, 1)
        line.add(a, forKey: "drain")
    }

    private func placeLine() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineClip.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        line.bounds = CGRect(x: 0, y: 0, width: lineClip.bounds.width, height: 2)
        line.position = CGPoint(x: 0, y: lineClip.bounds.height - 1.5)
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat {
        var w: CGFloat = 14 + (symbol == nil ? 0 : 20) + ceil(text.size().width) + 14
        if let c = countdown { w += ceil((c as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 12 }
        if let b = button { w += b.fittingWidth + 6 }
        return min(w, 520)
    }

    override func layout() {
        super.layout()
        if let b = button {
            let bw = b.fittingWidth
            b.frame = NSRect(x: bounds.width - 8 - bw, y: (bounds.height - 26) / 2, width: bw, height: 26)
        }
        if drain != nil { placeLine() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var x: CGFloat = 14
        let midY = bounds.height / 2
        if let sym = symbol, let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
            let c = symbolColor
            let tinted = NSImage(size: img.size, flipped: false) { r in img.draw(in: r); c.set(); r.fill(using: .sourceAtop); return true }
            tinted.draw(in: NSRect(x: x, y: midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
            x += 20
        }
        let maxTextW = (button.map { $0.frame.minX } ?? bounds.width) - x - 12
            - (countdown == nil ? 0 : 30)
        let ts = text.size()
        text.draw(with: NSRect(x: x, y: midY - ts.height / 2, width: maxTextW, height: ts.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let c = countdown, let b = button {
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: T.Colors.textTertiary.nsColor]
            let sz = (c as NSString).size(withAttributes: a)
            (c as NSString).draw(at: NSPoint(x: b.frame.minX - 10 - sz.width, y: midY - sz.height / 2), withAttributes: a)
        }
    }
}

/// A terminal frame held still over its pane: the surface's own pixels, byte for byte, shown the
/// way libghostty's layer shows them (top left, its scale, its color space), so nothing on screen
/// changes when it goes up or comes down. Also drawn, so snapshots show it.
final class FrozenFrameView: NSView {
    let image: CGImage
    let scale: CGFloat

    /// nil when the surface has no frame yet.
    init?(surface: SurfaceView) {
        guard let contents = surface.layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID(),
              let image = Self.copy(unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)) else { return nil }
        self.image = image
        scale = surface.layer?.contentsScale ?? 2
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsPlacement = .topLeft
        updateLayer()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer else { return }
        layer.contentsGravity = .topLeft
        layer.contentsScale = scale
        layer.masksToBounds = true
        layer.contents = image
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = CGFloat(image.width) / scale, h = CGFloat(image.height) / scale
        NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: 0, y: bounds.height - h, width: w, height: h))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The IOSurface's BGRA bytes copied as they are (libghostty renders 32BGRA in Display P3), no
    /// color conversion on the way.
    static func copy(_ s: IOSurfaceRef) -> CGImage? {
        guard IOSurfaceGetPixelFormat(s) == 0x4247_5241 /* 'BGRA' */, IOSurfaceLock(s, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(s, .readOnly, nil) }
        let w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s)
        guard w > 0, h > 0 else { return nil }
        let data = Data(bytes: IOSurfaceGetBaseAddress(s), count: bpr * h)
        let space = IOSurfaceCopyValue(s, kIOSurfaceColorSpace).flatMap { CGColorSpace(propertyListPlist: $0 as CFPropertyList) }
            ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Container over a pane's terminal. Passes every click through except on its controls.
final class PaneOverlayView: FlippedView {
    var turnBar: TurnActionBar?
    let inputLabel = InputLabelView()
    var card: ConfirmCard?
    var toast: ToastView?
    var findBar: FindBar?
    /// The pane's last frame, held over it while lmux drives Claude Code's rewind menu.
    var freeze: NSView?
    var freezeShown: Bool { freeze != nil }
    /// Highlight band behind the hovered turn's visible rows (overlay coordinates).
    var turnBand: NSRect? { didSet { if turnBand != oldValue { needsDisplay = true } } }
    let tip = TipView()
    let link = LinkBanner()
    /// The hovered turn's first visible row (top, height) in overlay coordinates: the pill sits on it.
    var turnRow: (top: CGFloat, height: CGFloat)?
    var inputRuleRow: (top: CGFloat, height: CGFloat)?
    /// Where Claude's input rule starts (overlay x: the terminal's left padding).
    var inputRuleStart: CGFloat = 14
    /// Vertical runs of blank terminal rows (top, bottom): where a card can sit without
    /// covering Claude's output. Set when a card is shown.
    var freeRuns: [(top: CGFloat, bottom: CGFloat)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        inputLabel.isHidden = true
        addSubview(inputLabel)
        tip.isHidden = true
        addSubview(tip)
        link.isHidden = true
        addSubview(link)
    }

    /// The hovered link's URL (nil hides it); `pointer` in the surface's (unflipped) coordinates.
    func showLink(_ url: String?, pointer: NSPoint?) {
        link.show(url, pointer: pointer.map { NSPoint(x: $0.x, y: bounds.height - $0.y) }, in: bounds)
    }

    /// A drag is over this pane: a calm accent outline + faint tint (never a preview panel).
    var dropTarget = false { didSet { if dropTarget != oldValue { needsDisplay = true } } }

    /// The hovered turn: a faint `promptRowHover` band across its rows (the block and the pill read as one).
    override func draw(_ dirtyRect: NSRect) {
        if dropTarget {
            T.Colors.accent.nsColor.withAlphaComponent(0.06).setFill()
            bounds.fill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: T.Radius.pane, yRadius: T.Radius.pane)
            path.lineWidth = 2
            T.Colors.accent.nsColor.withAlphaComponent(0.7).setStroke()
            path.stroke()
        }
        guard let b = turnBand else { return }
        T.Colors.promptRowHover.nsColor.setFill()
        b.fill()
    }

    /// The × explanation beside the hover bar (nil hides it).
    func showTip(_ text: String?) {
        tip.text = text ?? ""
        tip.isHidden = text == nil
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    var isEmpty: Bool {
        (turnBar?.isHidden ?? true) && inputLabel.isHidden && card == nil && toast == nil
            && findBar == nil && turnBand == nil && !dropTarget && freeze == nil
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        freeze?.frame = bounds
        if let bar = turnBar, let r = turnRow {
            // The turn block's top right, inside the pane, centered on its first visible row.
            let sz = bar.size
            bar.frame = NSRect(x: max(8, W - sz.width - T.Layout.turnActionInset), y: max(2, r.top + (r.height - sz.height) / 2),
                               width: sz.width, height: sz.height)
            if !tip.isHidden {
                // Below the pill, right-aligned to it.
                let t = tip.naturalSize
                let w = min(t.width, bar.frame.maxX - 8)
                tip.frame = NSRect(x: bar.frame.maxX - w, y: bar.frame.maxY + 6, width: w, height: t.height)
            }
        }
        if let r = inputRuleRow {
            // A legend on the rule: rule start + 10, centered on it, no row of its own.
            let h = max(13, min(r.height - 2, 15))
            inputLabel.frame = NSRect(x: inputRuleStart + 10, y: r.top + (r.height - h) / 2,
                                      width: min(inputLabel.fittingWidth, W - inputRuleStart - 24), height: h)
        }
        if let c = card {
            // As wide as its one-line message needs (it only truncates in a narrow pane),
            // right above Claude's input box with the "● workspace" label between, like the mockup.
            let w = min(W - 24, max(360, c.naturalWidth))
            let h = c.height(forWidth: w)
            let rule = inputRuleRow.map { $0.top } ?? (H - 8)
            c.frame = NSRect(x: 12, y: max(8, rule - 6 - h), width: w, height: h)
        }
        if let f = findBar {
            let w = min(FindBar.size.width, W - 24)
            f.frame = NSRect(x: W - 12 - w, y: 10, width: w, height: FindBar.size.height)
        }
        if let t = toast {
            // Inset well inside the pane so it never sits on the notification ring.
            let inset: CGFloat = 22
            let w = min(t.fittingWidth, W - 2 * inset), h: CGFloat = 40
            t.frame = NSRect(x: W - inset - w, y: H - inset - h, width: w, height: h)
        }
    }
}
