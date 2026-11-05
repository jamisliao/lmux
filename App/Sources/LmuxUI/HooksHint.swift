import AppKit
import LmuxHooks

// "lmux isn't receiving Claude Code hooks from this pane": a claude has run in a pane for a while
// and no hook event ever came from it (hooks not installed, installed in ~/.claude while this
// claude uses another CLAUDE_CONFIG_DIR, or added after it started). One calm card per pane.
//
// No polling: a pane's title change (a command starting; Claude Code titling the terminal) or a Return arms
// one deferred check; nothing runs while the pane is idle, and nothing once a hook was heard.

extension LmuxController {
    /// Any hook event from the pane: hooks work there, the hint is never needed.
    func heardHook(_ pane: Pane) {
        guard !pane.hooksHeard else { return }
        pane.hooksHeard = true
        pane.hooksHintCheck?.cancel()
        pane.hooksHintCheck = nil
    }

    func considerHooksHint(_ pane: Pane, after delay: TimeInterval? = nil) {
        guard !pane.hooksHeard, !pane.hooksHinted, pane.hooksHintCheck == nil else { return }
        let work = DispatchWorkItem { [weak self, weak pane] in
            MainActor.assumeIsolated {
                guard let self, let pane else { return }
                pane.hooksHintCheck = nil
                self.checkHooksHint(pane)
            }
        }
        pane.hooksHintCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? hooksHintDelay), execute: work)
    }

    func checkHooksHint(_ pane: Pane) {
        guard !pane.hooksHeard, !pane.hooksHinted, self.pane(id: pane.id) != nil else { return }
        let fg = pane.surface.foregroundPID
        // Claude Code only: Codex has its own one-time notice (noticeCodexStarting).
        guard fg > 0, let pid = ClaudeProcess.representative(ofGroup: fg), Self.isClaudeNotCodex(pid) else { return }
        // Started since the check was armed: give it the full delay (SessionStart comes within a second).
        let age = ClaudeProcess.age(pid) ?? hooksHintDelay
        if age < hooksHintDelay * 0.8 { considerHooksHint(pane, after: hooksHintDelay - age); return }
        pane.hooksHinted = true
        let hint = Self.hooksHint(settingsPath: HooksSetup.settingsPath(), claudePID: pid, candidates: claudeConfigCandidates())
        log("hooks hint: \(hint.kind) pane=\(pane.id)")
        showCard(pane, message: Self.bold("", "lmux isn’t receiving Claude Code hooks from this pane.", ""),
                 detail: hint.detail, confirmTitle: hint.action, passive: true) { [weak self] in
            guard let self else { return }
            switch hint.kind {
            case .otherConfigDir:
                if let dir = hint.configDir {
                    self.presentHooksSheet(install: true, settingsPath: dir.appendingPathComponent("settings.json").path)
                } else {
                    self.chooseClaudeConfigDirForHooks()
                }
            case .notInstalled: self.presentHooksSheet(install: true)
            case .startedBeforeInstall: break
            }
        }
    }

    /// Where another Claude config dir may be: `~/.claude*` and `~/.config/claude*` (tests: temp dirs).
    func claudeConfigCandidates() -> [URL] {
        if let c = claudeConfigCandidatesOverride { return c }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let fm = FileManager.default
        var dirs: [URL] = []
        for (parent, prefix) in [(home, ".claude"), (home.appendingPathComponent(".config"), "claude")] {
            for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where name.hasPrefix(prefix) {
                dirs.append(parent.appendingPathComponent(name, isDirectory: true))
            }
        }
        return dirs
    }

    nonisolated static func isClaudeNotCodex(_ pid: pid_t) -> Bool {
        ClaudeProcess.isClaude(pid) && !(ClaudeProcess.arguments(pid) ?? []).prefix(2).contains(where: isCodexArgument)
    }

    struct HooksHint: Equatable {
        enum Kind: String { case notInstalled, otherConfigDir, startedBeforeInstall }
        var kind: Kind
        var detail: String
        var action: String
        /// The config dir this claude runs on, when found (otherConfigDir).
        var configDir: URL?
    }

    /// What to say, from where the hooks are and what this claude uses: every running Claude Code
    /// keeps `<config dir>/sessions/<pid>.json`, so a claude with none in the hooks' config dir runs
    /// on another one (its CLAUDE_CONFIG_DIR; macOS doesn't show another process's environment),
    /// found among `candidates` by that same file.
    nonisolated static func hooksHint(settingsPath: String, claudePID: pid_t, candidates: [URL] = []) -> HooksHint {
        let dir = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
        func runs(on d: URL) -> Bool { FileManager.default.fileExists(atPath: d.appendingPathComponent("sessions/\(claudePID).json").path) }
        let own = candidates.first { $0.standardizedFileURL != dir.standardizedFileURL && runs(on: $0) }
        let installed = HookInstaller.isComplete(settingsPath: settingsPath)
        guard installed || own != nil else {
            return HooksHint(kind: .notInstalled,
                             detail: "If you use CLAUDE_CONFIG_DIR, install the hooks there: lmux → Install Claude Code Hooks…",
                             action: "Install Hooks…")
        }
        if let own, !runs(on: dir) {
            return HooksHint(kind: .otherConfigDir,
                             detail: "This Claude Code uses \(abbreviateHome(own.path)) (CLAUDE_CONFIG_DIR); "
                                + (installed ? "the hooks are set up for \(abbreviateHome(dir.path)). Install them there too."
                                             : "lmux’s hooks aren’t installed there yet."),
                             action: "Install There…", configDir: own)
        }
        if !runs(on: dir) {
            return HooksHint(kind: .otherConfigDir,
                             detail: "The hooks are in \(abbreviateHome(settingsPath)), but this Claude Code uses another "
                                + "config folder (CLAUDE_CONFIG_DIR). Install them there too.",
                             action: "Choose Folder…")
        }
        return HooksHint(kind: .startedBeforeInstall,
                         detail: "The hooks are installed; this Claude Code probably started before they were. Restart it here.",
                         action: "OK")
    }

    /// The hint's Choose Folder…: the user's other Claude config dir, then the usual install sheet.
    func chooseClaudeConfigDirForHooks() {
        guard !headless else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the folder your CLAUDE_CONFIG_DIR points to"
        panel.prompt = "Install Hooks Here"
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            // One sheet at a time: after the panel has gone.
            DispatchQueue.main.async {
                self.presentHooksSheet(install: true, settingsPath: url.appendingPathComponent("settings.json").path)
            }
        }
    }
}

extension ClaudeProcess {
    /// Seconds since `pid` started.
    static func age(_ pid: pid_t) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
        return Date().timeIntervalSince1970 - start
    }
}
