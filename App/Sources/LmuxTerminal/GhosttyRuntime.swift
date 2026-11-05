// Adapted from Ghostty (https://github.com/ghostty-org/ghostty) at commit ff23824:
//   macos/Sources/Ghostty/Ghostty.App.swift (runtime callbacks, clipboard, actions)
//   macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift (ghostty(_:))
// Trimmed to what a single-window spike needs.
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT License.
// See THIRD_PARTY_NOTICES.md.

import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// Owns the `ghostty_app_t` and implements the libghostty runtime callbacks.
public final class GhosttyRuntime {
    public private(set) var app: ghostty_app_t?
    public private(set) var config: ghostty_config_t?

    /// Observer for every action libghostty asks the host to perform. Used by
    /// tests (e.g. Cmd+T -> new_tab) and for logging.
    public var onAction: ((ghostty_action_tag_e, SurfaceView?) -> Void)?

    /// Called when a surface asks to be closed (e.g. the shell exited).
    /// lmux: second argument is libghostty's `processAlive` (true = closing would kill a process).
    public var onCloseSurface: ((SurfaceView, Bool) -> Void)?

    /// lmux: host handler consulted before the built-in handling. Return nil to
    /// fall through, or whether the action was performed. Runs on the thread
    /// libghostty calls from; copy any C strings before going async.
    public var actionHandler: ((ghostty_target_s, ghostty_action_s, SurfaceView?) -> Bool?)?

    private var appearanceObserver: NSKeyValueObservation?

    /// Terminal background of the app-level (theme-resolved) config. New
    /// surfaces start with this; per-surface changes arrive via CONFIG_CHANGE.
    public internal(set) var background: NSColor?

    static func background(of cfg: ghostty_config_t) -> NSColor? {
        var c = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(cfg, &c, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    static func from(_ app: ghostty_app_t) -> GhosttyRuntime? { runtime(app) }

    /// The default-font profile this runtime loads its config with (also on reloads).
    public let fontProfile: LmuxConfig.FontProfile

    public init?(simulatedUserConfig: [String] = [], fontProfile: LmuxConfig.FontProfile? = nil) {
        let profile = fontProfile ?? LmuxConfig.resolveFontProfile()
        self.fontProfile = profile
        guard let config = LmuxConfig.load(simulatedUserConfig: simulatedUserConfig,
                                           fontProfile: profile) else { return nil }
        self.config = config

        var runtime_cfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
            action_cb: { app, target, action in GhosttyRuntime.action(app!, target: target, action: action) },
            read_clipboard_cb: { userdata, loc, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(userdata, location: loc, state: state,
                                             mimes: mimes, mimesLen: mimesLen, list: list) },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, confirm: confirm, state: state, request: request) },
            write_clipboard_cb: { userdata, loc, content, len, confirm in
                GhosttyRuntime.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm) },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive) }
        )

        guard let app = ghostty_app_new(&runtime_cfg, config) else {
            NSLog("lmux: ghostty_app_new failed")
            return nil
        }
        self.app = app
        self.background = Self.background(of: config)
        ghostty_app_set_focus(app, NSApp.isActive)

        // Report the app appearance so `theme = light:X,dark:Y` resolves.
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new, .initial]) { [weak self] app, _ in
            guard let ghostty = self?.app else { return }
            let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ghostty_app_set_color_scheme(ghostty, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        }

        let center = NotificationCenter.default
        center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_keyboard_changed(app) }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            if let app = self?.app { ghostty_app_set_focus(app, false) }
        }
    }

    /// Re-read every config file and apply it to the app and all surfaces (libghostty answers
    /// with CONFIG_CHANGE), as Ghostty's reload_config does. `overrides` load last (theme preview).
    @discardableResult
    public func reloadConfig(overrides: [String] = []) -> Bool {
        guard let app, let fresh = LmuxConfig.load(fontProfile: fontProfile, overrides: overrides) else { return false }
        if let old = config { ghostty_config_free(old) }
        config = fresh
        ghostty_app_update_config(app, fresh)
        background = Self.background(of: fresh)
        return true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: Callbacks

    static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        let state = Unmanaged<GhosttyRuntime>.fromOpaque(userdata!).takeUnretainedValue()
        // Wakeup can be called from any thread so we schedule the tick on main.
        DispatchQueue.main.async { state.tick() }
    }

    private static func runtime(_ app: ghostty_app_t) -> GhosttyRuntime? {
        guard let ud = ghostty_app_userdata(app) else { return nil }
        return Unmanaged<GhosttyRuntime>.fromOpaque(ud).takeUnretainedValue()
    }

    private static func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView {
        Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
    }

    private static func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
        guard let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        let view = surfaceUserdata(from: userdata)
        DispatchQueue.main.async {
            guard let surface = view.surface, let app = ghostty_surface_app(surface),
                  let rt = runtime(app) else { return }
            rt.onCloseSurface?(view, processAlive)
        }
    }

    static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        var view: SurfaceView?
        if target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface {
            view = surfaceView(from: s)
        }
        let rt = runtime(app)
        defer { rt?.onAction?(action.tag, view) }
        if let handled = rt?.actionHandler?(target, action, view) { return handled }

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let cstr = action.action.set_title.title,
                  let title = String(cString: cstr, encoding: .utf8) else { return false }
            view.titleArrived(title)
            return true

        case GHOSTTY_ACTION_PROGRAM_STATUS:
            guard let view else { return false }
            let v = action.action.program_status
            let state: SurfaceView.ProgramStatus.State
            switch v.state {
            case GHOSTTY_PROGRAM_STATUS_IDLE: state = .idle
            case GHOSTTY_PROGRAM_STATUS_WORKING: state = .working
            case GHOSTTY_PROGRAM_STATUS_DONE: state = .done
            case GHOSTTY_PROGRAM_STATUS_BLOCKED: state = .blocked
            case GHOSTTY_PROGRAM_STATUS_ERROR: state = .error
            default: state = .clear
            }
            let kind: String?
            switch v.kind {
            case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: kind = "permission"
            case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: kind = "question"
            case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: kind = "auth"
            default: kind = nil
            }
            let app = withUnsafeBytes(of: v.app) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let status = SurfaceView.ProgramStatus(state: state, kind: kind, app: app, at: Date())
            DispatchQueue.main.async { view.onProgramStatus?(status) }
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view else { return false }
            let v = action.action.cell_size
            let backing = NSSize(width: Double(v.width), height: Double(v.height))
            DispatchQueue.main.async { view.cellSize = view.convertFromBacking(backing) }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursorShape(action.action.mouse_shape)
            return true

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            // As Ghostty.App.setMouseOverLink: an empty URL means the pointer left the link.
            guard let view else { return false }
            let v = action.action.mouse_over_link
            let url = v.len > 0 && v.url != nil
                ? String(data: Data(bytes: v.url!, count: Int(v.len)), encoding: .utf8) : nil
            DispatchQueue.main.async { view.hoverURL = url }
            return true

        case GHOSTTY_ACTION_SCROLLBAR:
            guard let view else { return false }
            let v = action.action.scrollbar
            let sb = SurfaceView.Scrollbar(total: v.total, offset: v.offset, len: v.len)
            DispatchQueue.main.async { view.scrollbar = sb }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            view?.window?.performClose(nil)
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let v = action.action.open_url
            guard let ptr = v.url else { return false }
            let data = Data(bytes: ptr, count: Int(v.len))
            guard let str = String(data: data, encoding: .utf8) else { return false }
            let kind = v.kind
            // Runs with the renderer mutex held: decide and present on the next main-loop turn.
            DispatchQueue.main.async {
                // The text under the pointer: an OSC 8 label that reads as another address is asked about.
                let label = kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 ? view?.wordUnderMouse() : nil
                openTerminalURL(str, kind: kind, window: view?.window, label: label)
            }
            // Always handled: false would make the core retry with its unrestricted opener.
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // Soft reloads re-apply the current config with the surface/app
            // conditional state (e.g. light/dark theme); hard reloads re-read
            // the config files. libghostty answers with CONFIG_CHANGE.
            guard let rt else { return false }
            if !action.action.reload_config.soft, let fresh = LmuxConfig.load(fontProfile: rt.fontProfile) {
                if let old = rt.config { ghostty_config_free(old) }
                rt.config = fresh
            }
            guard let cfg = rt.config else { return false }
            if target.tag == GHOSTTY_TARGET_SURFACE, let s = target.target.surface {
                ghostty_surface_update_config(s, cfg)
            } else {
                ghostty_app_update_config(app, cfg)
            }
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // Theme-resolved colors changed (e.g. light/dark switch). Read the
            // background now: the config pointer is only valid during the callback.
            guard let cfg = action.action.config_change.config,
                  let color = background(of: cfg) else { return true }
            if let view {
                DispatchQueue.main.async { view.terminalBackground = color }
            } else {
                rt?.background = color
            }
            return true

        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW:
            // Tabs/windows are out of scope for the P0 spike; report as handled
            // so the binding is consumed (and observable via onAction).
            return true

        default:
            return false
        }
    }

    /// lmux: how an opened link (⌘-click, OPEN_URL) is handed to the system. Tests swap it so
    /// nothing is ever opened for real.
    public static var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// lmux: headless runs (tests, renders) never present an alert or sheet: no display may show one.
    public static var headless = false
    /// lmux: LMUX_HEADLESS_BACKGROUND=1: the headless window counts as not key (lmux in the
    /// background: surfaces unfocused, no cursor blink), for memory and idle budgets.
    public static let headlessBackground = ProcessInfo.processInfo.environment["LMUX_HEADLESS_BACKGROUND"] == "1"

    /// OPEN_URL as Ghostty.App.openURL does it: targets from terminal output (OSC 8 links and
    /// ⌘-clicked text, `unknown`) go through the UntrustedURL policy (web / mail / a plain local
    /// file open directly, other schemes ask first, executables and deceptive targets are
    /// blocked); config files (`text`) and lmux's own pages (`html`) open as before.
    public static func openTerminalURL(_ value: String, kind: ghostty_action_open_url_kind_e, window: NSWindow?,
                                       label: String? = nil) {
        if kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 {
            UntrustedURLAlert.open(value, window: window, label: label)
            return
        }
        // No valid scheme: a file path (~ expanded), as in Ghostty.
        let url: URL
        if let candidate = URL(string: value), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(filePath: NSString(string: value).standardizingPath)
        }
        if kind == GHOSTTY_ACTION_OPEN_URL_KIND_TEXT || kind == GHOSTTY_ACTION_OPEN_URL_KIND_HTML {
            openURL(url)
            return
        }
        // Unknown targets may be plain paths, which UntrustedURL rejects: check the file URL built
        // above. Values with unsafe characters go unchanged so percent-encoding can't hide them.
        let hasScheme = URL(string: value)?.scheme != nil
        UntrustedURLAlert.open(hasScheme || UntrustedURL.containsUnsafeCharacters(value) ? value : url.absoluteString,
                               window: window)
    }

    /// A config value of enum type (e.g. `scrollbar`: "system" / "never").
    static func enumValue(_ cfg: ghostty_config_t, _ key: String) -> String? {
        var v: UnsafePointer<Int8>?
        guard ghostty_config_get(cfg, &v, key, UInt(key.lengthOfBytes(using: .utf8))), let v else { return nil }
        return String(cString: v)
    }

    /// Ghostty's `scrollbar` setting: false for `never` (no scroller, like Ghostty).
    public var showsScrollbar: Bool {
        guard let config else { return true }
        return Self.enumValue(config, "scrollbar") != "never"
    }

    // MARK: Clipboard

    /// lmux: the clipboard copy/paste use. Tests swap in a private named pasteboard so
    /// they never touch the user's clipboard.
    public static var standardPasteboard: NSPasteboard = .general

    static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return standardPasteboard
        case GHOSTTY_CLIPBOARD_SELECTION: return NSPasteboard(name: .init("com.mitchellh.ghostty.selection"))
        default: return nil
        }
    }

    static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        let view = surfaceUserdata(from: userdata)
        guard let surface = view.surface, let pb = pasteboard(location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        // lmux: text/plain the way Ghostty serves it (copied files = escaped paths), plus an
        // image on the clipboard as the path of a temp PNG (R18; Claude Code attaches it).
        var contents: [(String, Data)] = []
        let wantsText = mimes.map { m in (0..<mimesLen).contains { m[$0].map { String(cString: $0) } == "text/plain" } } ?? false
        if wantsText, let str = PasteContents.string(from: pb) {
            contents.append(("text/plain", Data(str.utf8)))
        }
        let available: [String] = list && PasteContents.hasContents(pb) ? ["text/plain"] : []
        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }

        complete(surface, contents: contents, available: available, state: state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        let view = surfaceUserdata(from: userdata)
        guard let surface = view.surface else { return }
        // Headless: nobody to ask and nothing may be shown; denied.
        guard let confirm, !headless else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        let c = confirm.pointee
        var reps: [(String, Data)] = []
        if let contents = c.contents {
            for i in 0..<c.contents_len {
                let item = contents[i]
                let data = item.len > 0 ? Data(bytes: item.data, count: item.len) : Data()
                reps.append((String(cString: item.mime), data))
            }
        }
        let text = reps.first { $0.0 == "text/plain" }.flatMap { String(data: $0.1, encoding: .utf8) } ?? ""

        // Minimal stand-in for Ghostty's clipboard confirmation window.
        DispatchQueue.main.async {
            let alert = clipboardConfirmation(request: request, text: text)
            if alert.runModal() == .alertFirstButtonReturn {
                complete(surface, contents: reps, available: [], state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
        }
    }

    /// The confirmation for a clipboard request; the first button allows. A program asking to
    /// READ the clipboard (OSC 52 / kitty) gets Cancel as the default button, so a stray Return
    /// denies it; an unsafe paste the user started keeps Allow as the default.
    public static func clipboardConfirmation(request: ghostty_clipboard_request_e, text: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
            ? "Paste potentially unsafe text?" : "Allow clipboard access?"
        alert.informativeText = String(text.prefix(1000))
        let allow = alert.addButton(withTitle: "Allow")
        let cancel = alert.addButton(withTitle: "Cancel")
        if request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ || request == GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ {
            allow.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
        }
        return alert
    }

    private static func complete(
        _ surface: ghostty_surface_t,
        contents: [(String, Data)],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var cDatas: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            cDatas.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for (mime, data) in contents {
            guard let m = strdup(mime) else { continue }
            cStrings.append(m)
            let buf = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
            cDatas.append(buf)
            data.withUnsafeBytes { src in
                if let base = src.baseAddress { buf.copyMemory(from: base, byteCount: src.count) }
            }
            cContents.append(ghostty_clipboard_content_s(
                mime: m, data: buf.assumingMemoryBound(to: CChar.self), len: data.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let s = strdup(mime) else { continue }
            cStrings.append(s)
            cAvailable.append(UnsafePointer(s))
        }

        cContents.withUnsafeBufferPointer { contentsBuf in
            cAvailable.withUnsafeBufferPointer { availableBuf in
                var done = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress,
                    contents_len: contentsBuf.count,
                    available: availableBuf.baseAddress,
                    available_len: availableBuf.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &done, state)
            }
        }
    }

    static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let pb = pasteboard(location), let content, len > 0 else { return }
        // OSC 52 writes that require confirmation are denied in the spike.
        guard !confirm else { return }
        let items: [(NSPasteboard.PasteboardType, Data)] = (0..<len).compactMap { i in
            let c = content[i]
            guard let mime = c.mime, let data = c.data else { return nil }
            let m = String(cString: mime)
            let type: NSPasteboard.PasteboardType? = m == "text/plain" ? .string
                : NSPasteboard.PasteboardType(mimeType: m)
            guard let type else { return nil }
            return (type, Data(bytes: data, count: c.len))
        }
        guard !items.isEmpty else { return }
        pb.declareTypes(items.map(\.0), owner: nil)
        for (type, data) in items { pb.setData(data, forType: type) }
    }
}

private extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        guard let ut = UTType(mimeType: mimeType) else { return nil }
        self.init(ut.identifier)
    }
}
