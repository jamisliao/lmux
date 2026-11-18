// @feature: liquid-glass-app.feature
// @scenario: 淺色與深色外觀下提供具備頂部高光與無障礙對比的玻璃視覺設定
// @scenario: 預覽 tab 渲染 Markdown 檔案時套用雙主題玻璃卡片樣式與減少透明度降級規則

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

        // 1. Liquid Glass 新增語意色與尺寸常數檢查
        check(
            "LmuxTokens 具備 specularHighlight 雙主題高光設定",
            C.specularHighlight.light == 0xFFFFFF && C.specularHighlight.dark == 0xFFFFFF &&
            C.specularHighlight.lightAlpha > C.specularHighlight.darkAlpha && C.specularHighlight.darkAlpha > 0
        )
        check(
            "LmuxTokens 具備 glassBorder 微透立體邊框設定",
            C.glassBorder.lightAlpha > 0 && C.glassBorder.lightAlpha <= 0.2 &&
            C.glassBorder.darkAlpha > 0 && C.glassBorder.darkAlpha <= 0.2
        )
        check(
            "LmuxTokens 具備 dragHandlePill 與 dragHandlePillActive 及膠囊尺寸",
            C.dragHandlePillActive.lightAlpha > C.dragHandlePill.lightAlpha &&
            C.dragHandlePillActive.darkAlpha > C.dragHandlePill.darkAlpha &&
            L.dragHandlePillWidth == 24 && L.dragHandlePillHeight == 2.5
        )

        // 2. WCAG AA 對比度：選取中的 workspace 列與搜尋結果列上的主要文字、次要文字及狀態文字
        for (name, dark) in [("light", false), ("dark", true)] {
            func v(_ d: LmuxTokens.DynamicColor) -> UInt32 { dark ? d.dark : d.light }
            let sidebar = v(C.sidebarBackground)
            let pill = blend(v(C.rowSelected), over: sidebar, Double(dark ? C.rowSelected.darkAlpha : C.rowSelected.lightAlpha))
            let rPrimary = ratio(v(C.textPrimary), pill)
            let rSecondary = ratio(v(C.textSecondary), pill)
            let rTertiary = ratio(v(C.textTertiary), pill)
            let rNeedsInput = ratio(v(C.stateNeedsInput), pill)
            let searchHighlight = blend(v(C.accent), over: pill, 0.24)
            let rSearchPrimary = ratio(v(C.textPrimary), searchHighlight)
            check(
                "\(name) 模式選取膠囊與搜尋結果列的主要、次要及狀態文字對比符合 WCAG AA",
                rPrimary >= 9.0 && rSecondary >= 4.5 && rTertiary >= 4.5 && rNeedsInput >= 4.5 && rSearchPrimary >= 4.5,
                String(format: "primary=%.1f secondary=%.1f tertiary=%.1f needsInput=%.1f search=%.1f",
                       rPrimary, rSecondary, rTertiary, rNeedsInput, rSearchPrimary)
            )
        }

        print(failures == 0 ? "APP TOKEN CHECK: ok" : "APP TOKEN CHECK: FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
