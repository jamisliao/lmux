// Adapted from Ghostty (https://github.com/ghostty-org/ghostty) at commit ff23824:
//   macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift
// The keyboard / NSTextInputClient (IME) / mouse / scroll / copy-paste paths are
// kept as close to upstream as possible; SwiftUI, splits, inspector, notifications and
// accessibility were removed. Drag & drop follows upstream (escaped paths, as a paste).
// lmux changes are marked with "lmux:".
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import CoreText
import GhosttyKit

/// Options for creating a surface.
public struct SurfaceOptions {
    public var command: String?
    public var workingDirectory: String?
    public var environment: [String: String] = [:]
    /// lmux: text written to the pty as if typed once the shell starts
    /// (e.g. `claude --resume <id>\n` when restoring a session).
    public var initialInput: String?
    public init(command: String? = nil, workingDirectory: String? = nil, environment: [String: String] = [:],
                initialInput: String? = nil) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.initialInput = initialInput
    }
}

/// The NSView implementation for a terminal surface.
open class SurfaceView: NSView, NSTextInputClient {
    public private(set) var surface: ghostty_surface_t?

    /// Cell size in points (set by libghostty via the CELL_SIZE action).
    public internal(set) var cellSize: CGSize = .zero {
        didSet { if cellSize != oldValue { onScrollbarChange?() } }
    }

    /// Scrollback position (libghostty's SCROLLBAR action), in rows: `total` rows of scrollback +
    /// screen, the viewport starts at row `offset` (0 = top of scrollback) and is `len` rows tall.
    public struct Scrollbar: Equatable {
        public let total: UInt64
        public let offset: UInt64
        public let len: UInt64
    }
    public internal(set) var scrollbar: Scrollbar? {
        didSet { if scrollbar != oldValue { onScrollbarChange?() } }
    }
    /// lmux: the scrollbar state or the cell size changed (drives `SurfaceScroller`).
    public var onScrollbarChange: (() -> Void)?

    /// lmux: a frame landed on the layer. libghostty's renderer only draws when something on
    /// screen changed, so this is the "screen changed" signal it has no callback for.
    public var onFrame: (() -> Void)?
    private var frameObservation: NSKeyValueObservation?

    /// lmux: the link under the pointer (libghostty's MOUSE_OVER_LINK: a URL with ⌘ held, an
    /// OSC 8 hyperlink), nil when none.
    public internal(set) var hoverURL: String? {
        didSet { if hoverURL != oldValue { onLinkHover?(hoverURL, lastMousePoint) } }
    }
    /// lmux: `hoverURL` changed, or the pointer moved while it is set (point in view coordinates).
    public var onLinkHover: ((String?, NSPoint?) -> Void)?
    /// lmux: where the pointer last moved over this surface (view coordinates), nil once it left.
    public private(set) var lastMousePoint: NSPoint?

    public internal(set) var title: String = "" {
        // lmux: programs repaint the same title (spinners); only a new value is a change.
        didSet { if title != oldValue { onTitleChange?(title) } }
    }
    public var onTitleChange: ((String) -> Void)?

    /// lmux: what the running program says it is doing (OSC 7501; Codex's TUI reports this way).
    public struct ProgramStatus: Equatable, Sendable {
        public enum State: Equatable, Sendable { case idle, working, done, blocked, error, clear }
        public var state: State
        /// For `blocked`: "permission", "question" or "auth".
        public var kind: String?
        /// The reporting program ("codex"), empty if it didn't say.
        public var app: String
        /// When it came (on libghostty's thread, before the hop to the main queue).
        public var at: Date
        public init(state: State, kind: String? = nil, app: String, at: Date = Date()) {
            self.state = state
            self.kind = kind
            self.app = app
            self.at = at
        }
    }
    public var onProgramStatus: ((ProgramStatus) -> Void)?

    /// lmux: a burst of title escapes (a program setting thousands in a row) is applied once per
    /// main-queue turn, with the latest one, instead of once each (every change refreshes the
    /// row, the header and the branch). Called on libghostty's thread.
    private let titleLock = NSLock()
    private var pendingTitle: String?
    func titleArrived(_ t: String) {
        titleLock.lock()
        let scheduled = pendingTitle != nil
        pendingTitle = t
        titleLock.unlock()
        guard !scheduled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.titleLock.lock()
            let latest = self.pendingTitle
            self.pendingTitle = nil
            self.titleLock.unlock()
            if let latest { self.title = latest }
        }
    }

    /// lmux: terminal background color from the active (theme-resolved) config.
    public internal(set) var terminalBackground: NSColor? {
        didSet { if let terminalBackground { onBackgroundChange?(terminalBackground) } }
    }
    public var onBackgroundChange: ((NSColor) -> Void)?

    /// lmux: called when this surface gains or loses keyboard focus.
    public var onFocusChange: ((Bool) -> Void)?
    /// lmux: called on every key press / IME commit the user sends to this
    /// surface (one closure call; used to clear "needs input").
    public var onUserInput: (() -> Void)?
    /// lmux: the user pressed Esc (true) or Ctrl+C (false) here (keys that may stop the agent in the pane).
    public var onInterruptKey: ((_ esc: Bool) -> Void)?
    /// lmux: while non-nil, sees every key down first; returning true consumes it
    /// (set only while an lmux overlay such as a confirm card is up).
    public var keyInterceptor: ((NSEvent) -> Bool)?
    /// lmux: while lmux itself drives the program (Claude Code's rewind menu), the user's keys,
    /// IME text, pastes and mouse clicks / scrolls don't reach it (`sendKey` / `sendText` still do).
    public var inputHeld = false
    /// lmux: called for a plain Return key down (no modifiers), before the key goes on.
    public var onReturnKey: (() -> Void)?
    /// lmux: mouse moved over / left the surface (point in view coordinates, origin
    /// bottom-left). Drives the hover actions on Claude prompts.
    public var onMouseMove: ((NSPoint) -> Void)?
    public var onMouseExit: (() -> Void)?

    /// lmux: the preedit string last pushed to libghostty ("" when cleared).
    /// Exposed for the IME test harness.
    public private(set) var currentPreedit: String = ""

    private var markedText = NSMutableAttributedString()
    /// lmux: the input method's caret in `markedText` (UTF-16 offset; nil: none given).
    private var markedCaret: Int?
    /// lmux: the marked text left after an insertText that confirmed only part of it (see insertText),
    /// still shown, until the input method marks it again or the key event ends.
    private var unconfirmedRest: String?
    public private(set) var focused: Bool = true
    private var prevPressureStage: Int = 0
    private var contentSizeBacking: NSSize?
    private var contentSize: NSSize {
        get { contentSizeBacking ?? frame.size }
        set { contentSizeBacking = newValue }
    }

    // This is set to non-null during keyDown to accumulate insertText contents
    private var keyTextAccumulator: [String]?
    /// Temporary lead surrogate that's waiting for the trail
    private var leadSurrogate: LeadSurrogate?

    // True when we've consumed a left mouse-down only to move focus and
    // should suppress the matching mouse-up from being reported.
    private var suppressNextLeftMouseUp: Bool = false

    /// The pointer shape libghostty asked for (MOUSE_SHAPE: I-beam over text, pointing hand over a link).
    public private(set) var pointerCursor: NSCursor = .iBeam
    private var eventMonitor: Any?

    open override var acceptsFirstResponder: Bool { true }

    public init(app: ghostty_app_t, options: SurfaceOptions = .init()) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            self?.localEventHandler(event) ?? event
        }

        let surface = Self.withCValue(options, view: self) { cfg in
            ghostty_surface_new(app, &cfg)
        }
        guard let surface else {
            NSLog("lmux: ghostty_surface_new failed")
            return
        }
        self.surface = surface
        // The renderer sets the layer's contents (on the main queue) once per frame it draws.
        frameObservation = layer?.observe(\.contents) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onFrame?() }
        }
        terminalBackground = GhosttyRuntime.from(app)?.background
        updateTrackingAreas()
        registerForDraggedTypes(Array(Self.dropTypes))
    }

    // MARK: - Drag & drop (R18)

    public static let dropTypes: Set<NSPasteboard.PasteboardType> =
        Set([.string, .fileURL, .URL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })

    /// lmux: a drag is over this pane (true) or left / dropped (false): the pane shows a drop highlight.
    public var onDropTarget: ((Bool) -> Void)?

    open override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types, !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        onDropTarget?(true)
        return .copy
    }

    open override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types, !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy
    }

    open override func draggingExited(_ sender: NSDraggingInfo?) { onDropTarget?(false) }
    open override func draggingEnded(_ sender: NSDraggingInfo) { onDropTarget?(false) }

    open override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTarget?(false)
        if inputHeld { return false }
        // The pane you drop on is the pane you're working in now.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        return drop(sender.draggingPasteboard)
    }

    /// lmux: insert what was dropped (escaped file paths, text, or a dropped image's temp
    /// PNG path) as a paste, so it goes through the program's bracketed paste like ⌘V.
    /// A file promise (the screenshot thumbnail, Photos, Mail attachments) is received into
    /// lmux's private temp dir first and its path pasted when the file is there.
    @discardableResult
    public func drop(_ pb: NSPasteboard) -> Bool {
        if let text = PasteContents.dropString(from: pb) {
            DispatchQueue.main.async { [weak self] in self?.pasteText(text) }
            return true
        }
        let promises = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        guard !promises.isEmpty else { return false }
        PasteContents.receive(promises) { [weak self] urls in
            guard !urls.isEmpty else { return }
            self?.pasteText(urls.map { PasteContents.shellEscape($0.path) }.joined(separator: " "))
        }
        return true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let surface { ghostty_surface_free(surface) }
    }

    /// Free the surface now (e.g. when the window closes).
    public func close() {
        // lmux: drain the app mailbox first. A pane that just got a lot of output can have its IO
        // thread blocked pushing to a full mailbox (only the main thread empties it), and the free
        // below joins that thread: it would wait forever.
        if let surface, let app = ghostty_surface_app(surface) { ghostty_app_tick(app) }
        if let surface { ghostty_surface_free(surface) }
        surface = nil
    }

    private static func withCValue<T>(_ o: SurfaceOptions, view: SurfaceView,
                                      _ body: (inout ghostty_surface_config_s) -> T) -> T {
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(view).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = 0
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let keys = Array(o.environment.keys)
        let cKeys = keys.map { strdup($0) }
        let cVals = keys.map { strdup(o.environment[$0]!) }
        defer { (cKeys + cVals).forEach { free($0) } }
        var envs = zip(cKeys, cVals).map { ghostty_env_var_s(key: $0, value: $1) }

        return o.workingDirectory.withCStringOpt { wd in
            o.command.withCStringOpt { cmd in
                o.initialInput.withCStringOpt { input in
                    envs.withUnsafeMutableBufferPointer { buf in
                        config.working_directory = wd
                        config.command = cmd
                        config.initial_input = input
                        config.env_vars = buf.baseAddress
                        config.env_var_count = buf.count
                        return body(&config)
                    }
                }
            }
        }
    }

    // MARK: - Size / focus

    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeDidChange(newSize)
        updateTrackingAreas()
    }

    func sizeDidChange(_ size: CGSize) {
        let scaledSize = self.convertToBacking(size)
        setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
        contentSize = size
    }

    private func setSurfaceSize(width: UInt32, height: UInt32) {
        guard let surface = self.surface else { return }
        ghostty_surface_set_size(surface, width, height)
    }

    public var surfaceSize: ghostty_surface_size_s? {
        guard let surface else { return nil }
        return ghostty_surface_size(surface)
    }

    /// lmux: public so split panes that are not first responder can be marked
    /// unfocused (a new surface starts focused, like upstream).
    public func focusDidChange(_ focused: Bool) {
        guard let surface = self.surface else { return }
        guard self.focused != focused else { return }
        self.focused = focused
        if !focused { suppressNextLeftMouseUp = false }
        ghostty_surface_set_focus(surface, focused)
        onFocusChange?(focused)
    }

    /// lmux: tell libghostty whether the surface is visible (hidden workspaces
    /// stop rendering).
    public func setOcclusion(visible: Bool) {
        guard let surface else { return }
        occlusionVisible = visible
        ghostty_surface_set_occlusion(surface, visible)
        // lmux: hidden, libghostty frees its swap chain but the layer keeps showing (and holding)
        // the last frame's IOSurface. Let go of it; becoming visible draws a new frame right away.
        // Again on the next turn: a frame that was already in flight lands on the main queue.
        if !visible {
            layer?.contents = nil
            DispatchQueue.main.async { [weak self] in if self?.occlusionVisible == false { self?.layer?.contents = nil } }
        }
    }

    /// lmux: the cursor's bottom edge in view points from the top (one read under the terminal lock).
    public var cursorY: Double {
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        if let surface { ghostty_surface_ime_point(surface, &x, &y, &w, &h) }
        return y
    }

    /// lmux: the last value given to `setOcclusion` (surfaces start visible).
    public private(set) var occlusionVisible = true

    /// lmux: type `text` into the terminal as key input (not a paste);
    /// "\n" presses Return. Used by `lmux send`.
    public func sendText(_ text: String) {
        guard let surface else { return }
        var chunk = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chunk)
            chunk = ""
        }
        for ch in text {
            if ch == "\n" || ch == "\r" {
                flush()
                var ev = ghostty_input_key_s()
                ev.action = GHOSTTY_ACTION_PRESS
                ev.keycode = 0x24  // kVK_Return
                ev.mods = GHOSTTY_MODS_NONE
                ev.consumed_mods = GHOSTTY_MODS_NONE
                ev.composing = false
                ev.unshifted_codepoint = 0x0D
                _ = "\r".withCString { ptr in
                    ev.text = ptr
                    return ghostty_surface_key(surface, ev)
                }
                ev.action = GHOSTTY_ACTION_RELEASE
                ev.text = nil
                _ = ghostty_surface_key(surface, ev)
            } else {
                chunk.append(ch)
            }
        }
        flush()
    }

    // lmux: no TSM document access (see SurfaceInputContext: Korean IME first-jamo commit).
    private lazy var surfaceInputContext = SurfaceInputContext(client: self)
    open override var inputContext: NSTextInputContext? { surfaceInputContext }

    /// lmux: whether this surface's input context advertises TSM document access (tests;
    /// nil if it can't be read).
    public var inputContextAdvertisesDocumentAccess: Bool? { surfaceInputContext.advertisesDocumentAccess }

    /// lmux: like Ghostty (BaseTerminalController.syncFocusToSurfaceTree), a surface only has
    /// focus while its window is key: in the background no cursor blinks, so nothing redraws and
    /// the renderer releases its GPU memory. Headless windows are never key: they count as key.
    public var windowIsKey: Bool {
        GhosttyRuntime.headless ? !GhosttyRuntime.headlessBackground : window?.isKeyWindow ?? false
    }

    open override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusDidChange(windowIsKey) }
        return result
    }

    open override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange(false) }
        return result
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        updateColorScheme()
    }

    // lmux: report the effective appearance so `theme = light:X,dark:Y` follows it.
    open override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColorScheme()
    }

    private func updateColorScheme() {
        guard let surface else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    open override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        if let window = window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }

        // lmux: a view detached from its window (hidden workspace, split
        // rebuild) has no backing scale; keep the last one instead of
        // re-rasterizing at 1x.
        guard window != nil, let surface = self.surface else { return }

        let fbFrame = self.convertToBacking(self.frame)
        let xScale = fbFrame.size.width / self.frame.size.width
        let yScale = fbFrame.size.height / self.frame.size.height
        ghostty_surface_set_content_scale(surface, xScale, yScale)

        let scaledSize = self.convertToBacking(contentSize)
        setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
    }

    // MARK: - Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: cursor = .resizeUpDown
        default: return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pointerCursor = cursor
            self.window?.invalidateCursorRects(for: self)
        }
    }

    open override func resetCursorRects() {
        addCursorRect(bounds, cursor: pointerCursor)
    }

    // MARK: - Local events

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyUp: return localEventKeyUp(event)
        case .leftMouseDown: return localEventLeftMouseDown(event)
        default: return event
        }
    }

    private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window != nil, window == event.window else { return event }
        // lmux: hitTest expects the point in the content view's superview
        // coordinates; converting into a flipped content view (lmux's root) would
        // hit the wrong split pane.
        guard let contentView = window.contentView else { return event }
        let location = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard contentView.hitTest(location) == self else { return event }
        suppressNextLeftMouseUp = false
        guard window.firstResponder !== self else { return event }
        if NSApp.isActive && window.isKeyWindow {
            window.makeFirstResponder(self)
            suppressNextLeftMouseUp = true
            return nil
        }
        window.makeFirstResponder(self)
        return event
    }

    private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
        // Command keyUp events are never sent to the normal responder chain.
        if !event.modifierFlags.contains(.command) { return event }
        guard focused, window?.firstResponder === self else { return event }
        self.keyUp(with: event)
        return nil
    }

    // MARK: - Mouse

    open override func mouseDown(with event: NSEvent) {
        guard let surface = self.surface, !inputHeld else { return }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    open override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        prevPressureStage = 0
        guard let surface = self.surface, !inputHeld else { return }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    open override func otherMouseDown(with event: NSEvent) {
        guard let surface = self.surface, event.buttonNumber == 2, !inputHeld else { return }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods)
    }

    open override func otherMouseUp(with event: NSEvent) {
        guard let surface = self.surface, event.buttonNumber == 2, !inputHeld else { return }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods)
    }

    open override func rightMouseDown(with event: NSEvent) {
        if inputHeld { return }
        guard let surface = self.surface else { return super.rightMouseDown(with: event) }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) { return }
        super.rightMouseDown(with: event)
    }

    open override func rightMouseUp(with event: NSEvent) {
        if inputHeld { return }
        guard let surface = self.surface else { return super.rightMouseUp(with: event) }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        if ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods) { return }
        super.rightMouseUp(with: event)
    }

    open override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface else { return }
        let pos = self.convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Ghostty.ghosttyMods(event.modifierFlags))
    }

    open override func mouseExited(with event: NSEvent) {
        lastMousePoint = nil
        onMouseExit?()
        guard let surface else { return }
        if NSEvent.pressedMouseButtons != 0 { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Ghostty.ghosttyMods(event.modifierFlags))
    }

    open override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = self.convert(event.locationInWindow, from: nil)
        lastMousePoint = pos
        onMouseMove?(pos)
        if hoverURL != nil { onLinkHover?(hoverURL, pos) }
        if inputHeld { return }
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Ghostty.ghosttyMods(event.modifierFlags))
    }

    open override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    open override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    open override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    open override func scrollWheel(with event: NSEvent) {
        guard let surface, !inputHeld else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // We do a 2x speed multiplier. This is subjective, it "feels" better to me.
            x *= 2
            y *= 2
        }

        // ghostty_input_scroll_mods_t: bit 0 = precision, bits 1-3 = momentum phase.
        var mods: Int32 = precision ? 1 : 0
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(mods))
    }

    open override func pressureChange(with event: NSEvent) {
        guard let surface = self.surface, !inputHeld else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
        prevPressureStage = event.stage
    }

    // MARK: - Keyboard

    /// lmux: latency probe (tests only; nil in the app): called first thing in keyDown.
    public static var keyDownProbe: (() -> Void)?
    /// lmux: the user typed or pasted here at least once (an untouched first shell can give way to imported workspaces).
    public private(set) var hadUserInput = false

    open override func keyDown(with event: NSEvent) {
        Self.keyDownProbe?()
        hadUserInput = true
        if inputHeld { NSSound.beep(); return }
        // lmux: overlays (confirm cards) see the key first.
        if let k = keyInterceptor, k(event) { return }
        if event.keyCode == 0x24 || event.keyCode == 0x4C, let r = onReturnKey,
           event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) { r() }
        // lmux: Cmd shortcuts are not "typing into the pane".
        if !event.modifierFlags.contains(.command) {
            onUserInput?()
            // Ctrl+C by key code too (kVK_ANSI_C): with the Korean source the character is "ㅊ".
            if event.keyCode == 0x35 || (event.modifierFlags.contains(.control)
                                         && (event.keyCode == 8 || event.charactersIgnoringModifiers == "c")) {
                onInterruptKey?(event.keyCode == 0x35)
            }
        }
        guard let surface = self.surface else {
            self.interpretKeyEvents([event])
            return
        }

        // We need to translate the mods (maybe) to handle configs such as option-as-alt
        let translationModsGhostty = Ghostty.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                Ghostty.ghosttyMods(event.modifierFlags)
            )
        )

        // There are hidden bits set in our event that matter for certain dead keys
        // so we can't use translationModsGhostty directly. Instead, we just check
        // for exact states and set them.
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // If the translation modifiers are not equal to our original modifiers
        // then we need to construct a new NSEvent. If they are equal we reuse the
        // old one. IMPORTANT: we MUST reuse the old event if they're equal because
        // this keeps things like Korean input working. There must be some object
        // equality happening in AppKit somewhere because this is required.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.layoutCharacters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // By setting this to non-nil, we note that we're in a keyDown event. From here,
        // we call interpretKeyEvents so that we can handle complex input such as Korean
        // language.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // lmux: track whether AppKit dispatched a command selector for this key
        // after the input method saw it (see doCommand and the commit path below).
        commandsDispatchedDuringKeyDown = []

        // We need to know what the length of marked text was before this event to
        // know if these events cleared it.
        let markedTextBefore = markedText.length > 0

        // We need to know the keyboard layout before below because some keyboard
        // input events will change our keyboard layout and we don't want those
        // going to the terminal.
        let keyboardIdBefore: String? = if !markedTextBefore {
            KeyboardLayout.id
        } else {
            nil
        }

        // If we are in a keyDown then we don't need to redispatch a command-modded
        // key event (see docs for this field) so reset this to nil because
        // `interpretKeyEvents` may dispatch it.
        self.lastPerformKeyEvent = nil

        self.interpretKeyEvents([translationEvent])
        // lmux: the IME confirmed part of its marked text and didn't mark the rest again: it's committed.
        confirmUnconfirmedRest()

        // If our keyboard changed from this we just assume an input method
        // grabbed it and do nothing.
        if !markedTextBefore && keyboardIdBefore != KeyboardLayout.id {
            return
        }

        // If we have marked text, we're in a preedit state. The order we
        // do this and the key event callbacks below doesn't matter since
        // we control the preedit state only through the preedit API.
        syncPreedit(clearIfNeeded: markedTextBefore)

        // We're composing if we have preedit (the obvious case). But we're also
        // composing if we don't have preedit and we had marked text before,
        // because this input probably just reset the preedit state. It shouldn't
        // be encoded. Example: Japanese begin composing, then press backspace
        // or ctrl+h. This should only cancel the composing state but not
        // actually delete the prior input characters (prior to the composing).
        let composing = markedText.length > 0 || markedTextBefore

        // The input method may commit all or part of the preedit text via
        // insertText while handling a key that should not itself be
        // encoded. Send that committed text separately, then only replay
        // keys that should still affect the terminal after committing.
        if markedTextBefore,
           var list = keyTextAccumulator,
           list.count > 0 {
            // lmux: the macOS Korean IME commits the preedit and then lets the
            // key continue (AppKit calls doCommand: insertNewline:, noop: for
            // Cmd+key, cancelOperation:, moveLeft:, ...). Such a key was not
            // consumed by the IME, so it must still reach the terminal, after
            // the committed text. Upstream Ghostty only replays arrow keys
            // here, which swallows Enter / Shift+Enter / Esc / Cmd+T / Cmd+V
            // pressed while composing. IMEs that consume the key (e.g. Japanese
            // Enter to confirm a conversion) do not dispatch a command, so they
            // are unaffected.
            var replay = !commandsDispatchedDuringKeyDown.isEmpty
                || shouldReplayCommittedPreeditKey(translationEvent)

            // lmux: a bare Control key (Ctrl+C) while composing: the Korean IME commits the syllable
            // and hands the key's own control character back as text. It wasn't consumed, so the key
            // goes on after the commit (else Ctrl+C there only commits and never interrupts).
            if event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command),
               let last = list.last, last == event.characters, last.startsWithASCIIControlCharacter {
                list.removeLast()
                replay = true
            }

            // lmux: Backspace on the last jamo makes the Korean IME commit that
            // jamo and then send deleteBackward:. Apply the deletion to the text
            // being committed instead of sending "ㅎ" + DEL to the pty.
            if commandsDispatchedDuringKeyDown == [#selector(NSResponder.deleteBackward(_:))],
               let i = list.lastIndex(where: { !$0.isEmpty }) {
                list[i].removeLast()
                replay = false
            }

            for text in list where !text.isEmpty {
                if Self.shouldSuppressComposingControlInput(
                    text,
                    composing: composing
                ) {
                    continue
                }

                _ = committedTextAction(action, text: text)
            }

            if replay {
                // lmux: pass the key's text like the normal path does. With a
                // Korean input source the unshifted codepoint of Cmd+T is 'ㅅ',
                // so without the text "t" Ghostty cannot match the cmd+t binding.
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: translationEvent.ghosttyCharacters,
                    composing: false
                )
            }
            return
        }

        if let list = keyTextAccumulator, list.count > 0 {
            // Accumulated text from interpretKeyEvents (committed by the IME).
            for text in list {
                // Drop bare control characters the IME accumulated while
                // composing so they don't leak through to the terminal.
                if Self.shouldSuppressComposingControlInput(
                    text,
                    composing: composing
                ) {
                    continue
                }

                // We've composed a character; send it down. keyAction's
                // default composing=false applies because this is the
                // committed result of a composition, not in-progress preedit.
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text
                )
            }
        } else {
            // Raw control characters (e.g. ctrl+h) arriving during
            // composition belong to the IME, not the terminal.
            if Self.shouldSuppressComposingControlInput(
                event.characters,
                composing: composing
            ) {
                return
            }

            // lmux: an input method (Korean, Japanese, …) that hasn't answered yet. Its answer comes
            // a moment later through setMarkedText / insertText (both handled outside keyDown), but
            // the event's own characters are the input mode's (ㅎ for g with Korean 2-Set): sending
            // them would put a loose jamo in front of the composed text (하이 -> ㅎㅏ이). Keys an
            // IME passes on arrive through doCommand; Cmd / Ctrl keys take the normal path.
            if Self.awaitsInputMethod(event: translationEvent, inputMethodActive: inputMethodActive) {
                return
            }

            // We have no accumulated text so this is a normal key event.
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: translationEvent.ghosttyCharacters,
                composing: composing
            )
        }
    }

    /// lmux: the selected input source is an input method (not a plain keyboard layout).
    open var inputMethodActive: Bool {
        guard let id = inputContext?.selectedKeyboardInputSource else { return false }
        return id.contains(".inputmethod.")
    }

    /// lmux: an unanswered key whose own text is a loose Hangul jamo (the Korean input mode's
    /// key characters; kana or bopomofo of Kana Typing / Zhuyin alike) belongs to the IME, which
    /// delivers the composed text itself. Anything else (Latin keys of an IME in a pass-through
    /// mode or of Pinyin / Romaji, digits, punctuation) keeps the normal path.
    static func awaitsInputMethod(event: NSEvent, inputMethodActive: Bool) -> Bool {
        guard inputMethodActive, event.modifierFlags.isDisjoint(with: [.command, .control]),
              let chars = event.characters, !chars.isEmpty else { return false }
        return chars.unicodeScalars.allSatisfy { Ghostty.isInputMethodKeyCharacter($0.value) }
    }

    /// lmux: selectors AppKit dispatched via `doCommand(by:)` during the
    /// current `keyDown`'s `interpretKeyEvents` (i.e. keys the IME passed on).
    private var commandsDispatchedDuringKeyDown: [Selector] = []

    open override func keyUp(with event: NSEvent) {
        if inputHeld { return }
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// Records the timestamp of the last event to performKeyEquivalent that we need to save.
    /// See upstream SurfaceView_AppKit.swift for the full rationale.
    var lastPerformKeyEvent: TimeInterval?

    /// Special case handling for some control keys
    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // lmux: held input: no binding (⌘V paste…) reaches the program; the app's menu still answers.
        if inputHeld { return false }

        // Only process events if we're focused.
        if !focused { return false }

        // Get information about if this is a binding.
        let isBinding: Bool = surface.map { surface in
            var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
            return (event.characters ?? "").withCString { ptr in
                ghosttyEvent.text = ptr
                var flags = ghostty_binding_flags_e(0)
                return ghostty_surface_key_is_binding(surface, ghosttyEvent, &flags)
            }
        } ?? false

        // If this is a binding then we want to perform it.
        if isBinding {
            self.keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass C-<return> through verbatim
            // (prevent the default context menu equivalent)
            if !event.modifierFlags.contains(.control) {
                return false
            }

            equivalent = "\r"

        case "/":
            // Treat C-/ as C-_. We do this because C-/ makes macOS make a beep
            // sound and we don't like the beep sound.
            if !event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                return false
            }

            equivalent = "_"

        default:
            // It looks like some part of AppKit sometimes generates synthetic NSEvents
            // with a zero timestamp. We never process these at this point.
            if event.timestamp == 0 {
                return false
            }

            // Ignore all other non-command events. This lets the event continue
            // through the AppKit event systems.
            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                // Reset since we got a non-command event.
                lastPerformKeyEvent = nil
                return false
            }

            // If we have a prior command binding and the timestamp matches exactly
            // then we pass it through to keyDown for encoding.
            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        self.keyDown(with: finalEvent!)
        return true
    }

    open override func flagsChanged(with event: NSEvent) {
        if inputHeld { return }
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        // If we're in the middle of a preedit, don't do anything with mods.
        if hasMarkedText() { return }

        let mods = Ghostty.ghosttyMods(event.modifierFlags)

        // If the key that pressed this is active, its a press, else release.
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }

            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface = self.surface else { return false }

        var key_ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        key_ev.composing = composing

        if let text = text?.keyEventText {
            return text.withCString { ptr in
                key_ev.text = ptr
                return ghostty_surface_key(surface, key_ev)
            }
        } else {
            return ghostty_surface_key(surface, key_ev)
        }
    }

    private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: // arrow down, right, up
            return true
        case 0x7B: // arrow left
            // Don't replay plain left-arrow because AppKit already leaves
            // the caret in place after Korean IMEs commit preedit text.
            return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default:
            return false
        }
    }

    private func committedTextAction(
        _ action: ghostty_input_action_e,
        text: String
    ) -> Bool {
        guard let surface = self.surface else { return false }

        var key_ev = ghostty_input_key_s()
        key_ev.action = action
        key_ev.keycode = 0
        key_ev.text = nil
        key_ev.composing = false
        key_ev.mods = GHOSTTY_MODS_NONE
        key_ev.consumed_mods = GHOSTTY_MODS_NONE
        key_ev.unshifted_codepoint = 0

        return text.withCString { ptr in
            key_ev.text = ptr
            return ghostty_surface_key(surface, key_ev)
        }
    }

    // MARK: - Menu handlers

    @IBAction public func copy(_ sender: Any?) { _ = performBindingAction("copy_to_clipboard") }
    @IBAction public func paste(_ sender: Any?) {
        if inputHeld { NSSound.beep(); return }
        hadUserInput = true; _ = performBindingAction("paste_from_clipboard")
    }
    @IBAction open override func selectAll(_ sender: Any?) { _ = performBindingAction("select_all") }

    /// Perform a Ghostty keybind action such as `copy_to_clipboard`.
    @discardableResult
    public func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
    }

    /// lmux: press and release one key by virtual keycode (e.g. Esc 0x35, `c` 0x08
    /// with control for Ctrl-C, ↑ 0x7E with shift), encoded by libghostty like a real key press.
    public func sendKey(keyCode: UInt32, codepoint: UInt32, text: String? = nil, control: Bool = false, shift: Bool = false) {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.action = GHOSTTY_ACTION_PRESS
        ev.keycode = keyCode
        ev.mods = ghostty_input_mods_e(rawValue: (control ? GHOSTTY_MODS_CTRL.rawValue : 0) | (shift ? GHOSTTY_MODS_SHIFT.rawValue : 0))
        ev.consumed_mods = GHOSTTY_MODS_NONE
        ev.composing = false
        ev.unshifted_codepoint = codepoint
        if let text {
            _ = text.withCString { ptr in ev.text = ptr; return ghostty_surface_key(surface, ev) }
        } else {
            _ = ghostty_surface_key(surface, ev)
        }
        ev.action = GHOSTTY_ACTION_RELEASE
        ev.text = nil
        _ = ghostty_surface_key(surface, ev)
    }

    /// lmux: insert text as a paste (bracketed when the program asked for it).
    public func pasteText(_ text: String) {
        // A drop's text arrives a moment later: held input drops it too.
        guard let surface, !inputHeld else { return }
        hadUserInput = true
        let len = text.utf8CString.count
        guard len > 0 else { return }
        text.withCString { ptr in ghostty_surface_text(surface, ptr, UInt(len - 1)) }
    }

    /// lmux: pid of the pty's foreground process group (0 if unknown).
    public var foregroundPID: pid_t {
        guard let surface else { return 0 }
        return pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
    }

    /// lmux: Ghostty's own "closing this would kill something" check.
    /// lmux: the terminal has a selection (tests).
    public var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    public var needsConfirmQuit: Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// lmux: left offset of column 0 in points (window padding), learned from `viewportRows`.
    public private(set) var terminalPadding = CGSize(width: 14, height: 10)

    /// lmux: one visible row of the viewport.
    public struct Row {
        public let text: String
        /// Top of the row, in points from the top of the surface view.
        public let top: CGFloat
    }

    /// lmux: the viewport, row by row (soft-wrapped lines stay separate rows), with
    /// each row's position. Only called on demand (hover, overlay refresh).
    public func viewportRows() -> (rows: [Row], rowHeight: CGFloat) {
        guard let surface else { return ([], 0) }
        let size = ghostty_surface_size(surface)
        let cols = UInt32(max(1, size.columns)), n = Int(size.rows)
        let scale = max(1, window?.backingScaleFactor ?? layer?.contentsScale ?? 2)
        let rowH = CGFloat(size.cell_height_px) / scale
        var rows: [Row] = []
        rows.reserveCapacity(n)
        var firstTop: CGFloat?
        for y in 0..<n {
            var text = ghostty_text_s()
            let sel = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(y)),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: cols - 1, y: UInt32(y)),
                rectangle: false)
            var s = ""
            if ghostty_surface_read_text(surface, sel, &text) {
                // tl_px_y is the row's text baseline (points); the descent is ~22% of a cell.
                if firstTop == nil, text.tl_px_y >= 0 {
                    firstTop = CGFloat(text.tl_px_y) - rowH * 0.78 - CGFloat(y) * rowH
                    if text.tl_px_x >= 0 { terminalPadding.width = CGFloat(text.tl_px_x) }
                }
                if let p = text.text { s = String(cString: p) }
                ghostty_surface_free_text(surface, &text)
            }
            rows.append(Row(text: s, top: 0))
        }
        let top0 = firstTop ?? 0
        return (rows.enumerated().map { Row(text: $1.text, top: top0 + CGFloat($0) * rowH) }, rowH)
    }

    /// The word under the pointer (Ghostty's Quick Look word; its selection-word-chars split it).
    public func wordUnderMouse() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return text.text.map { String(cString: $0) }
    }

    /// Read text from the viewport (no scrollback) or the whole screen.
    public func readText(viewportOnly: Bool = true) -> String {
        guard let surface else { return "" }
        let tag = viewportOnly ? GHOSTTY_POINT_VIEWPORT : GHOSTTY_POINT_SCREEN
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// lmux: a hash of the active screen's text (the bottom rows, wherever the user scrolled):
    /// changes with output, not with a cursor blink, focus, selection or scrolling. libghostty keeps
    /// the terminal up to date while the pane is hidden, so this sees output no frame shows.
    public func activeTextHash() -> Int {
        guard let surface else { return 0 }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return 0 }
        defer { ghostty_surface_free_text(surface, &text) }
        var h = Hasher()
        h.combine(String(cString: text.text))
        return h.finalize()
    }

    /// lmux: scrollback + screen as plain text, at most the last `rows` rows (the whole buffer when
    /// its size isn't known yet).
    public func screenText(rows: Int) -> String {
        guard let surface else { return "" }
        let total = scrollbar.map { Int($0.total) } ?? 0
        guard total > rows else { return readText(viewportOnly: false) }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(total - rows)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return readText(viewportOnly: false) }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// lmux: show `text` in the terminal as if the pane's program had printed it: written to the
    /// pty's terminal side, so the program never reads it as input. The pty opens on libghostty's
    /// IO thread just after the surface is made: waited for up to `timeout`.
    @discardableResult
    public func printOutput(_ text: String, timeout: TimeInterval = 1) -> Bool {
        guard let surface else { return false }
        var tty = ""
        let end = Date().addingTimeInterval(timeout)
        while tty.isEmpty {
            let s = ghostty_surface_tty_name(surface)
            if let p = s.ptr, s.len > 0 { tty = String(decoding: UnsafeRawBufferPointer(start: p, count: Int(s.len)), as: UTF8.self) }
            ghostty_string_free(s)
            if tty.isEmpty {
                guard Date() < end else { return false }
                usleep(500)
            }
        }
        if !tty.hasPrefix("/") { tty = "/dev/" + tty }
        let fd = Darwin.open(tty, O_WRONLY | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        // Off the main thread: a write blocks until libghostty's IO thread drains the pty, which
        // may itself wait for the main thread (its mailbox).
        let bytes = Array(text.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { Darwin.close(fd) }
            bytes.withUnsafeBytes { buf in
                var off = 0
                while off < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return }
                }
            }
        }
        return true
    }

    // MARK: - NSTextInputClient

    open func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    open func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length-1))
    }

    open func selectedRange() -> NSRange {
        guard let surface = self.surface else { return NSRange() }

        // Get our range from the Ghostty API. There is a race condition between getting the
        // range and actually using it since our selection may change but there isn't a good
        // way I can think of to solve this for AppKit.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let incoming: NSAttributedString
        switch string {
        case let v as NSAttributedString:
            incoming = v

        case let v as String:
            incoming = NSAttributedString(string: v)

        default:
            // Never logged: it is what the user is typing.
            return
        }
        // lmux: after a partial insertText (see there), new marked text that isn't the rest again,
        // given as a new composition (no replacementRange), means the IME took the rest as confirmed.
        if let rest = unconfirmedRest, replacementRange.location == NSNotFound, !incoming.string.hasPrefix(rest) {
            confirmUnconfirmedRest()
        }
        unconfirmedRest = nil
        // lmux: replacementRange is relative to the marked text. The Japanese IME's Backspace in a
        // conversion replaces one character of it with "" (日本語 → 日本): keep the rest
        // (manaflow-ai/cmux#13416). Anything else replaces the whole preedit, as before.
        var start = 0
        if let r = Self.partialMarkedRange(replacementRange, markedLength: markedText.length) {
            markedText.replaceCharacters(in: r, with: incoming)
            start = r.location
        } else {
            markedText = NSMutableAttributedString(attributedString: incoming)
        }
        // lmux: the IME's caret in the marked text (UTF-16), relative to what it just inserted.
        markedCaret = selectedRange.location == NSNotFound || selectedRange.length > 0
            ? nil : start + min(selectedRange.location, incoming.length)

        // If we're not in a keyDown event, then we want to update our preedit
        // text immediately. This can happen due to external events, for example
        // changing keyboard layouts while composing: (1) set US intl (2) type '
        // to enter dead key state (3)
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    open func unmarkText() {
        // lmux: the rest a partial insertText left marked is text the IME confirmed: commit it, as
        // NSTextView's unmarkText keeps marked text.
        if let rest = unconfirmedRest {
            unconfirmedRest = nil
            markedText.mutableString.setString("")
            syncPreedit()
            sendCommittedText(rest)
            return
        }
        if self.markedText.length > 0 {
            self.markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    open func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    open func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface = self.surface else { return nil }

        // If the range is empty then we don't need to return anything
        guard range.length > 0 else { return nil }

        // Get our selection text
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        var attributes: [ NSAttributedString.Key: Any ] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            // Memory management here is wonky: ghostty_surface_quicklook_font
            // will create a copy of a CTFont, Swift will auto-retain the
            // unretained value passed into the dict, so we release the original.
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return .init(string: String(cString: text.text), attributes: attributes)
    }

    open func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    open func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = self.surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Ghostty will tell us where it thinks an IME keyboard should render.
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height

        // QuickLook never gives us a matching range to our selection so if we detect
        // this then we return the top-left selection point rather than the cursor point.
        // This is hacky but I can't think of a better way to get the right IME vs. QuickLook
        // point right now. I'm sure I'm missing something fundamental...
        // lmux: while composing the range is inside the marked text (Pinyin and Japanese IMEs ask for
        // the whole preedit or the clause being converted): always the cursor, never a selection on screen.
        if markedText.length > 0 {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            let u = Array(markedText.string.utf16), start = min(range.location, u.count)
            let end = min(start + min(range.length, u.count), u.count)
            x += cellSize.width * Double(Self.displayCells(String(decoding: u[..<start], as: UTF16.self)))
            width = cellSize.width * Double(Self.displayCells(String(decoding: u[start..<end], as: UTF16.self)))
        } else if range.length > 0 && range != self.selectedRange() {
            // QuickLook
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                // The -2/+2 here is subjective. QuickLook seems to offset the rectangle
                // a bit and I think these small adjustments make it look more natural.
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2

                // Free our text
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }
        if range.length == 0, width > 0 {
            // This fixes #8493 while speaking
            // My guess is that positive width doesn't make sense
            // for the dictation microphone indicator
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        // Ghostty coordinates are in top-left (0, 0) so we have to convert to
        // bottom-left since that is what AppKit expects
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, cellSize.height))

        // Convert the point to the window coordinates
        let winRect = self.convert(viewRect, to: nil)

        // Convert from view to screen coordinates
        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    open func insertText(_ string: Any, replacementRange: NSRange) {
        // We must have an associated event
        guard NSApp.currentEvent != nil, !inputHeld else { return }

        // We want the string view of the any value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as NSString:
            if let leadSurrogate = LeadSurrogate(v) {
                self.leadSurrogate = leadSurrogate
                chars = ""
            } else if let trail = TrailSurrogate(v) {
                // We ignore trail surrogate without a lead like Terminal.app.
                chars = leadSurrogate?.encode(trail: trail) ?? ""
                leadSurrogate = nil
            } else {
                chars = v as String
                leadSurrogate = nil
            }
        default:
            return
        }

        // lmux: a replacementRange inside part of the marked text confirms that part (an IME confirming
        // the clause 日本 of 日本語 as 二本): the marked text before it and the string are committed, and
        // what follows (語) stays marked. An IME that marks it again right after (setMarkedText("語"))
        // gets it back without "語" being typed twice; one that treats it as confirmed, as NSTextView
        // does, gets it committed when the key event ends, so it isn't lost either. A range outside the
        // marked text is text already in the terminal, which can't be edited: the string is sent as is.
        var rest = ""
        if let r = Self.partialMarkedRange(replacementRange, markedLength: markedText.length) {
            let m = markedText.string as NSString
            chars = m.substring(to: r.location) + chars
            rest = m.substring(from: NSMaxRange(r))
        } else if replacementRange.location == NSNotFound, let pending = unconfirmedRest {
            // The rest was confirmed text to this IME: it goes first.
            chars = pending + chars
        }
        unconfirmedRest = nil

        // If insertText is called, our preedit must be over.
        unmarkText()

        if !rest.isEmpty {
            markedText = NSMutableAttributedString(string: rest)
            markedCaret = nil
            unconfirmedRest = rest
            if keyTextAccumulator == nil {
                syncPreedit()
                DispatchQueue.main.async { [weak self] in self?.confirmUnconfirmedRest() }
            }
        }
        sendCommittedText(chars)
    }

    /// lmux: `replacementRange` when it is a part of the marked text (not all of it): a range with
    /// characters, or an insertion point strictly inside it. An empty range at either end is what an
    /// IME passes for "the caret" or `selectedRange()` (which is {0, 0} with no selection), so it
    /// keeps meaning the whole marked text, as in upstream Ghostty: reading it as an insertion would
    /// turn 하 + 한 into "한하".
    static func partialMarkedRange(_ r: NSRange, markedLength n: Int) -> NSRange? {
        guard n > 0, r.location != NSNotFound, NSMaxRange(r) <= n, !(r.location == 0 && r.length == n) else { return nil }
        return r.length > 0 || (r.location > 0 && r.location < n) ? r : nil
    }

    /// lmux: commits the rest an insertText left marked (see insertText), if the IME didn't mark it again.
    private func confirmUnconfirmedRest() {
        if unconfirmedRest != nil { unmarkText() }
    }

    private func sendCommittedText(_ chars: String) {
        // If we have an accumulator we're in another key event so we just
        // accumulate and return.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // All committed text (IME, dictation, etc.) must be sent as key
        // events so programs treat it as typed input, never as a paste.
        if !chars.isEmpty {
            onUserInput?()
            _ = committedTextAction(GHOSTTY_ACTION_PRESS, text: chars)
        }
    }

    /// This function needs to exist for two reasons:
    /// 1. Prevents an audible NSBeep for unimplemented actions.
    /// 2. Allows us to properly encode super+key input events that we don't handle
    open override func doCommand(by selector: Selector) {
        if keyTextAccumulator != nil { commandsDispatchedDuringKeyDown.append(selector) }

        // If we are being processed by performKeyEquivalent with a command binding,
        // we send it back through the event system so it can be encoded.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    /// lmux: terminal cells `s` takes (East Asian wide characters and emoji 2, others 1), for the IME's
    /// candidate window inside a preedit like "日本語" or "你好".
    static func displayCells(_ s: String) -> Int {
        s.reduce(0) { n, ch in
            guard let v = ch.unicodeScalars.first?.value else { return n }
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v)
            return n + (wide ? 2 : 1)
        }
    }

    /// Sync the preedit state based on the markedText value to libghostty
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                // lmux: a caret inside the preedit (moving through a composition with the arrow
                // keys) is drawn there (manaflow-ai/cmux#1521); libghostty skips it at either end.
                let caret = markedCaret.map { String(decoding: Array(str.utf16.prefix($0)), as: UTF16.self).utf8.count }
                markedText.string.withCString { ptr in
                    // Subtract 1 for the null terminator
                    if let caret {
                        ghostty_surface_preedit_caret(surface, ptr, UInt(len - 1), UInt(caret))
                    } else {
                        ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                    }
                }
                currentPreedit = str
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
            currentPreedit = ""
        }
    }

    /// True when `text` is a single C0 control character (U+0000-U+001F)
    /// arriving while the IME is composing. Such input belongs to the IME
    /// and must not be forwarded to the terminal.
    static func shouldSuppressComposingControlInput(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }
}

extension SurfaceView: NSMenuItemValidation {
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        default:
            return true
        }
    }
}

private extension Optional where Wrapped == String {
    func withCStringOpt<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        switch self {
        case .some(let s): return s.withCString { body($0) }
        case .none: return body(nil)
        }
    }
}

/// Check if a UTF16 text is a single lead surrogate character
struct LeadSurrogate {
    let char: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let char = text.character(at: 0)
        guard UTF16.isLeadSurrogate(char) else { return nil }
        self.char = char
    }

    func encode(trail: TrailSurrogate) -> String {
        String(decoding: [char, trail.char], as: UTF16.self)
    }
}

/// Check if a UTF16 text is a single trail surrogate character
struct TrailSurrogate {
    let char: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let char = text.character(at: 0)
        guard UTF16.isTrailSurrogate(char) else { return nil }
        self.char = char
    }
}
