import AppKit
import LmuxTokens
import SwiftUI
@testable import LmuxUI

// `lmux-apptest --bell`: the bell's notification list, headless (its content view sits in an
// offscreen window that is never ordered in; no popover is shown).

@MainActor
func runBell() async -> Int32 {
    let r = Report()
    let c = makeController()
    r.section = "bell"
    let home = c.model.selected!
    c.bellClicked(modifiers: [])
    guard let view = c.notificationsView else { r.check("the list exists", false); return finish(r, c) }
    view.layoutSubtreeIfNeeded()
    r.check("a click opens the list", c.notificationsPanel.isOpen)
    r.check("…empty: a calm one-liner, no Mark all read", c.model.notifications.isEmpty && c.model.unreadNotifications == 0
            && NotificationsView.emptyText == "No notifications yet. You’ll see them here when an agent needs you.")
    r.check("…320pt wide", abs(view.fittingSize.width - 320) < 0.5, "\(view.fittingSize)")
    r.check("…headless: on no display, never key, app never active", view.window.map { w in
        !NSScreen.screens.contains { $0.frame.intersects(w.frame) } && !w.isKeyWindow } ?? false && !NSApp.isActive)
    c.bellClicked(modifiers: [])
    r.check("a second click closes it", !c.notificationsPanel.isOpen)

    // Three agents need attention in other workspaces, in this order.
    var made: [Workspace] = []
    for t in ["auth fix", "build", "docs"] {
        let w = c.newWorkspace(select: false)
        w.customTitle = t
        made.append(w)
        _ = await sinks.waitReady(w.panes[0].id)
    }
    hookEvent(c, made[0].panes[0], "SessionStart", session: "bell-1")
    hookEvent(c, made[0].panes[0], "UserPromptSubmit", session: "bell-1", ["prompt": "x"])
    hookEvent(c, made[0].panes[0], "Notification", session: "bell-1", ["message": "Allow pnpm db:migrate?", "notification_type": "permission_prompt"])
    await sleepMs(30)
    hookEvent(c, made[1].panes[0], "SessionStart", session: "bell-2")
    hookEvent(c, made[1].panes[0], "UserPromptSubmit", session: "bell-2", ["prompt": "x"])
    hookEvent(c, made[1].panes[0], "StopFailure", session: "bell-2", ["error_type": "xcodebuild exited 65"])
    await sleepMs(30)
    hookEvent(c, made[2].panes[0], "SessionStart", session: "bell-3")
    hookEvent(c, made[2].panes[0], "UserPromptSubmit", session: "bell-3", ["prompt": "x"])
    hookEvent(c, made[2].panes[0], "Stop", session: "bell-3", ["last_assistant_message": "README updated"])
    _ = await waitFor(2) { c.model.notifications.count == 3 }
    let titles = c.model.notifications.map(\.title)
    r.check("alerts are listed newest first", titles == ["docs", "build", "auth fix"], "\(titles)")
    r.check("…with their message and kind", c.model.notifications.map(\.message) == ["README updated", "xcodebuild exited 65", "Allow pnpm db:migrate?"]
            && c.model.notifications.map(\.kind) == ["done", "failed", "needsInput"], "\(c.model.notifications.map(\.message))")
    r.check("…all unread (badge 3)", c.model.unreadNotifications == 3 && c.model.totalUnread == 3)
    r.check("relative times: now, 3m, 2h, 4d", NotificationRow.age(Date()) == "now"
            && NotificationRow.age(Date().addingTimeInterval(-185)) == "3m" && NotificationRow.age(Date().addingTimeInterval(-7300)) == "2h"
            && NotificationRow.age(Date().addingTimeInterval(-4 * 86400 - 10)) == "4d")

    // A row click jumps there, marks it read, closes.
    c.bellClicked(modifiers: [])
    view.layoutSubtreeIfNeeded()
    let H = NotificationsView.headerHeight + 0.5 + 4
    func rowPoint(_ i: Int) -> NSPoint {
        let y = H + CGFloat(i) * NotificationsView.rowHeight + NotificationsView.rowHeight / 2
        return NSPoint(x: 160, y: view.isFlipped ? y : view.bounds.height - y)
    }
    r.check("open with rows: as tall as 3 rows", abs(view.fittingSize.height - (H + 3 * NotificationsView.rowHeight + 4)) < 2, "\(view.fittingSize)")
    await click(view, at: rowPoint(1))
    _ = await waitFor(2) { !c.notificationsPanel.isOpen }
    r.check("clicking “build” jumps to its pane", c.model.selected === made[1] && c.model.selected?.focusedPane === made[1].panes[0])
    r.check("…marks it read (badge 2) and closes the list", !c.notificationsPanel.isOpen && c.model.notifications[1].read
            && made[1].panes[0].unread == 0 && c.model.unreadNotifications == 2 && c.model.totalUnread == 2)

    // ↑↓ and Enter.
    c.bellClicked(modifiers: [])
    func key(_ code: UInt16) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                 isARepeat: false, keyCode: code)!
        view.keyDown(with: e)
    }
    r.check("opens with the newest row highlighted", c.notificationsPanel.highlighted == 0)
    key(125); key(125); key(125)
    r.check("↓ moves down (and stops at the last row)", c.notificationsPanel.highlighted == 2)
    key(126)
    r.check("↑ moves up", c.notificationsPanel.highlighted == 1)
    key(126); key(126)
    r.check("…stops at the first", c.notificationsPanel.highlighted == 0)
    key(125); key(125); key(36)
    r.check("Enter opens the highlighted row (“auth fix”)", c.model.selected === made[0] && !c.notificationsPanel.isOpen
            && c.model.notifications[2].read)
    c.bellClicked(modifiers: [])
    key(53)
    r.check("Esc closes it", !c.notificationsPanel.isOpen)

    // Mark all read.
    c.select(home)
    c.bellClicked(modifiers: [])
    r.check("Mark all read is offered while something is unread", c.model.unreadNotifications == 1)
    c.markAllNotificationsRead()
    r.check("Mark all read clears every row and the bell's badge", c.model.unreadNotifications == 0 && c.model.totalUnread == 0
            && made.allSatisfy { $0.unread == 0 })
    c.closeNotifications()

    // ⌥-click: the old behavior, jump straight to the latest unread.
    hookEvent(c, made[1].panes[0], "UserPromptSubmit", session: "bell-2", ["prompt": "y"])
    hookEvent(c, made[1].panes[0], "Stop", session: "bell-2", ["last_assistant_message": "fixed"])
    _ = await waitFor(2) { made[1].panes[0].unread > 0 }
    c.bellClicked(modifiers: .option)
    r.check("⌥-click jumps to the latest unread without opening the list", c.model.selected === made[1] && !c.notificationsPanel.isOpen)

    // Bounded: the last 50 notifications (and posts).
    for i in 0..<60 {
        c.model.recordNotification(NotificationEntry(paneID: nil, workspaceID: nil, title: "t\(i)", message: "m\(i)", kind: "cli", read: true))
    }
    r.check("the list keeps the last 50, newest first", c.model.notifications.count == 50 && c.model.notifications.first?.title == "t59"
            && c.model.notifications.last?.title == "t10")
    let posted0 = c.notifier.postedCount
    for i in 0..<60 { c.notifier.post(title: "p", body: "\(i)", paneID: nil, kind: "cli") }
    r.check("Notifier keeps the last 50 posts (the count goes on)", c.notifier.posted.count == 50 && c.notifier.postedCount == posted0 + 60
            && c.notifier.posted.last?.body == "59")
    return finish(r, c)
}

/// `--bell-shots D`: the list with a few rows and the empty state, light and dark, rendered
/// offscreen (the popover's material is approximated by the elevated background).
@MainActor
func runBellShots(_ dir: URL) async -> Int32 {
    let c = makeController()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func shot(_ name: String) async {
        for dark in [false, true] {
            let v = NSHostingView(rootView: NotificationsView(model: c.model, panel: c.notificationsPanel, controller: c)
                .background(LmuxTokens.Colors.elevatedBackground.color))
            let holder = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            holder.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            holder.contentView = v
            v.layoutSubtreeIfNeeded()
            holder.setContentSize(v.fittingSize)
            v.layoutSubtreeIfNeeded()
            await sleepMs(300)
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
    }
    await shot("bell-empty")
    var ws: [Workspace] = []
    for t in ["auth fix", "build", "docs", "payments refactor"] {
        let w = c.newWorkspace(select: false)
        w.customTitle = t
        ws.append(w)
    }
    let now = Date()
    let rows: [(Int, String, String, TimeInterval, Bool)] = [
        (3, "Allow pnpm db:migrate?", "needsInput", 40, false),
        (1, "xcodebuild exited 65", "failed", 3 * 60, false),
        (2, "README updated with the new install steps and a screenshot", "done", 26 * 60, true),
        (0, "Which token store should the refresh flow use?", "needsInput", 2 * 3600, true),
        (2, "Fixed the broken links", "done", 26 * 3600, true),
    ]
    for (i, msg, kind, ago, read) in rows.reversed() {
        c.model.recordNotification(NotificationEntry(paneID: ws[i].panes[0].id, workspaceID: ws[i].id, title: ws[i].title,
                                                     message: msg, kind: kind, date: now.addingTimeInterval(-ago), read: read))
    }
    c.notificationsPanel.highlighted = 0
    await shot("bell-list")
    c.shutdown()
    return 0
}
