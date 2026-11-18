// @feature: liquid-glass-redesign-mockup.feature
// @scenario: 在右側 Inspector 切換三個分頁、切換預覽範例檔與重新整理
// @scenario: 點視窗底部狀態列各區塊自動展開右側 Inspector 並切到對應分頁

import AppKit
import WebKit

extension LiquidGlassMockupCheck {
    @MainActor static func inspectorChecks() async {
        let (web, win) = makeWebView()
        defer { win.close() }
        guard await loadMockup(web, in: win) else {
            check("右側 Inspector 檢查載入 preview-mockup.html", false)
            return
        }

        // 1. 切換 Markdown / Swift 範例、按重新整理 ↻（驗證缺陷 #5）並驗證外部開啟 ↗ 按鈕
        _ = await js(web, "document.querySelectorAll('.preview-file-chip')[1].click(); true")
        let mdOK = await jsBool(web, """
        document.getElementById('preview-url-text').innerText === 'README.md' &&
        document.getElementById('preview-viewport-content').innerText.includes('light mux (lmux)')
        """)
        check("即時預覽切換至 Markdown 顯示 README.md", mdOK)

        _ = await js(web, "document.querySelectorAll('.preview-file-chip')[2].click(); true")
        let swiftOK = await jsBool(web, """
        document.getElementById('preview-url-text').innerText === 'App/Sources/LmuxUI/GlassTokens.swift' &&
        document.getElementById('preview-viewport-content').innerText.includes('GlassMaterialTokens') &&
        document.getElementById('preview-viewport-content').innerText.includes('40.0')
        """)
        check("即時預覽切換至 Swift 顯示 GlassTokens.swift（40.0）", swiftOK)

        // 點擊重新整理鈕 ↻ 應回到 preview-mockup.html 且第 0 顆 HTML 範例鈕亮起
        _ = await js(web, "document.querySelector(\"button[title='重新整理預覽']\").click(); true")
        let refreshOK = await jsBool(web, """
        (() => {
          const chips = document.querySelectorAll('.preview-file-chip');
          return document.getElementById('preview-url-text').innerText === 'preview-mockup.html' &&
                 chips[0].classList.contains('active') &&
                 !chips[1].classList.contains('active') &&
                 !chips[2].classList.contains('active');
        })()
        """)
        check("點擊預覽重新整理 ↻ 回到 HTML 並同步亮起 HTML 範例鈕", refreshOK)

        // 驗證外部開啟 ↗ 按鈕存在且呼叫 window.open(window.location.href, '_blank')
        let extOpenOK = await jsBool(web, """
        (() => {
          const origOpen = window.open;
          let captured = null;
          window.open = (url, target) => { captured = { url, target }; return null; };
          try {
            document.querySelector("button[title='在系統預設瀏覽器中開啟']")?.click();
          } finally {
            window.open = origOpen;
          }
          return !!(captured && captured.url === window.location.href && captured.target === '_blank');
        })()
        """)
        check("點擊即時預覽外部開啟 ↗ 按鈕於新分頁開啟目前網址", extOpenOK)

        // 2. 切換 變更 (Diff) 與 執行記錄 分頁，並確認渲染出的 .activity-bash 具備實體底色
        _ = await js(web, "document.querySelector(\".segment-btn[data-tab='diff']\").click(); true")
        let diffOK = await jsBool(web, """
        document.querySelector(\".segment-btn[data-tab='diff']\").classList.contains('active') &&
        document.getElementById('tab-content-context').textContent.includes('Git 變更狀態')
        """)
        check("右側 Inspector 切換至「變更 (Diff)」分頁", diffOK)

        _ = await js(web, "document.querySelector(\".segment-btn[data-tab='trace']\").click(); true")
        let traceOK = await jsBool(web, """
        (() => {
          const bashEl = document.querySelector('.activity-bash');
          const bashBg = bashEl ? getComputedStyle(bashEl).backgroundColor : '';
          const txt = document.getElementById('tab-content-context').textContent || '';
          return document.querySelector(\".segment-btn[data-tab='trace']\").classList.contains('active') &&
                 txt.includes('Context Window') &&
                 txt.includes('bash') &&
                 bashBg !== '' && bashBg !== 'rgba(0, 0, 0, 0)' && bashBg !== 'transparent';
        })()
        """)
        check("右側 Inspector 切換至「執行記錄」分頁且 .activity-bash 具備實體底色", traceOK)

        // 3. 先切至非目標分頁並收合右側 Inspector，再從視窗底部狀態列 5 個區塊觸發展開並切換分頁
        let footerTargets: [(String, String, String)] = [
            ("agent 模型徽章", ".footer-agent-badge", "trace"),
            ("最近工具呼叫區塊", ".footer-live-action", "trace"),
            ("Context Window 區塊", ".footer-section-center", "trace"),
            ("Git 變更統計徽章", ".footer-git-badge", "diff"),
            ("即時預覽快捷鈕", "#terminal-footer button[onclick=\\\"openRightPanel('preview')\\\"]", "preview")
        ]
        for (label, selector, expectedTab) in footerTargets {
            let otherTab = expectedTab == "trace" ? "preview" : "trace"
            _ = await js(web, "switchRightTab('\(otherTab)'); if (!document.getElementById('sidebar-right').classList.contains('collapsed')) toggleSidebar('right'); true")
            _ = await js(web, "document.querySelector(\"\(selector)\").click(); true")
            let opened = await jsBool(web, """
            !document.getElementById('sidebar-right').classList.contains('collapsed') &&
            document.getElementById('tb-toggle-right').classList.contains('active') &&
            document.querySelector(".segment-btn[data-tab='\(expectedTab)']").classList.contains('active')
            """)
            check("點擊底部狀態列「\(label)」自動展開右側 Inspector 並切至 \(expectedTab)", opened)
        }
    }
}
