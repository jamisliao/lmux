import AppKit
import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

// 在 sidebar 展開 workspace 的 tab（beat: sidebar-tab-tree.feature）：展開狀態的切換、
// Tab 子列要顯示的內容，以及畫它們的 view。

extension LmuxController {
    /// 點展開箭頭：展開或收合這個 workspace 的 Tab 子列，並存檔。不切換 workspace。
    /// 動畫由這裡帶動（下面的 workspace 列跟著滑動）；系統開「減少動態效果」時不做動畫。
    public func toggleTabsExpanded(_ ws: Workspace) {
        withAnimation(model.reduceMotion ? nil : .easeOut(duration: T.Motion.historyExpand)) {
            ws.tabsExpanded.toggle()
        }
        scheduleSave()
    }

    /// 點一列 Tab 子列：切換到那個 tab（必要時先切換 workspace、把被蓋住的 tab 顯示出來、取消放大）。
    /// 和點 workspace 列一樣，會結束 sidebar 的多選。
    public func clickTabRow(_ pane: Pane) {
        guard let ws = pane.workspace else { return }
        if model.isMultiSelection { setSelection([], anchor: ws.id) }
        focus(pane)
    }

    /// 點 Tab 子列的關閉按鈕。規則與 tab 列相同（`requestClosePane`）：閒置的 shell 直接關；
    /// 還有程式在跑就先詢問。詢問的卡片顯示在那個 tab 上，所以先切過去（它可能在沒選取的
    /// workspace，或被同一格的其他 tab 蓋住），使用者才看得到。
    public func closeTabFromSidebar(_ pane: Pane) {
        // 釘選的 tab 不能關。Tab 子列本來就不畫它的關閉按鈕；這裡再擋一次，
        // 因為 requestClosePane 只在那一格有 tab 列時才擋。
        if pane.pinned { NSSound.beep(); return }
        if runningProcess(pane) != nil { focus(pane) }
        requestClosePane(pane)
    }
}

/// 一列 Tab 子列要顯示的內容。view 只畫這個；測試直接檢查它。
struct SidebarTabItem: Identifiable, Equatable {
    /// 這個 tab（Pane）的 id。
    let id: String
    let title: String
    /// 預覽 tab（文件圖示）；否則是終端機 tab。
    let isPreview: Bool
    /// 這個 tab 自己的 agent 狀態。預覽 tab 沒有 agent，永遠是閒置。
    let display: AgentDisplay
    /// 進行中，但在等使用額度重設：畫時鐘，不畫轉圈（與 workspace 列一致）。
    let waiting: Bool
    let unread: Int
    /// 選取中的 workspace 的 focused tab：這一列有標示。
    let focused: Bool
    /// 釘選的 tab 不能關，沒有關閉按鈕。
    let closable: Bool
}

extension Workspace {
    /// 這個 workspace 的 Tab 子列，由上而下：每一格由左到右、由上到下，格內依 tab 列的順序。
    /// `selected`：這個 workspace 是不是選取中的 workspace（不是的話沒有任何一列有標示）。
    func tabItems(selected: Bool) -> [SidebarTabItem] {
        panes.map { pane in
            let focused = selected && focusedPane === pane
            let title = pane.headerTitle
            return SidebarTabItem(id: pane.id,
                                  title: title.isEmpty ? "Terminal" : title,
                                  isPreview: pane.preview != nil,
                                  display: pane.display,
                                  waiting: pane.agent.usageLimitResets != nil,
                                  unread: focused ? 0 : pane.unread,
                                  focused: focused,
                                  closable: !pane.pinned)
        }
    }
}

/// 一個 workspace 的 Tab 子列。自成一個 view：tab 的標題或狀態改變時，只重畫這一塊，不重畫整個 sidebar。
struct SidebarTabChildren: View {
    let ws: Workspace
    /// 這個 workspace 是不是選取中的 workspace。
    let selected: Bool
    /// 拖曳 workspace 列的期間不顯示 hover。
    let hoverEnabled: Bool
    let controller: LmuxController

    var body: some View {
        if ws.showsTabChildren {
            VStack(spacing: T.Layout.rowGap) {
                ForEach(ws.tabItems(selected: selected)) { item in
                    if let pane = ws.panes.first(where: { $0.id == item.id }) {
                        SidebarTabChildRow(item: item, pane: pane,
                                           hover: hoverEnabled && controller.model.hoveredTabRowID == item.id,
                                           controller: controller)
                    }
                }
            }
        }
    }
}

/// 一列 Tab 子列：類型圖示、標題、這個 tab 自己的狀態。點它切換到這個 tab。
struct SidebarTabChildRow: View {
    let item: SidebarTabItem
    let pane: Pane
    let hover: Bool
    let controller: LmuxController
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.isPreview ? "doc.text" : "terminal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(T.Colors.textTertiary.color)
                .frame(width: 14)
            Text(item.title)
                .font(T.Typography.rowSubtitle.font)
                .foregroundStyle((item.focused ? T.Colors.textPrimary : T.Colors.textSecondary).color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.isPreview {
                StateIndicator(display: item.display, unread: item.unread,
                               pulse: controller.model.pulseMotion, reduceMotion: controller.model.reduceMotion,
                               waiting: item.waiting)
                    .opacity(hover && item.closable ? 0 : 1)
            }
        }
        .padding(.leading, T.Layout.rowPaddingX + T.Layout.tabChildIndent)
        .padding(.trailing, T.Layout.rowPaddingX)
        .frame(maxWidth: .infinity, minHeight: T.Layout.tabChildRowHeight, maxHeight: T.Layout.tabChildRowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous).fill(fill))
        .padding(.horizontal, T.Layout.rowInsetX)
        .contentShape(Rectangle())
        .onTapGesture { controller.clickTabRow(pane) }
        // 在列的點擊手勢之外：點關閉按鈕不會先切換到這個 tab。釘選的 tab 沒有關閉按鈕。
        .overlay(alignment: .trailing) {
            if hover && item.closable {
                RowCloseButton(label: "Close \(item.title)", help: "Close Tab") {
                    controller.closeTabFromSidebar(pane)
                }
                .padding(.trailing, WorkspaceRow.closeTrailing)
            }
        }
        .onHover { inside in
            if inside { controller.model.hoveredTabRowID = item.id }
            else if controller.model.hoveredTabRowID == item.id { controller.model.hoveredTabRowID = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.focused ? [.isSelected, .isButton] : [.isButton])
    }

    /// 底色：有標示的那一列與 workspace 列的玻璃選取底色一致；滑鼠在上面時是 glassCardHover。
    private var fill: Color {
        if item.focused { return (activeState == .inactive ? T.Colors.rowSelectedInactive : T.Colors.glassCardSelected).color }
        return hover ? T.Colors.glassCardHover.color : .clear
    }
}

/// workspace 列的展開箭頭：收合時朝右，展開時朝下。
struct TabDisclosureButton: View {
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(T.Colors.textTertiary.color)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: T.Layout.tabDisclosureSize, height: T.Layout.tabDisclosureSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide Tabs" : "Show Tabs")
        .accessibilityLabel(expanded ? "Hide Tabs" : "Show Tabs")
    }
}
