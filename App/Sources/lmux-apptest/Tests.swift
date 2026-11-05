import AppKit
import Darwin
import GhosttyKit
import LmuxHooks
import LmuxTerminal
import LmuxTokens
@testable import LmuxUI

let env = ProcessInfo.processInfo.environment
let sinks = Sinks(dir: URL(fileURLWithPath: env["LMUX_SINK_DIR"] ?? "/tmp"))
let paths = LmuxPaths()

@MainActor
func makeController() -> LmuxController {
    guard let runtime = GhosttyRuntime(fontProfile: .korean) else { print("runtime init failed"); _exit(2) }
    // Copy / paste never touch the user's clipboard.
    GhosttyRuntime.standardPasteboard = NSPasteboard(name: NSPasteboard.Name("dev.lmux.apptest.\(getpid())"))
    let c = LmuxController(runtime: runtime, paths: paths, headless: true)
    c.buildMainMenu()
    // History indexes through the helper process, as the app does.
    c.history.helper = Bundle.main.executableURL
    c.start(windowFrame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    liveController = c
    return c
}

/// The controller `sendHook` takes pane tokens from (lmux-hook sends the pane's LMUX_PANE_NONCE).
@MainActor var liveController: LmuxController?

/// Send one hook payload through the real socket, as lmux-hook does (`from`: the claude
/// process that ran the hook and its process group, as lmux-hook reports them).
@MainActor
func sendHook(pane: String, _ payload: String, from: HookClient.Origin? = nil, token: String? = nil) -> Bool {
    let tok = token ?? liveController?.pane(id: pane).flatMap { liveController?.token(for: $0) }
    guard let line = HookClient.envelope(pane: pane, payload: Array(payload.utf8),
                                         sentNanos: UInt64(Date().timeIntervalSince1970 * 1e9), process: from,
                                         token: tok) else { return false }
    return HookClient.send(line, socketPath: paths.hookSocket)
}

func hook(_ name: String, session: String = "sess-1", _ extra: String = "") -> String {
    #"{"hook_event_name":"\#(name)","session_id":"\#(session)","cwd":"/tmp"\#(extra.isEmpty ? "" : "," + extra)}"#
}

/// Point inside the n-th sidebar row, in sidebar hosting view coordinates.
@MainActor
func rowPoint(_ c: LmuxController, _ i: Int) -> NSPoint {
    let host = c.root.sidebarHost
    // Rows are one line (30pt) unless they have a line 2 (46pt).
    func h(_ ws: Workspace) -> CGFloat {
        ws.showsStateLine ? LmuxTokens.Layout.workspaceRowHeightDouble : LmuxTokens.Layout.workspaceRowHeightSingle
    }
    let ws = c.model.workspaces
    let above = ws.prefix(i).reduce(CGFloat(0)) { $0 + h($1) + LmuxTokens.Layout.rowGap }
    let y = LmuxTokens.Spacing.s + above + (i < ws.count ? h(ws[i]) : LmuxTokens.Layout.workspaceRowHeightSingle) / 2
    return NSPoint(x: 100, y: host.isFlipped ? y : host.bounds.height - y)
}

@MainActor
func firstResponderPane(_ c: LmuxController) -> Pane? {
    guard let s = c.window.firstResponder as? SurfaceView else { return nil }
    return c.model.workspaces.flatMap(\.panes).first { $0.surface === s }
}

// MARK: - Main run

@MainActor
func runMain() async -> Int32 {
    let r = Report()
    let c = makeController()
    let w = c.window!

    // ---------------------------------------------------------------- startup
    r.section = "startup"
    r.check("one workspace with one pane", c.model.workspaces.count == 1 && c.model.selected?.panes.count == 1)
    let ws1 = c.model.workspaces[0]
    let p1 = ws1.panes[0]
    r.check("pane process sees LMUX_PANE_ID (its sink is named by it)", await sinks.waitReady(p1.id))
    r.check("first responder is the pane", firstResponderPane(c) === p1)
    r.check("window never became key / app never activated", !w.isKeyWindow && !NSApp.isActive)
    await type("abc", window: w)
    r.check("typing reaches the pane's pty", await sinks.wait(p1.id, contains: "abc"), sinks.text(p1.id))

    // ------------------------------------------------------------ workspaces
    r.section = "workspaces"
    await cmd("n", window: w)  // Ghostty new_window binding -> new workspace
    r.check("⌘N creates and selects a workspace", c.model.workspaces.count == 2 && c.model.selected !== ws1)
    let ws2 = c.model.selected!
    let p2 = ws2.panes[0]
    r.check("new workspace pane is ready", await sinks.waitReady(p2.id))
    r.check("focus moved to the new pane", firstResponderPane(c) === p2)
    r.check("accent colors differ", ws1.accent != ws2.accent, "\(ws1.accent) vs \(ws2.accent)")
    r.check("hidden workspace's pane is out of the window", p1.surface.window == nil)
    await type("xyz", window: w)
    r.check("keys go to the new pane only",
            await sinks.wait(p2.id, contains: "xyz") && !sinks.text(p1.id).contains("xyz"))
    await cmd("1", window: w)
    r.check("⌘1 selects workspace 1", c.model.selected === ws1 && firstResponderPane(c) === p1)
    await type("q", window: w)
    r.check("after switching, keys go to workspace 1", await sinks.wait(p1.id, contains: "abcq"), sinks.text(p1.id))
    await cmd("2", window: w)
    r.check("⌘2 selects workspace 2", c.model.selected === ws2 && firstResponderPane(c) === p2)

    // ---------------------------------------------------------------- splits
    r.section = "splits"
    await cmd("d", window: w)
    r.check("⌘D splits right", ws2.panes.count == 2, "\(ws2.panes.count)")
    if case .split(let ax, _, _) = ws2.root.content { r.check("split axis is horizontal", ax == .horizontal) }
    let p3 = ws2.focusedPane!
    r.check("focus moves to the new pane", p3 !== p2 && firstResponderPane(c) === p3)
    // Every pane has its tab bar (cmux's), in the header's place; its tab carries the pane's title.
    r.check("split panes: each its own tab bar, no header",
            [p2, p3].allSatisfy { $0.view.tabStrip != nil && $0.view.header.isHidden } && p2.view.tabStrip !== p3.view.tabStrip)
    c.renamePane(p2, to: "left")
    c.renamePane(p3, to: "right")
    r.check("…a renamed pane's tab shows its name", p2.view.tabStrip?.items.first?.title == "left"
            && p3.view.tabStrip?.items.first?.title == "right")
    r.check("pane rename locks its title", p2.titleState.isManual && p2.headerTitle == "left")
    r.check("new pane sits right of the old one",
            p3.view.convert(p3.view.bounds, to: nil).minX > p2.view.convert(p2.view.bounds, to: nil).minX)
    _ = await sinks.waitReady(p3.id)
    await cmd("d", shift: true, window: w)
    r.check("⇧⌘D splits down", ws2.panes.count == 3)
    let p4 = ws2.focusedPane!
    _ = await sinks.waitReady(p4.id)
    c.renamePane(p4, to: "below")
    r.check("down split stacks vertically",
            p4.view.convert(p4.view.bounds, to: nil).maxY <= p3.view.convert(p3.view.bounds, to: nil).minY + 1,
            "p2=\(p2.view.convert(p2.view.bounds, to: nil)) p3=\(p3.view.convert(p3.view.bounds, to: nil)) p4=\(p4.view.convert(p4.view.bounds, to: nil))")

    // ----------------------------------------------------------- focus (R6)
    r.section = "focus"
    await click(p2.surface, at: NSPoint(x: p2.surface.bounds.midX, y: p2.surface.bounds.midY))
    r.check("click on a pane focuses it", firstResponderPane(c) === p2 && ws2.focusedPane === p2,
            "fr=\(firstResponderPane(c)?.id.prefix(4) ?? "nil") focused=\(ws2.focusedPane?.id.prefix(4) ?? "nil") p2=\(p2.id.prefix(4)) p3=\(p3.id.prefix(4)) p4=\(p4.id.prefix(4))")
    await type("k", window: w)
    r.check("…and its pty receives the keys", await sinks.wait(p2.id, contains: "xyzk") &&
            !sinks.text(p3.id).contains("k") && !sinks.text(p4.id).contains("k"),
            "p2=\(sinks.text(p2.id)) p3=\(sinks.text(p3.id)) p4=\(sinks.text(p4.id))")
    let hdr = p4.view.tabStrip!
    await click(hdr, at: NSPoint(x: hdr.tabRect(0).midX, y: hdr.bounds.midY))
    r.check("click on a pane's tab bar focuses that pane", firstResponderPane(c) === p4,
            "fr=\(firstResponderPane(c)?.id.prefix(4) ?? "nil")")
    await type("j", window: w)
    r.check("…and keys go there", await sinks.wait(p4.id, contains: "j"))
    await cmd("[", window: w)
    r.check("⌘[ goes to the previous pane", firstResponderPane(c) === p3)
    c.moveFocus(.left)
    r.check("goto_split left from the right column", firstResponderPane(c) === p2)
    c.moveFocus(.right)
    r.check("goto_split right goes to the right column", firstResponderPane(c) === p3 || firstResponderPane(c) === p4)
    c.moveFocus(.down)
    r.check("goto_split down", firstResponderPane(c) === p4)

    // Sidebar clicks
    await click(c.root.sidebarHost, at: rowPoint(c, 0))
    r.check("click on sidebar row selects that workspace", c.model.selected === ws1)
    r.check("…and the keyboard is in its visible pane, not the sidebar", firstResponderPane(c) === p1,
            "\(String(describing: c.window.firstResponder))")
    r.check("…hidden panes are out of the window", ws2.panes.allSatisfy { $0.surface.window == nil })
    await type("m", window: w)
    r.check("…typing reaches workspace 1", await sinks.wait(p1.id, contains: "qm"), sinks.text(p1.id))
    await click(c.root.sidebarHost, at: NSPoint(x: 100, y: c.root.sidebarHost.isFlipped ? 400 : c.root.sidebarHost.bounds.height - 400))
    r.check("click on empty sidebar keeps focus in the visible pane", firstResponderPane(c) === p1)
    await click(c.root.sidebarHost, at: rowPoint(c, 1))
    r.check("click on row 2 returns to the split workspace's focused pane",
            c.model.selected === ws2 && firstResponderPane(c) === p4)

    // Resize
    r.section = "resize"
    guard case .split(_, let left, _) = ws2.root.content, let sv = c.splitView(for: ws2.root) else {
        r.check("root split view exists", false); return finish(r, c)
    }
    _ = left
    let before = ws2.root.ratio
    let divX = sv.divider.frame.midX
    await click(sv, at: NSPoint(x: divX, y: 200), dragTo: NSPoint(x: divX - 150, y: 200))
    r.check("dragging the divider resizes the split", ws2.root.ratio < before - 0.1, "\(before) -> \(ws2.root.ratio)")
    let r2 = ws2.root.ratio
    c.resizeSplit(p2, GHOSTTY_RESIZE_SPLIT_RIGHT, amount: 40)
    r.check("resize_split right moves the divider", ws2.root.ratio > r2, "\(r2) -> \(ws2.root.ratio)")
    c.equalize(ws2)
    r.check("equalize_splits weights by pane count (1 | 2 → 1/3)", abs(ws2.root.ratio - 1.0 / 3) < 0.01, "\(ws2.root.ratio)")
    c.toggleSidebar()
    await sleepMs(100)
    r.check("sidebar toggle hides it and keeps focus", c.root.sidebarHost.isHidden && firstResponderPane(c) === p4)
    r.check("content never under the traffic lights when hidden",
            c.root.header.frame.minX >= LmuxTokens.Layout.trafficLightsInset)
    c.toggleSidebar()
    await sleepMs(100)

    // Close pane
    r.section = "close"
    await cmd("w", window: w)  // Ghostty close_surface -> close pane
    // The sink pane runs `cat`, not an idle shell: ⌘W asks first (like Ghostty).
    r.check("⌘W on a pane running a process asks first", await waitFor { c.cardShown(p4) } && ws2.panes.count == 3,
            c.runningProcess(p4) ?? "nil")
    r.check("…naming the process", (p4.view.overlay.card?.message.stringValue ?? "").contains("cat"),
            p4.view.overlay.card?.message.stringValue ?? "")
    await type("x", window: w)
    let typedThrough = await sinks.wait(p4.id, contains: "jx")
    r.check("any other key cancels and is typed", !c.cardShown(p4) && ws2.panes.count == 3 && typedThrough, sinks.text(p4.id))
    await cmd("w", window: w)
    _ = await waitFor { c.cardShown(p4) }
    c.scheduleTitleRefresh(p4, delay: 30)
    c.scheduleOverlayRefresh(p4, delay: 30)
    let p4Work = [c.titleWork[p4.id], c.overlayWork[p4.id]]
    await type("\r", window: w)
    _ = await waitFor { ws2.panes.count == 2 }
    r.check("Enter confirms: ⌘W closes the focused pane", ws2.panes.count == 2 && !ws2.panes.contains { $0 === p4 })
    r.check("focus lands on a remaining visible pane",
            firstResponderPane(c).map { p in ws2.panes.contains { $0 === p } } ?? false)
    r.check("…and the closed pane's pending title / overlay work is cancelled",
            p4Work.allSatisfy { $0?.isCancelled == true } && c.titleWork[p4.id] == nil && c.overlayWork[p4.id] == nil)

    // Window occlusion (minimized, closed with the red button, covered): no pane renders.
    r.section = "occlusion"
    let shownPanes = c.model.selected?.panes ?? []
    r.check("visible window: the selected workspace's panes render", !shownPanes.isEmpty && shownPanes.allSatisfy { $0.surface.occlusionVisible })
    c.windowShownOverride = false
    c.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: w))
    r.check("window occluded / minimized / closed: no pane renders", c.model.workspaces.flatMap(\.panes).allSatisfy { !$0.surface.occlusionVisible })
    c.selectRelative(1); c.selectRelative(-1)
    r.check("…and switching workspaces meanwhile keeps them hidden",
            c.model.workspaces.flatMap(\.panes).allSatisfy { !$0.surface.occlusionVisible })
    c.windowShownOverride = nil
    c.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: w))
    r.check("shown again: the selected workspace renders, the others stay hidden",
            c.model.workspaces.allSatisfy { ws in ws.panes.allSatisfy { $0.surface.occlusionVisible == (ws === c.model.selected) } })
    // A hidden pane lets go of its last frame (the layer's IOSurface); shown again, it draws a new one.
    let framed = c.model.selected!.panes[0]
    let drew = await waitFor(3) { framed.surface.layer?.contents != nil }
    c.selectRelative(1)
    let released = await waitFor(2) { framed.surface.layer?.contents == nil }
    c.selectRelative(-1)
    let redrawn = await waitFor(3) { framed.surface.layer?.contents != nil }
    r.check("a hidden pane releases its last frame and draws a new one when shown again", drew && released && redrawn,
            "drew \(drew) released \(released) redrawn \(redrawn)")
    // A visible pane that stops drawing (here: unfocused, no cursor blink) releases its GPU memory
    // after 3 s (scripts/ghostty.patch); its layer keeps showing the last frame, and the next frame
    // (focus: the hollow cursor turns solid) is drawn in full right away, with no blank frame.
    let ws = c.model.selected!
    if let idle = ws.panes.first(where: { $0 !== ws.focusedPane }) {
        let early = panePixels(c, idle)
        await sleepMs(4500)
        let a = panePixels(c, idle), contentsA = idle.surface.layer?.contents as AnyObject?
        c.focus(idle)
        let redrew = await waitFor(3) { (idle.surface.layer?.contents as AnyObject?) !== contentsA }
        await sleepMs(200)
        let after = panePixels(c, idle)
        let shown = a.map { px in Set(px).count > 1 } ?? false
        let changed = zip(a ?? [], after ?? []).filter { $0 != $1 }.count
        let total = max(1, a?.count ?? 1)
        r.check("an idle visible pane keeps its last frame, then redraws in full when it changes",
                shown && early == a && redrew && changed > 0 && Double(changed) / Double(total) < 0.03,
                "shown \(shown) kept \(early == a) redrew \(redrew) changed \(changed)/\(total) px")
    } else {
        r.check("an idle visible pane keeps its last frame, then redraws in full when it changes", false, "no unfocused pane")
    }

    // -------------------------------------------------------- agent awareness
    r.section = "agent"
    // p1 lives in workspace 1, which is not selected: it's unfocused.
    r.check("hook: UserPromptSubmit via socket", sendHook(pane: p1.id, hook("UserPromptSubmit", #""prompt":"hi""#)))
    r.check("hook: PreToolUse(Bash)", sendHook(pane: p1.id, hook("PreToolUse", #""tool_name":"Bash""#)))
    r.check("sidebar shows running (neutral) with the tool", await waitFor { ws1.display == .running("Bash") },
            "\(ws1.display)")
    r.check("Claude session id remembered from hooks", p1.claudeSessionID == "sess-1")
    let n0 = c.notifier.postedCount
    _ = sendHook(pane: p1.id, hook("PermissionRequest", #""tool_name":"Bash""#))
    r.check("permission -> needs input", await waitFor { ws1.display == .needsInput("Permission: Bash") }, "\(ws1.display)")
    r.check("unread badge counts it", ws1.unread == 1 && c.model.totalUnread == 1)
    r.check("one notification (pane not focused)", c.notifier.postedCount == n0 + 1
            && c.notifier.posted.last?.kind == "needsInput" && c.notifier.posted.last?.paneID == p1.id)
    _ = sendHook(pane: p1.id, hook("Notification", #""notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#))
    await sleepMs(200)
    r.check("duplicate permission notification is absorbed", c.notifier.postedCount == n0 + 1 && ws1.unread == 1)
    _ = sendHook(pane: p1.id, hook("SubagentStop", #""agent_id":"a1""#))
    await sleepMs(150)
    r.check("subagent events never flip state", ws1.display == .needsInput("Permission: Bash"))
    // …nor end or alert a running turn (the main agent is still working).
    let nSub = c.notifier.postedCount
    _ = sendHook(pane: p1.id, hook("PostToolUse", #""tool_name":"Bash""#))
    _ = sendHook(pane: p1.id, hook("PreToolUse", #""tool_name":"Bash""#))
    r.check("back to running after the permission", await waitFor { ws1.display == .running("Bash") }, "\(ws1.display)")
    for ev in [hook("SubagentStart", #""agent_id":"a2","agent_type":"Explore""#),
               hook("PreToolUse", #""agent_id":"a2","tool_name":"Grep""#),
               hook("Stop", #""agent_id":"a2","last_assistant_message":"sub done""#),
               hook("SubagentStop", #""agent_id":"a2","last_assistant_message":"sub done""#)] {
        _ = sendHook(pane: p1.id, ev)
    }
    await sleepMs(250)
    r.check("subagent start/tool/stop while running: still running the main tool, no alert",
            ws1.display == .running("Bash") && c.notifier.postedCount == nSub, "\(ws1.display)")
    _ = sendHook(pane: p1.id, hook("PermissionRequest", #""tool_name":"Bash""#))
    _ = await waitFor { p1.needsInput }

    // Nested `claude -p` (Claude's Bash tool) inherits LMUX_PANE_ID: it must not take over the pane.
    r.section = "agent-binding"
    let wsN = c.newWorkspace(select: false)
    let pN = wsN.panes[0]
    _ = await sinks.waitReady(pN.id)
    let fgN = pN.surface.foregroundPID
    let top = HookClient.Origin(pid: 70001, pgid: fgN)        // the pane's foreground claude
    // A detached `claude -p` started by it (Claude's Bash tool): own group, the pane's claude among its ancestors.
    let nested = HookClient.Origin(pid: 70002, pgid: 70002, ancestorGroups: [70010, fgN, fgN])
    r.check("pane has a foreground process group", fgN > 0, "\(fgN)")
    _ = sendHook(pane: pN.id, hook("SessionStart", session: "top", #""source":"startup","transcript_path":"/tmp/top.jsonl""#), from: top)
    _ = sendHook(pane: pN.id, hook("UserPromptSubmit", session: "top", #""prompt":"run the eval""#), from: top)
    _ = sendHook(pane: pN.id, hook("PreToolUse", session: "top", #""tool_name":"Bash""#), from: top)
    r.check("top-level session binds the pane", await waitFor { pN.claudeSessionID == "top" && pN.agent.state == .running })
    for ev in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] {
        _ = sendHook(pane: pN.id, hook(ev, session: "nested", #""source":"startup","transcript_path":"/tmp/nested.jsonl","prompt":"x","last_assistant_message":"nested done""#), from: nested)
    }
    await sleepMs(300)
    r.check("nested start/prompt/stop/end: pane keeps its session, transcript and running state",
            pN.claudeSessionID == "top" && pN.transcriptPath == "/tmp/top.jsonl" && pN.agent.state == .running
            && pN.runsClaude && pN.display == .running("Bash"), "\(pN.claudeSessionID ?? "nil") \(pN.agent.state)")
    r.check("…and no alert or unread from it", pN.unread == 0 && pN.alertDetail == nil)
    // Same, from an old lmux-hook that sends no process info: another session's events are ignored.
    _ = sendHook(pane: pN.id, hook("Stop", session: "other", #""last_assistant_message":"x""#))
    await sleepMs(150)
    r.check("an unknown session's Stop never ends the pane's turn", pN.agent.state == .running && pN.claudeSessionID == "top")
    // /clear: SessionEnd(clear) + SessionStart(clear) with a new id from the same claude.
    _ = sendHook(pane: pN.id, hook("Stop", session: "top"), from: top)
    _ = sendHook(pane: pN.id, hook("SessionEnd", session: "top", #""reason":"clear""#), from: top)
    _ = sendHook(pane: pN.id, hook("SessionStart", session: "cleared", #""source":"clear","transcript_path":"/tmp/cleared.jsonl""#), from: top)
    r.check("/clear rebinds the pane to the new session", await waitFor { pN.claudeSessionID == "cleared" }
            && pN.transcriptPath == "/tmp/cleared.jsonl" && pN.agent.state == .idle, "\(pN.claudeSessionID ?? "nil")")
    // /clear (or /resume) whose SessionEnd never arrived: the SessionStart alone switches.
    _ = sendHook(pane: pN.id, hook("SessionStart", session: "resumed", #""source":"resume""#), from: top)
    r.check("a SessionStart from the pane's claude switches sessions", await waitFor { pN.claudeSessionID == "resumed" })
    // A nested claude while the parent is idle (no top-level session events in between).
    _ = sendHook(pane: pN.id, hook("UserPromptSubmit", session: "nested2", #""prompt":"y""#), from: nested)
    await sleepMs(150)
    r.check("nested prompt while the parent is idle: still the parent's, still idle",
            pN.claudeSessionID == "resumed" && pN.agent.state == .idle)
    // Quit claude, start a new one.
    _ = sendHook(pane: pN.id, hook("SessionEnd", session: "resumed", #""reason":"prompt_input_exit""#), from: top)
    r.check("quitting claude unbinds the pane", await waitFor { pN.claudeSessionID == nil && !pN.runsClaude })
    _ = sendHook(pane: pN.id, hook("SessionStart", session: "nested3", #""source":"startup""#), from: nested)
    await sleepMs(150)
    r.check("a nested claude never binds a pane without a session", pN.claudeSessionID == nil)
    // nohup / double fork from the Bash tool: reparented to launchd, no ancestor in the pane.
    let detached = HookClient.Origin(pid: 70005, pgid: 70005, ancestorGroups: [])
    _ = sendHook(pane: pN.id, hook("SessionStart", session: "detached-1", #""source":"startup""#), from: detached)
    await sleepMs(150)
    r.check("a detached nested claude never binds an unbound pane", pN.claudeSessionID == nil)
    let top2 = HookClient.Origin(pid: 70003, pgid: fgN)
    _ = sendHook(pane: pN.id, hook("SessionStart", session: "new-claude", #""source":"startup""#), from: top2)
    r.check("a new claude after quitting binds the pane", await waitFor { pN.claudeSessionID == "new-claude" && pN.runsClaude })
    _ = sendHook(pane: pN.id, hook("SessionStart", session: "detached-2", #""source":"startup""#), from: detached)
    _ = sendHook(pane: pN.id, hook("UserPromptSubmit", session: "detached-2", #""prompt":"x""#), from: detached)
    await sleepMs(150)
    r.check("a detached nested claude never takes over a bound pane (switch only from the foreground group)",
            pN.claudeSessionID == "new-claude" && pN.agent.state == .idle, "\(pN.claudeSessionID ?? "nil")")
    _ = sendHook(pane: pN.id, hook("SessionEnd", session: "new-claude"), from: top2)
    _ = await waitFor { pN.claudeSessionID == nil }
    c.closeWorkspace(wsN)
    r.section = "agent"

    _ = sendHook(pane: p2.id, hook("UserPromptSubmit", session: "sess-2"))
    r.check("hook without process info (older lmux-hook) still binds", await waitFor { p2.agent.state == .running && p2.claudeSessionID == "sess-2" })
    // Real lmux-hook binary, run the way Claude Code runs it: by the pane's foreground process.
    if let hookBin = paths.hookBinary, FileManager.default.isExecutableFile(atPath: hookBin) {
        let res = await runProcess(hookBin, [], env: ["LMUX_PANE_ID": p2.id, "LMUX_SOCKET": paths.hookSocket],
                                   stdin: Data(hook("SessionStart", session: "from-outside", #""source":"startup""#).utf8))
        await sleepMs(200)
        r.check("lmux-hook binary exits 0 silently", res.status == 0 && res.out.isEmpty, res.err)
        r.check("a SessionStart from outside the pane's foreground group never rebinds it", p2.claudeSessionID == "sess-2")
        let fx0 = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("hookpane.sh")
        let payload = hook("SessionStart", session: "real-hook", #""source":"startup""#)
        try? "#!/bin/sh\nprintf '%s' '\(payload)' | '\(hookBin)'\nexec sleep 100000\n".write(to: fx0, atomically: true, encoding: .utf8)
        chmod(fx0.path, 0o755)
        let wsHook = c.newWorkspace(select: false, program: fx0.path)
        let ph = wsHook.panes[0]
        r.check("lmux-hook run by the pane's foreground process binds it, reporting that process",
                await waitFor(5) { ph.claudeSessionID == "real-hook" } && ph.claudePID == ph.surface.foregroundPID,
                "\(ph.claudeSessionID ?? "nil") pid=\(ph.claudePID ?? 0) fg=\(ph.surface.foregroundPID)")
        hookEvent(c, ph, "SessionEnd", session: "real-hook")
        c.closeWorkspace(wsHook)
    } else {
        r.check("bundled lmux-hook found", false, paths.hookBinary ?? "nil")
    }

    // Ring on an unfocused pane of the visible workspace.
    let other = ws2.panes.first { $0 !== ws2.focusedPane }!
    // The pane's own session (a pane only follows the claude bound to it).
    let s3 = other.claudeSessionID ?? "sess-3"
    _ = sendHook(pane: other.id, hook("UserPromptSubmit", session: s3))
    _ = sendHook(pane: other.id, hook("PreToolUse", session: s3, #""tool_name":"AskUserQuestion""#))
    r.check("question -> needs input on the unfocused split pane", await waitFor { other.needsInput })
    r.check("ring shows on that pane", await waitFor { other.view.ring.shown })
    r.check("no ring on the focused pane", !(ws2.focusedPane?.view.ring.shown ?? true))
    if let fp = ws2.focusedPane {
        _ = sendHook(pane: fp.id, hook("PermissionRequest", session: fp.claudeSessionID ?? "sess-f", #""tool_name":"Bash""#))
        _ = await waitFor { fp.needsInput }
        r.check("the focused pane shows no ring even when it needs input", fp.needsInput && !fp.view.ring.shown)
        fp.agent.userTyped()
        c.refreshPaneChrome()
    }

    // Jumping (R15) and the bell.
    c.assumeAppActive = true  // from here on, behave like a frontmost app
    c.jumpToNextNeedsInput()
    r.check("next needs-input jump goes to one that needs input", c.model.selected?.focusedPane?.needsInput == true)
    let firstJump = c.model.selected?.focusedPane
    c.jumpToNextNeedsInput()
    r.check("…and cycles to the other one", c.model.selected?.focusedPane !== firstJump
            && c.model.selected?.focusedPane?.needsInput == true)
    await cmd("j", shift: true, window: w)
    r.check("⇧⌘J typed on the keyboard reaches lmux (Ghostty's default write_screen_file binding is off)",
            c.model.selected?.focusedPane === firstJump)
    r.check("focusing clears unread and the ring", (c.model.selected?.focusedPane?.unread ?? 1) == 0
            && !(c.model.selected?.focusedPane?.view.ring.shown ?? true))
    c.select(ws2, focusing: ws2.panes.first { $0 !== other })
    _ = sendHook(pane: other.id, hook("Stop", session: s3, #""last_assistant_message":"All done.""#))
    await sleepMs(200)
    r.check("an unfocused pane that is only done/unread gets no ring (rings mean: needs you)",
            other.unread > 0 && !other.needsInput && !other.view.ring.shown)
    let bellCount = c.model.totalUnread
    c.jumpToLatestUnread()
    r.check("bell jumps to the latest unread pane", c.model.selected?.focusedPane === other, "unread=\(bellCount)")

    // Typing clears needs-input (Esc interrupt sends no hook event).
    c.focus(p1)
    r.check("p1 still needs input before typing", p1.needsInput)
    await type("y", window: w)
    r.check("typing into the pane clears needs input", !p1.needsInput && ws1.display == .idle, "\(ws1.display)")
    let n1 = c.notifier.postedCount
    _ = sendHook(pane: p1.id, hook("UserPromptSubmit"))
    _ = sendHook(pane: p1.id, hook("Stop", #""last_assistant_message":"Fixed it.\nDetails…""#))
    r.check("done state", await waitFor { ws1.display == .done("Fixed it.") }, "\(ws1.display)")
    r.check("no notification for the focused pane", c.notifier.postedCount == n1 && p1.unread == 0)
    _ = sendHook(pane: p2.id, hook("StopFailure", session: "sess-2", #""error_type":"rate_limit""#))
    r.check("failed state on an unfocused pane", await waitFor { p2.display == .failed("rate_limit") })
    r.check("…notifies once", c.notifier.postedCount == n1 + 1 && c.notifier.posted.last?.kind == "failed")

    // ---------------------------------------------------------------- CLI
    r.section = "cli"
    let cli = paths.binDir!.appendingPathComponent("lmux").path
    let cliEnv = ["LMUX_CONTROL_SOCKET": paths.controlSocket, "LMUX_PANE_ID": ""]
    let count0 = c.model.workspaces.count
    let res1 = await runProcess(cli, ["new-workspace", "--cwd", "/tmp", "--cmd", "echo hi"], env: cliEnv)
    r.check("lmux new-workspace", res1.status == 0 && c.model.workspaces.count == count0 + 1, res1.out + res1.err)
    let wsCli = c.model.selected!
    let pCli = wsCli.panes[0]
    r.check("…in the requested cwd", pCli.cwd == "/tmp" || pCli.cwd == "/private/tmp", pCli.cwd ?? "nil")
    r.check("…types the command into the new pane", await sinks.wait(pCli.id, contains: "echo hi"), sinks.text(pCli.id))
    let res2 = await runProcess(cli, ["send", "--pane", p2.id, #"hello\n"#], env: cliEnv)
    let sent = await sinks.wait(p2.id, contains: "hello\r")
    r.check("lmux send types text + Return into the pane", res2.status == 0 && sent, sinks.text(p2.id) + res2.err)
    let res3 = await runProcess(cli, ["send", "--pane", "nope", "x"], env: cliEnv)
    r.check("lmux send to an unknown pane fails", res3.status != 0 && res3.err.contains("no such pane"))
    // From outside lmux with only LMUX_STATE_DIR (a second instance): the CLI finds that instance.
    let viaState = await runProcess(cli, ["send", "--pane", p2.id, "viastate"],
                                    env: ["LMUX_CONTROL_SOCKET": "", "LMUX_PANE_ID": "", "LMUX_STATE_DIR": paths.stateDir.path])
    let viaArrived = await sinks.wait(p2.id, contains: "viastate")
    r.check("lmux send from outside finds the instance of LMUX_STATE_DIR", viaState.status == 0 && viaArrived, viaState.err)
    let list = await runProcess(cli, ["list"], env: cliEnv)
    r.check("lmux list shows workspaces and pane ids", list.status == 0 && list.out.contains(p2.id) && list.out.contains(pCli.id), list.out + list.err)
    let listJSON = await runProcess(cli, ["list", "--json"], env: cliEnv)
    let parsed = (try? JSONSerialization.jsonObject(with: Data(listJSON.out.utf8))) as? [[String: Any]]
    r.check("lmux list --json parses", parsed?.count == c.model.workspaces.count, listJSON.out.prefix(200) + listJSON.err)
    // A response far bigger than the socket buffer (many panes, long titles) arrives whole.
    let bigPane = c.model.workspaces[0].panes[0]
    let cwd0 = bigPane.cwd
    bigPane.cwd = "/" + String(repeating: "long-dir-name/", count: 4700)  // ~66KB
    let bigList = await runProcess(cli, ["list", "--json"], env: cliEnv)
    bigPane.cwd = cwd0
    let bigParsed = (try? JSONSerialization.jsonObject(with: Data(bigList.out.utf8))) as? [[String: Any]]
    r.check("lmux list with a ~66KB response arrives whole and parses",
            bigList.status == 0 && bigParsed?.count == c.model.workspaces.count && bigList.out.utf8.count > 65_000,
            "\(bigList.out.utf8.count) bytes " + bigList.err)
    // The pane environment never carries the launching process's terminal / Claude session markers.
    let envText = (try? String(contentsOf: sinks.dir.appendingPathComponent("\(p2.id).env"), encoding: .utf8)) ?? ""
    let envNames = Set(envText.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
    // libghostty sets TERM_PROGRAM(_VERSION) and GHOSTTY_BIN_DIR / _SHELL_FEATURES / _SURFACE_ID for its child, as in Ghostty.
    let ghosttyOwn: Set<String> = ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "GHOSTTY_BIN_DIR", "GHOSTTY_SHELL_FEATURES", "GHOSTTY_SURFACE_ID"]
    let leaked = envNames.filter { LmuxController.isInherited($0) && !ghosttyOwn.contains($0) && !$0.hasPrefix("LMUX_") }
    r.check("a pane's environment has no inherited CLAUDECODE / CLAUDE_CODE_* / CMUX_* / other-terminal vars", leaked.isEmpty,
            leaked.sorted().joined(separator: ","))
    r.check("…set by lmux's parent, they're dropped at startup", ProcessInfo.processInfo.environment["CLAUDE_CODE_CHILD_SESSION"] == nil
            && ProcessInfo.processInfo.environment["CMUX_SOCKET_PATH"] == nil && ProcessInfo.processInfo.environment["CLAUDECODE"] == nil)
    r.check("…but the user's Claude settings stay (CLAUDE_CODE_USE_BEDROCK)", !LmuxController.isInherited("CLAUDE_CODE_USE_BEDROCK"))
    r.check("…and Ghostty's resources dir stays", !LmuxController.isInherited("GHOSTTY_RESOURCES_DIR"))
    r.check("raw OSC titles lose their spinner glyphs", Pane.cleanTitle("✳ Claude Code") == "Claude Code"
            && Pane.cleanTitle("⠋ Fix the bug") == "Fix the bug" && Pane.cleanTitle("vim") == "vim")
    // Cross-pane send: a process inside pane X may only type into X (identified by X's token).
    let tok1 = c.token(for: p1) ?? "", tok2 = c.token(for: p2) ?? ""
    r.check("every pane gets its own unguessable LMUX_PANE_NONCE", tok1.count == 32 && tok2.count == 32 && tok1 != tok2
            && !tok1.contains(p1.id))
    let p2Env = (try? String(contentsOf: sinks.dir.appendingPathComponent("\(p2.id).env"), encoding: .utf8)) ?? ""
    r.check("…in the pane's environment, and under the old name LMUX_PANE_TOKEN too (one release)",
            p2Env.contains("LMUX_PANE_NONCE=\(tok2)\n") && p2Env.contains("LMUX_PANE_TOKEN=\(tok2)\n"))
    let selfSend = await runProcess(cli, ["send", "--pane", p2.id, "own"], env: cliEnv.merging(["LMUX_PANE_NONCE": tok2]) { $1 })
    let ownArrived = await sinks.wait(p2.id, contains: "own")
    r.check("lmux send from inside a pane into itself works", selfSend.status == 0 && ownArrived, selfSend.err)
    let oldName = await runProcess(cli, ["send", "--pane", p2.id, "oldname"], env: cliEnv.merging(["LMUX_PANE_TOKEN": tok2]) { $1 })
    let oldArrived = await sinks.wait(p2.id, contains: "oldname")
    r.check("…also with only the old LMUX_PANE_TOKEN set (an older shell's environment, one release)",
            oldName.status == 0 && oldArrived, oldName.err)
    let cross = await runProcess(cli, ["send", "--pane", p2.id, "evil"], env: cliEnv.merging(["LMUX_PANE_NONCE": tok1]) { $1 })
    await sleepMs(150)
    r.check("lmux send from pane 1 into pane 2 is refused by default", cross.status != 0 && cross.err.contains("allowCrossPaneSend")
            && !sinks.text(p2.id).contains("evil"), cross.err)
    // The setting is read at each send: `defaults write` on a running lmux applies at once
    // (a temp defaults suite stands in for dev.lmux.app; removed again below).
    let suite = "dev.lmux.apptest.\(getpid())"
    c.defaults = UserDefaults(suiteName: suite)!
    let wrote = await runProcess("/usr/bin/defaults", ["write", suite, "allowCrossPaneSend", "-bool", "true"], env: cliEnv)
    let crossOK = await runProcess(cli, ["send", "--pane", p2.id, "granted"], env: cliEnv.merging(["LMUX_PANE_NONCE": tok1]) { $1 })
    let granted = await sinks.wait(p2.id, contains: "granted")
    r.check("…and allowed once the user turns it on (defaults write, no relaunch)", wrote.status == 0 && crossOK.status == 0 && granted,
            wrote.err + crossOK.err)
    _ = await runProcess("/usr/bin/defaults", ["delete", suite, "allowCrossPaneSend"], env: cliEnv)
    let crossOff = await runProcess(cli, ["send", "--pane", p2.id, "revoked"], env: cliEnv.merging(["LMUX_PANE_NONCE": tok1]) { $1 })
    await sleepMs(150)
    r.check("…and refused again once it's turned off", crossOff.status != 0 && !sinks.text(p2.id).contains("revoked"), crossOff.err)
    c.defaults.removePersistentDomain(forName: suite)
    _ = await runProcess("/usr/bin/defaults", ["delete", suite], env: cliEnv)
    c.defaults = .standard
    // cfprefsd leaves an empty plist behind; this suite was the test's own.
    let suitePlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suite).plist")
    for _ in 0..<20 where FileManager.default.fileExists(atPath: suitePlist.path) {
        try? FileManager.default.removeItem(at: suitePlist)
        await sleepMs(100)
    }
    // Unsetting the token doesn't get around it: the caller's tty says which pane it runs in.
    let sneak = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("sneak.sh")
    let sneakOut = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("sneak.status")
    try? "#!/bin/sh\nenv -u LMUX_PANE_NONCE -u LMUX_PANE_TOKEN '\(cli)' send --pane \(p2.id) sneaky 2>/dev/null; echo $? > '\(sneakOut.path)'\nexec sleep 100000\n"
        .write(to: sneak, atomically: true, encoding: .utf8)
    chmod(sneak.path, 0o755)
    let wsSneak = c.newWorkspace(select: false, program: sneak.path)
    _ = await waitFor(5) { FileManager.default.fileExists(atPath: sneakOut.path) }
    await sleepMs(150)
    let sneakStatus = (try? String(contentsOf: sneakOut, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    r.check("…even with LMUX_PANE_NONCE / LMUX_PANE_TOKEN unset (the caller's tty is a pane's)", sneakStatus == "1"
            && !sinks.text(p2.id).contains("sneaky"), "status=\(sneakStatus ?? "nil")")
    c.closeWorkspace(wsSneak)
    let n2 = c.notifier.postedCount
    let res4 = await runProcess(cli, ["notify", "build finished"], env: cliEnv.merging(["LMUX_PANE_ID": p2.id]) { $1 })
    r.check("lmux notify from an unfocused pane", res4.status == 0 && c.notifier.postedCount == n2 + 1
            && p2.workspace?.notification == "build finished", res4.err)
    // Rate limit: one notification per pane per 5s; a burst is coalesced into one at the end.
    r.check("notify rate limit is 5s per pane", c.notifyInterval == 5)
    c.notifyInterval = 1
    try? await Task.sleep(for: .milliseconds(1100))
    let n3 = c.notifier.postedCount
    for i in 1...5 { c.notify(text: "step \(i)", title: nil, paneID: p2.id) }
    r.check("a burst posts one notification right away", c.notifier.postedCount == n3 + 1
            && c.notifier.posted.last?.body == "step 1" && p2.workspace?.notification == "step 5")
    _ = await waitFor(2) { c.notifier.postedCount == n3 + 2 }
    await sleepMs(300)
    r.check("…and the rest as one coalesced notification with the latest text", c.notifier.postedCount == n3 + 2
            && c.notifier.posted.last?.body == "step 5", c.notifier.posted.suffix(3).map(\.body).joined(separator: ", "))
    c.notifyInterval = 5

    // ------------------------------------------------- single instance
    r.section = "single-instance"
    let second = ControlServer(path: paths.controlSocket) { _ in ["ok": true, "second": true] }
    var refused = false
    do { try second.start() } catch { refused = true }
    r.check("a second instance never takes over the live control socket", refused)
    let still = await runProcess(cli, ["notify", "still here"], env: cliEnv)
    r.check("…and the running instance still answers", still.status == 0, still.err)
    let activations = c.activationRequests
    let handedOff = await Task.detached { ControlServer.handOff(path: paths.controlSocket) }.value
    let activated = await waitFor { c.activationRequests == activations + 1 }
    r.check("a second launch hands off: asks the running one to come forward, then exits", handedOff && activated)
    r.check("…headless: nothing activated, no window raised", !NSApp.isActive && !c.window.isKeyWindow)

    // ------------------------------------------- control server: never blocks the main thread
    r.section = "control-server-nonblocking"
    let stuckPane = c.model.workspaces[0].panes[0]
    let stuckCwd0 = stuckPane.cwd
    // Bigger than any socket send buffer: writing this to a client that never reads would
    // block a synchronous `write()` for its full timeout (ControlServer.writeAll must not).
    stuckPane.cwd = "/" + String(repeating: "pad-dir-name/", count: 300_000)
    if let stuckFD = ControlServer.connect(paths.controlSocket) {
        let req = Array("{\"cmd\":\"list\"}\n".utf8)
        _ = req.withUnsafeBufferPointer { Darwin.write(stuckFD, $0.baseAddress, $0.count) }
        // Never read from stuckFD: the server must answer a concurrent client promptly anyway.
        let start = Date()
        let concurrent = await runProcess(cli, ["list"], env: cliEnv)
        let elapsed = Date().timeIntervalSince(start)
        r.check("a client that connects, sends a request and never reads doesn't block the main "
                + "thread: a concurrent `lmux list` still completes promptly",
                concurrent.status == 0 && elapsed < 0.3, "elapsed=\(Int(elapsed * 1000))ms " + concurrent.err)
        Darwin.close(stuckFD)
    } else {
        r.check("could open a raw client connection to the control socket", false)
    }
    stuckPane.cwd = stuckCwd0

    // --------------------------------------------- notification click -> reopenWindow (R14)
    r.section = "notification-click"
    // Headless: no system notification is ever posted, so the real UNUserNotificationCenter
    // delegate callback never fires. `simulateClick` exercises the same `onActivate` path it
    // would take, and `reopenWindowCalls` is the only way to see that it reached `reopenWindow()`
    // (whose body is a no-op in headless mode).
    let reopensBefore = c.reopenWindowCalls
    c.notifier.simulateClick(paneID: p1.id)
    r.check("a clicked notification reaches reopenWindow()", c.reopenWindowCalls == reopensBefore + 1)
    r.check("…and focuses that notification's pane", firstResponderPane(c) === p1)
    r.check("…without activating the app or raising a window (headless)", !NSApp.isActive && !c.window.isKeyWindow)
    let reopensBefore2 = c.reopenWindowCalls
    c.notifier.simulateClick(paneID: "no-such-pane")
    r.check("a click for an unknown pane id is ignored (no onActivate match)", c.reopenWindowCalls == reopensBefore2)

    // ------------------------------------------------- drag & drop, image paste (R18)
    r.section = "drop-paste"
    PasteContents.imageDirectory = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("paste", isDirectory: true)
    let wsD = c.newWorkspace()
    let pD = wsD.panes[0]
    _ = await sinks.waitReady(pD.id)
    r.check("panes accept dropped files, text and images", Set(pD.surface.registeredDraggedTypes)
            .isSuperset(of: [.fileURL, .string, .png, .tiff]))
    let dropPB = NSPasteboard(name: NSPasteboard.Name("dev.lmux.apptest.drop.\(getpid())"))
    dropPB.clearContents()
    dropPB.writeObjects([URL(fileURLWithPath: "/tmp/a b/it's (1).txt") as NSURL, URL(fileURLWithPath: "/tmp/plain.md") as NSURL])
    r.check("dropping files is accepted", pD.surface.drop(dropPB))
    let dropped = await sinks.wait(pD.id, contains: #"/tmp/a\ b/it\'s\ \(1\).txt /tmp/plain.md"#)
    r.check("…and inserts their shell-escaped paths, space separated (like Ghostty)", dropped, sinks.text(pD.id))
    let pb = GhosttyRuntime.standardPasteboard
    pb.clearContents()
    pb.writeObjects([URL(fileURLWithPath: "/tmp/copied in Finder.png") as NSURL])
    await cmd("v", window: w)
    let pastedFile = await sinks.wait(pD.id, contains: #"/tmp/copied\ in\ Finder.png"#)
    r.check("⌘V with a file copied in Finder pastes its escaped path", pastedFile, sinks.text(pD.id))
    pb.clearContents()
    pb.setString("plain paste ok", forType: .string)
    await cmd("v", window: w)
    let pastedText = await sinks.wait(pD.id, contains: "plain paste ok")
    r.check("⌘V with text pastes the text", pastedText)
    // An image on the clipboard (a screenshot): saved as a PNG, its path pasted.
    let img = NSImage(size: NSSize(width: 8, height: 8))
    img.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); img.unlockFocus()
    pb.clearContents()
    pb.setData(img.tiffRepresentation, forType: .tiff)
    await cmd("v", window: w)
    _ = await sinks.wait(pD.id, contains: ".png", timeout: 3)
    let text = String(decoding: sinks.bytes(pD.id), as: UTF8.self)
    let pngPath = text.range(of: #"/\S*/paste/pasted-\S*\.png"#, options: .regularExpression)
        .map { String(text[$0]).replacingOccurrences(of: "\\", with: "") }
    let pngData = pngPath.flatMap { FileManager.default.contents(atPath: $0) }
    let pngMode = pngPath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.posixPermissions] as? NSNumber }
    r.check("⌘V with an image pastes the path of a PNG copy (Claude Code attaches it as an image)",
            pngData.map { Array($0.prefix(4)) == [0x89, 0x50, 0x4E, 0x47] } == true && pngMode?.intValue == 0o600,
            pngPath ?? sinks.text(pD.id))
    // Text copied after an image replaces it: ⌘V gives the text, never the old image too.
    func pastes(_ id: String) -> String { String(decoding: sinks.bytes(id), as: UTF8.self) }
    let wsT = c.newWorkspace()
    let pT = wsT.panes[0]
    _ = await sinks.waitReady(pT.id)
    pT.surface.pasteText("! open -a Safari ~")  // the sink echoes it onto the screen
    _ = await waitFor(2) { pT.surface.readText().contains("Safari ~") }
    pb.clearContents()
    pb.setData(img.tiffRepresentation, forType: .tiff)
    _ = pT.surface.performBindingAction("select_all")
    _ = pT.surface.performBindingAction("copy_to_clipboard")
    let types = pb.types ?? []
    r.check("copying text in a pane after an image leaves only text on the clipboard",
            !types.contains(.tiff) && !types.contains(.png) && pb.string(forType: .string)?.contains("Safari ~") == true, "\(types)")
    // (A select-all copy is multi-line, which the sink's unbracketed paste would confirm: check
    // what a paste would send instead.)
    let wouldPaste = PasteContents.string(from: pb) ?? ""
    r.check("…and a paste then sends that text only", wouldPaste.contains("Safari ~") && !wouldPaste.contains(".png"), wouldPaste.debugDescription)
    // Text and an image on the clipboard together (rich text with an inline picture): text only.
    let rich = NSPasteboardItem()
    rich.setString("caption text", forType: .string)
    rich.setData(img.tiffRepresentation!, forType: .tiff)
    let picture = NSPasteboardItem()
    picture.setData(img.tiffRepresentation!, forType: .png)
    for (name, items) in [("one item", [rich]), ("separate items", [picture, rich])] {
        pb.clearContents()
        pb.writeObjects(items.map { i in let n = NSPasteboardItem(); for t in i.types { n.setData(i.data(forType: t)!, forType: t) }; return n })
        let mark = pastes(pT.id).count
        await cmd("v", window: w)
        _ = await waitFor(2) { pastes(pT.id).dropFirst(mark).contains("caption text") }
        await sleepMs(200)
        let p = String(pastes(pT.id).dropFirst(mark))
        r.check("⌘V with text + image (\(name)) pastes the text only", p.contains("caption text") && !p.contains(".png"), p.debugDescription)
    }
    c.closeWorkspace(wsT)
    c.focus(pD)
    dropPB.clearContents()
    dropPB.setData(img.tiffRepresentation, forType: .tiff)
    let pngsBefore = String(decoding: sinks.bytes(pD.id), as: UTF8.self).components(separatedBy: ".png").count
    let droppedImage = pD.surface.drop(dropPB)
    let imageArrived = await waitFor(2) {
        String(decoding: sinks.bytes(pD.id), as: UTF8.self).components(separatedBy: ".png").count > pngsBefore
    }
    r.check("dropping an image works the same way", droppedImage && imageArrived)
    func pngCount() -> Int { String(decoding: sinks.bytes(pD.id), as: UTF8.self).components(separatedBy: ".png").count }
    // An image dragged from a browser: image data + its web address, no file on disk.
    dropPB.clearContents()
    let browserItem = NSPasteboardItem()
    browserItem.setData(img.tiffRepresentation!, forType: .tiff)
    browserItem.setString("https://example.com/cat.png", forType: .URL)
    browserItem.setString("https://example.com/cat.png", forType: .string)
    dropPB.writeObjects([browserItem])
    let pngs0 = pngCount()
    _ = pD.surface.drop(dropPB)
    let browserArrived = await waitFor(2) { pngCount() > pngs0 }
    r.check("an image dragged from a browser drops as a private PNG file, not its URL",
            browserArrived && !sinks.text(pD.id).contains("example.com/cat.png"), sinks.text(pD.id).suffix(120).description)
    // A link from a browser's address bar (URL only) drops as the URL text.
    dropPB.clearContents()
    let linkItem = NSPasteboardItem()
    linkItem.setString("https://example.com/page", forType: .URL)
    dropPB.writeObjects([linkItem])
    _ = pD.surface.drop(dropPB)
    r.check("a dragged link drops as its URL", await sinks.wait(pD.id, contains: "https://example.com/page"))
    // A folder, and text dragged from another app.
    dropPB.clearContents()
    dropPB.writeObjects([URL(fileURLWithPath: "/tmp/My Folder", isDirectory: true) as NSURL])
    _ = pD.surface.drop(dropPB)
    r.check("a dropped folder inserts its escaped path", await sinks.wait(pD.id, contains: #"/tmp/My\ Folder"#))
    dropPB.clearContents()
    dropPB.setString("dragged words", forType: .string)
    _ = pD.surface.drop(dropPB)
    r.check("dragged text inserts the text", await sinks.wait(pD.id, contains: "dragged words"))
    // A file promise (the screenshot thumbnail, Photos): received into lmux's private dir, path pasted.
    final class PromiseSource: NSObject, NSFilePromiseProviderDelegate {
        func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Screenshot 2026.png" }
        func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
            let d = NSBitmapImageRep(data: NSImage(size: NSSize(width: 4, height: 4)).tiffRepresentation ?? Data())?
                .representation(using: .png, properties: [:]) ?? Data([0x89, 0x50, 0x4E, 0x47])
            completionHandler((try? d.write(to: url)) == nil ? CocoaError(.fileWriteUnknown) : nil)
        }
    }
    let promiseSource = PromiseSource()
    let provider = NSFilePromiseProvider(fileType: "public.png", delegate: promiseSource)
    dropPB.clearContents()
    dropPB.writeObjects([provider])
    let receivers = (dropPB.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
    let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    r.check("panes accept file promises (the screenshot thumbnail) and recognize one on the pasteboard",
            promiseTypes.isSubset(of: Set(pD.surface.registeredDraggedTypes)) && receivers.count == 1
            && PasteContents.dropString(from: dropPB) == nil)
    // The promised file itself is only written inside a real drag session (window server):
    // the manual checklist covers dragging the screenshot thumbnail.
    var promised: [URL]?
    PasteContents.receive(receivers) { promised = $0 }
    _ = await waitFor(2) { promised != nil }
    print("INFO  [drop-paste] file promise outside a drag session: \(promised.map { "\($0.count) file(s)" } ?? "not delivered (expected)")")
    // Dropping on a pane that isn't focused: it goes there, and that pane gets the keyboard.
    let pD2 = c.split(pD, .right)!
    _ = await sinks.waitReady(pD2.id)
    c.focus(pD)
    dropPB.clearContents()
    dropPB.setString("to the other pane", forType: .string)
    let info = FakeDrag(pasteboard: dropPB, window: w)
    r.check("a drag over a pane highlights it (drop target)",
            pD2.surface.draggingEntered(info) == .copy && pD2.view.overlay.dropTarget)
    _ = pD2.surface.performDragOperation(info)
    r.check("…dropping clears the highlight", !pD2.view.overlay.dropTarget)
    let toOther = await sinks.wait(pD2.id, contains: "to the other pane")
    r.check("a drop on an unfocused pane goes to THAT pane and focuses it",
            toOther && firstResponderPane(c) === pD2 && wsD.focusedPane === pD2 && !sinks.text(pD.id).contains("to the other pane"))
    _ = pD.surface.draggingEntered(info)
    pD.surface.draggingExited(info)
    r.check("a drag that leaves clears the highlight", !pD.view.overlay.dropTarget)
    // ⌃V is Claude Code's own image paste (it reads the clipboard itself): passed through untouched.
    let ts = ProcessInfo.processInfo.systemUptime
    for t in [NSEvent.EventType.keyDown, .keyUp] {
        dispatchKey(NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [.control], timestamp: ts, windowNumber: w.windowNumber,
                                     context: nil, characters: "\u{16}", charactersIgnoringModifiers: "v", isARepeat: false,
                                     keyCode: 9)!, window: w)
    }
    r.check("⌃V reaches the program as ^V (0x16), lmux doesn't paste", await waitFor(2) { sinks.bytes(pD2.id).contains(0x16) })
    dropPB.releaseGlobally()
    pb.clearContents()
    c.closeWorkspace(wsD)

    // ------------------------------------------------- ⌘F search, Secure Keyboard Entry
    r.section = "search"
    let wsS = c.newWorkspace()
    let pS = wsS.panes[0]
    _ = await sinks.waitReady(pS.id)
    pS.surface.sendText("findme one findme two findme\r")
    _ = await waitFor(3) { pS.surface.readText().contains("findme two") }
    await cmd("f", window: w)
    let bar = pS.view.overlay.findBar
    r.check("⌘F opens the find bar (Ghostty's start_search)", bar != nil && !(bar?.isHidden ?? true))
    r.check("…with the keyboard in its field", c.window.firstResponder is NSText)
    bar?.field.stringValue = "findme"
    bar?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    r.check("typing searches the scrollback (libghostty counts the matches)", await waitFor(3) { (bar?.total ?? 0) >= 3 },
            "total=\(bar?.total.map(String.init) ?? "nil")")
    bar?.onNavigate?(true)
    r.check("Return / ⌘G selects a match", await waitFor(2) { bar?.selected != nil } && (bar?.count.stringValue ?? "").contains("/"),
            bar?.count.stringValue ?? "")
    bar?.onClose?()
    r.check("Esc closes it and the keyboard is back in the pane", pS.view.overlay.findBar == nil && firstResponderPane(c) === pS)
    c.secureKeyboardEntry = true
    r.check("Secure Keyboard Entry toggles from the menu", c.secureInputMenuItem?.state == .on)
    r.check("…and only engages while lmux is the active app (never in the background)", !c.secureInputEngaged)
    c.secureKeyboardEntry = false
    r.check("…and turns off", c.secureInputMenuItem?.state == .off && !c.secureInputEngaged)
    c.closeWorkspace(wsS)

    // ------------------------------------------------- P2: message actions, guard, titles, History
    await runP2(r, c, w)

    // ------------------------------------------------------ hooks installer
    r.section = "hooks-setup"
    let tmp = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("claude/settings.json")
    try? FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Formatted the way Claude Code writes settings.json (JSON.stringify, 2 spaces).
    let original = """
    {
      "model": "opus",
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "say done"
              }
            ]
          }
        ]
      }
    }

    """
    try? Data(original.utf8).write(to: tmp)
    do {
        let hookBin = paths.hookBinary ?? "/x/lmux-hook"
        let plan = try HooksSetup.planInstall(settingsPath: tmp.path, hookBinary: hookBin)
        let diff = HooksSetup.diff(plan)
        r.check("install plan shows an exact unified diff", diff.contains("+") && diff.contains("lmux-managed")
                && diff.contains("--- \(tmp.path)"))
        try HooksSetup.apply(plan)
        r.check("hooks installed in the temp settings", HooksSetup.isInstalled(settingsPath: tmp.path))
        let text = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        // Full structure: the installed file minus lmux's groups is exactly the original document.
        func dropLmux(_ v: JSONValue) -> JSONValue {
            guard case .object(var root) = v, let hi = root.firstIndex(where: { $0.key == "hooks" }),
                  case .object(var hooks) = root[hi].value else { return v }
            hooks = hooks.compactMap { m in
                guard case .array(let groups) = m.value else { return m }
                let kept = groups.filter { !"\($0)".contains(HookInstaller.marker) }
                return kept.isEmpty ? nil : .init(m.key, .array(kept))
            }
            root[hi].value = .object(hooks)
            return .object(root)
        }
        let same = (try? JSONValue.parse(text)).map(dropLmux) == (try? JSONValue.parse(original))
        r.check("foreign hooks and every other key kept (full JSON structure)", same)
        let removedLines = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
        r.check("the install diff only adds lines", removedLines.isEmpty, removedLines.joined(separator: " | "))
        let again = try HooksSetup.planInstall(settingsPath: tmp.path, hookBinary: hookBin)
        r.check("reinstall is a no-op", !again.changed)
        try HooksSetup.apply(try HooksSetup.planUninstall(settingsPath: tmp.path))
        let after = (try? Data(contentsOf: tmp)) ?? Data()
        r.check("uninstall restores the file byte for byte", after == Data(original.utf8),
                String(decoding: after, as: UTF8.self).debugDescription)
        r.check("real ~/.claude/settings.json untouched (not the path used)",
                tmp.path != HookInstaller.defaultSettingsPath(environment: ["HOME": NSHomeDirectory()]))
        // The sheet was up while settings.json changed: the confirmed install is planned again from
        // the file as it is now, so the edit made meanwhile is kept.
        let shown = try HooksSetup.planInstall(settingsPath: tmp.path, hookBinary: hookBin)
        let editedMeanwhile = original.replacingOccurrences(of: "\"model\": \"opus\"", with: "\"model\": \"sonnet\"")
        try Data(editedMeanwhile.utf8).write(to: tmp)
        let applyErr = c.applyHooksChange(shown, install: true)
        let afterEdit = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        r.check("settings.json edited while the sheet was up: re-planned, the edit kept, hooks installed",
                applyErr == nil && afterEdit.contains("\"model\": \"sonnet\"") && HooksSetup.isInstalled(settingsPath: tmp.path)
                    && c.actionLog.contains { $0.hasPrefix("hooks:") && $0.contains("planned again") }, "\(String(describing: applyErr))")
        try HooksSetup.apply(try HooksSetup.planUninstall(settingsPath: tmp.path))
        // …and a failure is reported (the sheet shows it), nothing written.
        let shown2 = try HooksSetup.planInstall(settingsPath: tmp.path, hookBinary: hookBin)
        try Data("[]".utf8).write(to: tmp)
        let applyErr2 = c.applyHooksChange(shown2, install: true)
        r.check("…a change that can't be applied returns its error (shown in an alert), file untouched",
                applyErr2 != nil && (try? String(contentsOf: tmp, encoding: .utf8)) == "[]", "\(String(describing: applyErr2))")
        try Data(original.utf8).write(to: tmp)
        // Hooks installed by an lmux at another path (moved / reinstalled app) are offered an update.
        try HooksSetup.apply(try HooksSetup.planInstall(settingsPath: tmp.path, hookBinary: "/Applications/old lmux.app/lmux-hook"))
        r.check("installed hooks running another lmux-hook are detected as stale",
                HooksSetup.installedHookIsStale(settingsPath: tmp.path, hookBinary: hookBin))
        let update = try HooksSetup.planInstall(settingsPath: tmp.path, hookBinary: hookBin)
        try HooksSetup.apply(update)
        r.check("…the update points them at this lmux-hook (no longer stale)",
                update.changed && !HooksSetup.installedHookIsStale(settingsPath: tmp.path, hookBinary: hookBin)
                    && HooksSetup.isInstalled(settingsPath: tmp.path))
        try HooksSetup.apply(try HooksSetup.planUninstall(settingsPath: tmp.path))
        r.check("…and settings without lmux hooks are never stale", !HooksSetup.installedHookIsStale(settingsPath: tmp.path, hookBinary: hookBin))
    } catch {
        r.check("installer", false, "\(error)")
    }

    // ---------------------------------------------------------- persistence
    r.section = "persistence"
    // Leave a known layout: workspace 2 split with a custom title and a Claude session.
    ws2.customTitle = "payments refactor"
    // Claude exited in p1/p2 (SessionEnd clears the session); one still runs in `other`.
    _ = sendHook(pane: p1.id, hook("SessionEnd", #""reason":"prompt_input_exit""#))
    _ = sendHook(pane: p2.id, hook("SessionEnd", session: "sess-2", #""reason":"other""#))
    // A stand-in `claude` started with flags and a leading env assignment, as the user would type it.
    let fakeDir = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("fake-bin")
    try? FileManager.default.createDirectory(at: fakeDir, withIntermediateDirectories: true)
    let fakeClaude = fakeDir.appendingPathComponent("claude")
    try? "#!/bin/sh\nsleep 30\n".write(to: fakeClaude, atomically: true, encoding: .utf8)
    chmod(fakeClaude.path, 0o755)
    let fake = Process()
    fake.executableURL = fakeClaude
    fake.arguments = ["--model", "opus", "--add-dir", "/tmp/a", "/tmp/b c", "--permission-mode", "plan", "do the thing"]
    fake.environment = ProcessInfo.processInfo.environment.merging(["CLAUDE_CONFIG_DIR": "/tmp/lmux test claude"]) { $1 }
    try? fake.run()
    await sleepMs(150)
    // What a compromised or old lmux-hook could send: secrets next to the real settings.
    let secrets = ["ANTHROPIC_CUSTOM_HEADERS": "Authorization: Bearer sk-SECRET-HEADER",
                   "ANTHROPIC_BASE_URL": "https://user:SECRET-PASS@proxy.example", "ANTHROPIC_API_KEY": "sk-SECRET-KEY"]
    _ = sendHook(pane: other.id, hook("SessionStart", session: "8e1f0c2a-0000-4000-8000-0000000abc12", #""source":"startup""#),
                 from: .init(pid: fake.processIdentifier, pgid: other.surface.foregroundPID,
                             environment: secrets.merging(["CLAUDE_CONFIG_DIR": "/tmp/lmux test claude",
                                                           "CLAUDE_CONFIG_DIR_X": "no"]) { $1 }))
    await sleepMs(200)
    let expectedResume = "\(fakeClaude.path) --model opus --add-dir /tmp/a '/tmp/b c' --permission-mode plan --resume 8e1f0c2a-0000-4000-8000-0000000abc12"
    r.check("SessionStart captures the resume command (flags, no prompt) and the env apart from it",
            other.resumeCommand == expectedResume && other.resumeEnvironment == ["CLAUDE_CONFIG_DIR": "/tmp/lmux test claude"],
            "\(other.resumeCommand ?? "nil") \(other.resumeEnvironment)")
    r.check("credential-like variables are never captured", other.claudeEnvironment.keys.allSatisfy { !secrets.keys.contains($0) })
    fake.terminate()
    r.check("SessionEnd forgets the session", p1.claudeSessionID == nil && (p2 === other || p2.claudeSessionID == nil),
            "\(p1.claudeSessionID ?? "nil") \(p2.claudeSessionID ?? "nil")")
    c.saveNow()
    let saved = try? JSONDecoder().decode(LayoutFile.self, from: Data(contentsOf: paths.layoutFile))
    r.check("layout.json written to the state dir", saved != nil, paths.layoutFile.path)
    if let saved {
        r.check("all workspaces saved", saved.workspaces.count == c.model.workspaces.count)
        let s2 = saved.workspaces.first { $0.id == ws2.id }
        r.check("split tree saved", s2?.root.axis == .horizontal && s2?.root.children?.count == 2)
        r.check("custom title and accent saved", s2?.customTitle == "payments refactor" && s2?.accent == ws2.accent)
        func panes(_ n: LayoutFile.NodeState) -> [LayoutFile.PaneState] {
            (n.pane.map { [$0] } ?? []) + (n.children ?? []).flatMap(panes)
        }
        let savedPane: LayoutFile.PaneState? = panes(s2!.root).first { $0.id == other.id }
        let wantEnv: [String: String] = ["CLAUDE_CONFIG_DIR": "/tmp/lmux test claude"]
        r.check("claude session saved for its pane, with its resume command",
                savedPane?.claudeSession == "8e1f0c2a-0000-4000-8000-0000000abc12" && savedPane?.resumeCommand == expectedResume
                && savedPane?.resumeEnvironment == wantEnv)
        let layoutBytes = (try? String(contentsOf: paths.layoutFile, encoding: .utf8)) ?? ""
        r.check("…and no credential ever reaches layout.json", !layoutBytes.contains("SECRET") && !layoutBytes.isEmpty)
        let lmode = (try? FileManager.default.attributesOfItem(atPath: paths.layoutFile.path)[.posixPermissions] as? NSNumber)?.intValue
        r.check("layout.json is private (0600)", lmode == 0o600, String(lmode ?? -1, radix: 8))
        r.check("cwd saved", saved.workspaces.flatMap { panes($0.root) }.contains { $0.cwd == pCli.cwd })
        // Hand the expectations to the --restore run.
        let exp: [String: Any] = ["layout": String(decoding: try! JSONEncoder().encode(saved), as: UTF8.self),
                                  "claudePane": other.id, "session": "8e1f0c2a-0000-4000-8000-0000000abc12", "resume": expectedResume]
        try? JSONSerialization.data(withJSONObject: exp)
            .write(to: URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("expect.json"))
    }
    let mtime0 = (try? FileManager.default.attributesOfItem(atPath: paths.layoutFile.path)[.modificationDate]) as? Date
    await sleepMs(1100)
    c.newWorkspace()
    await sleepMs(300)
    let mtime1 = (try? FileManager.default.attributesOfItem(atPath: paths.layoutFile.path)[.modificationDate]) as? Date
    r.check("autosave is debounced (not written immediately)", mtime1 == mtime0)
    await sleepMs(1200)
    let mtime2 = (try? FileManager.default.attributesOfItem(atPath: paths.layoutFile.path)[.modificationDate]) as? Date
    r.check("…and written ~1s after the change", mtime2 != nil && mtime2 != mtime0)
    c.closeWorkspace(c.model.selected!)
    c.saveNow()
    // An unreadable layout.json is kept aside (layout.json.bad-<time>, private) before anything
    // is saved over it; the model is left alone.
    let goodLayout = try? Data(contentsOf: paths.layoutFile)
    let corrupt = Data("{\"version\":1,\"workspaces\":[{\"id\":\"x\",\"root\":".utf8)
    try? corrupt.write(to: paths.layoutFile)
    let wsCount = c.model.workspaces.count
    let restoredCorrupt = c.restoreLayout()
    let bads = ((try? FileManager.default.contentsOfDirectory(at: paths.stateDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.lastPathComponent.hasPrefix("layout.json.bad-") }
    r.check("corrupt layout.json: not restored, kept as layout.json.bad-<time> (0600), workspaces untouched",
            !restoredCorrupt && c.model.workspaces.count == wsCount && bads.count == 1
                && (try? Data(contentsOf: bads[0])) == corrupt && ((try? FileManager.default.attributesOfItem(atPath: bads[0].path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600,
            bads.map(\.lastPathComponent).joined(separator: ","))
    for b in bads { try? FileManager.default.removeItem(at: b) }
    if let goodLayout { try? goodLayout.write(to: paths.layoutFile); chmod(paths.layoutFile.path, 0o600) }
    // Keys missing from an older / newer file fall back to their defaults instead of failing the load.
    let sparse = #"{"workspaces":[{"id":"w1","root":{"pane":{"id":"p1"}},"futureKey":true}],"futureTop":[1]}"#
    let sparseFile = try? JSONDecoder().decode(LayoutFile.self, from: Data(sparse.utf8))
    r.check("layout.json without version / sidebar / accent keys (and with unknown ones) still loads",
            sparseFile?.workspaces.first?.root.pane?.id == "p1" && sparseFile?.sidebarVisible == true && sparseFile?.version == 1
                && sparseFile?.workspaces.first?.accent == 0)
    r.check("…and without zoomedPane (older lmux) loads unzoomed", sparseFile != nil && sparseFile?.workspaces.first?.zoomedPane == nil)
    // The split zoom round-trips through layout.json under its own key (the zoomed pane's id).
    var zoomFile = LayoutFile()
    zoomFile.workspaces = [.init(id: "w1", customTitle: nil, accent: 0, focusedPane: "p2", zoomedPane: "p2",
                                 root: .init(axis: .horizontal, ratio: 0.5,
                                             children: [.init(pane: .init(id: "p1")), .init(pane: .init(id: "p2"))]))]
    let zoomData = try? JSONEncoder().encode(zoomFile)
    let zoomJSON = zoomData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let zoomKey = ((zoomJSON?["workspaces"] as? [[String: Any]])?.first?["zoomedPane"]) as? String
    r.check("zoomedPane encodes as the pane's id and decodes back the same",
            zoomKey == "p2" && zoomData.flatMap { try? JSONDecoder().decode(LayoutFile.self, from: $0) } == zoomFile)
    var unzoomedFile = zoomFile
    unzoomedFile.workspaces[0].zoomedPane = nil
    let unzoomedJSON = (try? JSONEncoder().encode(unzoomedFile)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    r.check("…an unzoomed workspace writes no zoomedPane key", !unzoomedJSON.isEmpty && !unzoomedJSON.contains("zoomedPane"))
    // A done pane's end time, reply line and (unattended) wait start, in Unix seconds, round-trip;
    // absent keys (not done, an older lmux) decode as none.
    var waitFile = LayoutFile()
    waitFile.workspaces = [.init(id: "w1", customTitle: nil, accent: 0, focusedPane: nil,
                                 root: .init(pane: .init(id: "p1", claudeSession: "s", doneAt: 1_790_000_000.25, alertDetail: "done",
                                                        attentionSince: 1_790_000_000.5)))]
    let waitData = try? JSONEncoder().encode(waitFile)
    let waitJSON = waitData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let waitPane = (((waitJSON?["workspaces"] as? [[String: Any]])?.first?["root"] as? [String: Any])?["pane"]) as? [String: Any]
    r.check("doneAt / attentionSince encode as Unix seconds (with alertDetail) and decode back the same",
            waitPane?["doneAt"] as? Double == 1_790_000_000.25 && waitPane?["attentionSince"] as? Double == 1_790_000_000.5
                && waitPane?["alertDetail"] as? String == "done"
                && waitData.flatMap { try? JSONDecoder().decode(LayoutFile.self, from: $0) } == waitFile)
    let quietJSON = (try? JSONEncoder().encode(unzoomedFile)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    r.check("…a pane that isn't done writes none of them, and an older layout loads with none",
            !quietJSON.isEmpty && !quietJSON.contains("doneAt") && !quietJSON.contains("attentionSince") && !quietJSON.contains("alertDetail")
                && sparseFile?.workspaces.first?.root.pane.map { $0.doneAt == nil && $0.attentionSince == nil } == true)
    // An 8-day-old backup of the old forget: the next launch (--restore) must prune it.
    let stale = c.forgottenDirectory.appendingPathComponent("stale-backup.jsonl")
    try? FileManager.default.createDirectory(at: c.forgottenDirectory, withIntermediateDirectories: true)
    try? Data("forgotten text".utf8).write(to: stale)
    // 0600 like the backups lmux writes itself, so the restore run's permission scan doesn't depend on
    // whether the prune already ran.
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400), .posixPermissions: 0o600],
                                           ofItemAtPath: stale.path)
    // Rewrite exactly what --restore will check.
    if let data = try? Data(contentsOf: paths.layoutFile), let f = try? JSONDecoder().decode(LayoutFile.self, from: data) {
        let exp: [String: Any] = ["layout": String(decoding: try! JSONEncoder().encode(f), as: UTF8.self),
                                  "claudePane": other.id, "session": "8e1f0c2a-0000-4000-8000-0000000abc12", "resume": expectedResume]
        try? JSONSerialization.data(withJSONObject: exp)
            .write(to: URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("expect.json"))
    }
    return finish(r, c)
}

@MainActor
func finish(_ r: Report, _ c: LmuxController) -> Int32 {
    c.shutdown()
    print("INFO  [harness] \(MouseQueue.environment); mouse events not returned by the queue: \(MouseQueue.misses) (delivered directly)")
    print("\nRESULT: \(r.failed == 0 ? "PASS" : "FAIL") (\(r.passed)/\(r.passed + r.failed) checks passed)")
    return r.failed == 0 ? 0 : 1
}

// MARK: - Restore run

@MainActor
func runRestore() async -> Int32 {
    let r = Report()
    r.section = "restore"
    let expURL = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("expect.json")
    guard let d = try? Data(contentsOf: expURL),
          let exp = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let layoutJSON = exp["layout"] as? String,
          let expected = try? JSONDecoder().decode(LayoutFile.self, from: Data(layoutJSON.utf8)),
          let claudePane = exp["claudePane"] as? String, let session = exp["session"] as? String,
          let resume = exp["resume"] as? String else {
        print("FAIL  [restore] no expectations from the main run")
        return 1
    }
    let c = makeController()
    let got = c.snapshotLayout()
    r.check("same workspaces, order, titles and accents",
            got.workspaces.map { [$0.id, $0.customTitle ?? "", "\($0.accent)"] }
            == expected.workspaces.map { [$0.id, $0.customTitle ?? "", "\($0.accent)"] })
    func shape(_ n: LayoutFile.NodeState) -> String {
        if let p = n.pane { return "P(\(p.id),\(p.cwd ?? "-"))" }
        return "S(\(n.axis?.rawValue ?? "?"),\(String(format: "%.2f", n.ratio ?? 0)),\((n.children ?? []).map(shape).joined(separator: ",")))"
    }
    r.check("same split trees, pane ids, cwds and ratios",
            got.workspaces.map { shape($0.root) } == expected.workspaces.map { shape($0.root) },
            got.workspaces.map { shape($0.root) }.joined(separator: " | "))
    r.check("selected workspace restored", got.selected == expected.selected)
    r.check("focused panes restored", got.workspaces.map(\.focusedPane) == expected.workspaces.map(\.focusedPane))
    let resumed = await sinks.wait(claudePane, contains: resume)
    let typed = sinks.text(claudePane)
    r.check("Claude pane restored with its own command: same flags, `--resume <id>`",
            resumed && resume.hasSuffix("--resume \(session)") && resume.contains("--model opus")
            && resume.contains("--add-dir /tmp/a '/tmp/b c'") && !resume.contains("do the thing"), typed)
    r.check("…its env goes to the pane's shell environment, never typed (nothing in shell history)",
            !typed.contains("CLAUDE_CONFIG_DIR") && !typed.contains("SECRET"), typed)
    let shellEnv = (try? String(contentsOf: sinks.dir.appendingPathComponent("\(claudePane).env"), encoding: .utf8)) ?? ""
    r.check("…the restored shell has CLAUDE_CONFIG_DIR of that session, and no credential",
            shellEnv.contains("CLAUDE_CONFIG_DIR=/tmp/lmux test claude\n") && !shellEnv.contains("SECRET"))
    // Every state file lmux writes is private.
    var loose: [String] = []
    for sub in ["layout.json", "sessions.db", "archive", "forgotten", "hooks-pristine", "paste"] {
        let u = paths.stateDir.appendingPathComponent(sub)
        let subs: [String] = (FileManager.default.enumerator(atPath: u.path)?.allObjects as? [String]) ?? []
        let items: [String] = [u.path] + subs.map { (u.path as NSString).appendingPathComponent($0) }
        for i in items where FileManager.default.fileExists(atPath: i) {
            let m = ((try? FileManager.default.attributesOfItem(atPath: i)[.posixPermissions] as? NSNumber)?.intValue) ?? 0
            if m & 0o077 != 0 { loose.append("\((i as NSString).lastPathComponent) \(String(m, radix: 8))") }
        }
    }
    r.check("state files are 0600 and dirs 0700", loose.isEmpty, loose.joined(separator: ", "))
    let plain = c.model.workspaces.flatMap(\.panes).filter { $0.id != claudePane }
    var typedClaude: [String] = []
    for p in plain { _ = await sinks.waitReady(p.id); if sinks.text(p.id).contains("claude") { typedClaude.append("\(p.id.prefix(8)): \(sinks.text(p.id))") } }
    r.check("other panes start a plain shell", typedClaude.isEmpty, typedClaude.joined(separator: " | "))
    r.check("focus is in the selected workspace's pane", firstResponderPane(c) === c.model.selected?.focusedPane)
    let stale = c.forgottenDirectory.appendingPathComponent("stale-backup.jsonl")
    r.check("launch prunes old forget backups older than 7 days",
            await waitFor(3) { !FileManager.default.fileExists(atPath: stale.path) })
    return finish(r, c)
}

// MARK: - Screenshots

/// The pane's pixels in a window snapshot (RGBA words, row by row).
@MainActor func panePixels(_ c: LmuxController, _ p: Pane) -> [UInt32]? {
    guard let img = c.snapshotImage(scale: 2) else { return nil }
    let r = p.surface.convert(p.surface.bounds, to: nil)
    let crop = CGRect(x: r.minX * 2, y: CGFloat(img.height) - r.maxY * 2, width: r.width * 2, height: r.height * 2).integral
    guard let cg = img.cropping(to: crop) else { return nil }
    var px = [UInt32](repeating: 0, count: cg.width * cg.height)
    let ok = px.withUnsafeMutableBytes { buf in
        CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            .map { $0.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)); return true } ?? false
    }
    return ok ? px : nil
}

/// The shell printed something after `Last login` (its prompt) in every visible pane.
@MainActor
func waitForPrompts(_ c: LmuxController, timeout: Double = 15) async -> Bool {
    await waitFor(timeout) {
        (c.model.selected?.panes ?? []).allSatisfy { p in
            let lines = p.surface.readText().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lines.contains { !$0.hasPrefix("Last login") }
        }
    }
}

@MainActor
func shoot(_ c: LmuxController, _ dir: URL, _ name: String, prepare: (() async -> Void)? = nil) async {
    for (appearance, mode) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
        NSApp.appearance = NSAppearance(named: appearance)
        await sleepMs(1200)  // theme switch round-trips through libghostty
        await prepare?()
        c.root.updateHeader()
        c.window.contentView?.needsDisplay = true
        await sleepMs(300)
        let out = dir.appendingPathComponent("\(name)-\(mode).png")
        do { try c.snapshotPNG(to: out); print("wrote \(out.path)") } catch { print("snapshot failed: \(error)") }
    }
}

@MainActor
func runScreenshots(_ dir: URL) async -> Int32 {
    let c = makeController()
    let ws = c.model.selected!
    ws.customTitle = "payments refactor"
    let main = ws.panes[0]
    let side = c.split(main, .right)!
    c.focus(main)
    func feed(_ p: Pane, _ payloads: [String]) {
        for s in payloads {
            let obj = try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any]
            c.handleHook(try! HookEvent(paneID: p.id, payload: obj))
        }
    }
    feed(side, [hook("UserPromptSubmit"), hook("PermissionRequest", #""tool_name":"Bash""#)])
    feed(main, [hook("UserPromptSubmit"), hook("PreToolUse", #""tool_name":"Read""#)])
    let fakeRows: [(String, [String])] = [
        ("README 다듬기", [hook("UserPromptSubmit"), hook("PreToolUse", #""tool_name":"AskUserQuestion""#)]),
        ("flaky IME test", [hook("UserPromptSubmit"), hook("PreToolUse", #""tool_name":"Bash""#)]),
        ("bench script", [hook("UserPromptSubmit"), hook("Stop", #""last_assistant_message":"RSS 사용량 표 만들었어요""#)]),
        ("release 0.1", [hook("UserPromptSubmit"), hook("StopFailure", #""error_type":"notarytool exited 65""#)]),
    ]
    for (title, events) in fakeRows {
        let w = c.newWorkspace(cwd: NSHomeDirectory(), select: false)
        w.customTitle = title
        feed(w.panes[0], events)
    }
    c.select(ws, focusing: main)
    let prompted = await waitForPrompts(c)
    print(prompted ? "shell prompts are up" : "warning: shell prompt did not appear within 15s")
    await shoot(c, dir, "p1")

    // ---- P2: a Claude-like split (mockup), History with a Korean search, overlays.
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("fixtures", isDirectory: true)
    try? FileManager.default.createDirectory(at: fx, withIntermediateDirectories: true)
    let work = fx.appendingPathComponent("payments", isDirectory: true)
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    writeHistoryCorpus(root: c.history.projectsRoot, cwd: work.path)
    let s1 = fx.appendingPathComponent("screen-1.jsonl").path
    let s2 = fx.appendingPathComponent("screen-2.jsonl").path
    try? fixtureJSONL(session: "screen-1", cwd: work.path, turns: ScreenFixture.turns).write(toFile: s1, atomically: true, encoding: .utf8)
    try? fixtureJSONL(session: "screen-2", cwd: work.path, turns: [FixtureTurn(prompt: ScreenFixture.prompt3, reply: nil)])
        .write(toFile: s2, atomically: true, encoding: .utf8)
    let left = ScreenFixture.script(ScreenFixture.screen, input: "머지 전에 CHANGELOG에도 한 줄 남겨줘", dir: fx, name: "left")
    let right = ScreenFixture.script(ScreenFixture.screen2, input: nil, dir: fx, name: "right")
    let pw = c.newWorkspace(cwd: work.path, program: left)
    pw.customTitle = "payments refactor"
    let pl = pw.panes[0]
    let pr = c.split(pl, .right, program: right)!
    c.closeWorkspace(ws)
    c.focus(pl)
    hookEvent(c, pl, "SessionStart", session: "screen-1", transcript: s1, ["source": "startup"])
    hookEvent(c, pr, "SessionStart", session: "screen-2", transcript: s2, ["source": "startup"])
    hookEvent(c, pr, "UserPromptSubmit", session: "screen-2", ["prompt": ScreenFixture.prompt3])
    hookEvent(c, pr, "PermissionRequest", session: "screen-2", ["tool_name": "Bash"])
    hookEvent(c, pl, "UserPromptSubmit", session: "screen-1", ["prompt": ScreenFixture.prompt2])
    hookEvent(c, pl, "PreToolUse", session: "screen-1", ["tool_name": "Bash"])
    pl.titleState = TitleState(title: "refund validation")
    pr.titleState = TitleState(title: "refunds migration")
    c.titlesChanged(pl); c.titlesChanged(pr)
    c.select(pw, focusing: pl)
    _ = await waitFor(5) { rows(pl).contains { $0.contains("accept edits") } && rows(pr).contains { $0.contains("1. Yes") } }
    await c.history.refresh()
    await c.history.search("환불")
    _ = await c.loadTurns(pl)
    func hoverPrompt() async {
        pl.hover.readAt = .distantPast
        let m = c.screenMap(pl, maxAge: 0)
        if let h = m.map?.promptHeads().first {
            c.paneMouseMoved(pl, NSPoint(x: 300, y: pl.surface.bounds.height - (m.rows[h.row].top + m.rowHeight / 2)))
        }
        await sleepMs(100)
        c.refreshInputLabel(pl)
    }
    await shoot(c, dir, "p2-history-hover", prepare: hoverPrompt)

    c.hideHoverActions(pl)

    func toast() async {
        let m = c.screenMap(pl, maxAge: 0)
        if let row = m.map?.roles.firstIndex(of: .reply(turn: 1)) {
            c.paneMouseMoved(pl, NSPoint(x: 300, y: pl.surface.bounds.height - (m.rows[row].top + m.rowHeight / 2)))
        }
        c.refreshInputLabel(pl)
        c.showUndoToast(pr, prompt: ScreenFixture.prompt3)
        await sleepMs(1000)
    }
    await shoot(c, dir, "p2-toast-copy", prepare: toast)
    c.clearPendingUndo()
    await shootPolish(c, dir, fx: fx.appendingPathComponent("polish", isDirectory: true))
    c.shutdown()
    return 0
}

/// `--polish-shots D`: only the polish reference scene (POLISH.md), offscreen.
@MainActor
func runPolishShots(_ dir: URL) async -> Int32 {
    let c = makeController()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("polish", isDirectory: true)
    await shootPolish(c, dir, fx: fx)
    c.shutdown()
    return 0
}

/// A minimal NSDraggingInfo for drop tests (no drag session needed).
final class FakeDrag: NSObject, NSDraggingInfo {
    let pb: NSPasteboard
    weak var win: NSWindow?
    init(pasteboard: NSPasteboard, window: NSWindow) { pb = pasteboard; win = window }
    var draggingDestinationWindow: NSWindow? { win }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pb }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
