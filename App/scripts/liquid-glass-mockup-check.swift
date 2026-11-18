// @feature: liquid-glass-redesign-mockup.feature
// @scenario: 預設顯示淺色主題並可在淺色與深色之間切換
//
// 使用螢幕外 macOS WKWebView 驗證 preview-mockup.html 的外觀、DOM 互動與 CSS 計算樣式。
// 執行方式：beat/changes/preview-liquid-glass/dev.sh check

import AppKit
import Foundation
import WebKit

@main
enum LiquidGlassMockupCheck {
    @MainActor static var failures = 0

    @MainActor static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  -- \(detail)")")
    }

    @MainActor static func js(_ web: WKWebView, _ code: String) async -> Any? {
        do {
            return try await web.evaluateJavaScript(code)
        } catch {
            fputs("JS ERROR: \(error)\nCODE: \(code)\n", stderr)
            return nil
        }
    }

    @MainActor static func jsString(_ web: WKWebView, _ code: String) async -> String? {
        await js(web, code) as? String
    }

    @MainActor static func jsBool(_ web: WKWebView, _ code: String) async -> Bool {
        if let b = await js(web, code) as? Bool { return b }
        if let n = await js(web, code) as? NSNumber { return n.boolValue }
        return false
    }

    @MainActor static func waitJS(
        _ web: WKWebView,
        _ code: String,
        _ seconds: Double = 6,
        where pred: (Any?) -> Bool
    ) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if pred(await js(web, code)) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return pred(await js(web, code))
    }

    static var mockupURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("preview-mockup.html")
    }

    @MainActor static func makeWebView() -> (WKWebView, NSWindow) {
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 960), configuration: config)
        let win = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 1440, height: 960),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        web.frame = win.contentView!.bounds
        win.contentView!.addSubview(web)
        return (web, win)
    }

    @MainActor static func loadMockup(_ web: WKWebView, in win: NSWindow) async -> Bool {
        _ = win
        let url = mockupURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            fputs("MOCKUP FILE NOT FOUND: \(url.path)\n", stderr)
            return false
        }
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return await waitJS(web, "document.readyState === 'complete' && !!document.getElementById('window-frame')") {
            ($0 as? Bool) == true || ($0 as? NSNumber)?.boolValue == true
        }
    }

    @MainActor static func withLoadedMockup(
        _ loadLabel: String,
        reportSuccess: Bool = false,
        _ body: (WKWebView) async -> Void
    ) async {
        let (web, win) = makeWebView()
        defer { win.close() }
        let loaded = await loadMockup(web, in: win)
        if reportSuccess || !loaded {
            check(loadLabel, loaded)
        }
        guard loaded else { return }
        await body(web)
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await themeChecks()
            await styleChecks()
            await panelChecks()
            await resizeChecks()
            await inboxChecks()
            await inspectorChecks()
            print(failures == 0 ? "MOCKUP CHECK: ok" : "MOCKUP CHECK: FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            print("MOCKUP CHECK: FAILED (timeout)")
            exit(2)
        }
        app.run()
    }

    @MainActor static func themeChecks() async {
        await withLoadedMockup("載入 preview-mockup.html 完成", reportSuccess: true) { web in
            let initialTheme = await jsString(web, "document.body.getAttribute('data-theme')") ?? ""
            let lightInitiallyActive = await jsBool(web, "document.getElementById('btn-theme-light').classList.contains('active')")
            check("預設為淺色主題且淺色鈕亮起", initialTheme == "light" && lightInitiallyActive, "theme=\(initialTheme)")

            _ = await js(web, "document.getElementById('btn-theme-dark').click(); true")
            let darkTheme = await jsString(web, "document.body.getAttribute('data-theme')") ?? ""
            let darkActive = await jsBool(web, "document.getElementById('btn-theme-dark').classList.contains('active')")
            let lightInactive = await jsBool(web, "!document.getElementById('btn-theme-light').classList.contains('active')")
            check("點擊深色主題鈕切換為 dark 並更新按鈕亮起狀態", darkTheme == "dark" && darkActive && lightInactive, "theme=\(darkTheme)")

            _ = await js(web, "document.getElementById('btn-theme-light').click(); true")
            let backTheme = await jsString(web, "document.body.getAttribute('data-theme')") ?? ""
            let backLightActive = await jsBool(web, "document.getElementById('btn-theme-light').classList.contains('active')")
            let darkInactive = await jsBool(web, "!document.getElementById('btn-theme-dark').classList.contains('active')")
            check("再點擊淺色主題鈕恢復為 light", backTheme == "light" && backLightActive && darkInactive, "theme=\(backTheme)")
        }
    }
}
