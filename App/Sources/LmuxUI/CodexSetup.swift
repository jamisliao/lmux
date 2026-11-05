import AppKit
import LmuxHooks

// Codex CLI in lmux: the same hook-driven integration as Claude Code (never a wrapper).
// Hooks go into $CODEX_HOME/hooks.json (LmuxHooks.CodexHookInstaller); Codex runs them only
// after the user trusted them once in Codex. Resume replays `codex resume <flags> <id>`.

/// Codex hooks setup: the paths and plans the sheet and Settings use.
public enum CodexHooksSetup {
    public static let onboardingDoneKey = "codexHooksOnboardingDone"
    public static let updateOfferedKey = "codexHooksUpdateOfferedFor"

    public static func hooksPath() -> String { CodexHookInstaller.defaultHooksPath() }

    public static func planInstall(hooksPath: String, hookBinary: String) throws -> HookInstaller.Change {
        try CodexHookInstaller.planInstall(hooksPath: hooksPath, hookPath: hookBinary)
    }

    public static func planUninstall(hooksPath: String) throws -> HookInstaller.Change {
        try CodexHookInstaller.planUninstall(hooksPath: hooksPath, pristineDirectory: HooksSetup.pristineDirectory)
    }

    public static func isInstalled(hooksPath: String = hooksPath()) -> Bool {
        CodexHookInstaller.isComplete(hooksPath: hooksPath)
    }

    public static func trust(hooksPath: String = hooksPath()) -> CodexHookInstaller.Trust {
        CodexHookInstaller.trust(hooksPath: hooksPath, configPath: CodexHookInstaller.configPath())
    }

    /// lmux's Codex hooks run another lmux-hook than this lmux's (the app moved).
    public static func installedHookIsStale(hooksPath: String, hookBinary: String) -> Bool {
        guard let text = try? HookInstaller.read(hooksPath),
              let status = try? HookInstaller.status(of: text, target: CodexHookInstaller.target) else { return false }
        let want = HookInstaller.command(hookPath: hookBinary, argument: AgentKind.codex.rawValue)
        return status.commands.contains { $0 != want }
    }
}

extension LmuxController {
    /// After Claude Code's onboarding: offer Codex's hooks when Codex is on this Mac (once),
    /// or an update when lmux's Codex hooks point at another lmux-hook (once per path).
    func offerCodexHooksIfNeeded() {
        guard !headless, let hook = paths.hookBinary, FileManager.default.isExecutableFile(atPath: hook) else { return }
        let path = CodexHooksSetup.hooksPath()
        let defaults = UserDefaults.standard
        if CodexHooksSetup.installedHookIsStale(hooksPath: path, hookBinary: hook),
           defaults.string(forKey: CodexHooksSetup.updateOfferedKey) != hook {
            presentWhenWindowIsUp { c in
                defaults.set(hook, forKey: CodexHooksSetup.updateOfferedKey)
                c.presentHooksSheet(install: true, update: true, agent: .codex)
            }
            return
        }
        guard !defaults.bool(forKey: CodexHooksSetup.onboardingDoneKey), CodexHookInstaller.isInstalled() else { return }
        if CodexHooksSetup.isInstalled(hooksPath: path) {
            defaults.set(true, forKey: CodexHooksSetup.onboardingDoneKey)
            return
        }
        presentWhenWindowIsUp { $0.presentHooksSheet(install: true, firstRun: true, agent: .codex) }
    }

    /// Capture how the pane's codex was started (its argv, read once at SessionStart), so restore
    /// resumes it with the same model, sandbox, approvals, profile and `-c` overrides.
    func captureCodexResumeCommand(_ pane: Pane, _ e: HookEvent, sessionID sid: String) {
        let p = e.claudePID ?? ClaudeProcess.representative(ofGroup: pane.surface.foregroundPID)
        let tail = " " + ClaudeCommand.shellQuote(sid)
        guard let cl = p.flatMap(ClaudeProcess.commandLine), cl.argv.contains(where: Self.isCodexArgument) else {
            // Not readable: keep what we had for this session, else plain resume (seen starting only).
            if !(pane.resumeCommand?.hasSuffix(tail) ?? false) {
                pane.resumeCommand = e.kind == .sessionStart ? CodexCommand.resume(argv: nil, sessionID: sid) : nil
            }
            return
        }
        pane.resumeCommand = CodexCommand.resume(argv: cl.argv, sessionID: sid)
    }

    /// `codex` itself, or node running the npm package's `codex.js`.
    nonisolated static func isCodexArgument(_ a: String) -> Bool {
        (a as NSString).lastPathComponent == "codex" || a.hasSuffix("/codex.js")
    }

    /// The pane's title says a `codex` started (shells title the window with the command). If no
    /// Codex hook has reported anything a while later, Codex isn't running lmux's hooks: most
    /// likely they were never trusted ("Continue without trusting"). Say so once per launch (also
    /// for a Codex session lmux resumed: it has a session id before any hook),
    /// in that pane. One delayed check; nothing is polled.
    func noticeCodexStarting(_ pane: Pane, title: String) {
        guard !codexHintShown, codexHookEvents == 0, codexHintWork == nil, !pane.runsClaude || pane.runsCodex,
              title.split(separator: " ").first.map({ ($0 as NSString).lastPathComponent == "codex" }) == true else { return }
        let work = DispatchWorkItem { [weak self, weak pane] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.codexHintWork = nil
                guard let pane, !self.codexHintShown, self.codexHookEvents == 0, !pane.runsClaude || pane.runsCodex,
                      self.runningProcess(pane) != nil else { return }
                let text: String
                switch CodexHooksSetup.trust() {
                case .notInstalled:
                    return  // the user chose not to install them: nothing to say
                case .needsReview:
                    text = "Codex isn’t running lmux’s hooks yet. Restart codex and choose “Trust all and continue”."
                case .trusted:
                    // Its status comes from its own terminal (OSC 7501); its session only with hooks.
                    text = pane.codexReport != nil
                        ? "Codex’s hooks haven’t reached lmux: its status shows, but resume, History and titles need them."
                        : "Codex hasn’t reported to lmux yet. Check that hooks are on in Codex (features.hooks)."
                }
                self.codexHintShown = true
                self.showNote(pane, text, duration: 10)
            }
        }
        codexHintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + codexHintDelay, execute: work)
    }
}
