import AppKit
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

/// Window content: sidebar column (titlebar strip + SwiftUI list), titlebar
/// buttons, content header and the workspace's split tree.
///
/// Nothing is placed left of `trafficLightsInset` in the titlebar strip (outside full screen,
/// which hides the traffic lights until the pointer reveals them).
final class RootView: FlippedView {
    let model: AppModel
    weak var controller: LmuxController?
    /// Height of the titlebar strip; measured from the live window (toolbar style, macOS version).
    private(set) var titlebarHeight: CGFloat
    /// The window's titlebar view (titled window only). The titlebar buttons live in it: AppKit
    /// puts the toolbar's titlebar container above the content view, so controls in the content
    /// view's titlebar strip are drawn but never receive a click.
    private(set) weak var titlebarHost: NSView?

    /// Full 1:1 Apple Liquid Glass backdrops
    let titlebarBackdrop = TitlebarBackdrop()
    let sidebarBackdrop = SidebarBackdrop()
    let sidebarTitlebar = TitlebarDragView()
    let workspaceFilterHeaderHost: SidebarHostingView<WorkspaceFilterHeader>
    let sidebarHost: SidebarHostingView<SidebarView>
    let sidebarEdge = ColorView(T.Colors.separator.nsColor)
    let resizeHandle = SidebarResizeHandle()
    private var resizeObservers: [NSObjectProtocol] = []
    private var titlebarHostObserver: NSObjectProtocol?
    let chipState: TitlebarChipState
    let cluster: SidebarHostingView<TitlebarCluster>
    let centerChipHost: SidebarHostingView<TitlebarCenterChip>
    let rightClusterHost: SidebarHostingView<TitlebarRightCluster>
    let header = ContentHeaderView(frame: .zero)
    /// Holds the selected workspace's split tree.
    let content = FlippedView()
    /// Right inspector column
    let rightInspectorBackdrop = RightInspectorBackdrop()
    let rightInspectorHost: SidebarHostingView<InspectorContainerView>
    let rightInspectorHandle = RightInspectorResizeHandle()
    /// Full-width 32pt footer
    let footerBackdrop = FooterBackdrop()
    let footerHost: SidebarHostingView<WindowFooterView>

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
        self.chipState = TitlebarChipState(workspace: model.selected, availableWidth: 400)
        sidebarHost = SidebarHostingView(rootView: SidebarView(model: model, controller: controller))
        workspaceFilterHeaderHost = SidebarHostingView(rootView: WorkspaceFilterHeader(model: model, controller: controller))
        cluster = SidebarHostingView(rootView: TitlebarCluster(model: model, controller: controller))
        centerChipHost = SidebarHostingView(rootView: TitlebarCenterChip(state: chipState))
        rightClusterHost = SidebarHostingView(rootView: TitlebarRightCluster(model: model, controller: controller))
        rightInspectorHost = SidebarHostingView(rootView: InspectorContainerView(model: model, controller: controller))
        footerHost = SidebarHostingView(rootView: WindowFooterView(model: model, onInspectTab: { [weak controller] tab in
            controller?.showInspectorTab(tab)
        }, onToggleInspector: { [weak controller] in
            controller?.toggleInspector()
        }))
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        // SwiftUI hosting views size themselves to content by default; lmux lays them out.
        sidebarHost.sizingOptions = []
        workspaceFilterHeaderHost.sizingOptions = []
        cluster.sizingOptions = []
        centerChipHost.sizingOptions = []
        rightClusterHost.sizingOptions = []
        rightInspectorHost.sizingOptions = []
        footerHost.sizingOptions = []

        sidebarHost.safeAreaRegions = []
        workspaceFilterHeaderHost.safeAreaRegions = []
        cluster.safeAreaRegions = []
        centerChipHost.safeAreaRegions = []
        rightClusterHost.safeAreaRegions = []
        rightInspectorHost.safeAreaRegions = []
        footerHost.safeAreaRegions = []

        for v in [
            content, header,
            titlebarBackdrop,
            sidebarBackdrop, sidebarTitlebar, workspaceFilterHeaderHost, sidebarHost, sidebarEdge, resizeHandle,
            rightInspectorBackdrop, rightInspectorHost, rightInspectorHandle,
            footerBackdrop, footerHost,
            cluster, centerChipHost, rightClusterHost
        ] as [NSView] {
            addSubview(v)
        }
        resizeHandle.onDrag = { [weak self] x in
            guard let self else { return }
            self.model.sidebarWidth = min(max(x, T.Layout.sidebarWidthMin), T.Layout.sidebarWidthMax)
            self.needsLayout = true
            self.controller?.scheduleSave()
        }
        resizeHandle.onDragStateChange = { [weak self] active in
            self?.setAllBackdropsResizing(active)
        }
        rightInspectorHandle.onDrag = { [weak self] x in
            guard let self else { return }
            let W = self.bounds.width
            let newWidth = min(max(W - x, T.Layout.rightInspectorWidthMin), T.Layout.rightInspectorWidthMax)
            self.model.inspectorWidth = newWidth
            self.needsLayout = true
            self.controller?.scheduleSave()
        }
        rightInspectorHandle.onDragStateChange = { [weak self] active in
            self?.setAllBackdropsResizing(active)
        }
        let nc = NotificationCenter.default
        resizeObservers.append(nc.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, note.object as AnyObject? === w else { return }
                self.setAllBackdropsResizing(true)
            }
        })
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didResignKeyNotification] {
            resizeObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let w = self.window, note.object as AnyObject? === w else { return }
                    self.setAllBackdropsResizing(false)
                }
            })
        }
        resizeObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setAllBackdropsResizing(false)
            }
        })
        trackSidebarState()
        header.onDoubleClickTitle = { [weak self] in
            guard let self, let ws = self.model.selected else { return }
            self.controller?.promptRename(ws)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        resizeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let titlebarHostObserver {
            NotificationCenter.default.removeObserver(titlebarHostObserver)
        }
    }

    func setAllBackdropsResizing(_ active: Bool) {
        if !active {
            resizeHandle.cancelDragIfNeeded()
            rightInspectorHandle.cancelDragIfNeeded()
        }
        sidebarBackdrop.isResizing = active
        titlebarBackdrop.isResizing = active
        rightInspectorBackdrop.isResizing = active
        footerBackdrop.isResizing = active
    }

    /// Re-layout when the sidebar is toggled or resized (from anywhere).
    private func trackSidebarState() {
        withObservationTracking {
            _ = model.sidebarVisible
            _ = model.sidebarWidth
            _ = model.inspectorVisible
            _ = model.inspectorWidth
            _ = model.inspectorTab
            _ = model.selectedID
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
        if let titlebarHostObserver {
            NotificationCenter.default.removeObserver(titlebarHostObserver)
            self.titlebarHostObserver = nil
        }
        titlebarHost = host
        for v in [cluster, centerChipHost, rightClusterHost] as [NSView] {
            v.removeFromSuperview()
            host.addSubview(v)
        }
        host.postsFrameChangedNotifications = true
        titlebarHostObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: host, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
        needsLayout = true
    }

    /// The traffic lights in window coordinates (nil without a titled window). In full screen that's
    /// the coordinates of the window holding the titlebar (see `trackTrafficLights`), like the cluster's.
    var trafficLightsFrame: NSRect? {
        guard let w = window, let close = w.standardWindowButton(.closeButton), let zoom = w.standardWindowButton(.zoomButton),
              close.superview != nil, zoom.superview != nil else { return nil }
        return close.convert(close.bounds, to: nil).union(zoom.convert(zoom.bounds, to: nil))
    }

    /// The traffic lights are drawn on screen: not hidden or transparent (themselves or an ancestor),
    /// in a visible window, centered on the window's screen. In full screen they're in the view tree
    /// all along but shown only while the pointer reveals the titlebar.
    var trafficLightsVisible: Bool {
        guard let w = window, let close = w.standardWindowButton(.closeButton), let holder = close.window,
              holder.isVisible, holder.alphaValue > 0, !close.isHiddenOrHasHiddenAncestor,
              let screen = w.screen ?? holder.screen else { return false }
        var v: NSView? = close
        while let x = v {
            if x.alphaValue <= 0.01 { return false }
            v = x.superview
        }
        let r = holder.convertToScreen(close.convert(close.bounds, to: nil))
        return screen.frame.contains(NSPoint(x: r.midX, y: r.midY))
    }

    /// Set from `windowWillExitFullScreen` to `windowDidExitFullScreen`: the traffic lights come back
    /// during the exit animation, so the buttons take their windowed place as soon as it starts.
    var exitingFullScreen = false { didSet { needsLayout = true } }
    private var lightsObservations: [NSKeyValueObservation] = []
    private var lightsObservers: [NSObjectProtocol] = []

    /// Full screen: re-lay out when the traffic lights are revealed or hidden again (on while in full
    /// screen, off when it ends). AppKit moves the titlebar into a separate private window then
    /// (`NSToolbarFullScreenWindow`, whose parent is this window) and slides / fades it in when the
    /// pointer reaches the top edge. Nothing tells lmux about the reveal itself, so it watches what
    /// the reveal changes: that window's frame and the hidden / alpha / frame of the close button
    /// and its ancestors. No timer, and nothing at all outside full screen.
    func trackTrafficLights(_ on: Bool) {
        lightsObservations = []  // invalidated on release
        lightsObservers.forEach(NotificationCenter.default.removeObserver)
        lightsObservers = []
        guard on, let w = window, let close = w.standardWindowButton(.closeButton) else { return }
        let relayout: () -> Void = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
        }
        var v: NSView? = close
        while let x = v {
            lightsObservations += [x.observe(\.isHidden) { _, _ in relayout() }, x.observe(\.alphaValue) { _, _ in relayout() },
                                   x.observe(\.frame) { _, _ in relayout() }]
            v = x.superview
        }
        guard let holder = close.window, holder !== w else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            lightsObservers.append(NotificationCenter.default.addObserver(forName: name, object: holder, queue: .main) { _ in relayout() })
        }
    }

    override func layout() {
        super.layout()
        if let w = window, w.styleMask.contains(.titled), !w.styleMask.contains(.fullScreen) {
            let h = w.frame.height - w.contentLayoutRect.height
            if h > 0 { titlebarHeight = max(T.Layout.titlebarHeight, h) }
        }
        let W = bounds.width, H = bounds.height, tb = titlebarHeight
        let visible = model.sidebarVisible
        let effectiveSw: CGFloat = visible ? min(model.sidebarWidth, max(0, W - 120)) : 0

        // Footer layout
        let footerH: CGFloat = (H >= 120) ? T.Layout.footerHeight : 0
        let midH = max(0, H - tb - footerH)
        footerBackdrop.isHidden = (footerH == 0)
        footerHost.isHidden = (footerH == 0)
        if footerH > 0 {
            footerBackdrop.frame = NSRect(x: 0, y: H - footerH, width: W, height: footerH)
            footerHost.frame = NSRect(x: 0, y: H - footerH, width: W, height: footerH)
        }

        // Right Inspector layout & Narrow Window clamp
        let iw = model.inspectorWidth
        let canFitInspector = model.inspectorVisible && (W - effectiveSw - iw >= 120)
        let rw: CGFloat = canFitInspector ? iw : 0

        rightInspectorBackdrop.isHidden = !canFitInspector
        rightInspectorHost.isHidden = !canFitInspector
        rightInspectorHandle.isHidden = !canFitInspector

        if canFitInspector {
            let ix = W - rw
            rightInspectorBackdrop.frame = NSRect(x: ix, y: tb, width: rw, height: midH)
            rightInspectorHost.frame = NSRect(x: ix, y: tb, width: rw, height: midH)
            rightInspectorHandle.frame = NSRect(x: ix - 4, y: tb, width: 8, height: midH)
        }

        // Left Sidebar layout
        for v in [sidebarBackdrop, sidebarTitlebar, workspaceFilterHeaderHost, sidebarHost, sidebarEdge, resizeHandle] as [NSView] {
            v.isHidden = !visible
        }
        updateClusterAppearance()

        let headerH = T.Layout.workspaceFilterHeaderHeight
        // Keep sidebarBackdrop and sidebarEdge below the 44pt unified titlebar so only a single NSVisualEffectView sits in the titlebar (ADR-0003).
        sidebarBackdrop.frame = NSRect(x: 0, y: tb, width: max(0, effectiveSw - 1), height: midH)
        sidebarTitlebar.frame = NSRect(x: 0, y: 0, width: effectiveSw, height: tb)
        workspaceFilterHeaderHost.frame = NSRect(x: 0, y: tb, width: max(0, effectiveSw - 1), height: headerH)
        sidebarHost.frame = NSRect(x: 0, y: tb + headerH, width: max(0, effectiveSw - 1), height: max(0, midH - headerH))
        sidebarEdge.frame = NSRect(x: effectiveSw - 1, y: tb, width: 1, height: midH)
        resizeHandle.frame = NSRect(x: effectiveSw - 4, y: tb, width: 8, height: midH)

        // Titlebar layout
        titlebarBackdrop.frame = NSRect(x: 0, y: 0, width: W, height: tb)
        let cw = TitlebarCluster.width, bs = T.Layout.titlebarButtonSize
        let rcw = TitlebarRightCluster.width
        let lights = trafficLightsFrame
        // Full screen hides the traffic lights: the buttons go to the left edge (like Finder, Xcode),
        // and right after the lights again while the pointer reveals them (or full screen ends).
        let fullScreen = (window?.styleMask.contains(.fullScreen) ?? false) && !exitingFullScreen
        let inset = fullScreen && !trafficLightsVisible ? T.Layout.rowInsetX
            : lights.map { max(T.Layout.trafficLightsInset, $0.maxX + 12) } ?? T.Layout.trafficLightsInset
        let clusterX = inset
        let rightClusterX = max(clusterX + cw + 16, W - rcw - 8)

        if let host = titlebarHost, let lights {
            let midLeft = host.convert(NSPoint(x: clusterX, y: lights.midY), from: nil)
            cluster.frame = NSRect(x: midLeft.x, y: midLeft.y - bs / 2, width: cw, height: bs)

            let midRight = host.convert(NSPoint(x: rightClusterX, y: lights.midY), from: nil)
            rightClusterHost.frame = NSRect(x: midRight.x, y: midRight.y - bs / 2, width: rcw, height: bs)
        } else {
            cluster.frame = NSRect(x: clusterX, y: (tb - bs) / 2, width: cw, height: bs)
            rightClusterHost.frame = NSRect(x: rightClusterX, y: (tb - bs) / 2, width: rcw, height: bs)
        }

        // Center Chip layout
        let leftBound = clusterX + cw + 12
        let rightBound = rightClusterX - 12
        let maxChipW = max(0, rightBound - leftBound)
        let chipW = min(400, maxChipW)
        centerChipHost.isHidden = maxChipW < 40
        let chipX = max(leftBound, min(rightBound - chipW, (W - chipW) / 2))
        if abs(chipState.availableWidth - chipW) > 0.5 { chipState.availableWidth = chipW }
        if chipState.workspace !== model.selected { chipState.workspace = model.selected }

        if let host = titlebarHost, let lights {
            let midCenter = host.convert(NSPoint(x: chipX, y: lights.midY), from: nil)
            centerChipHost.frame = NSRect(x: midCenter.x, y: midCenter.y - bs / 2, width: chipW, height: bs)
        } else {
            centerChipHost.frame = NSRect(x: chipX, y: (tb - bs) / 2, width: chipW, height: bs)
        }

        // Content & Content Header layout
        let contentX = visible ? effectiveSw : clusterX + cw + 8
        header.frame = NSRect(x: contentX, y: 0, width: max(0, W - rw - contentX), height: tb)
        content.frame = NSRect(x: effectiveSw, y: tb, width: max(0, W - effectiveSw - rw), height: midH)

        // plugin 的 bar 放在 sidebar 最底部。集中寫在 layout() 最後：上面的版面計算怎麼改，
        // 這裡都是在它算完之後才扣掉 bar 的高度，rebase 時不必記得補回去。
        if let a = sidebarAccessory {
            let h = min(a.height, max(0, sidebarHost.frame.height - Self.sidebarListMinHeight))
            sidebarHost.frame.size.height -= h
            a.view.frame = NSRect(x: 0, y: H - footerH - h, width: max(0, effectiveSw - 1), height: h)
            a.view.isHidden = !visible
        }
    }

    /// Sidebar contents follow the terminal background only when sidebarMatchesTerminal is enabled.
    /// Unified 44pt titlebar controls stay on TitlebarBackdrop and inherit system/window appearance.
    func updateClusterAppearance() {
        let matchBg = model.sidebarVisible ? sidebarBackdrop.matchColor : nil
        cluster.appearance = nil
        centerChipHost.appearance = nil
        rightClusterHost.appearance = nil
        workspaceFilterHeaderHost.adoptAppearance(on: matchBg)
        // plugin 的 bar 與 sidebar 的列用同一套外觀（applySidebarLook 會先設定 sidebarHost 再呼叫這裡）。
        if let v = sidebarAccessory?.view, v.appearance?.name != sidebarHost.appearance?.name { v.appearance = sidebarHost.appearance }
    }

    func updateAllBackdropAppearances() {
        updateClusterAppearance()
        // Use NSApp.appearance (nil in .system mode) so inspector/footer track live Light/Dark switches dynamically.
        let appAppearance = NSApp.appearance
        rightInspectorHost.appearance = appAppearance
        footerHost.appearance = appAppearance
    }

    /// Content header (POLISH.md 5): chip · title · `⎇ branch · ~/path`, without repeats.
    func updateHeader() {
        guard let ws = model.selected else { return }
        header.dotColor = T.Colors.workspaceAccents[ws.accent % T.Colors.workspaceAccents.count].nsColor
        let bg = ws.focusedPane?.surface?.terminalBackground
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
        if chipState.workspace !== ws { chipState.workspace = ws }
        if chipState.modeBadge != header.modeBadge { chipState.modeBadge = header.modeBadge }
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
final class SidebarBackdrop: GlassBackdropView {
    /// The terminal's background when the sidebar matches it (setting), else nil (translucent Nord).
    var matchColor: NSColor? { didSet { update() } }

    init(frame: NSRect = .zero) {
        super.init(
            frame: frame,
            materialStyle: .sidebar,
            translucentTint: T.Colors.sidebarTint,
            opaqueTint: T.Colors.sidebarBackground
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update() {
        if let c = matchColor {
            material.isHidden = true
            specular.isHidden = true
            tint.color = c
            return
        }
        super.update()
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
        title.textColor = .clear
        title.lineBreakMode = .byTruncatingTail
        for l in [branch, subtitle] {
            l.font = .systemFont(ofSize: 11.5)
            l.textColor = .clear
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
        zoomIcon.contentTintColor = .clear
        zoomIcon.alphaValue = 0
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
        T.Colors.separator.nsColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// Invisible strip on the sidebar edge; drag to resize the sidebar.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    private(set) var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        isDragging = true
        onDragStateChange?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) {
        isDragging = false
        onDragStateChange?(false)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { cancelDragIfNeeded() }
    }
    func cancelDragIfNeeded() {
        if isDragging {
            isDragging = false
            onDragStateChange?(false)
        }
    }
}
