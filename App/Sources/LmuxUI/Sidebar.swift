import AppKit
import QuartzCore
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

// SwiftUI is used only here (sidebar + titlebar buttons), never in the terminal path.

/// Hosting view that takes the first click even when the window is not key,
/// and never keeps keyboard focus (the controller hands it back to a pane).
final class SidebarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

/// The named coordinate space rows report their frames in (drag-and-drop, `SidebarReorder.swift`):
/// the rows' scroll content, not the window, so a frame tracks a row through scrolling.
private let sidebarRowsSpace = "sidebarRows"

/// Collects every visible row's frame (`sidebarRowsSpace`), keyed by workspace id, as laid out
/// (drag offsets not included), for the drag gesture and the rows' drag offsets (`SidebarDragGeometry`).
private struct SidebarRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The rows' frames, read by the drag gesture and the drag offsets only: kept out of SwiftUI's
/// state so a frame change (a row growing a second line) doesn't re-evaluate every row.
final class SidebarRowFrameStore {
    var frames: [String: CGRect] = [:]
}

struct SidebarView: View {
    let model: AppModel
    let controller: LmuxController
    /// The hosting view's root, made once: a plain reference is as stable as `@State` here (and tests can read it).
    let rowFrames = SidebarRowFrameStore()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        let names = model.rowDisambiguators
                        let drag = model.sidebarDrag
                        let shifts = drag.map { dragOffsets($0) } ?? [:]
                        VStack(spacing: T.Layout.rowGap) {
                            ForEach(Array(model.workspaces.enumerated()), id: \.element.id) { _, ws in
                                SidebarRowMotion(model: model, id: ws.id, shift: shifts[ws.id] ?? 0,
                                                 lifted: drag?.ids.contains(ws.id) ?? false) {
                                    WorkspaceRow(ws: ws, disambiguator: names[ws.id], selected: ws.id == model.selectedID,
                                                 inSelection: model.isInSelection(ws),
                                                 hover: drag == nil && model.hoveredRowID == ws.id,
                                                 controller: controller, rowFrames: rowFrames)
                                }
                            }
                        }
                        .padding(.top, T.Spacing.s)
                        .padding(.bottom, T.Spacing.m)
                        .animation(T.Motion.reduceMotion ? nil : .easeOut(duration: T.Motion.selection), value: model.selectedID)
                        .animation(T.Motion.reduceMotion ? nil : .easeOut(duration: T.Motion.selection), value: model.selection)
                    }
                    .scrollIndicators(.never)
                    .coordinateSpace(name: sidebarRowsSpace)
                    .onPreferenceChange(SidebarRowFrames.self) { rowFrames.frames = $0 }
                    .background(SidebarDragAutoScroll(model: model, controller: controller, proxy: proxy,
                                                      viewportHeight: viewport.size.height))
                }
            }
            HistorySection(history: controller.history)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.lmuxMotion, model.pulseMotion)
        // The surface (translucent material + Nord tint, or the opaque fallback) is drawn by
        // `SidebarBackdrop` behind this view, full height, titlebar included.
    }

    /// Every row's shift for the drag's current slot: evaluated when the slot changes, not per move.
    private func dragOffsets(_ drag: AppModel.SidebarDrag) -> [String: CGFloat] {
        SidebarDragGeometry(order: model.workspaces.map(\.id), moving: Set(drag.ids), frames: rowFrames.frames)
            .offsets(grabbed: drag.grabbedID, dropIndex: drag.dropIndex)
    }
}

/// A row's place in a drag: the rows being dragged lift (an elevated card, slightly larger) and
/// follow the pointer live; the others slide by `shift` to open the drop slot, and everything
/// springs into place on drop or Esc. Only a lifted row reads the per-move pointer, so a mouse
/// move re-renders just these wrappers, never the rows inside them.
struct SidebarRowMotion<Content: View>: View {
    let model: AppModel
    let id: String
    let shift: CGFloat
    let lifted: Bool
    @ViewBuilder let content: Content

    private struct Pose: Equatable { let shift: CGFloat; let lifted: Bool }

    var body: some View {
        let follow = lifted ? (model.sidebarDragPointer?.translation ?? 0) : 0
        content
            .background {
                if lifted {
                    RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                        .fill(T.Colors.elevatedBackground.color)
                        .overlay(RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                            .strokeBorder(T.Colors.border.color, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        .padding(.horizontal, T.Layout.rowInsetX)
                        .transition(.opacity)
                }
            }
            .scaleEffect(lifted ? 1.02 : 1)
            .offset(y: shift + follow)
            // Slot changes, lift, drop and Esc animate; the pointer itself is followed as is.
            .animation(T.Motion.reduceMotion ? nil : T.Motion.reorder, value: Pose(shift: shift, lifted: lifted))
            .zIndex(lifted ? 1 : 0)
            // After the offset: the frame as laid out, so the drag geometry never sees its own shifts.
            .background(GeometryReader { geo in
                Color.clear.preference(key: SidebarRowFrames.self, value: [id: geo.frame(in: .named(sidebarRowsSpace))])
            })
    }
}

/// Auto-scroll near the list's ends while dragging: its own view so that following the pointer
/// re-evaluates only this, not the sidebar.
private struct SidebarDragAutoScroll: View {
    let model: AppModel
    let controller: LmuxController
    let proxy: ScrollViewProxy
    let viewportHeight: CGFloat

    var body: some View {
        Color.clear.onChange(of: model.sidebarDragPointer) { _, _ in
            controller.sidebarAutoScroll(proxy: proxy, viewportHeight: viewportHeight)
        }
    }
}

/// The workspace's color: the only place it shows (row, content header, input legend; R7).
struct AccentChip: View {
    let accent: Int
    var size: CGFloat = T.Layout.accentChipSize
    var body: some View {
        RoundedRectangle(cornerRadius: size >= 8 ? T.Radius.accentChip : 2, style: .continuous)
            .fill(T.Colors.workspaceAccents[accent % T.Colors.workspaceAccents.count].color)
            .frame(width: size, height: size)
    }
}

/// A sidebar row (POLISH.md 4): chip · title · one state indicator; line 2 only when there is
/// something to say. Selection is a neutral pill behind unchanged text. On hover the trailing
/// slot is a × that closes the row (or the multi-selection it is part of).
struct WorkspaceRow: View {
    let ws: Workspace
    /// Line 2 for an idle row that shares its title (computed once for the whole list).
    let disambiguator: String?
    /// The active workspace (on screen).
    let selected: Bool
    /// Drawn with a selection pill (the active row, or any row of a multi-selection).
    let inSelection: Bool
    let hover: Bool
    let controller: LmuxController
    /// Every visible row's frame (`sidebarRowsSpace`), for the drag gesture to compute a drop slot.
    let rowFrames: SidebarRowFrameStore

    var body: some View {
        let detail = ws.rowDetail(now: controller.model.clock, disambiguator: disambiguator)
        let targets = hover ? controller.closeTargets(for: ws).count : 1
        WorkspaceRowContent(title: ws.title, accent: ws.accent, state: ws.rowState,
                            detail: detail, unread: ws.unread,
                            selected: selected, inSelection: inSelection, hover: hover,
                            unattended: ws.unattendedSince != nil, pulse: controller.model.pulseMotion,
                            reduceMotion: controller.model.reduceMotion, waiting: ws.waitsForUsageLimit)
            .contentShape(Rectangle())
            .onTapGesture { controller.clickRow(ws, modifiers: LmuxWindow.clickModifiers) }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if LmuxWindow.clickModifiers.isDisjoint(with: [.command, .shift]) { controller.promptRename(ws) }
            })
            // A small threshold so a plain click (select), ⌘/⇧-click and the double-click above
            // all still land as taps: this only starts once the pointer has moved past it.
            // The named space is the scroll content, not this row: the row moving under the
            // pointer (it follows it) doesn't feed back into the location.
            .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named(sidebarRowsSpace))
                .onChanged { value in
                    // The rows this drag carries (fixed when it started; a selection change mid-drag
                    // must not shift where the others are counted from).
                    let ids = Set(controller.model.sidebarDrag?.ids ?? controller.closeTargets(for: ws).map(\.id))
                    let moved = value.location.y - value.startLocation.y
                    let idx = SidebarDragGeometry(order: controller.model.workspaces.map(\.id), moving: ids, frames: rowFrames.frames)
                        .dropIndex(grabbed: ws.id, translation: moved)
                    controller.sidebarDragUpdate(ws, dropIndex: idx, pointerY: value.location.y, translation: moved)
                }
                .onEnded { _ in controller.sidebarDragEnded() })
            .help(ws.rowHelp)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(inSelection ? [.isSelected, .isButton] : [.isButton])
            .accessibilityValue([inSelection && controller.model.isMultiSelection
                                    ? "\(controller.model.selection.count) workspaces selected" : nil,
                                 ws.unattendedSince == nil ? nil : controller.waitingLabel(ws)]
                                    .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAction(named: "Close \(ws.title)") { controller.closeFromRow(ws) }
            .accessibilityAction(named: "Move Up") { controller.moveWorkspace(from: ws, by: -1) }
            .accessibilityAction(named: "Move Down") { controller.moveWorkspace(from: ws, by: 1) }
            // Outside the row's tap gesture: a click on the × never selects the row first.
            .overlay(alignment: .topTrailing) {
                if hover {
                    RowCloseButton(label: Self.closeLabel(ws.title), help: Self.closeHelp(controller.closeTitle(count: targets))) {
                        controller.closeFromRow(ws)
                    }
                    .padding(.top, Self.closeTop(detail != nil))
                    .padding(.trailing, Self.closeTrailing)
                }
            }
            .onHover { inside in
                if inside { controller.model.hoveredRowID = ws.id }
                else if controller.model.hoveredRowID == ws.id { controller.model.hoveredRowID = nil }
            }
            .contextMenu {
                ForEach(Array(controller.rowMenu(for: ws).enumerated()), id: \.offset) { _, item in
                    if let item { Button(item.title, action: item.run) } else { Divider() }
                }
            }
    }

    static func closeLabel(_ title: String) -> String { "Close \(title)" }
    /// "Close Workspace (⇧⌘W)": the Close Workspace shortcut (Ghostty's `close_window`, ⇧⌘W by default).
    static func closeHelp(_ title: String) -> String { "\(title) (⇧⌘W)" }

    /// The × centered on line 1's trailing 12pt slot, its hit target `rowCloseButtonSize` square.
    static let closeTrailing = T.Layout.rowInsetX + T.Layout.rowPaddingX + 6 - T.Layout.rowCloseButtonSize / 2
    static func closeTop(_ twoLines: Bool) -> CGFloat {
        let h = twoLines ? T.Layout.workspaceRowHeightDouble : T.Layout.workspaceRowHeightSingle
        let content = T.Typography.rowTitle.lineHeight + (twoLines ? T.Layout.rowLineGap + T.Typography.rowSubtitle.lineHeight : 0)
        return (h - content) / 2 + T.Typography.rowTitle.lineHeight / 2 - T.Layout.rowCloseButtonSize / 2
    }
}

/// The row ×: a small `xmark` in `textTertiary`; on hover `textSecondary` over a soft round fill.
struct RowCloseButton: View {
    let label: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle((hover ? T.Colors.textSecondary : T.Colors.textTertiary).color)
                .frame(width: T.Layout.rowCloseButtonSize, height: T.Layout.rowCloseButtonSize)
                .background(Circle().fill(hover ? T.Colors.controlHover.color : .clear).padding(2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// What a row draws; also used as-is by the onboarding sheet's preview.
struct WorkspaceRowContent: View {
    let title: String
    let accent: Int
    let state: AgentDisplay
    let detail: Workspace.RowDetail?
    let unread: Int
    let selected: Bool
    var inSelection = false
    var hover = false
    /// Done / needs input and left unattended past the reminder delay.
    var unattended = false
    var pulse = true
    var reduceMotion = false
    /// Running, but waiting for a usage limit to reset (a still clock instead of the spinner).
    var waiting = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let height = detail == nil ? T.Layout.workspaceRowHeightSingle : T.Layout.workspaceRowHeightDouble
        VStack(alignment: .leading, spacing: T.Layout.rowLineGap) {
            HStack(spacing: 0) {
                AccentChip(accent: accent)
                    .padding(.trailing, T.Layout.accentChipGap)
                Text(title)
                    .font(T.Typography.rowTitle.font)
                    .foregroundStyle(T.Colors.textPrimary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Hovered, the trailing slot is the row's × (drawn by WorkspaceRow over it).
                StateIndicator(display: state, unread: selected ? 0 : unread, unattended: unattended,
                               pulse: pulse, reduceMotion: reduceMotion, waiting: waiting)
                    .padding(.leading, 6)
                    .opacity(hover ? 0 : 1)
            }
            .frame(height: T.Typography.rowTitle.lineHeight)
            if let d = detail {
                HStack(spacing: 4) {
                    if d.isBranch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                    }
                    Text(d.text)
                        .fontWeight(d.tone == .needsInput ? .medium : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let age = d.age {
                        Text(age)
                            .font(T.Typography.rowMeta.font.monospacedDigit())
                            .foregroundStyle(T.Colors.textTertiary.color)
                            .opacity(hover ? 0 : 1)
                    }
                }
                .font(d.tone == .tertiary ? T.Typography.rowMeta.font : T.Typography.rowSubtitle.font)
                .foregroundStyle(color(d.tone))
                .padding(.leading, T.Layout.accentChipSize + T.Layout.accentChipGap)
                .frame(height: T.Typography.rowSubtitle.lineHeight)
            }
        }
        .padding(.horizontal, T.Layout.rowPaddingX)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                .fill(pillColor)
        )
        .padding(.horizontal, T.Layout.rowInsetX)
    }

    private var pillColor: Color {
        let inactive = activeState == .inactive
        if selected { return (inactive ? T.Colors.rowSelectedInactive : T.Colors.rowSelected).color }
        if inSelection { return (inactive ? T.Colors.rowSelectedSecondaryInactive : T.Colors.rowSelectedSecondary).color }
        return hover ? T.Colors.rowHover.color : .clear
    }

    private func color(_ tone: Workspace.RowDetail.Tone) -> Color {
        switch tone {
        case .needsInput: return T.Colors.stateNeedsInput.color
        case .secondary: return T.Colors.textSecondary.color
        case .tertiary: return T.Colors.textTertiary.color
        }
    }
}

/// The one state indicator in a row's trailing 12×12 slot.
struct StateIndicator: View {
    let display: AgentDisplay
    /// Unread alerts (0 on the selected row): a needs-input row shows the badge instead of the dot.
    let unread: Int
    /// Left unattended: the indicator breathes (accent check, a soft accent halo behind it), or a
    /// static accent ring under Reduce Motion.
    var unattended = false
    var pulse = true
    var reduceMotion = false
    var waiting = false

    var body: some View {
        if unattended && reduceMotion {
            plain.overlay(Circle().stroke(T.Colors.accent.color, lineWidth: 1.5).frame(width: 17, height: 17))
        } else if unattended {
            Pulse(animating: pulse) { plain }
        } else {
            plain
        }
    }

    @ViewBuilder private var plain: some View {
        switch display {
        case .needsInput where unread > 0:
            Badge(count: unread)
        case .idle where unread > 0:
            Badge(count: unread)
        default:
            StateGlyph(display: display, emphasized: unattended, waiting: waiting)
        }
    }
}

struct StateGlyph: View {
    let display: AgentDisplay
    /// Unattended: the check takes the accent so it shows in peripheral vision.
    var emphasized = false
    /// Running but waiting for a usage limit: a still clock (nothing is working).
    var waiting = false

    var body: some View {
        Group {
            switch display {
            case .needsInput:
                Circle()
                    .fill(T.Colors.stateNeedsInput.color)
                    .frame(width: 7, height: 7)
            case .running where waiting:
                Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(T.Colors.stateRunning.color)
            case .running:
                Spinner(color: T.Colors.stateRunning)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle((emphasized ? T.Colors.accent : T.Colors.stateDone).color)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(T.Colors.stateFailed.color)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// May the sidebar animate (window seen, sidebar shown, motion not reduced)? Set by SidebarView
/// from `AppModel.pulseMotion`; the spinner and the unattended pulse stop when false.
struct LmuxMotionKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var lmuxMotion: Bool {
        get { self[LmuxMotionKey.self] }
        set { self[LmuxMotionKey.self] = newValue }
    }
}

/// The running indicator: a neutral 3/4 arc turning once a second. A Core Animation rotation on
/// a shape layer (the render server runs it; SwiftUI never re-renders per frame). Without motion
/// (window hidden, Reduce Motion) it is the same arc, still.
struct Spinner: NSViewRepresentable {
    let color: LmuxTokens.DynamicColor
    @Environment(\.lmuxMotion) private var motion

    final class Arc: NSView {
        let arc = CAShapeLayer()
        var color: LmuxTokens.DynamicColor? { didSet { applyColor() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineWidth = 1.5
            arc.lineCap = .round
            arc.strokeEnd = 0.75
            layer?.addSublayer(arc)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError() }
        override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.frame = bounds
            let d: CGFloat = 10, r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
            arc.path = CGPath(ellipseIn: r.insetBy(dx: 0.75, dy: 0.75), transform: nil)
            CATransaction.commit()
        }

        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColor() }

        func applyColor() {
            guard let color else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance { self.arc.strokeColor = color.nsColor.cgColor }
        }

        var isSpinning: Bool { arc.animation(forKey: "spin") != nil }

        func setSpinning(_ on: Bool) {
            guard on != isSpinning else { return }
            if on {
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = -2 * Double.pi  // clockwise (layer y points up)
                a.duration = LmuxTokens.Motion.spinnerPeriod
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                arc.add(a, forKey: "spin")
            } else {
                arc.removeAnimation(forKey: "spin")
            }
        }
    }

    func makeNSView(context: Context) -> Arc { Arc(frame: NSRect(x: 0, y: 0, width: 10, height: 10)) }

    func updateNSView(_ v: Arc, context: Context) {
        v.color = color
        v.setSpinning(motion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Arc, context: Context) -> CGSize? { CGSize(width: 10, height: 10) }
}

struct Badge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: T.Typography.badge.size, weight: .bold).monospacedDigit())
            .foregroundStyle(T.Colors.badgeText.color)
            .padding(.horizontal, 4.5)
            .frame(minWidth: T.Layout.badgeMinWidth, minHeight: T.Layout.badgeHeight, maxHeight: T.Layout.badgeHeight)
            .background(Capsule().fill(T.Colors.badgeBackground.color))
    }
}

// MARK: - Titlebar buttons (sidebar toggle, bell, +)

struct TitlebarCluster: View {
    let model: AppModel
    let controller: LmuxController

    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "sidebar.left", help: "Toggle Sidebar (⌃⌘S)") { controller.toggleSidebar() }
            ZStack(alignment: .topTrailing) {
                IconButton(symbol: "bell", help: "Notifications (⌥-click: Jump to Latest Unread, ⇧⌘U)") {
                    controller.bellClicked(modifiers: LmuxWindow.clickModifiers)
                }
                if model.totalUnread > 0 {
                    // At the glyph's top right; no ring (a sidebar-colored ring looks wrong on the material).
                    Text("\(model.totalUnread)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(T.Colors.badgeText.color)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 14, minHeight: 14, maxHeight: 14)
                        .background(Capsule().fill(T.Colors.badgeBackground.color))
                        .offset(x: 3, y: -2)
                        .allowsHitTesting(false)
                }
            }
            IconButton(symbol: "plus", help: "New Workspace (⌘N)") { controller.newWorkspace() }
        }
        .frame(height: T.Layout.titlebarButtonSize)
    }

    static let width: CGFloat = 3 * T.Layout.titlebarButtonSize + 2 * 2
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .frame(width: T.Layout.titlebarButtonSize, height: T.Layout.titlebarButtonSize)
                .foregroundStyle((hover ? T.Colors.titlebarIconHover : T.Colors.titlebarIcon).color)
                .background(RoundedRectangle(cornerRadius: T.Radius.control)
                    .fill(hover ? T.Colors.controlHover.color : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
