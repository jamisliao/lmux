// @feature: liquid-glass-redesign-mockup.feature
// @scenario: 用按鈕或快捷鍵收合與展開 sidebar 及右側 Inspector
// @scenario: 透過摘要列、雙擊手把或頂部控制列切換通知 bar 收合與展開

import AppKit
import WebKit

extension LiquidGlassMockupCheck {
    @MainActor static func panelChecks() async {
        await withLoadedMockup("面板收合檢查載入 preview-mockup.html") { web in

        // 1. 左側 sidebar 三種切換入口：標題列鈕、頂部控制列鈕、快捷鍵 Cmd+B
        let leftEntries: [(String, String)] = [
            ("標題列左側欄鈕", "document.getElementById('tb-toggle-left').click()"),
            ("頂部控制列左側欄鈕", "document.querySelector(\".mockup-controls button[onclick=\\\"toggleSidebar('left')\\\"]\").click()"),
            ("快捷鍵 ⌘B", "window.dispatchEvent(new KeyboardEvent('keydown', { key: 'b', code: 'KeyB', metaKey: true, bubbles: true, cancelable: true }))")
        ]
        for (label, script) in leftEntries {
            _ = await js(web, "\(script); true")
            let collapsed = await jsBool(web, "document.getElementById('sidebar-left').classList.contains('collapsed') && !document.getElementById('tb-toggle-left').classList.contains('active')")
            check("sidebar 透過「\(label)」收合且標題列鈕取消亮起", collapsed)

            _ = await js(web, "\(script); true")
            let expanded = await jsBool(web, "!document.getElementById('sidebar-left').classList.contains('collapsed') && document.getElementById('tb-toggle-left').classList.contains('active')")
            check("sidebar 透過「\(label)」恢復展開且標題列鈕亮起", expanded)
        }

        // 2. 右側 Inspector 四種切換入口（含 macOS Option+Cmd+B 送出 key:'∫' 時依 code:'KeyB' 辨識）
        let rightEntries: [(String, String)] = [
            ("標題列右側欄鈕", "document.getElementById('tb-toggle-right').click()"),
            ("頂部控制列右側欄鈕", "document.querySelector(\".mockup-controls button[onclick=\\\"toggleSidebar('right')\\\"]\").click()"),
            ("視窗底部狀態列 ⌥⌘B 鈕", "document.querySelector(\"#terminal-footer button[onclick=\\\"toggleSidebar('right')\\\"]\").click()"),
            ("快捷鍵 ⌥⌘B（key: 'b'）", "window.dispatchEvent(new KeyboardEvent('keydown', { key: 'b', code: 'KeyB', metaKey: true, altKey: true, bubbles: true, cancelable: true }))"),
            ("快捷鍵 ⌥⌘B（macOS Option 送出 '∫'）", "window.dispatchEvent(new KeyboardEvent('keydown', { key: '∫', code: 'KeyB', metaKey: true, altKey: true, bubbles: true, cancelable: true }))")
        ]
        for (label, script) in rightEntries {
            _ = await js(web, "\(script); true")
            let collapsed = await jsBool(web, "document.getElementById('sidebar-right').classList.contains('collapsed') && !document.getElementById('tb-toggle-right').classList.contains('active')")
            check("右側 Inspector 透過「\(label)」收合且標題列鈕取消亮起", collapsed)

            _ = await js(web, "\(script); true")
            let expanded = await jsBool(web, "!document.getElementById('sidebar-right').classList.contains('collapsed') && document.getElementById('tb-toggle-right').classList.contains('active')")
            check("右側 Inspector 透過「\(label)」恢復展開且標題列鈕亮起", expanded)
        }

        // 3. 通知 bar 收合與展開：摘要列 ↔ 摘要列、摘要列 ↔ 雙擊手把、頂部 Inbox 鈕 ↔ 頂部 Inbox 鈕
        let inboxPairs: [(String, String, String)] = [
            (
                "摘要列 → 摘要列",
                "document.querySelector('.inbox-summary-row').click()",
                "document.querySelector('.inbox-summary-row').click()"
            ),
            (
                "摘要列 → 雙擊調整手把",
                "document.querySelector('.inbox-summary-row').click()",
                "document.getElementById('handle-inbox').dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))"
            ),
            (
                "頂部控制列 Inbox 鈕 → 頂部控制列 Inbox 鈕",
                "document.querySelector(\".mockup-controls button[onclick=\\\"toggleInboxCollapse()\\\"]\").click()",
                "document.querySelector(\".mockup-controls button[onclick=\\\"toggleInboxCollapse()\\\"]\").click()"
            )
        ]
        for (label, collapseJS, expandJS) in inboxPairs {
            _ = await js(web, "\(collapseJS); true")
            let isCollapsed = await jsBool(web, "document.getElementById('sidebar-inbox').classList.contains('collapsed')")
            check("通知 bar（\(label)）收合成功", isCollapsed)

            _ = await js(web, "\(expandJS); true")
            let isExpanded = await jsBool(web, """
            !document.getElementById('sidebar-inbox').classList.contains('collapsed') &&
            document.getElementById('sidebar-inbox').style.height === '175px'
            """)
            check("通知 bar（\(label)）恢復展開並回到 175px", isExpanded)
        }
        }
    }
}
