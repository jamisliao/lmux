import AppKit

// plugin 掛載點：讓 LmuxUI 以外的 module 在 sidebar 最底部放一條固定高度的橫列。
// RootView 與 `root` 都是 internal，所以由這裡對外開一個 public 入口。

extension LmuxController {
    /// 在 sidebar 最底部放入 `view`，高度固定為 `height`；傳入 nil 則移除。
    /// 必須在 `start()` 之後呼叫（`root` 在 start 時才建立）。sidebar 隱藏時 bar 會一起隱藏。
    public func installSidebarAccessory(_ view: NSView?, height: CGFloat) {
        precondition(root != nil, "installSidebarAccessory: call after start()")
        root.sidebarAccessory = view.map { ($0, height) }
        root.updateClusterAppearance()
    }
}
