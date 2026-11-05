import AppKit
import LmuxHooks
import LmuxTokens
import QuartzCore
import SwiftUI

private typealias T = LmuxTokens

// Unattended reminder: a row that went done (✓) or needs input (●) while nobody looked starts
// a breathing pulse after N minutes (settings, default 3): the accent check dims and brightens
// with a soft accent halo behind it. (No tint on the row's pill: at its peak it read as a second
// selected row.) Looking at it (selected while lmux is active), typing into the pane or a new prompt
// resets it. No per-frame work in the app: one deadline timer while something is pending, and
// the pulse is Core Animation layer animations that run in the render server and are removed
// while nobody can see them.

extension LmuxController {
    var attentionNow: Date { attentionClock?() ?? Date() }

    /// The workspace is being looked at: on screen while lmux is the active app.
    func isAttending(_ ws: Workspace?) -> Bool {
        guard let ws else { return false }
        return isAppActive && ws === model.selected && windowShown
    }

    /// The pane is on screen in a workspace being looked at (not hidden behind a zoomed split).
    func isAttending(_ pane: Pane) -> Bool {
        guard let ws = pane.workspace, isAttending(ws) else { return false }
        return ws.zoomedPane == nil || ws.zoomedPane === pane
    }

    static func wantsAttention(_ p: Pane) -> Bool {
        switch p.display {
        case .done, .needsInput: return true
        default: return false
        }
    }

    /// A pane just went done / needs input.
    func noteAttentionNeeded(_ pane: Pane) {
        let before = pane.attentionSince
        if isAttending(pane) { pane.attentionSince = nil } else if pane.attentionSince == nil { pane.attentionSince = attentionNow }
        if pane.attentionSince != before { scheduleSave() }  // (layout.json keeps it across a relaunch)
        updateAttention()
    }

    /// The user attended the pane (typed, sent a prompt).
    func attended(_ pane: Pane) {
        guard pane.attentionSince != nil || pane.workspace?.unattendedSince != nil else { return }
        if pane.attentionSince != nil { pane.attentionSince = nil; scheduleSave() }
        updateAttention()
    }

    /// How long a running agent may stay quiet (no hook event, no output) before its row says so.
    nonisolated static let quietAfter: TimeInterval = 10 * 60
    /// How often the screen of a running agent that has been quiet for that long is looked at.
    nonisolated static let screenLookEvery: TimeInterval = 60
    /// After a usage limit's reset time, how long Claude has to continue (or say it won't).
    nonisolated static let usageLimitGrace: TimeInterval = 15 * 60
    /// The wait's end when Claude's reset text can't be read: its session limits last 5 hours.
    nonisolated static let usageLimitFallback: TimeInterval = 5 * 60 * 60

    /// A hook event, a new title or an accepted report came from the pane's agent: its quiet hint
    /// (if any) goes. Hot path (every spinner frame): a store, and a write only when the hint was showing.
    func noteAgentActivity(_ pane: Pane) {
        pane.lastActivityAt = attentionNow
        pane.screenHash = nil  // the next look starts from the screen as it is then
        if pane.quietMinutes != nil { pane.quietMinutes = nil }
    }

    /// Minutes the running agent in `p` has been quiet, once that is `quietAfter` or more. Not while
    /// it waits for a usage limit (quiet on purpose).
    func quietMinutes(_ p: Pane, now: Date) -> Int? {
        guard p.agent.state == .running, p.agent.usageLimitResets == nil else { return nil }
        let quiet = now.timeIntervalSince(p.lastActivityAt)
        return quiet >= Self.quietAfter ? Int(quiet / 60) : nil
    }

    /// Output that neither hooks nor titles show (a build printing in a hidden pane, a TUI that
    /// redraws): the active screen changed since the last look, once a minute at most and only while
    /// the agent has been quiet for a minute. Not drawn frames: a cursor blink, focus or scrolling
    /// draws them with no output, and a hidden pane draws none while its output goes on.
    private func lookAtScreen(_ p: Pane, now: Date) {
        guard now.timeIntervalSince(p.lastActivityAt) >= Self.screenLookEvery,
              now.timeIntervalSince(p.screenSampledAt) >= Self.screenLookEvery else { return }
        let h = p.surface.activeTextHash()
        // Changed since the last look: output came in since then (counted from now, the later end).
        // No last look since the last activity: this one is the baseline.
        if let old = p.screenHash, old != h { noteAgentActivity(p) }
        p.screenHash = h
        p.screenSampledAt = now
    }

    /// The reset time (Claude's own words) plus the grace; 5 hours from now when they can't be read.
    func usageLimitDeadline(_ p: Pane, now: Date) -> (Date, knownReset: Bool)? {
        guard let text = p.agent.usageLimitResets else { return nil }
        let read = PaneAgent.usageLimitResetDate(text, zone: p.agent.usageLimitZone, after: now)
        let reset = read ?? now.addingTimeInterval(Self.usageLimitFallback)
        return (reset.addingTimeInterval(Self.usageLimitGrace), read != nil)
    }

    /// The wait outlived its reset time and Claude said nothing: the user's turn (done, one alert).
    private func usageLimitPassed(_ p: Pane) {
        let focused = isPaneFocused(p)
        var a = p.agent
        let t = a.usageLimitPassed(focused: focused, knownReset: p.usageLimitKnownReset)
        p.usageLimitDeadline = nil
        guard a != p.agent else { return }
        p.agent = a
        log("usage limit wait ended (reset time passed): pane=\(p.id.prefix(8))")
        apply(t, to: p, focused: focused)
    }

    /// Re-derive every row's unattended state, quiet hints and usage-limit waits, and arm the one
    /// timer for the next deadline.
    public func updateAttention() {
        let now = attentionNow
        // Waits past their deadline end first (their alert re-enters here, with nothing left to end).
        let expired = model.workspaces.flatMap(\.panes).filter { p in
            p.agent.usageLimitResets != nil && (p.usageLimitDeadline.map { $0 <= now } ?? false)
        }
        if !expired.isEmpty {
            for p in expired { usageLimitPassed(p) }
            return updateAttention()
        }
        let minutes = settings.remindAfterMinutes
        var next: Date?   // reminders (coarse: at most 30 s away, below)
        var exact: Date?  // quiet looks, hint minutes, wait deadlines
        func at(_ d: Date) { exact = min(exact ?? d, d) }
        for ws in model.workspaces {
            for p in ws.panes {
                // A usage-limit wait: its deadline, set when it is first seen (right after the hook).
                if p.agent.usageLimitResets == nil {
                    if p.usageLimitDeadline != nil { p.usageLimitDeadline = nil }
                } else {
                    if p.usageLimitDeadline == nil, let (d, known) = usageLimitDeadline(p, now: now) {
                        p.usageLimitDeadline = d
                        p.usageLimitKnownReset = known
                    }
                    if let d = p.usageLimitDeadline { at(d) }
                }
                // Quiet running agents: a look at the screen, the hint, and when either is due next.
                if p.agent.state == .running, p.agent.usageLimitResets == nil { lookAtScreen(p, now: now) }
                let q = quietMinutes(p, now: now)
                if p.quietMinutes != q { p.quietMinutes = q }
                guard p.agent.state == .running, p.agent.usageLimitResets == nil else { continue }
                at(max(p.lastActivityAt, p.screenSampledAt).addingTimeInterval(Self.screenLookEvery))
                at(p.lastActivityAt.addingTimeInterval(q.map { TimeInterval(($0 + 1) * 60) } ?? Self.quietAfter))
            }
            let looking = isAttending(ws)
            for p in ws.panes where p.attentionSince != nil
                && ((looking && (ws.zoomedPane == nil || ws.zoomedPane === p)) || !Self.wantsAttention(p)) {
                p.attentionSince = nil
                scheduleSave()
            }
            let since = ws.panes.compactMap(\.attentionSince).min()
            var due: Date?
            if minutes > 0, let s = since {
                let d = s.addingTimeInterval(TimeInterval(minutes * 60))
                if d <= now { due = s } else { next = min(next ?? d, d) }
            }
            if ws.unattendedSince != due {
                let started = ws.unattendedSince == nil
                ws.unattendedSince = due
                // None for rows the launch restores already overdue: no burst of reminders at every relaunch.
                if due != nil, started, persistenceEnabled, settings.remindNotification {
                    let p = ws.panes.first { $0.attentionSince != nil }
                    notifier.post(title: ws.title, body: "Still waiting for you" + (p?.alertDetail.map { ": " + $0 } ?? ""),
                                  paneID: p?.id, kind: "reminder")
                }
            }
        }
        // Reminders: at most every 30s while one is pending; the others exactly. Wall-clock deadlines
        // (a sleep in between still ends a wait on time). A fake clock in tests is re-checked directly.
        var delay = next.map { min(max($0.timeIntervalSince(now), 1), 30) }
        if let e = exact { let d = max(e.timeIntervalSince(now), 1); delay = min(delay ?? d, d) }
        attentionDelay = delay
        guard let delay else {
            attentionWork?.cancel()
            attentionWork = nil
            return
        }
        if attentionWork == nil {
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.updateAttention() } }
            t.resume()
            attentionWork = t
        }
        attentionWork?.schedule(wallDeadline: .now() + delay, leeway: .seconds(1))
    }

    /// Animations only while someone can see the sidebar and motion isn't reduced.
    func updatePulseMotion() {
        let reduce = reduceMotionOverride ?? T.Motion.reduceMotion
        if model.reduceMotion != reduce { model.reduceMotion = reduce }
        let on = windowShown && model.sidebarVisible && !reduce && !NSApp.isHidden
        if model.pulseMotion != on { model.pulseMotion = on }
    }

    /// "waiting 7 minutes" for VoiceOver.
    func waitingLabel(_ ws: Workspace) -> String? {
        guard let s = ws.panes.compactMap(\.attentionSince).min(), ws.unattendedSince != nil else { return nil }
        let m = max(1, Int(attentionNow.timeIntervalSince(s) / 60))
        return "waiting \(m) minute\(m == 1 ? "" : "s")"
    }
}

/// Breathes its content with Core Animation layer animations: the render server runs them, the
/// app does nothing per frame. One breath (`T.Motion.attentionBreath`, ease-in-out) takes the glyph
/// from full to 0.25 opacity and back, while a soft accent halo behind it (20pt) swells and fades
/// with it. `animating` false removes both (window hidden, Reduce Motion).
struct Pulse<Content: View>: NSViewRepresentable {
    let animating: Bool
    @ViewBuilder let content: Content

    final class Box: NSView {
        let host: NSHostingView<Content>
        let halo = CALayer()
        init(_ c: Content) {
            host = NSHostingView(rootView: c)
            super.init(frame: .zero)
            wantsLayer = true
            host.wantsLayer = true
            addSubview(host)
            halo.opacity = 0
            layer?.masksToBounds = false
            layer?.insertSublayer(halo, at: 0)
            colorHalo()
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() {
            super.layout()
            host.frame = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            halo.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
            halo.cornerRadius = 10
            halo.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var intrinsicContentSize: NSSize { host.fittingSize }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); colorHalo() }

        private func colorHalo() {
            effectiveAppearance.performAsCurrentDrawingAppearance { halo.backgroundColor = T.Colors.attentionHalo.nsColor.cgColor }
        }

        var isPulsing: Bool { host.layer?.animation(forKey: "pulse") != nil }

        func setPulsing(_ on: Bool) {
            guard let glyph = host.layer, on != isPulsing else { return }
            if on {
                glyph.add(breath(step("opacity", from: 1.0, to: 0.25)), forKey: "pulse")
                let swell = CAAnimationGroup()
                swell.animations = [step("opacity", from: 1.0, to: 0.0), step("transform.scale", from: 1.0, to: 0.55)]
                halo.add(breath(swell), forKey: "halo")
            } else {
                glyph.removeAnimation(forKey: "pulse")
                halo.removeAnimation(forKey: "halo")
            }
        }
    }

    func makeNSView(context: Context) -> Box {
        let b = Box(content)
        b.setAccessibilityElement(false)
        return b
    }

    func updateNSView(_ b: Box, context: Context) {
        b.host.rootView = content
        b.setPulsing(animating)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Box, context: Context) -> CGSize? { nsView.host.fittingSize }
}

/// Half a breath (bright -> dim) of one property.
private func step(_ keyPath: String, from: Double, to: Double) -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: keyPath)
    a.fromValue = from
    a.toValue = to
    a.duration = T.Motion.attentionBreath / 2
    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    return a
}

/// Back and forth forever, every breathing layer on the same beat (aligned to the media clock).
private func breath<A: CAAnimation>(_ a: A) -> A {
    a.duration = T.Motion.attentionBreath / 2
    a.autoreverses = true
    a.repeatCount = .infinity
    a.isRemovedOnCompletion = false
    let now = CACurrentMediaTime()
    a.beginTime = now - now.truncatingRemainder(dividingBy: T.Motion.attentionBreath)
    a.fillMode = .both
    return a
}
