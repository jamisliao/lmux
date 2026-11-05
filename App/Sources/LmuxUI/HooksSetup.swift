import AppKit
import LmuxHooks
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

/// Claude Code hooks onboarding (R17): show the exact settings.json diff,
/// install/uninstall with LmuxHooks' installer and the bundled `lmux-hook`.
public enum HooksSetup {
    public static let onboardingDoneKey = "hooksOnboardingDone"
    /// The lmux-hook path the stale-hooks update was last offered for.
    public static let updateOfferedKey = "hooksUpdateOfferedFor"

    public static func settingsPath() -> String { HookInstaller.defaultSettingsPath() }

    public static func planInstall(settingsPath: String, hookBinary: String) throws -> HookInstaller.Change {
        try HookInstaller.planInstall(settingsPath: settingsPath, hookPath: hookBinary)
    }

    /// The settings file's original bytes are kept in lmux's state dir at install, so an
    /// uninstall of an untouched file restores it exactly (R17).
    static var pristineDirectory: URL { LmuxPaths().stateDir.appendingPathComponent("hooks-pristine", isDirectory: true) }

    public static func planUninstall(settingsPath: String) throws -> HookInstaller.Change {
        try HookInstaller.planUninstall(settingsPath: settingsPath, pristineDirectory: pristineDirectory)
    }

    public static func apply(_ change: HookInstaller.Change) throws {
        try HookInstaller.apply(change, pristineDirectory: pristineDirectory)
    }

    /// lmux's hooks are in the settings but run another `lmux-hook` than this lmux's (the app
    /// was moved or reinstalled elsewhere): they would fail silently, the sidebar shows nothing.
    public static func installedHookIsStale(settingsPath: String, hookBinary: String) -> Bool {
        guard let text = try? HookInstaller.read(settingsPath), let status = try? HookInstaller.status(of: text) else { return false }
        let ours = status.commands.filter { $0.contains(HookInstaller.marker) }
        return !ours.isEmpty && ours.contains { $0 != HookInstaller.command(hookPath: hookBinary) }
    }

    /// lmux runs from a copy macOS made because it was opened where it was unzipped (App
    /// Translocation, e.g. straight from Downloads): the path changes on every launch, so hooks
    /// pointing into it would stop working after a quit.
    public static func runsFromTemporaryCopy(_ hookBinary: String) -> Bool {
        hookBinary.contains("/AppTranslocation/")
    }

    public static func isInstalled(settingsPath: String) -> Bool {
        let text = try? HookInstaller.read(settingsPath)
        return (try? HookInstaller.status(of: text))?.isComplete ?? false
    }

    /// Unified diff of a planned change (what the sheet shows).
    public static func diff(_ change: HookInstaller.Change) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lmux-diff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("before.json"), b = dir.appendingPathComponent("after.json")
        try? Data((change.before ?? "").utf8).write(to: a)
        try? Data(change.after.utf8).write(to: b)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        p.arguments = ["-u", "--label", change.path, "--label", change.path + " (after)", a.path, b.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return change.after }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: out, as: UTF8.self)
    }
}

extension LmuxController {
    /// First launch: offer to install hooks (never in headless mode). Later launches: offer to
    /// update hooks that point at another lmux-hook (asked once per path; "Not Now" sticks).
    public func offerHooksOnboardingIfNeeded() {
        guard !headless, let hook = paths.hookBinary, FileManager.default.isExecutableFile(atPath: hook) else { return }
        // Not from a temporary copy: asked again once lmux runs from where it was moved to.
        if HooksSetup.runsFromTemporaryCopy(hook) {
            if !UserDefaults.standard.bool(forKey: HooksSetup.onboardingDoneKey) {
                presentWhenWindowIsUp { $0.presentMoveToApplications() }
            }
            return
        }
        let settings = HooksSetup.settingsPath()
        if HooksSetup.installedHookIsStale(settingsPath: settings, hookBinary: hook),
           UserDefaults.standard.string(forKey: HooksSetup.updateOfferedKey) != hook {
            presentWhenWindowIsUp { c in
                UserDefaults.standard.set(hook, forKey: HooksSetup.updateOfferedKey)
                c.presentHooksSheet(install: true, update: true)
            }
            return
        }
        guard !UserDefaults.standard.bool(forKey: HooksSetup.onboardingDoneKey) else { return offerCodexHooksIfNeeded() }
        if HooksSetup.isInstalled(settingsPath: settings) {
            UserDefaults.standard.set(true, forKey: HooksSetup.onboardingDoneKey)
            return offerCodexHooksIfNeeded()
        }
        presentWhenWindowIsUp { $0.presentHooksSheet(install: true, firstRun: true) }
    }

    /// A sheet on a window that isn't on screen yet (lmux launched in the background, from a
    /// login item or `open -g`) is never shown: wait until the window is visible and key.
    func presentWhenWindowIsUp(_ body: @escaping (LmuxController) -> Void) {
        if window.isVisible, window.isKeyWindow { body(self); return }
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                if let token { NotificationCenter.default.removeObserver(token) }
                guard let self else { return }
                body(self)
            }
        }
        pendingSheetObserver = token
    }

    func presentMoveToApplications() {
        let a = NSAlert()
        a.messageText = "Move lmux to Applications first"
        a.informativeText = "macOS is running lmux from a temporary copy, so Claude Code hooks installed now "
            + "would stop working after you quit. Quit lmux, drag lmux.app to Applications, and open it from there."
        a.beginSheetModal(for: window)
    }

    /// `settingsPath`: another Claude config dir's settings.json (the hooks hint's Install There… / Choose Folder…).
    func presentHooksSheet(install: Bool, firstRun: Bool = false, update: Bool = false, agent: AgentKind = .claude,
                           settingsPath: String? = nil) {
        guard !headless else { return }
        if install, let hook = paths.hookBinary, HooksSetup.runsFromTemporaryCopy(hook) { presentMoveToApplications(); return }
        let codex = agent == .codex
        let settings = settingsPath ?? (codex ? CodexHooksSetup.hooksPath() : HooksSetup.settingsPath())
        let name = codex ? "Codex" : "Claude Code"
        let ch: HookInstaller.Change
        do {
            if install {
                guard let hook = paths.hookBinary else { return }
                ch = codex ? try CodexHooksSetup.planInstall(hooksPath: settings, hookBinary: hook)
                           : try HooksSetup.planInstall(settingsPath: settings, hookBinary: hook)
            } else {
                ch = codex ? try CodexHooksSetup.planUninstall(hooksPath: settings) : try HooksSetup.planUninstall(settingsPath: settings)
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Can’t edit \(settings)"
            a.informativeText = "\(error) Check that it’s valid JSON, then choose lmux → "
                + (install ? "Install \(name) Hooks…" : "Uninstall \(name) Hooks…") + " again."
            a.beginSheetModal(for: window)
            return
        }
        if !ch.changed {
            let alert = NSAlert()
            alert.messageText = install ? "\(name) hooks are already installed" : "No lmux hooks to uninstall"
            alert.beginSheetModal(for: window)
            return
        }
        let sheet = HooksSheet.window(install: install, update: update, diff: HooksSetup.diff(ch), settingsPath: settings,
                                      cancelTitle: firstRun || install ? "Not Now" : "Cancel", agent: agent) { [weak self] confirmed in
            guard let self, let s = self.window.attachedSheet else { return }
            self.window.endSheet(s, returnCode: confirmed ? .OK : .cancel)
        }
        window.beginSheet(sheet) { [weak self] resp in
            if firstRun { UserDefaults.standard.set(true, forKey: codex ? CodexHooksSetup.onboardingDoneKey : HooksSetup.onboardingDoneKey) }
            guard let self else { return }
            if resp == .OK, let error = self.applyHooksChange(ch, install: install, agent: agent) {
                let a = NSAlert()
                a.messageText = install ? "Couldn’t install the \(name) hooks" : "Couldn’t uninstall the \(name) hooks"
                a.informativeText = "\(error) Check that \(settings) is valid JSON, then try "
                    + (install ? "Install \(name) Hooks…" : "Uninstall \(name) Hooks…") + " again."
                a.alertStyle = .warning
                // After this sheet has gone (one sheet at a time).
                DispatchQueue.main.async { a.beginSheetModal(for: self.window) }
            }
            self.settingsModel?.refreshHooks()
            self.focusCurrent()
            // First run: Codex is offered right after Claude Code (one sheet at a time).
            if firstRun, !codex { DispatchQueue.main.async { self.offerCodexHooksIfNeeded() } }
        }
    }

    /// Apply the change the user confirmed. If settings.json changed while the sheet was up, the
    /// same install / uninstall is planned again from the file as it is now (never written over
    /// the edit). Returns the error to show, if any.
    func applyHooksChange(_ ch: HookInstaller.Change, install: Bool, agent: AgentKind = .claude) -> Error? {
        do {
            do {
                try HooksSetup.apply(ch)
            } catch HookInstaller.InstallError.changedSincePlanned {
                guard let hook = paths.hookBinary else { throw HookInstaller.InstallError.changedSincePlanned(ch.path) }
                let again: HookInstaller.Change
                if agent == .codex {
                    again = install ? try CodexHooksSetup.planInstall(hooksPath: ch.path, hookBinary: hook)
                                    : try CodexHooksSetup.planUninstall(hooksPath: ch.path)
                } else {
                    again = install ? try HooksSetup.planInstall(settingsPath: ch.path, hookBinary: hook)
                                    : try HooksSetup.planUninstall(settingsPath: ch.path)
                }
                log("hooks: \(ch.path) changed since shown, planned again")
                try HooksSetup.apply(again)
            }
            return nil
        } catch {
            NSLog("lmux: applying hooks change failed: %@", "\(error)")
            return error
        }
    }

    @objc func installHooksMenu(_ sender: Any?) { presentHooksSheet(install: true) }
    @objc func uninstallHooksMenu(_ sender: Any?) { presentHooksSheet(install: false) }
    @objc func installCodexHooksMenu(_ sender: Any?) { presentHooksSheet(install: true, agent: .codex) }
    @objc func uninstallCodexHooksMenu(_ sender: Any?) { presentHooksSheet(install: false, agent: .codex) }
}

// MARK: - Sheet (POLISH.md 12)

/// The hooks sheet: shows the payoff (three sidebar rows), says what changes in one paragraph,
/// and keeps the exact diff one click away. The uninstall variant has no preview and opens the diff.
enum HooksSheet {
    @MainActor static func window(install: Bool, update: Bool = false, diff: String, settingsPath: String, cancelTitle: String,
                                  agent: AgentKind = .claude, done: @escaping (Bool) -> Void) -> NSWindow {
        let vc = NSHostingController(rootView: HooksSheetView(install: install, update: update, diff: diff, settingsPath: settingsPath,
                                                              cancelTitle: cancelTitle, agent: agent, done: done))
        vc.sizingOptions = .preferredContentSize
        let w = NSWindow(contentViewController: vc)
        w.styleMask = [.titled, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.backgroundColor = T.Colors.elevatedBackground.nsColor
        let name = agent == .codex ? "Codex" : "Claude Code"
        w.setAccessibilityLabel(install ? "Install \(name) hooks" : "Uninstall \(name) hooks")
        return w
    }
}

struct HooksSheetView: View {
    let install: Bool
    /// Installed hooks point at another lmux-hook: the install replaces just that path.
    var update = false
    let diff: String
    let settingsPath: String
    let cancelTitle: String
    /// Whose hooks: Claude Code's settings.json or Codex's hooks.json.
    var agent: AgentKind = .claude
    let done: (Bool) -> Void
    @State private var showDiff: Bool

    init(install: Bool, update: Bool = false, diff: String, settingsPath: String, cancelTitle: String,
         agent: AgentKind = .claude, done: @escaping (Bool) -> Void) {
        self.install = install
        self.update = update
        self.diff = diff
        self.settingsPath = settingsPath
        self.cancelTitle = cancelTitle
        self.agent = agent
        self.done = done
        _showDiff = State(initialValue: !install)
    }

    private var shownPath: String { abbreviateHome(settingsPath) }
    private var agentName: String { agent == .codex ? "Codex" : "Claude Code" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if install {
                previewCard.padding(.bottom, 18)
            }
            Text(update ? "Update lmux’s \(agentName) hooks" : install ? "Know when \(agent.displayName) needs you"
                 : "Uninstall lmux’s \(agentName) hooks?")
                .font(T.Typography.sheetTitle.font)
                .foregroundStyle(T.Colors.textPrimary.color)
                .padding(.bottom, 6)
            bodyText
                .font(T.Typography.sheetBody.font)
                .foregroundStyle(T.Colors.textSecondary.color)
                .lineSpacing(T.Typography.sheetBody.lineHeight - 15)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
            Button {
                withAnimation(T.Motion.reduceMotion ? nil : .easeOut(duration: 0.16)) { showDiff.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showDiff ? 90 : 0))
                    Text(showDiff ? "Hide the exact change" : "Show the exact change")
                }
                .font(.system(size: 12))
                .foregroundStyle(T.Colors.textTertiary.color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showDiff {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : String(line))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(T.Colors.textPrimary.color)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(tint(line))
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.Colors.windowBackground.color))
                .padding(.top, 8)
            }
            HStack(spacing: 8) {
                Spacer()
                SheetButton(title: cancelTitle, primary: false) { done(false) }
                    .keyboardShortcut(.cancelAction)
                SheetButton(title: update ? "Update Hooks" : install ? "Install Hooks" : "Uninstall Hooks", primary: true) { done(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(.top, 22)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: T.Layout.sheetWidth)
        .background(T.Colors.elevatedBackground.color)
    }

    private var bodyText: Text {
        if update {
            return Text("The hooks in ") + Text(shownPath).font(.system(size: 11.5, design: .monospaced))
                + Text(" run an lmux-hook from another copy of lmux, so the sidebar can’t show what \(agent.displayName) is doing. "
                       + "Updating changes only that path; everything else in the file stays the same.")
        }
        if !install {
            return Text("This is the exact change to ") + Text(shownPath).font(.system(size: 11.5, design: .monospaced))
                + Text(". Everything else in the file stays byte for byte the same.")
        }
        if agent == .codex {
            return Text("lmux adds a few hooks to ") + Text(shownPath).font(.system(size: 11.5, design: .monospaced))
                + Text(" so the sidebar can show when Codex is running, done, or waiting on you. Codex asks once to trust "
                       + "new hooks: choose “Trust all and continue” the next time it starts. "
                       + "Uninstalling the hooks restores the file byte for byte.")
        }
        return Text("lmux adds a few hooks to ") + Text(shownPath).font(.system(size: 11.5, design: .monospaced))
            + Text(" so the sidebar can show when Claude is running, done, or waiting on you. Claude runs exactly as before. "
                   + "The first time an agent in another pane needs you, lmux sends a macOS notification, and macOS will ask you to allow it. "
                   + "Uninstalling the hooks restores the file byte for byte.")
    }

    private func tint(_ line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return T.Colors.stateDone.color.opacity(0.12) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return T.Colors.stateFailed.color.opacity(0.12) }
        return .clear
    }

    /// The payoff: three static rows drawn by the sidebar's own row view.
    private var previewCard: some View {
        VStack(spacing: T.Layout.rowGap) {
            WorkspaceRowContent(title: "payments refactor", accent: 0, state: .needsInput("Allow pnpm db:migrate?"),
                                detail: .init(text: "Allow pnpm db:migrate?", tone: .needsInput), unread: 0, selected: false)
            WorkspaceRowContent(title: "flaky IME test", accent: 2, state: .running("Bash · swift test"),
                                detail: .init(text: "Bash · swift test", tone: .secondary), unread: 0, selected: false)
            WorkspaceRowContent(title: "bench script", accent: 3, state: .done("RSS table is ready"),
                                detail: .init(text: "RSS table is ready", tone: .secondary, age: "4m"), unread: 0, selected: false)
        }
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.Colors.windowBackground.color))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.Colors.separator.color, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// 28pt sheet button: neutral (`rowSelected` fill) or primary (`accent`).
struct SheetButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: primary ? .semibold : .regular))
                .foregroundStyle((primary ? T.Colors.onAccent : T.Colors.textPrimary).color)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: T.Radius.button, style: .continuous)
                    .fill(primary ? T.Colors.accent.color : T.Colors.rowSelected.color))
                .overlay(RoundedRectangle(cornerRadius: T.Radius.button, style: .continuous)
                    .fill(hover ? T.Colors.rowHover.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
