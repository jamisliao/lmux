import AppKit
import GhosttyKit
import LmuxTerminal

/// 在終端機 ⌘-click 可預覽檔案的路徑時，跳出開啟選單讓使用者選擇開在哪裡（beat: open-menu.feature）。
extension LmuxController {
    /// 開啟選單的項目。
    public enum OpenChoice: Equatable {
        case inspectorPreview, preview, defaultApp, finder, copyPath
    }

    /// 選單的項目與順序（第 1 列的完整路徑不在這裡）。
    static let openMenuItems: [(title: String, choice: OpenChoice)] = [
        ("在右側欄即時預覽", .inspectorPreview),
        ("在新 tab 預覽", .preview),
        ("用預設 app 開", .defaultApp),
        ("在 Finder 顯示", .finder),
        ("複製路徑", .copyPath),
    ]

    /// 測試用：設定後不跳出選單，改由它回答（回傳 nil 表示使用者關掉選單）。
    public static var openMenuTestHook: ((URL) -> OpenChoice?)?
    /// 「在 Finder 顯示」實際做的事；測試換掉它，不真的打開 Finder。
    public static var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    /// 終端機送來的 OPEN_URL（⌘-click 的文字、OSC 8 連結）：可預覽檔案跳出開啟選單，其他照原本流程。
    /// `pane`、`view`：連結所在的終端機 tab 與它的終端機。
    public func openTerminalLink(_ value: String, kind: ghostty_action_open_url_kind_e, pane: Pane?, view: SurfaceView?) {
        let textOrFileLink = kind == GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
            || (kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 && value.lowercased().hasPrefix("file://"))
        if textOrFileLink, let pane, let file = PreviewTarget.resolve(value, cwd: pane.cwd) {
            guard isLivePane(pane) else { return }
            showOpenMenu(file, pane: pane, view: view)
            return
        }
        // 原本流程：與 GhosttyRuntime 收到 OPEN_URL 時做的事相同。
        let label = kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 ? view?.wordUnderMouse() : nil
        GhosttyRuntime.openTerminalURL(value, kind: kind, window: view?.window, label: label)
    }

    private func isLivePane(_ pane: Pane) -> Bool {
        guard let ws = pane.workspace else { return false }
        return model.workspaces.contains { $0 === ws }
    }

    public func openInInspectorPreview(_ file: URL, workspace: Workspace? = nil) {
        let ws = workspace ?? model.selected
        if let ws {
            model.inspectorPreviewURLByWorkspace[ws.id] = file
            if ws === model.selected {
                previewCoordinator.load(url: file, workspaceID: ws.id)
            }
        }
        model.inspectorTab = .preview
        model.inspectorVisible = true
        scheduleSave()
    }

    /// 跳出開啟選單，執行使用者選的項目。
    func showOpenMenu(_ file: URL, pane: Pane, view: SurfaceView?) {
        guard isLivePane(pane) else { return }
        let choice: OpenChoice?
        if let hook = Self.openMenuTestHook {
            choice = hook(file)
        } else {
            // headless（測試、截圖）不顯示任何選單。
            if headless { return }
            guard let view, view.window != nil else {
                GhosttyRuntime.openTerminalURL(file.path, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
                                               window: view?.window ?? (window as NSWindow?))
                return
            }
            PreviewView.prewarm()  // 使用者看選單、挑項目的時間，拿來先啟動 WebKit 程序
            choice = popUpOpenMenu(file, in: view)
        }
        guard isLivePane(pane) else { return }
        guard let choice else {
            focusCurrent()
            return
        }
        switch choice {
        case .inspectorPreview:
            openInInspectorPreview(file, workspace: pane.workspace)
            focusCurrent()
        case .preview:
            newPreviewTab(file, after: pane)
        case .defaultApp:
            // 選單第 1 列已經顯示真正的路徑，所以這裡不再比對 OSC 8 連結的文字。
            GhosttyRuntime.openTerminalURL(file.path, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
                                           window: view?.window ?? (window as NSWindow?))
            focusCurrent()
        case .finder:
            Self.revealInFinder(file)
            focusCurrent()
        case .copyPath:
            let pb = GhosttyRuntime.standardPasteboard
            pb.clearContents()
            pb.setString(file.path, forType: .string)
            focusCurrent()
        }
    }

    /// 開啟選單本身：第 1 列是完整路徑（不能點），接著是 `openMenuItems`（item 的 tag 是它在清單裡的位置）。
    static func makeOpenMenu(_ file: URL, target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: shortPath(file.path), action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.toolTip = file.path
        menu.addItem(header)
        menu.addItem(.separator())
        for (i, entry) in openMenuItems.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(OpenMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = i
            menu.addItem(item)
        }
        return menu
    }

    /// 在滑鼠位置顯示選單，等使用者選完才回來；回傳選到的項目，關掉選單回傳 nil。
    private func popUpOpenMenu(_ file: URL, in view: NSView) -> OpenChoice? {
        let target = OpenMenuTarget()
        let menu = Self.makeOpenMenu(file, target: target)
        let point = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        menu.popUp(positioning: nil, at: point, in: view)
        return target.picked.map { Self.openMenuItems[$0].choice }
    }

    /// 太長的路徑把資料夾的中間用 … 省略，檔名一定完整保留（完整路徑放在 tooltip）。
    static func shortPath(_ path: String, limit: Int = 90) -> String {
        guard path.count > limit else { return path }
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let room = max(10, limit - name.count - 2)
        guard dir.count > room else { return path }
        let head = room / 2
        return String(dir.prefix(head)) + "…" + String(dir.suffix(room - head)) + "/" + name
    }
}

/// 選單項目的 target：記下使用者選了哪一項（item 的 tag）。
private final class OpenMenuTarget: NSObject {
    var picked: Int?
    @objc func pick(_ item: NSMenuItem) { picked = item.tag }
}
