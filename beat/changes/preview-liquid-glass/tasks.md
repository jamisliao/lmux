# Apple Liquid Glass 與雙欄介面 UI 原型 — 實作計畫

> **給執行的 agent：** 使用 `superpowers:executing-plans` 或 `superpowers:subagent-driven-development` 逐個 task 依序實作。每個 step 做完後將 `- [ ]` 改為 `- [x]`。

**Goal:** 修正 `preview-mockup.html` 的 6 個 CSS／JS／文案缺陷，並建立以 macOS `WKWebView` 執行的自動化檢查腳本覆蓋全部 13 個 `@e2e` 與 `@behavior` 場景。

**Architecture:** 不引入 Node／npm 依賴，比照 `App/scripts/preview-webkit-check*.swift` 拆分成數支小於 300 行的 Swift 檢查模組，由 `beat/changes/preview-liquid-glass/dev.sh` 統一編譯執行；`preview-mockup.html` 維持單檔自足 HTML／CSS／JS。每個缺陷修復皆先寫出會紅燈的 `WKWebView` 檢查，再最小修改 `preview-mockup.html` 至綠燈通過後提交。

**Tech Stack:** HTML5 / CSS3 / Vanilla JavaScript (`preview-mockup.html`)、Swift 6 + AppKit + WebKit (`WKWebView` 檢查腳本)、Bash (`dev.sh`)。不改動 `App/Sources/` 與 `Core/`。

## Global Constraints

- 只在 worktree `/Users/jamis.liao/opensource/lmux/.worktrees/feat/preview-liquid-glass` 工作，不要修改 `App/Sources/`、`App/Tests/` 或 `Core/` 下的任何正式程式碼。
- 不新增任何第三方依賴（不可引入 Node / npm / Playwright），只使用 Apple 內建 `AppKit` / `WebKit`。
- 所有檢查一律透過 `beat/changes/preview-liquid-glass/dev.sh check`（或分項指令）執行。
- 新建的每支 Swift 檢查檔不超過 ~300 行；註解使用繁體中文，術語對齊 `GLOSSARY.md`（`sidebar`、`右側 Inspector`、`通知 bar`、`視窗底部狀態列`、`UI 原型`）。
- 禁止 `git push` 或 `git commit --no-verify`；禁止為了通過測試而放寬斷言或修改測試預期。
- 若驗證結果與預期不同，最多修兩次；兩次仍未解決則停下來回報指令與完整輸出。

## Quality Principles

**Testing:** Tests verify behavior (return values, state changes, responses), not wiring.
If the main assertion is `toHaveBeenCalledWith`, rewrite to assert on the function's output.

**Code:** No single new file exceeds ~300 lines. If it grows past that, split into focused sub-modules.

---

## 檔案與場景對照

| 檔案 | 新增／修改 | 負責內容 | Task |
|---|---|---|---|
| `beat/changes/preview-liquid-glass/dev.sh` | 新增 | 編譯並執行 `liquid-glass-mockup-check*.swift` | 1 |
| `App/scripts/liquid-glass-mockup-check.swift` | 新增 | `WKWebView` 測試基座與雙主題切換檢查 | 1 |
| `App/scripts/liquid-glass-mockup-check-styles.swift` | 新增 | 靜態 CSS 結構與 `prefers-reduced-*` 檢查 | 2 |
| `App/scripts/liquid-glass-mockup-check-panels.swift` | 新增 | 左右面板收合／快捷鍵與 `通知 bar` 收合檢查 | 3 |
| `App/scripts/liquid-glass-mockup-check-resize.swift` | 新增 | 拖曳調寬調高、上下限夾緊與 `.is-resizing` 模糊停用檢查 | 4 |
| `App/scripts/liquid-glass-mockup-check-inbox.swift` | 新增 | Workspace 選取與 `通知 bar` 未讀／已讀連動檢查 | 5 |
| `App/scripts/liquid-glass-mockup-check-inspector.swift` | 新增 | 右側 Inspector 分頁／檔案切換、`↻`、`↗` 與底部狀態列連動檢查 | 6 |
| `preview-mockup.html` | 修改 | 修正 6 項 CSS／JS／文案缺陷與 macOS `⌥⌘B` `e.code` 支援 | 2, 3, 4, 6 |
| `beat/changes/preview-liquid-glass/features/liquid-glass-redesign-mockup.feature` | 修改 | 為全部 13 個場景加上 `# @covered-by:` 標註 | 7 |
| `beat/changes/preview-liquid-glass/design.md`、`proposal.md` | 修改 | 同步測試腳本路徑清單 | 7 |

---

### Task 1: 建立 `dev.sh` 與 `WKWebView` 測試基座（含雙主題切換驗證）

**Files:**
- Create: `beat/changes/preview-liquid-glass/dev.sh`
- Create: `App/scripts/liquid-glass-mockup-check.swift`

**Interfaces:**
- Produces in `App/scripts/liquid-glass-mockup-check.swift`:
  - `enum LiquidGlassMockupCheck` (`@main`, `static var failures: Int`, `static func check(_ name: String, _ ok: Bool, _ detail: String = "")`, `static func js(_ web: WKWebView, _ code: String) async -> Any?`, `static func jsString(_ web: WKWebView, _ code: String) async -> String?`, `static func jsBool(_ web: WKWebView, _ code: String) async -> Bool`, `static func waitJS(_ web: WKWebView, _ code: String, _ seconds: Double = 6, where pred: (Any?) -> Bool) async -> Bool`, `static func loadMockup(_ web: WKWebView, in win: NSWindow) async -> Bool`, `static func makeWebView() -> (WKWebView, NSWindow)`, `static func themeChecks() async`)
  - Calls `themeChecks()` directly in `main()`, leaving extension hooks for Tasks 2–6.

- [x] **Step 1: 建立 `beat/changes/preview-liquid-glass/dev.sh`**

```bash
#!/bin/bash
# preview-liquid-glass 實作與驗證用指令。在 worktree 任何位置執行：
#   beat/changes/preview-liquid-glass/dev.sh check    編譯並執行 App/scripts/liquid-glass-mockup-check*.swift
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/usr/bin:$PATH"
OUT="${TMPDIR:-/tmp}/preview-liquid-glass"
mkdir -p "$OUT"

case "${1:-}" in
  check)
    swiftc -parse-as-library -o "$OUT/liquid-glass-mockup-check" \
      App/scripts/liquid-glass-mockup-check*.swift \
      && "$OUT/liquid-glass-mockup-check" ;;
  *)
    sed -n 2,3p "$0"; exit 2 ;;
esac
```

執行權限設定：
```bash
chmod +x beat/changes/preview-liquid-glass/dev.sh
```

- [x] **Step 2: 建立 `App/scripts/liquid-glass-mockup-check.swift` 與雙主題測試**

```swift
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
        try? await web.evaluateJavaScript(code)
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
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return await waitJS(web, "document.readyState === 'complete' && !!document.getElementById('window-frame')") {
            ($0 as? Bool) == true || ($0 as? NSNumber)?.boolValue == true
        }
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await themeChecks()
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
        let (web, win) = makeWebView()
        defer { win.close() }
        check("載入 preview-mockup.html 完成", await loadMockup(web, in: win))

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
```

- [x] **Step 3: 執行檢查腳本確認編譯與主題檢查通過**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `PASS  載入 preview-mockup.html 完成`, 3 個主題 PASS, 最後一行 `MOCKUP CHECK: ok`。

- [x] **Step 4: Commit**

```bash
git add beat/changes/preview-liquid-glass/dev.sh App/scripts/liquid-glass-mockup-check.swift
git commit -m "test(preview-liquid-glass): 建立 WKWebView 原型檢查基座與雙主題測試"
```

---

### Task 2: 修正孤立 CSS、`.activity-bash`、`40px` 文案與 `prefers-reduced-*` 覆蓋清單

**Files:**
- Create: `App/scripts/liquid-glass-mockup-check-styles.swift`
- Modify: `App/scripts/liquid-glass-mockup-check.swift:82-85` (呼叫 `await styleChecks()`)
- Modify: `preview-mockup.html:33-36`, `:87-90`, `:195-217`, `:290-298`, `:335`, `:372`, `:527`, `:1516`, `:1590-1591`, `:1686-1688`, `:1727-1728`, `:1845-1846`, `:2285`, `:2365`, `:2520`, `:2558`, `:2642`

**Interfaces:**
- Consumes: `LiquidGlassMockupCheck.makeWebView()`, `loadMockup(_:in:)`, `jsString(_:_:)`, `jsBool(_:_:)`, `check(_:_:_:)`
- Produces: `LiquidGlassMockupCheck.styleChecks()`

- [x] **Step 1: 建立 `App/scripts/liquid-glass-mockup-check-styles.swift` 並掛入 `main()`**

新增 `App/scripts/liquid-glass-mockup-check-styles.swift`：
```swift
// @feature: liquid-glass-redesign-mockup.feature
// @scenario: 系統開啟減少透明度時停用全部毛玻璃模糊
// @scenario: 系統開啟減少動態效果時縮短動畫與過渡時間

import AppKit
import WebKit

extension LiquidGlassMockupCheck {
    @MainActor static func styleChecks() async {
        let (web, win) = makeWebView()
        defer { win.close() }
        guard await loadMockup(web, in: win) else {
            check("樣式檢查載入 preview-mockup.html", false)
            return
        }

        // 1. 檢查 <style> 大括號平衡與 .ctrl-pill-btn:hover 無重複規則（對應缺陷 #1）
        let braceBalanceOK = await jsBool(web, """
        (() => {
          const css = document.querySelector('style')?.textContent || '';
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
          const disablesBoth = disableRule.style.getPropertyValue('backdrop-filter') === 'none' &&
            ((disableRule.cssText || '').includes('-webkit-backdrop-filter: none') ||
             disableRule.style.getPropertyValue('-webkit-backdrop-filter') === 'none');

          const resetRule = inner.find(r => (r.selectorText || '').includes(':root') && (r.selectorText || '').includes('[data-theme="light"]'));
          const resetsTokens = !!(resetRule &&
            resetRule.style.getPropertyValue('--glass-blur').trim() === 'none' &&
            resetRule.style.getPropertyValue('--glass-blur-subtle').trim() === 'none' &&
            resetRule.style.getPropertyValue('--glass-blur-card').trim() === 'none');

          const darkSolid = inner.some(r =>
            r.selectorText && !r.selectorText.includes('[data-theme="light"]') &&
            r.selectorText.includes('.sidebar-left') && r.selectorText.includes('.sidebar-right') &&
            r.style && r.style.backgroundColor !== ''
          );
          const lightSolid = inner.some(r =>
            r.selectorText && r.selectorText.includes('[data-theme="light"] .sidebar-left') &&
            r.selectorText.includes('[data-theme="light"] .sidebar-right') &&
            r.style && r.style.backgroundColor !== ''
          );
          return disablesBoth && resetsTokens && darkSolid && lightSolid;
        })()
        """)
        check("prefers-reduced-transparency 完整涵蓋 11 個玻璃元件、雙屬性 none、變數歸零與深淺色實底", reducedTransOK)

        // 4. 檢查 @media (prefers-reduced-motion: reduce) 針對 * / *::before / *::after 設定雙重 0.01ms
        let reducedMotionOK = await jsBool(web, """
        (() => {
          const rules = Array.from(document.styleSheets[0]?.cssRules || []);
          const media = rules.find(r => r.conditionText && r.conditionText.includes('prefers-reduced-motion'));
          if (!media) return false;
          return Array.from(media.cssRules).some(r => {
            const sel = r.selectorText || '';
            return sel.includes('*') && sel.includes('::before') && sel.includes('::after') &&
              r.style && r.style.animationDuration === '0.01ms' && r.style.transitionDuration === '0.01ms';
          });
        })()
        """)
        check("prefers-reduced-motion 針對全域元素將動畫與過渡壓縮至 0.01ms", reducedMotionOK)

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
```

同時修改 `App/scripts/liquid-glass-mockup-check.swift` 的 `main()` 在 `await themeChecks()` 後加上 `await styleChecks()`：
```swift
        Task { @MainActor in
            await themeChecks()
            await styleChecks()
            print(failures == 0 ? "MOCKUP CHECK: ok" : "MOCKUP CHECK: FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
```

- [x] **Step 2: 執行檢查確認這 6 項新檢查先失敗（紅燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `FAIL` 出現於大括號平衡／重複 hover 規則、`-webkit-backdrop-filter` 前綴、`prefers-reduced-transparency`、`.activity-bash`、以及 `36px` 殘留；最後輸出 `MOCKUP CHECK: FAILED (...)`。

- [x] **Step 3: 修正 `preview-mockup.html` 的靜態樣式、token 與文案缺陷（缺陷 #1, #2 部分, #4, #6）**

1. 在 `:root`（`:33-36`）與 `[data-theme="light"]`（`:87-90`）新增 `--glass-blur-card`：
```css
      /* :root (:33-36) */
      --glass-blur: blur(40px) saturate(210%) contrast(104%);
      --glass-blur-subtle: blur(24px) saturate(180%);
      --glass-blur-card: blur(16px);
      --bg-resizing-fallback: rgba(18, 22, 30, 0.98);
```
```css
      /* [data-theme="light"] (:87-90) */
      --glass-blur: blur(40px) saturate(240%) contrast(105%) brightness(103%);
      --glass-blur-subtle: blur(24px) saturate(200%) brightness(102%);
      --glass-blur-card: blur(16px);
```

2. 更新 `@media (prefers-reduced-transparency: reduce)`（`:195-217`）：
```css
    @media (prefers-reduced-transparency: reduce) {
      :root, [data-theme="light"] {
        --glass-blur: none !important;
        --glass-blur-subtle: none !important;
        --glass-blur-card: none !important;
      }
      .lmux-window,
      .sidebar-left,
      .sidebar-right,
      .sidebar-inbox-accessory,
      .titlebar,
      .mockup-controls,
      .window-footer,
      .terminal-pane,
      .inspector-card,
      .preview-browser-card,
      .preview-viewport-card {
        backdrop-filter: none !important;
        -webkit-backdrop-filter: none !important;
      }
      .sidebar-left,
      .sidebar-right {
        background: #141822 !important;
      }
      [data-theme="light"] .sidebar-left,
      [data-theme="light"] .sidebar-right {
        background: #F3F5F9 !important;
      }
    }
```

3. 移除 `:290-298` 孤立 CSS 片段與重複 `.ctrl-pill-btn:hover`（保留 `:287-289` `[data-theme="dark"] .ctrl-pill-btn:hover` 與 `:299` `.ctrl-pill-btn:active`）。

4. 為 `.lmux-window`（`:335`）、`.titlebar`（`:372`）、`.sidebar-left`（`:527`）、`.sidebar-right`（`:1516`）補齊 `-webkit-backdrop-filter`：
```css
      /* .lmux-window */
      backdrop-filter: var(--glass-blur);
      -webkit-backdrop-filter: var(--glass-blur);

      /* .titlebar */
      backdrop-filter: var(--glass-blur-subtle);
      -webkit-backdrop-filter: var(--glass-blur-subtle);

      /* .sidebar-left 與 .sidebar-right */
      backdrop-filter: var(--glass-blur);
      -webkit-backdrop-filter: var(--glass-blur);
```

5. 將 `.inspector-card`（`:1590-1591`）、`.preview-browser-card`（`:1727-1728`）、`.preview-viewport-card`（`:1845-1846`）的 `blur(16px)` 改為 `var(--glass-blur-card)`：
```css
      backdrop-filter: var(--glass-blur-card);
      -webkit-backdrop-filter: var(--glass-blur-card);
```

6. 在 `:1688` 下方補上 `.activity-bash`（沿用 `.activity-run` 綠色風格）：
```css
    .activity-read { background: rgba(10, 132, 255, 0.15); color: var(--accent-blue); }
    .activity-edit { background: rgba(255, 159, 10, 0.15); color: var(--accent-orange); }
    .activity-run,
    .activity-bash { background: rgba(48, 209, 88, 0.15); color: var(--accent-green); }
```

7. 將 `:2285`、`:2365`、`:2520`、`:2642` 的 `36px blur`／`blur(36px)` 統一改為 `40px blur`／`blur(40px)`，並將 `:2558` 的 `blurRadius: CGFloat = 36.0` 更新為 `40.0`。

- [x] **Step 4: 執行檢查確認全部通過（綠燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `themeChecks` 與 `styleChecks` 全數 `PASS`，最後一行 `MOCKUP CHECK: ok`。

- [x] **Step 5: Commit**

```bash
git add preview-mockup.html App/scripts/liquid-glass-mockup-check.swift App/scripts/liquid-glass-mockup-check-styles.swift
git commit -m "fix(preview-liquid-glass): 修正孤立 CSS、活動圖示樣式、40px 文案與無障礙媒體規則"
```

---

### Task 3: 側邊面板與 `通知 bar` 收合互動驗證（含修正 macOS `⌥⌘B` 鍵盤處理）

**Files:**
- Create: `App/scripts/liquid-glass-mockup-check-panels.swift`
- Modify: `App/scripts/liquid-glass-mockup-check.swift` (呼叫 `await panelChecks()`)
- Modify: `preview-mockup.html:2457-2469` (基準 `9d15b95` 行號：補上 `e.code === 'KeyB'` 與 `!e.shiftKey` 檢查並清除多餘的 `Cmd+Shift+R` 註解)

**Interfaces:**
- Consumes: `LiquidGlassMockupCheck.makeWebView()`, `loadMockup(_:in:)`, `js(_:_:)`, `jsBool(_:_:)`, `check(_:_:_:)`
- Produces: `LiquidGlassMockupCheck.panelChecks()`

- [ ] **Step 1: 建立 `App/scripts/liquid-glass-mockup-check-panels.swift` 並掛入 `main()`**

```swift
// @feature: liquid-glass-redesign-mockup.feature
// @scenario: 用按鈕或快捷鍵收合與展開 sidebar 及右側 Inspector
// @scenario: 透過摘要列、雙擊手把或頂部控制列切換通知 bar 收合與展開

import AppKit
import WebKit

extension LiquidGlassMockupCheck {
    @MainActor static func panelChecks() async {
        let (web, win) = makeWebView()
        defer { win.close() }
        guard await loadMockup(web, in: win) else {
            check("面板收合檢查載入 preview-mockup.html", false)
            return
        }

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
```

在 `App/scripts/liquid-glass-mockup-check.swift` 的 `main()` 補上 `await panelChecks()`。

- [ ] **Step 2: 執行檢查確認 macOS `⌥⌘B`（`key: '∫'`）測試先失敗（紅燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `FAIL  右側 Inspector 透過「快捷鍵 ⌥⌘B（macOS Option 送出 '∫'）」收合且標題列鈕取消亮起`。

- [ ] **Step 3: 修正 `preview-mockup.html` 的鍵盤快捷鍵判斷與註解**

修改 `preview-mockup.html`（基準 `9d15b95` 行號 `:2457-2469`）：
```javascript
    // Keyboard Shortcuts: Cmd+B (Left), Opt+Cmd+B (Right)
    window.addEventListener('keydown', (e) => {
      const isBKey = e.key === 'b' || e.key === 'B' || e.code === 'KeyB';
      // Cmd + B
      if ((e.metaKey || e.ctrlKey) && !e.altKey && !e.shiftKey && isBKey) {
        e.preventDefault();
        toggleSidebar('left');
      }
      // Option + Cmd + B
      if ((e.metaKey || e.ctrlKey) && e.altKey && !e.shiftKey && isBKey) {
        e.preventDefault();
        toggleSidebar('right');
      }
    });
```

- [ ] **Step 4: 執行檢查確認全部通過（綠燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `themeChecks`、`styleChecks`、`panelChecks` 全數 `PASS`，最後一行 `MOCKUP CHECK: ok`。

- [ ] **Step 5: Commit**

```bash
git add preview-mockup.html App/scripts/liquid-glass-mockup-check.swift App/scripts/liquid-glass-mockup-check-panels.swift
git commit -m "fix(preview-liquid-glass): 修正 macOS Option+Cmd+B 按鍵辨識並新增面板收合測試"
```

---

### Task 4: 修正 `.is-resizing` 拖曳停用模糊與淺色模式底色（含上下限夾緊測試）

**Files:**
- Create: `App/scripts/liquid-glass-mockup-check-resize.swift`
- Modify: `App/scripts/liquid-glass-mockup-check.swift` (呼叫 `await resizeChecks()`)
- Modify: `preview-mockup.html:165-183`, `:2799`, `:2847`（基準 `9d15b95` 行號）

**Interfaces:**
- Consumes: `LiquidGlassMockupCheck.makeWebView()`, `loadMockup(_:in:)`, `js(_:_:)`, `jsBool(_:_:)`, `jsString(_:_:)`, `check(_:_:_:)`
- Produces: `LiquidGlassMockupCheck.resizeChecks()`

- [ ] **Step 1: 建立 `App/scripts/liquid-glass-mockup-check-resize.swift` 並掛入 `main()`**

新增 `App/scripts/liquid-glass-mockup-check-resize.swift`（先在 `preview-mockup.html` 未修正前跑這個測試，驗證紅燈）：
```swift
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
```

在 `App/scripts/liquid-glass-mockup-check.swift` 的 `main()` 補上 `await resizeChecks()`。

- [ ] **Step 2: 執行檢查確認在修復前失敗（紅燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `FAIL`（在未防禦的 `setPointerCapture` 會使合成 `PointerEvent` 中止，或於 `backdrop-filter` / 淺色實底 `rgba(18, 22, 30, 0.98)` 檢查失敗）。

- [ ] **Step 3: 修正 `preview-mockup.html` 的 `.is-resizing`、淺色底色 selector 與 `setPointerCapture`（缺陷 #2, #3）**

1. 修改 `preview-mockup.html:165-183`：
```css
    body.is-resizing .sidebar-left,
    body.is-resizing .sidebar-right,
    body.is-resizing .sidebar-inbox-accessory,
    body.is-resizing .lmux-window,
    body.is-resizing .titlebar,
    body.is-resizing .mockup-controls,
    body.is-resizing .window-footer,
    body.is-resizing .terminal-pane,
    body.is-resizing .inspector-card,
    body.is-resizing .preview-browser-card,
    body.is-resizing .preview-viewport-card {
      backdrop-filter: none !important;
      -webkit-backdrop-filter: none !important;
      transition: none !important;
    }

    body.is-resizing .sidebar-left,
    body.is-resizing .sidebar-right {
      background: var(--bg-resizing-fallback, rgba(18, 22, 30, 0.98)) !important;
    }

    body[data-theme="light"].is-resizing .sidebar-left,
    body[data-theme="light"].is-resizing .sidebar-right {
      background: rgba(245, 247, 252, 0.98) !important;
    }
```

2. 在 `setupResize`（`:2799`）與 `setupInboxResize`（`:2847`）安全呼叫 `setPointerCapture`（避免無真實活動指標 ID 時拋出 `NotFoundError` 中斷事件處理）：
```javascript
        try { handle.setPointerCapture(e.pointerId); } catch (_) {}
```

- [ ] **Step 4: 執行檢查確認全部通過（綠燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `resizeChecks` 全數 `PASS`，最後一行 `MOCKUP CHECK: ok`。

- [ ] **Step 5: Commit**

```bash
git add preview-mockup.html App/scripts/liquid-glass-mockup-check.swift App/scripts/liquid-glass-mockup-check-resize.swift
git commit -m "fix(preview-liquid-glass): 修正 .is-resizing 玻璃清單與淺色主題拖曳底色 selector"
```

---

### Task 5: Workspace 選取與 `通知 bar` 未讀／已讀連動驗證

**Files:**
- Create: `App/scripts/liquid-glass-mockup-check-inbox.swift`
- Modify: `App/scripts/liquid-glass-mockup-check.swift` (呼叫 `await inboxChecks()`)

**Interfaces:**
- Consumes: `LiquidGlassMockupCheck.makeWebView()`, `loadMockup(_:in:)`, `js(_:_:)`, `jsBool(_:_:)`, `jsString(_:_:)`, `check(_:_:_:)`
- Produces: `LiquidGlassMockupCheck.inboxChecks()`

- [ ] **Step 1: 建立 `App/scripts/liquid-glass-mockup-check-inbox.swift` 並掛入 `main()`**

```swift
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
```

在 `App/scripts/liquid-glass-mockup-check.swift` 的 `main()` 補上 `await inboxChecks()`。

- [ ] **Step 2: 執行檢查確認通過**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `inboxChecks` 全數 `PASS`，最後一行 `MOCKUP CHECK: ok`。

- [ ] **Step 3: Commit**

```bash
git add App/scripts/liquid-glass-mockup-check.swift App/scripts/liquid-glass-mockup-check-inbox.swift
git commit -m "test(preview-liquid-glass): 新增 workspace 選取與通知 bar 未讀連動測試"
```

---

### Task 6: 修正預覽重新整理鈕 `↻` 同步，並驗證右側 Inspector 與視窗底部狀態列連動

**Files:**
- Create: `App/scripts/liquid-glass-mockup-check-inspector.swift`
- Modify: `App/scripts/liquid-glass-mockup-check.swift` (呼叫 `await inspectorChecks()`)
- Modify: `preview-mockup.html:2489-2493`（基準 `9d15b95` 行號）

**Interfaces:**
- Consumes: `LiquidGlassMockupCheck.makeWebView()`, `loadMockup(_:in:)`, `js(_:_:)`, `jsBool(_:_:)`, `jsString(_:_:)`, `check(_:_:_:)`
- Produces: `LiquidGlassMockupCheck.inspectorChecks()`

- [ ] **Step 1: 建立 `App/scripts/liquid-glass-mockup-check-inspector.swift` 並掛入 `main()`**

```swift
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
        document.getElementById('tab-content-context').innerText.includes('Git 變更狀態')
        """)
        check("右側 Inspector 切換至「變更 (Diff)」分頁", diffOK)

        _ = await js(web, "document.querySelector(\".segment-btn[data-tab='trace']\").click(); true")
        let traceOK = await jsBool(web, """
        (() => {
          const bashEl = document.querySelector('.activity-bash');
          const bashBg = bashEl ? getComputedStyle(bashEl).backgroundColor : '';
          return document.querySelector(\".segment-btn[data-tab='trace']\").classList.contains('active') &&
                 document.getElementById('tab-content-context').innerText.includes('Context Window') &&
                 document.getElementById('tab-content-context').innerText.includes('bash') &&
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
```

在 `App/scripts/liquid-glass-mockup-check.swift` 的 `main()` 補上 `await inspectorChecks()`。

- [ ] **Step 2: 執行檢查確認 `↻` 按鈕測試先失敗（紅燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `FAIL  點擊預覽重新整理 ↻ 回到 HTML 並同步亮起 HTML 範例鈕`（因為 `chips[0]` 沒有 `.active`，`chips[2]` 仍留著 `.active`）。

- [ ] **Step 3: 修正 `preview-mockup.html:2489-2493` 的 `switchPreviewFile`**

將 `switchPreviewFile(type, el)`（`:2489-2493`）改為在未傳 `el` 時自動比對對應的 `.preview-file-chip`：
```javascript
    function switchPreviewFile(type, el) {
      const targetChip = el || document.querySelector(`.preview-file-chip[onclick*="'${type}'"]`);
      if (targetChip) {
        document.querySelectorAll('.preview-file-chip').forEach(c => c.classList.remove('active'));
        targetChip.classList.add('active');
      }
```

- [ ] **Step 4: 執行檢查確認全部通過（綠燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: 全部檢查項目 `PASS`，最後一行 `MOCKUP CHECK: ok`。

- [ ] **Step 5: Commit**

```bash
git add preview-mockup.html App/scripts/liquid-glass-mockup-check.swift App/scripts/liquid-glass-mockup-check-inspector.swift
git commit -m "fix(preview-liquid-glass): 修正預覽重新整理鈕 chip 亮起狀態並補齊 Inspector 與狀態列測試"
```

---

### Task 7: 補上 `@covered-by` 標註、手動視覺／無障礙確認並驗證全套規格

**Files:**
- Modify: `beat/changes/preview-liquid-glass/features/liquid-glass-redesign-mockup.feature`
- Modify: `beat/changes/preview-liquid-glass/design.md`、`beat/changes/preview-liquid-glass/proposal.md` (對齊最新腳本路徑清單與行號)

**Interfaces:**
- Consumes: 已完成的 `App/scripts/liquid-glass-mockup-check*.swift`

- [ ] **Step 1: 為 `.feature` 的 13 個場景加上 `# @covered-by:` 標註**

依 `testing-conventions.md` 規範，在每個場景的標籤列與 `場景:` / `場景大綱:` 之間補上對應腳本路徑：
- 雙主題場景 → `# @covered-by: App/scripts/liquid-glass-mockup-check.swift`
- 減少透明度／減少動態效果 2 個場景 → `# @covered-by: App/scripts/liquid-glass-mockup-check-styles.swift`
- 側邊面板與 `通知 bar` 收合 2 個場景 → `# @covered-by: App/scripts/liquid-glass-mockup-check-panels.swift`
- 拖曳調寬調高 3 個場景 → `# @covered-by: App/scripts/liquid-glass-mockup-check-resize.swift`
- Workspace 與 `通知 bar` 連動 3 個場景 → `# @covered-by: App/scripts/liquid-glass-mockup-check-inbox.swift`
- 右側 Inspector 與底部狀態列 2 個場景 → `# @covered-by: App/scripts/liquid-glass-mockup-check-inspector.swift`

- [ ] **Step 2: 執行全套 `WKWebView` 檢查與檔案影響檢查**

Run:
```bash
beat/changes/preview-liquid-glass/dev.sh check
wc -l App/scripts/liquid-glass-mockup-check*.swift
git diff --name-only main...HEAD -- App/Sources/ App/Tests/ Core/
```
Expected:
- 最後一行輸出 `MOCKUP CHECK: ok`
- 每支 `liquid-glass-mockup-check*.swift` 檔案皆小於 300 行
- `git diff --name-only main...HEAD -- App/Sources/ App/Tests/ Core/` 無任何輸出（確認正式 Swift／Ghostty 程式未被改動）

- [ ] **Step 3: 人工開啟原型快速目視確認（Visual & Accessibility Sanity Check）**

在 Safari 或 lmux **預覽 tab** 開啟 `preview-mockup.html`（只做目視確認，不擴大範圍改寫元件架構）：
- 確認淺色／深色雙主題對比度與按鈕 hover 觀感、實體鍵盤 `⌘B`／`⌥⌘B` 反應、拖曳游標與流暢度。
- 若方便切換 macOS「系統設定 → 輔助使用 → 顯示 → 減少透明度 / 減少動態效果」，確認頁面即時移除毛玻璃與動畫延遲。

- [ ] **Step 4: 同步更新 `design.md` 與 `proposal.md` 的腳本清單並 Commit**

將 `design.md`（`:89`, `:124`）與 `proposal.md`（`:46`）列的測試檔名更新為 `App/scripts/liquid-glass-mockup-check*.swift`（共 6 支聚焦模組）與 `beat/changes/preview-liquid-glass/dev.sh`，並更新 `design.md` 行號基準。
```bash
git add beat/changes/preview-liquid-glass/
git commit -m "docs(preview-liquid-glass): 加上 @covered-by 標註並同步實作測試腳本清單"
```
