import AppKit
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

/// Window content: sidebar column (titlebar strip + SwiftUI list), titlebar
/// buttons, content header and the workspace's split tree.
///
/// Nothing is placed left of `trafficLightsInset` in the titlebar strip.
final class RootView: FlippedView {
    let model: AppModel
    weak var controller: LmuxController?
    /// Height of the titlebar strip; measured from the live window (toolbar style, macOS version).
    private(set) var titlebarHeight: CGFloat
    /// The window's titlebar view (titled window only). The titlebar buttons live in it: AppKit
    /// puts the toolbar's titlebar container above the content view, so controls in the content
    /// view's titlebar strip are drawn but never receive a click.
    private(set) weak var titlebarHost: NSView?

    /// The sidebar's surface, full window height (titlebar included): translucent material + Nord tint.
    let sidebarBackdrop = SidebarBackdrop()
    /// Empty titlebar space over the sidebar: drags the window (paints nothing).
    let sidebarTitlebar = TitlebarDragView()
    let sidebarHost: SidebarHostingView<SidebarView>
    let sidebarEdge = ColorView(T.Colors.separator.nsColor)
    let resizeHandle = SidebarResizeHandle()
    let cluster: SidebarHostingView<TitlebarCluster>
    let header = ContentHeaderView(frame: .zero)
    /// Holds the selected workspace's split tree.
    let content = FlippedView()
    /// plugin 掛在 sidebar 最底部的橫列（`installSidebarAccessory`）；nil 表示沒有。
    var sidebarAccessory: (view: NSView, height: CGFloat)? {
        didSet {
            // 同一個 view 只改高度時不必重新加入（plugin 行數變動時會這樣呼叫）。
            if oldValue?.view !== sidebarAccessory?.view {
                oldValue?.view.removeFromSuperview()
                // 放在 resizeHandle 下層：兩者右緣重疊，sidebar 邊緣在 bar 上也要能拖拉。
                if let v = sidebarAccessory?.view { addSubview(v, positioned: .below, relativeTo: resizeHandle) }
            }
            needsLayout = true
        }
    }

    init(model: AppModel, controller: LmuxController, titlebarHeight: CGFloat) {
        self.model = model
        self.controller = controller
        self.titlebarHeight = titlebarHeight
        sidebarHost = SidebarHostingView(rootView: SidebarView(model: model, controller: controller))
        cluster = SidebarHostingView(rootView: TitlebarCluster(model: model, controller: controller))
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        // SwiftUI hosting views size themselves to content by default; lmux lays them out.
        sidebarHost.sizingOptions = []
        cluster.sizingOptions = []
        // With a full-size content view the titlebar is an unsafe area: SwiftUI would push the
        // buttons' content down out of their frame (drawn one row low, clicks landing nowhere).
        // lmux places these views itself, so no safe-area insets.
        sidebarHost.safeAreaRegions = []
        cluster.safeAreaRegions = []
        for v in [content, header, sidebarBackdrop, sidebarTitlebar, sidebarHost, sidebarEdge, resizeHandle, cluster] as [NSView] {
            addSubview(v)
        }
        resizeHandle.onDrag = { [weak self] x in
            guard let self else { return }
            self.model.sidebarWidth = min(max(x, T.Layout.sidebarWidthMin), T.Layout.sidebarWidthMax)
            self.needsLayout = true
            self.controller?.scheduleSave()
        }
        trackSidebarState()
        header.onDoubleClickTitle = { [weak self] in
            guard let self, let ws = self.model.selected else { return }
            self.controller?.promptRename(ws)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Re-layout when the sidebar is toggled or resized (from anywhere).
    private func trackSidebarState() {
        withObservationTracking {
            _ = model.sidebarVisible
            _ = model.sidebarWidth
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.needsLayout = true
                self?.trackSidebarState()
            }
        }
    }

    var sidebarWidth: CGFloat { model.sidebarVisible ? model.sidebarWidth : 0 }

    /// Move the titlebar buttons into the window's titlebar view (see `titlebarHost`).
    func attachTitlebar(_ host: NSView) {
        titlebarHost = host
        cluster.removeFromSuperview()
        host.addSubview(cluster)
        host.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: host, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
        needsLayout = true
    }

    /// The traffic lights in window coordinates (nil without a titled window).
    var trafficLightsFrame: NSRect? {
        guard let w = window, let close = w.standardWindowButton(.closeButton), let zoom = w.standardWindowButton(.zoomButton),
              close.superview != nil, zoom.superview != nil else { return nil }
        return close.convert(close.bounds, to: nil).union(zoom.convert(zoom.bounds, to: nil))
    }

    override func layout() {
        super.layout()
        if let w = window, w.styleMask.contains(.titled), !w.styleMask.contains(.fullScreen) {
            let h = w.frame.height - w.contentLayoutRect.height
            if h > 0 { titlebarHeight = h }
        }
        let W = bounds.width, H = bounds.height, tb = titlebarHeight
        let sw = sidebarWidth
        let visible = model.sidebarVisible
        for v in [sidebarBackdrop, sidebarTitlebar, sidebarHost, sidebarEdge, resizeHandle] as [NSView] { v.isHidden = !visible }
        updateClusterAppearance()

        sidebarBackdrop.frame = NSRect(x: 0, y: 0, width: max(0, sw - 1), height: H)
        sidebarTitlebar.frame = NSRect(x: 0, y: 0, width: sw, height: tb)
        sidebarHost.frame = NSRect(x: 0, y: tb, width: max(0, sw - 1), height: H - tb)
        sidebarEdge.frame = NSRect(x: sw - 1, y: 0, width: 1, height: H)
        resizeHandle.frame = NSRect(x: sw - 4, y: tb, width: 8, height: H - tb)

        let cw = TitlebarCluster.width, bs = T.Layout.titlebarButtonSize
        let lights = trafficLightsFrame
        let inset = lights.map { max(T.Layout.trafficLightsInset, $0.maxX + 12) } ?? T.Layout.trafficLightsInset
        // Fixed right after the traffic lights whether the sidebar is shown or not (like Finder,
        // Notes, Xcode): the toggle never moves under the pointer, so a second click toggles back.
        let clusterX = inset
        if let host = titlebarHost, let lights {
            // Vertically centered on the traffic lights, in the titlebar view's coordinates.
            let mid = host.convert(NSPoint(x: clusterX, y: lights.midY), from: nil)
            cluster.frame = NSRect(x: mid.x, y: mid.y - bs / 2, width: cw, height: bs)
        } else {
            cluster.frame = NSRect(x: clusterX, y: (tb - bs) / 2, width: cw, height: bs)
        }

        let contentX = visible ? sw : clusterX + cw + 8
        header.frame = NSRect(x: contentX, y: 0, width: W - contentX, height: tb)
        content.frame = NSRect(x: sw, y: tb, width: W - sw, height: H - tb)

        // plugin 的 bar 放在 sidebar 最底部。集中寫在 layout() 最後：上面的版面計算怎麼改，
        // 這裡都是在它算完之後才扣掉 bar 的高度，rebase 時不必記得補回去。
        if let a = sidebarAccessory {
            sidebarHost.frame.size.height -= a.height
            a.view.frame = NSRect(x: 0, y: H - a.height, width: max(0, sw - 1), height: a.height)
            a.view.isHidden = !visible
        }
    }

    /// The titlebar buttons sit on the sidebar, or on the content header when it's hidden: they read
    /// like what's under them (the terminal's color: header, a sidebar that matches it).
    func updateClusterAppearance() {
        cluster.adoptAppearance(on: model.sidebarVisible ? sidebarBackdrop.matchColor : model.selected?.focusedPane?.surface.terminalBackground)
        // plugin 的 bar 與 sidebar 的列用同一套外觀（applySidebarLook 會先設定 sidebarHost 再呼叫這裡）。
        if let v = sidebarAccessory?.view, v.appearance?.name != sidebarHost.appearance?.name { v.appearance = sidebarHost.appearance }
    }

    /// Content header (POLISH.md 5): chip · title · `⎇ branch · ~/path`, without repeats.
    func updateHeader() {
        guard let ws = model.selected else { return }
        header.dotColor = T.Colors.workspaceAccents[ws.accent % T.Colors.workspaceAccents.count].nsColor
        let bg = ws.focusedPane?.surface.terminalBackground
        header.background = bg ?? T.Colors.windowBackground.nsColor
        header.zoomed = ws.isZoomed
        // Split, each pane header has its own; one pane (or zoomed), the content header says it.
        // (A pane with a tab strip has it there: the strip is that pane's header.)
        let shownPane = ws.zoomedPane ?? ws.focusedPane ?? ws.visiblePanes.first
        header.modeBadge = (ws.isSplit && !ws.isZoomed) || (shownPane.flatMap { ws.root.find($0) }?.hasStrip ?? false)
            ? nil : shownPane?.modeBadge
        // On the terminal's background: its text takes the appearance that reads there.
        header.adoptAppearance(on: bg)
        updateClusterAppearance()
        let (branch, path) = ws.headerMeta
        // Same texts (most calls: a hook event, a focus refresh): no layout or redraw.
        var changed = false
        for (field, text) in [(header.title, ws.title), (header.branch, branch ?? ""), (header.subtitle, path ?? "")]
            where field.stringValue != text {
            field.stringValue = text
            changed = true
        }
        guard changed else { return }
        header.needsLayout = true
        header.needsDisplay = true
    }
}

extension NSView {
    /// Chrome drawn on `background` (the terminal's) takes the appearance whose text tokens read on
    /// it (`LmuxTokens.appearance(on:)`); nil: inherit the app's.
    func adoptAppearance(on background: NSColor?) {
        let want = background.map { T.appearance(on: $0) }
        if appearance?.name != want?.name { appearance = want }
    }
}

/// The sidebar's surface (POLISH.md 2): `NSVisualEffectView(.sidebar, .behindWindow)` with a
/// `sidebarTint` layer on top, so the sidebar stays Nord and lets a little of the desktop through.
/// Opaque `sidebarBackground` under Reduce Transparency, and in headless / offscreen snapshots
/// (a material has nothing behind it to blend there).
final class SidebarBackdrop: NSView {
    let material = NSVisualEffectView()
    let tint = ColorView(T.Colors.sidebarTint.nsColor)
    /// Forced opaque (headless snapshots, tests).
    var forceOpaque = false { didSet { update() } }
    /// The terminal's background when the sidebar matches it (setting), else nil (translucent Nord).
    var matchColor: NSColor? { didSet { update() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        addSubview(material)
        addSubview(tint)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isOpaqueFallback: Bool { forceOpaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    private func update() {
        if let c = matchColor {
            material.isHidden = true
            tint.color = c
            return
        }
        let opaque = isOpaqueFallback
        material.isHidden = opaque
        tint.color = (opaque ? T.Colors.sidebarBackground : T.Colors.sidebarTint).nsColor
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        tint.frame = bounds
    }
}

/// Empty titlebar space: drags the window (also when lmux isn't active), and a
/// double-click does what System Settings > Desktop & Dock says (zoom, minimize or nothing).
class TitlebarDragView: FlippedView {
    var color: NSColor? { didSet { needsDisplay = true } }
    init(color: NSColor? = nil) {
        self.color = color
        super.init(frame: .zero)
    }
    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let color else { return }
        color.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Dragged explicitly (performDrag), so the window server never also starts a drag.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            Self.titlebarDoubleClick(window)
        } else {
            window?.performDrag(with: event)
        }
    }

    /// `AppleActionOnDoubleClick`: Maximize (default) / Fill -> zoom, Minimize, None.
    static func titlebarDoubleClick(_ window: NSWindow?, defaults: UserDefaults = .standard) {
        guard let window else { return }
        switch titlebarDoubleClickAction(defaults) {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    static func titlebarDoubleClickAction(_ defaults: UserDefaults) -> String {
        titlebarDoubleClickAction(setting: defaults.string(forKey: "AppleActionOnDoubleClick"),
                                  legacyMinimize: defaults.object(forKey: "AppleMiniaturizeOnDoubleClick") as? Bool)
    }

    /// `AppleActionOnDoubleClick` wins; before macOS 11 the setting was the bool
    /// `AppleMiniaturizeOnDoubleClick`; nothing set means zoom.
    static func titlebarDoubleClickAction(setting: String?, legacyMinimize: Bool?) -> String {
        if let setting { return setting }
        if let legacyMinimize { return legacyMinimize ? "Minimize" : "Maximize" }
        return "Maximize"
    }
}

/// The content column's titlebar: draggable, draws the terminal background and a bottom rule.
final class ContentHeaderView: TitlebarDragView {
    let title = NSTextField(labelWithString: "")
    /// `branch ·` (cut at its end when space runs out) and `~/…/folder` (kept whole).
    let branch = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    /// A tiny glyph after the title while the workspace is split-zoomed (POLISH.md-style subtle
    /// indicator): the only sign besides the menu item that the rest of the split is hidden.
    let zoomIcon = NSImageView()
    var dotColor: NSColor = .clear { didSet { if dotColor != oldValue { needsDisplay = true } } }
    var background: NSColor = T.Colors.windowBackground.nsColor { didSet { if background != oldValue { needsDisplay = true } } }
    var zoomed = false { didSet { if zoomed != oldValue { zoomIcon.isHidden = !zoomed; needsLayout = true } } }
    /// The shown pane's mode badge ("bypass", "auto") while no pane header shows it (one pane, or zoomed).
    var modeBadge: String? { didSet { if modeBadge != oldValue { needsLayout = true; needsDisplay = true } } }
    private var badgeRect: NSRect?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = T.Typography.windowTitle.nsFont
        title.textColor = T.Colors.textPrimary.nsColor
        title.lineBreakMode = .byTruncatingTail
        for l in [branch, subtitle] {
            l.font = .systemFont(ofSize: 11.5)
            l.textColor = T.Colors.textTertiary.nsColor
        }
        branch.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingMiddle
        for l in [title, branch, subtitle] {
            // Labels pass clicks to the header (drag / double-click), never select.
            l.isSelectable = false
            l.refusesFirstResponder = true
            addSubview(l)
        }
        zoomIcon.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                                 accessibilityDescription: "Zoomed")?.withSymbolConfiguration(.init(pointSize: 9.5, weight: .regular))
        zoomIcon.contentTintColor = T.Colors.textTertiary.nsColor
        zoomIcon.isHidden = true
        addSubview(zoomIcon)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The labels are decoration: the whole header is one drag / double-click target.
        frame.contains(point) ? self : nil
    }

    /// Double-click on the title renames the workspace.
    var onDoubleClickTitle: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, title.frame.insetBy(dx: -6, dy: -6).contains(convert(event.locationInWindow, from: nil)) {
            onDoubleClickTitle?()
        } else {
            super.mouseDown(with: event)
        }
    }

    private let padX = T.Layout.contentHeaderPaddingX
    private let chip: CGFloat = 9
    private static let branchGlyph = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "branch")?
        .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
    private var branchGlyphX: CGFloat?
    private var separatorX: CGFloat?

    override func layout() {
        super.layout()
        let midY = (bounds.height - 1) / 2
        var x = padX + chip + T.Spacing.m
        let tw = min(ceil(title.attributedStringValue.size().width) + 4, max(0, bounds.width * 0.6))
        let th = title.intrinsicContentSize.height
        title.frame = NSRect(x: x, y: midY - th / 2, width: tw, height: th)
        x += tw + 10
        if zoomed {
            zoomIcon.frame = NSRect(x: x, y: midY - 6, width: 13, height: 13)
            x += 13 + 8
        }
        badgeRect = nil
        if let b = modeBadge {
            let sz = ModeBadge.size(b)
            badgeRect = NSRect(x: x, y: midY - sz.height / 2, width: sz.width, height: sz.height)
            x += sz.width + 8
        }
        let sh = subtitle.intrinsicContentSize.height
        let y = midY - sh / 2 + 0.5   // the 11.5pt meta sits on the 13pt title's baseline
        let hasBranch = !branch.stringValue.isEmpty, hasPath = !subtitle.stringValue.isEmpty
        let glyphW: CGFloat = hasBranch ? 14 : 0
        let sepW: CGFloat = hasBranch && hasPath ? 14 : 0
        let avail = max(0, bounds.width - x - padX - glyphW - sepW)
        // The branch keeps at least 12 characters; the path is middle-truncated into what is left.
        let bNat = hasBranch ? ceil(branch.attributedStringValue.size().width) + 4 : 0
        let bMin = hasBranch ? min(bNat, ceil(NSAttributedString(string: String(repeating: "m", count: 12),
                                                                 attributes: [.font: branch.font!]).size().width)) : 0
        let pNat = hasPath ? ceil(subtitle.attributedStringValue.size().width) + 4 : 0
        let bw = min(bNat, max(bMin, avail - pNat))
        let pw = min(pNat, max(0, avail - bw))
        branchGlyphX = hasBranch ? x : nil
        x += glyphW
        branch.frame = NSRect(x: x, y: y, width: bw, height: sh)
        x += bw
        separatorX = sepW > 0 ? x : nil
        x += sepW
        subtitle.frame = NSRect(x: x, y: y, width: pw, height: sh)
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        T.Colors.separator.nsColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        dotColor.setFill()
        let midY = (bounds.height - 1) / 2
        NSBezierPath(roundedRect: NSRect(x: padX, y: midY - chip / 2, width: chip, height: chip), xRadius: 2.5, yRadius: 2.5).fill()
        let meta = T.Colors.textTertiary.nsColor
        if let gx = branchGlyphX, let img = Self.branchGlyph {
            let tinted = NSImage(size: img.size, flipped: false) { r in img.draw(in: r); meta.set(); r.fill(using: .sourceAtop); return true }
            tinted.draw(in: NSRect(x: gx, y: midY - img.size.height / 2 + 0.5, width: img.size.width, height: img.size.height))
        }
        if let b = modeBadge, let r = badgeRect { ModeBadge.draw(b, in: r) }
        if let sx = separatorX {
            let a: [NSAttributedString.Key: Any] = [.font: subtitle.font!, .foregroundColor: meta]
            let sz = ("·" as NSString).size(withAttributes: a)
            ("·" as NSString).draw(at: NSPoint(x: sx + (14 - sz.width) / 2, y: subtitle.frame.minY + 1), withAttributes: a)
        }
    }
}

/// Invisible strip on the sidebar edge; drag to resize the sidebar.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil).x)
    }
}
