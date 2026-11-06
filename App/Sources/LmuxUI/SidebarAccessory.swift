import AppKit

// plugin 掛載點：讓 LmuxUI 以外的 module 在 sidebar 最底部放一條橫列。
// RootView 與 `root` 都是 internal，所以由這裡對外開一個 public 入口。

extension RootView {
    /// bar 再高，也要替上面的 workspace 清單和 History 搜尋欄留這麼多空間。
    static let sidebarListMinHeight: CGFloat = 120
}

extension LmuxController {
    /// 在 sidebar 最底部放入 `view`，高度為 `height`；傳入 nil 則移除。同一個 view 再呼叫一次只會更新高度。
    /// 必須在 `start()` 之後呼叫（`root` 在 start 時才建立）。sidebar 隱藏時 bar 會一起隱藏。
    public func installSidebarAccessory(_ view: NSView?, height: CGFloat) {
        precondition(root != nil, "installSidebarAccessory: call after start()")
        root.sidebarAccessory = view.map { ($0, height) }
        root.updateClusterAppearance()
    }

    /// 以目前的視窗大小，bar 最高可以到多高（超過的部分 RootView 排版時也會截掉）。
    public var sidebarAccessoryMaxHeight: CGFloat {
        guard let root else { return 0 }
        return max(0, root.bounds.height - root.titlebarHeight - RootView.sidebarListMinHeight)
    }
}
