# 純文字檔的預覽 — 實作計畫

> **給執行的 agent：** 照順序一次做一個 task。每個 step 做完，把 `- [ ]` 改成 `- [x]`。

**Goal:** ⌘-click 終端機裡 macOS 判斷為純文字的檔案（例如 `.sh`、`.yaml`、`.log`）時也跳出開啟選單，「在新 tab 預覽」以等寬字型原樣顯示內容，不執行。

**Architecture:** `PreviewTarget` 新增 `Kind`（markdown／html／text），用 UTType 判斷純文字。純文字檔和 Markdown 一樣走 `lmux-preview` scheme，由 `MarkdownHTML.textPage` 產生跳脫過的 `<pre>` 頁面；scheme 只在整頁請求時回應純文字檔。`PreviewView` 與導覽規則把「走 scheme」從「是 Markdown」改成「是 Markdown 或純文字檔」；頁面裡連到純文字檔的連結仍然不換頁。最後才讓 `resolve` 接受純文字檔，所以每個 commit 都不會出現「跳出選單卻顯示錯誤頁」的中間狀態。

**Tech Stack:** Swift 5 語言模式、SwiftPM、AppKit、WebKit、Foundation、UniformTypeIdentifiers。沒有第三方依賴。

**規格來源：** `beat/changes/plain-text-preview/` 的 `proposal.md`、`design.md`、`features/plain-text-preview.feature`、`features/open-menu.feature`。

**plan 階段的驗證：** Task 1–6 的程式碼與檢查，已在 repo 外的複本依 task 順序套用、編譯並執行：每個「確認失敗」與「確認通過」的預期都是實際輸出。Task 7 的 apptest 程式碼**沒有編譯過**（plan 階段沒有執行 apptest 的權限）。

## Global Constraints

- 只在 worktree `/Users/jamis.liao/opensource/lmux/.worktrees/feat/plain-text-preview` 裡工作。不要 `cd` 到 `/Users/jamis.liao/opensource/lmux`（那是 main）。
- 不新增任何第三方依賴。只用 Apple 的框架：Foundation、AppKit、WebKit、UniformTypeIdentifiers。
- 只改每個 task 的「Files」列出的檔案。看到其他想改的地方，記下來，最後回報，不要改。
- 程式碼註解用繁體中文。
- build、測試一律用 `beat/changes/plain-text-preview/dev.sh`（Task 0 建立）。它會先 `unset LMUX_*` 變數：這個 session 跑在使用者正在用的 lmux 裡，不 unset 的話，測試會送進使用者的 lmux。
- 每個 task 結束都要 commit。commit message 用繁體中文，結尾加一行 `Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>`。
- 不可以 `git push`。不可以 `git commit --no-verify`。
- 不可以為了讓測試通過而修改測試的預期值。
- **停止規則：** 驗證的結果跟「預期」不同時，最多修兩次。兩次後還是不同，就停下來，回報：task 編號、跑的指令、完整輸出。不要自己換做法。
  - 寫著「確認失敗」的步驟：結果跟預期不同（例如沒有失敗），就停下來回報。不要為了讓它失敗去改程式。
- **WebKit 檢查的偶發失敗：** 機器忙時，既有的 HTML 載入檢查會偶發失敗（plan 階段在 load average 14 時，**未修改**的程式也失敗過 `FAIL  rootA/index.html 載入`）。`webkit` 有 FAIL、但那一項名稱不含「純文字」，也不是這個 task 寫明的預期失敗時：等 60 秒重跑一次。第二次通過就算通過，回報時寫明重跑過。
- **跑很久的指令：** `apptest-quick` 要幾分鐘。工具有逾時限制時，改成背景執行再輪詢：
  `nohup beat/changes/plain-text-preview/dev.sh apptest-quick > "${TMPDIR:-/tmp}/plain-text-preview/run.out" 2>&1 &`，之後每 60 秒跑一次 `tail -3 "${TMPDIR:-/tmp}/plain-text-preview/run.out"`，看到 `APPTEST EXIT:` 才算跑完。
- **apptest 的結束碼：** 起點本來就有 FAIL 時，`APPTEST EXIT` 不會是 0，這不算失敗。回歸只看 `new-failures` 的 `NEW FAILURES` 與 `MISSING CHECKS` 是不是 0。

## Quality Principles

**Testing:** Tests verify behavior (return values, state changes, responses), not wiring.
If the main assertion is `toHaveBeenCalledWith`, rewrite to assert on the function's output.

**Code:** No single new file exceeds ~300 lines. If it grows past that, split into focused sub-modules.

## 共用指令（`dev.sh`，Task 0 建立）

| 指令 | 做什麼 | 成功時最後一行 |
|---|---|---|
| `beat/changes/plain-text-preview/dev.sh build` | build 整個 App package | `BUILD EXIT: 0` |
| `beat/changes/plain-text-preview/dev.sh errors A.swift B.swift` | build，只列出這些檔案的 error | `ERRORS TOTAL: 0` |
| `beat/changes/plain-text-preview/dev.sh check` | 編譯並執行 `App/scripts/preview-check.swift` | `preview check: ok` |
| `beat/changes/plain-text-preview/dev.sh webkit` | 編譯並執行 `App/scripts/preview-webkit-check*.swift`（約 60 秒） | `WEBKIT CHECK: ok` |
| `beat/changes/plain-text-preview/dev.sh apptest-preview` | 只跑 apptest 的預覽那一組 | 看 `new-failures preview` |
| `beat/changes/plain-text-preview/dev.sh apptest-quick` | apptest 主要那一輪（幾分鐘） | 看 `new-failures quick` |
| `beat/changes/plain-text-preview/dev.sh new-failures preview` 或 `quick` | 跟 Task 0 的基準比：多出來的 FAIL、不見的檢查 | `NEW FAILURES: 0` 與 `MISSING CHECKS: 0` |

## 檔案一覽

| 檔案 | 新增／修改 | 負責 | Task |
|---|---|---|---|
| `beat/changes/plain-text-preview/dev.sh` | 新增 | 實作用的指令 | 0 |
| `App/Sources/LmuxUI/PreviewTarget.swift` | 修改 | `Kind`、`kind`、`isText`、`usesPreviewScheme`（1）；`resolve` 接受純文字檔、刪除 `extensions`（6） | 1、6 |
| `App/Sources/LmuxUI/MarkdownHTML.swift` | 修改 | `textPage`、`textCSP`；CSS 加 `pre.plain` | 2 |
| `App/Sources/LmuxUI/PreviewScheme.swift` | 修改 | 純文字檔只當整頁回應 | 3 |
| `App/Sources/LmuxUI/PreviewView.swift` | 修改 | 純文字檔走 scheme（4）；監看直接重新載入（5） | 4、5 |
| `App/Sources/LmuxUI/PreviewViewNavigation.swift` | 修改 | 純文字檔的導覽規則 | 4 |
| `App/scripts/preview-check.swift` | 修改 | 種類判斷（1）、`textPage`（2）、`resolve`（6） | 1、2、6 |
| `App/scripts/preview-webkit-check-text.swift` | 新增 | 純文字檔在真的 WKWebView 裡的檢查 | 3、4、5 |
| `App/scripts/preview-webkit-check.swift` | 修改 | 呼叫新的檢查；總時限 120 → 240 秒 | 3、4、5 |
| `App/Sources/lmux-apptest/PreviewInteractions.swift` | 修改 | 「不是可預覽檔案」的例子從 `notes.txt` 改成 `icon.svg` | 6 |
| `App/Sources/lmux-apptest/PreviewText.swift` | 新增 | ⌘-click → 選單 → 預覽 tab、外觀、自動更新、`.sh`／`.command` 被擋 | 7 |
| `App/Sources/lmux-apptest/Preview.swift` | 修改 | 呼叫 `runPreviewTextChecks` | 7 |
| `beat/changes/plain-text-preview/features/plain-text-preview.feature` | 修改 | `@covered-by` | 8 |
| `App/README.md`、`docs/features.md` | 修改 | 說明可預覽純文字檔 | 8 |

---

### Task 0: 建立 dev.sh，確認起點能 build、記錄基準

**Files:**
- Create: `beat/changes/plain-text-preview/dev.sh`

**Interfaces:**
- Produces: `dev.sh` 的子指令（見「共用指令」）。`$TMPDIR/plain-text-preview/baseline-preview.log`、`baseline-quick.log`：起點的 apptest 結果。

- [x] **Step 1: 確認 worktree 有 `vendor`（build 需要 libghostty）**

```bash
cd /Users/jamis.liao/opensource/lmux/.worktrees/feat/plain-text-preview
[ -e vendor ] || ln -s /Users/jamis.liao/opensource/lmux/vendor vendor
ls vendor/ghostty/macos/GhosttyKit.xcframework/Info.plist
git status --short
```

預期：印出 `vendor/ghostty/macos/GhosttyKit.xcframework/Info.plist`；`git status --short` 沒有 `vendor`（`.gitignore` 第 4 行忽略它）。

- [x] **Step 2: 建立 `beat/changes/plain-text-preview/dev.sh`，內容如下（整份照抄），再加執行權限**

```bash
#!/bin/bash
# plain-text-preview 實作用的指令（給照 tasks.md 實作的 agent 用）。在 worktree 的任何位置執行：
#   beat/changes/plain-text-preview/dev.sh build                build 整個 App package，印出最後 40 行與結束碼
#   beat/changes/plain-text-preview/dev.sh errors 檔名...        build，只列出這些檔案（只寫檔名，例如 Agent.swift）的 error
#   beat/changes/plain-text-preview/dev.sh check                編譯並執行 App/scripts/preview-check.swift
#   beat/changes/plain-text-preview/dev.sh webkit               編譯並執行 App/scripts/preview-webkit-check.swift
#   beat/changes/plain-text-preview/dev.sh apptest-preview      只跑 apptest 的 --preview
#   beat/changes/plain-text-preview/dev.sh apptest-quick        apptest --quick（主要那一輪，要幾分鐘）
#   beat/changes/plain-text-preview/dev.sh new-failures preview|quick   跟 Task 0 的基準比：多出來的 FAIL、不見的檢查
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
# 不讓測試送進使用者正在用的 lmux；避開 Homebrew 的 GNU libtool。
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/usr/bin:$PATH"
OUT="${TMPDIR:-/tmp}/plain-text-preview"
mkdir -p "$OUT"
S=App/Sources/LmuxUI

# 這些檔案裡已經存在的那幾個（前面的 task 還沒建立的檔案不編譯）。
existing() {
  local list=()
  for f in "$@"; do [ -f "$S/$f.swift" ] && list+=("$S/$f.swift"); done
  echo "${list[@]}"
}

case "${1:-}" in
  build)
    (cd App && swift build 2>&1) > "$OUT/build.log"; code=$?
    tail -40 "$OUT/build.log"; echo "BUILD EXIT: $code"; exit $code ;;
  errors)
    shift
    (cd App && swift build 2>&1) > "$OUT/build.log"; code=$?
    total=0
    for f in "$@"; do
      grep -E "/${f}:[0-9]+:[0-9]+: error:" "$OUT/build.log" | sort -u > "$OUT/errors-one.txt"
      n=$(wc -l < "$OUT/errors-one.txt" | tr -d ' ')
      cat "$OUT/errors-one.txt"
      echo "ERRORS IN $f: $n"; total=$((total + n))
    done
    echo "ALL ERRORS IN BUILD: $(grep -cE ': error:' "$OUT/build.log")"
    echo "BUILD EXIT: $code"
    echo "ERRORS TOTAL: $total" ;;
  check)
    # shellcheck disable=SC2046
    swiftc -parse-as-library -o "$OUT/preview-check" $(existing PreviewTarget MarkdownHTML) App/scripts/preview-check.swift \
      && "$OUT/preview-check" ;;
  webkit)
    # shellcheck disable=SC2046,SC2086
    swiftc -parse-as-library -o "$OUT/preview-webkit-check" \
      $(existing PreviewTarget MarkdownHTML PreviewScheme PreviewWatcher PreviewView PreviewViewNavigation) App/scripts/preview-webkit-check*.swift \
      && "$OUT/preview-webkit-check" ;;
  apptest-preview)
    App/scripts/apptest.sh --preview > "$OUT/preview.log" 2>&1; code=$?
    grep -E '^(PASS|FAIL|RESULT)' "$OUT/preview.log"; echo "APPTEST EXIT: $code"; exit $code ;;
  apptest-quick)
    App/scripts/apptest.sh --quick > "$OUT/quick.log" 2>&1; code=$?
    grep -E '^(FAIL|RESULT)' "$OUT/quick.log"; echo "RESULT LINES: $(grep -c '^RESULT' "$OUT/quick.log")"
    echo "APPTEST EXIT: $code"; exit $code ;;
  new-failures)
    mode="${2:-quick}"
    # 只比檢查項目的名稱（去掉「  -- 細節」），細節裡的暫存路徑每次都不同。
    names() { grep "^$1" "$2" 2>/dev/null | sed 's/  -- .*//; s/^[A-Z]*  //' | sort -u; }
    comm -13 <(names FAIL "$OUT/baseline-$mode.log") <(names FAIL "$OUT/$mode.log") > "$OUT/new-failures.txt"
    # 基準有、這次完全沒出現的檢查（某一段當掉了，就不會印 FAIL，只會少掉）。
    comm -23 <(names PASS "$OUT/baseline-$mode.log") <(cat <(names PASS "$OUT/$mode.log") <(names FAIL "$OUT/$mode.log") | sort -u) > "$OUT/missing-checks.txt"
    cat "$OUT/new-failures.txt"
    echo "NEW FAILURES: $(wc -l < "$OUT/new-failures.txt" | tr -d ' ')"
    head -20 "$OUT/missing-checks.txt"
    echo "MISSING CHECKS: $(wc -l < "$OUT/missing-checks.txt" | tr -d ' ')" ;;
  *)
    sed -n 2,10p "$0"; exit 2 ;;
esac
```

```bash
chmod +x beat/changes/plain-text-preview/dev.sh
```

- [x] **Step 3: 確認起點能 build、兩個預覽檢查都通過，記下 webkit 花的時間**

```bash
beat/changes/plain-text-preview/dev.sh build | tail -1
beat/changes/plain-text-preview/dev.sh check | tail -1
time beat/changes/plain-text-preview/dev.sh webkit | tail -1
```

預期：`BUILD EXIT: 0`、`preview check: ok`、`WEBKIT CHECK: ok`。把 `time` 印出的 `real` 記下來，最後回報。

- [x] **Step 4: 記錄 apptest 基準（預覽那一組、主要那一輪）**

```bash
beat/changes/plain-text-preview/dev.sh apptest-preview | tail -1
cp "${TMPDIR:-/tmp}/plain-text-preview/preview.log" "${TMPDIR:-/tmp}/plain-text-preview/baseline-preview.log"
beat/changes/plain-text-preview/dev.sh apptest-quick | tail -1
cp "${TMPDIR:-/tmp}/plain-text-preview/quick.log" "${TMPDIR:-/tmp}/plain-text-preview/baseline-quick.log"
grep -c '^PASS' "${TMPDIR:-/tmp}/plain-text-preview/baseline-preview.log" "${TMPDIR:-/tmp}/plain-text-preview/baseline-quick.log"
```

預期：兩個 `APPTEST EXIT:` 行（不一定是 0）；兩個 baseline 檔的 PASS 數都大於 0。

- [x] **Step 5: Commit**

```bash
git add beat/changes/plain-text-preview/dev.sh
git commit -m "chore(plain-text-preview): 新增實作用的 dev.sh

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 1: PreviewTarget 新增種類判斷（行為不變）

**Files:**
- Modify: `App/Sources/LmuxUI/PreviewTarget.swift`（第 1 行 import、第 6 行 `extensions` 之後、第 127-128 行 `isHTML` 之後）
- Test: `App/scripts/preview-check.swift`

**Interfaces:**
- Produces（Task 3–7 會用）：
  - `enum PreviewTarget.Kind: Equatable { case markdown, html, text }`
  - `static func PreviewTarget.kind(_ url: URL) -> PreviewTarget.Kind?`（Markdown 與 HTML 沿用 `isMarkdown`／`isHTML`）
  - `static func PreviewTarget.isText(_ url: URL) -> Bool`
  - `static func PreviewTarget.usesPreviewScheme(_ url: URL) -> Bool`（Markdown 或純文字檔）
- 這個 task **不改** `resolve`，⌘-click 的行為不變（Task 6 才改）。

- [x] **Step 1: 修改測試 `App/scripts/preview-check.swift`（兩處）**

(a) 檔案開頭，原文：

```swift
import Foundation

@main
```

換成：

```swift
import Foundation
import UniformTypeIdentifiers

@main
```

(b) 原文：

```swift
        expect(!PreviewTarget.isHTML(URL(fileURLWithPath: design)), "isHTML .md")
```

換成：

```swift
        expect(!PreviewTarget.isHTML(URL(fileURLWithPath: design)), "isHTML .md")

        // @feature: plain-text-preview.feature
        // @scenario: ⌘-click 純文字檔的路徑跳出開啟選單
        // @scenario: macOS 不認為是純文字、或被排除的檔案，照原本流程
        // 判斷依本機 macOS 的類型登記：失敗訊息附上 UTType，換一台電腦失敗時看得出原因。
        func uti(_ name: String) -> String { UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? "nil" }
        let text = docs.appendingPathComponent("text")
        try? FileManager.default.createDirectory(at: text, withIntermediateDirectories: true)
        let textNames = ["todo.txt", "deploy.sh", "run.command", "app.yaml", "app.yml", "result.json", "run.log", "check.py", "LOUD.TXT"]
        // .env 與 Makefile 沒有副檔名（pathExtension 是空字串），不查 UTType 就不是純文字檔。
        let notTextNames = ["intro.rtf", "logo.svg", "app.ts", ".env", "Makefile", "photo.png", "notes.mdown"]
        for name in textNames + notTextNames {
            FileManager.default.createFile(atPath: text.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        for name in textNames {
            expect(PreviewTarget.kind(text.appendingPathComponent(name)) == .text, "\(name) 的種類是純文字檔（UTType：\(uti(name))）")
        }
        for name in notTextNames {
            expect(PreviewTarget.kind(text.appendingPathComponent(name)) == nil, "\(name) 不是可預覽檔案（UTType：\(uti(name))）")
        }
        expect(PreviewTarget.kind(URL(fileURLWithPath: design)) == .markdown, "kind：.md 是 Markdown")
        expect(PreviewTarget.kind(docs.appendingPathComponent("page.html")) == .html, "kind：.html 是 HTML")
        for u in (textNames + notTextNames).map({ text.appendingPathComponent($0) })
            + [URL(fileURLWithPath: design), docs.appendingPathComponent("page.html"), docs.appendingPathComponent("UPPER.MD")] {
            expect(PreviewTarget.isMarkdown(u) == (PreviewTarget.kind(u) == .markdown)
                   && PreviewTarget.isHTML(u) == (PreviewTarget.kind(u) == .html), "kind 與 isMarkdown／isHTML 一致：\(u.lastPathComponent)")
        }
        expect(PreviewTarget.isText(text.appendingPathComponent("app.yaml")) && !PreviewTarget.isText(URL(fileURLWithPath: design)),
               "isText：純文字檔是、Markdown 不是")
        expect(PreviewTarget.usesPreviewScheme(URL(fileURLWithPath: design))
               && PreviewTarget.usesPreviewScheme(text.appendingPathComponent("app.yaml"))
               && !PreviewTarget.usesPreviewScheme(docs.appendingPathComponent("page.html")),
               "Markdown 與純文字檔走 lmux-preview，HTML 不走")
```

- [x] **Step 2: 確認失敗**

Run: `beat/changes/plain-text-preview/dev.sh check`
預期：編譯失敗，訊息含 `type 'PreviewTarget' has no member 'kind'`。

- [x] **Step 3: 修改 `App/Sources/LmuxUI/PreviewTarget.swift`（三處）**

(a) 第 1 行，原文：

```swift
import Foundation
```

換成：

```swift
import Foundation
import UniformTypeIdentifiers
```

(b) 在 `extensions` 之後加上 `Kind` 與 `kind`。原文：

```swift
    static let extensions: Set<String> = ["md", "markdown", "html", "htm"]
```

換成：

```swift
    static let extensions: Set<String> = ["md", "markdown", "html", "htm"]

    /// 可預覽檔案的三種顯示方式（beat: plain-text-preview.feature）。
    enum Kind: Equatable { case markdown, html, text }

    private static let markdownType = UTType("net.daringfireball.markdown")

    /// 種類：Markdown 與 HTML 沿用 `isMarkdown`／`isHTML`（規則只有一份）；其他副檔名問 macOS，
    /// 屬於純文字（`public.text`）、而且不是 HTML、Markdown、RTF、SVG 的是純文字檔。都不是回傳 nil。
    /// 只看副檔名、不讀檔案：檔案被刪除後，監看仍要知道它是哪一種。
    static func kind(_ url: URL) -> Kind? {
        if isMarkdown(url) { return .markdown }
        if isHTML(url) { return .html }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .text) else { return nil }
        if type.conforms(to: .html) || type.conforms(to: .rtf) || type.conforms(to: .svg) { return nil }
        if let markdownType, type.conforms(to: markdownType) { return nil }
        return .text
    }
```

(c) 檔案最後，原文：

```swift
    /// HTML 檔案（由 WebView 直接載入）。
    static func isHTML(_ url: URL) -> Bool { ["html", "htm"].contains(url.pathExtension.lowercased()) }
```

換成：

```swift
    /// HTML 檔案（由 WebView 直接載入）。
    static func isHTML(_ url: URL) -> Bool { ["html", "htm"].contains(url.pathExtension.lowercased()) }

    /// 純文字檔（`kind` 是 `.text`）：由 `MarkdownHTML.textPage` 原樣顯示。
    static func isText(_ url: URL) -> Bool { kind(url) == .text }

    /// 經 `lmux-preview` scheme 顯示的檔案：Markdown 與純文字檔。HTML 不是（用 `loadFileURL`）。
    static func usesPreviewScheme(_ url: URL) -> Bool { isMarkdown(url) || isText(url) }
```

- [x] **Step 4: 確認通過**

Run: `beat/changes/plain-text-preview/dev.sh check`
預期：最後一行 `preview check: ok`。失敗訊息會附上 UTType（例如 `UTType：public.xhtml`）：如果是某個副檔名在這台電腦的判斷不同，照停止規則回報，附上這一行。

- [x] **Step 5: 確認整個 App 能 build**

Run: `beat/changes/plain-text-preview/dev.sh errors PreviewTarget.swift`
預期：`ERRORS TOTAL: 0` 與 `BUILD EXIT: 0`。

- [x] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/PreviewTarget.swift App/scripts/preview-check.swift
git commit -m "feat(plain-text-preview): PreviewTarget 新增 Kind，以 UTType 判斷純文字檔

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 2: MarkdownHTML.textPage 產生純文字頁面

**Files:**
- Modify: `App/Sources/LmuxUI/MarkdownHTML.swift`（`shellPage`、`missingPage` 上方、`body` 上方、`css` 的 `table{...}` 那一行上方）
- Test: `App/scripts/preview-check.swift`

**Interfaces:**
- Produces（Task 3 用）：`static func MarkdownHTML.textPage(_ text: String, title: String) -> String`，頁面結構 `<pre class="plain"><code>跳脫後的內容</code></pre>`；`static let MarkdownHTML.textCSP`（`default-src 'none'; style-src 'unsafe-inline'`，不允許任何載入）。
- `shellPage` 多一個參數 `csp`，預設值是原本的 `csp`，既有呼叫端不用改。

- [x] **Step 1: 在 `App/scripts/preview-check.swift` 加測試**

原文：

```swift
        print("preview check: ok")
```

換成：

```swift
        // @feature: plain-text-preview.feature
        // @scenario: 純文字檔以等寬字型原樣顯示
        // @scenario: 很長的一行自動換行
        let plain = MarkdownHTML.textPage("echo '<b>done</b>' & </code></pre><img src=x onerror=alert(1)>\n# 不是標題\n",
                                          title: "deploy<1>.sh")
        expect(plain.contains("<pre class=\"plain\"><code>echo &#39;&lt;b&gt;done&lt;/b&gt;&#39; &amp; &lt;/code&gt;&lt;/pre&gt;&lt;img src=x onerror=alert(1)&gt;\n# 不是標題\n</code></pre>"),
               "純文字原樣跳脫，跳不出 <pre>：\(plain)")
        expect(!plain.contains("<b>") && !plain.contains("<h1") && !plain.contains("<img"), "純文字不轉成 HTML 標籤：\(plain)")
        expect(plain.contains("<title>deploy&lt;1&gt;.sh</title>"), "純文字頁的標題是跳脫後的檔名")
        expect(plain.contains("Content-Security-Policy") && plain.contains("default-src 'none'") && !plain.contains("img-src"),
               "純文字頁的 CSP 不允許任何載入（連圖片都不行）")
        expect(plain.contains("pre.plain{white-space:pre-wrap;overflow-wrap:anywhere"), "純文字頁自動換行")
        expect(MarkdownHTML.page("# T", title: "t").contains("img-src lmux-preview:"), "Markdown 頁面的 CSP 不變")

        print("preview check: ok")
```

- [x] **Step 2: 確認失敗**

Run: `beat/changes/plain-text-preview/dev.sh check`
預期：編譯失敗，訊息含 `type 'MarkdownHTML' has no member 'textPage'`。

- [x] **Step 3: 修改 `App/Sources/LmuxUI/MarkdownHTML.swift`（四處）**

(a) 原文：

```swift
    private static func shellPage(title: String?, bodyHTML: String) -> String {
        let titleTag = title.map { "<title>\(escape($0))</title>" } ?? ""
        return "<!doctype html><html><head><meta charset=\"utf-8\">" + csp
```

換成：

```swift
    private static func shellPage(title: String?, bodyHTML: String, csp pageCSP: String = csp) -> String {
        let titleTag = title.map { "<title>\(escape($0))</title>" } ?? ""
        return "<!doctype html><html><head><meta charset=\"utf-8\">" + pageCSP
```

(b) 原文：

```swift
    /// 預覽中的檔案不存在時顯示的頁面。
```

換成：

```swift
    /// 純文字檔的整頁（beat: plain-text-preview.feature）：內容全部跳脫，放進等寬字型、會自動換行的 `<pre>`。
    /// 用比 Markdown 更嚴的 CSP：純文字頁用不到圖片，連圖片都不載入。
    static func textPage(_ text: String, title: String) -> String {
        shellPage(title: title, bodyHTML: "<pre class=\"plain\"><code>\(escape(text))</code></pre>", csp: textCSP)
    }

    /// 預覽中的檔案不存在時顯示的頁面。
```

(c) 原文：

```swift
    /// 轉好的 Markdown（HTML 片段）。
```

換成：

```swift
    /// 純文字頁的內容安全政策：什麼都不載入，只允許頁面自己的樣式。
    static let textCSP = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">"

    /// 轉好的 Markdown（HTML 片段）。
```

(d) `css` 裡，原文：

```swift
    table{border-collapse:collapse;margin:0 0 1em}
```

換成：

```swift
    pre.plain{white-space:pre-wrap;overflow-wrap:anywhere;overflow:visible}pre.plain code{white-space:inherit}
    table{border-collapse:collapse;margin:0 0 1em}
```

- [x] **Step 4: 確認通過**

Run: `beat/changes/plain-text-preview/dev.sh check`
預期：最後一行 `preview check: ok`。

- [x] **Step 5: Commit**

```bash
git add App/Sources/LmuxUI/MarkdownHTML.swift App/scripts/preview-check.swift
git commit -m "feat(plain-text-preview): MarkdownHTML 新增 textPage，以 <pre> 原樣顯示純文字

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 3: lmux-preview scheme 只在整頁請求時回應純文字檔

**Files:**
- Modify: `App/Sources/LmuxUI/PreviewScheme.swift`（第 5-6、11、16 行註解；`response(for:)` 的宣告與 Markdown 分支；`webView(_:start:)`）
- Create: `App/scripts/preview-webkit-check-text.swift`
- Modify: `App/scripts/preview-webkit-check.swift`（`main` 裡呼叫檢查的地方、第 128 行總時限）

**Interfaces:**
- Consumes: Task 1 的 `PreviewTarget.kind`、`isText`、`usesPreviewScheme`；Task 2 的 `MarkdownHTML.textPage`。
- Produces: `static func PreviewSchemeHandler.response(for file: URL, mainDocument: Bool = false) -> (data: Data, mime: String)?`。純文字檔只在 `mainDocument == true` 時回應；`webView(_:start:)` 用 `task.request.mainDocumentURL == url` 判斷（plan 階段實測：中文與空格的檔名也成立）。`PreviewWebKitCheck.textSchemeChecks(_:)`。

- [x] **Step 1: 建立 `App/scripts/preview-webkit-check-text.swift`，內容如下（整份照抄）**

```swift
import AppKit
import WebKit

// 純文字檔的預覽（beat/changes/plain-text-preview）在真的 WKWebView 裡的檢查。
// 由 preview-webkit-check.swift 的 main 呼叫；固定資料夾在 makeFixtures 建的 root 底下的 text/。
extension PreviewWebKitCheck {
    // @feature: plain-text-preview.feature
    // @scenario: 純文字檔以等寬字型原樣顯示
    @MainActor static func textSchemeChecks(_ root: URL) async {
        let dir = root.appendingPathComponent("text")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = dir.appendingPathComponent("app.yaml")
        try? "name: <one>\n".write(to: yaml, atomically: true, encoding: .utf8)
        let page = PreviewSchemeHandler.response(for: yaml, mainDocument: true)
        let html = page.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        check("scheme 回應純文字檔：text/html 頁面", page?.mime == "text/html", page?.mime ?? "nil")
        check("scheme 回應純文字檔：內容放進 <pre class=\"plain\"> 並跳脫",
              html.contains("<pre class=\"plain\"><code>name: &lt;one&gt;\n</code></pre>"), String(html.suffix(200)))
        check("scheme 不把純文字檔當子資源回應（直接呼叫）", PreviewSchemeHandler.response(for: yaml) == nil)
        let alias = dir.appendingPathComponent("alias.txt")
        try? FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("docs/a.md"))
        check("scheme 不回應指向 Markdown 的 .txt symlink", PreviewSchemeHandler.response(for: alias, mainDocument: true) == nil)

        // 經過 webView(_:start:)：整頁才回應，Markdown 頁面引用時拒絕（驗證 mainDocument 的判斷有接上）。
        let handler = PreviewSchemeHandler()
        let web = WKWebView(frame: .zero)
        var sub = URLRequest(url: PreviewSchemeHandler.url(for: yaml))
        sub.mainDocumentURL = PreviewSchemeHandler.url(for: root.appendingPathComponent("docs/a.md"))
        let subTask = MockSchemeTask(request: sub)
        handler.webView(web, start: subTask)
        check("Markdown 頁面引用純文字檔（子資源）時 scheme 拒絕", subTask.failedError != nil && !subTask.receivedResponse)
        var main = URLRequest(url: PreviewSchemeHandler.url(for: yaml))
        main.mainDocumentURL = PreviewSchemeHandler.url(for: yaml)
        let mainTask = MockSchemeTask(request: main)
        handler.webView(web, start: mainTask)
        check("純文字檔當整頁時 scheme 回應", mainTask.finished && mainTask.failedError == nil
              && String(decoding: mainTask.receivedData, as: UTF8.self).contains("name: &lt;one&gt;"))
    }
}
```

- [x] **Step 2: 修改 `App/scripts/preview-webkit-check.swift`（兩處）**

(a) 呼叫新的檢查。原文：

```swift
            await boundaryChecks(root)
```

換成：

```swift
            await boundaryChecks(root)
            await textSchemeChecks(root)
```

(b) 總時限。原文：

```swift
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("WEBKIT CHECK: FAILED (timeout)"); exit(2) }
```

換成：

```swift
        // 預覽檢查變多（含純文字檔），整體時限放寬到 240 秒；失敗時每項最多等 6 秒，120 秒會在印出 FAIL 前就逾時。
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) { print("WEBKIT CHECK: FAILED (timeout)"); exit(2) }
```

- [x] **Step 3: 確認失敗**

Run: `beat/changes/plain-text-preview/dev.sh webkit`
預期：編譯失敗，訊息含 `extra argument 'mainDocument' in call`。

- [x] **Step 4: 修改 `App/Sources/LmuxUI/PreviewScheme.swift`（六處）**

(a) 類別註解，原文：

```swift
/// 提供 `lmux-preview:///<絕對路徑>` 給預覽 tab（beat: preview-tab.feature）：Markdown 檔回傳
/// `MarkdownHTML` 轉好的頁面，圖片原樣回傳（Markdown 頁面用相對路徑引用的圖片）。
```

換成：

```swift
/// 提供 `lmux-preview:///<絕對路徑>` 給預覽 tab（beat: preview-tab.feature、plain-text-preview.feature）：
/// Markdown 檔與純文字檔回傳 `MarkdownHTML` 轉好的頁面，圖片原樣回傳（Markdown 頁面用相對路徑引用的圖片）。
```

(b) 類別註解的安全規則，原文：

```swift
/// - Markdown 以外只給圖片，而且不給 SVG（SVG 可以帶 script）。
```

換成：

```swift
/// - Markdown 與純文字檔以外只給圖片，而且不給 SVG（SVG 可以帶 script）。純文字檔只當整頁回應，不當子資源。
```

(c) `maxBytes` 的註解，原文：

```swift
    /// 一個請求最多讀多少位元組（圖片與 HTML）；Markdown 另外收緊避免主執行緒轉換大檔卡頓。
```

換成：

```swift
    /// 一個請求最多讀多少位元組（圖片與 HTML）；Markdown 與純文字檔另外收緊（`maxMarkdownBytes`），避免主執行緒轉換大檔卡頓。
```

(d) `response(for:)` 的宣告，原文：

```swift
    static func response(for file: URL) -> (data: Data, mime: String)? {
```

換成：

```swift
    /// `mainDocument`：這個請求是整頁（主框架）本身。純文字檔只當整頁回應；Markdown 頁面用 `<img>` 之類
    /// 引用純文字檔時拒絕，和加入純文字預覽前一樣（beat: plain-text-preview）。
    static func response(for file: URL, mainDocument: Bool = false) -> (data: Data, mime: String)? {
```

(e) Markdown 分支，原文：

```swift
        if PreviewTarget.isMarkdown(file) {
            guard PreviewTarget.isMarkdown(real) else { return nil }
            switch readRegularFileResult(real, maxBytes: maxMarkdownBytes) {
            case .ok(let data):
                let text = String(decoding: data, as: UTF8.self)
                return (Data(MarkdownHTML.page(text, title: file.lastPathComponent).utf8), "text/html")
            case .tooLarge:
                return (Data(MarkdownHTML.tooLargePage(path: file.path, maxMB: maxMarkdownBytes / (1024 * 1024)).utf8), "text/html")
            case .missing:
                return (Data(MarkdownHTML.missingPage(path: file.path).utf8), "text/html")
            case .unreadable:
                return (Data(MarkdownHTML.unreadablePage(path: file.path).utf8), "text/html")
            }
        }
```

換成：

```swift
        if PreviewTarget.usesPreviewScheme(file) {
            guard PreviewTarget.kind(real) == PreviewTarget.kind(file) else { return nil }
            if PreviewTarget.isText(file) && !mainDocument { return nil }
            switch readRegularFileResult(real, maxBytes: maxMarkdownBytes) {
            case .ok(let data):
                let text = String(decoding: data, as: UTF8.self)
                let page: String
                switch PreviewTarget.kind(file) {
                case .markdown?:
                    page = MarkdownHTML.page(text, title: file.lastPathComponent)
                case .text?:
                    page = MarkdownHTML.textPage(text, title: file.lastPathComponent)
                case .html?, nil:
                    return nil
                }
                return (Data(page.utf8), "text/html")
            case .tooLarge:
                return (Data(MarkdownHTML.tooLargePage(path: file.path, maxMB: maxMarkdownBytes / (1024 * 1024)).utf8), "text/html")
            case .missing:
                return (Data(MarkdownHTML.missingPage(path: file.path).utf8), "text/html")
            case .unreadable:
                return (Data(MarkdownHTML.unreadablePage(path: file.path).utf8), "text/html")
            }
        }
```

(f) `webView(_:start:)` 裡，原文：

```swift
              let (data, mime) = Self.response(for: file) else {
```

換成：

```swift
              let (data, mime) = Self.response(for: file, mainDocument: task.request.mainDocumentURL == url) else {
```

- [x] **Step 5: 確認通過，而且既有的檢查沒有變**

Run: `beat/changes/plain-text-preview/dev.sh webkit | grep -E '^FAIL|scheme 拒收非圖片|子資源|整頁|WEBKIT CHECK'`
預期：沒有 `FAIL`；有 `PASS  scheme 拒收非圖片（.txt）`、`PASS  Markdown 頁面引用純文字檔（子資源）時 scheme 拒絕`、`PASS  純文字檔當整頁時 scheme 回應`；最後一行 `WEBKIT CHECK: ok`。

- [x] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/PreviewScheme.swift App/scripts/preview-webkit-check-text.swift App/scripts/preview-webkit-check.swift
git commit -m "feat(plain-text-preview): lmux-preview scheme 只在整頁請求時回應純文字檔

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 4: 預覽 tab 顯示純文字檔、導覽規則

**Files:**
- Modify: `App/Sources/LmuxUI/PreviewView.swift`（第 4-5 行註解、第 95 行註解、第 124-125 行 `show`、第 238 行 `handleNavigationFailure`）
- Modify: `App/Sources/LmuxUI/PreviewViewNavigation.swift`（第 35、54 行註解，第 69-73 行）
- Test: `App/scripts/preview-webkit-check-text.swift`、`App/scripts/preview-webkit-check.swift`

**Interfaces:**
- Consumes: Task 1 的 `PreviewTarget.kind`、`isText`、`usesPreviewScheme`；Task 3 的 scheme 回應。
- Produces: `PreviewWebKitCheck.textViewChecks(_:)`。`PreviewView.show(_:)` 對純文字檔載入 `lmux-preview:///<路徑>`。
- **不改：** `PreviewViewNavigation.swift` 的 `openHTMLFromPreview`（第 180-183 行）與 `handleFileMainFrameNavigation`（第 192 行起，含第 228-230 行的 `isMarkdown`）。改了會讓 HTML 連到 `.txt` 時換頁，違反規格「連到純文字檔的連結不換頁」；回歸檢查是 `preview-webkit-check-security.swift` 的「HTML 跳同資料夾 secret.txt 被擋」。

- [x] **Step 1: 在 `App/scripts/preview-webkit-check-text.swift` 加 `textViewChecks`**

在檔案**最後一行 `}` 的上方**，插入下面整段：

```swift
    // @feature: plain-text-preview.feature
    // @scenario: 純文字檔以等寬字型原樣顯示
    // @scenario: 有執行權限的 shell script 只顯示，不執行
    // @scenario: 純文字預覽跟著 lmux 的外觀設定切換深淺色
    // @scenario: 很長的一行自動換行
    // @scenario: 內容有不是 UTF-8 的位元組
    // @scenario: 檔案超過大小上限
    // @scenario: Markdown 預覽裡連到純文字檔的連結不換頁
    @MainActor static func textViewChecks(_ root: URL) async {
        // 先建好全部的檔案再開預覽：剛建立的檔案若馬上開啟，監看可能收到建檔事件而重新載入上一頁，檢查會偶發失敗。
        let dir = root.appendingPathComponent("text-view")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = dir.appendingPathComponent("deploy.sh")
        let ran = dir.appendingPathComponent("deploy-ran")
        try? "#!/bin/sh\ntouch '\(ran.path)'\necho '<b>done</b>'\n".write(to: sh, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
        let log = dir.appendingPathComponent("run.log")
        try? (String(repeating: "x", count: 4000) + "\n").write(to: log, atomically: true, encoding: .utf8)
        let bad = dir.appendingPathComponent("bad.log")
        try? (Data("前段 ".utf8) + Data([0xFF, 0xFE]) + Data(" 後段".utf8)).write(to: bad)
        let huge = dir.appendingPathComponent("huge.log")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: huge) {
            try? fh.truncate(atOffset: UInt64(PreviewSchemeHandler.maxMarkdownBytes + 4096))
            try? fh.close()
        }
        let locked = dir.appendingPathComponent("locked.log")
        try? "locked\n".write(to: locked, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let empty = dir.appendingPathComponent("empty.txt")
        try? "".write(to: empty, atomically: true, encoding: .utf8)
        let big = dir.appendingPathComponent("big.log")
        try? ((0..<38_000).map { "line \($0) 0123456789 abcdefghij" }.joined(separator: "\n") + "\nEND-OF-BIG")
            .write(to: big, atomically: true, encoding: .utf8)
        let cjk = dir.appendingPathComponent("設定 檔.yaml")
        try? "cjk: ok\n".write(to: cjk, atomically: true, encoding: .utf8)
        let aliasMD = dir.appendingPathComponent("alias-md.txt")
        try? FileManager.default.createSymbolicLink(at: aliasMD, withDestinationURL: root.appendingPathComponent("docs/a.md"))
        let guide = dir.appendingPathComponent("guide.md")
        try? "# Guide\n\n[設定](run.log)\n".write(to: guide, atomically: true, encoding: .utf8)
        let secret = dir.appendingPathComponent("secret.json")
        try? "TOP-SECRET\n".write(to: secret, atomically: true, encoding: .utf8)
        let gate = dir.appendingPathComponent("gate.html")
        try? "<html><body><h1>Gate</h1></body></html>".write(to: gate, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(500))

        var changes: [String] = []
        let v = PreviewView(fileURL: sh)
        v.onFileChange = { changes.append($0.lastPathComponent) }
        let win = host(v)
        defer { v.close(); win.close() }

        // 原樣顯示、不執行
        check("純文字檔顯示原文", await waitBody(v.webView, contains: "echo '<b>done</b>'"))
        check("純文字檔走 lmux-preview scheme", v.webView.url?.scheme == PreviewSchemeHandler.scheme, v.webView.url?.absoluteString ?? "nil")
        let bold = await js(v.webView, "document.querySelectorAll('b').length")
        check("內容裡的 <b> 沒有變成粗體元素", (bold as? Int) == 0, "\(String(describing: bold))")
        let font = await js(v.webView, "getComputedStyle(document.querySelector('pre.plain code')).fontFamily")
        check("純文字以等寬字型顯示", (font as? String)?.contains("monospace") == true, "\(String(describing: font))")
        check("純文字頁的標題是檔名", v.webView.title == "deploy.sh", v.webView.title ?? "nil")
        check("開啟時通知檔案（deploy.sh）", changes.last == "deploy.sh", "\(changes)")
        try? await Task.sleep(for: .milliseconds(300))
        check("有執行權限的 shell script 沒有被執行", !FileManager.default.fileExists(atPath: ran.path))
        _ = await js(v.webView, "document.body.insertAdjacentHTML('beforeend', '<img src=\"nope.png\" onerror=\"document.title=\\'jsran\\'\">')")
        try? await Task.sleep(for: .milliseconds(500))
        check("純文字頁面的 script（onerror）不會執行", v.webView.title != "jsran", v.webView.title ?? "nil")

        // 深淺色（lmux 的外觀設定經 NSApp.appearance 傳到 WKWebView；這裡直接設定 WKWebView，端對端在 apptest）
        v.webView.appearance = NSAppearance(named: .darkAqua)
        check("深色外觀：純文字預覽用深色背景與淺色文字",
              await waitJS(v.webView, "getComputedStyle(document.documentElement).backgroundColor + '|' + getComputedStyle(document.body).color") {
                  ($0 as? String) == "rgb(13, 17, 23)|rgb(230, 237, 243)" })
        v.webView.appearance = NSAppearance(named: .aqua)
        check("淺色外觀：純文字預覽用淺色背景與深色文字",
              await waitJS(v.webView, "getComputedStyle(document.documentElement).backgroundColor + '|' + getComputedStyle(document.body).color") {
                  ($0 as? String) == "rgb(255, 255, 255)|rgb(36, 41, 47)" })

        // 很長的一行：<pre> 本身與整頁都沒有橫向捲動
        v.show(log)
        check("開啟 run.log", await waitBody(v.webView, contains: "xxxxxxxx"))
        let fits = await js(v.webView, """
            (() => { const p = document.querySelector('pre.plain'), d = document.documentElement;
              return !!p && p.scrollWidth <= p.clientWidth && d.scrollWidth <= d.clientWidth
                && getComputedStyle(p).whiteSpace === 'pre-wrap' })()
            """)
        check("很長的一行自動換行，<pre> 與整頁都沒有橫向捲動", (fits as? Bool) == true, "\(String(describing: fits))")

        // 編碼、大小上限、讀不了、空檔案、接近上限的檔案
        v.show(bad)
        check("不是 UTF-8 的位元組顯示成替代字元，其他內容照常", await waitBody(v.webView, contains: "前段 \u{FFFD}\u{FFFD} 後段"))
        v.show(huge)
        check("超過大小上限的純文字檔顯示提示與完整路徑", await waitBody(v.webView, contains: "檔案太大，無法預覽", also: huge.path))
        v.show(locked)
        check("讀不了的純文字檔顯示「無法讀取檔案」，不說「已不存在」",
              await waitBody(v.webView, contains: "無法讀取檔案", also: locked.path, excluding: "檔案已不存在"))
        v.show(empty)
        let emptyOK = await waitJS(v.webView, "(() => { const p = document.querySelector('pre.plain'); return !!p && p.innerText === '' })()") {
            ($0 as? Bool) == true }
        let emptyBody = await js(v.webView, "document.body ? document.body.innerText : 'nil'") as? String ?? "nil"
        check("空的純文字檔顯示空白頁面，不是錯誤頁", emptyOK,
              "url=\(v.webView.url?.lastPathComponent ?? "nil") body=\(emptyBody.prefix(60))")
        let t0 = Date()
        v.show(big)
        let bigOK = await waitBody(v.webView, contains: "END-OF-BIG")
        let secs = Date().timeIntervalSince(t0)
        check("接近上限（約 1.3 MB）的純文字檔 5 秒內顯示", bigOK && secs < 5, String(format: "%.2f 秒", secs))

        // 中文與空格的檔名（scheme 以「請求網址 == 主文件網址」判斷整頁，要經得起百分比編碼）
        v.show(cjk)
        check("中文與空格檔名的純文字檔顯示", await waitBody(v.webView, contains: "cjk: ok"), v.webView.url?.absoluteString ?? "nil")

        // 種類不同的 symlink：.txt 指向 Markdown 時不顯示
        v.show(aliasMD)
        check("指向 Markdown 的 .txt symlink 顯示「檔案已不存在」", await waitBody(v.webView, contains: "檔案已不存在", excluding: "A 文件"))

        // 連結與導覽：Markdown 連到純文字檔不換頁；HTML 不能把主框架導到純文字檔
        v.show(guide)
        check("開啟 guide.md", await waitH1(v.webView, "Guide"))
        v.noteUserClick()
        _ = await js(v.webView, "document.querySelector('a').click()")
        try? await Task.sleep(for: .milliseconds(400))
        check("Markdown 點純文字檔連結不換頁",
              v.webView.url?.lastPathComponent == "guide.md" && v.fileURL.lastPathComponent == "guide.md",
              "\(v.webView.url?.absoluteString ?? "nil") \(v.fileURL)")
        v.show(gate)
        check("開啟 gate.html", await waitH1(v.webView, "Gate"))
        _ = await js(v.webView, "window.top.location = 'lmux-preview://\(secret.path)'; true")
        try? await Task.sleep(for: .milliseconds(400))
        let gateText = await js(v.webView, "document.body && document.body.innerText") as? String ?? ""
        check("HTML 頁面不能把主框架導到 lmux-preview 的純文字檔",
              v.webView.url?.lastPathComponent == "gate.html" && !gateText.contains("TOP-SECRET"),
              v.webView.url?.absoluteString ?? "nil")
    }
```

- [x] **Step 2: 在 `App/scripts/preview-webkit-check.swift` 呼叫它**

原文：

```swift
            await textSchemeChecks(root)
```

換成：

```swift
            await textSchemeChecks(root)
            await textViewChecks(root)
```

- [x] **Step 3: 確認失敗**

Run: `beat/changes/plain-text-preview/dev.sh webkit | grep -E '^FAIL|WEBKIT CHECK'`
預期（plan 階段實測）：13 個 `FAIL`，第一個是 `FAIL  純文字檔顯示原文`；最後一行 `WEBKIT CHECK: FAILED (13)`。機器很忙時，最後一行可能是 `WEBKIT CHECK: FAILED (timeout)`，也算確認失敗。

- [x] **Step 4: 修改 `App/Sources/LmuxUI/PreviewView.swift`（四處）**

(a) 原文：

```swift
/// 預覽 tab 的內容（beat: preview-tab.feature）：一個 WKWebView，顯示 Markdown 檔（經
/// `PreviewSchemeHandler` 轉成 HTML）或 HTML 檔（原樣）。檔案改變時重新載入。
```

換成：

```swift
/// 預覽 tab 的內容（beat: preview-tab.feature、plain-text-preview.feature）：一個 WKWebView，顯示 Markdown 檔
/// 或純文字檔（經 `PreviewSchemeHandler` 轉成 HTML）、或 HTML 檔（原樣）。檔案改變時重新載入。
```

(b) 原文：

```swift
    /// 載入 `file`：Markdown 走 scheme；HTML 驗證為合法一般檔案後從磁碟載入，只開放它所在的資料夾。
```

換成：

```swift
    /// 載入 `file`：Markdown 與純文字檔走 scheme；HTML 驗證為合法一般檔案後從磁碟載入，只開放它所在的資料夾。
```

(c) 原文：

```swift
        if PreviewTarget.isMarkdown(file) {
            guard !PreviewTarget.hasUnsafeScalar(real.path), PreviewTarget.isMarkdown(real) else {
```

換成：

```swift
        if PreviewTarget.usesPreviewScheme(file) {
            guard !PreviewTarget.hasUnsafeScalar(real.path), PreviewTarget.kind(real) == PreviewTarget.kind(file) else {
```

(d) 原文：

```swift
            keepPinnedHTMLRoot: !PreviewTarget.isMarkdown(file)
```

換成：

```swift
            keepPinnedHTMLRoot: !PreviewTarget.usesPreviewScheme(file)
```

- [x] **Step 5: 修改 `App/Sources/LmuxUI/PreviewViewNavigation.swift`（三處）**

(a) 原文：

```swift
        // 只有本機 HTML 檔案執行 JavaScript；Markdown（lmux-preview）與錯誤頁（about:blank）皆不執行。
```

換成：

```swift
        // 只有本機 HTML 檔案執行 JavaScript；Markdown 與純文字檔（lmux-preview）與錯誤頁（about:blank）皆不執行。
```

(b) 原文：

```swift
            // 只允許 Swift 主動載入、Markdown 頁面內連結/重整或歷史上一頁，禁止本機 HTML 主動跳轉到 lmux-preview://。
```

換成：

```swift
            // 只允許 Swift 主動載入、Markdown 頁面內連結/重整或歷史上一頁，禁止本機 HTML 主動跳轉到 lmux-preview://。
            // 純文字檔更嚴：頁面內的連結也不接受（下方 isText 分支）。
```

(c) 原文：

```swift
            if !PreviewTarget.isMarkdown(file) {
                decisionHandler(.cancel, preferences)
                openHTMLFromPreview(file, real: real)
                return
            }
```

換成：

```swift
            if PreviewTarget.isText(file) {
                // 純文字檔只在 Swift 主動載入（開啟選單、監看、WebContent 重啟）、重新整理、上一頁／下一頁時顯示；
                // 頁面裡連到純文字檔的連結不換頁（beat: plain-text-preview.feature）。
                guard isProgrammaticShow || isReload || action.navigationType == .backForward,
                      PreviewTarget.kind(real) == .text else {
                    decisionHandler(.cancel, preferences)
                    return
                }
                preferences.allowsContentJavaScript = false
                activeNavigationURL = url
                decisionHandler(.allow, preferences)
                return
            }
            if !PreviewTarget.isMarkdown(file) {
                decisionHandler(.cancel, preferences)
                openHTMLFromPreview(file, real: real)
                return
            }
```

- [x] **Step 6: 確認通過**

Run: `time beat/changes/plain-text-preview/dev.sh webkit | grep -E '^FAIL|WEBKIT CHECK'`
預期：沒有 `FAIL`；最後一行 `WEBKIT CHECK: ok`。記下 `real` 時間；超過 90 秒時在回報裡寫明。

- [x] **Step 7: 確認整個 App 能 build**

Run: `beat/changes/plain-text-preview/dev.sh errors PreviewView.swift PreviewViewNavigation.swift PreviewScheme.swift`
預期：`ERRORS TOTAL: 0` 與 `BUILD EXIT: 0`。

- [x] **Step 8: Commit**

```bash
git add App/Sources/LmuxUI/PreviewView.swift App/Sources/LmuxUI/PreviewViewNavigation.swift App/scripts/preview-webkit-check-text.swift App/scripts/preview-webkit-check.swift
git commit -m "feat(plain-text-preview): 預覽 tab 顯示純文字檔；頁面裡連到純文字檔不換頁

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 5: 純文字檔的自動更新保留捲動位置

**Files:**
- Modify: `App/Sources/LmuxUI/PreviewView.swift`（第 315-316 行 `watch`）
- Test: `App/scripts/preview-webkit-check-text.swift`、`App/scripts/preview-webkit-check.swift`

**Interfaces:**
- Consumes: Task 1 的 `PreviewTarget.kind`、`usesPreviewScheme`。
- Produces: `PreviewWebKitCheck.textWatchChecks(_:)`。純文字檔改變時 `webView.reload()`（保留捲動位置），種類改變或顯示錯誤頁時才重新 `show`。

- [x] **Step 1: 在 `App/scripts/preview-webkit-check-text.swift` 加 `textWatchChecks`**

在檔案**最後一行 `}` 的上方**，插入下面整段：

```swift
    // @feature: plain-text-preview.feature
    // @scenario: 純文字檔內容改變後，預覽自動更新
    // @scenario: 預覽中的純文字檔被刪除
    @MainActor static func textWatchChecks(_ root: URL) async {
        let dir = root.appendingPathComponent("text-watch")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = dir.appendingPathComponent("live.yaml")
        try? "name: one\n".write(to: yaml, atomically: true, encoding: .utf8)
        let hidden = dir.appendingPathComponent("hidden-secret")
        try? "TOP-SECRET\n".write(to: hidden, atomically: true, encoding: .utf8)
        let tail = dir.appendingPathComponent("tail.log")
        try? (1...400).map { "line \($0)" }.joined(separator: "\n").write(to: tail, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(500))
        let v = PreviewView(fileURL: yaml)
        let win = host(v)
        defer { v.close(); win.close() }
        check("開啟 live.yaml", await waitBody(v.webView, contains: "name: one"))
        try? await Task.sleep(for: .milliseconds(300))
        try? "name: one\ndebug: true\n".write(to: yaml, atomically: true, encoding: .utf8)
        check("純文字檔改寫後自動顯示新內容", await waitBody(v.webView, contains: "debug: true"))
        try? FileManager.default.removeItem(at: yaml)
        check("純文字檔被刪除後顯示「檔案已不存在」與完整路徑", await waitBody(v.webView, contains: "檔案已不存在", also: yaml.path))
        try? "name: two\n".write(to: yaml, atomically: true, encoding: .utf8)
        check("純文字檔重新出現後恢復顯示", await waitBody(v.webView, contains: "name: two"))

        // 換成指向「沒有副檔名」檔案的 symlink：種類變了，不顯示目標內容
        try? await Task.sleep(for: .milliseconds(300))
        try? FileManager.default.removeItem(at: yaml)
        try? FileManager.default.createSymbolicLink(at: yaml, withDestinationURL: hidden)
        check("監看中把檔案換成指向無副檔名檔案的 symlink：顯示「檔案已不存在」",
              await waitBody(v.webView, contains: "檔案已不存在", excluding: "TOP-SECRET"))

        // 自動更新後捲動位置不變（plan 階段實測：重新載入保留 scrollY；改用重新 show 會跳回 0）
        v.show(tail)
        _ = await waitBody(v.webView, contains: "line 400")
        _ = await js(v.webView, "window.scrollTo(0, document.documentElement.scrollHeight)")
        try? await Task.sleep(for: .milliseconds(300))
        let before = await js(v.webView, "window.scrollY") as? Double ?? -1
        try? ((1...400).map { "line \($0)" } + ["line 401"]).joined(separator: "\n").write(to: tail, atomically: true, encoding: .utf8)
        _ = await waitBody(v.webView, contains: "line 401")
        try? await Task.sleep(for: .milliseconds(300))
        let after = await js(v.webView, "window.scrollY") as? Double ?? -1
        check("自動更新後捲動位置不變，不跳回開頭", before > 0 && after == before, "before=\(before) after=\(after)")
    }
```

- [x] **Step 2: 在 `App/scripts/preview-webkit-check.swift` 呼叫它**

原文：

```swift
            await textViewChecks(root)
```

換成：

```swift
            await textViewChecks(root)
            await textWatchChecks(root)
```

- [x] **Step 3: 確認失敗**

Run: `beat/changes/plain-text-preview/dev.sh webkit | grep -E '^FAIL|WEBKIT CHECK'`
預期（plan 階段實測）：只有一個 `FAIL  自動更新後捲動位置不變，不跳回開頭  -- before=… after=0.0`；最後一行 `WEBKIT CHECK: FAILED (1)`。原因：還沒改的監看對非 Markdown 檔會重新 `show`，重新載入整頁，捲動位置回到 0。

- [x] **Step 4: 修改 `App/Sources/LmuxUI/PreviewView.swift`**

原文：

```swift
            if PreviewTarget.isMarkdown(self.fileURL) {
                if PreviewTarget.hasUnsafeScalar(real.path) || !PreviewTarget.isMarkdown(real) || self.isShowingFallbackPage {
```

換成：

```swift
            if PreviewTarget.usesPreviewScheme(self.fileURL) {
                if PreviewTarget.hasUnsafeScalar(real.path) || PreviewTarget.kind(real) != PreviewTarget.kind(self.fileURL)
                    || self.isShowingFallbackPage {
```

- [x] **Step 5: 確認通過**

Run: `beat/changes/plain-text-preview/dev.sh webkit | grep -E '^FAIL|WEBKIT CHECK'`
預期：沒有 `FAIL`；最後一行 `WEBKIT CHECK: ok`。

- [x] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/PreviewView.swift App/scripts/preview-webkit-check-text.swift App/scripts/preview-webkit-check.swift
git commit -m "feat(plain-text-preview): 純文字檔自動更新時保留捲動位置

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 6: ⌘-click 開始接受純文字檔

**Files:**
- Modify: `App/Sources/LmuxUI/PreviewTarget.swift`（刪除 `extensions`；`resolve` 的兩處副檔名檢查）
- Modify: `App/scripts/preview-check.swift`
- Modify: `App/Sources/lmux-apptest/PreviewInteractions.swift`（「不是可預覽檔案：照原本流程開啟」那個檢查）

**Interfaces:**
- Consumes: Task 1 的 `PreviewTarget.kind`。
- Produces: `PreviewTarget.resolve` 接受純文字檔；symlink 的目標必須是同一種 `Kind`（`.md` 指向 `.html` 也改成照原本流程，design.md 的邊緣情況有記）。`PreviewTarget.extensions` 刪除（只有 `resolve` 用過它）。

- [x] **Step 1: 修改測試 `App/scripts/preview-check.swift`（三處）**

(a) 原文：

```swift
        for name in ["design.md", "page.html", "notes.txt", "UPPER.MD",
```

換成：

```swift
        for name in ["design.md", "page.html", "notes.txt", "AppIcon.icns", "UPPER.MD",
```

(b) 原文：

```swift
        expect(PreviewTarget.resolve("docs/notes.txt", cwd: rootPath) == nil, "不是可預覽檔案")
```

換成：

```swift
        expect(PreviewTarget.resolve("docs/AppIcon.icns", cwd: rootPath) == nil, "不是可預覽檔案（.icns）")
        expect(PreviewTarget.resolve("docs/notes.txt", cwd: rootPath) != nil, "純文字檔（.txt）是可預覽檔案")
```

(c) 在 Task 1 加的區塊裡，原文：

```swift
        expect(PreviewTarget.isText(text.appendingPathComponent("app.yaml")) && !PreviewTarget.isText(URL(fileURLWithPath: design)),
```

換成：

```swift
        for name in textNames {
            let path = text.appendingPathComponent(name).standardizedFileURL.path
            expect(PreviewTarget.resolve("docs/text/\(name)", cwd: rootPath)?.path == path,
                   "純文字檔 \(name) 是可預覽檔案（UTType：\(uti(name))）")
        }
        for name in notTextNames {
            expect(PreviewTarget.resolve("docs/text/\(name)", cwd: rootPath) == nil, "\(name) 照原本流程（UTType：\(uti(name))）")
        }
        // @scenario: 路徑帶行號時，從檔案開頭顯示
        expect(PreviewTarget.resolve("docs/text/app.yaml:42", cwd: rootPath)?.path
               == text.appendingPathComponent("app.yaml").standardizedFileURL.path, "純文字檔帶行號：去掉行號")
        // symlink 的目標必須是同一種
        try? FileManager.default.createSymbolicLink(at: text.appendingPathComponent("alias-md.txt"),
                                                    withDestinationURL: URL(fileURLWithPath: design))
        expect(PreviewTarget.resolve("docs/text/alias-md.txt", cwd: rootPath) == nil, "指向 .md 的 .txt symlink 不預覽（種類不同）")
        try? FileManager.default.createSymbolicLink(at: text.appendingPathComponent("alias-sh.txt"),
                                                    withDestinationURL: text.appendingPathComponent("deploy.sh"))
        expect(PreviewTarget.resolve("docs/text/alias-sh.txt", cwd: rootPath) != nil, "指向純文字檔的 .txt symlink 可預覽")
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("alias-html.md"),
                                                    withDestinationURL: docs.appendingPathComponent("page.html"))
        expect(PreviewTarget.resolve("docs/alias-html.md", cwd: rootPath) == nil, "指向 .html 的 .md symlink 不預覽（種類不同，改走原本流程）")
        expect(PreviewTarget.isText(text.appendingPathComponent("app.yaml")) && !PreviewTarget.isText(URL(fileURLWithPath: design)),
```

- [x] **Step 2: 確認失敗**

Run: `beat/changes/plain-text-preview/dev.sh check`
預期（plan 階段實測）：`Precondition failed: 失敗：純文字檔（.txt）是可預覽檔案`。

- [x] **Step 3: 修改 `App/Sources/LmuxUI/PreviewTarget.swift`（三處）**

(a) 刪除 `extensions`（連同註解與後面的空行）。原文：

```swift
    /// 可預覽檔案的副檔名（小寫）。
    static let extensions: Set<String> = ["md", "markdown", "html", "htm"]
```

換成：

```swift
（刪掉，什麼都不留）
```

(b) `resolve` 裡，原文：

```swift
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
```

換成：

```swift
        guard let fileKind = kind(url) else { return nil }
```

(c) `resolve` 裡，原文：

```swift
              extensions.contains(canonical.pathExtension.lowercased()),
```

換成：

```swift
              kind(canonical) == fileKind,
```

- [x] **Step 4: 確認通過**

Run: `beat/changes/plain-text-preview/dev.sh check`
預期：最後一行 `preview check: ok`。

- [x] **Step 5: 修改 `App/Sources/lmux-apptest/PreviewInteractions.swift`**

`notes.txt` 現在是純文字檔，會跳出選單，不能再當「不是可預覽檔案」的例子。

原文：

```swift
        r.check("不是可預覽檔案：照原本流程開啟",
                sameAsBefore(docs.appendingPathComponent("notes.txt").path) && external.urls.count == 1,
                "\(external.urls)")
```

換成：

```swift
        let svg = docs.appendingPathComponent("icon.svg")
        try? "<svg xmlns=\"http://www.w3.org/2000/svg\"/>".write(to: svg, atomically: true, encoding: .utf8)
        r.check("不是可預覽檔案（SVG）：照原本流程開啟",
                sameAsBefore(svg.path) && external.urls.count == 1,
                "\(external.urls)")
```

- [x] **Step 6: build，跑 apptest 的預覽那一組，跟基準比**

```bash
beat/changes/plain-text-preview/dev.sh errors PreviewTarget.swift PreviewInteractions.swift
beat/changes/plain-text-preview/dev.sh apptest-preview | grep -E '不是可預覽檔案|APPTEST EXIT'
beat/changes/plain-text-preview/dev.sh new-failures preview
```

預期：
- `ERRORS TOTAL: 0` 與 `BUILD EXIT: 0`。
- 有 `PASS` 的「不是可預覽檔案（SVG）：照原本流程開啟」。
- `NEW FAILURES: 0`。`MISSING CHECKS` 只列出改名前的「不是可預覽檔案：照原本流程開啟」這一項（`MISSING CHECKS: 1`）：只有這一項時算通過，在回報裡寫明。

- [x] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/PreviewTarget.swift App/scripts/preview-check.swift App/Sources/lmux-apptest/PreviewInteractions.swift
git commit -m "feat(plain-text-preview): ⌘-click 純文字檔跳出開啟選單

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 7: apptest：⌘-click 純文字檔的端對端檢查

**Files:**
- Create: `App/Sources/lmux-apptest/PreviewText.swift`
- Modify: `App/Sources/lmux-apptest/Preview.swift`（第 277 行附近）

**Interfaces:**
- Consumes: 既有的 `Report`、`sleepMs`、`previewSetup`、`waitPreviewJS`、`LmuxController.openMenuTestHook`、`LmuxController.OpenChoice`（`.preview`、`.defaultApp`）、`LmuxController.setAppearance`、`UntrustedURLAlert.testHook`、`UntrustedURLPrompt.block(reason:display:)`、`UntrustedURL.DenialReason.unsafeFile`、`PreviewFixtures`、`PreviewExternalSpy`。
- Produces: `func runPreviewTextChecks(_ r: Report, _ c: LmuxController, _ fx: PreviewFixtures, external: PreviewExternalSpy) async`。

> 注意：這個 task 的程式碼在 plan 階段**沒有編譯過**。Step 3 遇到編譯錯誤時，照錯誤訊息只修 `PreviewText.swift`，最多兩輪；兩輪後還有錯就停下來回報。不可以為了編譯通過而刪掉檢查。

- [x] **Step 1: 建立 `App/Sources/lmux-apptest/PreviewText.swift`，內容如下（整份照抄）**

```swift
import AppKit
import GhosttyKit
import LmuxTerminal
@testable import LmuxUI
import UniformTypeIdentifiers
import WebKit

/// 純文字檔的預覽（beat/changes/plain-text-preview）：⌘-click 跳出開啟選單、開出預覽 tab、外觀、自動更新、
/// 頁內連結、`.sh`／`.command` 選「用預設 app 開」仍被擋。選單由 `openMenuTestHook` 回答，提示由 `UntrustedURLAlert.testHook` 回答。
@MainActor
func runPreviewTextChecks(_ r: Report, _ c: LmuxController, _ fx: PreviewFixtures, external: PreviewExternalSpy) async {
    // @feature: plain-text-preview.feature
    // @scenario: ⌘-click 純文字檔的路徑跳出開啟選單
    // @scenario: macOS 不認為是純文字、或被排除的檔案，照原本流程
    // @scenario: 路徑帶行號時，從檔案開頭顯示
    // @scenario: 純文字檔以等寬字型原樣顯示
    // @scenario: 有執行權限的 shell script 只顯示，不執行
    // @scenario: 純文字預覽跟著 lmux 的外觀設定切換深淺色
    // @scenario: 純文字檔內容改變後，預覽自動更新
    // @scenario: 預覽中的純文字檔被刪除
    // @scenario: shell script 選「用預設 app 開」仍被安全規則擋下
    // @scenario: Markdown 預覽裡連到純文字檔的連結不換頁
    r.section = "preview-text"
    let root = fx.root.appendingPathComponent("text-fixtures", isDirectory: true)
    let textPaths = ["notes/todo.txt", "scripts/deploy.sh", "scripts/run.command", "config/app.yaml", "config/app.yml",
                     "data/result.json", "logs/run.log", "tools/check.py"]
    let otherPaths = ["docs/intro.rtf", "assets/logo.svg", "web/app.ts", "config/.env"]
    for path in textPaths + otherPaths {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "x\n".write(to: url, atomically: true, encoding: .utf8)
    }
    let sh = root.appendingPathComponent("scripts/deploy.sh")
    let ran = root.appendingPathComponent("scripts/deploy-ran")
    try? "#!/bin/sh\ntouch '\(ran.path)'\necho '<b>done</b>'\n".write(to: sh, atomically: true, encoding: .utf8)
    _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
    let yaml = root.appendingPathComponent("config/app.yaml")
    try? (1...80).map { "line \($0): value" }.joined(separator: "\n").write(to: yaml, atomically: true, encoding: .utf8)
    let guide = root.appendingPathComponent("docs/guide.md")
    try? "# Guide\n\n[設定](../config/app.yml)\n".write(to: guide, atomically: true, encoding: .utf8)
    await sleepMs(500)  // 先建好檔案再開預覽：避免監看收到建檔事件而重新載入

    var asked: [URL] = []
    var answer: LmuxController.OpenChoice?
    var prompts: [UntrustedURLPrompt] = []
    LmuxController.openMenuTestHook = { asked.append($0); return answer }
    UntrustedURLAlert.testHook = { prompts.append($0); return false }
    defer {
        LmuxController.openMenuTestHook = nil
        UntrustedURLAlert.testHook = nil
    }
    let ws = c.newWorkspace(cwd: root.path)
    let a = ws.panes[0]
    a.cwd = root.path
    c.focus(a)
    func click(_ value: String) {
        c.openTerminalLink(value, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, pane: a, view: a.surface)
    }
    /// 同一個值：經過 openTerminalLink，與直接走原本流程（GhosttyRuntime.openTerminalURL），開啟的東西與詢問都一樣。
    func sameAsBefore(_ value: String) -> Bool {
        external.urls.removeAll(); prompts.removeAll()
        GhosttyRuntime.openTerminalURL(value, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: a.surface?.window)
        let before = (external.urls, prompts)
        external.urls.removeAll(); prompts.removeAll()
        click(value)
        return external.urls == before.0 && prompts == before.1
    }
    func real(_ u: URL) -> String { u.resolvingSymlinksInPath().path }
    func uti(_ path: String) -> String { UTType(filenameExtension: (path as NSString).pathExtension)?.identifier ?? "nil" }

    // 判斷：純文字檔跳出選單，其他照原本流程
    answer = nil
    for path in textPaths {
        asked.removeAll()
        click(path)
        r.check("⌘-click \(path)：跳出開啟選單", asked.map(real) == [real(root.appendingPathComponent(path))], "\(asked) UTType=\(uti(path))")
    }
    for path in otherPaths {
        asked.removeAll()
        r.check("⌘-click \(path)：不跳出開啟選單，照原本流程",
                sameAsBefore(root.appendingPathComponent(path).path) && asked.isEmpty, "\(asked) UTType=\(uti(path))")
    }

    // 在新 tab 預覽 shell script：原樣顯示、不執行
    answer = .preview
    click("scripts/deploy.sh")
    let p = ws.root.find(a)?.tabs.first { $0.preview?.fileURL.lastPathComponent == "deploy.sh" }
    r.check("在新 tab 預覽：開出 deploy.sh 的預覽 tab", p != nil && ws.focusedPane === p)
    r.check("預覽 tab 的標題是檔名", p?.headerTitle == "deploy.sh", p?.headerTitle ?? "nil")
    let shown = await waitPreviewJS(
        p?.preview?.webView,
        "Boolean(document.body?.innerText.includes(\"echo '<b>done</b>'\")) && document.querySelectorAll('b').length === 0"
    )
    r.check("預覽 tab 原樣顯示 shell script 的內容", shown)
    r.check("預覽 shell script 時沒有執行它", !FileManager.default.fileExists(atPath: ran.path))

    // lmux 的外觀設定 → 純文字預覽（背景與文字顏色，同 Markdown 的 preview-appearance）
    c.setAppearance(.dark)
    let dark = await waitPreviewJS(p?.preview?.webView,
        "getComputedStyle(document.documentElement).backgroundColor === 'rgb(13, 17, 23)' && getComputedStyle(document.body).color === 'rgb(230, 237, 243)'")
    r.check("lmux 切換成 Dark 時，純文字預覽跟著變深色", dark)
    c.setAppearance(.light)
    let light = await waitPreviewJS(p?.preview?.webView,
        "getComputedStyle(document.documentElement).backgroundColor === 'rgb(255, 255, 255)' && getComputedStyle(document.body).color === 'rgb(36, 41, 47)'")
    r.check("lmux 切換成 Light 時，純文字預覽跟著變淺色", light)
    c.setAppearance(.system)

    // 路徑帶行號：從檔案開頭顯示
    asked.removeAll()
    click("config/app.yaml:42")
    r.check("路徑帶行號：去掉行號後跳出開啟選單", asked.map(real) == [real(yaml)], "\(asked)")
    let py = ws.root.find(a)?.tabs.first { $0.preview?.fileURL.lastPathComponent == "app.yaml" }
    let atTop = await waitPreviewJS(
        py?.preview?.webView,
        "Boolean(document.body?.innerText.includes('line 42: value')) && window.scrollY === 0"
    )
    r.check("路徑帶行號：預覽從檔案開頭顯示", atTop)

    // 自動更新與刪除
    await sleepMs(300)
    try? ((1...80).map { "line \($0): value" } + ["debug: true"]).joined(separator: "\n").write(to: yaml, atomically: true, encoding: .utf8)
    r.check("純文字檔改寫後預覽 tab 自動更新",
            await waitPreviewJS(py?.preview?.webView, "Boolean(document.body?.innerText.includes('debug: true'))"))
    try? FileManager.default.removeItem(at: yaml)
    r.check("純文字檔被刪除後顯示「檔案已不存在」，預覽 tab 仍然留著",
            await waitPreviewJS(py?.preview?.webView, "Boolean(document.body?.innerText.includes('檔案已不存在'))")
                && ws.panes.contains { $0 === py })

    // Markdown 預覽裡連到純文字檔：不換頁、不開新 tab
    let (gws, _, gp) = previewSetup(c, dir: root, file: guide)
    _ = await waitPreviewJS(gp.preview?.webView, "Boolean(document.querySelector('h1'))")
    let gCount = gws.panes.count
    gp.preview!.noteUserClick()
    _ = try? await gp.preview!.webView.evaluateJavaScript("document.querySelector('a').click()")
    await sleepMs(500)
    r.check("Markdown 預覽點純文字檔連結：不換頁、不開新 tab",
            gp.headerTitle == "guide.md" && gws.panes.count == gCount, "\(gp.headerTitle) \(gws.panes.count)")
    c.closeWorkspace(gws)

    // 用預設 app 開 shell script（.sh、.command）：被既有的 script 規則擋下，和不經選單時一樣
    answer = .defaultApp
    c.focus(a)
    for path in ["scripts/deploy.sh", "scripts/run.command"] {
        let abs = root.appendingPathComponent(path).path
        external.urls.removeAll(); prompts.removeAll()
        GhosttyRuntime.openTerminalURL(abs, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: a.surface?.window)
        let direct = prompts
        let tabCount = ws.panes.count
        external.urls.removeAll(); prompts.removeAll()
        click(path)
        var unsafe = false
        if case .block(reason: .unsafeFile, display: _)? = prompts.first { unsafe = true }
        r.check("\(path) 選「用預設 app 開」：以 script 規則擋下，和不經選單時相同，沒有交給系統開啟",
                unsafe && prompts == direct && external.urls.isEmpty, "\(prompts) direct=\(direct) \(external.urls)")
        r.check("\(path) 選「用預設 app 開」：沒有開出預覽 tab", ws.panes.count == tabCount, "\(ws.panes.count)")
    }
    r.check("shell script 沒有被執行", !FileManager.default.fileExists(atPath: ran.path))
    c.closeWorkspace(ws)
}
```

- [x] **Step 2: 在 `App/Sources/lmux-apptest/Preview.swift` 呼叫它**

原文：

```swift
    await runPreviewInteractionChecks(r, c, fixtures, external: external)
```

換成：

```swift
    await runPreviewInteractionChecks(r, c, fixtures, external: external)
    await runPreviewTextChecks(r, c, fixtures, external: external)
```

- [x] **Step 3: build**

Run: `beat/changes/plain-text-preview/dev.sh errors PreviewText.swift Preview.swift`
預期：`ERRORS TOTAL: 0` 與 `BUILD EXIT: 0`。

- [x] **Step 4: 跑 apptest 的預覽那一組，跟基準比**

```bash
beat/changes/plain-text-preview/dev.sh apptest-preview | grep -E 'preview-text|APPTEST EXIT'
beat/changes/plain-text-preview/dev.sh new-failures preview
```

預期：
- `preview-text` 段落的每一行都是 `PASS`。
- `NEW FAILURES: 0`；`MISSING CHECKS` 同 Task 6，只有改名的那一項。
- 某個「⌘-click …：跳出開啟選單」FAIL 時，看 detail 的 `UTType=`：如果是這台電腦把那個副檔名判斷成別的類型，照停止規則回報這一行，不要改清單。

- [x] **Step 5: Commit**

```bash
git add App/Sources/lmux-apptest/PreviewText.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "test(plain-text-preview): apptest 檢查 ⌘-click 純文字檔、外觀、自動更新與 .sh 被擋

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 8: 規格標註與文件

**Files:**
- Modify: `beat/changes/plain-text-preview/features/plain-text-preview.feature`
- Modify: `App/README.md`（第 5、24、55 行）
- Modify: `docs/features.md`（第 7、37 行）

**Interfaces:** 無程式介面。

- [x] **Step 1: 在 `plain-text-preview.feature` 每個場景加 `@covered-by`**

格式：加在 tag 行（例如 `  @e2e @happy-path`）與 `  場景:`／`  場景大綱:` 那一行之間，一個檔案一行。例：

```gherkin
  @e2e @happy-path
  # @covered-by: App/scripts/preview-check.swift
  # @covered-by: App/Sources/lmux-apptest/PreviewText.swift
  場景大綱: ⌘-click 純文字檔的路徑跳出開啟選單
```

每個場景要加的檔案：

| 場景 | @covered-by |
|---|---|
| ⌘-click 純文字檔的路徑跳出開啟選單 | `App/scripts/preview-check.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |
| macOS 不認為是純文字、或被排除的檔案，照原本流程 | `App/scripts/preview-check.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |
| 純文字檔以等寬字型原樣顯示 | `App/scripts/preview-check.swift`、`App/scripts/preview-webkit-check-text.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |
| 有執行權限的 shell script 只顯示，不執行 | `App/scripts/preview-webkit-check-text.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |
| 很長的一行自動換行 | `App/scripts/preview-check.swift`、`App/scripts/preview-webkit-check-text.swift` |
| 路徑帶行號時，從檔案開頭顯示 | `App/scripts/preview-check.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |
| 純文字預覽跟著 lmux 的外觀設定切換深淺色 | `App/scripts/preview-webkit-check-text.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |
| 內容有不是 UTF-8 的位元組 | `App/scripts/preview-webkit-check-text.swift` |
| 檔案超過大小上限 | `App/scripts/preview-webkit-check-text.swift` |
| 純文字檔內容改變後，預覽自動更新 | `App/scripts/preview-webkit-check-text.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |
| 預覽中的純文字檔被刪除 | `App/scripts/preview-webkit-check-text.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |
| shell script 選「用預設 app 開」仍被安全規則擋下 | `App/Sources/lmux-apptest/PreviewText.swift` |
| Markdown 預覽裡連到純文字檔的連結不換頁 | `App/scripts/preview-webkit-check-text.swift`、`App/Sources/lmux-apptest/PreviewText.swift` |

確認：

```bash
grep -c '# @covered-by' beat/changes/plain-text-preview/features/plain-text-preview.feature
```

預期：`24`。

- [x] **Step 2: 更新 `App/README.md`（三處，英文）**

| 行 | 原文 | 換成 |
|---|---|---|
| 5 | `WKWebView` is used only for `.md` / `.html` preview tabs | `WKWebView` is used only for `.md` / `.html` / plain-text preview tabs |
| 24 | Markdown/HTML preview suite alone | Markdown/HTML/plain-text preview suite alone |
| 55 | terminal or Markdown/HTML `PreviewView` | terminal or Markdown/HTML/plain-text `PreviewView` |

- [x] **Step 3: 更新 `docs/features.md`（兩處，英文）**

| 行 | 原文 | 換成 |
|---|---|---|
| 7 | loaded only for opt-in `.md` / `.html` preview tabs | loaded only for opt-in `.md` / `.html` / plain-text preview tabs |
| 37 | an opt-in `.md` / `.html` preview tab | an opt-in `.md` / `.html` / plain-text preview tab (plain text: any file macOS treats as text, such as `.sh`, `.yaml` or `.log`, shown as is) |

- [x] **Step 4: Commit**

```bash
git add beat/changes/plain-text-preview/features/plain-text-preview.feature App/README.md docs/features.md
git commit -m "docs(plain-text-preview): 標註 @covered-by，文件加上純文字預覽

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 9: 回歸檢查與回報

**Files:** 不改檔案。

- [x] **Step 1: 跑全部的預覽檢查**

```bash
beat/changes/plain-text-preview/dev.sh check | tail -1
time beat/changes/plain-text-preview/dev.sh webkit | tail -1
```

預期：`preview check: ok`、`WEBKIT CHECK: ok`。

- [x] **Step 2: 跑 apptest 主要那一輪，跟基準比**

```bash
beat/changes/plain-text-preview/dev.sh apptest-quick | tail -1
beat/changes/plain-text-preview/dev.sh new-failures quick
```

預期：`NEW FAILURES: 0`；`MISSING CHECKS` 只有改名的那一項（見 Task 6 Step 6）。

- [x] **Step 3: 回報**

回報內容：
- 每個 task 的 commit SHA（`git log --oneline dd0dc71..HEAD`）。
- Step 1–2 輸出的最後幾行；Task 0 與 Task 4 記下的 webkit 時間。
- WebKit 檢查有沒有重跑過（偶發失敗規則）。
- 記下但沒改的地方。至少包含：既有測試的名稱與註解還寫著「非預覽檔（.txt）」：`App/scripts/preview-check.swift:18`、`:87`，`App/scripts/preview-webkit-check-view.swift:95`、`:112`，`App/scripts/preview-webkit-check-security.swift:83`、`:90`、`:96`。改名會讓 `new-failures` 多出 MISSING CHECKS，所以這次不改。
- 未驗證：CI（GitHub Actions 的 `macos-26`）上 UTType 的判斷是否和本機相同；只在本機跑過。

## 手動驗證（使用者做，agent 不做）

自動測試用 `openMenuTestHook` 代替真的選單，以下要在真的 lmux 裡確認：

1. 一般 shell：`cd ~/opensource/lmux && ls scripts/bootstrap.sh`，⌘-click 路徑 → 跳出開啟選單 → 選「在新 tab 預覽」→ 等寬字型顯示腳本內容。
2. Claude Code 裡：⌘⇧-click 一個 `.yaml` 路徑 → 同上（Claude Code 開了滑鼠回報，要多按 Shift）。
3. 選「用預設 app 開」一個 `.sh` → 看到擋下的提示，檔案沒有被開啟。
4. lmux 外觀設定切 System，macOS 切深色 → 純文字預覽變深色。
