// @feature: liquid-glass-app.feature
// @scenario: 淺色與深色外觀具備 1:1 液態玻璃設計 Token 與無障礙對比

import AppKit
import Foundation

@main
enum LiquidGlassAppCheck {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  -- \(detail)")")
    }

    static func lum(_ c: UInt32) -> Double {
        func ch(_ v: UInt32) -> Double {
            let x = Double(v) / 255.0
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch((c >> 16) & 0xFF) + 0.7152 * ch((c >> 8) & 0xFF) + 0.0722 * ch(c & 0xFF)
    }

    static func blend(_ a: UInt32, over b: UInt32, _ t: Double) -> UInt32 {
        func m(_ s: UInt32) -> UInt32 {
            UInt32((Double((a >> s) & 0xFF) * t + Double((b >> s) & 0xFF) * (1.0 - t)).rounded())
        }
        return (m(16) << 16) | (m(8) << 8) | m(0)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func main() {
        typealias C = LmuxTokens.Colors
        typealias L = LmuxTokens.Layout

        // 1. Liquid Glass 尺寸常數檢查
        check(
            "LmuxTokens Layout 尺寸常數符合 44/32/260/320/10/30 規格",
            L.titlebarHeight == 44 &&
            L.footerHeight == 32 &&
            L.sidebarWidthDefault == 260 &&
            L.rightInspectorWidthDefault == 320 &&
            L.paneCornerRadius == 10 &&
            L.paneTabStripHeight == 30 &&
            L.paneGap == 8 &&
            L.workspaceFilterHeaderHeight == 30
        )

        // 2. Liquid Glass 新增語意色彩 Token 檢查
        check(
            "LmuxTokens 具備 specularHighlight 與 glassHighlightBorder 雙主題高光設定",
            C.specularHighlight.light == 0xFFFFFF && C.specularHighlight.dark == 0xFFFFFF &&
            C.glassHighlightBorder.light == 0xFFFFFF && C.glassHighlightBorder.dark == 0xFFFFFF &&
            C.glassHighlightBorder.lightAlpha >= 0.70 && C.glassHighlightBorder.darkAlpha >= 0.10 &&
            C.glassBorder.lightAlpha > 0 && C.glassBorder.darkAlpha > 0
        )

        check(
            "LmuxTokens 具備 activePaneRing (藍) 與 needsInputRing (琥珀) 獨立色彩設定",
            C.activePaneRing.light == 0x0A84FF && C.activePaneRing.dark == 0x0A84FF &&
            C.needsInputRing != C.activePaneRing
        )

        check(
            "LmuxTokens 具備 titlebarBackground、rightSidebarTint 與 footerBackground",
            C.titlebarBackground.lightAlpha > 0 && C.titlebarBackground.darkAlpha > 0 &&
            C.rightSidebarTint.lightAlpha > 0 && C.rightSidebarTint.darkAlpha > 0 &&
            C.footerBackground.lightAlpha > 0 && C.footerBackground.darkAlpha > 0
        )

        // 3. WCAG AA 對比度：選取卡片、狀態藥丸、Diff 與底部狀態列文字皆 >= 4.5:1
        for (name, dark) in [("light", false), ("dark", true)] {
            func v(_ d: LmuxTokens.DynamicColor) -> UInt32 { dark ? d.dark : d.light }
            func a(_ d: LmuxTokens.DynamicColor) -> Double { Double(dark ? d.darkAlpha : d.lightAlpha) }

            let sidebar = v(C.sidebarBackground)
            let cardBg = blend(v(C.glassCardSelected), over: sidebar, a(C.glassCardSelected))

            let rCardPrimary = ratio(v(C.textPrimary), cardBg)
            let rCardSecondary = ratio(v(C.textSecondary), cardBg)
            check(
                "\(name) 模式選中 Workspace 卡片主要/次要文字符合 WCAG AA (>= 4.5:1)",
                rCardPrimary >= 4.5 && rCardSecondary >= 4.5,
                String(format: "primary=%.1f secondary=%.1f", rCardPrimary, rCardSecondary)
            )

            let recessedBg = blend(v(C.glassSurfaceRecessed), over: sidebar, a(C.glassSurfaceRecessed))
            let rSearchPrimary = ratio(v(C.textPrimary), recessedBg)
            let rSearchSecondary = ratio(v(C.textSecondary), recessedBg)
            check(
                "\(name) 模式 History 搜尋欄文字符合 WCAG AA (>= 4.5:1)",
                rSearchPrimary >= 4.5 && rSearchSecondary >= 4.5,
                String(format: "primary=%.1f secondary=%.1f", rSearchPrimary, rSearchSecondary)
            )

            // 狀態藥丸
            let runPill = blend(v(C.statusRunningPill), over: cardBg, a(C.statusRunningPill))
            let rRun = ratio(v(C.statusRunningText), runPill)

            let needsPill = blend(v(C.statusNeedsInputPill), over: cardBg, a(C.statusNeedsInputPill))
            let rNeeds = ratio(v(C.statusNeedsInputText), needsPill)

            let donePill = blend(v(C.statusDonePill), over: cardBg, a(C.statusDonePill))
            let rDone = ratio(v(C.statusDoneText), donePill)

            let idlePill = blend(v(C.statusIdlePill), over: cardBg, a(C.statusIdlePill))
            let rIdle = ratio(v(C.statusIdleText), idlePill)

            check(
                "\(name) 模式狀態藥丸文字在 pill 底色上符合 WCAG AA (>= 4.5:1)",
                rRun >= 4.5 && rNeeds >= 4.5 && rDone >= 4.5 && rIdle >= 4.5,
                String(format: "run=%.1f needs=%.1f done=%.1f idle=%.1f", rRun, rNeeds, rDone, rIdle)
            )

            // Diff 高亮
            let diffAddBg = blend(v(C.diffAddedBg), over: v(C.windowBackground), a(C.diffAddedBg))
            let rDiffAdd = ratio(v(C.diffAddedFg), diffAddBg)

            let diffDelBg = blend(v(C.diffRemovedBg), over: v(C.windowBackground), a(C.diffRemovedBg))
            let rDiffDel = ratio(v(C.diffRemovedFg), diffDelBg)

            check(
                "\(name) 模式 Diff 增刪文字在對應背景上符合 WCAG AA (>= 4.5:1)",
                rDiffAdd >= 4.5 && rDiffDel >= 4.5,
                String(format: "add=%.1f del=%.1f", rDiffAdd, rDiffDel)
            )

            // 底部狀態列文字
            let footerBg = blend(v(C.footerBackground), over: v(C.windowBackground), a(C.footerBackground))
            let rFooterPrimary = ratio(v(C.textPrimary), footerBg)
            let rFooterSecondary = ratio(v(C.textSecondary), footerBg)
            let rFooterTertiary = ratio(v(C.textTertiary), footerBg)

            check(
                "\(name) 模式底部狀態列主要、次要與補充文字符合 WCAG AA (>= 4.5:1)",
                rFooterPrimary >= 4.5 && rFooterSecondary >= 4.5 && rFooterTertiary >= 4.5,
                String(format: "primary=%.1f secondary=%.1f tertiary=%.1f", rFooterPrimary, rFooterSecondary, rFooterTertiary)
            )

            // 通知列 / 摘要列未讀角標 (onAccent over accent)
            let rBadge = ratio(v(C.onAccent), v(C.accent))
            check(
                "\(name) 模式未讀角標文字 (onAccent on accent) 符合 WCAG AA (>= 4.5:1)",
                rBadge >= 4.5,
                String(format: "badge=%.1f", rBadge)
            )
        }

        // 4. MarkdownHTML 預覽頁雙主題 Liquid Glass 樣式與無障礙降級檢查
        let html = MarkdownHTML.page("> [!NOTE]\n> Glass callout\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n", title: "Spec")
        check(
            "MarkdownHTML 保留嚴格 CSP 與淺深雙主題 --bg/--fg 相容色碼",
            html.contains("default-src 'none'") &&
            html.contains("--bg:#ffffff;--fg:#24292f") &&
            html.contains("@media (prefers-color-scheme: dark){:root{--bg:#0d1117;--fg:#e6edf3")
        )
        check(
            "MarkdownHTML 包含淺深雙主題 Liquid Glass 變數、頂部內高光與 pre/blockquote/callout/table 卡片規則",
            html.contains("--glass-surface:") &&
            html.contains("--glass-border:") &&
            html.contains("--glass-highlight:") &&
            html.contains("inset 0 1px 0 var(--glass-highlight)") &&
            html.contains("pre{background:var(--glass-surface)") &&
            html.contains("blockquote{") &&
            html.contains("table{border-collapse:separate;border-spacing:0;") &&
            html.contains("border-radius:8px;box-shadow:inset 0 1px 0 var(--glass-highlight);overflow:hidden") &&
            html.contains("th{background:var(--code-bg)") &&
            html.contains("<pre><code class=\"language-swift\">") &&
            html.contains("class=\"callout") &&
            html.contains("<table><thead>")
        )
        check(
            "MarkdownHTML 包含 prefers-reduced-transparency 與 prefers-reduced-motion 降級規則",
            html.contains("@media (prefers-reduced-transparency: reduce)") &&
            html.contains("@media (prefers-reduced-motion: reduce)")
        )

        print(failures == 0 ? "APP TOKEN CHECK: ok" : "APP TOKEN CHECK: FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
