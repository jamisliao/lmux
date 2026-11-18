// @feature: liquid-glass-redesign-mockup.feature
// @scenario: 系統開啟減少透明度時停用全部毛玻璃模糊
// @scenario: 系統開啟減少動態效果時縮短動畫與過渡時間

import AppKit
import WebKit

extension LiquidGlassMockupCheck {
    @MainActor static func styleChecks() async {
        await withLoadedMockup("樣式檢查載入 preview-mockup.html") { web in

        // 1. 檢查 <style> 剝除註解後的大括號平衡與 .ctrl-pill-btn:hover 無重複規則（對應缺陷 #1）
        let braceBalanceOK = await jsBool(web, """
        (() => {
          const css = (document.querySelector('style')?.textContent || '').replace(/\\/\\*[\\s\\S]*?\\*\\//g, '');
          let depth = 0;
          for (const ch of css) {
            if (ch === '{') depth++;
            else if (ch === '}') depth--;
            if (depth < 0) return false;
          }
          return depth === 0;
        })()
        """)
        check("樣式表大括號平衡且無孤立閉合括號", braceBalanceOK)

        let hoverRuleCount = (await js(web, """
        (() => {
          const rules = Array.from(document.styleSheets[0]?.cssRules || []);
          return rules.filter(r => r.selectorText === '.ctrl-pill-btn:hover').length;
        })()
        """) as? NSNumber)?.intValue ?? -1
        check(".ctrl-pill-btn:hover 規則不重複（僅 1 條）", hoverRuleCount == 1, "count=\(hoverRuleCount)")

        // 2. 檢查四個主玻璃容器獨立規則區塊皆包含 -webkit-backdrop-filter，且三張內層卡片使用 --glass-blur-card（對應缺陷 #2）
        let webkitAndCardTokenOK = await jsBool(web, """
        (() => {
          const raw = (document.querySelector('style')?.textContent || '').replace(/\\/\\*[\\s\\S]*?\\*\\//g, '');
          for (const sel of ['.lmux-window', '.titlebar', '.sidebar-left', '.sidebar-right']) {
            const re = new RegExp('(?:^|\\\\})\\\\s*' + sel.replace('.', '\\\\.') + '\\\\s*\\\\{([^}]*)\\\\}');
            const m = raw.match(re);
            if (!m || !m[1].includes('-webkit-backdrop-filter')) return false;
          }
          for (const card of ['.inspector-card', '.preview-browser-card', '.preview-viewport-card']) {
            const re = new RegExp('(?:^|\\\\})\\\\s*' + card.replace('.', '\\\\.') + '\\\\s*\\\\{([^}]*)\\\\}');
            const m = raw.match(re);
            if (!m || !m[1].includes('var(--glass-blur-card)')) return false;
          }
          return true;
        })()
        """)
        check("主玻璃容器含 -webkit-backdrop-filter 且內層卡片使用 --glass-blur-card", webkitAndCardTokenOK)

        // 3. 檢查 @media (prefers-reduced-transparency: reduce) 涵蓋全部 11 個玻璃圖層、雙屬性 none、變數歸零與深淺色實底（對應缺陷 #2）
        let reducedTransOK = await jsBool(web, """
        (() => {
          const rules = Array.from(document.styleSheets[0]?.cssRules || []);
          const media = rules.find(r => r.conditionText && r.conditionText.includes('prefers-reduced-transparency'));
          if (!media) return false;
          const inner = Array.from(media.cssRules);
          const required = [
            '.lmux-window', '.sidebar-left', '.sidebar-right', '.sidebar-inbox-accessory',
            '.titlebar', '.mockup-controls', '.window-footer', '.terminal-pane',
            '.inspector-card', '.preview-browser-card', '.preview-viewport-card'
          ];
          const allText = inner.map(r => r.cssText || '').join('\\n');
          if (allText.includes('.inbox-accessory-panel')) return false;

          const disableRule = inner.find(r => {
            const sel = r.selectorText || '';
            return required.every(s => sel.includes(s));
          });
          if (!disableRule) return false;
          const disablesBoth =
            disableRule.style.getPropertyValue('backdrop-filter') === 'none' &&
            disableRule.style.getPropertyPriority('backdrop-filter') === 'important' &&
            ((disableRule.style.getPropertyValue('-webkit-backdrop-filter') === 'none' &&
              disableRule.style.getPropertyPriority('-webkit-backdrop-filter') === 'important') ||
             /-webkit-backdrop-filter:\\s*none\\s*!important/i.test(disableRule.cssText || ''));

          const resetRule = inner.find(r => (r.selectorText || '').includes(':root') && (r.selectorText || '').includes('[data-theme="light"]'));
          const resetsTokens = !!(resetRule &&
            ['--glass-blur', '--glass-blur-subtle', '--glass-blur-card'].every(prop =>
              resetRule.style.getPropertyValue(prop).trim() === 'none' &&
              resetRule.style.getPropertyPriority(prop) === 'important'
            ));

          const darkSolid = inner.some(r =>
            r.selectorText && !r.selectorText.includes('[data-theme="light"]') &&
            r.selectorText.includes('.sidebar-left') && r.selectorText.includes('.sidebar-right') &&
            r.style &&
            r.style.backgroundColor === 'rgb(20, 24, 34)' &&
            r.style.getPropertyPriority('background-color') === 'important'
          );
          const lightSolid = inner.some(r =>
            r.selectorText && r.selectorText.includes('[data-theme="light"] .sidebar-left') &&
            r.selectorText.includes('[data-theme="light"] .sidebar-right') &&
            r.style &&
            r.style.backgroundColor === 'rgb(243, 245, 249)' &&
            r.style.getPropertyPriority('background-color') === 'important'
          );
          return disablesBoth && resetsTokens && darkSolid && lightSolid;
        })()
        """)
        check("prefers-reduced-transparency 完整涵蓋 11 個玻璃元件、雙屬性 none !important、變數歸零與深淺色精確 !important 實底", reducedTransOK)

        // 4. 檢查 @media (prefers-reduced-motion: reduce) 針對 * / *::before / *::after 設定雙重 0.01ms !important
        let reducedMotionOK = await jsBool(web, """
        (() => {
          const rules = Array.from(document.styleSheets[0]?.cssRules || []);
          const media = rules.find(r => r.conditionText && r.conditionText.includes('prefers-reduced-motion'));
          if (!media) return false;
          return Array.from(media.cssRules).some(r => {
            const sel = r.selectorText || '';
            return sel.includes('*') && sel.includes('::before') && sel.includes('::after') &&
              r.style &&
              r.style.animationDuration === '0.01ms' &&
              r.style.getPropertyPriority('animation-duration') === 'important' &&
              r.style.transitionDuration === '0.01ms' &&
              r.style.getPropertyPriority('transition-duration') === 'important';
          });
        })()
        """)
        check("prefers-reduced-motion 針對全域元素將動畫與過渡壓縮至 0.01ms !important", reducedMotionOK)

        // 5. 檢查 .activity-bash 具備有效樣式（對應缺陷 #4）
        let bashStyleOK = await jsBool(web, """
        (() => {
          const rules = Array.from(document.styleSheets[0]?.cssRules || []);
          const r = rules.find(rule => rule.selectorText && rule.selectorText.includes('.activity-bash'));
          return !!(r && r.style && r.style.backgroundColor && r.style.color);
        })()
        """)
        check(".activity-bash 具備圖示底色與文字色彩規則", bashStyleOK)

        // 6. 檢查預覽文案與模擬 Token 皆已統一為 40px（對應缺陷 #6）
        let noStale36px = await jsBool(web, """
        (() => {
          const html = document.documentElement.innerHTML;
          return !html.includes('36px blur') && !html.includes('blur(36px)') && !html.includes('36.0</span>');
        })()
        """)
        check("預覽文案與模擬 Token 皆已統一為 40px（無 36px / 36.0 殘留）", noStale36px)
        }
    }
}
