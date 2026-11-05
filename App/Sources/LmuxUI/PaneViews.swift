import AppKit
import LmuxTerminal
import LmuxTokens

private typealias T = LmuxTokens

/// A flat color box. Drawn in `draw(_:)` (not a layer color) so it follows the
/// appearance and shows up in `cacheDisplay` snapshots.
final class ColorView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.intersection(dirtyRect).fill()  // views don't clip to bounds on macOS 14+
    }
}

/// Flipped container so layout code reads top-down.
public class FlippedView: NSView {
    public override var isFlipped: Bool { true }
}

/// The 1.5pt notification ring drawn over an unfocused pane that needs input.
final class RingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let w = T.Layout.ringWidth
        let r = bounds.insetBy(dx: T.Layout.ringInset + w / 2, dy: T.Layout.ringInset + w / 2)
        let path = NSBezierPath(roundedRect: r, xRadius: T.Radius.pane, yRadius: T.Radius.pane)
        path.lineWidth = w
        T.Colors.notificationRing.nsColor.setStroke()
        path.stroke()
    }

    private(set) var shown = false
    func setShown(_ on: Bool, animated: Bool = true) {
        guard on != shown else { return }
        shown = on
        let instant = !animated || T.Motion.reduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = instant ? 0 : (on ? T.Motion.ringIn : T.Motion.ringOut)
            ctx.timingFunction = CAMediaTimingFunction(name: on ? .easeOut : .easeIn)
            animator().alphaValue = on ? 1 : 0
        }
    }
}

/// The small outlined word a header shows while its agent acts without asking ("bypass",
/// "auto"): `textTertiary` in a hairline capsule, drawn by the header that holds it.
enum ModeBadge {
    static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    static func size(_ text: String) -> NSSize {
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(w) + 10, height: 15)
    }
    static func draw(_ text: String, in r: NSRect) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: r.height / 2, yRadius: r.height / 2)
        path.lineWidth = 0.5
        T.Colors.textTertiary.nsColor.withAlphaComponent(0.6).setStroke()
        path.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: T.Colors.textTertiary.nsColor]
        let sz = (text as NSString).size(withAttributes: a)
        (text as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: a)
    }
}

/// Pane header, shown only when the workspace is split (POLISH.md 5): the pane's own title,
/// left-aligned, no rule. Focused in `textSecondary`, unfocused in `textTertiary`, and an unfocused
/// pane that needs input gets a leading dot. A trailing badge while its agent runs in bypass / auto mode.
final class PaneHeaderView: FlippedView {
    let label = NSTextField(labelWithString: "")
    var background: NSColor = T.Colors.windowBackground.nsColor { didSet { if background != oldValue { needsDisplay = true } } }
    var focused = false { didSet { if focused != oldValue { updateColor(); placeLabel(); needsDisplay = true } } }
    var needsInput = false { didSet { if needsInput != oldValue { placeLabel(); needsDisplay = true } } }
    var modeBadge: String? { didSet { if modeBadge != oldValue { placeLabel(); needsDisplay = true } } }
    /// Double-click renames the pane (locks its title).
    var onDoubleClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = T.Typography.paneTitle.nsFont
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        updateColor()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateColor() {
        label.textColor = (focused ? T.Colors.textSecondary : T.Colors.textTertiary).nsColor
    }

    private var showsDot: Bool { needsInput && !focused }

    override func layout() {
        super.layout()
        placeLabel()
    }

    private var badgeRect: NSRect? {
        guard let b = modeBadge else { return nil }
        let sz = ModeBadge.size(b)
        return NSRect(x: bounds.width - T.Layout.paneHeaderPaddingX - sz.width, y: (bounds.height - sz.height) / 2,
                      width: sz.width, height: sz.height)
    }

    private func placeLabel() {
        let h = T.Typography.paneTitle.lineHeight + 2
        let x = T.Layout.paneHeaderPaddingX + (showsDot ? 6 + 6 : 0)
        let right = badgeRect.map { bounds.width - $0.minX + 6 } ?? 8
        label.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: max(0, bounds.width - x - right), height: h)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        if showsDot {
            T.Colors.stateNeedsInput.nsColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: T.Layout.paneHeaderPaddingX, y: bounds.height / 2 - 3, width: 6, height: 6)).fill()
        }
        if let b = modeBadge, let r = badgeRect { ModeBadge.draw(b, in: r) }
    }
}

/// One pane: optional header, the terminal surface, and the ring overlay.
public final class PaneView: FlippedView {
    weak var pane: Pane?
    let header = PaneHeaderView()
    let ring = RingView()
    let overlay = PaneOverlayView(frame: .zero)
    /// The scrollback's overlay scroller (over the terminal, under lmux's overlays).
    let scroller: SurfaceScroller
    /// The workspace is split; the header shows only if the pane also has a title.
    var showsHeader = false { didSet { updateHeaderVisibility() } }

    /// Set the header text; an empty title collapses the header (no empty bar).
    func setHeaderTitle(_ t: String) {
        if header.label.stringValue != t { header.label.stringValue = t }
        updateHeaderVisibility()
    }

    private func updateHeaderVisibility() {
        // A tab strip takes the header's place (its active tab says the same).
        let on = showsHeader && tabStrip == nil && !header.label.stringValue.isEmpty
        if header.isHidden == on { header.isHidden = !on; needsLayout = true }
    }

    /// The leaf's tab strip, while this is the shown tab of a leaf with tabs (one strip per leaf,
    /// moved into whichever tab's view is shown).
    var tabStrip: TabStripView? {
        didSet {
            guard tabStrip !== oldValue else { return }
            if let old = oldValue, old.superview === self { old.removeFromSuperview() }
            if let s = tabStrip { addSubview(s, positioned: .below, relativeTo: ring) }
            updateHeaderVisibility()
            needsLayout = true
        }
    }

    init(pane: Pane) {
        self.pane = pane
        scroller = SurfaceScroller(surface: pane.surface)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        header.isHidden = true
        addSubview(header)
        addSubview(pane.surface)
        addSubview(scroller)
        addSubview(overlay)
        addSubview(ring)
        pane.surface.onDropTarget = { [weak self] on in self?.overlay.dropTarget = on }
        pane.surface.onLinkHover = { [weak self] url, pointer in self?.overlay.showLink(url, pointer: pointer) }
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        // A strip that moved on to another tab's view isn't this one's.
        if let s = tabStrip, s.superview !== self { tabStrip = nil }
        let hh = tabStrip != nil ? TabStripView.height : header.isHidden ? 0 : T.Layout.paneHeaderHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: header.isHidden ? 0 : hh)
        tabStrip?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: hh)
        let sf = NSRect(x: 0, y: hh, width: bounds.width, height: max(0, bounds.height - hh))
        pane?.surface.frame = sf
        scroller.frame = sf
        overlay.frame = sf
        ring.frame = bounds
    }
}

/// A split node's view: two children and a 1pt divider that can be dragged.
final class SplitContainerView: FlippedView {
    let node: SplitNode
    let axis: SplitAxis
    let first: NSView
    let second: NSView
    let divider = ColorView(T.Colors.separator.nsColor)
    var onRatioChange: (() -> Void)?
    private let grab: CGFloat = 3  // extra hit area on each side of the divider

    init(node: SplitNode, axis: SplitAxis, first: NSView, second: NSView) {
        self.node = node
        self.axis = axis
        self.first = first
        self.second = second
        super.init(frame: .zero)
        addSubview(first)
        addSubview(second)
        addSubview(divider)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var length: CGFloat { axis == .horizontal ? bounds.width : bounds.height }

    override func layout() {
        super.layout()
        let d = T.Layout.splitDividerWidth
        let avail = max(0, length - d)
        let a = (avail * node.ratio).rounded()
        if axis == .horizontal {
            first.frame = NSRect(x: 0, y: 0, width: a, height: bounds.height)
            divider.frame = NSRect(x: a, y: 0, width: d, height: bounds.height)
            second.frame = NSRect(x: a + d, y: 0, width: avail - a, height: bounds.height)
        } else {
            first.frame = NSRect(x: 0, y: 0, width: bounds.width, height: a)
            divider.frame = NSRect(x: 0, y: a, width: bounds.width, height: d)
            second.frame = NSRect(x: 0, y: a + d, width: bounds.width, height: avail - a)
        }
    }

    private var dividerHitRect: NSRect {
        axis == .horizontal
            ? divider.frame.insetBy(dx: -grab, dy: 0)
            : divider.frame.insetBy(dx: 0, dy: -grab)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if bounds.contains(p), dividerHitRect.contains(p) { return self }
        return super.hitTest(point)
    }

    override func resetCursorRects() {
        addCursorRect(dividerHitRect, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setRatio(forPosition: axis == .horizontal ? p.x : p.y)
    }

    /// Move the divider to `pos` (points from the leading edge), clamped so
    /// neither side gets smaller than ~2 cells.
    func setRatio(forPosition pos: CGFloat) {
        let minSide: CGFloat = 60
        let avail = max(1, length - T.Layout.splitDividerWidth)
        let clamped = min(max(pos, minSide), max(minSide, avail - minSide))
        node.ratio = clamped / avail
        needsLayout = true
        window?.invalidateCursorRects(for: self)
        onRatioChange?()
    }
}
