import AppKit
import Carbon
import GhosttyKit
import LmuxHooks
import LmuxTerminal
import LmuxTokens
import Security
import SwiftUI

private typealias T = LmuxTokens

/// The single lmux window: sidebar of workspaces, each a split tree of
/// libghostty surfaces. Owns agent awareness, persistence and the CLI socket.
@MainActor
public final class LmuxController: NSObject, NSWindowDelegate {
    public let runtime: GhosttyRuntime
    public let model = AppModel()
    public let paths: LmuxPaths
    public let headless: Bool
    public private(set) var window: LmuxWindow!
    public let notifier: Notifier
    var root: RootView!

    /// Tests: treat the app as active/key (headless never is).
    public var assumeAppActive = false
    /// Tests: a headless window with the real titled chrome (toolbar, traffic lights, the titlebar
    /// view the buttons live in), ordered in off screen like the borderless one (never on a display).
    static var headlessTitled = false

    private var panesByID: [String: Pane] = [:]
    /// Per-pane secret (`LMUX_PANE_NONCE` in the pane's environment) -> pane id. Identifies
    /// which pane a CLI call comes from; pane ids are not secret (they're in every hook).
    private var paneIDByToken: [String: String] = [:]
    /// Where lmux's settings are read (tests: a temp suite).
    public var defaults = UserDefaults.standard
    /// `lmux send` from inside one pane into another (off unless the user turns it on:
    /// `defaults write dev.lmux.app allowCrossPaneSend -bool true`). Read at every send, so
    /// the setting applies without relaunching lmux.
    public var allowCrossPaneSend: Bool { defaults.bool(forKey: "allowCrossPaneSend") }
    /// `lmux send` / `lmux new-workspace --cmd` from outside lmux (no valid pane token): off unless
    /// the user turns it on (`defaults write dev.lmux.app allowExternalSend -bool true`, read at
    /// every request), or lmux was started with LMUX_ALLOW_EXTERNAL_SEND=1 (scripts/bench.sh, tests).
    public var allowExternalSend: Bool { defaults.bool(forKey: "allowExternalSend") || allowExternalSendAtLaunch }
    public var allowExternalSendAtLaunch = ProcessInfo.processInfo.environment["LMUX_ALLOW_EXTERNAL_SEND"] == "1"
    /// `lmux notify` rate limit per pane: at most one notification per window, extra ones
    /// coalesced into one at the end of it (latest text wins).
    public var notifyInterval: TimeInterval = 5
    var notifyGate: [String: (last: Date, pending: (text: String, title: String?)?, work: DispatchWorkItem?)] = [:]
    private var panesBySurface: [ObjectIdentifier: Pane] = [:]
    private var accentCounter = 0
    var hookServer: HookSocketServer?
    var controlServer: ControlServer?
    var saveWork: DispatchWorkItem?
    /// Persistence is off until restore finished (so restore doesn't save half a layout).
    var persistenceEnabled = false

    /// Where Copy original writes (the terminal's clipboard; tests use a private one).
    public var pasteboard = GhosttyRuntime.standardPasteboard
    /// Languages of the current keyboard input source (Return handling; tests swap it).
    var inputSourceLanguages: () -> [String] = LmuxController.currentInputSourceLanguages
    /// What rewind / undo did, step by step (tests and debugging; bounded).
    var actionLog: [String] = []
    func log(_ s: String) {
        actionLog.append(s)
        if actionLog.count > 200 { actionLog.removeFirst(actionLog.count - 200) }
    }
    /// Test tap: every hook event as received (e2e instrumentation).
    var hookTap: ((HookEvent) -> Void)?
    /// How long a claude may run in a pane without a hook event before the hooks hint (tests: shorter).
    var hooksHintDelay: TimeInterval = 10
    /// Tests: where to look for other Claude config dirs instead of the home folder.
    var claudeConfigCandidatesOverride: [URL]?
    /// The undo-send toast currently shown, if any.
    var pendingUndo: PendingUndo?
    /// Pending reads of Claude's session title after a Stop, per pane (R16).
    var titleWork: [String: DispatchWorkItem] = [:]
    /// Codex: hook events received this run, and the one-time "trust lmux's hooks" hint.
    var codexHookEvents = 0
    var codexHintWork: DispatchWorkItem?
    var codexHintShown = false
    /// OSC 7501 reports refused: not from the program they name, and foreground argv lookups
    /// for them (tests count both).
    var ignoredProgramReports = 0
    var argvLookups = 0
    /// After a reporter exits, how long its last words get to arrive before it's forgotten (tests lengthen it).
    var reporterExitGrace: TimeInterval = 0.5
    /// How long after `codex` starts its first hook event is waited for (tests shorten it).
    var codexHintDelay: TimeInterval = 8
    /// A Codex PermissionRequest counts as "needs input" only if nothing else came from the pane
    /// within this long (auto-approved tools never notify). Pending ones per pane.
    var codexPermissionGrace: TimeInterval = 1.0
    var codexPermissionWork: [String: (agent: String, work: DispatchWorkItem)] = [:]
    /// Tokens of closed panes (this run's and earlier runs'): Codex's shared app-server keeps the
    /// environment of the codex that started it, also after its pane closed or lmux quit, so its
    /// events still carry one (they're routed by session, see `routeSharedCodex`).
    var retiredPaneTokens: [(token: String, paneID: String)] = []
    /// Codex sessions from a shared app-server that no pane is bound to yet, waiting for the
    /// pane whose codex started a turn at that moment.
    var codexBinder = CodexSessionBinder(window: LmuxController.codexBindWindow)
    /// When `bindPendingCodexSessions` is set to look again (nil: not set).
    var codexBindCheck: Date?
    /// Hook runner pid -> whether it is Codex's shared app-server (`codex app-server …`).
    var sharedCodexServers: [Int32: Bool] = [:]
    var overlayWork: [String: DispatchWorkItem] = [:]
    /// Per pane: the pending look at the transcript after Esc / Ctrl+C (`interruptKeyPressed`).
    var interruptChecks: [String: UUID] = [:]
    /// `lmux wait` calls in progress (Wait.swift), looked at once per runloop turn a state changed in.
    var waits: [Int: PaneWait] = [:]
    var nextWaitID = 0
    var waitsScheduled = false
    /// Panes whose chrome a hook event changed, refreshed together at the end of the runloop turn.
    var chromePending: Set<String> = []
    var chromeScheduled = false
    /// Incremental per-pane transcript readers (hover, titles), off the main thread.
    let transcripts = TranscriptCache()
    /// Per pane: bytes its transcript reader parsed so far, and how often it read from the start (tests).
    var transcriptReads: [String: (bytes: Int, fullReads: Int)] = [:]
    var secureInputWanted = false
    /// A minute tick for the sidebar's elapsed times is pending (tests).
    var ageTickScheduled: Bool { ageTick != nil }
    private var ageTick: DispatchWorkItem?
    /// Observer that presents a deferred sheet once the window is key (see presentWhenWindowIsUp).
    var pendingSheetObserver: NSObjectProtocol?
    /// The config file ⌘, opened last (tests).
    public internal(set) var lastOpenedConfig: URL?
    /// `activate` requests from a second launch (tests).
    public internal(set) var activationRequests = 0
    /// `reopenWindow()` calls (tests): headless mode makes its body a no-op, so this is the
    /// only way a test can see that a path (notification click, dock icon, `activate`) reached it.
    public internal(set) var reopenWindowCalls = 0
    var secureInputEngaged = false
    var secureInputMenuItem: NSMenuItem?
    /// Shell > Close Pane (⌘W): with a multi-selection its shortcut closes the selected workspaces.
    var closePaneMenuItem: NSMenuItem?
    /// View > Zoom Split: its title tracks "Zoom Split" / "Unzoom Split".
    var splitZoomMenuItem: NSMenuItem?
    /// A ⌘/⇧-click in the sidebar made the list the thing the user is working with: the next Esc
    /// clears the multi-selection instead of reaching the terminal (any click in a pane or other key disarms it).
    var sidebarEscapeArmed = false
    /// Esc cancelled the sidebar drag in progress: the rest of that press-and-drag (until the next
    /// mouse down) neither restarts nor commits it.
    var sidebarDragCancelled = false
    /// The last selection-count announcement (VoiceOver), for tests.
    var lastSelectionAnnouncement: String?
    /// The pane a left-button press started in (a drag there selects text: no hover pill).
    weak var pressedPane: Pane?
    /// Where a tab dragged out of its strip would land (shown while it's dragged).
    var tabDropPreview: TabDropPreview?
    /// The window was closed in full screen: it hides once full screen has ended (`windowShouldClose`).
    var hideAfterFullScreen = false
    /// Times the open notification list was resized to new rows (tests: headless, the hosting view
    /// resizes its holder window by itself, so the size alone doesn't show the popover follows).
    public internal(set) var notificationsResizes = 0
    /// The bell's popover (built on first open; never shown headless, see `Notifications.swift`).
    var notificationsPopover: NSPopover?
    var notificationsView: NotificationsHostingView?
    let notificationsPanel = NotificationsPanel()
    /// lmux's app settings (appearance, quit warning, notifications, cmux import).
    public lazy var settings = LmuxSettings(url: paths.stateDir.appendingPathComponent("settings.plist"))
    var dockBadgeShown: String?
    /// Config reloads done by lmux (Theme / Font / import), for tests.
    public internal(set) var configReloads = 0
    var settingsWindow: NSWindow?
    /// The one deadline timer of reminders, quiet hints and usage-limit waits (only while one is
    /// pending; rescheduled in place, never stacked) and test hooks.
    var attentionWork: DispatchSourceTimer?
    /// Seconds until it fires, as last scheduled (tests).
    var attentionDelay: TimeInterval?
    var attentionClock: (() -> Date)?
    var reduceMotionOverride: Bool?
    var settingsModel: SettingsModel?
    /// The cmux import sheet's model (headless: built, never shown) and the window frame it applied.
    var cmuxImportModel: CmuxImportModel?
    public internal(set) var importedWindowFrame: NSRect?
    /// What the last cmux import changed, until it is undone or lmux quits (Undo cmux Import).
    var cmuxUndo: CmuxImportUndo?
    /// Closed sessions + search (R12).
    public private(set) var history: HistoryModel!

    public init(runtime: GhosttyRuntime, paths: LmuxPaths = LmuxPaths(), headless: Bool) {
        self.runtime = runtime
        self.paths = paths
        self.headless = headless
        if headless { GhosttyRuntime.headless = true }
        self.notifier = Notifier(postToSystem: !headless)
        super.init()
        history = HistoryModel(paths: paths, controller: self)
        notifier.onActivate = { [weak self] paneID in
            guard let self, let p = self.panesByID[paneID] else { return }
            // The window may be closed (red button) or minimized: bring it back first.
            self.reopenWindow()
            self.focus(p)
        }
        runtime.actionHandler = { [weak self] target, action, view in
            self?.handleGhosttyAction(target: target, action: action, view: view)
        }
        runtime.onCloseSurface = { [weak self] view, processAlive in
            guard let self, let pane = self.panesBySurface[ObjectIdentifier(view)] else { return }
            if processAlive { self.requestClosePane(pane) } else { self.closePane(pane) }
        }
    }

    // MARK: - Startup

    /// Another lmux answered on the control socket at `start()`: nothing was started (the caller
    /// hands off to it and exits).
    public private(set) var alreadyRunning = false
    /// The state dir belongs to another user (or isn't a dir): nothing was started, nothing read.
    public private(set) var unsafeStateDir = false

    /// Build the window, restore the layout (or open one workspace), start sockets.
    public func start(windowFrame: NSRect = NSRect(x: 0, y: 0, width: 1280, height: 800)) {
        try? FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Its layout.json is replayed into shells and its sockets accept commands: it must be ours.
        guard paths.secureStateDir() else {
            unsafeStateDir = true
            return
        }
        // First: a live instance on these sockets means this one must not restore the layout
        // (its panes would run twice) nor touch the hook socket.
        guard startControlServer() else {
            alreadyRunning = true
            return
        }
        SplitNode.stripWithOneTab = settings.tabBarWithOneTab
        buildWindow(frame: windowFrame)
        loadRetiredPaneTokens()
        startHookServer()
        if !restoreLayout() { newWorkspace() }
        removeSavedScrollback()
        persistenceEnabled = true
        scheduleSave()
        // History indexing / archiving runs off the main thread, after the window is up (a first
        // index only once History is opened).
        DispatchQueue.main.async { [weak self] in self?.history.launch() }
        Task { await pruneForgottenBackups() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPaneChrome(); self?.applySecureInput() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySecureInput() }
        }
        if !headless { secureKeyboardEntry = UserDefaults.standard.bool(forKey: "secureKeyboardEntry") }
        // lmux's own settings (Settings window, cmux import). System appearance leaves NSApp's alone.
        if settings.appearance != .system { applyAppearance() }
        notifier.sound = settings.notificationSound
        applySidebarLook()
        // A display unplugged, rearranged or woken can leave the window where no screen is.
        if !headless {
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                                   queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.keepWindowOnScreen() } }
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil,
                                                              queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.keepWindowOnScreen() } }
        }
    }

    /// Quit (⌘Q, SIGTERM / SIGINT / SIGHUP): save, stop the sockets, and hang up every pane the
    /// way Ghostty does when it frees a surface (SIGHUP to its process group, pty closed), plus the
    /// pane's foreground job (Claude runs in its own process group), so nothing is left running.
    public func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        saveScrollback()
        saveNow()
        hookServer?.stop()
        controlServer?.stop()
        retirePaneTokens(paneIDByToken.filter { pane(id: $0.value)?.ranCodex == true }.map { ($0.key, $0.value) })
        for p in model.workspaces.flatMap(\.panes) {
            let fg = p.surface.foregroundPID
            if fg > 0 { killpg(fg, SIGHUP) }
            p.surface.close()
        }
    }
    private var didShutdown = false

    var isAppActive: Bool { assumeAppActive || (NSApp.isActive && window.isKeyWindow) }

    // MARK: - Window

    private func buildWindow(frame: NSRect) {
        let titled = !headless || Self.headlessTitled
        let style: NSWindow.StyleMask = !titled
            ? [.borderless]
            : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let rect = headless ? NSRect(x: -10000, y: -10000, width: frame.width, height: frame.height) : frame
        let w = LmuxWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        w.controller = self
        w.title = "lmux"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 600, height: 360)
        if titled {
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // A compact (empty) toolbar gives a ~38-40pt titlebar with the
            // traffic lights vertically centered in it.
            let tb = NSToolbar(identifier: "lmux.titlebar")
            tb.showsBaselineSeparator = false
            w.toolbar = tb
            w.toolbarStyle = .unifiedCompact
        }
        w.backgroundColor = T.Colors.windowBackground.nsColor
        w.delegate = self

        let titlebar: CGFloat = !titled ? T.Layout.titlebarHeight
            : max(T.Layout.titlebarHeight, w.frame.height - w.contentLayoutRect.height)
        root = RootView(model: model, controller: self, titlebarHeight: titlebar)
        w.contentView = root
        // The theme frame clips a layer-backed content view to the window's rounded corners.
        root.wantsLayer = true
        // Offscreen (headless) there is no desktop behind the window to blend: opaque sidebar.
        root.sidebarBackdrop.forceOpaque = headless
        window = w
        if headless {
            // Off screen before it is ever ordered in (LmuxWindow keeps AppKit from pulling a titled
            // window onto a display), so no display shows it even for a frame.
            w.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            w.orderFrontRegardless()
            if titled, let titlebarView = w.standardWindowButton(.closeButton)?.superview { root.attachTitlebar(titlebarView) }
        } else {
            w.center()
            w.setFrameAutosaveName("lmux.main")
            w.makeKeyAndOrderFront(nil)
            if let titlebarView = w.standardWindowButton(.closeButton)?.superview { root.attachTitlebar(titlebarView) }
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        syncSurfaceFocus()
        refreshPaneChrome()
    }
    public func windowDidResignKey(_ notification: Notification) { syncSurfaceFocus() }
    /// Full screen moves the titlebar buttons to the left edge while the traffic lights are hidden, and back.
    public func windowWillEnterFullScreen(_ notification: Notification) { root.needsLayout = true }
    public func windowDidEnterFullScreen(_ notification: Notification) {
        root.trackTrafficLights(true)
        root.needsLayout = true
    }
    public func windowWillExitFullScreen(_ notification: Notification) {
        root.trackTrafficLights(false)
        root.exitingFullScreen = true
    }
    public func windowDidExitFullScreen(_ notification: Notification) {
        root.exitingFullScreen = false
        if hideAfterFullScreen { hideWindow() }
    }
    public func windowDidFailToExitFullScreen(_ window: NSWindow) {
        hideAfterFullScreen = false
        root.exitingFullScreen = false
        root.trackTrafficLights(true)
    }

    /// The first responder surface has focus only while the window is key (see
    /// `SurfaceView.windowIsKey`).
    func syncSurfaceFocus() {
        guard let ws = model.selected else { return }
        for p in ws.panes { p.surface.focusDidChange(p.surface.windowIsKey && window.firstResponder === p.surface) }
    }

    /// After a screen change: a window whose titlebar no screen shows comes back onto the screen it
    /// overlaps most (else the first), keeping its size when it fits.
    func keepWindowOnScreen() {
        guard !headless, window.isVisible, !window.styleMask.contains(.fullScreen),
              let f = Self.frameKeptOnScreen(window.frame, screens: NSScreen.screens.map(\.visibleFrame)) else { return }
        window.setFrame(f, display: true)
    }

    /// nil when at least 80 x 10 pt of the titlebar strip is on some screen (the window can still be dragged).
    nonisolated static func frameKeptOnScreen(_ f: NSRect, screens: [NSRect]) -> NSRect? {
        guard !screens.isEmpty else { return nil }
        let bar = NSRect(x: f.minX, y: f.maxY - 30, width: f.width, height: 30)
        if screens.contains(where: { let i = $0.intersection(bar); return i.width >= 80 && i.height >= 10 }) { return nil }
        func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
        let target = screens.max { area($0.intersection(f)) < area($1.intersection(f)) }
            .flatMap { area($0.intersection(f)) > 0 ? $0 : nil } ?? screens[0]
        let w = min(f.width, target.width), h = min(f.height, target.height)
        let x = min(max(f.minX, target.minX), target.maxX - w), y = min(max(f.minY, target.minY), target.maxY - h)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// Tests: what `windowShown` reports.
    var windowShownOverride: Bool?
    /// The window can be seen: on screen, not minimized, not fully covered (headless: always,
    /// it lives off screen on purpose and its frames are read back by tests and renders).
    var windowShown: Bool {
        if let o = windowShownOverride { return o }
        if headless { return true }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Only the selected workspace renders, and only while the window can be seen (like
    /// Ghostty's BaseTerminalController.syncSurfaceTreeOcclusionState).
    func syncOcclusion() {
        updatePulseMotion()
        updateAttention()  // (seen again: the selected row is being looked at)
        let shown = windowShown
        for ws in model.workspaces {
            // Zoomed: the other panes are out of the window and stay occluded.
            for p in ws.panes {
                p.surface.setOcclusion(visible: shown && ws === model.selected && (ws.zoomedPane == nil || p === ws.zoomedPane))
            }
        }
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) { syncOcclusion() }
    public func windowDidMiniaturize(_ notification: Notification) { syncOcclusion() }
    public func windowDidDeminiaturize(_ notification: Notification) { syncOcclusion() }

    /// After any sheet (hooks onboarding, rename, Move to Trash) the keyboard goes back to the
    /// pane, with its input context active, so the first keys typed reach it through the IME.
    public func windowDidEndSheet(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window.attachedSheet == nil else { return }
                if !(self.window.firstResponder is NSText) { self.focusCurrent() }
                self.model.selected?.focusedPane?.surface.inputContext?.activate()
            }
        }
    }

    /// The red button closes the window, not the sessions: every pane keeps running and the
    /// Dock icon or ⌘N brings the window back (Ghostty keeps running with no window too).
    /// Quitting is ⌘Q, which asks first while something is running.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        saveNow()
        // Hidden in full screen, the window would leave its Space behind, empty and black: leave
        // full screen first and hide it when that's done (`windowDidExitFullScreen`).
        if sender.styleMask.contains(.fullScreen) {
            if !root.exitingFullScreen { sender.toggleFullScreen(nil) }
            hideAfterFullScreen = true
            return false
        }
        hideWindow()
        return false
    }

    func hideWindow() {
        hideAfterFullScreen = false
        window.orderOut(nil)
        syncOcclusion()
    }

    /// Dock icon click / `open -a lmux` / ⌘N with no visible window: show it again.
    public func reopenWindow() {
        reopenWindowCalls += 1
        hideAfterFullScreen = false  // reopened while leaving full screen to close: it stays
        guard !headless else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        syncOcclusion()
        focusCurrent()
    }

    /// Panes whose process would be killed by quitting (not an idle shell), per Ghostty's
    /// `confirm-close-surface` (libghostty answers it per surface).
    public var panesNeedingQuitConfirmation: [Pane] {
        model.workspaces.flatMap(\.panes).filter { $0.surface.needsConfirmQuit }
    }

    /// ⌘Q: like Ghostty, ask before killing running processes.
    public func shouldTerminate() -> NSApplication.TerminateReply {
        guard settings.warnBeforeQuit else { return .terminateNow }
        let busy = panesNeedingQuitConfirmation
        guard !headless, !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit lmux?"
        alert.informativeText = busy.count == 1
            ? "A process is still running in “\(busy[0].workspace?.title ?? "a pane")”. Quitting will terminate it."
            : "Processes are still running in \(busy.count) panes. Quitting will terminate them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: - Panes

    func makePane(id: String = UUID().uuidString, cwd: String?, initialInput: String? = nil,
                  command: String? = nil, extraEnvironment: [String: String] = [:]) -> Pane {
        let token = Self.randomToken()
        var env: [String: String] = [
            "LMUX_PANE_ID": id,
            "LMUX_PANE_NONCE": token,
            "LMUX_PANE_TOKEN": token,  // the old name, for one release (an older lmux-hook / lmux CLI reads it)
            "LMUX_SOCKET": paths.hookSocket,
            "LMUX_CONTROL_SOCKET": paths.controlSocket,
        ]
        if let bin = paths.binDir?.path {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = bin + ":" + path
        }
        // A restored Claude pane gets its session's settings (CLAUDE_CONFIG_DIR, …) through the
        // shell's environment instead of typed `VAR=x` assignments (which shell history keeps).
        let replay = extraEnvironment.filter { HookClient.replayable($0.key) }
        env.merge(replay) { $1 }
        let validCwd = cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let opts = SurfaceOptions(command: command ?? paths.paneCommand, workingDirectory: validCwd,
                                  environment: env, initialInput: initialInput)
        let surface = SurfaceView(app: runtime.app!, options: opts)
        surface.focusDidChange(false)
        let pane = Pane(id: id, surface: surface)
        pane.cwd = validCwd
        if let c = validCwd { pane.branch = GitBranch.read(cwd: c) }
        surface.onProgramStatus = { [weak self, weak pane] status in
            guard let self, let pane else { return }
            self.programStatus(pane, status)
        }
        surface.onTitleChange = { [weak self, weak pane] title in
            guard let self, let pane else { return }
            // A working agent's spinner retitles the pane every moment: it is alive, even with a hidden
            // pane. (Any new title is bytes the pane's program wrote: output, which is what the hint is about.)
            self.noteAgentActivity(pane)
            // Spinner frames (`⠋ Working`, `⠙ Working`) clean to the same title: nothing changed.
            let clean = Pane.cleanTitle(title)
            guard clean != pane.title else { return }
            pane.title = clean
            pane.foregroundCache = nil
            pane.programArgv = nil  // (`exec` keeps the job: look at it again)
            self.checkClaudeStillRunning(pane)
            self.noticeCodexStarting(pane, title: clean)
            self.considerHooksHint(pane)
            // Titles change after each command: a cheap moment to notice `git checkout`.
            if let c = pane.cwd { let b = GitBranch.read(cwd: c); if b != pane.branch { pane.branch = b } }
            // A hidden workspace's pane headers are refreshed when it is shown (rebuildContent).
            if pane.workspace === self.model.selected, let ws = pane.workspace {
                self.refreshHeaders(ws)
                self.root.updateHeader()
            }
            self.scheduleSave()
        }
        surface.onFocusChange = { [weak self, weak pane] focused in
            guard focused, let self, let pane else { return }
            self.surfaceDidFocus(pane)
        }
        surface.onUserInput = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.userTyped(pane)
        }
        surface.onInterruptKey = { [weak self, weak pane] esc in
            guard let self, let pane else { return }
            self.interruptKeyPressed(pane, esc: esc)
        }
        installMessageActions(pane)
        surface.onFrame = { [weak self, weak pane] in
            if let self, let pane { self.paneDrewFrame(pane) }
        }
        surface.onBackgroundChange = { [weak self, weak pane] _ in
            self?.root.updateHeader()
            // The tab strip is drawn on the terminal's background (a theme or light / dark switch).
            if let pane, let leaf = pane.workspace?.root.find(pane), leaf.hasStrip, leaf.shownTab === pane { leaf.strip.update() }
            if let self, let pane, pane.runsClaude { self.scheduleOverlayRefresh(pane) }
        }
        pane.view.header.onDoubleClick = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.promptRenamePane(pane)
        }
        panesByID[id] = pane
        panesBySurface[ObjectIdentifier(surface)] = pane
        paneIDByToken[token] = id
        return pane
    }

    /// Variables that describe the process lmux was launched FROM (a Claude Code session, cmux,
    /// another terminal or multiplexer) and would mislead programs in lmux's panes: a claude
    /// that sees CLAUDE_CODE_CHILD_SESSION turns transcript saving off (no message actions, History or
    /// titles). Panes inherit lmux's environment, so lmux drops them from its own at startup.
    /// libghostty sets TERM, TERM_PROGRAM(=ghostty, like in Ghostty), COLORTERM itself.
    nonisolated static let inheritedNames: Set<String> = [
        "CLAUDECODE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "LC_TERMINAL",
        "LC_TERMINAL_VERSION", "TMUX", "TMUX_PANE", "STY", "WINDOW", "KITTY_WINDOW_ID", "KITTY_PID",
        "KITTY_LISTEN_ON", "ALACRITTY_SOCKET", "ALACRITTY_LOG", "ALACRITTY_WINDOW_ID", "WEZTERM_PANE",
        "WEZTERM_UNIX_SOCKET", "WEZTERM_EXECUTABLE", "WEZTERM_CONFIG_DIR", "WEZTERM_CONFIG_FILE",
        "ITERM_SESSION_ID", "ITERM_PROFILE", "WT_SESSION", "VSCODE_INJECTION", "COLORFGBG",
        "LMUX_PANE_ID", "LMUX_PANE_NONCE", "LMUX_PANE_TOKEN", "LMUX_SOCKET", "LMUX_CONTROL_SOCKET", "CLAUDE_PID",
    ]
    nonisolated static let inheritedPrefixes = ["CLAUDE_CODE_", "CMUX_", "GHOSTTY_", "ITERM_", "KITTY_", "WEZTERM_", "VSCODE_",
                                    "TERMINAL_EMULATOR"]

    nonisolated static func isInherited(_ name: String) -> Bool {
        if inheritedNames.contains(name) { return true }
        // Ghostty's resources dir is lmux's own input (themes, shell integration), not the parent's.
        if name == "GHOSTTY_RESOURCES_DIR" { return false }
        // The user's own Claude settings (CLAUDE_CODE_USE_BEDROCK, …) stay; session markers go.
        if name.hasPrefix("CLAUDE_CODE_"), HookClient.replayable(name) { return false }
        return inheritedPrefixes.contains { name.hasPrefix($0) }
    }

    /// Call before `ghostty_init` only: libghostty keeps a view of the process environment, and
    /// unsetenv afterwards shifts the entries under it (crash).
    nonisolated public static func sanitizeInheritedEnvironment() {
        for name in ProcessInfo.processInfo.environment.keys where isInherited(name) { unsetenv(name) }
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The token injected into a pane's environment (tests).
    func token(for pane: Pane) -> String? { paneIDByToken.first { $0.value == pane.id }?.key }

    /// The pane a CLI call came from: its token, else the pane whose terminal the calling
    /// process runs on (its controlling tty, from the socket peer's pid). nil = outside lmux.
    /// A guard against mistakes, not a security boundary: a process that drops both (no
    /// token, `setsid` off the tty) is treated as outside.
    func callerPane(token: String?, peerPID: Int?) -> Pane? {
        if let p = pane(token: token) { return p }
        guard let pid = peerPID, pid > 0, let tpgid = Self.terminalForegroundGroup(pid_t(pid)) else { return nil }
        // Each pane's pty has its own foreground process group (what Ghostty reports).
        return panesByID.values.first { $0.surface.foregroundPID == tpgid }
    }

    /// The foreground process group of `pid`'s controlling terminal, nil without one.
    static func terminalForegroundGroup(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size), info.e_tdev != UInt32(bitPattern: -1), info.e_tdev != 0,
              info.e_tpgid > 0 else { return nil }
        return pid_t(info.e_tpgid)
    }

    /// The pane a CLI call came from (by its token), nil = from outside lmux.
    func pane(token: String?) -> Pane? {
        guard let token, !token.isEmpty, let id = paneIDByToken[token] else { return nil }
        return panesByID[id]
    }

    public func pane(id: String) -> Pane? { panesByID[id] }

    func discard(_ pane: Pane) {
        transcripts.drop(pane: pane.id)
        codexPermissionWork.removeValue(forKey: pane.id)?.work.cancel()
        if pane.ranCodex { retirePaneTokens(paneIDByToken.filter { $0.value == pane.id }.map { ($0.key, $0.value) }) }
        paneIDByToken = paneIDByToken.filter { $0.value != pane.id }
        notifyGate[pane.id]?.work?.cancel()
        notifyGate[pane.id] = nil
        // Pending title / overlay work would otherwise keep the closed pane alive and run on it.
        titleWork.removeValue(forKey: pane.id)?.cancel()
        overlayWork.removeValue(forKey: pane.id)?.cancel()
        interruptChecks[pane.id] = nil
        transcriptReads[pane.id] = nil
        pane.programExitWatch?.cancel()
        pane.programArgvWatch?.cancel()
        panesByID[pane.id] = nil
        scheduleWaitCheck()  // (a wait on it, or on its workspace, may be over: target gone)
        panesBySurface[ObjectIdentifier(pane.surface)] = nil
        pane.view.removeFromSuperview()
        pane.surface.close()
    }

    // MARK: - Workspaces

    func nextAccent() -> Int {
        let n = T.Colors.workspaceAccents.count
        let used = Set(model.workspaces.map { $0.accent % n })
        for i in 0..<n {
            let c = (accentCounter + i) % n
            if !used.contains(c) { accentCounter = c + 1; return c }
        }
        defer { accentCounter += 1 }
        return accentCounter % n
    }

    /// ⌘N / `lmux new-workspace`. `command` is typed into the new shell. Without `cwd` it starts in
    /// Ghostty's `working-directory` (else home), or the focused pane's directory when the config
    /// asks to inherit (`LmuxConfig.newWorkspaceInherits`).
    @discardableResult
    public func newWorkspace(cwd: String? = nil, command: String? = nil, select: Bool = true,
                             program: String? = nil) -> Workspace {
        let dir = cwd ?? (LmuxConfig.newWorkspaceInherits() ? model.selected?.focusedPane?.cwd : nil)
            ?? LmuxConfig.workingDirectory()
        let pane = makePane(cwd: dir, initialInput: command.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" },
                            command: program)
        pane.startedPlain = command == nil && program == nil
        if command != nil { pane.lastSentAt = Date() }
        let ws = Workspace(id: UUID().uuidString, accent: nextAccent(), root: SplitNode(pane: pane))
        if let i = model.workspaces.firstIndex(where: { $0.id == model.selectedID }) {
            model.workspaces.insert(ws, at: i + 1)
        } else {
            model.workspaces.append(ws)
        }
        if select || model.selected == nil { self.select(ws) } else { pane.surface.setOcclusion(visible: false) }
        scheduleSave()
        return ws
    }

    public func select(_ ws: Workspace, focusing pane: Pane? = nil) {
        if let pane, ws.panes.contains(where: { $0 === pane }) { ws.focusedPane = pane }
        if let cur = model.selected, cur !== ws {
            for p in cur.panes {
                p.surface.focusDidChange(false)
                p.surface.setOcclusion(visible: false)
            }
        }
        if ws.id != model.selectedID {
            // Switching workspace any other way (⌘1, jump to unread, …) ends a multi-selection.
            model.selection = []
            model.selectionAnchorID = ws.id
        }
        model.selectedID = ws.id
        rebuildContent()
        focusCurrent()
        scheduleSave()
    }

    public func selectWorkspace(at index: Int) {
        guard model.workspaces.indices.contains(index) else { return }
        select(model.workspaces[index])
    }

    func selectRelative(_ delta: Int) {
        guard let i = model.workspaces.firstIndex(where: { $0.id == model.selectedID }),
              !model.workspaces.isEmpty else { return }
        let n = model.workspaces.count
        select(model.workspaces[((i + delta) % n + n) % n])
    }

    public func closeWorkspace(_ ws: Workspace) {
        guard let i = model.workspaces.firstIndex(where: { $0 === ws }) else { return }
        let wasSelected = ws.id == model.selectedID
        for p in ws.panes { discard(p) }
        model.workspaces.remove(at: i)
        model.selection.remove(ws.id)
        if model.selection.count < 2 { model.selection = [] }
        if model.hoveredRowID == ws.id { model.hoveredRowID = nil }
        if model.workspaces.isEmpty {
            model.selectedID = nil
            newWorkspace()  // lmux always has one workspace
        } else if wasSelected {
            select(model.workspaces[min(i, model.workspaces.count - 1)])
        }
        scheduleSave()
    }

    public func promptRename(_ ws: Workspace) {
        guard !headless else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Leave empty to follow the terminal title."
        let field = NSTextField(string: ws.customTitle ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.renameWorkspace(ws, to: field.stringValue)
            self?.focusCurrent()
        }
    }

    public func toggleSidebar() {
        model.sidebarVisible.toggle()
        if !model.sidebarVisible, model.sidebarDrag != nil { cancelSidebarDrag() }  // its row is gone mid-drag
        model.clock = Date()
        updateAgeTick()
        updatePulseMotion()
        root.needsLayout = true
        scheduleSave()
        focusCurrent()
    }

    // MARK: - Splits

    public enum SplitDirection { case right, down, left, up }

    @discardableResult
    public func split(_ pane: Pane, _ dir: SplitDirection, program: String? = nil) -> Pane? {
        guard let ws = pane.workspace, let node = ws.root.find(pane) else { return nil }
        let cwd = (LmuxConfig.splitInherits() ? pane.cwd : nil) ?? LmuxConfig.workingDirectory()
        let newPane = makePane(cwd: cwd, command: program)
        splitLeaf(node, in: ws, dir, with: newPane)
        return newPane
    }

    /// Split the leaf `node`, `newPane` (new, or a tab dragged out of a strip) on the `dir` side, focused.
    func splitLeaf(_ node: SplitNode, in ws: Workspace, _ dir: SplitDirection, with newPane: Pane) {
        ws.zoomedPane = nil  // splitting while zoomed unzooms first, then splits as normal
        // The leaf's tabs stay together on the old side.
        let old = SplitNode(tabs: node.tabs, selected: node.tabs.firstIndex { $0 === node.shownTab } ?? 0)
        let new = SplitNode(pane: newPane)
        node.tabs = []
        let axis: SplitAxis = (dir == .right || dir == .left) ? .horizontal : .vertical
        let newFirst = dir == .left || dir == .up
        node.content = .split(axis, newFirst ? new : old, newFirst ? old : new)
        old.parent = node
        new.parent = node
        node.ratio = 0.5
        ws.focusedPane = newPane
        ws.structureChanged()
        if ws === model.selected {
            rebuildContent()
            focusCurrent()
        } else {
            newPane.surface.setOcclusion(visible: false)
        }
        scheduleSave()
    }

    public func closePane(_ pane: Pane) {
        guard let ws = pane.workspace, let node = ws.root.find(pane) else { return }
        if node.tabs.count > 1 { closeTab(pane, in: node); return }
        ws.zoomedPane = nil  // closing while zoomed unzooms first, then closes as normal
        guard removeLeaf(node, in: ws, leaving: pane) else {
            closeWorkspace(ws)
            return
        }
        discard(pane)
        ws.structureChanged()
        if ws === model.selected {
            rebuildContent()
            focusCurrent()
        }
        scheduleSave()
    }

    /// Take the leaf `node` out of the tree: its sibling takes the parent's place (focus moves off
    /// `pane` there). False for the workspace's root (nothing to collapse into).
    func removeLeaf(_ node: SplitNode, in ws: Workspace, leaving pane: Pane) -> Bool {
        guard let parent = node.parent, case .split(_, let a, let b) = parent.content else { return false }
        let sibling = a === node ? b : a
        parent.content = sibling.content
        parent.tabs = sibling.tabs
        parent.ratio = sibling.ratio
        if case .split(_, let x, let y) = sibling.content { x.parent = parent; y.parent = parent }
        if ws.focusedPane === pane { ws.focusedPane = parent.visiblePanes.first }
        return true
    }

    public func moveFocus(_ dir: FocusDirection) {
        guard let ws = model.selected, let cur = ws.focusedPane else { return }
        let panes = ws.visiblePanes
        guard panes.count > 1, let i = panes.firstIndex(where: { $0 === cur }) else { return }
        var target: Pane?
        switch dir {
        case .previous: target = panes[(i - 1 + panes.count) % panes.count]
        case .next: target = panes[(i + 1) % panes.count]
        default:
            // Zoomed, the other panes' views are out of the window and have no place to measure:
            // lay the split out again first (moving focus unzooms anyway, as everywhere else).
            let zoomed = ws.zoomedPane
            if zoomed != nil { ws.zoomedPane = nil; rebuildContent() }
            defer {
                if target == nil, let zoomed { ws.zoomedPane = zoomed; rebuildContent() } else if zoomed != nil { scheduleSave() }
            }
            let f = cur.view.convert(cur.view.bounds, to: nil)
            var best: (Pane, CGFloat)?
            for p in panes where p !== cur {
                let g = p.view.convert(p.view.bounds, to: nil)
                // Window coordinates: y grows upward.
                let primary: CGFloat
                let overlap: Bool
                switch dir {
                case .left: primary = f.minX - g.maxX; overlap = g.maxY > f.minY && g.minY < f.maxY
                case .right: primary = g.minX - f.maxX; overlap = g.maxY > f.minY && g.minY < f.maxY
                case .up: primary = g.minY - f.maxY; overlap = g.maxX > f.minX && g.minX < f.maxX
                case .down: primary = f.minY - g.maxY; overlap = g.maxX > f.minX && g.minX < f.maxX
                default: continue
                }
                guard primary >= -2 else { continue }
                let score = primary + (overlap ? 0 : 10_000)
                if best == nil || score < best!.1 { best = (p, score) }
            }
            target = best?.0
        }
        if let target { focus(target) }
    }

    public func resizeSplit(_ pane: Pane, _ dir: ghostty_action_resize_split_direction_e, amount: CGFloat) {
        let axis: SplitAxis = (dir == GHOSTTY_RESIZE_SPLIT_LEFT || dir == GHOSTTY_RESIZE_SPLIT_RIGHT) ? .horizontal : .vertical
        guard let ws = pane.workspace, var node = ws.root.find(pane) else { return }
        while let parent = node.parent {
            if case .split(let ax, _, _) = parent.content, ax == axis {
                guard let view = splitView(for: parent) else { return }
                let len = axis == .horizontal ? view.bounds.width : view.bounds.height
                let pos = parent.ratio * (len - T.Layout.splitDividerWidth)
                let sign: CGFloat = (dir == GHOSTTY_RESIZE_SPLIT_LEFT || dir == GHOSTTY_RESIZE_SPLIT_UP) ? -1 : 1
                view.setRatio(forPosition: pos + sign * amount)
                return
            }
            node = parent
        }
    }

    /// ⇧⌘↩ (Ghostty's `toggle_split_zoom`): maximize the focused pane within its workspace, the
    /// rest hidden until toggled back. A no-op without a split (nothing to zoom into).
    public func toggleSplitZoom(_ ws: Workspace? = nil) {
        guard let ws = ws ?? model.selected, ws.isZoomed || ws.isSplit else { return }
        ws.zoomedPane = ws.zoomedPane == nil ? ws.focusedPane : nil
        if ws === model.selected {
            rebuildContent()
            focusCurrent()
        }
        scheduleSave()
    }

    public func equalize(_ ws: Workspace) {
        func walk(_ n: SplitNode) {
            if case .split(_, let a, let b) = n.content {
                n.ratio = CGFloat(a.leafCount) / CGFloat(n.leafCount)
                walk(a)
                walk(b)
            }
        }
        walk(ws.root)
        if ws === model.selected { rebuildContent(); focusCurrent() }
        scheduleSave()
    }

    func splitView(for node: SplitNode) -> SplitContainerView? {
        func find(_ v: NSView) -> SplitContainerView? {
            if let s = v as? SplitContainerView, s.node === node { return s }
            for sub in v.subviews { if let r = find(sub) { return r } }
            return nil
        }
        return find(root.content)
    }

    // MARK: - Content and focus

    func buildView(_ node: SplitNode) -> NSView {
        switch node.content {
        case .pane(let p):
            return p.view
        case .split(let axis, let a, let b):
            let v = SplitContainerView(node: node, axis: axis, first: buildView(a), second: buildView(b))
            v.onRatioChange = { [weak self] in self?.scheduleSave() }
            return v
        }
    }

    func rebuildContent() {
        root.content.subviews.forEach { $0.removeFromSuperview() }
        guard let ws = model.selected else { return }
        // Zoomed: only the zoomed pane's own view is in the tree, filling the content area; the
        // rest stay out of the hierarchy (and occluded, below) exactly like a hidden workspace.
        let zoomed = ws.zoomedPane
        let v: NSView = zoomed?.view ?? buildView(ws.root)
        v.frame = root.content.bounds
        v.autoresizingMask = [.width, .height]
        root.content.addSubview(v)
        refreshHeaders(ws)
        let shown = ws.visiblePanes
        for p in ws.panes {
            let leaf = ws.root.find(p)
            let isShown = shown.contains { $0 === p }
            let visible = isShown && (zoomed == nil || p === zoomed)
            p.view.showsHeader = ws.isSplit && zoomed == nil
            if let leaf, leaf.hasStrip, isShown { p.view.tabStrip = leaf.strip } else { p.view.tabStrip = nil }
            p.surface.setOcclusion(visible: windowShown && visible)
            if visible { scheduleOverlayRefresh(p); showPendingRewindNote(p) }
        }
        root.updateHeader()
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }

    /// Give keyboard focus to the selected workspace's focused pane.
    public func focusCurrent() {
        guard let pane = model.selected?.focusedPane else { return }
        // A surface removed from the window while first responder never gets
        // resignFirstResponder; clear stale focus so only one surface claims
        // key equivalents (performKeyEquivalent walks every visible surface).
        for ws in model.workspaces {
            for p in ws.panes where p !== pane && p.surface.focused { p.surface.focusDidChange(false) }
        }
        if window.firstResponder !== pane.surface {
            window.makeFirstResponder(pane.surface)
        }
        refreshPaneChrome()
    }

    public func focus(_ pane: Pane) {
        guard let ws = pane.workspace else { return }
        // A tab behind another one is brought to the front first (⇧⌘J, a notification, unread).
        let switched = ws.root.find(pane).map { showTab(pane, in: $0, ws) } ?? false
        if switched { scheduleSave() }
        if ws !== model.selected {
            unzoom(ws, toFocus: pane)
            select(ws, focusing: pane)
        } else {
            if unzoom(ws, toFocus: pane) || switched { rebuildContent() }
            ws.focusedPane = pane
            focusCurrent()
        }
    }

    /// Focusing a pane other than the zoomed one unzooms first (Ghostty does the same), so the
    /// focused pane is always one on screen. True: it was zoomed (the caller rebuilds the content).
    @discardableResult
    func unzoom(_ ws: Workspace, toFocus pane: Pane) -> Bool {
        guard let z = ws.zoomedPane, z !== pane else { return false }
        ws.zoomedPane = nil
        scheduleSave()
        return true
    }

    /// A surface became first responder (click, makeFirstResponder, ...).
    func surfaceDidFocus(_ pane: Pane) {
        guard let ws = pane.workspace, ws === model.selected else { return }
        if ws.focusedPane !== pane {
            ws.focusedPane = pane
            scheduleSave()
        }
        if unzoom(ws, toFocus: pane) { rebuildContent(); focusCurrent() }
        refreshPaneChrome()
    }

    /// Focus invariant (R6): keyboard focus is always on a visible pane of the
    /// selected workspace, never on the sidebar or a hidden pane. Text fields
    /// (rename sheet, future History search) are allowed.
    func ensureFocus() {
        guard let ws = model.selected, let pane = ws.focusedPane else { return }
        let fr = window.firstResponder
        if fr is NSText { return }
        if let s = fr as? SurfaceView, ws.visiblePanes.contains(where: { $0.surface === s }) { return }
        window.makeFirstResponder(pane.surface)
    }

    /// Clicking anywhere on a pane (terminal, header) focuses it.
    func handleMouseDown(_ event: NSEvent) {
        guard event.window === window, let contentView = window.contentView else { return }
        // hitTest takes a point in the receiver's superview (the frame view), i.e. window coordinates.
        let p = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        let hit = contentView.hitTest(p)
        var v = hit
        while let cur = v, !(cur is PaneView) { v = cur.superview }
        pressedPane = nil
        guard let pv = v as? PaneView, let pane = pv.pane else { return }
        sidebarEscapeArmed = false
        // A press on the terminal itself (not on an overlay control) may start a text selection.
        if hit is SurfaceView { pressedPane = pane }
        if model.selected?.focusedPane !== pane || window.firstResponder !== pane.surface {
            focus(pane)
        }
    }

    /// Pane header texts of a workspace (duplicates disambiguated).
    func refreshHeaders(_ ws: Workspace) {
        let titles = ws.headerTitles(running: ClaudeProcess.foregroundName)
        for p in ws.panes { p.view.setHeaderTitle(titles[ObjectIdentifier(p)] ?? p.headerTitle) }
        refreshTabStrips(ws)
    }

    /// Recompute focus-derived chrome: ring, pane header emphasis, unread clearing.
    /// The unread count on the Dock icon (setting `dockBadge`, imported from cmux).
    func updateDockBadge() {
        guard !headless else { return }
        let n = model.totalUnread
        let label = settings.dockBadge && n > 0 ? "\(n)" : nil
        if label != dockBadgeShown { dockBadgeShown = label; NSApp.dockTile.badgeLabel = label }
    }

    func refreshPaneChrome() {
        let active = isAppActive
        let sel = model.selected
        if let sel { refreshHeaders(sel) }
        for ws in model.workspaces {
            for p in ws.panes {
                let focused = ws === sel && ws.focusedPane === p
                if p.isFocused != focused { p.isFocused = focused }
                if focused && active && p.unread > 0 { p.unread = 0 }
                if ws === sel {
                    p.view.ring.setShown(p.showsRing && settings.unreadRing)
                    p.view.header.focused = focused
                    p.view.header.needsInput = p.needsInput
                    p.view.header.modeBadge = p.modeBadge
                }
            }
        }
        // The strips' accent line and badges follow the focus just set.
        if let sel { refreshTabStrips(sel) }
        root.updateHeader()
        updateAgeTick()
        updateDockBadge()
        updatePulseMotion()
        updateAttention()
    }

    /// Elapsed times ("4m") on Done / Failed rows move once a minute, and only while
    /// someone can see them: no timer while every row is idle/running or the sidebar is hidden.
    func updateAgeTick() {
        let visible = model.sidebarVisible && !NSApp.isHidden && !(window?.isMiniaturized ?? false)
        let needed = visible && model.workspaces.contains { $0.finishedAt != nil }
        if !needed { ageTick?.cancel(); ageTick = nil; return }
        guard ageTick == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ageTick = nil
                self.model.clock = Date()
                self.updateAgeTick()
            }
        }
        ageTick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    // MARK: - Jumping

    /// Bell ⌥-click / ⇧⌘U: the pane with the most recent unread alert.
    public func jumpToLatestUnread() {
        let all = model.workspaces.flatMap(\.panes).filter { $0.unread > 0 }
        guard let p = all.max(by: { ($0.lastAlertAt ?? .distantPast) < ($1.lastAlertAt ?? .distantPast) }) else { return }
        focus(p)
    }

    /// ⌘⇧J (R15): cycle through panes that need input, in sidebar order.
    public func jumpToNextNeedsInput() {
        let all = model.workspaces.flatMap(\.panes)
        guard !all.isEmpty else { return }
        let cur = model.selected?.focusedPane
        let start = cur.flatMap { c in all.firstIndex { $0 === c } } ?? -1
        for k in 1...all.count {
            let p = all[(start + k + all.count) % all.count]
            if p.needsInput && (p !== cur || all.count == 1) { focus(p); return }
        }
    }

    // MARK: - Typing

    func userTyped(_ pane: Pane) {
        // Hot path: one enum check per key press (+ one for Claude panes: the input
        // label follows the input box as it grows).
        if pane.runsClaude, overlayWork[pane.id] == nil { scheduleOverlayRefresh(pane, delay: 0.3) }
        if pane.attentionSince != nil { attended(pane) }
        // Codex's approval answered within its grace second: it was never waiting on the user.
        if pane.runsCodex, let pending = codexPermissionWork.removeValue(forKey: pane.id) { pending.work.cancel() }
        guard pane.needsInput || pane.unread > 0 else { return }
        // (A codex reporting its own state says when its dialog is answered: arrows in it aren't.)
        if pane.needsInput, pane.codexReport == nil, pane.programApp == nil { pane.agent.userTyped() }
        pane.unread = 0
        refreshPaneChrome()
    }

    // MARK: - Ghostty actions

    private func handleGhosttyAction(target: ghostty_target_s, action: ghostty_action_s, view: SurfaceView?) -> Bool? {
        let pane = view.flatMap { panesBySurface[ObjectIdentifier($0)] }
        func onMain(_ body: @escaping @MainActor () -> Void) {
            if Thread.isMainThread { MainActor.assumeIsolated { body() } }
            else { DispatchQueue.main.async { MainActor.assumeIsolated { body() } } }
        }
        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let pane else { return false }
            let d: SplitDirection
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_DOWN: d = .down
            case GHOSTTY_SPLIT_DIRECTION_LEFT: d = .left
            case GHOSTTY_SPLIT_DIRECTION_UP: d = .up
            default: d = .right
            }
            onMain { self.split(pane, d) }
            return true
        case GHOSTTY_ACTION_GOTO_SPLIT:
            let dir: FocusDirection
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: dir = .previous
            case GHOSTTY_GOTO_SPLIT_NEXT: dir = .next
            case GHOSTTY_GOTO_SPLIT_UP: dir = .up
            case GHOSTTY_GOTO_SPLIT_DOWN: dir = .down
            case GHOSTTY_GOTO_SPLIT_LEFT: dir = .left
            default: dir = .right
            }
            onMain { self.moveFocus(dir) }
            return true
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let pane else { return false }
            let r = action.action.resize_split
            onMain { self.resizeSplit(pane, r.direction, amount: CGFloat(r.amount)) }
            return true
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let ws = pane?.workspace else { return false }
            onMain { self.equalize(ws) }
            return true
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let ws = pane?.workspace else { return false }
            onMain { self.toggleSplitZoom(ws) }
            return true
        case GHOSTTY_ACTION_NEW_TAB:
            // ⌘T: a new tab in the pane (Ghostty's tabs are lmux's pane tabs; its windows, workspaces).
            guard let pane = pane ?? model.selected?.focusedPane else { return false }
            onMain { self.newTab(pane) }
            return true
        case GHOSTTY_ACTION_NEW_WINDOW:
            let cwd = LmuxConfig.newWorkspaceInherits() ? pane?.cwd : nil
            onMain { self.newWorkspace(cwd: cwd) }
            return true
        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = action.action.goto_tab.rawValue
            onMain {
                switch raw {
                // Ghostty's next / previous tab (⇧⌘] / ⇧⌘[, ⌃⇥ / ⌃⇧⇥) are the pane's tabs, as in cmux;
                // its numbered tabs (⌘1…⌘9) stay workspaces.
                case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: self.selectTabRelative(-1)
                case GHOSTTY_GOTO_TAB_NEXT.rawValue: self.selectTabRelative(1)
                case GHOSTTY_GOTO_TAB_LAST.rawValue: self.selectWorkspace(at: self.model.workspaces.count - 1)
                default: self.selectWorkspace(at: Int(raw) - 1)
                }
            }
            return true
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            guard let ws = pane?.workspace ?? model.selected else { return false }
            onMain { self.requestCloseWorkspaces(self.model.isMultiSelection ? self.model.selectedWorkspaces : [ws]) }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let pane, let c = action.action.pwd.pwd else { return false }
            let dir = String(cString: c)
            onMain { self.paneDidChangeDirectory(pane, dir) }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // OSC 9/777 from programs. Not a second notification path (R14):
            // only shown as the row's latest notification text.
            guard let ws = pane?.workspace else { return true }
            let body = action.action.desktop_notification.body.map { String(cString: $0) } ?? ""
            onMain { if !body.isEmpty { ws.notification = body } }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            // Like Ghostty's default bell-features (attention): bounce the Dock icon when lmux
            // isn't frontmost. The row's unread badge covers lmux's own window.
            onMain { if !self.headless, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) } }
            return true
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            onMain { if !self.headless { self.window.toggleFullScreen(nil) } }
            return true
        case GHOSTTY_ACTION_OPEN_CONFIG:
            onMain { self.openSettings() }
            return true
        case GHOSTTY_ACTION_PROMPT_TITLE:
            guard let pane else { return false }
            onMain { self.promptRenamePane(pane) }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let pane else { return false }
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            onMain { self.searchStarted(pane, needle: needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let pane else { return false }
            onMain { self.searchEnded(pane) }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let pane else { return false }
            let t = action.action.search_total.total
            onMain { self.searchCounts(pane, total: t >= 0 ? Int(t) : nil, selected: pane.view.overlay.findBar?.selected) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let pane else { return false }
            let sel = action.action.search_selected.selected
            onMain { self.searchCounts(pane, total: nil, selected: sel >= 0 ? Int(sel) : nil) }
            return true
        case GHOSTTY_ACTION_SECURE_INPUT:
            let v = action.action.secure_input
            onMain {
                switch v {
                case GHOSTTY_SECURE_INPUT_ON: self.secureKeyboardEntry = true
                case GHOSTTY_SECURE_INPUT_OFF: self.secureKeyboardEntry = false
                default: self.secureKeyboardEntry.toggle()
                }
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // Ghostty's reload_config (⇧⌘,): the runtime reloads; the menus follow its keybinds after.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.buildMainMenu() } }
            return nil
        case GHOSTTY_ACTION_UNDO:
            // ⌘Z is Ghostty's `undo` by default: while the undo-send toast is up it means Undo Send.
            guard pendingUndo != nil else { return false }
            onMain { _ = self.undoSend() }
            return true
        default:
            return nil
        }
    }

    /// Settings > General > "Open config file": lmux's config (Ghostty syntax) in the default text
    /// editor, created with a commented header when missing so it is never blank.
    @objc public func openConfigFile() {
        let url = LmuxConfig.configFile
        lastOpenedConfig = url
        // Automation only ever writes a config it was pointed at (LMUX_CONFIG_FILE), never the user's.
        guard !headless || ProcessInfo.processInfo.environment["LMUX_CONFIG_FILE"] != nil else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) || ((try? Data(contentsOf: url))?.isEmpty ?? true) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.configHeader.write(to: url, atomically: true, encoding: .utf8)
        }
        guard !headless else { return }
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static let configHeader = """
    # lmux config (Ghostty syntax: https://ghostty.org/docs/config/reference)
    #
    # Loaded after ~/.config/ghostty/config, so a key set here wins. Settings (⌘,) writes the
    # theme, font and size here and keeps every other line and comment as you left them.
    # Changes apply to all panes right away.
    #
    # theme = light:Nord Light,dark:Nord
    # font-family = D2Coding
    # font-family = Symbols Nerd Font Mono   (a fallback for icons)
    # font-size = 13

    """

    func paneDidChangeDirectory(_ pane: Pane, _ dir: String) {
        guard pane.cwd != dir else { return }
        pane.cwd = dir
        pane.branch = GitBranch.read(cwd: dir)
        if pane.workspace === model.selected { root.updateHeader() }
        scheduleSave()
    }

    // MARK: - CLI

    public enum SendResult: Equatable { case sent, noSuchPane, crossPaneDenied, externalDenied, paneBusy }

    /// `lmux send`: type text into a pane. A process inside pane X (its token) may only type into X
    /// (unless `allowCrossPaneSend`); a caller without a valid token only when `allowExternalSend`
    /// is on, and then still not from inside another pane (its tty says which).
    public func send(text: String, toPane id: String, token: String? = nil, peerPID: Int? = nil) -> SendResult {
        guard let p = panesByID[id] else { return .noSuchPane }
        if pane(token: token) == nil, !allowExternalSend { return .externalDenied }
        if let caller = callerPane(token: token, peerPID: peerPID), caller !== p, !allowCrossPaneSend { return .crossPaneDenied }
        // lmux is driving Claude Code's rewind menu there: typed text would land in it.
        if p.surface.inputHeld { return .paneBusy }
        p.surface.sendText(text)
        // Input that presses Return is the one that can start a turn (`lmux wait` waits for what comes after).
        if text.hasSuffix("\n") || text.hasSuffix("\r") {
            p.lastSentAt = Date()
            if p.needsInput, p.programApp != nil { p.programAnswered = true }  // (an answer: its next blocked is a new ask)
        }
        return .sent
    }

    /// `lmux notify`: row text + (when not looking) unread and a notification, at most one
    /// per `notifyInterval` per pane; the rest are coalesced into one at the end of the window.
    public func notify(text: String, title: String?, paneID: String?) {
        let pane = paneID.flatMap { panesByID[$0] }
        if let ws = pane?.workspace { ws.notification = text }
        let key = pane?.id ?? ""
        let now = Date()
        var gate = notifyGate[key] ?? (last: .distantPast, pending: nil, work: nil)
        if now.timeIntervalSince(gate.last) >= notifyInterval, gate.work == nil {
            gate.last = now
            notifyGate[key] = gate
            postNotify(text: text, title: title, pane: pane)
            return
        }
        gate.pending = (text, title)
        if gate.work == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, var g = self.notifyGate[key], let p = g.pending else { return }
                    g.pending = nil
                    g.work = nil
                    g.last = Date()
                    self.notifyGate[key] = g
                    self.postNotify(text: p.text, title: p.title, pane: key.isEmpty ? nil : self.panesByID[key])
                }
            }
            gate.work = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, notifyInterval - now.timeIntervalSince(gate.last)),
                                          execute: work)
        }
        notifyGate[key] = gate
    }

    private func postNotify(text: String, title: String?, pane: Pane?) {
        let focused = pane.map(isPaneFocused) ?? isAppActive
        if let pane, !focused {
            pane.unread += 1
            pane.lastAlertAt = Date()
            refreshPaneChrome()
        }
        if !focused {
            notifier.post(title: title ?? pane?.workspace?.title ?? "lmux", body: text, paneID: pane?.id, kind: "cli")
        }
        model.recordNotification(NotificationEntry(paneID: pane?.id, workspaceID: pane?.workspace?.id,
                                                   title: title ?? pane?.workspace?.title ?? "lmux", message: text,
                                                   kind: "cli", read: focused))
    }

    func isPaneFocused(_ pane: Pane) -> Bool {
        isAppActive && pane.workspace === model.selected && pane.workspace?.focusedPane === pane
    }
}

/// The lmux window. Focus-on-click and the focus invariant live here so they
/// hold for every click, whichever view receives it.
public final class LmuxWindow: NSWindow {
    weak var controller: LmuxController?

    /// ⌘W with a multi-selection closes the selected workspaces, before the terminal sees it
    /// (libghostty would close just the focused pane).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handleCloseSelectionKey(event) == true { return true }
        if super.performKeyEquivalent(with: event) { return true }
        // A non-Latin input source (Korean 2-Set: ⌃⌘S is "ㄴ" ignoring modifiers): menus match ⌃/⌥ shortcuts
        // on that character and miss. Try the same key as the ASCII-capable layout types it.
        if let latin = Self.asciiEquivalent(event), let menu = NSApp.mainMenu { return menu.performKeyEquivalent(with: latin) }
        return false
    }

    /// The event re-typed on the ASCII-capable layout, for a ⌘ key (every lmux shortcut needing this
    /// pairs ⌃/⌥ with ⌘) whose character isn't ASCII; else nil. Command-less, so a bare Control or
    /// Option combo (Ctrl+C with a Korean source, say) never reaches `NSMenu.performKeyEquivalent` and
    /// risks matching an unrelated system shortcut there (Control-C is macOS's own "Center Window").
    static func asciiEquivalent(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown, event.modifierFlags.contains(.command),
              let ign = event.charactersIgnoringModifiers, !ign.isEmpty, !ign.unicodeScalars.allSatisfy(\.isASCII),
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        func type(_ shift: Bool) -> String? {
            data.withUnsafeBytes { raw -> String? in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var dead: UInt32 = 0, len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
                guard UCKeyTranslate(layout, event.keyCode, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                     OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars) == noErr, len > 0
                else { return nil }
                return String(utf16CodeUnits: chars, count: len)
            }
        }
        guard let plain = type(event.modifierFlags.contains(.shift)), plain.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        let chars = event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) ? plain : (event.characters ?? plain)
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: chars,
                                charactersIgnoringModifiers: plain, isARepeat: event.isARepeat, keyCode: event.keyCode)
    }

    /// Headless: stay off screen (AppKit pulls titled windows onto a display when ordered in).
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        controller?.headless == true ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// Headless: no frame may meet a display (a zoom, a restored frame, a resize): same size, off screen.
    static func offScreen(_ f: NSRect) -> NSRect {
        NSScreen.screens.contains { $0.frame.intersects(f) } ? NSRect(origin: NSPoint(x: -10000, y: -10000), size: f.size) : f
    }
    public override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(controller?.headless == true ? Self.offScreen(frameRect) : frameRect, display: flag)
    }
    public override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(controller?.headless == true ? Self.offScreen(frameRect) : frameRect, display: flag, animate: animate)
    }
    // Headless: zoom, minimize (the genie into the Dock) and full screen would all reach a display.
    public override func zoom(_ sender: Any?) { if controller?.headless != true { super.zoom(sender) } }
    public override func performZoom(_ sender: Any?) { if controller?.headless != true { super.performZoom(sender) } }
    public override func miniaturize(_ sender: Any?) { if controller?.headless != true { super.miniaturize(sender) } }
    public override func performMiniaturize(_ sender: Any?) { if controller?.headless != true { super.performMiniaturize(sender) } }
    public override func toggleFullScreen(_ sender: Any?) { if controller?.headless != true { super.toggleFullScreen(sender) } }
    /// The modifiers of the click being handled (its mouse-down / up). SwiftUI ends a tap
    /// gesture when it likes; NSApp.currentEvent by then can be another event (a click delivered
    /// while the queue held others read the previous click's ⌘ / ⇧, or none).
    @MainActor public static var clickModifiers: NSEvent.ModifierFlags = []

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseUp { Self.clickModifiers = event.modifierFlags }
        if event.type == .keyDown, controller?.handleSidebarKey(event) == true { return }
        if event.type == .leftMouseDown { controller?.sidebarDragCancelled = false; controller?.handleMouseDown(event) }
        if event.type == .leftMouseDragged, let p = controller?.pressedPane, !p.hover.selecting {
            controller?.paneSelectionDrag(p, active: true)
        }
        if event.type == .leftMouseUp, let p = controller?.pressedPane {
            controller?.pressedPane = nil
            controller?.paneSelectionDrag(p, active: false)
        }
        super.sendEvent(event)
        // The press is over: a sidebar drag whose row never saw the mouse-up (sidebar hidden,
        // row closed mid-drag) ends here, so it can't outlive the gesture.
        if event.type == .leftMouseUp, controller?.model.sidebarDrag != nil { controller?.cancelSidebarDrag() }
        if event.type == .leftMouseUp || event.type == .leftMouseDown { controller?.ensureFocus() }
    }
}
