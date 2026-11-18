// @feature: liquid-glass-redesign-mockup.feature
// @scenario: 點 sidebar 的 workspace 列切換選取狀態
// @scenario: 點未讀通知卡片標記已讀並選取對應 workspace
// @scenario: 點已讀通知卡片仍選取對應 workspace 且不扣減未讀數

import AppKit
import WebKit

extension LiquidGlassMockupCheck {
    @MainActor static func inboxChecks() async {
        let (web, win) = makeWebView()
        defer { win.close() }
        guard await loadMockup(web, in: win) else {
            check("通知 bar 檢查載入 preview-mockup.html", false)
            return
        }

        // 1. 點擊第二個 workspace 列應成為唯一選取狀態
        _ = await js(web, "document.querySelectorAll('.ws-row')[1].click(); true")
        let wsSelectedOK = await jsBool(web, """
        (() => {
          const rows = Array.from(document.querySelectorAll('.ws-row'));
          const selected = rows.filter(r => r.classList.contains('selected'));
          return selected.length === 1 && selected[0] === rows[1];
        })()
        """)
        check("點擊 workspace 列後僅該列保持選取狀態", wsSelectedOK)

        // 切回第一個 workspace 再測 Inbox 連動
        _ = await js(web, "document.querySelectorAll('.ws-row')[0].click(); true")

        // 2. 點擊第 1 張未讀通知卡片（web-client-auth）：變已讀、徽章 2 -> 1、紅點仍顯示、選取 web-client-auth
        let initialBadge = await jsString(web, "document.getElementById('inbox-badge').textContent") ?? ""
        check("初始未讀徽章數字為 2", initialBadge == "2", "badge=\(initialBadge)")

        _ = await js(web, "document.getElementById('inbox-card-1').click(); true")
        let afterFirstCard = await jsBool(web, """
        (() => {
          const card = document.getElementById('inbox-card-1');
          const badge = document.getElementById('inbox-badge');
          const dot = document.getElementById('inbox-dot-indicator');
          const selectedTitle = document.querySelector('.ws-row.selected .ws-title')?.textContent?.trim();
          return card.classList.contains('read') &&
                 !card.classList.contains('unread') &&
                 badge.textContent === '1' &&
                 getComputedStyle(badge).display !== 'none' &&
                 getComputedStyle(dot).display !== 'none' &&
                 selectedTitle === 'web-client-auth';
        })()
        """)
        check("點擊第一張未讀卡片標記已讀、徽章減為 1 且選取 web-client-auth", afterFirstCard)

        // 3. 點擊第 3 張已讀卡片（lmux-glass-design）：未讀數維持 1，但選取切換至 lmux-glass-design
        _ = await js(web, "document.getElementById('inbox-card-3').click(); true")
        let afterReadCard = await jsBool(web, """
        (() => {
          const badge = document.getElementById('inbox-badge');
          const selectedTitle = document.querySelector('.ws-row.selected .ws-title')?.textContent?.trim();
          return badge.textContent === '1' && selectedTitle === 'lmux-glass-design';
        })()
        """)
        check("點擊已讀卡片不重複扣減未讀數，仍選取 lmux-glass-design", afterReadCard)

        // 4. 點擊第 2 張未讀卡片（api-gateway）：未讀歸零並隱藏徽章與紅點
        _ = await js(web, "document.getElementById('inbox-card-2').click(); true")
        let afterAllRead = await jsBool(web, """
        (() => {
          const badge = document.getElementById('inbox-badge');
          const dot = document.getElementById('inbox-dot-indicator');
          const selectedTitle = document.querySelector('.ws-row.selected .ws-title')?.textContent?.trim();
          return document.querySelectorAll('.inbox-card.unread').length === 0 &&
                 getComputedStyle(badge).display === 'none' &&
                 getComputedStyle(dot).display === 'none' &&
                 selectedTitle === 'api-gateway';
        })()
        """)
        check("點擊最後一張未讀卡片後全部已讀、徽章與紅點隱藏且選取 api-gateway", afterAllRead)
    }
}
