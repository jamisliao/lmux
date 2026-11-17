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
        withAnimation(T.Motion.reduceMotion ? nil : .easeOut(duration: T.Motion.historyExpand)) {
            ws.tabsExpanded.toggle()
        }
        scheduleSave()
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
