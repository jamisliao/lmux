// Adapted from Ghostty (https://github.com/ghostty-org/ghostty) at commit ff23824:
//   macos/Sources/Ghostty/Surface View/SurfaceScrollView.swift
// The scrollbar math (document height with the grid padding, the +Y-up inversion of the row
// offset, live scrolling sent back as `scroll_to_row`, overlay style forced, the scroller's
// appearance from the terminal background, the legacy-style flash on hover) follows upstream.
// lmux: upstream reparents the surface into the scroll view's document view; lmux lays the
// surface out itself (PaneView), so this NSScrollView sits on top of the surface as a sibling with
// an empty document view, takes clicks only on its scroller, and hands scroll wheel events to
// the surface. lmux changes are marked with "lmux:".
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import GhosttyKit

/// The native overlay scroller for a surface's scrollback: hidden until you scroll (or hover it
/// with a legacy-style pointer setting), fades out like any macOS scroll view, and dragging it
/// scrolls the terminal. No timers: it only does work when libghostty reports a new position.
public final class SurfaceScroller: NSView {
    private let scrollView = ForwardingScrollView()
    private let documentView = NSView()
    private weak var surface: SurfaceView?
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    /// The last row position sent via scroll_to_row (or reported), to avoid redundant actions.
    private var lastSentRow: Int?
    private var last: SurfaceView.Scrollbar?

    public init(surface: SurfaceView) {
        self.surface = surface
        // Ghostty's `scrollbar = never` turns it off (the default, `system`, shows it).
        let enabled = surface.surface.flatMap { ghostty_surface_app($0) }.flatMap { GhosttyRuntime.from($0) }?.showsScrollbar ?? true
        super.init(frame: .zero)
        scrollView.surface = surface
        scrollView.hasVerticalScroller = enabled
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        // Always the overlay style (see mouseMoved for a legacy-style pointer setting).
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = documentView
        addSubview(scrollView)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in self?.isLiveScrolling = true })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in self?.isLiveScrolling = false })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main
        ) { [weak self] _ in self?.handleLiveScroll() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil,
            // Overrides the change it is told about, so it runs synchronously on the posting thread.
            queue: nil
        ) { [weak self] _ in self?.scrollView.scrollerStyle = .overlay })

        surface.onScrollbarChange = { [weak self] in self?.scrollbarChanged() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: Hit testing

    /// lmux: only the scroller takes clicks, only while it is shown (a faded-out overlay scroller
    /// hit-tests as the empty document view, which would swallow the click) and only when there
    /// is scrollback to move through; everything else goes to the terminal (and lmux's overlays).
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard hasScrollback, let scroller = scrollView.verticalScroller, !scroller.isHidden else { return nil }
        let v = super.hitTest(point)
        return v.map { $0 === scroller || $0.isDescendant(of: scroller) } == true ? v : nil
    }

    private var hasScrollback: Bool { (surface?.scrollbar).map { $0.total > $0.len } ?? false }

    // MARK: Layout

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        documentView.frame.size.width = scrollView.bounds.width
        synchronizeAppearance()
        synchronizeScrollView()
        updateTrackingAreas()
    }

    private func synchronizeAppearance() {
        // The scroller's appearance matches the terminal's background, not the app's.
        guard let bg = surface?.terminalBackground?.usingColorSpace(.sRGB) else { return }
        let light = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent > 0.5
        let name: NSAppearance.Name = light ? .aqua : .darkAqua
        if scrollView.appearance?.name != name { scrollView.appearance = NSAppearance(named: name) }
    }

    /// Sizes the document view and scrolls the clip view to the terminal's viewport.
    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()
        if !isLiveScrolling, let surface, surface.cellSize.height > 0, let sb = surface.scrollbar {
            // Invert: the terminal's offset is from the top, AppKit's position from the bottom.
            let offsetY = CGFloat(sb.total - sb.offset - sb.len) * surface.cellSize.height
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
            lastSentRow = Int(sb.offset)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollbarChanged() {
        let sb = surface?.scrollbar
        synchronizeAppearance()
        synchronizeScrollView()
        // lmux: show the overlay scroller when the viewport moved through the scrollback (the
        // user scrolled), not when output appended at the bottom (offset and total move
        // together) or the pane resized.
        if let sb, let last, sb.total == last.total, sb.len == last.len, sb.offset != last.offset, sb.total > sb.len {
            scrollView.flashScrollers()
        }
        last = sb
    }

    /// The user is dragging the scroller: tell the terminal which row is now at the top.
    private func handleLiveScroll() {
        // lmux: while lmux reads the screen to drive the program, the viewport stays at the bottom.
        guard let surface, surface.cellSize.height > 0, !surface.inputHeld else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let fromBottom = documentView.frame.height - visible.origin.y - visible.height
        let row = max(0, Int(fromBottom / surface.cellSize.height))
        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surface.performBindingAction("scroll_to_row:\(row)")
    }

    /// The document must have the same vertical padding around the scrollback grid as the
    /// surface has around the screen grid, or the knob loses alignment with the content.
    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        if let surface, surface.cellSize.height > 0, let sb = surface.scrollbar {
            let padding = contentHeight - CGFloat(sb.len) * surface.cellSize.height
            return CGFloat(sb.total) * surface.cellSize.height + padding
        }
        return contentHeight
    }

    // MARK: Mouse

    public override func mouseMoved(with event: NSEvent) {
        // With the legacy (always-visible) style preference the pointer must be able to grab the
        // scroller without a wheel or gesture: flash it when the mouse moves over its area.
        guard NSScroller.preferredScrollerStyle == .legacy, hasScrollback else { return }
        scrollView.flashScrollers()
    }

    public override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(rect: convert(scroller.bounds, from: scroller),
                                       options: [.mouseMoved, .activeInKeyWindow], owner: self, userInfo: nil))
    }

    // MARK: Tests

    /// The scroller's knob: proportion of the track and position (0 top … 1 bottom).
    public var knob: (proportion: CGFloat, position: Double)? {
        guard let s = scrollView.verticalScroller, scrollView.hasVerticalScroller else { return nil }
        return (s.knobProportion, s.doubleValue)
    }
    public var scroller: NSScroller? { scrollView.verticalScroller }
    /// Drag the knob to `position` (0 top … 1 bottom), as a live scroll does.
    public func liveScroll(toPosition position: Double) {
        let visible = scrollView.contentView.documentVisibleRect.height
        let maxY = max(0, documentView.frame.height - visible)
        isLiveScrolling = true
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: maxY * (1 - position)))
        handleLiveScroll()
        isLiveScrolling = false
    }
}

/// lmux: the wheel / trackpad scrolls the terminal (libghostty owns the scrollback), never the
/// empty document view, even over the scroller.
private final class ForwardingScrollView: NSScrollView {
    weak var surface: SurfaceView?
    override func scrollWheel(with event: NSEvent) {
        if let surface { surface.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
