import AppKit
import LmuxTokens
import LmuxUI
import Observation
import SwiftUI

private typealias T = LmuxTokens

/// sidebar 最底部的 bar，由上而下：可上下拖曳調整高度的拖曳帶、各個 plugin 的行（PluginHost）、
/// 摘要列（鈴鐺與未讀數，固定不捲動）、通知卡片清單（未讀在前、已讀在後，各自由新到舊）。
/// 點卡片會跳到該通知的 tab 並標成已讀。通知資料與鈴鐺清單相同（`AppModel.notifications`，最多 50 則，不保存）。
@MainActor
public enum NotificationBarPlugin {
    static let rowHeight: CGFloat = 29
    /// 最上緣的拖曳帶：1pt 分隔線在最上面，中央放膠囊指示條，整條都可以拖。
    static let handleHeight: CGFloat = 6

    /// 最小高度，也是沒拖過時的自動高度：拖曳帶 + 每個 plugin 一行（有 plugin 時再加一條分隔線）
    /// + 摘要列 + 一張完整的通知卡片（不拖拉也看得到第一張卡片）。
    static func minHeight(pluginRows: Int) -> CGFloat {
        handleHeight + rowHeight * CGFloat(pluginRows) + (pluginRows > 0 ? 1 : 0) + rowHeight + NotificationCard.maxHeight
    }

    /// 收合時的高度：拖曳帶 + 每個 plugin 一行（有 plugin 時加分隔線）+ 摘要列。
    public static func collapsedHeight(pluginRows: Int) -> CGFloat {
        handleHeight + rowHeight * CGFloat(pluginRows) + (pluginRows > 0 ? 1 : 0) + rowHeight
    }

    /// 在 `controller.start()` 之後呼叫。
    @discardableResult
    public static func install(on controller: LmuxController, defaults: UserDefaults = .standard) -> BarLayout {
        let host = makeHost(controller)
        let layout = BarLayout(defaults: defaults)
        let view = BarHostingView(rootView: NotificationBar(model: controller.model, controller: controller,
                                                            host: host, layout: layout))
        // 尺寸與位置由 RootView 決定，比照 RootView 對 sidebarHost 的設定。
        view.sizingOptions = []
        view.safeAreaRegions = []
        followHeight(host, layout, view, controller, last: -1)
        layout.observeFocusLoss(for: view, controller: controller)
        host?.reloadAll()
        return layout
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
        let pluginCount = host?.rows.count ?? 0
        let height: CGFloat
        if layout.isCollapsed {
            height = collapsedHeight(pluginRows: pluginCount)
        } else {
            height = minHeight(pluginRows: pluginCount) + layout.extra
        }
        withObservationTracking {
            _ = host?.rows.count
            _ = layout.extra
            _ = layout.isCollapsed
        } onChange: { [weak host, weak layout, weak view, weak controller] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let layout, let view, let controller else { return }
                    followHeight(host, layout, view, controller, last: height)
                }
            }
        }
        if height != last { controller.installSidebarAccessory(view, height: height) }
    }
}

/// 使用者拖出來、超過最小高度的部分（都給通知清單），存在 UserDefaults，重開 lmux 後維持。
@MainActor @Observable
public final class BarLayout {
    public static let defaultsKey = "sidebarBarExtraHeight"
    public static let collapsedDefaultsKey = "sidebarBarIsCollapsed"
    public static let collapseDragThreshold: CGFloat = 42

    public var extra: CGFloat
    public var isCollapsed: Bool
    var savedExtraBeforeCollapse: CGFloat
    private(set) var dragStart: CGFloat?
    private let defaults: UserDefaults
    @ObservationIgnored private nonisolated(unsafe) var focusObservers: [NSObjectProtocol] = []

    public var isDragging: Bool { dragStart != nil }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let e = max(0, CGFloat(defaults.double(forKey: Self.defaultsKey)))
        let c = defaults.bool(forKey: Self.collapsedDefaultsKey)
        self.extra = e
        self.savedExtraBeforeCollapse = e
        self.isCollapsed = c
    }

    deinit {
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func observeFocusLoss(for view: NSView, controller: LmuxController) {
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers.removeAll()
        let nc = NotificationCenter.default
        focusObservers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self, weak view, weak controller] note in
            MainActor.assumeIsolated {
                guard let self, let view, let controller, let w = view.window, note.object as AnyObject? === w else { return }
                if self.isDragging { self.endDrag(on: controller) }
            }
        })
        focusObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                if self.isDragging { self.endDrag(on: controller) }
            }
        })
    }

    public func toggleCollapsed(on controller: LmuxController) {
        controller.setSidebarResizing(true)
        if isCollapsed {
            isCollapsed = false
            extra = max(0, savedExtraBeforeCollapse)
        } else {
            savedExtraBeforeCollapse = extra
            isCollapsed = true
        }
        save()
        DispatchQueue.main.async {
            controller.setSidebarResizing(false)
        }
    }

    public func beginDrag(on controller: LmuxController) {
        if dragStart == nil {
            dragStart = extra
        }
        controller.setSidebarResizing(true)
    }

    public func updateDrag(translationHeight: CGFloat, maxExtra: CGFloat, on controller: LmuxController, pluginRows: Int = 0) {
        beginDrag(on: controller)
        let start = dragStart ?? extra

        if isCollapsed {
            if translationHeight < 0 {
                // Expand smoothly upward starting from 0 so the bar doesn't snap open abruptly.
                isCollapsed = false
                dragStart = 0
                extra = min(max(0, -translationHeight), max(0, maxExtra))
            }
            return
        }

        let newExtra = start - translationHeight
        let totalHeight = NotificationBarPlugin.minHeight(pluginRows: pluginRows) + newExtra
        if totalHeight <= Self.collapseDragThreshold {
            // Preserve the user's pre-collapse expanded height in `savedExtraBeforeCollapse` / `extra` (ignored while collapsed).
            if start > 0 {
                savedExtraBeforeCollapse = start
                extra = start
            }
            isCollapsed = true
        } else {
            extra = min(max(0, newExtra), max(0, maxExtra))
            savedExtraBeforeCollapse = extra
        }
    }

    public func endDrag(on controller: LmuxController) {
        dragStart = nil
        controller.setSidebarResizing(false)
        save()
    }

    /// 拖曳結束或狀態變更時寫入 UserDefaults。
    public func save() {
        defaults.set(Double(extra), forKey: Self.defaultsKey)
        defaults.set(isCollapsed, forKey: Self.collapsedDefaultsKey)
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
    let layout: BarLayout

    var body: some View {
        let pluginRows = host?.rows ?? []
        VStack(spacing: 0) {
            BarResizeHandle(layout: layout, controller: controller, pluginRowCount: pluginRows.count) {
                controller.sidebarAccessoryMaxHeight - NotificationBarPlugin.minHeight(pluginRows: pluginRows.count)
            }
            if let host, !pluginRows.isEmpty {
                ForEach(pluginRows) { row in PluginRow(row: row, host: host) }
                Rectangle().fill(T.Colors.separator.color).frame(height: 1)
            }
            NotificationSummaryRow(model: model, controller: controller, host: host, layout: layout)
            if !layout.isCollapsed {
                Rectangle().fill(T.Colors.glassBorder.color).frame(height: 0.5)
                NotificationList(model: model, controller: controller, host: host)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// bar 最上緣：往上拖變高、往下拖變矮（不會低於最小高度），雙擊切換收合。
struct BarResizeHandle: View {
    let layout: BarLayout
    let controller: LmuxController
    let pluginRowCount: Int
    /// 以目前的視窗大小，`extra` 最多可以到多少。
    let maxExtra: () -> CGFloat
    @State private var hover = false
    @GestureState private var isGestureDragging = false

    static func pillColor(hover: Bool, isDragging: Bool) -> LmuxTokens.DynamicColor {
        (hover || isDragging) ? T.Colors.dragHandlePillActive : T.Colors.dragHandlePill
    }

    var body: some View {
        let pill = Self.pillColor(hover: hover, isDragging: layout.isDragging)
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(T.Colors.glassBorder.color).frame(height: 0.5)
                Rectangle().fill(T.Colors.specularHighlight.color).frame(height: 0.5)
            }
            Capsule()
                .fill(pill.color)
                .frame(width: T.Layout.dragHandlePillWidth, height: T.Layout.dragHandlePillHeight)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotificationBarPlugin.handleHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            hover = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        // global 座標：bar 在拖曳中會跟著變高、位置會移動，用 local 座標的話位移量會抖動。
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($isGestureDragging) { _, state, _ in state = true }
            .onChanged { value in
                layout.updateDrag(translationHeight: value.translation.height, maxExtra: maxExtra(), on: controller, pluginRows: pluginRowCount)
            }
            .onEnded { _ in
                layout.endDrag(on: controller)
            })
        .onChange(of: isGestureDragging) { _, active in
            if !active, layout.isDragging {
                layout.endDrag(on: controller)
            }
        }
        .onDisappear {
            if hover {
                hover = false
                NSCursor.pop()
            }
            if layout.isDragging {
                layout.endDrag(on: controller)
            }
        }
        .onTapGesture(count: 2) {
            layout.toggleCollapsed(on: controller)
        }
        .help("Drag to resize, double-click to collapse/expand")
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

/// 摘要列（固定在上方）+ 通知卡片；卡片比 bar 的可用高度長時可以捲動。
struct NotificationList: View {
    let model: AppModel
    let controller: LmuxController
    let host: PluginHost?

    var body: some View {
        // 未讀在前、已讀在後，各自由新到舊。
        let ordered = model.notifications.filter { !$0.read } + model.notifications.filter(\.read)
        // ponytail: 「3m」這類時間只在通知變動或 sidebar 每分鐘的 tick（model.clock）時更新，閒置時不另外開計時器。
        let now = max(model.clock, Date())
        // 只反白 focused tab 的最新一則通知（notifications 由新到舊）。
        let focusedPaneID = model.selected?.focusedPane?.id
        let highlightedID = focusedPaneID == nil ? nil : model.notifications.first { $0.paneID == focusedPaneID }?.id
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if ordered.isEmpty {
                        Text("尚無通知")
                            .font(.system(size: 12))
                            .foregroundStyle(T.Colors.textTertiary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 32)
                            .frame(height: NotificationBarPlugin.rowHeight)
                    }
                    ForEach(ordered) { e in
                        NotificationCard(entry: e, model: model, age: Self.age(e.date, now: now),
                                         highlighted: e.id == highlightedID) {
                            controller.openNotification(e)
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            // 捲動過後來了新的未讀通知：捲回最上面，不必動滑鼠。
            .onChange(of: ordered.first?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
        }
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

/// 清單最上面一列：鈴鐺、Inbox 標題與未讀數。
struct NotificationSummaryRow: View {
    let model: AppModel
    let controller: LmuxController
    let host: PluginHost?
    let layout: BarLayout
    @State private var hover = false

    /// 這一次 build 的版號（Info.plist 的 CFBundleVersion，由 bundle.sh 用 git 寫入）。不是 .app（例如 `swift run`）時沒有。
    static let buildVersion: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    var body: some View {
        let unread = model.unreadNotifications
        HStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 11))
                    .foregroundStyle((unread > 0 ? T.Colors.statusRunningText : T.Colors.textSecondary).color)
                    .frame(width: 14, height: 14)
                if unread > 0 {
                    Circle()
                        .fill(T.Colors.needsInputRing.color)
                        .frame(width: 5, height: 5)
                        .shadow(color: T.Colors.needsInputRing.color.opacity(0.55), radius: 2)
                        .offset(x: 2, y: -2)
                }
            }
            .frame(width: 14)

            Text("Inbox")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(T.Colors.textPrimary.color)

            if let v = Self.buildVersion {
                // 窄的時候先截斷版號，未讀數不受影響。
                Text(v)
                    .font(T.Typography.rowMeta.font.monospacedDigit())
                    .foregroundStyle(T.Colors.textTertiary.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(T.Colors.glassSurfaceRecessed.color))
                    .layoutPriority(-1)
                    .help("lmux build \(v)")
            }

            Spacer(minLength: 4)

            if unread > 0 {
                Text("\(unread)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(T.Colors.statusRunningText.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(T.Colors.statusRunningPill.color)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(T.Colors.statusRunningText.color.opacity(0.25), lineWidth: 0.5)
                    )
            }

            Image(systemName: layout.isCollapsed ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(T.Colors.textTertiary.color)
                .frame(width: 12)
        }
        .padding(.horizontal, 12)
        .frame(height: NotificationBarPlugin.rowHeight)
        .background(hover ? T.Colors.glassCardHover.color : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            layout.toggleCollapsed(on: controller)
        }
        .contextMenu { if let host { PluginMenuItems(host: host) } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(unread > 0 ? "Inbox Notifications, \(unread) unread" : "Inbox Notifications")
        .accessibilityAddTraits(.isButton)
    }
}
