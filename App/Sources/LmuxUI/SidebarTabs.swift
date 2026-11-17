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
