import AppKit
import Foundation

extension LmuxController {
    public var askStore: AskSessionStore { model.askStore }

    private static let askWaitUnauthorizedError = "unknown or unauthorized ask session"

    /// Synchronously validates tenant permissions and creates a pending `AskSession`.
    public func handleAskCreate(_ req: [String: Any]) -> [String: Any] {
        let token = req["token"] as? String
        let peerPID = req["_peerpid"] as? Int
        let namedPane = req["pane"] as? String

        if let token, !token.isEmpty, pane(token: token) == nil {
            return ["ok": false, "error": "invalid pane token"]
        }

        let tokenPane = pane(token: token)
        let pidPane = (tokenPane == nil) ? callerPane(token: nil, peerPID: peerPID) : nil

        let targetPane: Pane?
        let createdInsidePane: Bool

        if let tokenPane {
            createdInsidePane = true
            if let namedPane, !namedPane.isEmpty {
                guard let named = pane(id: namedPane) else {
                    return ["ok": false, "error": "no such pane: \(namedPane)"]
                }
                if named !== tokenPane && !allowCrossPaneSend {
                    return [
                        "ok": false,
                        "error": "asking another pane from inside lmux is off (defaults write dev.lmux.app allowCrossPaneSend -bool true)"
                    ]
                }
                targetPane = named
            } else {
                targetPane = tokenPane
            }
        } else {
            // Unauthenticated caller (no valid LMUX_PANE_NONCE token).
            if let pidPane, let namedPane, !namedPane.isEmpty, namedPane != pidPane.id {
                return ["ok": false, "error": "cannot target another pane without a pane token"]
            }
            guard allowExternalSend else {
                return ["ok": false, "error": Self.externalSendOff]
            }
            if let namedPane, !namedPane.isEmpty {
                guard let named = pane(id: namedPane) else {
                    return ["ok": false, "error": "no such pane: \(namedPane)"]
                }
                targetPane = named
            } else if let pidPane {
                targetPane = pidPane
            } else {
                targetPane = model.selected?.focusedPane
            }
            createdInsidePane = pidPane != nil
        }

        guard let target = targetPane else {
            return ["ok": false, "error": "no target pane available"]
        }
        guard target.surface != nil else {
            return ["ok": false, "error": "not a terminal: \(target.id)"]
        }

        guard let specObj = req["spec"] as? [String: Any] else {
            return ["ok": false, "error": "ask-create requires spec object"]
        }
        let lenient = req["lenient"] as? Bool ?? false
        let spec: AskSpec
        do {
            spec = try AskSpec.parse(jsonObject: specObj, lenient: lenient)
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

        let sessionID = Self.randomToken()
        let session: AskSession
        do {
            session = try askStore.create(
                spec: spec,
                paneID: target.id,
                createdInsidePane: createdInsidePane,
                sessionID: sessionID
            )
        } catch {
            return ["ok": false, "error": "\(error)"]
        }

        populateSessionDetails(session, for: target)
        syncAskStates()
        recordAskNotification(for: session, target: target)

        return [
            "ok": true,
            "sessionId": session.id,
            "pane": target.id,
            "queued": askStore.pendingCount(for: target.id)
        ]
    }

    func syncAskStates() {
        for pane in model.workspaces.flatMap(\.panes) {
            if let active = askStore.activeSession(for: pane.id) {
                let title = active.spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
                pane.pendingAskTitle = title.isEmpty ? nil : title
                if !pane.hasPendingAsk { pane.hasPendingAsk = true }
            } else {
                pane.pendingAskTitle = nil
                if pane.hasPendingAsk { pane.hasPendingAsk = false }
            }
        }
        refreshPaneChrome()
        scheduleWaitCheck()
        syncInspectorForFocusedPane()
    }

    /// Synchronizes dynamic `.ask` tab visibility, auto-open/collapse restore, and inspector draft focus.
    public func syncInspectorForFocusedPane() {
        let focusedPane = model.selected?.focusedPane
        let hasAsk = focusedPane.flatMap { askStore.activeSession(for: $0.id) } != nil

        if model.inspectorTab != .ask {
            model.lastNonAskInspectorTab = model.inspectorTab
        }

        if hasAsk {
            if !model.inspectorVisible {
                model.inspectorVisible = true
                model.inspectorAutoOpenedByAsk = true
            }
            if model.inspectorTab != .ask {
                let wasPreview = model.inspectorTab == .preview
                model.inspectorTab = .ask
                if wasPreview { focusCurrent() }
            }
        } else {
            if model.inspectorTab == .ask {
                model.inspectorTab = model.lastNonAskInspectorTab
                clearInspectorTextFocusIfNeeded()
            }
            if model.inspectorAutoOpenedByAsk {
                model.inspectorVisible = false
                model.inspectorAutoOpenedByAsk = false
                clearInspectorTextFocusIfNeeded()
            }
        }
        root?.needsLayout = true
    }

    func clearInspectorTextFocusIfNeeded() {
        guard let window,
              let host = root?.rightInspectorHost,
              let fr = window.firstResponder as? NSView,
              fr is NSText,
              fr.isDescendant(of: host) else {
            return
        }
        focusCurrent()
    }

    private func recordAskNotification(for session: AskSession, target: Pane) {
        let focused = isPaneFocused(target)
        let titleText = session.spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryTitle = titleText.isEmpty ? "待確認問題" : titleText
        target.lastAlertAt = Date()
        if !focused {
            target.unread += 1
            noteAttentionNeeded(target)
            notifier.post(
                title: target.workspace?.title ?? "lmux",
                body: summaryTitle,
                paneID: target.id,
                kind: "needsInput"
            )
        }
        model.recordNotification(NotificationEntry(
            paneID: target.id,
            workspaceID: target.workspace?.id,
            title: target.workspace?.title ?? "lmux",
            message: summaryTitle,
            kind: "needsInput",
            read: focused
        ))
        refreshPaneChrome()
    }

    /// Attaches a long-lived `ask-wait` responder after strict tenant authorization checks.
    public func startAskWait(
        _ req: [String: Any],
        reply: @escaping ([String: Any]) -> Void
    ) -> () -> Void {
        guard let sessionID = req["sessionId"] as? String, !sessionID.isEmpty else {
            reply(["ok": false, "error": Self.askWaitUnauthorizedError])
            return {}
        }

        let token = req["token"] as? String
        if let token, !token.isEmpty, pane(token: token) == nil {
            reply(["ok": false, "error": Self.askWaitUnauthorizedError])
            return {}
        }

        let meta: (paneID: String, createdInsidePane: Bool)?
        if let active = askStore.session(id: sessionID) {
            meta = (active.paneID, active.createdInsidePane)
        } else {
            meta = askStore.cachedOutcomeMeta(sessionID: sessionID)
        }
        guard let meta else {
            reply(["ok": false, "error": Self.askWaitUnauthorizedError])
            return {}
        }

        let callerTokenPane = pane(token: token)
        if meta.createdInsidePane {
            // External callers can NEVER wait for a pane-originated session, even with allowExternalSend or allowCrossPaneSend.
            guard let callerTokenPane else {
                reply(["ok": false, "error": Self.askWaitUnauthorizedError])
                return {}
            }
            if callerTokenPane.id != meta.paneID && !allowCrossPaneSend {
                reply(["ok": false, "error": Self.askWaitUnauthorizedError])
                return {}
            }
        } else {
            if let callerTokenPane {
                if callerTokenPane.id != meta.paneID && !allowCrossPaneSend && !allowExternalSend {
                    reply(["ok": false, "error": Self.askWaitUnauthorizedError])
                    return {}
                }
            } else {
                guard allowExternalSend else {
                    reply(["ok": false, "error": Self.askWaitUnauthorizedError])
                    return {}
                }
            }
        }

        let cancel = askStore.attachWaiter(sessionID: sessionID) { outcome in
            reply(Self.formatAskWaitOutcome(outcome, sessionID: sessionID))
        }
        return cancel ?? {}
    }

    private func populateSessionDetails(_ session: AskSession, for target: Pane) {
        let cwd = target.cwd
        let hasRefs = session.spec.questions.contains { !$0.refs.isEmpty || !$0.gitDiff.isEmpty }
        session.isLoadingContext = true

        Task { @MainActor [weak self, weak session, weak target] in
            guard let self, let session, let target else { return }
            let ctx = await AskContextBuilder.build(
                for: target,
                transcripts: self.transcripts,
                activeGitSnapshot: nil
            )
            session.context = ctx

            if hasRefs {
                var repoRoot: String?
                if let cwd, !cwd.isEmpty {
                    let top = await GitDiffService.runGitHardened(["rev-parse", "--show-toplevel"], cwd: cwd)
                    let trimmed = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if top.status == 0, !trimmed.isEmpty { repoRoot = trimmed }
                }

                for q in session.spec.questions {
                    if !q.refs.isEmpty {
                        let rootPath = repoRoot
                        let loadedRefs = await Task.detached(priority: .utility) {
                            q.refs.map { AskRefLoader.loadFileRef($0, baseDir: cwd, repoRoot: rootPath) }
                        }.value
                        session.loadedFileRefs[q.id] = loadedRefs
                    }
                    if !q.gitDiff.isEmpty {
                        var diffs: [AskGitDiffRefResult] = []
                        for rel in q.gitDiff {
                            diffs.append(await AskRefLoader.loadGitDiff(rel, cwd: cwd))
                        }
                        session.loadedGitDiffs[q.id] = diffs
                    }
                }
            }

            session.isLoadingContext = false
        }
    }

    private static func formatAskWaitOutcome(_ outcome: AskWaitOutcome, sessionID: String) -> [String: Any] {
        switch outcome.status {
        case "submitted":
            return [
                "ok": true,
                "status": "submitted",
                "sessionId": sessionID,
                "answers": outcome.answers.map { $0.toJSONObject() }
            ]
        case "cancelled":
            return [
                "ok": true,
                "status": "cancelled",
                "sessionId": sessionID,
                "note": outcome.note ?? "User cancelled ask session"
            ]
        case "lost":
            return [
                "ok": true,
                "status": "lost",
                "sessionId": sessionID,
                "note": outcome.note ?? "Session lost"
            ]
        case "superseded":
            return [
                "ok": false,
                "status": "superseded",
                "error": outcome.note ?? "Waiter superseded"
            ]
        default:
            return ["ok": false, "error": askWaitUnauthorizedError]
        }
    }
}
