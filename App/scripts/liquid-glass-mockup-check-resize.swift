// @feature: liquid-glass-redesign-mockup.feature
// @scenario: 拖曳調整面板寬度時停用全部毛玻璃模糊並在放開後恢復
// @scenario: 水平拖曳調寬受最小與最大寬度限制
// @scenario: 垂直拖曳調整通知 bar 高度並在拉到過低時自動收合

import AppKit
import WebKit

extension LiquidGlassMockupCheck {
    @MainActor static func resizeChecks() async {
        let (web, win) = makeWebView()
        defer { win.close() }
        guard await loadMockup(web, in: win) else {
            check("拖曳檢查載入 preview-mockup.html", false)
            return
        }

        // 在 WebKit 中透過 PointerEvent 驅動 setupResize / setupInboxResize 驗證真實計算樣式與寬高變化。
        let helpersJS = """
        window.__testDragStart = (id, x, y) => {
          const el = document.getElementById(id);
          el.dispatchEvent(new PointerEvent('pointerdown', { pointerId: 1, clientX: x, clientY: y, bubbles: true }));
        };
        window.__testDragMove = (id, x, y) => {
          const el = document.getElementById(id);
          el.dispatchEvent(new PointerEvent('pointermove', { pointerId: 1, clientX: x, clientY: y, bubbles: true }));
        };
        window.__testDragEnd = (id, x, y) => {
          const el = document.getElementById(id);
          el.dispatchEvent(new PointerEvent('pointerup', { pointerId: 1, clientX: x, clientY: y, bubbles: true }));
        };
        window.__isRGBA = (color, er, eg, eb, minA, maxA) => {
          const m = color.match(/^rgba?\\(\\s*(\\d+),\\s*(\\d+),\\s*(\\d+)(?:,\\s*([\\d.]+))?\\s*\\)$/);
          if (!m) return false;
          const a = m[4] === undefined ? 1 : parseFloat(m[4]);
          return Number(m[1]) === er && Number(m[2]) === eg && Number(m[3]) === eb && a >= minA && a <= maxA;
        };
        window.__allBothBackdropNone = (selectors) => {
          return selectors.every(sel => {
            const el = document.querySelector(sel);
            if (!el) return false;
            const cs = getComputedStyle(el);
            const stdNone = !cs.backdropFilter || cs.backdropFilter === 'none';
            const wkNone = !cs.webkitBackdropFilter || cs.webkitBackdropFilter === 'none';
            return stdNone && wkNone;
          });
        };
        true;
        """
        _ = await js(web, helpersJS)

        // 檢查樣式表內的 body.is-resizing 使用 .sidebar-inbox-accessory 而非過時的 .inbox-accessory-panel
        let resizeSelectorOK = await jsBool(web, """
        (() => {
          const rules = Array.from(document.styleSheets[0]?.cssRules || []);
          const allText = rules.map(r => r.selectorText || '').join(',');
          return allText.includes('body.is-resizing .sidebar-inbox-accessory') &&
                 !allText.includes('.inbox-accessory-panel');
        })()
        """)
        check("樣式表 body.is-resizing 使用 .sidebar-inbox-accessory 且無舊 selector", resizeSelectorOK)

        // 1. 預設即時預覽分頁拖曳 sidebar：10 個現有 DOM 玻璃圖層雙重 backdrop-filter 皆為 none、過渡停用、游標 col-resize、淺色左右側底色皆正確
        _ = await js(web, "window.__testDragStart('handle-left', 260, 200); window.__testDragMove('handle-left', 310, 200); true")
        let previewLayersDisabled = await jsBool(web, """
        document.body.classList.contains('is-resizing') &&
        window.__allBothBackdropNone([
          '.mockup-controls', '.lmux-window', '.titlebar', '.sidebar-left',
          '.sidebar-right', '#sidebar-inbox', '.window-footer', '.terminal-pane',
          '.preview-browser-card', '.preview-viewport-card'
        ])
        """)
        check("拖曳期間即時預覽分頁全部 10 個玻璃圖層的雙重 backdrop-filter 皆為 none", previewLayersDisabled)

        let transitionAndCursorOK = await jsBool(web, """
        (() => {
          const sb = getComputedStyle(document.getElementById('sidebar-left'));
          const bodyCursor = getComputedStyle(document.body).cursor;
          return (sb.transitionProperty === 'none' || sb.transitionDuration === '0s') && bodyCursor === 'col-resize';
        })()
        """)
        check("水平拖曳期間停用過渡動畫且游標為 col-resize", transitionAndCursorOK)

        let lightSidebarsBGOK = await jsBool(web, """
        window.__isRGBA(getComputedStyle(document.getElementById('sidebar-left')).backgroundColor, 245, 247, 252, 0.97, 0.99) &&
        window.__isRGBA(getComputedStyle(document.getElementById('sidebar-right')).backgroundColor, 245, 247, 252, 0.97, 0.99)
        """)
        check("淺色主題拖曳期間左右面板皆維持淺色實底（非深色底）", lightSidebarsBGOK)

        let movedWidth = (await js(web, "parseFloat(document.getElementById('sidebar-left').style.width)") as? NSNumber)?.doubleValue ?? 0
        check("拖曳期間 sidebar 寬度隨指標移動更新（260 -> ~310）", abs(movedWidth - 310) <= 2, "width=\(movedWidth)")

        _ = await js(web, "window.__testDragEnd('handle-left', 310, 200); true")
        let blurAndCursorRestored = await jsBool(web, """
        (() => {
          if (document.body.classList.contains('is-resizing')) return false;
          const cs = getComputedStyle(document.getElementById('sidebar-left'));
          const hasBlur = (cs.backdropFilter && cs.backdropFilter !== 'none') ||
                          (cs.webkitBackdropFilter && cs.webkitBackdropFilter !== 'none');
          return hasBlur && getComputedStyle(document.body).cursor !== 'col-resize';
        })()
        """)
        check("放開指標後離開 .is-resizing、恢復毛玻璃模糊與游標", blurAndCursorRestored)

        // 切至 trace 分頁驗證 .inspector-card 在拖曳時也停用模糊，並測深色模式拖曳實底
        _ = await js(web, "switchRightTab('trace'); setTheme('dark'); window.__testDragStart('handle-right', 1120, 200); true")
        let inspectorCardAndDarkOK = await jsBool(web, """
        window.__allBothBackdropNone(['.inspector-card']) &&
        window.__isRGBA(getComputedStyle(document.getElementById('sidebar-left')).backgroundColor, 18, 22, 30, 0.97, 0.99) &&
        window.__isRGBA(getComputedStyle(document.getElementById('sidebar-right')).backgroundColor, 18, 22, 30, 0.97, 0.99)
        """)
        check("執行記錄分頁的 .inspector-card 拖曳時停用模糊，且深色主題維持深色實底", inspectorCardAndDarkOK)
        _ = await js(web, "window.__testDragEnd('handle-right', 1120, 200); setTheme('light'); switchRightTab('preview'); true")

        // 2. 左右寬度上下限夾緊（左 180-400，右 240-500）
        _ = await js(web, "window.__testDragStart('handle-left', 310, 200); window.__testDragMove('handle-left', 10, 200); window.__testDragEnd('handle-left', 10, 200); true")
        let leftMin = (await js(web, "parseFloat(document.getElementById('sidebar-left').style.width)") as? NSNumber)?.doubleValue ?? 0
        check("sidebar 往左超過下限時夾緊於 180px", leftMin == 180, "width=\(leftMin)")

        _ = await js(web, "window.__testDragStart('handle-left', 180, 200); window.__testDragMove('handle-left', 900, 200); window.__testDragEnd('handle-left', 900, 200); true")
        let leftMax = (await js(web, "parseFloat(document.getElementById('sidebar-left').style.width)") as? NSNumber)?.doubleValue ?? 0
        check("sidebar 往右超過上限時夾緊於 400px", leftMax == 400, "width=\(leftMax)")

        _ = await js(web, "window.__testDragStart('handle-right', 1100, 200); window.__testDragMove('handle-right', 200, 200); window.__testDragEnd('handle-right', 200, 200); true")
        let rightMax = (await js(web, "parseFloat(document.getElementById('sidebar-right').style.width)") as? NSNumber)?.doubleValue ?? 0
        check("右側 Inspector 往左超過上限時夾緊於 500px", rightMax == 500, "width=\(rightMax)")

        _ = await js(web, "window.__testDragStart('handle-right', 900, 200); window.__testDragMove('handle-right', 1400, 200); window.__testDragEnd('handle-right', 1400, 200); true")
        let rightMin = (await js(web, "parseFloat(document.getElementById('sidebar-right').style.width)") as? NSNumber)?.doubleValue ?? 0
        check("右側 Inspector 往右超過下限時夾緊於 240px", rightMin == 240, "width=\(rightMin)")

        // 3. 通知 bar 垂直拖曳：游標 row-resize、往上增高夾緊 340px、往下拖至 <= 42px 自動收合並清除 resizing-row
        _ = await js(web, "window.__testDragStart('handle-inbox', 100, 600); window.__testDragMove('handle-inbox', 100, 200); true")
        let inboxMaxOK = await jsBool(web, """
        document.body.classList.contains('is-resizing') &&
        document.body.classList.contains('resizing-row') &&
        getComputedStyle(document.body).cursor === 'row-resize' &&
        parseFloat(document.getElementById('sidebar-inbox').style.height) === 340
        """)
        check("通知 bar 向上拖曳游標為 row-resize 且高度夾緊於 340px 上限", inboxMaxOK)

        _ = await js(web, "window.__testDragMove('handle-inbox', 100, 950); window.__testDragEnd('handle-inbox', 100, 950); true")
        let inboxAutoCollapsed = await jsBool(web, """
        document.getElementById('sidebar-inbox').classList.contains('collapsed') &&
        !document.body.classList.contains('is-resizing') &&
        !document.body.classList.contains('resizing-row')
        """)
        check("通知 bar 拖曳至 <= 42px 自動收合且清除 resizing-row 並恢復模糊", inboxAutoCollapsed)
    }
}
