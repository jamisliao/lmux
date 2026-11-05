import Foundation
import LmuxHooks

/// One `lmux wait` in progress: its connection stays open until the target reaches the state (or
/// is gone, or the CLI hangs up on its timeout). Nothing runs for it in between: a pane's state
/// change schedules one look at every wait (`Pane.agentStateChanged`), and so does a pane closing.
struct PaneWait {
    let target: String
    let until: WaitUntil
    /// The target's state when the wait began (`--until any`).
    let initial: String
    /// `--until any`: the target's state differed from `initial` at some change, even one undone
    /// before the coalesced look (needs input -> running -> needs input in one runloop turn).
    var changed = false
    let reply: ([String: Any]) -> Void
}

extension LmuxController {
    /// `{"cmd":"wait","target":"<pane or workspace id>","until":"done"}`: answered now if the
    /// target is already there (or doesn't exist), else once it is. Returns a cancel for when the
    /// CLI leaves first.
    func startWait(_ req: [String: Any], reply: @escaping ([String: Any]) -> Void) -> () -> Void {
        guard let target = req["target"] as? String, !target.isEmpty else {
            reply(["ok": false, "error": "wait needs a pane or workspace id"])
            return {}
        }
        guard let until = WaitUntil(rawValue: req["until"] as? String ?? "settled") else {
            reply(["ok": false, "error": "--until is idle, done, needs-you or any"])
            return {}
        }
        guard let now = waitState(target) else {
            reply(["ok": true, "gone": true])
            return {}
        }
        if until.reached(now.state, fresh: now.fresh, changed: false) {
            reply(waitAnswer(target))
            return {}
        }
        let id = nextWaitID
        nextWaitID += 1
        waits[id] = PaneWait(target: target, until: until, initial: now.state, reply: reply)
        model.onAgentStateChange = { [weak self] p in self?.agentStateChanged(p) }
        return { [weak self] in self?.endWait(id) }
    }

    private func endWait(_ id: Int) {
        waits[id] = nil
        if waits.isEmpty { model.onAgentStateChange = nil }
    }

    /// Every state change, as it happens: an `any` wait on this pane (or its workspace) notes a
    /// change now, the rest is looked at once per runloop turn.
    func agentStateChanged(_ p: Pane) {
        for (id, w) in waits where w.until == .any && !w.changed && (w.target == p.id || w.target == p.workspace?.id) {
            if waitState(w.target)?.state != w.initial { waits[id]?.changed = true }
        }
        scheduleWaitCheck()
    }

    /// Once per runloop turn: a hook event sets a pane's state, then its failed flag and detail.
    func scheduleWaitCheck() {
        guard !waits.isEmpty, !waitsScheduled else { return }
        waitsScheduled = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.checkWaits() } }
    }

    func checkWaits() {
        waitsScheduled = false
        for (id, w) in waits {
            guard let now = waitState(w.target) else {
                endWait(id)
                w.reply(["ok": true, "gone": true])
                continue
            }
            guard w.until.reached(now.state, fresh: now.fresh, changed: w.changed || now.state != w.initial) else { continue }
            endWait(id)
            w.reply(waitAnswer(w.target))
        }
    }

    /// The target's state as `lmux list` names it, and whether it came after the last input lmux
    /// typed there. A workspace: the state its sidebar row shows. nil: no such pane or workspace.
    func waitState(_ target: String) -> (state: String, fresh: Bool)? {
        let panes: [Pane]
        let state: String
        if let p = pane(id: target) {
            panes = [p]
            state = p.display.stateName
        } else if let ws = model.workspaces.first(where: { $0.id == target }) {
            panes = ws.panes
            state = ws.display.stateName
        } else {
            return nil
        }
        let sent = panes.compactMap(\.lastSentAt).max() ?? .distantPast
        return (state, panes.contains { $0.stateChangedAt >= sent })
    }

    /// What `lmux wait` prints: the state, and which pane it is about (a workspace: the pane its row
    /// shows), with that pane's agent, session and last reply when known.
    func waitAnswer(_ target: String) -> [String: Any] {
        let ws = pane(id: target)?.workspace ?? model.workspaces.first { $0.id == target }
        let shown = ws?.display
        let p = pane(id: target)
            ?? ws?.panes.filter { $0.display == shown }.max { ($0.lastAlertAt ?? .distantPast) < ($1.lastAlertAt ?? .distantPast) }
        var out: [String: Any] = ["ok": true, "state": waitState(target)?.state ?? "idle", "workspace": ws?.id ?? "", "pane": p?.id ?? ""]
        if let p {
            out["agent"] = p.agentName ?? ""
            out["session"] = p.claudeSessionID ?? ""
            out["reply"] = reply(p) ?? ""
            out["detail"] = p.display.detail ?? ""
        }
        return out
    }

    /// The reply of the pane's current turn, never the one before: a codex reporting its own
    /// state has it per turn (its done can come before the Stop hook with the text); otherwise
    /// the last Stop's, if it came after the last prompt.
    func reply(_ p: Pane) -> String? {
        if p.codexReport != nil { return p.codexTurnReply }
        guard let at = p.lastReplyAt, at >= (p.promptAt ?? 0) else { return nil }
        return p.lastReply
    }
}
