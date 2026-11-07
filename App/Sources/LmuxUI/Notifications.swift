import AppKit
import LmuxTokens
import Observation
import SwiftUI

private typealias T = LmuxTokens

// The bell (POLISH.md 2): a click opens a popover with the recent notifications, newest first
// (the last 50 alerts and CLI notifies, not persisted). A row jumps to its pane and marks it
// read; ⌥-click jumps to the latest unread directly (⇧⌘U). Headless, the popover is never shown:
// its content view lives in an offscreen window that is never ordered in.

@MainActor @Observable
public final class NotificationsPanel {
    /// Row the keyboard points at (↑↓, Enter).
    public var highlighted = 0
    public internal(set) var isOpen = false
}

extension LmuxController {
    /// The bell: ⌥-click jumps to the latest unread, a click toggles the list.
    public func bellClicked(modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.option) { jumpToLatestUnread(); return }
        if notificationsPanel.isOpen { closeNotifications() } else { showNotifications() }
    }

    public func showNotifications() {
        notificationsPanel.highlighted = 0
        let view = notificationsView ?? NotificationsHostingView(
            rootView: NotificationsView(model: model, panel: notificationsPanel, controller: self))
        view.controller = self
        notificationsView = view
        notificationsPanel.isOpen = true
        if headless {
            // Like the headless main window: a borderless LmuxWindow ordered in off screen
            // (-10000, -10000; on no display, never key), so clicks route as in the popover.
            let holder = view.window ?? {
                let w = LmuxWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 100),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
                w.controller = self
                w.isReleasedWhenClosed = false
                w.contentView = view
                return w
            }()
            view.layoutSubtreeIfNeeded()
            holder.setContentSize(view.fittingSize)
            holder.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            holder.orderFrontRegardless()
            return
        }
        let pop = notificationsPopover ?? NSPopover()
        pop.behavior = .transient  // Esc or a click outside closes it
        pop.animates = !T.Motion.reduceMotion
        if pop.contentViewController == nil {
            let vc = NSViewController()
            vc.view = view
            pop.contentViewController = vc
            pop.delegate = self
        }
        notificationsPopover = pop
        // Size the popover to its SwiftUI content before showing it. Otherwise AppKit places it for
        // its default (~320pt tall) content, then the hosting view shrinks it to the real height
        // keeping the bottom edge fixed: the popover hangs far below the bell, detached from it.
        view.layoutSubtreeIfNeeded()
        pop.contentSize = view.fittingSize
        let bs = T.Layout.titlebarButtonSize
        let bell = NSRect(x: bs + 2, y: 0, width: bs, height: root.cluster.bounds.height)
        pop.show(relativeTo: bell, of: root.cluster, preferredEdge: root.cluster.isFlipped ? .maxY : .minY)
        view.window?.makeFirstResponder(view)
    }

    /// Rows came in while the list is open (its height follows the count): resize the popover (headless, its
    /// holder) to the content. Left to the hosting view, it grows from its bottom edge and drifts off the bell.
    func notificationsCountChanged() {
        guard notificationsPanel.isOpen, let view = notificationsView else { return }
        notificationsResizes += 1
        view.layoutSubtreeIfNeeded()
        if headless { view.window?.setContentSize(view.fittingSize) } else { notificationsPopover?.contentSize = view.fittingSize }
    }

    public func closeNotifications() {
        notificationsPanel.isOpen = false
        notificationsPopover?.performClose(nil)
        if headless { notificationsView?.window?.orderOut(nil); return }
        focusCurrent()
    }

    /// A row: jump to its pane (or workspace), mark it read, close.
    public func openNotification(_ e: NotificationEntry) {
        closeNotifications()
        if let id = e.paneID, let p = model.workspaces.flatMap(\.panes).first(where: { $0.id == id }) {
            focus(p)
            p.unread = 0
        } else if let w = model.workspaces.first(where: { $0.id == e.workspaceID }) {
            select(w)
        }
        model.markNotificationsRead(id: e.id)
        refreshPaneChrome()
    }

    public func markAllNotificationsRead() {
        for p in model.workspaces.flatMap(\.panes) where p.unread > 0 { p.unread = 0 }
        model.markAllNotificationsRead()
        refreshPaneChrome()
    }

    /// ↑↓ move, Enter opens, Esc closes (the popover's content has the keyboard).
    func notificationsKey(_ event: NSEvent) -> Bool {
        let n = model.notifications.count
        switch event.keyCode {
        case 125: if n > 0 { notificationsPanel.highlighted = min(n - 1, notificationsPanel.highlighted + 1) }
        case 126: notificationsPanel.highlighted = max(0, notificationsPanel.highlighted - 1)
        case 36, 76: if notificationsPanel.highlighted < n { openNotification(model.notifications[notificationsPanel.highlighted]) }
        case 53: closeNotifications()
        default: return false
        }
        return true
    }
}

extension LmuxController: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        notificationsPanel.isOpen = false
    }
}

/// The popover's content: takes the keyboard for ↑↓ / Enter / Esc.
public final class NotificationsHostingView: NSHostingView<NotificationsView> {
    weak var controller: LmuxController?
    public override var acceptsFirstResponder: Bool { true }
    public override func keyDown(with event: NSEvent) {
        if controller?.notificationsKey(event) == true { return }
        super.keyDown(with: event)
    }
    public override func cancelOperation(_ sender: Any?) { controller?.closeNotifications() }
}

public struct NotificationsView: View {
    let model: AppModel
    let panel: NotificationsPanel
    let controller: LmuxController?
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 36
    static let maxRows = 8
    static let emptyText = "No notifications yet. You’ll see them here when an agent needs you."

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(T.Colors.textPrimary.color)
                Spacer()
                if model.unreadNotifications > 0 {
                    Button("Mark all read") { controller?.markAllNotificationsRead() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(T.Colors.accent.color)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight)
            Rectangle().fill(T.Colors.separator.color).frame(height: 0.5)
            if model.notifications.isEmpty {
                Text(Self.emptyText)
                    .font(T.Typography.rowSubtitle.font)
                    .foregroundStyle(T.Colors.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.notifications.enumerated()), id: \.element.id) { i, e in
                                NotificationRow(entry: e, workspace: model.workspaces.first { $0.id == e.workspaceID },
                                                highlighted: i == panel.highlighted)
                                    .id(e.id)
                                    .onTapGesture { controller?.openNotification(e) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: CGFloat(min(model.notifications.count, Self.maxRows)) * Self.rowHeight + 8)
                    .onChange(of: panel.highlighted) { _, i in
                        if model.notifications.indices.contains(i) { proxy.scrollTo(model.notifications[i].id) }
                    }
                }
            }
        }
        .frame(width: Self.width)
        .onChange(of: model.notifications.count) { DispatchQueue.main.async { controller?.notificationsCountChanged() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }
}

struct NotificationRow: View {
    let entry: NotificationEntry
    let workspace: Workspace?
    let highlighted: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(entry.read ? Color.clear : T.Colors.accent.color)
                .frame(width: 6, height: 6)
            AccentChip(accent: workspace?.accent ?? 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(workspace?.title ?? entry.title)
                        .font(.system(size: 13, weight: entry.read ? .regular : .medium))
                        .foregroundStyle((entry.read ? T.Colors.textSecondary : T.Colors.textPrimary).color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(Self.age(entry.date))
                        .font(T.Typography.rowMeta.font.monospacedDigit())
                        .foregroundStyle(T.Colors.textTertiary.color)
                }
                Text(entry.message)
                    .font(T.Typography.rowSubtitle.font)
                    .foregroundStyle((entry.read ? T.Colors.textTertiary : T.Colors.textSecondary).color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: NotificationsView.rowHeight)
        .background(RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
            .fill(highlighted || hover ? T.Colors.rowHover.color : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(entry.read ? "" : "unread")
    }

    /// "now", "3m", "2h", "4d".
    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
