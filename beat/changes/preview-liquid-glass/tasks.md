# 正式 App Apple Liquid Glass 視覺材質與拖曳零開銷守護 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 將正式 macOS `lmux.app`（`LmuxTokens`、`LmuxUI`、`LmuxNotificationBar`、`MarkdownHTML`）升級為支援淺色／深色雙主題的 Apple Liquid Glass 視覺材質（含 1pt 頂部入射光亮邊、選取膠囊與卡片的微透立體邊框、**通知 bar** 調整手把膠囊指示條、**預覽 tab** 玻璃卡片樣式），並在拖曳調整 sidebar、窗格分割線、**通知 bar** 或視窗縮放期間自動切換 `SidebarBackdrop.isResizing` 為不透明實底以達成 GPU 零開銷守護，最後建置並啟動 `App/build/lmux.app`。

**Architecture:** 維持 `App/README.md` 的單一 `SidebarBackdrop`（`NSVisualEffectView(.sidebar, .behindWindow)`）背景混合架構與「SwiftUI 不進終端機路徑」原則；於 `LmuxTokens` 定義雙主題 Liquid Glass token，在 `SidebarBackdrop` 整合頂部 1pt `specular` 亮邊與集中式 `isResizing` 不透明降級旗標，並透過 `beat/changes/preview-liquid-glass/dev.sh check`（含 `liquid-glass-app-check`、`apptest.sh --liquid-glass` 與 `liquid-glass-mockup-check`）及 `App/scripts/apptest.sh --preview` 驗證所有 `@behavior` 與 `@e2e` 場景。

**Tech Stack:** Swift 6、AppKit、SwiftUI、WebKit (`WKWebView` / `MarkdownHTML`)、Bash (`dev.sh` / `bundle.sh` / `apptest.sh`)。

## Global Constraints

- 只在 worktree `/Users/jamis.liao/opensource/lmux/.worktrees/feat/preview-liquid-glass` 工作；`Core/` 與 `LmuxTerminal`（libghostty 終端機渲染路徑）不得修改。
- 必須維持既有 Nord 調色盤的 WCAG AA 文字對比度（`P2Tests.swift:925-952` 所有對比檢查必須 100% 通過），且 `MarkdownHTML.css` 的 `--bg`／`--fg` 主背景與文字色碼維持與既有 `Preview.swift`／`PreviewText.swift`／`preview-webkit-check-text.swift` 相容。
- 保留根目錄 `preview-mockup.html` 與 `App/scripts/liquid-glass-mockup-check*.swift` 作為 **UI 原型** 基準。
- 單一新建檔案不得超過 ~300 行；禁止 `git push` 或 `git commit --no-verify`。
- 若 worktree 下尚未連結 `vendor`，建置前建立符號連結 `ln -sfn /Users/jamis.liao/opensource/lmux/vendor vendor`（`.gitignore` 已忽略 `/vendor/`）。

## Quality Principles

**Testing:** Tests verify behavior (return values, state changes, responses), not wiring.
If the main assertion is `toHaveBeenCalledWith`, rewrite to assert on the function's output.

**Code:** No single new file exceeds ~300 lines. If it grows past that, split into focused sub-modules.

---

## 檔案與任務對照

| 檔案 | 新增／修改 | 負責內容 | Task |
|---|---|---|---|
| `App/Sources/LmuxTokens/Tokens.swift` | 修改 | 新增 `specularHighlight`、`glassBorder`、`dragHandlePill`、`dragHandlePillActive` 與手把膠囊尺寸常數 | 1 |
| `App/scripts/liquid-glass-app-check.swift` | 新增 | 快速編譯驗證 `Tokens.swift`（含選取膠囊與搜尋結果列 WCAG AA 對比）與 `MarkdownHTML.swift` 的 `@behavior` 檢查腳本 | 1, 5 |
| `beat/changes/preview-liquid-glass/dev.sh` | 修改 | 串接 `liquid-glass-app-check.swift`、`apptest.sh --liquid-glass` 與 `liquid-glass-mockup-check*.swift` | 1, 6 |
| `App/Sources/LmuxUI/RootView.swift` | 修改 | `SidebarBackdrop` 頂部 1pt `specular` 亮邊、`isResizing` 降級、`SidebarResizeHandle` 與視窗縮放／`didResignKey`／`didResignActive` 監聽 | 2 |
| `App/Sources/LmuxUI/SidebarAccessory.swift` | 修改 | `LmuxController.setSidebarResizing(_:)` 與 `isSidebarResizing` 公開屬性 | 2 |
| `App/Sources/LmuxUI/PaneViews.swift` | 修改 | `SplitContainerView` 分割線 `mouseDown` / `mouseUp` 拖曳狀態回呼 | 3 |
| `App/Sources/LmuxUI/Controller.swift` | 修改 | `buildView` 將 `SplitContainerView.onDragStateChange` 串接至 `setSidebarResizing` | 3 |
| `App/Sources/LmuxNotificationBar/NotificationBar.swift` | 修改 | `BarResizeHandle` 居中膠囊指示條與 `BarLayout` 拖曳狀態同步 `controller.setSidebarResizing` | 3 |
| `App/Sources/LmuxUI/Sidebar.swift` | 修改 | `WorkspaceRowContent` 選取膠囊疊加 `glassBorder` 微透立體邊框 | 4 |
| `App/Sources/LmuxUI/History.swift` | 修改 | `HistorySection` 搜尋框與 `HistoryRow` 選取列疊加 `glassBorder` 微透立體邊框 | 4 |
| `App/Sources/LmuxNotificationBar/NotificationCard.swift` | 修改 | `NotificationCard` 反白與 hover 狀態疊加 `glassBorder` 微透邊框 | 4 |
| `App/Sources/LmuxUI/MarkdownHTML.swift` | 修改 | **預覽 tab** 淺／深雙主題 Liquid Glass 卡片 CSS、頂部內高光與 `prefers-reduced-*` 降級 | 5 |
| `App/Package.swift`、`App/Sources/lmux-apptest/LiquidGlass.swift`、`main.swift`、`App/scripts/apptest.sh` | 新增／修改 | 新增 `--liquid-glass` `@e2e` 測試套件，驗證 `SidebarBackdrop`、4 種拖曳入口、失焦復原、**通知 bar** 與卡片立體邊框 | 6 |
| `beat/changes/preview-liquid-glass/features/liquid-glass-app.feature` | 修改 | 為全部 6 個場景補齊 `# @covered-by:` 標註 | 6 |

---

### Task 1: 擴充 `LmuxTokens` 的雙主題 Liquid Glass 語意色與尺寸常數

**Files:**
- Modify: `App/Sources/LmuxTokens/Tokens.swift:125-130`, `:355-358`
- Create: `App/scripts/liquid-glass-app-check.swift`
- Modify: `beat/changes/preview-liquid-glass/dev.sh`

**Interfaces:**
- Produces in `LmuxTokens.Colors`:
  - `public static let specularHighlight: DynamicColor`
  - `public static let glassBorder: DynamicColor`
  - `public static let dragHandlePill: DynamicColor`
  - `public static let dragHandlePillActive: DynamicColor`
- Produces in `LmuxTokens.Layout`:
  - `public static let dragHandlePillWidth: CGFloat = 24`
  - `public static let dragHandlePillHeight: CGFloat = 2.5`

- [ ] **Step 1: 建立 `App/scripts/liquid-glass-app-check.swift` 並掛入 `dev.sh`（先寫失敗測試）**

建立 `App/scripts/liquid-glass-app-check.swift`：
```swift
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
```

更新 `beat/changes/preview-liquid-glass/dev.sh` 的 `check)` 分支：
```bash
  check)
    swiftc -parse-as-library -o "$OUT/liquid-glass-app-check" \
      App/Sources/LmuxTokens/Tokens.swift \
      App/Sources/LmuxUI/MarkdownHTML.swift \
      App/scripts/liquid-glass-app-check.swift \
      && "$OUT/liquid-glass-app-check" \
      && swiftc -parse-as-library -o "$OUT/liquid-glass-mockup-check" \
        App/scripts/liquid-glass-mockup-check*.swift \
      && "$OUT/liquid-glass-mockup-check" ;;
```

- [ ] **Step 2: 執行 `dev.sh check` 確認因缺少新 Token 而編譯失敗（紅燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: 編譯失敗，回報 `LmuxTokens.Colors` 無 `specularHighlight`、`glassBorder`、`dragHandlePill`、`dragHandlePillActive`。

- [ ] **Step 3: 在 `App/Sources/LmuxTokens/Tokens.swift` 實作新 Token**

於 `App/Sources/LmuxTokens/Tokens.swift` 的 `Colors`（`:126-129` `border` 下方）新增：
```swift
        /// Liquid Glass top 1pt specular edge on the sidebar and notification bar.
        public static let specularHighlight = DynamicColor(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.65, darkAlpha: 0.12)
        /// Subtle translucent border on selected workspace pills, highlighted notification cards, and the History search field.
        public static let glassBorder = DynamicColor(light: Nord.nord0, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.11)
        /// Center capsule indicator on the notification bar's resize handle (idle vs hover/dragging).
        public static let dragHandlePill = DynamicColor(light: Nord.nord0, dark: Nord.nord6, lightAlpha: 0.22, darkAlpha: 0.24)
        public static let dragHandlePillActive = DynamicColor(light: 0x46658E, dark: Nord.nord8, lightAlpha: 0.70, darkAlpha: 0.75)
```

於 `App/Sources/LmuxTokens/Tokens.swift` 的 `Layout`（`:356` `sheetWidth` 下方）新增：
```swift
        public static let dragHandlePillWidth: CGFloat = 24
        public static let dragHandlePillHeight: CGFloat = 2.5
```

- [ ] **Step 4: 執行 `dev.sh check` 確認綠燈通過**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `APP TOKEN CHECK: ok` 與 `MOCKUP CHECK: ok`（exit code 0）。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/LmuxTokens/Tokens.swift App/scripts/liquid-glass-app-check.swift beat/changes/preview-liquid-glass/dev.sh
git commit -m "feat(tokens): add Liquid Glass specular, border, and drag-handle tokens"
```

---

### Task 2: `SidebarBackdrop` 頂部 1pt Specular 高光邊與拖曳／Live Resize `isResizing` 守護

**Files:**
- Modify: `App/Sources/LmuxUI/RootView.swift:64-75`, `:256-303`, `:482-493`
- Modify: `App/Sources/LmuxUI/SidebarAccessory.swift:11-25`

**Interfaces:**
- Produces on `SidebarBackdrop` (`App/Sources/LmuxUI/RootView.swift`):
  - `let specular = ColorView(T.Colors.specularHighlight.nsColor)`
  - `var isResizing = false { didSet { if isResizing != oldValue { update() } } }`
  - `var isOpaqueFallback: Bool { forceOpaque || isResizing || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }`
- Produces on `SidebarResizeHandle`:
  - `var onDragStateChange: ((Bool) -> Void)?`
- Produces on `LmuxController` (`App/Sources/LmuxUI/SidebarAccessory.swift`):
  - `public func setSidebarResizing(_ active: Bool)`
  - `public var isSidebarResizing: Bool`

- [ ] **Step 1: 在 `App/Sources/LmuxUI/RootView.swift` 與 `SidebarAccessory.swift` 實作 `specular`、`isResizing`、視窗縮放／失焦（`didResignKey` + `didResignActive`）自動復原與 `SidebarResizeHandle` 狀態回呼**

1. 修改 `App/Sources/LmuxUI/RootView.swift` 的 `SidebarBackdrop`（`:256-303`）：
```swift
final class SidebarBackdrop: NSView {
    let material = NSVisualEffectView()
    let tint = ColorView(T.Colors.sidebarTint.nsColor)
    let specular = ColorView(T.Colors.specularHighlight.nsColor)
    /// Forced opaque (headless snapshots, tests).
    var forceOpaque = false { didSet { update() } }
    /// Set while dragging a resize handle / split divider or during window live resize to pause blur recomputation.
    var isResizing = false { didSet { if isResizing != oldValue { update() } } }
    /// The terminal's background when the sidebar matches it (setting), else nil (translucent Nord).
    var matchColor: NSColor? { didSet { update() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        addSubview(material)
        addSubview(tint)
        addSubview(specular)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isOpaqueFallback: Bool {
        forceOpaque || isResizing || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private func update() {
        if let c = matchColor {
            material.isHidden = true
            specular.isHidden = true
            tint.color = c
            return
        }
        let opaque = isOpaqueFallback
        material.isHidden = opaque
        specular.isHidden = opaque
        tint.color = (opaque ? T.Colors.sidebarBackground : T.Colors.sidebarTint).nsColor
        specular.color = T.Colors.specularHighlight.nsColor
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        tint.frame = bounds
        specular.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: min(1, bounds.height))
    }
}
```

2. 修改 `SidebarResizeHandle`（`RootView.swift:482-493`）：
```swift
/// Invisible strip on the sidebar edge; drag to resize the sidebar.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        onDragStateChange?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let sv = superview else { return }
        onDrag?(sv.convert(event.locationInWindow, from: nil).x)
    }
    override func mouseUp(with event: NSEvent) {
        onDragStateChange?(false)
    }
}
```

3. 在 `RootView.init`（`RootView.swift:64-70`）綁定 `resizeHandle.onDragStateChange` 與視窗 live resize／`didResignKey`／`didResignActive` 通知：
```swift
        resizeHandle.onDrag = { [weak self] x in
            guard let self else { return }
            self.model.sidebarWidth = min(max(x, T.Layout.sidebarWidthMin), T.Layout.sidebarWidthMax)
            self.needsLayout = true
            self.controller?.scheduleSave()
        }
        resizeHandle.onDragStateChange = { [weak self] active in
            self?.sidebarBackdrop.isResizing = active
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = self.window, note.object as AnyObject? === w else { return }
                self.sidebarBackdrop.isResizing = true
            }
        }
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didResignKeyNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let w = self.window, note.object as AnyObject? === w else { return }
                    self.sidebarBackdrop.isResizing = false
                }
            }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sidebarBackdrop.isResizing = false
            }
        }
```

4. 在 `App/Sources/LmuxUI/SidebarAccessory.swift` 為 `LmuxController` 新增公開方法：
```swift
    /// 設定或查詢 sidebar 是否正處於拖曳調整大小狀態（拖曳時暫停毛玻璃模糊，放開後恢復）。
    public func setSidebarResizing(_ active: Bool) {
        root?.sidebarBackdrop.isResizing = active
    }

    public var isSidebarResizing: Bool {
        root?.sidebarBackdrop.isResizing ?? false
    }
```

- [ ] **Step 2: 連結 `vendor` 並以 `swift build` 驗證 `LmuxUI` 編譯通過**

Run:
```bash
ln -sfn /Users/jamis.liao/opensource/lmux/vendor vendor && swift build --package-path App --target LmuxUI
```
Expected: `Build complete!`（0 errors）。

- [ ] **Step 3: Commit**

```bash
git add App/Sources/LmuxUI/RootView.swift App/Sources/LmuxUI/SidebarAccessory.swift
git commit -m "feat(ui): add SidebarBackdrop specular edge and isResizing GPU guard"
```

---

### Task 3: 串接 `SplitContainerView` 分割線與 `BarResizeHandle` 調整手把（含居中膠囊指示條）的 `isResizing` 守護

**Files:**
- Modify: `App/Sources/LmuxUI/PaneViews.swift:212-275`
- Modify: `App/Sources/LmuxUI/Controller.swift:963-973`
- Modify: `App/Sources/LmuxNotificationBar/NotificationBar.swift:15-36`, `:65-140`

**Interfaces:**
- Consumes: `LmuxController.setSidebarResizing(_:)` (`SidebarAccessory.swift`), `LmuxTokens.Colors.dragHandlePill` / `dragHandlePillActive`, `LmuxTokens.Layout.dragHandlePillWidth` / `dragHandlePillHeight`
- Produces on `SplitContainerView` (`PaneViews.swift`):
  - `var onDragStateChange: ((Bool) -> Void)?`
- Produces on `BarLayout` (`NotificationBar.swift`):
  - `var isDragging: Bool`
  - `func beginDrag(on controller: LmuxController)`
  - `func updateDrag(translationHeight: CGFloat, maxExtra: CGFloat, on controller: LmuxController)`
  - `func endDrag(on controller: LmuxController)`

- [ ] **Step 1: 在 `SplitContainerView` 與 `Controller.buildView` 串接分割線拖曳狀態**

修改 `App/Sources/LmuxUI/PaneViews.swift`（`:218` 與 `:267-273`）：
```swift
    let divider = ColorView(T.Colors.separator.nsColor)
    var onRatioChange: (() -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    private let grab: CGFloat = 3  // extra hit area on each side of the divider
```
```swift
    override func mouseDown(with event: NSEvent) {
        onDragStateChange?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setRatio(forPosition: axis == .horizontal ? p.x : p.y)
    }

    override func mouseUp(with event: NSEvent) {
        onDragStateChange?(false)
    }
```

修改 `App/Sources/LmuxUI/Controller.swift` 的 `buildView(_:)`（`:967-971`）：
```swift
        case .split(let axis, let a, let b):
            let v = SplitContainerView(node: node, axis: axis, first: buildView(a), second: buildView(b))
            v.onRatioChange = { [weak self] in self?.scheduleSave() }
            v.onDragStateChange = { [weak self] active in self?.setSidebarResizing(active) }
            return v
```

- [ ] **Step 2: 升級 `BarLayout` 與 `BarResizeHandle`（`NotificationBar.swift`）加入居中膠囊指示條並串接 `setSidebarResizing`**

修改 `App/Sources/LmuxNotificationBar/NotificationBar.swift`：
1. 將 `handleHeight` 由 `5` 調整為 `6`（`:16`）：
```swift
    /// 最上緣的拖曳帶：1pt 分隔線在最上面，中央放膠囊指示條，整條都可以拖。
    static let handleHeight: CGFloat = 6
```
2. 在 `BarLayout`（`:65-74`）封裝拖曳生命週期方法，讓手勢與自動化測試共用同一套邏輯：
```swift
@MainActor @Observable
final class BarLayout {
    static let defaultsKey = "sidebarBarExtraHeight"
    var extra: CGFloat
    private(set) var dragStart: CGFloat?

    var isDragging: Bool { dragStart != nil }

    init() { extra = max(0, CGFloat(UserDefaults.standard.double(forKey: Self.defaultsKey))) }

    func beginDrag(on controller: LmuxController) {
        if dragStart == nil {
            dragStart = extra
            controller.setSidebarResizing(true)
        }
    }

    func updateDrag(translationHeight: CGFloat, maxExtra: CGFloat, on controller: LmuxController) {
        beginDrag(on: controller)
        let start = dragStart ?? extra
        // 往上拖（translation 為負）bar 變高。
        extra = min(max(0, start - translationHeight), max(0, maxExtra))
    }

    func endDrag(on controller: LmuxController) {
        dragStart = nil
        controller.setSidebarResizing(false)
        save()
    }

    /// 拖曳結束才寫入，拖曳過程中不必每一步都寫。
    func save() { UserDefaults.standard.set(Double(extra), forKey: Self.defaultsKey) }
}
```
3. 在 `NotificationBar.body`（`:91-93`）將 `controller` 傳入 `BarResizeHandle`，並更新 `BarResizeHandle`（`:105-140`）：
```swift
            BarResizeHandle(layout: layout, controller: controller) {
                controller.sidebarAccessoryMaxHeight - NotificationBarPlugin.minHeight(pluginRows: pluginRows.count)
            }
```
```swift
/// bar 最上緣：往上拖變高、往下拖變矮（不會低於最小高度），雙擊恢復自動高度。
struct BarResizeHandle: View {
    let layout: BarLayout
    let controller: LmuxController
    /// 以目前的視窗大小，`extra` 最多可以到多少。
    let maxExtra: () -> CGFloat
    @State private var hover = false

    static func pillColor(hover: Bool, isDragging: Bool) -> LmuxTokens.DynamicColor {
        (hover || isDragging) ? T.Colors.dragHandlePillActive : T.Colors.dragHandlePill
    }

    var body: some View {
        let pill = Self.pillColor(hover: hover, isDragging: layout.isDragging)
        ZStack(alignment: .top) {
            Rectangle().fill(T.Colors.separator.color).frame(height: 1)
            Capsule()
                .fill(pill.color)
                .frame(width: T.Layout.dragHandlePillWidth, height: T.Layout.dragHandlePillHeight)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: NotificationBarPlugin.handleHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            hover = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        // global 座標：bar 在拖曳中會跟著變高、位置會移動，用 local 座標的話位移量會抖動。
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                layout.updateDrag(translationHeight: value.translation.height, maxExtra: maxExtra(), on: controller)
            }
            .onEnded { _ in
                layout.endDrag(on: controller)
            })
        .onTapGesture(count: 2) {
            layout.extra = 0
            layout.save()
        }
        .help("Drag to resize, double-click to reset")
    }
}
```

- [ ] **Step 3: 執行 `swift build` 驗證 `LmuxNotificationBar` 與 `lmux` 編譯通過**

Run: `swift build --package-path App --target lmux`
Expected: `Build complete!`（0 errors）。

- [ ] **Step 4: Commit**

```bash
git add App/Sources/LmuxUI/PaneViews.swift App/Sources/LmuxUI/Controller.swift App/Sources/LmuxNotificationBar/NotificationBar.swift
git commit -m "feat(resize): wire split divider and notification bar handle to isResizing guard"
```

---

### Task 4: 升級 `WorkspaceRowContent`、`HistorySection`、`HistoryRow` 與 `NotificationCard` 的微透立體 `glassBorder` 邊框

**Files:**
- Modify: `App/Sources/LmuxUI/Sidebar.swift:343-356`
- Modify: `App/Sources/LmuxUI/History.swift:523-529`, `:578-582`
- Modify: `App/Sources/LmuxNotificationBar/NotificationCard.swift:77-96`

**Interfaces:**
- Consumes: `LmuxTokens.Colors.glassBorder`
- Produces:
  - `WorkspaceRowContent.showsGlassBorder(selected: Bool, inSelection: Bool) -> Bool` (`Sidebar.swift`)
  - `HistoryRow.showsGlassBorder(selected: Bool) -> Bool` (`History.swift`)
  - `NotificationCard.showsGlassBorder(highlighted: Bool, hover: Bool) -> Bool` (`NotificationCard.swift`)

- [ ] **Step 1: 在 `WorkspaceRowContent`、`HistorySection.field`、`HistoryRow` 與 `NotificationCard` 加上 `glassBorder` 細邊框**

1. 修改 `App/Sources/LmuxUI/Sidebar.swift`（`:343-356`）：
```swift
        .background(
            RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                .fill(pillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                        .strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)
                        .opacity(Self.showsGlassBorder(selected: selected, inSelection: inSelection) ? 1 : 0)
                )
        )
        .padding(.horizontal, T.Layout.rowInsetX)
    }

    static func showsGlassBorder(selected: Bool, inSelection: Bool) -> Bool {
        selected || inSelection
    }
```

2. 修改 `App/Sources/LmuxUI/History.swift`：
- 在 `HistorySection.field`（`:523-528`）加上未展開時的 `glassBorder` 微透立體邊框：
```swift
        .background(RoundedRectangle(cornerRadius: T.Radius.field, style: .continuous)
            .fill(focused ? T.Colors.elevatedBackground.color : (hoverField ? T.Colors.rowSelected.color : T.Colors.rowHover.color)))
        .overlay(RoundedRectangle(cornerRadius: T.Radius.field, style: .continuous)
            .strokeBorder(focused ? T.Colors.border.color : T.Colors.glassBorder.color, lineWidth: focused ? 1 : 0.5))
        .overlay(RoundedRectangle(cornerRadius: T.Radius.field + 2.5, style: .continuous)
            .stroke(T.Colors.focusRing.color, lineWidth: 2.5).padding(-2.5).opacity(focused ? 1 : 0))
```
- 在 `HistoryRow`（`:579-595`）為選取中的搜尋結果列加上 `glassBorder` 微透邊框：
```swift
        .background(
            RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                .fill(selected ? T.Colors.rowSelected.color : (hover ? T.Colors.rowHover.color : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                        .strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)
                        .opacity(Self.showsGlassBorder(selected: selected) ? 1 : 0)
                )
        )
        .padding(.horizontal, T.Layout.rowInsetX)
```
並在 `HistoryRow` 內新增：
```swift
    static func showsGlassBorder(selected: Bool) -> Bool { selected }
```

3. 修改 `App/Sources/LmuxNotificationBar/NotificationCard.swift`（`:77-96`）：
```swift
        .background(
            RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                .fill(background)
                .overlay(
                    RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                        .strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5)
                        .opacity(Self.showsGlassBorder(highlighted: highlighted, hover: hover) ? 1 : 0)
                )
        )
```
並在 `NotificationCard` 內新增：
```swift
    static func showsGlassBorder(highlighted: Bool, hover: Bool) -> Bool {
        highlighted || hover
    }
```

- [ ] **Step 2: 執行 `swift build` 驗證編譯通過**

Run: `swift build --package-path App --target lmux`
Expected: `Build complete!`（0 errors）。

- [ ] **Step 3: Commit**

```bash
git add App/Sources/LmuxUI/Sidebar.swift App/Sources/LmuxUI/History.swift App/Sources/LmuxNotificationBar/NotificationCard.swift
git commit -m "feat(ui): apply Liquid Glass translucent border to selected rows, cards, and search field"
```

---

### Task 5: 升級內建預覽 tab（`MarkdownHTML.swift`）為雙主題 Liquid Glass 卡片與減少透明度降級

**Files:**
- Modify: `App/Sources/LmuxUI/MarkdownHTML.swift:392-407`
- Modify: `App/scripts/liquid-glass-app-check.swift`

**Interfaces:**
- Modifies `MarkdownHTML.css` (`App/Sources/LmuxUI/MarkdownHTML.swift`), preserving `--bg:#ffffff;--fg:#24292f` (light) and `--bg:#0d1117;--fg:#e6edf3` (dark) as well as `MarkdownHTML.page(_:title:)`, `MarkdownHTML.textPage(_:title:)`, `MarkdownHTML.csp`, and `MarkdownHTML.textCSP`.

- [ ] **Step 1: 在 `App/scripts/liquid-glass-app-check.swift` 新增 `MarkdownHTML` 的 Liquid Glass 樣式與降級檢查（先寫失敗測試）**

在 `App/scripts/liquid-glass-app-check.swift` 的 `main()`（`print(failures == 0 ...)` 之前）加入：
```swift
        // 3. MarkdownHTML 預覽頁雙主題 Liquid Glass 樣式與無障礙降級檢查
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
            html.contains("<pre><code>") &&
            html.contains("class=\"callout") &&
            html.contains("<table><thead>")
        )
        check(
            "MarkdownHTML 包含 prefers-reduced-transparency 與 prefers-reduced-motion 降級規則",
            html.contains("@media (prefers-reduced-transparency: reduce)") &&
            html.contains("@media (prefers-reduced-motion: reduce)")
        )
```

- [ ] **Step 2: 執行 `dev.sh check` 確認新測試先失敗（紅燈）**

Run: `beat/changes/preview-liquid-glass/dev.sh check`
Expected: `FAIL  MarkdownHTML 包含淺深雙主題 Liquid Glass 變數、頂部內高光與 pre/blockquote/callout/table 卡片規則`。

- [ ] **Step 3: 更新 `App/Sources/LmuxUI/MarkdownHTML.swift` 的 `static let css`**

修改 `App/Sources/LmuxUI/MarkdownHTML.swift`（`:392-407`）：
```swift
    /// 樣式表：淺色與深色兩組顏色與 Liquid Glass 卡片表面，跟著 `prefers-color-scheme` 切換（WKWebView 跟著 lmux 的外觀設定），
    /// 並在系統開啟 `prefers-reduced-transparency` 或 `prefers-reduced-motion` 時自動降級。
    static let css = """
    :root{--bg:#ffffff;--fg:#24292f;--muted:#57606a;--border:#d0d7de;--code-bg:#f6f8fa;--glass-surface:rgba(246,248,250,0.78);--glass-border:rgba(36,41,47,0.10);--glass-highlight:rgba(255,255,255,0.82);--glass-shadow:0 4px 14px rgba(15,23,42,0.04);--link:#0969da;--note:#0969da;--tip:#1a7f37;--important:#8250df;--warning:#9a6700;--caution:#cf222e}
    @media (prefers-color-scheme: dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8d96a0;--border:#30363d;--code-bg:#161b22;--glass-surface:rgba(22,27,34,0.78);--glass-border:rgba(255,255,255,0.10);--glass-highlight:rgba(255,255,255,0.12);--glass-shadow:0 8px 22px rgba(0,0,0,0.28);--link:#4493f8;--note:#4493f8;--tip:#3fb950;--important:#ab7df8;--warning:#d29922;--caution:#f85149}}
    @media (prefers-reduced-transparency: reduce){:root{--glass-surface:#f6f8fa;--glass-highlight:transparent;--glass-shadow:none}@media (prefers-color-scheme: dark){:root{--glass-surface:#161b22;--glass-highlight:transparent;--glass-shadow:none}}}
    @media (prefers-reduced-motion: reduce){*,*::before,*::after{animation-duration:0.01ms !important;transition-duration:0.01ms !important}}
    html{background:var(--bg);color:var(--fg)}body{margin:0;font:15px/1.6 -apple-system,"PingFang TC",sans-serif}article{max-width:880px;margin:0 auto;padding:24px 32px}
    a{color:var(--link)}h1,h2{border-bottom:1px solid var(--border);padding-bottom:.3em}
    code{font:13px ui-monospace,Menlo,monospace;background:var(--code-bg);padding:.1em .3em;border-radius:4px}
    pre{background:var(--glass-surface);padding:12px 16px;border-radius:8px;border:1px solid var(--glass-border);box-shadow:inset 0 1px 0 var(--glass-highlight),var(--glass-shadow);overflow:auto}pre code{padding:0;background:none}
    blockquote{margin:0 0 1em;padding:8px 1em;color:var(--muted);background:var(--glass-surface);border:1px solid var(--glass-border);border-left:4px solid var(--border);border-radius:8px;box-shadow:inset 0 1px 0 var(--glass-highlight)}
    .callout{color:var(--fg);border-left-color:var(--note)}.callout-title{font-weight:600;color:var(--note)}
    .callout-tip{border-left-color:var(--tip)}.callout-tip .callout-title{color:var(--tip)}.callout-important{border-left-color:var(--important)}.callout-important .callout-title{color:var(--important)}
    .callout-warning{border-left-color:var(--warning)}.callout-warning .callout-title{color:var(--warning)}.callout-caution{border-left-color:var(--caution)}.callout-caution .callout-title{color:var(--caution)}
    pre.plain{white-space:pre-wrap;overflow-wrap:anywhere;overflow:visible}pre.plain code{white-space:inherit}
    table{border-collapse:collapse;margin:0 0 1em;background:var(--glass-surface);box-shadow:inset 0 1px 0 var(--glass-highlight)}th,td{border:1px solid var(--border);padding:6px 13px}th{background:var(--code-bg)}img{max-width:100%}li>p{margin:0}hr{border:0;border-top:1px solid var(--border)}
    """
```

- [ ] **Step 4: 執行 `dev.sh check` 與 `App/scripts/apptest.sh --preview` 確認全部綠燈**

Run: `beat/changes/preview-liquid-glass/dev.sh check && App/scripts/apptest.sh --preview`
Expected: `APP TOKEN CHECK: ok`、`MOCKUP CHECK: ok`，且 `--preview` 套件全數 `PASS`。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/LmuxUI/MarkdownHTML.swift App/scripts/liquid-glass-app-check.swift
git commit -m "feat(preview): style MarkdownHTML with dual-theme Liquid Glass surfaces and reduced-transparency fallback"
```

---

### Task 6: 新增 `--liquid-glass` `@e2e` 測試套件、補齊 `# @covered-by:` 標註並建置啟動 `App/build/lmux.app`

**Files:**
- Modify: `App/Package.swift:70-77`
- Create: `App/Sources/lmux-apptest/LiquidGlass.swift`
- Modify: `App/Sources/lmux-apptest/main.swift:76-95`
- Modify: `App/scripts/apptest.sh:140-152`
- Modify: `beat/changes/preview-liquid-glass/dev.sh`
- Modify: `beat/changes/preview-liquid-glass/features/liquid-glass-app.feature`

**Interfaces:**
- Consumes: `SidebarBackdrop`, `SidebarResizeHandle`, `SplitContainerView`, `LmuxController.setSidebarResizing(_:)` / `isSidebarResizing`, `NotificationBarPlugin`, `BarLayout`, `BarResizeHandle`, `NotificationCard`, `WorkspaceRowContent`, `HistoryRow`
- Produces: `runLiquidGlass() async -> Int32` (`App/Sources/lmux-apptest/LiquidGlass.swift`), `lmux-apptest --liquid-glass`, `App/scripts/apptest.sh --liquid-glass`

- [ ] **Step 1: 在 `App/Package.swift` 將 `LmuxNotificationBar` 連結至 `lmux-apptest`，並建立 `App/Sources/lmux-apptest/LiquidGlass.swift`**

1. 修改 `App/Package.swift`（`:70-77`）在 `lmux-apptest` 的 `dependencies` 加入 `"LmuxNotificationBar"`：
```swift
        .executableTarget(
            name: "lmux-apptest",
            dependencies: ["LmuxUI", "LmuxTerminal", "LmuxTokens", "LmuxNotificationBar", "GhosttyKit",
                           .product(name: "LmuxHooks", package: "Core"),
                           .product(name: "LmuxTranscript", package: "Core"),
                           .product(name: "LmuxSessions", package: "Core")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

2. 建立 `App/Sources/lmux-apptest/LiquidGlass.swift`：
```swift
// @feature: liquid-glass-app.feature
// @scenario: Sidebar 背景在一般狀態顯示毛玻璃與頂部亮邊，並在系統開啟減少透明度時改用不透明實底
// @scenario: 拖曳調整面板或分割窗格期間暫停毛玻璃並在放開後恢復
// @scenario: 拖曳途中視窗失去焦點時自動解除拖曳降級並恢復毛玻璃
// @scenario: 選取中的 workspace 列、反白通知卡片與通知 bar 調整手把呈現立體玻璃細節

import AppKit
import LmuxTokens
@testable import LmuxNotificationBar
@testable import LmuxUI

@MainActor
func runLiquidGlass() async -> Int32 {
    let r = Report()
    let c = makeController()
    let w = c.window!
    r.section = "liquid-glass"

    func mouseEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 200, y: 200),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: w.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )!
    }

    // 1. SidebarBackdrop 一般毛玻璃 + 1pt 頂部亮邊 vs 不透明實底與跟隨終端機底色
    let bd = c.root.sidebarBackdrop
    let savedForceOpaque = bd.forceOpaque
    let savedMatch = bd.matchColor
    bd.matchColor = nil
    bd.forceOpaque = false
    bd.isResizing = false
    c.root.layoutSubtreeIfNeeded()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
        r.check("SidebarBackdrop: translucent material and 1pt top specular edge shown when idle",
                !bd.isOpaqueFallback && !bd.material.isHidden && !bd.specular.isHidden && bd.specular.frame.height == 1)
    }
    bd.forceOpaque = true
    r.check("SidebarBackdrop: opaque fallback hides NSVisualEffectView and specular edge",
            bd.isOpaqueFallback && bd.material.isHidden && bd.specular.isHidden)
    bd.forceOpaque = false
    bd.matchColor = .black
    r.check("SidebarBackdrop: terminal matchColor hides NSVisualEffectView and specular edge",
            bd.material.isHidden && bd.specular.isHidden)
    bd.matchColor = nil

    // 2. 四種拖曳調整大小目標期間暫停毛玻璃並在放開後恢復
    // (a) sidebar 寬度手把
    c.root.resizeHandle.mouseDown(with: mouseEvent(.leftMouseDown))
    r.check("SidebarResizeHandle mouseDown pauses blur (isResizing == true)",
            bd.isResizing && bd.isOpaqueFallback && bd.material.isHidden && bd.specular.isHidden)
    c.root.resizeHandle.mouseUp(with: mouseEvent(.leftMouseUp))
    r.check("SidebarResizeHandle mouseUp restores blur (isResizing == false)", !bd.isResizing)

    // (b) 窗格分割線
    if let ws = c.model.selected, let p0 = ws.focusedPane {
        let pSplit = c.split(p0, .right)
        if let sv = c.splitView(for: ws.root) {
            sv.mouseDown(with: mouseEvent(.leftMouseDown))
            r.check("SplitContainerView divider mouseDown pauses blur", bd.isResizing && bd.isOpaqueFallback && bd.material.isHidden)
            sv.mouseUp(with: mouseEvent(.leftMouseUp))
            r.check("SplitContainerView divider mouseUp restores blur", !bd.isResizing)
        } else {
            r.check("SplitContainerView created for split workspace", false)
        }
        if let pSplit { c.closePane(pSplit) }
    }

    // (c) 通知 bar 高度手把（安裝 NotificationBarPlugin 並透過 BarLayout 驅動拖曳）
    NotificationBarPlugin.install(on: c)
    c.root.layoutSubtreeIfNeeded()
    let barLayout = BarLayout()
    let savedExtra = barLayout.extra
    barLayout.updateDrag(translationHeight: -40, maxExtra: 200, on: c)
    r.check("BarResizeHandle / BarLayout drag pauses blur and increases bar height",
            barLayout.isDragging && c.isSidebarResizing && bd.isOpaqueFallback && barLayout.extra == savedExtra + 40)
    barLayout.endDrag(on: c)
    r.check("BarResizeHandle / BarLayout endDrag restores blur", !barLayout.isDragging && !c.isSidebarResizing && !bd.isResizing)
    barLayout.extra = savedExtra
    barLayout.save()

    // (d) 視窗邊緣縮放（willStartLiveResize -> didEndLiveResize）
    NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: w)
    r.check("Window willStartLiveResize pauses blur", bd.isResizing && bd.isOpaqueFallback && bd.material.isHidden)
    NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: w)
    r.check("Window didEndLiveResize restores blur", !bd.isResizing)

    // 3. 拖曳途中視窗或應用程式失去焦點時自動解除拖曳降級
    c.setSidebarResizing(true)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: w)
    r.check("Window didResignKey mid-drag clears isResizing", !bd.isResizing)

    c.setSidebarResizing(true)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    r.check("App didResignActive mid-drag clears isResizing", !bd.isResizing)

    // 4. 選取中的 workspace 列、反白通知卡片與通知 bar 調整手把呈現立體玻璃細節
    r.check("WorkspaceRowContent & HistoryRow show glassBorder only when selected",
            WorkspaceRowContent.showsGlassBorder(selected: true, inSelection: false) &&
            WorkspaceRowContent.showsGlassBorder(selected: false, inSelection: true) &&
            !WorkspaceRowContent.showsGlassBorder(selected: false, inSelection: false) &&
            HistoryRow.showsGlassBorder(selected: true) &&
            !HistoryRow.showsGlassBorder(selected: false))
    r.check("NotificationCard shows glassBorder when highlighted or hovered, and BarResizeHandle pill highlights when active",
            NotificationCard.showsGlassBorder(highlighted: true, hover: false) &&
            NotificationCard.showsGlassBorder(highlighted: false, hover: true) &&
            !NotificationCard.showsGlassBorder(highlighted: false, hover: false) &&
            NotificationBarPlugin.handleHeight == 6 &&
            BarResizeHandle.pillColor(hover: false, isDragging: false).lightAlpha < BarResizeHandle.pillColor(hover: true, isDragging: false).lightAlpha &&
            BarResizeHandle.pillColor(hover: false, isDragging: false).darkAlpha < BarResizeHandle.pillColor(hover: false, isDragging: true).darkAlpha)

    bd.matchColor = savedMatch
    bd.forceOpaque = savedForceOpaque
    return finish(r, c)
}
```

3. 在 `App/Sources/lmux-apptest/main.swift`（`:85` 附近）加入 `--liquid-glass` 分支：
```swift
            } else if args.contains("--liquid-glass") {
                code = await runLiquidGlass()
```

4. 在 `App/scripts/apptest.sh`（`:150` `--sidebar-tabs` 區塊下方）加入 `--liquid-glass` 支援，並在主流程呼叫 `run_liquid_glass_suite`：
```bash
run_liquid_glass_suite() {
  mkdir -p "$T/liquid-glass"
  LMUX_STATE_DIR="$T/liquid-glass" LMUX_IGNORE_GHOSTTY_CONFIG=1 LMUX_PANE_COMMAND="$T/sink.sh" \
    "$BIN/lmux-apptest" --liquid-glass 2>/dev/null | filter || status=1
}
if [ "${1:-}" = "--liquid-glass" ]; then
  run_liquid_glass_suite
  exit $status
fi
```
（並在 `run_sidebar_tabs_suite` 下方加一行 `run_liquid_glass_suite`。）

5. 更新 `beat/changes/preview-liquid-glass/dev.sh` 的 `check)` 分支，使其一併執行 `App/scripts/apptest.sh --liquid-glass`：
```bash
  check)
    swiftc -parse-as-library -o "$OUT/liquid-glass-app-check" \
      App/Sources/LmuxTokens/Tokens.swift \
      App/Sources/LmuxUI/MarkdownHTML.swift \
      App/scripts/liquid-glass-app-check.swift \
      && "$OUT/liquid-glass-app-check" \
      && App/scripts/apptest.sh --liquid-glass \
      && swiftc -parse-as-library -o "$OUT/liquid-glass-mockup-check" \
        App/scripts/liquid-glass-mockup-check*.swift \
      && "$OUT/liquid-glass-mockup-check" ;;
```

- [ ] **Step 2: 為 `beat/changes/preview-liquid-glass/features/liquid-glass-app.feature` 全部 6 個場景補上 `# @covered-by:` 標註**

在 `liquid-glass-app.feature` 每個場景的標籤列與 `場景:`／`場景大綱:` 列之間加上對應的 `# @covered-by:`：
- 場景 1（`淺色與深色外觀下提供具備頂部高光與無障礙對比的玻璃視覺設定`）：`# @covered-by: App/scripts/liquid-glass-app-check.swift`
- 場景 2（`Sidebar 背景在一般狀態顯示毛玻璃與頂部亮邊，並在系統開啟減少透明度時改用不透明實底`）：`# @covered-by: App/Sources/lmux-apptest/LiquidGlass.swift`
- 場景 3（`拖曳調整面板或分割窗格期間暫停毛玻璃並在放開後恢復`）：`# @covered-by: App/Sources/lmux-apptest/LiquidGlass.swift`
- 場景 4（`拖曳途中視窗失去焦點時自動解除拖曳降級並恢復毛玻璃`）：`# @covered-by: App/Sources/lmux-apptest/LiquidGlass.swift`
- 場景 5（`選取中的 workspace 列、反白通知卡片與通知 bar 調整手把呈現立體玻璃細節`）：`# @covered-by: App/Sources/lmux-apptest/LiquidGlass.swift`
- 場景 6（`預覽 tab 渲染 Markdown 檔案時套用雙主題玻璃卡片樣式與減少透明度降級規則`）：`# @covered-by: App/scripts/liquid-glass-app-check.swift`

- [ ] **Step 3: 執行 `dev.sh check`、`App/scripts/apptest.sh --preview` 與 `App/scripts/bundle.sh` 建置並啟動 `App/build/lmux.app`**

Run:
```bash
beat/changes/preview-liquid-glass/dev.sh check && App/scripts/apptest.sh --preview && App/scripts/bundle.sh && open App/build/lmux.app
```
Expected:
- `APP TOKEN CHECK: ok`
- `--liquid-glass` `@e2e` 測試全數 `PASS`
- `MOCKUP CHECK: ok`
- `--preview` 測試全數 `PASS`
- `App/scripts/bundle.sh` 產出 `App/build/lmux.app` 並成功啟動供使用者測試。

- [ ] **Step 4: Commit**

```bash
git add App/Package.swift App/Sources/lmux-apptest/LiquidGlass.swift App/Sources/lmux-apptest/main.swift App/scripts/apptest.sh beat/changes/preview-liquid-glass/dev.sh beat/changes/preview-liquid-glass/features/liquid-glass-app.feature
git commit -m "test(liquid-glass): add apptest --liquid-glass e2e suite and @covered-by annotations"
```
