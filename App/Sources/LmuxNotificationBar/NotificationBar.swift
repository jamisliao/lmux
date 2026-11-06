import AppKit
import LmuxTokens
import LmuxUI
import Observation
import SwiftUI

private typealias T = LmuxTokens

/// sidebar 最底部的 bar，由上而下：可上下拖曳調整高度的拖曳帶、各個 plugin 的行（PluginHost）、通知清單。
/// 通知清單的第一行是摘要（最新一則未讀，沒有未讀就是最新一則，加上未讀數），往下是其他未讀、再來是已讀。
/// 點一下會跳到該通知的 pane 並標成已讀。通知資料與鈴鐺清單相同（`AppModel.notifications`，最多 50 則，不保存）。
@MainActor
public enum NotificationBarPlugin {
    static let rowHeight: CGFloat = 29
    /// 最上緣的拖曳帶：1pt 分隔線在最上面，其餘透明，整條都可以拖。
    static let handleHeight: CGFloat = 5

    /// 最小高度，也是沒拖過時的自動高度：拖曳帶 + 每個 plugin 一行（有 plugin 時再加一條分隔線）+ 一行通知。
    static func minHeight(pluginRows: Int) -> CGFloat {
        handleHeight + rowHeight * CGFloat(pluginRows) + (pluginRows > 0 ? 1 : 0) + rowHeight
    }

    /// 在 `controller.start()` 之後呼叫。
    public static func install(on controller: LmuxController) {
        let host = makeHost(controller)
        let layout = BarLayout()
        let view = BarHostingView(rootView: NotificationBar(model: controller.model, controller: controller,
                                                            host: host, layout: layout))
        // 尺寸與位置由 RootView 決定，比照 RootView 對 sidebarHost 的設定。
        view.sizingOptions = []
        view.safeAreaRegions = []
        followHeight(host, layout, view, controller, last: -1)
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

    /// plugin 行數或拖出來的高度變了，就更新 bar 的高度（比照 RootView.trackSidebarState 的寫法）。
    private static func followHeight(_ host: PluginHost?, _ layout: BarLayout, _ view: NSView,
                                     _ controller: LmuxController, last: CGFloat) {
        let height = minHeight(pluginRows: host?.rows.count ?? 0) + layout.extra
        withObservationTracking {
            _ = host?.rows.count
            _ = layout.extra
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { followHeight(host, layout, view, controller, last: height) }
            }
        }
        if height != last { controller.installSidebarAccessory(view, height: height) }
    }
}

/// 使用者拖出來、超過最小高度的部分（都給通知清單），存在 UserDefaults，重開 lmux 後維持。
@MainActor @Observable
final class BarLayout {
    static let defaultsKey = "sidebarBarExtraHeight"
    var extra: CGFloat

    init() { extra = max(0, CGFloat(UserDefaults.standard.double(forKey: Self.defaultsKey))) }

    /// 拖曳結束才寫入，拖曳過程中不必每一步都寫。
    func save() { UserDefaults.standard.set(Double(extra), forKey: Self.defaultsKey) }
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
    let layout: BarLayout

    var body: some View {
        let pluginRows = host?.rows ?? []
        VStack(spacing: 0) {
            BarResizeHandle(layout: layout) {
                controller.sidebarAccessoryMaxHeight - NotificationBarPlugin.minHeight(pluginRows: pluginRows.count)
            }
            if let host, !pluginRows.isEmpty {
                ForEach(pluginRows) { row in PluginRow(row: row, host: host) }
                Rectangle().fill(T.Colors.separator.color).frame(height: 1)
            }
            NotificationList(model: model, controller: controller, host: host)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// bar 最上緣：往上拖變高、往下拖變矮（不會低於最小高度），雙擊恢復自動高度。
struct BarResizeHandle: View {
    let layout: BarLayout
    /// 以目前的視窗大小，`extra` 最多可以到多少。
    let maxExtra: () -> CGFloat
    @State private var dragStart: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(T.Colors.separator.color).frame(height: 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotificationBarPlugin.handleHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        // global 座標：bar 在拖曳中會跟著變高、位置會移動，用 local 座標的話位移量會抖動。
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? layout.extra
                dragStart = start
                // 往上拖（translation 為負）bar 變高。
                layout.extra = min(max(0, start - value.translation.height), max(0, maxExtra()))
            }
            .onEnded { _ in
                dragStart = nil
                layout.save()
            })
        .onTapGesture(count: 2) {
            layout.extra = 0
            layout.save()
        }
        .help("Drag to resize, double-click to reset")
    }
}

/// 右鍵選單裡兩種行都有的項目。
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

/// 「workspace 標題  訊息」一行；workspace 還在時用它目前的標題（比照鈴鐺清單的 NotificationRow）。
@MainActor
func notificationLine(_ e: NotificationEntry, in model: AppModel) -> Text {
    let title = model.workspaces.first { $0.id == e.workspaceID }?.title ?? e.title
    return Text(title)
        .fontWeight(e.read ? .regular : .medium)
        .foregroundStyle((e.read ? T.Colors.textSecondary : T.Colors.textPrimary).color)
        + Text("  " + e.message)
        .foregroundStyle((e.read ? T.Colors.textTertiary : T.Colors.textSecondary).color)
}

/// 摘要行 + 其餘通知；比 bar 的可用高度長時可以捲動。
struct NotificationList: View {
    let model: AppModel
    let controller: LmuxController
    let host: PluginHost?

    var body: some View {
        // 未讀在前、已讀在後，各自由新到舊；第一個就是摘要行顯示的那一則。
        let ordered = model.notifications.filter { !$0.read } + model.notifications.filter(\.read)
        // ponytail: 「3m」這類時間只在通知變動或 sidebar 每分鐘的 tick（model.clock）時更新，閒置時不另外開計時器。
        let now = max(model.clock, Date())
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                NotificationSummaryRow(model: model, controller: controller, host: host, shown: ordered.first)
                ForEach(Array(ordered.dropFirst())) { e in
                    NotificationListRow(entry: e, line: notificationLine(e, in: model), age: Self.age(e.date, now: now)) {
                        controller.openNotification(e)
                    }
                }
            }
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// 「now」「3m」「2h」「4d」，與鈴鐺清單相同（LmuxUI 的 NotificationRow.age 是 internal，這裡另寫一份）。
    static func age(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}

/// 清單第一行：最新一則未讀（沒有未讀就是最新一則）與未讀數。沒拖高時，bar 上只看得到這一行通知。
struct NotificationSummaryRow: View {
    let model: AppModel
    let controller: LmuxController
    let host: PluginHost?
    let shown: NotificationEntry?
    @State private var hover = false

    var body: some View {
        let unread = model.unreadNotifications
        HStack(spacing: 6) {
            Image(systemName: unread > 0 ? "bell.badge" : "bell")
                .font(.system(size: 11))
                .foregroundStyle((unread > 0 ? T.Colors.accent : T.Colors.textTertiary).color)
                .frame(width: 14)
            if let shown {
                notificationLine(shown, in: model)
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
        .background(hover && shown != nil ? T.Colors.rowHover.color : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let shown { controller.openNotification(shown) } }
        .contextMenu { if let host { PluginMenuItems(host: host) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(shown != nil ? .isButton : [])
        .accessibilityLabel("Notifications")
    }
}

/// 清單裡其餘的通知：未讀圓點、標題與訊息、經過時間。
struct NotificationListRow: View {
    let entry: NotificationEntry
    let line: Text
    let age: String
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(entry.read ? Color.clear : T.Colors.accent.color)
                .frame(width: 6, height: 6)
                .frame(width: 14)
            line
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(age)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(T.Colors.textTertiary.color)
        }
        .padding(.horizontal, 12)
        .frame(height: NotificationBarPlugin.rowHeight)
        .background(hover ? T.Colors.rowHover.color : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(entry.read ? "" : "unread")
    }
}
