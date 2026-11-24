import AppKit
import GhosttyKit
import LmuxTerminal
@testable import LmuxUI
import WebKit

/// 預覽 tab 的互動檢查：`open-menu`、`open-url-action`、`preview-links`、`preview-menu`、`preview-confirm`、`preview-cli`。
@MainActor
func runPreviewInteractionChecks(_ r: Report, _ c: LmuxController, _ fx: PreviewFixtures, external: PreviewExternalSpy) async {
    let docs = fx.docs
    let design = fx.design

    // MARK: 開啟選單（Task 22）
    // @feature: open-menu.feature
    // @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單
    // @scenario: 路徑後面帶行號時，去掉行號再判斷
    // @scenario: OSC 8 連結指向本機的可預覽檔案時也跳出開啟選單
    // @scenario: 不是存在的可預覽檔案時，照原本流程
    // @scenario: shell 沒回報目前目錄時，相對路徑照原本流程
    // @scenario: 選「在新 tab 預覽」開出預覽 tab
    // @scenario: 選「在右側欄即時預覽」載入檔案至右側 Inspector
    // @scenario: 選單的其他項目
    // @scenario: 不選任何項目就關掉選單
    do {
        r.section = "open-menu"
        var asked: [URL] = []
        var answer: LmuxController.OpenChoice?
        var revealed: [URL] = []
        var prompts: [UntrustedURLPrompt] = []
        LmuxController.openMenuTestHook = { asked.append($0); return answer }
        LmuxController.revealInFinder = { revealed.append($0) }
        UntrustedURLAlert.testHook = { prompts.append($0); return false }
        defer {
            LmuxController.openMenuTestHook = nil
            UntrustedURLAlert.testHook = nil
        }
        let ws = c.newWorkspace(cwd: fx.root.path)
        let a = ws.panes[0]
        a.cwd = fx.root.path
        let b = c.newTab(a)!
        c.focus(a)
        func click(_ value: String, _ kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN) {
            c.openTerminalLink(value, kind: kind, pane: a, view: a.surface)
        }
        /// 同一個值：經過 openTerminalLink，與直接走原本流程（GhosttyRuntime.openTerminalURL），開啟的東西與詢問都一樣。
        func sameAsBefore(_ value: String, _ kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN) -> Bool {
            external.urls.removeAll(); prompts.removeAll()
            GhosttyRuntime.openTerminalURL(value, kind: kind, window: a.surface?.window)
            let before = (external.urls, prompts)
            external.urls.removeAll(); prompts.removeAll()
            click(value, kind)
            return external.urls == before.0 && prompts == before.1
        }
        func real(_ u: URL) -> String { u.resolvingSymlinksInPath().path }

        // 選單本身
        let menu = LmuxController.makeOpenMenu(design, target: nil)
        r.check("選單第 1 列是完整路徑，不能點且 tooltip 含完整路徑",
                menu.items.first?.title == design.path && menu.items.first?.isEnabled == false
                    && menu.items.first?.toolTip == design.path,
                "\(menu.items.first?.title ?? "nil") tip=\(menu.items.first?.toolTip ?? "nil")")
        r.check("選單項目依序是 在右側欄即時預覽、在新 tab 預覽、用預設 app 開、在 Finder 顯示、複製路徑",
                menu.items.dropFirst(2).map(\.title) == ["在右側欄即時預覽", "在新 tab 預覽", "用預設 app 開", "在 Finder 顯示", "複製路徑"],
                "\(menu.items.map(\.title))")
        let longPath = "/" + String(repeating: "abcdefgh/", count: 15) + "design.md"
        let longMenu = LmuxController.makeOpenMenu(URL(fileURLWithPath: longPath), target: nil)
        r.check("太長的路徑省略資料夾中間，檔名與完整路徑 tooltip 皆保留",
                LmuxController.shortPath(longPath).hasSuffix("/design.md") && LmuxController.shortPath(longPath).count <= 90
                    && longMenu.items.first?.title == LmuxController.shortPath(longPath)
                    && longMenu.items.first?.toolTip == longPath,
                LmuxController.shortPath(longPath))

        // 跳出選單；關掉選單
        answer = nil
        c.window!.makeFirstResponder(nil)
        external.urls.removeAll()
        click("docs/design.md")
        r.check("⌘-click 可預覽檔案的路徑：跳出開啟選單，問的是這個檔案", asked == [design], "\(asked)")
        r.check("關掉選單：沒有開出預覽 tab，也沒有開啟任何東西",
                ws.panes.count == 2 && external.urls.isEmpty && revealed.isEmpty,
                "\(ws.panes.count) \(external.urls) \(revealed)")
        r.check("關掉選單：焦點回到終端機", c.window!.firstResponder === a.surface)
        asked.removeAll()
        click("docs/design.md:12")
        r.check("路徑帶行號：去掉行號後仍跳出選單", asked == [design], "\(asked)")
        asked.removeAll()
        click(design.absoluteString, GHOSTTY_ACTION_OPEN_URL_KIND_OSC8)
        r.check("OSC 8 的 file:// 連結：跳出選單", asked == [design], "\(asked)")

        // 照原本流程
        asked.removeAll()
        let svg = docs.appendingPathComponent("icon.svg")
        try? "<svg xmlns=\"http://www.w3.org/2000/svg\"/>".write(to: svg, atomically: true, encoding: .utf8)
        r.check("不是可預覽檔案（SVG）：照原本流程開啟",
                sameAsBefore(svg.path) && external.urls.count == 1,
                "\(external.urls)")
        r.check("檔案不存在：照原本流程", sameAsBefore("docs/missing.md"))
        r.check("網址：照原本流程開啟",
                sameAsBefore("https://example.com/readme.md") && external.urls == [URL(string: "https://example.com/readme.md")!],
                "\(external.urls)")
        a.cwd = nil
        r.check("shell 沒回報目前目錄：相對路徑照原本流程", sameAsBefore("docs/design.md"))
        a.cwd = fx.root.path
        r.check("設定檔類（text）的連結：照原本流程", sameAsBefore(design.path, GHOSTTY_ACTION_OPEN_URL_KIND_TEXT))
        r.check("照原本流程的這幾種都沒有跳出選單", asked.isEmpty, "\(asked)")

        // 已關閉的 pane 在彈出前即阻擋，不會開啟選單或系統開啟流程
        let staleWS = c.newWorkspace(cwd: fx.root.path)
        let stalePane = staleWS.panes[0]
        stalePane.cwd = fx.root.path
        c.closeWorkspace(staleWS)
        c.openTerminalLink("docs/design.md", kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, pane: stalePane, view: nil)
        r.check("已關閉 pane 的連結不跳出開啟選單", asked.isEmpty, "\(asked)")

        // 選單項目
        answer = .defaultApp; external.urls.removeAll()
        click("docs/design.md")
        r.check("用預設 app 開：交給系統開這個檔案", external.urls.map(real) == [real(design)], "\(external.urls)")
        answer = .finder
        click("docs/design.md")
        r.check("在 Finder 顯示：交給 Finder 選取這個檔案", revealed == [design], "\(revealed)")
        answer = .copyPath
        click("docs/design.md")
        r.check("複製路徑：剪貼簿是完整路徑", GhosttyRuntime.standardPasteboard.string(forType: .string) == design.path,
                GhosttyRuntime.standardPasteboard.string(forType: .string) ?? "nil")
        answer = .inspectorPreview
        c.model.inspectorVisible = false
        c.model.inspectorTab = .diff
        click("docs/design.md")
        let inspectorPV = c.previewCoordinator.previewView
        if let inspectorPV, let hostView = c.window?.contentView {
            inspectorPV.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
            hostView.addSubview(inspectorPV)
        }
        let inspectorDOMReady = await waitPreviewJS(inspectorPV?.webView, "document.querySelector('h1')?.textContent === 'Design'")
        inspectorPV?.removeFromSuperview()
        r.check("在右側欄即時預覽：設定 inspectorTab == .preview 且 inspectorVisible == true 不更動分割數，並完成 WKWebView DOM 載入",
                c.model.inspectorVisible && c.model.inspectorTab == .preview
                && c.model.inspectorPreviewURLByWorkspace[ws.id] == design
                && c.previewCoordinator.currentURL == design
                && inspectorPV != nil
                && inspectorDOMReady
                && ws.panes.count == 2)
        r.check("其他項目都不開出預覽 tab", ws.panes.count == 2, "\(ws.panes.count)")
        answer = .preview
        click("docs/design.md")
        let leaf = ws.root.find(a)
        let p = leaf?.tabs.first { $0.preview != nil }
        r.check("在新 tab 預覽：插在 A 與 B 之間", leaf?.tabs.map(\.id) == [a.id, p?.id ?? "-", b.id],
                "\(leaf?.tabs.map(\.id) ?? [])")
        r.check("在新 tab 預覽：成為 focused tab", p != nil && ws.focusedPane === p)
    }

    // MARK: Ghostty 的 OPEN_URL 走開啟選單（Task 23）
    // @feature: open-menu.feature
    // @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單
    do {
        r.section = "open-url-action"
        var asked: [URL] = []
        LmuxController.openMenuTestHook = { asked.append($0); return nil }
        defer { LmuxController.openMenuTestHook = nil }
        let ws = c.newWorkspace(cwd: fx.root.path)
        let a = ws.panes[0]
        a.cwd = fx.root.path
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        let handled: Bool? = "docs/design.md".withCString { ptr in
            action.action.open_url = ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: ptr,
                                                               len: UInt(strlen(ptr)))
            return c.runtime.actionHandler?(ghostty_target_s(), action, a.surface)
        }
        r.check("Ghostty 的 OPEN_URL 由 lmux 處理", handled == true, "\(String(describing: handled))")
        r.check("Ghostty 的 OPEN_URL 跳出開啟選單", await waitFor(3) { asked == [design] }, "\(asked)")
    }

    // MARK: 預覽裡換頁與點網址（Task 24）
    // @feature: preview-tab.feature
    // @scenario: 點相對路徑的 .md 連結，在同一個預覽 tab 換頁
    // @scenario: 在預覽裡用觸控板兩指往右滑，回到上一頁
    // @scenario: 點網址連結，照終端機裡點連結的規則處理
    // @scenario: 預覽中的檔案被刪除
    do {
        r.section = "preview-links"
        let gone = docs.appendingPathComponent("gone.md")
        try? "# Gone\n".write(to: gone, atomically: true, encoding: .utf8)
        let (ws, _, p) = previewSetup(c, dir: fx.root, file: design)
        _ = await waitFor(5) { p.preview?.webView.isLoading == false }
        r.check("預覽啟用雙指滑動上一頁／下一頁手勢", p.preview?.webView.allowsBackForwardNavigationGestures == true)
        let count = ws.panes.count
        p.preview!.noteUserClick()
        _ = try? await p.preview!.webView.evaluateJavaScript("document.querySelector('a[href=\"b.md\"]').click()")
        r.check("預覽換頁後 tab 標題跟著換成 b.md", await waitFor(5) { p.headerTitle == "b.md" }, p.headerTitle)
        r.check("預覽換頁時沒有開出新的 tab", ws.panes.count == count, "\(ws.panes.count)")
        p.preview!.webView.goBack()
        r.check("返回上一頁後 tab 標題改回 design.md", await waitFor(5) { p.headerTitle == "design.md" }, p.headerTitle)
        _ = await waitFor(5) { p.preview?.webView.isLoading == false }
        external.urls.removeAll()
        p.preview!.noteUserClick()
        _ = try? await p.preview!.webView.evaluateJavaScript("document.querySelector('a[href^=\"https\"]').click()")
        r.check("預覽裡點網址：照終端機點連結的規則開啟",
                await waitFor(3) { external.urls == [URL(string: "https://example.com/y")!] }, "\(external.urls)")
        p.preview!.show(gone)
        _ = await waitFor(5) { p.headerTitle == "gone.md" }
        try? FileManager.default.removeItem(at: gone)
        let missingRendered = await waitPreviewJS(p.preview?.webView, "Boolean(document.body?.innerText.includes('檔案已不存在'))")
        r.check("檔案被刪除後顯示「檔案已不存在」，且預覽 tab 仍然留著", missingRendered && ws.panes.contains { $0 === p })
    }

    // MARK: 預覽 tab 上的選單項目（Task 25）
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 上停用只對終端機有意義的功能
    do {
        r.section = "preview-menu"
        let (_, a, p) = previewSetup(c, dir: fx.root, file: design)
        func enabled(_ action: Selector) -> Bool {
            c.validateMenuItem(NSMenuItem(title: "x", action: action, keyEquivalent: ""))
        }
        c.focus(p)
        let off: [(String, Selector)] = [
            ("Find…", #selector(LmuxController.menuFind(_:))),
            ("Find Next", #selector(LmuxController.menuFindNext(_:))),
            ("Find Previous", #selector(LmuxController.menuFindPrevious(_:))),
            ("Undo Send", #selector(LmuxController.menuUndoSend(_:))),
            ("Copy Original Reply", #selector(LmuxController.menuCopyOriginal(_:))),
            ("Ghostty 的字級／Clear Screen", #selector(LmuxController.menuGhosttyBinding(_:))),
        ]
        for (name, sel) in off { r.check("預覽 tab 上停用 \(name)", !enabled(sel)) }
        r.check("預覽 tab 上 Close Pane 仍可用", enabled(#selector(LmuxController.menuClosePane(_:))))
        r.check("預覽 tab 上 Move Tab Right 仍可用", enabled(#selector(LmuxController.menuMoveTabRight(_:))))
        r.check("預覽 tab 上 Split Right 仍可用", enabled(#selector(LmuxController.menuSplitRight(_:))))
        r.check("預覽 tab 上 responder chain 找不到 SurfaceView Paste 目標",
                !(validatedPasteTarget(from: c.window!.firstResponder) is SurfaceView))
        c.paneMouseMoved(p, NSPoint(x: 20, y: 20))
        r.check("預覽 tab 上沒有 Rewind（turnBar）", p.view.overlay.turnBar == nil && c.hoveredTurn(p) == nil)
        c.focus(a)
        r.check("回到終端機 tab：Find… 與 Paste 皆可用",
                enabled(#selector(LmuxController.menuFind(_:))) && validatedPasteTarget(from: c.window!.firstResponder) === a.surface)
    }

    // MARK: 預覽 tab 上的 ConfirmCard 按鍵監聽隔離
    do {
        r.section = "preview-confirm"
        let (ws, _, p) = previewSetup(c, dir: fx.root, file: design)
        let ws2 = c.newWorkspace(cwd: fx.root.path)
        func sendMonitorKey(_ keyCode: UInt16, chars: String) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: c.window!.windowNumber, context: nil,
                                     characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: keyCode)!
            NSApp.sendEvent(e)
        }
        var confirmed = 0, cancelled = 0
        c.focus(p)
        c.showCard(p, message: NSAttributedString(string: "Close?"), detail: "", confirmTitle: "Close",
                   onConfirm: { confirmed += 1 }, onCancel: { cancelled += 1 })
        r.check("預覽 tab 顯示 ConfirmCard 時建立 keyMonitor", p.view.overlay.card?.keyMonitor != nil)
        c.select(ws2)
        sendMonitorKey(0x24, chars: "\r")
        r.check("切到別的 workspace 時按 Return 不會誤觸確認", confirmed == 0 && cancelled == 0 && p.view.overlay.card != nil)
        c.focus(p)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        c.window!.contentView?.addSubview(field)
        c.window!.makeFirstResponder(field)
        sendMonitorKey(0x24, chars: "\r")
        field.removeFromSuperview()
        r.check("焦點在文字輸入框時按 Return 不會誤觸確認", confirmed == 0 && p.view.overlay.card != nil)
        c.focus(p)
        sendMonitorKey(0x35, chars: "\u{1b}")
        r.check("回到預覽 tab 按 Esc 取消卡片並移除 monitor", cancelled == 1 && p.view.overlay.card == nil)
        c.showCard(p, message: NSAttributedString(string: "Close again?"), detail: "", confirmTitle: "Close",
                   onConfirm: { confirmed += 1 }, onCancel: { cancelled += 1 })
        sendMonitorKey(0x24, chars: "\r")
        r.check("預覽 tab 為焦點時按 Return 確認卡片", confirmed == 1 && p.view.overlay.card == nil)
        c.closeWorkspace(ws)
        c.closeWorkspace(ws2)
    }

    // MARK: CLI（Task 26）
    // @feature: preview-tab.feature
    // @scenario: CLI 指定預覽 tab 時回傳錯誤
    do {
        r.section = "preview-cli"
        let (_, a, p) = previewSetup(c, dir: fx.root, file: design)
        let prevExternal = c.allowExternalSendAtLaunch
        c.allowExternalSendAtLaunch = false
        r.check("關閉 external send 時對預覽 tab 送字回傳 externalDenied（不洩漏 tab 類型）",
                c.send(text: "x", toPane: p.id) == .externalDenied)
        let deniedReply = c.handleControl(["cmd": "send", "pane": p.id, "text": "x"])
        r.check("關閉 external send 時控制介面回應拒收而非 not a terminal",
                (deniedReply["ok"] as? Bool) == false && (deniedReply["error"] as? String) != "not a terminal: \(p.id)",
                "\(deniedReply)")
        c.allowExternalSendAtLaunch = prevExternal
        r.check("lmux send 指定預覽 tab：回傳不是終端機", c.send(text: "x", toPane: p.id) == .notTerminal)
        let reply = c.handleControl(["cmd": "send", "pane": p.id, "text": "x"])
        r.check("CLI 的 send 錯誤訊息說明不是終端機", (reply["error"] as? String) == "not a terminal: \(p.id)", "\(reply)")
        let list = c.handleControl(["cmd": "list"])
        let ids = ((list["workspaces"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["panes"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["id"] as? String }
        r.check("lmux list 不列出預覽 tab，仍列出終端機 tab", !ids.contains(p.id) && ids.contains(a.id), "\(ids)")
    }

    // MARK: WorkspacePreviewCoordinator（Task 10b-2）
    // @feature: liquid-glass-app.feature
    // @scenario: 右側 Inspector 即時預覽支援檔案切換、重整與雙軌開啟
    do {
        r.section = "preview-coordinator"
        var prompts: [UntrustedURLPrompt] = []
        UntrustedURLAlert.testHook = { prompts.append($0); return false }
        defer { UntrustedURLAlert.testHook = nil }

        let ws1 = c.newWorkspace(cwd: fx.root.path)
        let ws2 = c.newWorkspace(cwd: fx.root.path)

        let coord = WorkspacePreviewCoordinator(window: c.window)

        // 1. 載入合法檔案
        coord.load(url: design, workspaceID: ws1.id)
        r.check("Coordinator 載入檔案後 workspaceID 與 currentURL 正確",
                coord.workspaceID == ws1.id && coord.currentURL == design && coord.previewView != nil)
        let pv1 = coord.previewView

        // 2. 測試 ↗ 外開：若是合法 Markdown 檔，交給 GhosttyRuntime.openTerminalURL
        prompts.removeAll()
        coord.openCurrentExternally()
        r.check("合法 Markdown 點 ↗ 外開：不觸發拒絕 prompt", prompts.isEmpty)

        // 3. 測試 ↗ 與 openExternal 安全防護：.sh 腳本
        let shScript = fx.root.appendingPathComponent("evil.sh")
        try? "#!/bin/sh\necho hi\n".write(to: shScript, atomically: true, encoding: .utf8)
        coord.openExternalTarget(shScript)
        r.check("openExternal 遇 .sh 腳本被 UntrustedURLAlert 阻擋",
                prompts.contains { prompt in
                    if case .block(let reason, _) = prompt { return reason == .unsafeFile }
                    return false
                },
                "\(prompts)")

        // 4. 拒絕 /dev/zero 與 unsafe scalars
        prompts.removeAll()
        coord.openExternalTarget(URL(fileURLWithPath: "/dev/zero"))
        r.check("openExternal 遇 /dev/zero 被 UntrustedURLAlert 阻擋",
                prompts.contains { prompt in
                    if case .block(let reason, _) = prompt { return reason == .inaccessibleFile }
                    return false
                },
                "\(prompts)")

        prompts.removeAll()
        let unsafeScalarURL = URL(fileURLWithPath: "/tmp/evil\u{202E}txt.md")
        coord.openExternalTarget(unsafeScalarURL)
        r.check("openExternal 遇含 unsafe scalar (U+202E) 路徑被 UntrustedURLAlert 阻擋",
                prompts.contains { prompt in
                    if case .block(let reason, _) = prompt { return reason == .unsafeCharacters }
                    return false
                },
                "\(prompts)")

        coord.load(url: unsafeScalarURL, workspaceID: ws1.id)
        r.check("Coordinator 拒絕載入含 unsafe scalar 的檔案", coord.currentURL == design)

        coord.load(url: URL(fileURLWithPath: "/dev/zero"), workspaceID: ws1.id)
        r.check("Coordinator 拒絕載入非一般／不可預覽檔案 (/dev/zero)", coord.currentURL == design)

        let httpsURL = URL(string: "https://example.com" + design.path)!
        coord.load(url: httpsURL, workspaceID: ws1.id)
        r.check("Coordinator 拒絕載入非 file:// URL", coord.currentURL == design)

        // 同 workspace 內切換候選檔 chip 應保留 WKWebView 瀏覽歷史，讓 ‹ / › 可前後導覽
        if let pv1 {
            pv1.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            c.window!.contentView?.addSubview(pv1)
            _ = await waitFor(5) { pv1.fileURL == design && !pv1.webView.isLoading && pv1.webView.backForwardList.currentItem != nil }
        }
        let chipNext = docs.appendingPathComponent("chip-next.md")
        try? "# Chip Next\n".write(to: chipNext, atomically: true, encoding: .utf8)
        coord.load(url: chipNext, workspaceID: ws1.id)
        r.check("同 workspace 切換候選檔時保留瀏覽歷史並啟用 canGoBack",
                await waitFor(5) { coord.currentURL == chipNext && coord.canGoBack && !(coord.previewView?.webView.isLoading ?? true) },
                "current=\(coord.currentURL?.lastPathComponent ?? "nil") canGoBack=\(coord.canGoBack) backCount=\(coord.previewView?.webView.backForwardList.backList.count ?? -1)")
        pv1?.removeFromSuperview()

        // 5. 切換 workspace 後 backForwardList 清空且舊 PreviewWatcher 停止 (pv1.isClosed == true)
        let page2 = docs.appendingPathComponent("page2.md")
        try? "# Page 2\n".write(to: page2, atomically: true, encoding: .utf8)
        coord.load(url: page2, workspaceID: ws2.id)
        r.check("切換 workspace 後舊 PreviewView 已關閉 (isClosed == true 且 watcher 停止)",
                pv1?.isClosed == true, "pv1.isClosed=\(pv1?.isClosed ?? false)")
        r.check("切換 workspace 後新的 PreviewView backForwardList 為空",
                coord.previewView !== pv1 && coord.previewView?.webView.backForwardList.backList.isEmpty == true)
        r.check("切換 workspace 後 coordinator 狀態更新為新 workspace",
                coord.workspaceID == ws2.id && coord.currentURL == page2)

        // 5b. 直接呼叫 coord.load(url: workspaceID:) 傳入不存在檔案時會關閉舊 PreviewView 並清空狀態 (F24)
        let pv2 = coord.previewView
        let missingForWS1 = docs.appendingPathComponent("missing-\(UUID().uuidString).md")
        coord.load(url: missingForWS1, workspaceID: ws1.id)
        r.check("直接呼叫 coord.load(url: workspaceID:) 傳入無效檔案時關閉舊 PreviewView 並重設狀態",
                pv2 != nil
                && pv2?.isClosed == true
                && coord.workspaceID == ws1.id
                && coord.currentURL == nil
                && coord.previewView == nil,
                "pv2Closed=\(pv2?.isClosed ?? false) ws=\(String(describing: coord.workspaceID)) url=\(String(describing: coord.currentURL)) pv=\(String(describing: coord.previewView))")

        // 6. 導覽歷程：連結跳轉、‹ (goBack)、› (goForward) 與 ↻ (reload)
        let navA = docs.appendingPathComponent("nav-a.md")
        let navB = docs.appendingPathComponent("nav-b.md")
        try? "# Page A\n[Go to B](nav-b.md)\n".write(to: navA, atomically: true, encoding: .utf8)
        try? "# Page B\n".write(to: navB, atomically: true, encoding: .utf8)
        coord.load(url: navA, workspaceID: ws1.id)
        if let pvNav = coord.previewView {
            // Mount in window hierarchy so WKWebView processes navigation & KVO updates reliably in headless runs.
            pvNav.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            c.window!.contentView?.addSubview(pvNav)
            defer { pvNav.removeFromSuperview() }
            _ = await waitFor(5) { pvNav.fileURL == navA && !pvNav.webView.isLoading }
            var hasLink = false
            let linkDeadline = Date().addingTimeInterval(5)
            while Date() < linkDeadline {
                if let res = try? await pvNav.webView.evaluateJavaScript("Boolean(document.querySelector('a[href=\"nav-b.md\"]'))") as? Bool, res {
                    hasLink = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if hasLink {
                pvNav.noteUserClick()
                _ = try? await pvNav.webView.evaluateJavaScript("document.querySelector('a[href=\"nav-b.md\"]').click()")
                _ = await waitFor(5) { coord.currentURL == navB && coord.canGoBack }
            }
            r.check("WorkspacePreviewCoordinator 支援連結跳轉後 canGoBack 響應式啟用", coord.canGoBack && coord.currentURL == navB)
            coord.goBack()
            r.check("WorkspacePreviewCoordinator goBack() 退回上一頁並啟用 canGoForward",
                    await waitFor(5) { coord.currentURL == navA && coord.canGoForward })
            coord.goForward()
            r.check("WorkspacePreviewCoordinator goForward() 前進下一頁",
                    await waitFor(5) { coord.currentURL == navB })
            try? "# Page B\nUpdated on disk\n".write(to: navB, atomically: true, encoding: .utf8)
            coord.reload()
            var reloaded = false
            let reloadDeadline = Date().addingTimeInterval(5)
            while Date() < reloadDeadline {
                if coord.currentURL == navB, !pvNav.webView.isLoading,
                   let txt = try? await pvNav.webView.evaluateJavaScript("document.body.innerText") as? String,
                   txt.contains("Updated on disk") {
                    reloaded = true
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            r.check("WorkspacePreviewCoordinator reload() 重新載入磁碟內容並維持 currentURL", reloaded)

            let savedNavB = (try? String(contentsOf: navB, encoding: .utf8)) ?? "# Page B\n"
            try? FileManager.default.removeItem(at: navB)
            coord.reload()
            let mdShowedMissing = await waitPreviewJS(pvNav.webView, "document.body.innerText.includes('檔案已不存在')")
            try? (savedNavB + "\nRestored after delete\n").write(to: navB, atomically: true, encoding: .utf8)
            coord.reload()
            let mdRecovered = await waitPreviewJS(pvNav.webView, "document.body.innerText.includes('Restored after delete')")

            let navHTML = docs.appendingPathComponent("nav-fallback.html")
            defer { try? FileManager.default.removeItem(at: navHTML) }
            try? "<h1>Initial HTML</h1>".write(to: navHTML, atomically: true, encoding: .utf8)
            coord.load(url: navHTML, workspaceID: ws1.id)
            var htmlFallbackOK = false
            var htmlRecoveredOK = false
            if let pvHTML = coord.previewView {
                pvHTML.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
                c.window!.contentView?.addSubview(pvHTML)
                defer { pvHTML.removeFromSuperview() }
                let loadedInitial = await waitPreviewJS(pvHTML.webView, "document.body.innerText.includes('Initial HTML')", timeout: 10)
                try? FileManager.default.removeItem(at: navHTML)
                coord.reload()
                let becameFallback = await waitFor(10) { pvHTML.isShowingFallbackPage }
                try? "<h1>Restored HTML</h1>".write(to: navHTML, atomically: true, encoding: .utf8)
                coord.reload()
                let loadedRestored = await waitPreviewJS(pvHTML.webView, "document.body.innerText.includes('Restored HTML')", timeout: 10)
                htmlFallbackOK = loadedInitial && becameFallback
                htmlRecoveredOK = loadedRestored && !pvHTML.isShowingFallbackPage
            }
            r.check("WorkspacePreviewCoordinator reload() 透過 PreviewView.reload() 在檔案消失時顯示 fallback 並在恢復後重新載入",
                    mdShowedMissing && mdRecovered && htmlFallbackOK && htmlRecoveredOK,
                    "mdMissing=\(mdShowedMissing) mdRec=\(mdRecovered) htmlFallback=\(htmlFallbackOK) htmlRec=\(htmlRecoveredOK)")
        } else {
            r.check("WorkspacePreviewCoordinator 支援連結跳轉後 canGoBack 響應式啟用", false)
            r.check("WorkspacePreviewCoordinator goBack() 退回上一頁並啟用 canGoForward", false)
            r.check("WorkspacePreviewCoordinator goForward() 前進下一頁", false)
            r.check("WorkspacePreviewCoordinator reload() 不改變 currentURL 且可重載", false)
        }

        // 7. ensureFocus() 與 showInspectorTab() 切換分頁離開 .preview 時歸還焦點
        c.select(ws1)
        c.model.inspectorVisible = true
        c.model.inspectorTab = .preview
        c.openInInspectorPreview(design, workspace: ws1)
        if let pv = c.previewCoordinator.previewView {
            c.window!.contentView?.addSubview(pv)
            c.window!.makeFirstResponder(pv.webView)
            c.ensureFocus()
            r.check("ensureFocus() 在 inspectorPreview 焦點位於 WKWebView 時保留焦點",
                    c.window!.firstResponder === pv.webView || (c.window!.firstResponder as? NSView)?.isDescendant(of: pv.webView) == true,
                    "firstResponder=\(String(describing: c.window!.firstResponder))")

            // 透過 controller.showInspectorTab(.diff) 離開 .preview：自動歸還焦點至終端機 pane
            c.showInspectorTab(.diff)
            r.check("showInspectorTab(.diff) 切離 inspectorPreview 後自動將焦點交還給終端機 pane",
                    c.window!.firstResponder === ws1.panes[0].surface)
            pv.removeFromSuperview()
        }

        // 背景 workspace 呼叫 openInInspectorPreview 不干擾前景 coordinator；onFileChange 同步記錄至 inspectorPreviewURLByWorkspace
        c.select(ws1)
        c.openInInspectorPreview(design, workspace: ws1)
        c.openInInspectorPreview(page2, workspace: ws2)
        r.check("背景 workspace openInInspectorPreview 不覆寫前景 previewCoordinator",
                c.previewCoordinator.workspaceID == ws1.id
                && c.previewCoordinator.currentURL == design
                && c.model.inspectorPreviewURLByWorkspace[ws2.id] == page2)
        let navigatedNote = docs.appendingPathComponent("nav-callback.md")
        try? "# Callback\n".write(to: navigatedNote, atomically: true, encoding: .utf8)
        c.previewCoordinator.onFileChange?(navigatedNote)
        r.check("previewCoordinator.onFileChange 同步寫回 inspectorPreviewURLByWorkspace",
                c.model.inspectorPreviewURLByWorkspace[ws1.id] == navigatedNote)

        coord.switchWorkspace(to: ws2.id, targetURL: nil)
        r.check("switchWorkspace(to:) 未指定 targetURL 時同步清空 currentURL 與 previewView",
                coord.currentURL == nil && coord.previewView == nil && !coord.canGoBack && !coord.canGoForward)

        coord.closeCurrent()
        c.closeWorkspace(ws1)
        c.closeWorkspace(ws2)
    }
}
