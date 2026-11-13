import AppKit
import LmuxHooks
import LmuxTerminal
import LmuxTranscript
import os
import UserNotifications

private let hookLog = Logger(subsystem: "dev.lmux.app", category: "hooks")

// Agent awareness (R13-R15): hook events -> PaneAgent per pane -> sidebar,
// ring, unread, and the single notification path.

extension LmuxController {
    func startHookServer() {
        let server = HookSocketServer(path: paths.hookSocket, onEvent: { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleSocketHook(event) } }
        }, onError: { msg in
            // Sizes and parse errors only (HookSocketServer never puts line content in `msg`).
            hookLog.error("hook socket: \(msg, privacy: .private)")
        })
        do {
            try server.start()
            hookServer = server
        } catch {
            NSLog("lmux: hook server not started (%@): agent state disabled", "\(error)")
        }
    }

    /// An event from the hook socket: handled only when it carries the token of the pane it
    /// names (lmux-hook sends the pane's LMUX_PANE_NONCE). Anything else is dropped unread.
    /// A closed pane's token (with that pane's id) still counts for Codex's shared app-server,
    /// which keeps the environment of the codex that started it: its events go by session only.
    func handleSocketHook(_ e: HookEvent) {
        guard let token = e.paneToken else { return dropSocketHook(e) }
        if pane(token: token)?.id == e.paneID { return handleHook(e) }
        guard e.agent == .codex, retiredPaneTokens.contains(where: { $0.token == token && $0.paneID == e.paneID }),
              runsOnSharedCodexServer(e) else { return dropSocketHook(e) }
        hookTap?(e)
        routeSharedCodex(e)
    }

    private func dropSocketHook(_ e: HookEvent) {
        hookLog.notice("hook event dropped: no valid pane token (kind \(e.kind.rawValue, privacy: .private))")
    }

    /// One hook event for the pane named by its LMUX_PANE_ID.
    public func handleHook(_ event: HookEvent) {
        hookTap?(event)
        if event.agent == .codex, runsOnSharedCodexServer(event) { routeSharedCodex(event); return }
        guard let pane = pane(id: event.paneID) else { return }
        handleHook(event, on: pane)
    }

    func handleHook(_ event: HookEvent, on pane: Pane) {
        let e = codexRunnerAsCodex(pane, event)
        if e.agent == .claude { heardHook(pane) }  // (the hooks hint is about Claude Code's hooks)
        if e.agent == .codex { pane.ranCodex = true }
        guard acceptHook(pane, e) else {
            log("hook ignored: \(e.name) session=\(e.sessionID ?? "-") pid=\(e.claudePID ?? 0) pane=\(pane.claudeSessionID ?? "-")")
            return
        }
        // Hooks win over a program's own reports (Claude Code printing OSC 7501 too: one source, one alert).
        if pane.programApp != nil { forgetProgramReport(pane) }
        if e.agent == .codex {
            codexHookEvents += 1
            // Codex asks the user only after a moment it isn't approved some other way (auto
            // review, a rule): the same agent going on meanwhile (or the turn ending) means it
            // was approved without the user. Subagents working in parallel don't count.
            if let pending = codexPermissionWork[pane.id],
               pending.agent == (e.agentID ?? "") || [.stop, .interrupt, .userPromptSubmit, .sessionStart, .sessionEnd].contains(e.kind) {
                pending.work.cancel()
                codexPermissionWork[pane.id] = nil
            }
            if e.kind == .permissionRequest, pane.codexReport == nil {
                // Never "needs input" when Codex isn't asking (approvals bypassed).
                guard !["bypassPermissions", "dontAsk"].contains(e.permissionMode ?? "") else { return }
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.codexPermissionWork.removeValue(forKey: e.paneID) != nil,
                              let pane = self.pane(id: e.paneID) else { return }
                        self.processHook(pane, e)
                    }
                }
                codexPermissionWork[pane.id]?.work.cancel()  // a newer request replaces it (cancelled items never run)
                codexPermissionWork[pane.id] = (e.agentID ?? "", work)
                DispatchQueue.main.asyncAfter(deadline: .now() + codexPermissionGrace, execute: work)
                return
            }
        }
        processHook(pane, e)
    }

    /// `handleHook` once the event is accepted (and, for a Codex permission request, still pending).
    func processHook(_ pane: Pane, _ e: HookEvent) {
        noteAgentActivity(pane)
        // The header's mode badge follows the main agent's `permission_mode` (every event has it).
        if !e.isSubagent, let m = e.permissionMode, Self.permissionModes.contains(m), pane.permissionMode != m {
            pane.permissionMode = m
        }
        // Remember the session for `claude --resume` / `codex resume` on restore.
        let before = pane.claudeSessionID
        if e.kind == .sessionEnd {
            pane.claudeSessionID = nil
            pane.claudePID = nil
            pane.resumeCommand = nil
            pane.resumeEnvironment = [:]
            pane.claudeEnvironment = [:]
        } else if let sid = e.sessionID, !sid.isEmpty {
            if sid != pane.claudeSessionID {
                pane.claudePID = e.claudePID
                pane.agentKind = e.agent
                pane.claudeSessionID = sid
            }
            if let tp = e.transcriptPath, !tp.isEmpty, tp != pane.transcriptPath { pane.transcriptPath = tp }
            if pane.claudePID == nil { pane.claudePID = e.claudePID }
        }
        // A new prompt or session: a pending look for an Esc interrupt is about the old turn.
        if [.userPromptSubmit, .sessionStart, .sessionEnd].contains(e.kind) { interruptChecks[pane.id] = nil }
        if pane.claudeSessionID != before {
            if e.kind == .sessionStart || before == nil { captureResumeCommand(pane, e) }
            scheduleSave()
        }

        // Titles, message actions, History.
        switch e.kind {
        case .sessionStart:
            titleSessionStarted(pane, e)
            pane.relaunchingSessionID = nil
            pane.rewoundFrom = nil
        case .userPromptSubmit:
            pane.promptAt = ProcessInfo.processInfo.systemUptime
            promptSubmitted(pane, prompt: e.prompt)
            attended(pane)
        case .stop where !e.isSubagent:
            pane.lastReply = e.lastAssistantMessage
            pane.lastReplyAt = ProcessInfo.processInfo.systemUptime
            scheduleTitleRefresh(pane)
            history.scheduleRefresh()
        case .sessionEnd:
            hideHoverActions(pane)
            history.scheduleRefresh()
            resetAfterClaude(pane)
        default:
            break
        }
        if pane.workspace === model.selected { scheduleOverlayRefresh(pane, delay: 0.25) }

        // Observed properties are set only when they change: an equal write still redraws the sidebar.
        if e.kind == .preToolUse, !e.isSubagent, let tool = e.toolName {
            let t = e.toolArgument.map { "\(tool) · \($0)" } ?? tool
            if pane.lastTool != t { pane.lastTool = t }
        }
        // 壓縮中：workspace 列第 2 行顯示 Compacting，不顯示上一個回合的工具（beat: compaction-running-state.feature）。
        // 下一個 PreToolUse 會覆蓋它，UserPromptSubmit 會清掉它。
        if e.kind == .preCompact, !e.isSubagent, pane.lastTool != "Compacting" { pane.lastTool = "Compacting" }
        // 壓縮結束（SessionStart(compact) 或 PostCompact）：回合中的自動壓縮之後 Claude 可能還沒呼叫工具，別讓它一直顯示 Compacting。
        if e.kind == .postCompact || (e.kind == .sessionStart && e.source == "compact"), !e.isSubagent,
           pane.lastTool == "Compacting" { pane.lastTool = nil }
        if e.kind == .userPromptSubmit {
            if pane.failed { pane.failed = false }
            if pane.lastTool != nil { pane.lastTool = nil }
            if pane.alertDetail != nil { pane.alertDetail = nil }
        }

        // A codex that reports its own state (OSC 7501) has it from there: hooks only bring the
        // text of its alerts (and a late one fills in the row's detail, without a second alert).
        if e.agent == .codex, pane.codexReport != nil {
            switch e.kind {
            case .stop where !e.isSubagent:
                pane.codexTurnReply = e.lastAssistantMessage
                if pane.agent.state == .done, !pane.failed, pane.alertDetail == nil {
                    pane.alertDetail = e.lastAssistantMessage.flatMap(Self.firstLine)
                }
            case .permissionRequest:
                pane.codexAsk = e.toolName.map { "Permission: \($0)" }
                if pane.needsInput, pane.alertDetail == Self.describe(.permission) { pane.alertDetail = pane.codexAsk }
            case .subagentStart, .subagentStop:
                // The count only (subagent events never change the state).
                var agent = pane.agent
                agent.handle(e, focused: false)
                if agent != pane.agent { pane.agent = agent }
            default:
                break
            }
            schedulePaneChrome(pane)
            return
        }

        let focused = isPaneFocused(pane)
        var agent = pane.agent
        // The restored agent resuming its own session: it still sits on the done turn it ended on.
        let resumed = e.kind == .sessionStart && e.source != "clear" && e.sessionID == pane.restoredDoneSession
        if e.kind == .sessionStart { pane.restoredDoneSession = nil }
        let t = resumed ? nil : agent.handle(e, focused: focused)
        if agent != pane.agent {
            if (agent.state == .done) != (pane.agent.state == .done) { scheduleSave() }  // (a relaunch shows ✓ again)
            // A wait that ended or began: its deadline is computed afresh (even within one burst of events).
            if agent.usageLimitResets != pane.agent.usageLimitResets { pane.usageLimitDeadline = nil }
            pane.agent = agent
        }
        apply(t, to: pane, focused: focused)
    }

    /// Badge, row detail, bell list and the one notification for a state transition.
    func apply(_ t: AgentTransition?, to pane: Pane, focused: Bool) {
        if let alert = t?.alert {
            switch alert {
            case .needsInput(let reason, let message):
                pane.failed = false
                pane.alertDetail = message ?? Self.describe(reason)
            case .done(let last):
                pane.failed = false
                pane.alertDetail = last.flatMap(Self.firstLine)
            case .failed(let type):
                pane.failed = true
                pane.alertDetail = type
            }
            pane.lastAlertAt = Date()
            if !focused { pane.unread += 1 }
            let kind: String
            switch alert {
            case .needsInput: kind = "needsInput"
            case .done: kind = "done"
            case .failed: kind = "failed"
            }
            if kind != "failed" { noteAttentionNeeded(pane) }
            model.recordNotification(NotificationEntry(
                paneID: pane.id, workspaceID: pane.workspace?.id, title: pane.workspace?.title ?? "lmux",
                message: pane.alertDetail ?? pane.display.label, kind: kind, read: focused))
        }
        if let n = t?.notify {
            notifier.post(title: pane.workspace?.title ?? "lmux", body: Self.body(n), paneID: pane.id,
                          kind: Self.kind(n))
        }
        schedulePaneChrome(pane)
    }

    /// The chrome a hook event can change (the pane's ring and header, the content header, the
    /// Dock badge, reminders), once per runloop turn for every event that came in: busy agents
    /// send a burst of events, and only the panes they name are looked at.
    func schedulePaneChrome(_ pane: Pane) {
        chromePending.insert(pane.id)
        guard !chromeScheduled else { return }
        chromeScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.flushPaneChrome() } }
    }

    func flushPaneChrome() {
        guard chromeScheduled else { return }
        chromeScheduled = false
        let ids = chromePending
        chromePending = []
        let active = isAppActive
        let sel = model.selected
        var shown = false
        for id in ids {
            guard let p = pane(id: id), let ws = p.workspace else { continue }
            let focused = ws === sel && ws.focusedPane === p
            if p.isFocused != focused { p.isFocused = focused }
            if focused && active && p.unread > 0 { p.unread = 0 }
            if ws === sel {
                shown = true
                p.view.ring.setShown(p.showsRing && settings.unreadRing)
                p.view.header.focused = focused
                p.view.header.needsInput = p.needsInput
                p.view.header.modeBadge = p.modeBadge
            }
        }
        if shown, let sel {
            refreshHeaders(sel)
            root.updateHeader()
        }
        updateAgeTick()
        updateDockBadge()
        updatePulseMotion()
        updateAttention()
    }

    /// Claude left the pane (SessionEnd, or it's gone without one: killed, Ctrl-C twice). The pane
    /// is a shell again: no agent state, no input label, and its title goes back to the shell's
    /// (the session's auto title lives on in History). A title the user set stays.
    func resetAfterClaude(_ pane: Pane) {
        forgetCodexReport(pane)
        pane.claudeSessionID = nil
        pane.lastReply = nil
        pane.claudePID = nil
        pane.resumeCommand = nil
        pane.resumeEnvironment = [:]
        pane.claudeEnvironment = [:]
        pane.agent = PaneAgent()
        pane.failed = false
        pane.alertDetail = nil
        pane.lastTool = nil
        pane.permissionMode = nil
        if !pane.titleState.isManual { pane.titleState = TitleState() }
        pane.titleSession = nil
        pane.transcriptPath = nil
        hideHoverActions(pane)
        refreshInputLabel(pane)
        if let ws = pane.workspace { refreshHeaders(ws) }
        refreshPaneChrome()
        scheduleSave()
    }

    /// Esc / Ctrl+C in a pane where Claude Code is working. Claude sends no hook when the turn
    /// stops that way; it ends the turn in the transcript with `[Request interrupted by user…]`.
    /// So look there once shortly after the key (and once more if it isn't written yet), reading
    /// only what Claude appended, and move the pane to idle if the turn ended: no alert, no
    /// notification. Esc before any reply text writes no marker (Claude puts the prompt back in
    /// its input box); then Claude's own terminal title, back to `✳` from its working spinner, is
    /// the sign at the last look. Esc that stopped nothing (closed a menu) leaves the pane
    /// running. Nothing runs without the key. Codex sends its own Interrupt hook. Not while the turn
    /// waits for a usage limit: Claude sits at its prompt then (`✳`), and the wait isn't stopped by a key.
    func interruptKeyPressed(_ pane: Pane, esc: Bool = true) {
        if esc { pane.lastEscKey = Date() }
        guard pane.runsClaude, !pane.runsCodex, pane.agent.state == .running, pane.agent.usageLimitResets == nil,
              let path = pane.transcriptPath, TranscriptPath.isClaudeTranscript(path) else { return }
        let token = UUID()
        interruptChecks[pane.id] = token
        Task { [weak self, weak pane] in
            for (n, delay) in [300, 900].enumerated() {
                await sleepMs(delay)
                guard let self, let pane, self.interruptChecks[pane.id] == token,
                      pane.agent.state == .running, pane.transcriptPath == path else { return }
                let last = await self.loadTurns(pane).last
                guard self.interruptChecks[pane.id] == token, pane.agent.state == .running,
                      pane.agent.usageLimitResets == nil else { return }
                // 壓縮中按 Esc：Claude 取消壓縮，不會寫中斷標記，標題也不一定變回 ✳（beat: compaction-running-state.feature）。
                // 看狀態機的旗標，不看第 2 行的文字：回合中的自動壓縮結束後，旗標是 false。
                let compacting = pane.agent.isCompacting
                if last?.interrupted == true || (n == 1 && (compacting || pane.surface.title.hasPrefix("✳"))) {
                    self.interruptChecks[pane.id] = nil
                    pane.agent.userInterrupted()
                    self.log("interrupted with no hook: pane=\(pane.id) idle")
                    self.schedulePaneChrome(pane)
                    return
                }
            }
            if let self, let pane, self.interruptChecks[pane.id] == token { self.interruptChecks[pane.id] = nil }
        }
    }

    /// The pane's title changed (a shell prints its prompt after every command): if lmux still
    /// thinks Claude runs here but its process is gone, Claude ended without a SessionEnd.
    func checkClaudeStillRunning(_ pane: Pane) {
        // A codex that reported its state but no session (no hook reached lmux), gone with no `clear`.
        if pane.codexReport != nil, !pane.runsClaude, runningProcess(pane) == nil {
            log("codex gone without a clear: pane=\(pane.id.prefix(8))")
            forgetCodexReport(pane)
            pane.agent = PaneAgent()
            schedulePaneChrome(pane)
        }
        programMayBeGone(pane)
        pane.lastWords = nil  // (a prompt came back: nothing more from the program that quit)
        guard pane.runsClaude, !pane.busy, pane.relaunchingSessionID == nil else { return }
        let gone = pane.claudePID.map { kill($0, 0) != 0 } ?? false
        if gone || (pane.claudePID == nil && runningProcess(pane) == nil) { resetAfterClaude(pane) }
    }

    /// Manually clears a pane's agent status (ring, badge, state glyph) for when a hook was
    /// missed (cmux #1027/#2576): the agent process is untouched, and the next hook event updates
    /// the pane normally again.
    public func clearStatus(_ pane: Pane) {
        pane.agent = PaneAgent()
        pane.failed = false
        pane.alertDetail = nil
        pane.lastTool = nil
        pane.unread = 0
        pane.attentionSince = nil
        // What was already on its way for it is cleared too: Codex's pending "needs input" and a
        // coalesced `lmux notify` would otherwise bring the ring / badge back a moment later.
        codexPermissionWork.removeValue(forKey: pane.id)?.work.cancel()
        notifyGate[pane.id]?.work?.cancel()
        notifyGate[pane.id]?.work = nil
        notifyGate[pane.id]?.pending = nil
    }

    /// The row's "Clear Status": every pane of the workspace (or the selection it's part of, via
    /// `closeTargets`), plus the row's own latest `lmux notify` text.
    public func clearStatus(for ws: Workspace) {
        for w in closeTargets(for: ws) {
            for p in w.panes { clearStatus(p) }
            w.notification = nil
        }
        refreshPaneChrome()
        updateAttention()
        scheduleSave()
    }

    /// Capture how the pane's claude was started, so restore resumes it the same way (R11).
    func captureResumeCommand(_ pane: Pane, _ e: HookEvent) {
        guard let sid = pane.claudeSessionID, ClaudeCommand.isSessionID(sid) else { pane.resumeCommand = nil; return }
        // Allowlisted names only (lmux-hook filters too; never trust the wire for this).
        if e.claudePID != nil { pane.claudeEnvironment = e.claudeEnvironment.filter { HookClient.replayable($0.key) } }
        pane.resumeEnvironment = pane.claudeEnvironment
        if pane.agentKind == .codex { return captureCodexResumeCommand(pane, e, sessionID: sid) }
        let p = e.claudePID ?? ClaudeProcess.representative(ofGroup: pane.surface.foregroundPID)
        guard let cl = p.flatMap(ClaudeProcess.commandLine), cl.argv.contains(where: {
            ($0 as NSString).lastPathComponent == "claude" || $0.hasSuffix("/cli.js") || $0.hasSuffix("/cli.mjs")
        }) else {
            // Not readable (or not claude): keep what we had for this session, else plain resume,
            // but only for a claude seen starting (SessionStart). Bound by some other event from a
            // process lmux can't read, the pane may hold anything: restore then starts a plain shell.
            guard e.kind == .sessionStart else {
                if !(pane.resumeCommand?.hasSuffix(" --resume " + ClaudeCommand.shellQuote(sid)) ?? false) { pane.resumeCommand = nil }
                return
            }
            if !(pane.resumeCommand?.hasSuffix(" --resume " + ClaudeCommand.shellQuote(sid)) ?? false) {
                pane.resumeCommand = ClaudeCommand.resume(argv: nil, sessionID: sid)
            }
            return
        }
        // The command only; its env is kept apart and handed to a restored shell, never typed.
        pane.resumeCommand = ClaudeCommand.resume(argv: cl.argv, sessionID: sid)
    }

    /// Whether `e` belongs to the Claude session the pane shows. The pane is bound to the
    /// first live top-level session (the pty's foreground claude); a `claude -p` started
    /// inside it (Claude's Bash tool, a script) inherits LMUX_PANE_ID but runs in another
    /// process group, and its events never change the pane's session, state or title.
    /// A real switch (quit + new claude, `/clear`, `/resume`) arrives as a SessionStart
    /// from the foreground claude and rebinds the pane.
    func acceptHook(_ pane: Pane, _ e: HookEvent) -> Bool {
        if isNestedClaude(pane, e) == true { return false }
        let sid = e.sessionID ?? ""
        // Only the pane's foreground claude may bind or switch it. A claude outside that group
        // (nohup / double fork from Claude's Bash tool reparents to launchd, so no ancestor
        // shows it) only ever reaches the session the pane already shows.
        if let pgid = e.claudePGID, case let fg = pane.surface.foregroundPID, fg > 0, pgid != fg,
           sid != pane.claudeSessionID || sid.isEmpty {
            return false
        }
        guard let bound = pane.claudeSessionID else { return e.kind != .sessionEnd || sid.isEmpty }
        if sid.isEmpty || sid == bound { return true }
        // Another session from the pane's own (or a new foreground) claude: a switch.
        return e.kind == .sessionStart
    }

    // MARK: Codex's own status (OSC 7501)

    /// What the codex in this pane says it is doing, in its own terminal (OSC 7501). From its
    /// first report on, this is the pane's state and the source of its alerts (one notification
    /// per event); hooks still bring the session (resume, History, titles) and the alerts' text.
    func programStatus(_ pane: Pane, _ s: SurfaceView.ProgramStatus) {
        // Codex says `clear` (it quits) without its name. After its SessionEnd it has nothing left to clear.
        guard s.app == "codex" || (s.app.isEmpty && s.state == .clear && pane.programApp == nil
                                   && (pane.codexReport != nil || pane.ranCodex)) else { return otherProgramStatus(pane, s) }
        if s.state == .clear, pane.codexReport == nil, pane.codexHeld.isEmpty {
            log("codex report: pane=\(pane.id.prefix(8)) clear (already a shell)")
            return
        }
        // A new state only from a codex in the foreground (any program can print the escape).
        if s.state != .clear, s.state != pane.codexReport, !foregroundIsCodex(pane) {
            log("codex report ignored: pane=\(pane.id.prefix(8)) \(s.state): codex isn't its foreground program")
            return
        }
        log("codex report: pane=\(pane.id.prefix(8)) \(s.state)\(s.kind.map { ":" + $0 } ?? "")")
        noteAgentActivity(pane)
        if s.state != .clear { pane.ranCodex = true }
        if pane.programApp != nil { forgetProgramReport(pane) }  // (codex took the pane over)
        // While a session from Codex's shared server may still turn out to be this pane's, its
        // alert waits for it (its text, the tool asked for or the reply, comes with that
        // session's hooks), in order, each report no longer than the window after it came.
        if !pane.codexHeld.isEmpty || ([.blocked, .done].contains(s.state) && waitsForCodexSession(pane)) {
            pane.codexHeld.append(s)
            let wait = max(0, s.at.addingTimeInterval(Self.codexBindWindow).timeIntervalSinceNow)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak pane] in
                MainActor.assumeIsolated { if let self, let pane { self.releaseHeldCodexReports(pane, through: s.at) } }
            }
            return
        }
        applyProgramStatus(pane, s)
    }

    private func applyProgramStatus(_ pane: Pane, _ s: SurfaceView.ProgramStatus) {
        let was = pane.codexReport
        pane.codexReport = s.state == .clear ? nil : s.state
        let state: PaneAgent.ProgramState
        var message: String?
        switch s.state {
        case .idle: state = .idle
        case .working:
            state = .working
            if was != .working, was != .blocked {
                // A new turn: the previous one's reply and request are no longer this turn's.
                pane.codexTurnStartedAt = s.at
                pane.codexTurnReply = nil
                pane.codexAsk = nil
                if pane.failed { pane.failed = false }
                if pane.alertDetail != nil { pane.alertDetail = nil }
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.bindPendingCodexSessions() } }
            }
        case .blocked:
            switch s.kind {
            case "question": state = .blocked(.question); message = "Codex has a question"
            case "auth": state = .blocked(.permission); message = "Codex needs you to sign in"
            default: state = .blocked(.permission); message = pane.codexAsk
            }
        case .done: state = .done
        case .error: state = .error
        case .clear:
            state = .clear
            pane.codexTurnStartedAt = nil
        }
        let focused = isPaneFocused(pane)
        var agent = pane.agent
        let t = agent.report(state, message: message, lastMessage: pane.codexTurnReply, focused: focused)
        if agent != pane.agent {
            if (agent.state == .done) != (pane.agent.state == .done) { scheduleSave() }  // (a relaunch shows ✓ again)
            pane.agent = agent
        }
        apply(t, to: pane, focused: focused)
        if s.state == .clear {
            if pane.runsCodex { resetAfterClaude(pane) } else { forgetCodexReport(pane) }
        }
    }

    // MARK: Any other program's own status (OSC 7501)

    /// A program other than Codex reporting its state (OSC 7501 `state=…:app=<name>`): the
    /// pane's state, ring and one notification per wait come from it as from Codex's reports,
    /// with its name as the agent's. Status only: no session (no resume, History or Forget).
    /// Hooks win: a pane whose Claude Code (or Codex) session they bound ignores these.
    /// A new state counts only from the pane's foreground job when that job is the program
    /// `app=` names (`ProgramReporter`): a file shown with `cat` can't name `cat`'s job as
    /// anything else. One exception: the reporter's last words (it reported and quit before lmux
    /// looked), once, from the same app after its job is gone.
    func otherProgramStatus(_ pane: Pane, _ s: SurfaceView.ProgramStatus) {
        if s.state == .clear {
            guard let app = pane.programApp, s.app.isEmpty || s.app == app, fromReporter(pane, app: app, s.state) else { return }
            log("program report: pane=\(pane.id.prefix(8)) \(app) clear")
            forgetProgramReport(pane)
            if pane.agent.state != .done { pane.agent = PaneAgent() }  // (a finished turn stays, as below)
            schedulePaneChrome(pane)
            return
        }
        guard !s.app.isEmpty, !pane.runsClaude, pane.codexReport == nil else { return }
        // The same report again (a redraw, a retry printing its error twice): nothing new, nothing
        // to check. Unless the user answered meanwhile: then a `blocked` is the next ask.
        // (The same job's: a reporter restarted under the same name binds its new job.)
        let newAsk = s.state == .blocked && pane.programAnswered
        if s.state == pane.programReport, s.app == pane.programApp, s.kind == pane.programKind, !newAsk,
           pane.programGroup == pane.surface.foregroundPID { return }
        guard fromReporter(pane, app: s.app, s.state) else { return }
        log("program report: pane=\(pane.id.prefix(8)) \(s.app) \(s.state)\(s.kind.map { ":" + $0 } ?? "")")
        noteAgentActivity(pane)
        let was = pane.programReport
        if pane.programApp != s.app { pane.foregroundCache = nil }  // (the header names it: see apply's chrome)
        pane.programApp = s.app
        pane.programReport = s.state
        pane.programKind = s.kind
        pane.programAnswered = false
        let state: PaneAgent.ProgramState
        var message: String?
        switch s.state {
        case .idle: state = .idle
        case .working:
            state = .working
            if was != .working, was != .blocked {
                if pane.failed { pane.failed = false }
                if pane.alertDetail != nil { pane.alertDetail = nil }
            }
        case .blocked:
            switch s.kind {
            case "question": state = .blocked(.question); message = "\(s.app) has a question"
            case "auth": state = .blocked(.permission); message = "\(s.app) needs you to sign in"
            default: state = .blocked(.permission); message = "\(s.app) needs you"
            }
        case .done: state = .done
        case .error: state = .error
        case .clear: state = .clear
        }
        let focused = isPaneFocused(pane)
        var agent = pane.agent
        if newAsk, case .needsInput = agent.state {
            // The last ask was answered: a state change of its own (`lmux wait` sees a new ask).
            agent.report(.working, focused: focused)
            pane.agent = agent
        }
        let t = agent.report(state, message: message, focused: focused)
        if agent != pane.agent { pane.agent = agent }
        apply(t, to: pane, focused: focused)
    }

    /// The report came from the program `app` names: the pane's foreground job is that program
    /// (remembered as the reporter), or it is the reporter's last words, once: its job is gone,
    /// the shell has the terminal back (not the next job: `my-agent; cat notes` can't speak for
    /// it) and the words end a turn (a program that quit isn't working or waiting for anyone).
    private func fromReporter(_ pane: Pane, app: String, _ state: SurfaceView.ProgramStatus.State) -> Bool {
        let fg = pane.surface.foregroundPID
        let argv = foregroundArgv(pane, fg)
        if let argv, ProgramReporter.namesItself(app, argv: argv) {
            if pane.programGroup != fg { watchReporterExit(pane, fg) }
            pane.programGroup = fg
            return true
        }
        let reporter: (app: String, group: pid_t)? = pane.programApp.map { ($0, pane.programGroup) } ?? pane.lastWords
        if let (rApp, rGroup) = reporter, app == rApp, rGroup > 0, fg != rGroup,
           [.done, .error, .idle, .clear].contains(state), argv.map(ProgramReporter.isShell) == true,
           !ClaudeProcess.groupAlive(rGroup) {
            pane.programGroup = -1  // (its last words: nothing after them counts)
            pane.lastWords = nil
            return true
        }
        ignoredProgramReports += 1
        if pane.programIgnoredLogged != fg {  // (once per job: a file full of reports is one line)
            pane.programIgnoredLogged = fg
            log("program report ignored: pane=\(pane.id.prefix(8)) \(app) \(state): not its foreground program")
        }
        return false
    }

    /// The foreground job's argv, looked up once per job. Looked at again when its leader execs
    /// (kqueue, no polling: a shell in front may be one that just forked the next job and hasn't
    /// exec'd it yet, the group is the job's already) and at a title change.
    func foregroundArgv(_ pane: Pane, _ fg: pid_t) -> [String]? {
        if let c = pane.programArgv, c.group == fg { return c.argv }
        argvLookups += 1
        guard let pid = ClaudeProcess.representative(ofGroup: fg),
              let argv = ClaudeProcess.commandLine(pid)?.argv else { return nil }
        pane.programArgvWatch?.cancel()
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: [.exec, .exit], queue: .main)
        src.setEventHandler { [weak pane, weak src] in
            src?.cancel()
            if let pane, pane.programArgv?.group == fg { pane.programArgv = nil }
        }
        src.resume()
        pane.programArgvWatch = src
        pane.programArgv = (fg, argv)
        if !ClaudeProcess.alive(pid) { src.cancel(); pane.programArgv = nil }  // (gone already: no event comes)
        return argv
    }

    /// The reporter's exit, from the kernel (no polling): its row doesn't stay running or waiting
    /// until the next title change. A moment later, so its last words (still in the pty) come first.
    private func watchReporterExit(_ pane: Pane, _ pid: pid_t) {
        pane.programExitWatch?.cancel()
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let exited: () -> Void = { [weak self, weak pane, weak src] in
            guard let src, !src.isCancelled else { return }  // (once: a dead pid can also get the event)
            src.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + (self?.reporterExitGrace ?? 0.5)) { [weak self, weak pane] in
                MainActor.assumeIsolated {
                    guard let self, let pane, self.pane(id: pane.id) === pane else { return }  // (closed meanwhile)
                    self.reporterExited(pane)
                }
            }
        }
        src.setEventHandler(handler: exited)
        src.resume()
        pane.programExitWatch = src
        if !ClaudeProcess.alive(pid) { exited() }  // (gone before the watch began: no event comes)
    }

    /// The reporter exited (a moment ago): gone as below, but its last words still count once
    /// until the next title change (a big burst of output can still be in the pty).
    func reporterExited(_ pane: Pane) {
        guard let app = pane.programApp, pane.programGroup > 0, !ClaudeProcess.groupAlive(pane.programGroup) else { return }
        let group = pane.programGroup
        programMayBeGone(pane)
        pane.lastWords = (app, group)
    }

    /// The reporter is gone without a clear: a done or failed turn stays (as Claude's does), a
    /// running or waiting one ends.
    func programMayBeGone(_ pane: Pane) {
        guard pane.programApp != nil, !ClaudeProcess.groupAlive(pane.programGroup) else { return }
        log("program gone without a clear: pane=\(pane.id.prefix(8))")
        forgetProgramReport(pane)
        if pane.agent.state != .done { pane.agent = PaneAgent() }
    }

    func forgetProgramReport(_ pane: Pane) {
        pane.programApp = nil
        pane.programReport = nil
        pane.programKind = nil
        pane.programGroup = 0
        pane.programAnswered = false
        pane.programExitWatch?.cancel()
        pane.programExitWatch = nil
        pane.foregroundCache = nil
        schedulePaneChrome(pane)  // (the header named it)
    }

    func foregroundIs(_ pane: Pane, app: String) -> Bool {
        ClaudeProcess.representative(ofGroup: pane.surface.foregroundPID).flatMap(ClaudeProcess.commandLine)
            .map { ProgramReporter.namesItself(app, argv: $0.argv) } == true
    }

    /// The pane is a shell again as far as its codex's own reports go.
    func forgetCodexReport(_ pane: Pane) {
        pane.codexReport = nil
        pane.codexTurnStartedAt = nil
        pane.codexTurnClaimed = nil
        pane.codexTurnReply = nil
        pane.codexAsk = nil
        pane.codexHeld = []
    }

    func foregroundIsCodex(_ pane: Pane) -> Bool {
        ClaudeProcess.representative(ofGroup: pane.surface.foregroundPID).flatMap(ClaudeProcess.commandLine)?
            .argv.contains(where: Self.isCodexArgument) == true
    }

    /// The pane's current turn, as a session from the shared server could be matched to it.
    func codexTurn(_ pane: Pane) -> CodexSessionBinder.Turn? {
        guard pane.codexReport != nil, let t = pane.codexTurnStartedAt else { return nil }
        return CodexSessionBinder.Turn(pane: pane.id, at: t, claimedAt: pane.codexTurnClaimed)
    }

    func waitsForCodexSession(_ pane: Pane) -> Bool {
        !codexBinder.pending.isEmpty && codexTurn(pane).map(codexBinder.waits) == true
    }

    /// Held reports go on, oldest first: the ones up to `through` (their wait is over) and any
    /// once no waiting session could be this pane's.
    func releaseHeldCodexReports(_ pane: Pane, through: Date? = nil) {
        while let s = pane.codexHeld.first, through.map({ s.at <= $0 }) == true || !waitsForCodexSession(pane) {
            pane.codexHeld.removeFirst()
            applyProgramStatus(pane, s)
        }
    }

    /// Codex 0.166 runs sessions on one shared app-server (`features.daemon_auto_start`, on by
    /// default), started by the first codex and outliving it, and runs every session's hooks
    /// with that codex's environment: their LMUX_PANE_ID names the pane that started it, whoever
    /// asked. Such events go to the pane by session instead.
    func runsOnSharedCodexServer(_ e: HookEvent) -> Bool {
        guard let pid = e.claudePID else { return false }
        if let known = sharedCodexServers[pid] { return known }
        let shared = ClaudeProcess.commandLine(pid)?.argv.dropFirst().first == "app-server"
        if sharedCodexServers.count > 64 { sharedCodexServers = [:] }
        sharedCodexServers[pid] = shared
        return shared
    }

    /// The pane already bound to the session gets it. A session no pane has yet waits, from a
    /// turn start of its own, for the pane whose codex started a turn at that moment (its OSC
    /// 7501 report): bound only one to one (`CodexSessionBinder`), never a guess.
    func routeSharedCodex(_ e: HookEvent) {
        guard let sid = e.sessionID, !sid.isEmpty else { return }
        let now = Date()
        if let p = model.workspaces.flatMap(\.panes).first(where: { $0.agentKind == .codex && $0.claudeSessionID == sid }) {
            deliverSharedCodex(e, to: p, at: now)
            return
        }
        guard codexBinder.hold(e, at: now) else {
            log("codex shared server: \(e.name) session=\(sid) has no pane (not a turn start: not bound from it)")
            return
        }
        log("codex shared server: \(e.name) session=\(sid) waits for its pane")
        bindPendingCodexSessions()
    }

    var retiredTokensFile: URL { paths.stateDir.appendingPathComponent("codex-tokens") }

    func loadRetiredPaneTokens() {
        guard let d = try? Data(contentsOf: retiredTokensFile),
              let a = try? JSONSerialization.jsonObject(with: d) as? [[String]] else { return }
        retiredPaneTokens = a.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    /// Kept (0600, the last 256) for a shared app-server started from a pane that is gone: only
    /// panes that ran codex (the server's environment is that codex's).
    func retirePaneTokens(_ tokens: [(token: String, paneID: String)]) {
        guard !tokens.isEmpty else { return }
        let new = Set(tokens.map(\.token))
        retiredPaneTokens = Array((retiredPaneTokens.filter { !new.contains($0.token) } + tokens).suffix(256))
        if let d = try? JSONSerialization.data(withJSONObject: retiredPaneTokens.map { [$0.token, $0.paneID] }) {
            try? PrivateFile.replace(retiredTokensFile, d, mode: 0o600)
        }
    }

    /// How far apart a session's turn start and its pane's may be.
    nonisolated static let codexBindWindow: TimeInterval = 1.5

    func bindPendingCodexSessions() {
        guard !codexBinder.pending.isEmpty else { return }
        // Panes whose codex is still their foreground program.
        let turns = model.workspaces.flatMap(\.panes).compactMap { p in codexTurn(p).flatMap { foregroundIsCodex(p) ? $0 : nil } }
        let r = codexBinder.resolve(turns: turns, now: Date())
        // The next wait that will be over: looked at again then.
        if let next = r.next, codexBindCheck.map({ $0 > next }) ?? true {
            codexBindCheck = next
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next.timeIntervalSinceNow)) { [weak self] in
                MainActor.assumeIsolated {
                    self?.codexBindCheck = nil
                    self?.bindPendingCodexSessions()
                }
            }
        }
        for u in r.unbound { log("codex session \(u.session) not bound: \(u.panes) panes started a turn then, or another session did") }
        for b in r.bound {
            guard let p = pane(id: b.pane) else { continue }
            log("codex session \(b.session) bound to pane=\(p.id.prefix(8))")
            for e in b.events { deliverSharedCodex(e, to: p, at: b.since) }
        }
        for p in model.workspaces.flatMap(\.panes) where !p.codexHeld.isEmpty { releaseHeldCodexReports(p) }
    }

    /// A shared app-server's event (that came at `at`), as if the pane's own codex had run the hook.
    func deliverSharedCodex(_ event: HookEvent, to pane: Pane, at: Date) {
        if [.sessionStart, .userPromptSubmit].contains(event.kind) { pane.codexTurnClaimed = at }
        var e = event
        let fg = pane.surface.foregroundPID
        if fg > 0 {
            e.claudePGID = fg
            e.claudePID = ClaudeProcess.representative(ofGroup: fg) ?? e.claudePID
        }
        e.claudeAncestorGroups = []
        handleHook(e, on: pane)
    }

    /// Codex (0.166) runs its hooks from its app-server: a child of the pane's foreground codex in
    /// a process group of its own, so lmux-hook reports that process. It stands for the codex
    /// above it (whose argv `codex resume` replays, whose exit ends the session), never for a
    /// nested agent: those run under the app-server, so their first ancestor group isn't the pane's.
    func codexRunnerAsCodex(_ pane: Pane, _ e: HookEvent) -> HookEvent {
        let fg = pane.surface.foregroundPID
        guard e.agent == .codex, fg > 0, let pgid = e.claudePGID, pgid != fg, e.claudeAncestorGroups.first == fg else { return e }
        var e = e
        e.claudePGID = fg
        e.claudePID = ClaudeProcess.representative(ofGroup: fg) ?? e.claudePID
        return e
    }

    /// true: the hook ran in a claude started underneath the pane's foreground claude (its
    /// own group, the foreground group among its ancestors'). false: the foreground claude.
    /// nil: can't tell (an older lmux-hook, no pty yet, or a claude from elsewhere).
    func isNestedClaude(_ pane: Pane, _ e: HookEvent) -> Bool? {
        guard let pgid = e.claudePGID else { return nil }
        let fg = pane.surface.foregroundPID
        guard fg > 0 else { return nil }
        if pgid == fg { return false }
        return e.claudeAncestorGroups.contains(fg) ? true : nil
    }

    /// `permission_mode` values (Claude Code 2.1; Codex sends default / bypassPermissions / dontAsk).
    static let permissionModes: Set<String> = ["default", "plan", "acceptEdits", "auto", "bypassPermissions", "dontAsk"]

    static func describe(_ r: NeedsInputReason) -> String {
        switch r {
        case .permission: return "Permission"
        case .elicitation: return "Question from an MCP server"
        case .question: return "Claude has a question"
        case .planApproval: return "Plan ready for review"
        }
    }

    static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) }
    }

    static func body(_ a: AgentAlert) -> String {
        switch a {
        case .needsInput(let r, let m): return "Needs input · " + (m ?? describe(r))
        case .done(let last): return "Done" + (last.flatMap(firstLine).map { " · " + $0 } ?? "")
        case .failed(let type): return "Failed" + (type.map { " · " + $0 } ?? "")
        }
    }

    static func kind(_ a: AgentAlert) -> String {
        switch a {
        case .needsInput: return "needsInput"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

/// The single notification path (R14). Every post is recorded (tests read
/// `posted`); system notifications only outside headless mode.
@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public struct Posted: Equatable {
        public let title: String
        public let body: String
        public let paneID: String?
        public let kind: String
    }

    /// The last `cap` posts (tests read it); `postedCount` counts every one.
    public private(set) var posted: [Posted] = []
    public private(set) var postedCount = 0
    /// System notification sound: nil = silent, "default", or a sound name (settings).
    public var sound: String?
    static let cap = 50
    public var onActivate: ((String) -> Void)?
    private let postToSystem: Bool
    private var authorized: Bool?

    init(postToSystem: Bool) {
        // UNUserNotificationCenter needs a real app bundle.
        self.postToSystem = postToSystem && Bundle.main.bundleIdentifier != nil
        super.init()
        if self.postToSystem { UNUserNotificationCenter.current().delegate = self }
    }

    func post(title: String, body: String, paneID: String?, kind: String) {
        posted.append(Posted(title: title, body: body, paneID: paneID, kind: kind))
        postedCount += 1
        if posted.count > Self.cap { posted.removeFirst(posted.count - Self.cap) }
        guard postToSystem else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let s = self.sound { content.sound = s == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(s)) }
            if let paneID { content.userInfo = ["pane": paneID] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if authorized == true { send(); return }
        center.requestAuthorization(options: [.alert, .badge]) { ok, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.authorized = ok }
                if ok { send() }
            }
        }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping () -> Void) {
        let pane = response.notification.request.content.userInfo["pane"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated { if let pane { self.onActivate?(pane) } }
            completionHandler()
        }
    }

    /// Tests (headless: a system notification is never posted, so `didReceive` above never
    /// fires): simulate the user clicking the notification for `paneID`, exactly as that
    /// delegate call would — `onActivate?(paneID)`, which reopens the window and focuses it.
    public func simulateClick(paneID: String) {
        onActivate?(paneID)
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                                   willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Posted only for panes the user isn't looking at, so show it even while lmux is frontmost.
        completionHandler([.banner, .list])
    }
}
