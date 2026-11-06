import AppKit
import LmuxTokens
import LmuxUI
import Observation
import SwiftUI

private typealias T = LmuxTokens

/// sidebar 最底部的 bar：上面是各個 plugin 的行（PluginHost），最下面是內建的通知行。
/// 通知行常駐顯示最新一則通知（有未讀時優先顯示未讀）和未讀數，點一下會跳到該通知的 pane 並標成已讀。
/// 通知資料來源是 `AppModel.notifications`，也就是鈴鐺清單用的那一份，最多 50 則，不會保存到磁碟。
@MainActor
public enum NotificationBarPlugin {
    static let rowHeight: CGFloat = 29

    /// 上緣分隔線 1pt，加上每個 plugin 一行，再加上通知那一行。
    static func height(pluginRows: Int) -> CGFloat { 1 + rowHeight * CGFloat(pluginRows + 1) }

    /// 在 `controller.start()` 之後呼叫。
    public static func install(on controller: LmuxController) {
        let host = makeHost(controller)
        let view = BarHostingView(rootView: NotificationBar(model: controller.model, controller: controller, host: host))
        // 尺寸與位置由 RootView 決定，比照 RootView 對 sidebarHost 的設定。
        view.sizingOptions = []
        view.safeAreaRegions = []
        followRowCount(host, view, controller, last: -1)
        host?.reloadAll()
    }

    /// plugin 資料夾：`LMUX_PLUGIN_DIR`，否則 `~/.config/lmux/plugins`。
    /// headless（測試、截圖）只在明確指定 `LMUX_PLUGIN_DIR` 時才執行 plugin，比照 main.swift 對 LMUX_STATE_DIR 的規則。
    private static func makeHost(_ controller: LmuxController) -> PluginHost? {
        let custom = ProcessInfo.processInfo.environment["LMUX_PLUGIN_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        if controller.headless, custom == nil { return nil }
        let dir = custom.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/lmux/plugins")
        return PluginHost(dir: dir, logDir: controller.paths.stateDir.appendingPathComponent("plugins"),
                          controlSocket: controller.paths.controlSocket)
    }

    /// plugin 行數變了就更新 bar 的高度（比照 RootView.trackSidebarState 的寫法）。
    private static func followRowCount(_ host: PluginHost?, _ view: NSView, _ controller: LmuxController, last: Int) {
        let count = host?.rows.count ?? 0
        withObservationTracking {
            _ = host?.rows.count
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { followRowCount(host, view, controller, last: count) }
            }
        }
        if count != last { controller.installSidebarAccessory(view, height: height(pluginRows: count)) }
    }
}

/// 比照 LmuxUI 的 SidebarHostingView：視窗不在前景時第一下點擊就有效，且不搶 terminal 的鍵盤焦點。
final class BarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

struct NotificationBar: View {
    let model: AppModel
    let controller: LmuxController
    let host: PluginHost?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(T.Colors.separator.color).frame(height: 1)
            if let host {
                ForEach(host.rows) { row in PluginRow(row: row, host: host) }
            }
            NotificationRowView(model: model, controller: controller, host: host)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// 右鍵選單裡兩行都有的項目。
struct PluginMenuItems: View {
    let host: PluginHost
    var body: some View {
        Button("Reload All Plugins") { host.reloadAll() }
        Button("Reveal Plugin Folder") { host.revealFolder() }
    }
}

/// tone 對應 lmux 現有的狀態色；沒給就用一般文字色。
func toneColor(_ tone: PluginRowContent.Tone?) -> Color {
    switch tone {
    case .done?: return T.Colors.stateDone.color
    case .failed?: return T.Colors.stateFailed.color
    case .needsInput?: return T.Colors.stateNeedsInput.color
    case .accent?: return T.Colors.accent.color
    case nil: return T.Colors.textSecondary.color
    }
}

struct PluginRow: View {
    let row: PluginHost.Row
    let host: PluginHost
    @State private var hover = false

    var body: some View {
        let problem = row.problem
        let tone: PluginRowContent.Tone? = problem != nil ? .failed : row.content?.tone
        let text = problem.map { "\(row.id): \($0)" } ?? row.content?.text ?? ""
        HStack(spacing: 6) {
            Image(systemName: problem != nil ? "exclamationmark.triangle" : (row.content?.icon ?? "puzzlepiece.extension"))
                .font(.system(size: 11))
                .foregroundStyle(toneColor(tone))
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(T.Colors.textPrimary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if problem == nil, let badge = row.content?.badge {
                Text(badge)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(toneColor(tone ?? .accent))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NotificationBarPlugin.rowHeight)
        .background(hover ? T.Colors.rowHover.color : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { host.click(row.id) }
        .contextMenu {
            Button("Restart \(row.id)") { host.restart(row.id) }
            PluginMenuItems(host: host)
        }
        .help(problem != nil ? "Click to restart. Log: \(host.logPath(row.id))" : "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct NotificationRowView: View {
    let model: AppModel
    let controller: LmuxController
    let host: PluginHost?
    @State private var hover = false

    /// 最新一則未讀；全部已讀時顯示最新一則；沒有通知時為 nil。
    private var shown: NotificationEntry? {
        model.notifications.first { !$0.read } ?? model.notifications.first
    }

    var body: some View {
        let unread = model.unreadNotifications
        let entry = shown
        HStack(spacing: 6) {
            Image(systemName: unread > 0 ? "bell.badge" : "bell")
                .font(.system(size: 11))
                .foregroundStyle((unread > 0 ? T.Colors.accent : T.Colors.textTertiary).color)
                .frame(width: 14)
            if let entry {
                line(entry)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("No notifications")
                    .font(.system(size: 12))
                    .foregroundStyle(T.Colors.textTertiary.color)
            }
            Spacer(minLength: 4)
            if unread > 0 {
                Text("\(unread)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(T.Colors.accent.color)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: NotificationBarPlugin.rowHeight)
        .background(hover && entry != nil ? T.Colors.rowHover.color : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let entry { controller.openNotification(entry) } }
        .contextMenu { if let host { PluginMenuItems(host: host) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(entry != nil ? .isButton : [])
        .accessibilityLabel("Notifications")
    }

    /// 「workspace 標題  訊息」一行；workspace 還在時用它目前的標題（比照鈴鐺清單的 NotificationRow）。
    private func line(_ e: NotificationEntry) -> Text {
        let title = model.workspaces.first { $0.id == e.workspaceID }?.title ?? e.title
        return Text(title)
            .fontWeight(e.read ? .regular : .medium)
            .foregroundStyle((e.read ? T.Colors.textSecondary : T.Colors.textPrimary).color)
            + Text("  " + e.message)
            .foregroundStyle((e.read ? T.Colors.textTertiary : T.Colors.textSecondary).color)
    }
}
