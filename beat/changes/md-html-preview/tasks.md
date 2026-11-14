# 在 lmux 裡預覽 .md 與 .html — 實作計畫

> **給執行的 agent：** 照順序一次做一個 task。每個 step 做完，把 `- [ ]` 改成 `- [x]`。

**Goal:** 在終端機 ⌘-click `.md`／`.html` 路徑時跳出開啟選單，可以把檔案開成一個新的預覽 tab（WKWebView）。

**Architecture:** 先新增五個獨立的新檔（路徑判斷、Markdown 轉 HTML、自訂 scheme、資料夾監看、預覽畫面），用單獨編譯的檢查腳本驗證。再把 `Pane.surface` 改成 optional，讓 tab 能裝預覽（重構，行為不變）。最後把預覽接進 tab、焦點、選單、CLI、存檔。

**Tech Stack:** Swift 5 語言模式、SwiftPM、AppKit、WebKit、Foundation、CoreServices（FSEvents）、UniformTypeIdentifiers。沒有第三方依賴。

**規格來源：** `beat/changes/md-html-preview/` 的 `proposal.md`、`design.md`、`features/open-menu.feature`、`features/preview-tab.feature`。

## Global Constraints

- 只在 worktree `/Users/jamis.liao/opensource/lmux/.worktrees/feat/md-html-preview` 裡工作。不要 `cd` 到 `/Users/jamis.liao/opensource/lmux`（那是 main）。
- 不新增任何第三方依賴。只用 Apple 的框架：Foundation、AppKit、WebKit、CoreServices、UniformTypeIdentifiers。
- 只改每個 task 的「檔案」列出的檔案。看到其他想改的地方，記下來，最後回報，不要改。
- 程式碼註解用繁體中文。
- build、測試一律用 `beat/changes/md-html-preview/dev.sh`（Task 0 建立）。它會先 `unset LMUX_*` 變數：這個 session 跑在使用者正在用的 lmux 裡，不 unset 的話，測試會送進使用者的 lmux。
- 每個 task 結束都要 commit。commit message 用繁體中文，結尾加一行 `Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>`。
- 不可以 `git push`。不可以 `git commit --no-verify`。
- 不可以為了讓測試通過而修改測試的預期值。
- **停止規則：** 驗證的結果跟「預期」不同時，最多修兩次。兩次後還是不同，就停下來，回報：task 編號、跑的指令、完整輸出。不要自己換做法。
  - 例外：Task 16–18 照編譯錯誤逐行修正，可以跑很多輪；但每一輪的 `ERRORS TOTAL` 都必須比上一輪少，沒有變少就停下來回報。
  - 寫著「確認失敗」的步驟：結果跟預期不同（例如沒有失敗），就停下來回報。不要為了讓它失敗去改程式。
- **跑很久的指令：** `apptest-quick` 要幾分鐘，`apptest-full` 可能超過 30 分鐘。工具有逾時限制時，改成背景執行再輪詢：
  `nohup beat/changes/md-html-preview/dev.sh apptest-full > "${TMPDIR:-/tmp}/md-html-preview/run.out" 2>&1 &`，之後每 60 秒跑一次 `tail -3 "${TMPDIR:-/tmp}/md-html-preview/run.out"`，看到 `APPTEST EXIT:` 才算跑完。
- **apptest 的結束碼：** 起點本來就有 FAIL 時，`APPTEST EXIT` 不會是 0，這不算失敗。回歸只看 `new-failures` 的 `NEW FAILURES` 與 `MISSING CHECKS` 是不是 0。

## Quality Principles

**Testing:** Tests verify behavior (return values, state changes, responses), not wiring.
If the main assertion is `toHaveBeenCalledWith`, rewrite to assert on the function's output.

**Code:** No single new file exceeds ~300 lines. If it grows past that, split into focused sub-modules.

## 共用指令（`dev.sh`，Task 0 建立）

| 指令 | 做什麼 | 成功時最後一行 |
|---|---|---|
| `beat/changes/md-html-preview/dev.sh build` | build 整個 App package | `BUILD EXIT: 0` |
| `beat/changes/md-html-preview/dev.sh errors A.swift B.swift` | build，只列出這些檔案的 error（也印出整個 build 的 error 數與結束碼） | `ERRORS TOTAL: 0` |
| `beat/changes/md-html-preview/dev.sh check` | 編譯並執行 `App/scripts/preview-check.swift` | `preview check: ok` |
| `beat/changes/md-html-preview/dev.sh webkit` | 編譯並執行 `App/scripts/preview-webkit-check.swift` | `WEBKIT CHECK: ok` |
| `beat/changes/md-html-preview/dev.sh apptest-preview` | 只跑 apptest 的 `--preview`（Task 20 之後才有） | `APPTEST EXIT: 0` |
| `beat/changes/md-html-preview/dev.sh apptest-quick` | apptest 主要那一輪（幾分鐘） | 看 `new-failures quick` |
| `beat/changes/md-html-preview/dev.sh apptest-full` | apptest 全部，含還原、scrollback（可能超過 30 分鐘） | 看 `new-failures full` |
| `beat/changes/md-html-preview/dev.sh new-failures quick` 或 `full` | 跟 Task 0 的基準比：多出來的 FAIL、不見的檢查 | `NEW FAILURES: 0` 與 `MISSING CHECKS: 0` |

## 檔案一覽

| 檔案 | 新增／修改 | 負責 |
|---|---|---|
| `App/Sources/LmuxUI/PreviewTarget.swift` | 新增 | ⌘-click 的值 → 可預覽檔案的 URL |
| `App/Sources/LmuxUI/MarkdownHTML.swift` | 新增 | Markdown → HTML（Foundation 解析） |
| `App/Sources/LmuxUI/PreviewScheme.swift` | 新增 | `lmux-preview:` scheme：Markdown 轉頁面、其他檔案原樣 |
| `App/Sources/LmuxUI/PreviewWatcher.swift` | 新增 | FSEvents 監看檔案所在資料夾 |
| `App/Sources/LmuxUI/PreviewView.swift` | 新增 | 預覽 tab 的畫面（WKWebView、導覽規則、自動更新） |
| `App/Sources/LmuxUI/OpenMenu.swift` | 新增 | ⌘-click 的開啟選單 |
| `App/scripts/preview-check.swift` | 新增 | PreviewTarget、MarkdownHTML 的自我檢查 |
| `App/scripts/preview-webkit-check.swift` | 新增 | scheme、監看、PreviewView 在真的 WKWebView 裡的自我檢查 |
| `App/Sources/lmux-apptest/Preview.swift` | 新增 | apptest 的 `--preview` |
| `App/Sources/LmuxUI/Model.swift` 等 18 個 LmuxUI 檔案 | 修改 | `Pane.surface` 改 optional |
| `App/Sources/lmux-apptest/`、`lmux-imetest/` 26 個檔案 | 修改 | 機械式改成 `surface!` |

---

### Task 0: 建立 dev.sh，確認起點能 build、記錄 apptest 基準

**Files:**
- Create: `beat/changes/md-html-preview/dev.sh`

**Interfaces:**
- Produces: `dev.sh` 的子指令（見上面「共用指令」）。`$TMPDIR/md-html-preview/baseline-quick.log`、`baseline-full.log`：起點的 apptest 結果，後面的 task 拿來比。

- [x] **Step 1: 建立 `beat/changes/md-html-preview/dev.sh`，內容如下（整份照抄）**

```bash
#!/bin/bash
# md-html-preview 實作用的指令（給照 tasks.md 實作的 agent 用）。在 worktree 的任何位置執行：
#   beat/changes/md-html-preview/dev.sh build                build 整個 App package，印出最後 40 行與結束碼
#   beat/changes/md-html-preview/dev.sh errors 檔名...        build，只列出這些檔案（只寫檔名，例如 Agent.swift）的 error
#   beat/changes/md-html-preview/dev.sh check                編譯並執行 App/scripts/preview-check.swift
#   beat/changes/md-html-preview/dev.sh webkit               編譯並執行 App/scripts/preview-webkit-check.swift
#   beat/changes/md-html-preview/dev.sh apptest-preview      只跑 apptest 的 --preview
#   beat/changes/md-html-preview/dev.sh apptest-quick        apptest --quick（主要那一輪，要幾分鐘）
#   beat/changes/md-html-preview/dev.sh apptest-full         apptest 全部（含還原、scrollback，要很久）
#   beat/changes/md-html-preview/dev.sh new-failures quick|full   跟 Task 0 的基準比：多出來的 FAIL、不見的檢查
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
# 不讓測試送進使用者正在用的 lmux；避開 Homebrew 的 GNU libtool。
unset LMUX_CONTROL_SOCKET LMUX_PANE_ID LMUX_PANE_NONCE LMUX_PANE_TOKEN LMUX_SOCKET
export PATH="/usr/bin:$PATH"
OUT="${TMPDIR:-/tmp}/md-html-preview"
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
    # shellcheck disable=SC2046
    swiftc -parse-as-library -o "$OUT/preview-webkit-check" \
      $(existing PreviewTarget MarkdownHTML PreviewScheme PreviewWatcher PreviewView) App/scripts/preview-webkit-check.swift \
      && "$OUT/preview-webkit-check" ;;
  apptest-preview)
    App/scripts/apptest.sh --preview > "$OUT/preview.log" 2>&1; code=$?
    grep -E '^(PASS|FAIL|RESULT)' "$OUT/preview.log"; echo "APPTEST EXIT: $code"; exit $code ;;
  apptest-quick)
    App/scripts/apptest.sh --quick > "$OUT/quick.log" 2>&1; code=$?
    grep -E '^(FAIL|RESULT)' "$OUT/quick.log"; echo "RESULT LINES: $(grep -c '^RESULT' "$OUT/quick.log")"
    echo "APPTEST EXIT: $code"; exit $code ;;
  apptest-full)
    App/scripts/apptest.sh > "$OUT/full.log" 2>&1; code=$?
    grep -E '^(FAIL|RESULT)' "$OUT/full.log"; echo "RESULT LINES: $(grep -c '^RESULT' "$OUT/full.log")"
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

- [x] **Step 2: 加上執行權限**

Run: `chmod +x beat/changes/md-html-preview/dev.sh && beat/changes/md-html-preview/dev.sh`
Expected: 印出 9 行說明，第 1 行是 `# md-html-preview 實作用的指令（給照 tasks.md 實作的 agent 用）。在 worktree 的任何位置執行：`。結束碼 2 是正常的（沒有給子指令），不要改 dev.sh。

- [x] **Step 3: 確認起點能 build**

Run: `beat/changes/md-html-preview/dev.sh build`
Expected: 最後一行 `BUILD EXIT: 0`。
不是 0：**停止**，回報輸出。不要修。

- [x] **Step 4: 跑 apptest 主要那一輪，存成基準**

Run: `beat/changes/md-html-preview/dev.sh apptest-quick; cp "${TMPDIR:-/tmp}/md-html-preview/quick.log" "${TMPDIR:-/tmp}/md-html-preview/baseline-quick.log"; grep -c '^RESULT' "${TMPDIR:-/tmp}/md-html-preview/baseline-quick.log"; grep -c '^FAIL' "${TMPDIR:-/tmp}/md-html-preview/baseline-quick.log"`
Expected: 倒數第 2 行（RESULT 的數量）至少是 1，否則 apptest 沒跑完，停下來回報。最後一行是起點就有的 FAIL 數量（可能是 0）：這些 FAIL 不是這次改動造成的，記在回報裡，不要修。

- [x] **Step 5: 跑 apptest 全部，存成基準（很久，見「跑很久的指令」）**

Run: `beat/changes/md-html-preview/dev.sh apptest-full; cp "${TMPDIR:-/tmp}/md-html-preview/full.log" "${TMPDIR:-/tmp}/md-html-preview/baseline-full.log"; grep -c '^RESULT' "${TMPDIR:-/tmp}/md-html-preview/baseline-full.log"; grep -c '^FAIL' "${TMPDIR:-/tmp}/md-html-preview/baseline-full.log"`
Expected: 同 Step 4：RESULT 至少 1；最後一行是起點就有的 FAIL 數量，記在回報裡。

- [x] **Step 6: Commit**

```bash
git add beat/changes/md-html-preview/dev.sh
git commit -m "chore(md-html-preview): 新增實作用的 dev.sh

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 1: PreviewTarget（⌘-click 的值 → 可預覽檔案）

**Files:**
- Create: `App/Sources/LmuxUI/PreviewTarget.swift`
- Create: `App/scripts/preview-check.swift`

**Interfaces:**
- Produces: `enum PreviewTarget`
  - `static func resolve(_ value: String, cwd: String?, fileManager: FileManager = .default) -> URL?`
  - `static func stripLineSuffix(_ s: String) -> String`
  - `static func isMarkdown(_ url: URL) -> Bool`
  - `static let extensions: Set<String>`

- [x] **Step 1: 先寫檢查腳本 `App/scripts/preview-check.swift`（整份照抄）**

```swift
// 預覽 tab 的路徑判斷（App/Sources/LmuxUI/PreviewTarget.swift）的自我檢查（Task 2 會換成含 Markdown 的完整版）。不需要 libghostty，單獨編譯執行：
//   swiftc -parse-as-library -o /tmp/preview-check \
//     App/Sources/LmuxUI/PreviewTarget.swift App/scripts/preview-check.swift \
//     && /tmp/preview-check

import Foundation

@main
enum PreviewCheck {
    static func expect(_ ok: Bool, _ what: String, _ line: UInt = #line) {
        precondition(ok, "失敗：\(what)（第 \(line) 行）")
    }

    static func main() {
        // 暫存資料夾：docs/design.md、docs/page.html、docs/notes.txt、docs/folder.md/（資料夾）
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-check-\(getpid())")
        let docs = root.appendingPathComponent("docs")
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        for name in ["design.md", "page.html", "notes.txt", "UPPER.MD", "a\u{202E}b.md"] {
            FileManager.default.createFile(atPath: docs.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("zero.md"),
                                                    withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        defer { try? FileManager.default.removeItem(at: root) }
        let rootPath = root.standardizedFileURL.path
        let design = docs.appendingPathComponent("design.md").standardizedFileURL.path

        // @feature: open-menu.feature
        // @scenario: 路徑後面帶行號時，去掉行號再判斷
        expect(PreviewTarget.stripLineSuffix("docs/design.md:12") == "docs/design.md", "去掉 :12")
        expect(PreviewTarget.stripLineSuffix("docs/design.md:12:5") == "docs/design.md", "去掉 :12:5")
        expect(PreviewTarget.stripLineSuffix("docs/design.md") == "docs/design.md", "沒有行號時不變")
        expect(PreviewTarget.resolve("docs/design.md:12", cwd: rootPath)?.path == design, "帶行號的相對路徑")

        // @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單
        expect(PreviewTarget.resolve("docs/design.md", cwd: rootPath)?.path == design, "相對路徑")
        expect(PreviewTarget.resolve(design, cwd: nil)?.path == design, "絕對路徑不需要 cwd")
        expect(PreviewTarget.resolve("docs/page.html", cwd: rootPath) != nil, ".html")
        expect(PreviewTarget.resolve("docs/UPPER.MD", cwd: rootPath) != nil, "副檔名不分大小寫")

        // @scenario: OSC 8 連結指向本機的可預覽檔案時也跳出開啟選單
        expect(PreviewTarget.resolve(URL(fileURLWithPath: design).absoluteString, cwd: nil)?.path == design, "file:// 連結")

        // @scenario: 不是存在的可預覽檔案時，照原本流程
        expect(PreviewTarget.resolve("docs/notes.txt", cwd: rootPath) == nil, "不是可預覽檔案")
        expect(PreviewTarget.resolve("docs/missing.md", cwd: rootPath) == nil, "檔案不存在")
        expect(PreviewTarget.resolve("https://example.com/readme.md", cwd: rootPath) == nil, "網址")
        expect(PreviewTarget.resolve("docs/folder.md", cwd: rootPath) == nil, "資料夾不算檔案")

        // @scenario: shell 沒回報目前目錄時，相對路徑照原本流程
        expect(PreviewTarget.resolve("docs/design.md", cwd: nil) == nil, "沒有 cwd 的相對路徑")

        // 安全：控制字元（U+202E 讓檔名倒著顯示）、遠端主機的 file://、指向 /dev/zero 的 symlink 都不預覽
        expect(PreviewTarget.resolve("docs/a\u{202E}b.md", cwd: rootPath) == nil, "含 U+202E 的路徑（檔案存在）")
        expect(PreviewTarget.resolve("file://remotehost" + design, cwd: nil) == nil, "遠端主機的 file://")
        expect(PreviewTarget.resolve("file://localhost" + design, cwd: nil)?.path == design, "localhost 的 file://")
        expect(PreviewTarget.resolve("docs/zero.md", cwd: rootPath) == nil, "指向 /dev/zero 的 symlink")

        expect(PreviewTarget.isMarkdown(URL(fileURLWithPath: design)), "isMarkdown .md")
        expect(!PreviewTarget.isMarkdown(docs.appendingPathComponent("page.html")), "isMarkdown .html")

        print("preview check: ok")
    }
}
```

- [x] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh check`
Expected: 編譯失敗，訊息含 `cannot find 'PreviewTarget' in scope`。

- [x] **Step 3: 建立 `App/Sources/LmuxUI/PreviewTarget.swift`（整份照抄）**

```swift
import Foundation

/// 終端機裡 ⌘-click 的連結指向的檔案，是預覽 tab 能顯示的檔案時才有值（beat: open-menu.feature）。
enum PreviewTarget {
    /// 可預覽檔案的副檔名（小寫）。
    static let extensions: Set<String> = ["md", "markdown", "html", "htm"]

    /// Ghostty 交來的 `value`（絕對路徑、相對於 shell 目前目錄的路徑、`~/…`、或 `file://` 網址），
    /// 去掉結尾的 `:行號` 或 `:行號:欄號`。指向存在的可預覽檔案才回傳，否則 nil。
    /// `cwd`：這個 tab 的目前目錄，用來補相對路徑。
    static func resolve(_ value: String, cwd: String?, fileManager: FileManager = .default) -> URL? {
        // 看不見的控制字元（例如 U+202E 讓檔名倒著顯示）：不預覽，走原本流程（UntrustedURL 會擋）。
        if value.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) }) {
            return nil
        }
        var path = value
        if path.lowercased().hasPrefix("file://") {
            // 只接受本機的 file://（沒有 host，或 host 是 localhost）。
            guard let u = URL(string: path), u.isFileURL,
                  (u.host ?? "").isEmpty || u.host?.lowercased() == "localhost" else { return nil }
            path = u.path
        } else if path.contains("://") || path.lowercased().hasPrefix("mailto:") {
            return nil
        }
        path = stripLineSuffix(path)
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        // 只預覽一般檔案：資料夾、裝置檔（例如 /dev/zero）、指向它們的 symlink 都不算。
        guard fileManager.fileExists(atPath: url.path),
              let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return url
    }

    /// `a.md:12` → `a.md`，`a.md:12:5` → `a.md`；其他不變。
    static func stripLineSuffix(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #":\d+(:\d+)?$"#) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                           withTemplate: "")
    }

    /// Markdown（由 `MarkdownHTML` 轉成 HTML），不是 HTML（直接載入）。
    static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }
}
```

- [x] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh check`
Expected: 最後一行 `preview check: ok`。

- [x] **Step 5: 確認 app 仍能 build**

Run: `beat/changes/md-html-preview/dev.sh build`
Expected: `BUILD EXIT: 0`。

- [x] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/PreviewTarget.swift App/scripts/preview-check.swift
git commit -m "feat(md-html-preview): 新增 PreviewTarget，判斷 ⌘-click 的值是不是可預覽檔案

去掉 :行號、用 tab 的目前目錄補相對路徑、支援 file:// 連結；附自我檢查腳本。

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 2: MarkdownHTML（Markdown → HTML）

**Files:**
- Create: `App/Sources/LmuxUI/MarkdownHTML.swift`
- Modify: `App/scripts/preview-check.swift`（整份換掉）

**Interfaces:**
- Consumes: 無（只用 Foundation）。
- Produces: `enum MarkdownHTML`
  - `static func page(_ markdown: String, title: String) -> String`：整頁 HTML
  - `static func missingPage(path: String) -> String`：「檔案已不存在」頁
  - `static func body(_ markdown: String) -> String`：HTML 片段
  - `static func escape(_ s: String) -> String`

說明：這個檔案約 220 行，超過「每個 task 約 200 行」的建議。它只有一個職責（Markdown → HTML），拆開反而要在兩個 task 之間插入程式碼，容易貼錯，所以整份一次建立。

- [x] **Step 1: 把 `App/scripts/preview-check.swift` 整份換成下面的內容**

```swift
// 預覽 tab 的路徑判斷（App/Sources/LmuxUI/PreviewTarget.swift）與 Markdown 轉 HTML
// （App/Sources/LmuxUI/MarkdownHTML.swift）的自我檢查。不需要 libghostty，單獨編譯執行：
//   swiftc -parse-as-library -o /tmp/preview-check \
//     App/Sources/LmuxUI/PreviewTarget.swift App/Sources/LmuxUI/MarkdownHTML.swift App/scripts/preview-check.swift \
//     && /tmp/preview-check

import Foundation

@main
enum PreviewCheck {
    static func expect(_ ok: Bool, _ what: String, _ line: UInt = #line) {
        precondition(ok, "失敗：\(what)（第 \(line) 行）")
    }

    static func html(_ md: String) -> String { MarkdownHTML.body(md) }

    static func main() {
        // 暫存資料夾：docs/design.md、docs/page.html、docs/notes.txt、docs/folder.md/（資料夾）
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-check-\(getpid())")
        let docs = root.appendingPathComponent("docs")
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        for name in ["design.md", "page.html", "notes.txt", "UPPER.MD", "a\u{202E}b.md"] {
            FileManager.default.createFile(atPath: docs.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("zero.md"),
                                                    withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        defer { try? FileManager.default.removeItem(at: root) }
        let rootPath = root.standardizedFileURL.path
        let design = docs.appendingPathComponent("design.md").standardizedFileURL.path

        // @feature: open-menu.feature
        // @scenario: 路徑後面帶行號時，去掉行號再判斷
        expect(PreviewTarget.stripLineSuffix("docs/design.md:12") == "docs/design.md", "去掉 :12")
        expect(PreviewTarget.stripLineSuffix("docs/design.md:12:5") == "docs/design.md", "去掉 :12:5")
        expect(PreviewTarget.stripLineSuffix("docs/design.md") == "docs/design.md", "沒有行號時不變")
        expect(PreviewTarget.resolve("docs/design.md:12", cwd: rootPath)?.path == design, "帶行號的相對路徑")

        // @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單
        expect(PreviewTarget.resolve("docs/design.md", cwd: rootPath)?.path == design, "相對路徑")
        expect(PreviewTarget.resolve(design, cwd: nil)?.path == design, "絕對路徑不需要 cwd")
        expect(PreviewTarget.resolve("docs/page.html", cwd: rootPath) != nil, ".html")
        expect(PreviewTarget.resolve("docs/UPPER.MD", cwd: rootPath) != nil, "副檔名不分大小寫")

        // @scenario: OSC 8 連結指向本機的可預覽檔案時也跳出開啟選單
        expect(PreviewTarget.resolve(URL(fileURLWithPath: design).absoluteString, cwd: nil)?.path == design, "file:// 連結")

        // @scenario: 不是存在的可預覽檔案時，照原本流程
        expect(PreviewTarget.resolve("docs/notes.txt", cwd: rootPath) == nil, "不是可預覽檔案")
        expect(PreviewTarget.resolve("docs/missing.md", cwd: rootPath) == nil, "檔案不存在")
        expect(PreviewTarget.resolve("https://example.com/readme.md", cwd: rootPath) == nil, "網址")
        expect(PreviewTarget.resolve("docs/folder.md", cwd: rootPath) == nil, "資料夾不算檔案")

        // @scenario: shell 沒回報目前目錄時，相對路徑照原本流程
        expect(PreviewTarget.resolve("docs/design.md", cwd: nil) == nil, "沒有 cwd 的相對路徑")

        // 安全：控制字元（U+202E 讓檔名倒著顯示）、遠端主機的 file://、指向 /dev/zero 的 symlink 都不預覽
        expect(PreviewTarget.resolve("docs/a\u{202E}b.md", cwd: rootPath) == nil, "含 U+202E 的路徑（檔案存在）")
        expect(PreviewTarget.resolve("file://remotehost" + design, cwd: nil) == nil, "遠端主機的 file://")
        expect(PreviewTarget.resolve("file://localhost" + design, cwd: nil)?.path == design, "localhost 的 file://")
        expect(PreviewTarget.resolve("docs/zero.md", cwd: rootPath) == nil, "指向 /dev/zero 的 symlink")

        expect(PreviewTarget.isMarkdown(URL(fileURLWithPath: design)), "isMarkdown .md")
        expect(!PreviewTarget.isMarkdown(docs.appendingPathComponent("page.html")), "isMarkdown .html")

        // @feature: preview-tab.feature
        // @scenario: Markdown 顯示成排版後的樣子
        let doc = html("""
        # 標題

        - 一
        - 二

        | a | b |
        |---|:-:|
        | 1 | 2 |

        ```swift
        let x = 1 < 2
        ```

        > 引用
        """)
        expect(doc.contains("<h1>標題</h1>"), "標題：\(doc)")
        expect(doc.contains("<ul><li><p>一</p></li><li><p>二</p></li></ul>"), "清單：\(doc)")
        expect(doc.contains("<table><thead><tr><th>a</th><th style=\"text-align:center\">b</th></tr></thead><tr><td>1</td><td style=\"text-align:center\">2</td></tr></table>"), "表格：\(doc)")
        expect(doc.contains("<pre><code class=\"language-swift\">let x = 1 &lt; 2\n</code></pre>"), "程式碼區塊：\(doc)")
        expect(doc.contains("<blockquote><p>引用</p></blockquote>"), "引用：\(doc)")
        expect(!doc.contains("# ") && !doc.contains("|") && !doc.contains("```"), "看不到 Markdown 符號：\(doc)")

        // 分隔線只輸出 <hr>，不輸出解析器塞的 "⸻"
        let rule = html("上\n\n---\n\n下")
        expect(rule.contains("<hr>") && !rule.contains("⸻"), "分隔線：\(rule)")

        // 有序清單
        expect(html("1. x\n2. y").contains("<ol><li><p>x</p></li><li><p>y</p></li></ol>"), "有序清單")

        // 空的表格格子不讓欄位錯位
        let empty = html("| a | b | c |\n|---|---|---|\n|  | 2 |  |\n")
        expect(empty.contains("<tr><td></td><td>2</td><td></td></tr>"), "空格子：\(empty)")

        // 行內格式、連結、圖片
        let inline = html("**粗** *斜* `碼` ~~刪~~ [下一篇](b.md) ![圖](img/flow.png)")
        expect(inline.contains("<strong>粗</strong>"), "粗體：\(inline)")
        expect(inline.contains("<em>斜</em>"), "斜體：\(inline)")
        expect(inline.contains("<code>碼</code>"), "行內程式碼：\(inline)")
        expect(inline.contains("<del>刪</del>"), "刪除線：\(inline)")
        expect(inline.contains("<a href=\"b.md\">下一篇</a>"), "相對連結：\(inline)")
        expect(inline.contains("<img src=\"img/flow.png\" alt=\"圖\">"), "圖片：\(inline)")
        expect(!html("[x](javascript:alert(1))").contains("javascript"), "javascript: 連結被拿掉")

        // @scenario: callout 顯示成提示框
        let note = html("> [!NOTE]\n> 內文")
        expect(note.contains("<blockquote class=\"callout callout-note\"><p class=\"callout-title\">Note</p>"), "NOTE：\(note)")
        expect(note.contains("內文") && !note.contains("[!"), "NOTE 內文：\(note)")
        let warn = html("> [!warning] 小心\n> 第二行")
        expect(warn.contains("<blockquote class=\"callout callout-warning\"><p class=\"callout-title\">小心</p>"), "warning：\(warn)")
        expect(warn.contains("第二行") && !warn.contains("[!"), "warning 內文：\(warn)")
        let other = html("> [!todo] 待辦")
        expect(other.contains("callout callout-note") && other.contains(">待辦</p>"), "不認得的類型用 note：\(other)")

        // @scenario: 程式碼區塊不上色，mermaid 區塊顯示成一般程式碼區塊
        let mermaid = html("```mermaid\ngraph TD; A-->B\n```")
        expect(mermaid.contains("<pre><code class=\"language-mermaid\">graph TD; A--&gt;B\n</code></pre>"), "mermaid：\(mermaid)")
        expect(!mermaid.contains("<span"), "沒有上色用的 span：\(mermaid)")

        // @scenario: Markdown 裡的 HTML 標籤顯示成文字，不執行
        let script = html("前文 <script>alert(1)</script> 後文")
        expect(script.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), "script 跳脫：\(script)")
        expect(!script.contains("<script>"), "沒有真的 script 標籤：\(script)")
        let block = html("<details><summary>摺疊</summary>內容</details>")
        expect(block.contains("&lt;details&gt;") && !block.contains("<details>"), "區塊 HTML 跳脫：\(block)")

        // 整頁與檔案不存在
        let page = MarkdownHTML.page("# T", title: "a<b>.md")
        expect(page.hasPrefix("<!doctype html>") && page.contains("<title>a&lt;b&gt;.md</title>"), "整頁：\(page.prefix(200))")
        expect(page.contains("prefers-color-scheme: dark"), "深色樣式")
        expect(page.contains("Content-Security-Policy") && page.contains("default-src 'none'"), "頁面帶 CSP，不執行 script")
        let missing = MarkdownHTML.missingPage(path: "/x/<a>.md")
        expect(missing.contains("檔案已不存在") && missing.contains("/x/&lt;a&gt;.md"), "檔案不存在頁：\(missing)")

        print("preview check: ok")
    }
}
```

- [x] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh check`
Expected: 編譯失敗，訊息含 `cannot find 'MarkdownHTML' in scope`。

- [x] **Step 3: 建立 `App/Sources/LmuxUI/MarkdownHTML.swift`（整份照抄）**

```swift
import Foundation

/// 預覽 tab 的 Markdown 轉 HTML（beat: preview-tab.feature）。只用 Foundation 內建的解析器，不加依賴。
/// 所有文字都跳脫：Markdown 裡寫的 HTML 一律顯示成文字，不執行。
enum MarkdownHTML {
    /// 整頁：`<head>` 放樣式表，`<body>` 放轉好的 Markdown。
    static func page(_ markdown: String, title: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\">" + csp
            + "<meta name=\"color-scheme\" content=\"light dark\">"
            + "<title>\(escape(title))</title><style>\(css)</style></head>"
            + "<body><article>\(body(markdown))</article></body></html>"
    }

    /// 預覽中的檔案不存在時顯示的頁面。
    static func missingPage(path: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\">" + csp
            + "<meta name=\"color-scheme\" content=\"light dark\"><style>\(css)</style></head>"
            + "<body><article><h2>檔案已不存在</h2><p><code>\(escape(path))</code></p></article></body></html>"
    }

    /// 頁面的內容安全政策：不執行任何 script、不嵌入任何東西；圖片可以是本機（lmux-preview）、網路或 data:，
    /// 樣式只用頁面自己的。即使 JavaScript 沒被關掉，也多一層保護。
    static let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
        + "img-src lmux-preview: https: http: data:; style-src 'unsafe-inline'\">"

    /// 轉好的 Markdown（HTML 片段）。
    static func body(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let doc = try? AttributedString(markdown: markdown, options: options) else {
            return "<pre><code>\(escape(markdown))</code></pre>"
        }
        var r = Renderer()
        for run in doc.runs {
            let text = String(doc[run.range].characters)
            r.add(text: text, blocks: Array((run.presentationIntent?.components ?? []).reversed()),
                  inline: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL)
        }
        r.closeAll()
        return callouts(r.out)
    }

    /// `&`、`<`、`>`、`"`、`'` 換成 HTML entity。
    static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(c)
            }
        }
        return o
    }

    /// 連結或圖片網址轉成屬性值；scheme 不在允許清單（例如 `javascript:`）時回傳 nil，整個拿掉。
    static func safeURL(_ url: URL) -> String? {
        let allowed: Set<String> = ["http", "https", "mailto", "file", "lmux-preview"]
        if let scheme = url.scheme?.lowercased(), !allowed.contains(scheme) { return nil }
        return escape(url.absoluteString)
    }

    /// `<blockquote><p>[!類型] 標題`（GitHub／Obsidian 的 callout）換成有標題的提示框。
    static func callouts(_ html: String) -> String {
        let pattern = #"<blockquote>(<p>)?\[!([A-Za-z]+)\][+-]?[ \t]*([^<\n]*)\n?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let type = ns.substring(with: m.range(at: 2)).lowercased()
            let custom = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            let title = custom.isEmpty ? type.prefix(1).uppercased() + type.dropFirst() : custom
            let known: Set<String> = ["note", "tip", "important", "warning", "caution"]
            let kind = known.contains(type) ? type : "note"
            let hadP = m.range(at: 1).location != NSNotFound
            out += "<blockquote class=\"callout callout-\(kind)\"><p class=\"callout-title\">\(title)</p>"
                + (hadP ? "<p>" : "")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out.replacingOccurrences(of: "<p></p>", with: "")
    }

    /// 依解析器的 run 組 HTML：每個 run 帶著它所在的區塊（由外到內）；上一個 run 在、這個 run
    /// 不在的區塊就關掉，新的區塊就打開。
    private struct Renderer {
        var out = ""
        /// 開著的區塊（由外到內）與關掉它要寫的標籤。
        var open: [(intent: PresentationIntent.IntentType, close: String)] = []
        /// 目前表格的欄位，與這一列下一格的欄號。
        var columns: [PresentationIntent.TableColumn] = []
        var nextCell = 0

        mutating func add(text: String, blocks: [PresentationIntent.IntentType],
                          inline: InlinePresentationIntent, link: URL?, image: URL?) {
            var common = 0
            while common < open.count, common < blocks.count,
                  open[common].intent.identity == blocks[common].identity { common += 1 }
            while open.count > common { closeLast() }
            for b in blocks[common...] { openBlock(b) }
            // 解析器把分隔線寫成文字「⸻」：有 <hr> 就夠了。
            if case .thematicBreak = blocks.last?.kind { return }
            if blocks.isEmpty, !text.isEmpty {
                out += "<p>" + MarkdownHTML.escape(text) + "</p>"
                return
            }
            let inCode = blocks.contains { if case .codeBlock = $0.kind { return true }; return false }
            out += inCode ? MarkdownHTML.escape(text) : Self.inlineHTML(text, inline, link: link, image: image)
        }

        mutating func closeAll() { while !open.isEmpty { closeLast() } }

        private mutating func closeLast() {
            let last = open.removeLast()
            if case .tableHeaderRow = last.intent.kind { padRow() }
            if case .tableRow = last.intent.kind { padRow() }
            out += last.close
        }

        /// 空的格子不會有任何 run：補上空格子，欄位才不會錯位。
        private mutating func padRow() {
            let headerRow = open.last.map { if case .tableHeaderRow = $0.intent.kind { return true }; return false } ?? false
            while nextCell < columns.count {
                out += headerRow ? "<th></th>" : "<td></td>"
                nextCell += 1
            }
        }

        private mutating func openBlock(_ b: PresentationIntent.IntentType) {
            switch b.kind {
            case .paragraph:
                out += "<p>"; open.append((b, "</p>"))
            case .header(let level):
                let n = min(max(level, 1), 6)
                out += "<h\(n)>"; open.append((b, "</h\(n)>"))
            case .orderedList:
                out += "<ol>"; open.append((b, "</ol>"))
            case .unorderedList:
                out += "<ul>"; open.append((b, "</ul>"))
            case .listItem:
                out += "<li>"; open.append((b, "</li>"))
            case .codeBlock(let lang):
                let cls = lang.map { " class=\"language-\(MarkdownHTML.escape($0))\"" } ?? ""
                out += "<pre><code\(cls)>"; open.append((b, "</code></pre>"))
            case .blockQuote:
                out += "<blockquote>"; open.append((b, "</blockquote>"))
            case .thematicBreak:
                out += "<hr>"; open.append((b, ""))
            case .table(let cols):
                columns = cols
                out += "<table>"; open.append((b, "</table>"))
            case .tableHeaderRow:
                nextCell = 0
                out += "<thead><tr>"; open.append((b, "</tr></thead>"))
            case .tableRow:
                nextCell = 0
                out += "<tr>"; open.append((b, "</tr>"))
            case .tableCell(let column):
                let header = open.last.map { if case .tableHeaderRow = $0.intent.kind { return true }; return false } ?? false
                let tag = header ? "th" : "td"
                while nextCell < column { out += "<\(tag)></\(tag)>"; nextCell += 1 }
                nextCell = column + 1
                out += "<\(tag)\(align(column))>"; open.append((b, "</\(tag)>"))
            default:
                out += "<div>"; open.append((b, "</div>"))
            }
        }

        private func align(_ column: Int) -> String {
            guard column < columns.count else { return "" }
            switch columns[column].alignment {
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            default: return ""
            }
        }

        private static func inlineHTML(_ text: String, _ i: InlinePresentationIntent, link: URL?, image: URL?) -> String {
            if i.contains(.softBreak) { return "\n" }
            if i.contains(.lineBreak) { return "<br>" }
            var s = MarkdownHTML.escape(text)
            if let image {
                guard let src = MarkdownHTML.safeURL(image) else { return s }
                return "<img src=\"\(src)\" alt=\"\(s)\">"
            }
            if i.contains(.code) { s = "<code>\(s)</code>" }
            if i.contains(.strikethrough) { s = "<del>\(s)</del>" }
            if i.contains(.emphasized) { s = "<em>\(s)</em>" }
            if i.contains(.stronglyEmphasized) { s = "<strong>\(s)</strong>" }
            if let link, let href = MarkdownHTML.safeURL(link) { s = "<a href=\"\(href)\">\(s)</a>" }
            return s
        }
    }

    /// 樣式表：淺色與深色兩組顏色，跟著 `prefers-color-scheme` 切換（WKWebView 跟著 lmux 的外觀設定）。
    static let css = """
    :root{--bg:#ffffff;--fg:#24292f;--muted:#57606a;--border:#d0d7de;--code-bg:#f6f8fa;--link:#0969da;\
    --note:#0969da;--tip:#1a7f37;--important:#8250df;--warning:#9a6700;--caution:#cf222e}
    @media (prefers-color-scheme: dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8d96a0;--border:#30363d;\
    --code-bg:#161b22;--link:#4493f8;--note:#4493f8;--tip:#3fb950;--important:#ab7df8;--warning:#d29922;--caution:#f85149}}
    html{background:var(--bg);color:var(--fg)}
    body{margin:0;font:15px/1.6 -apple-system,"PingFang TC",sans-serif}
    article{max-width:880px;margin:0 auto;padding:24px 32px}
    a{color:var(--link)}
    h1,h2{border-bottom:1px solid var(--border);padding-bottom:.3em}
    code{font:13px ui-monospace,Menlo,monospace;background:var(--code-bg);padding:.1em .3em;border-radius:4px}
    pre{background:var(--code-bg);padding:12px 16px;border-radius:6px;overflow:auto}
    pre code{padding:0;background:none}
    blockquote{margin:0 0 1em;padding:0 1em;color:var(--muted);border-left:4px solid var(--border)}
    .callout{color:var(--fg);border-left-color:var(--note)}
    .callout-title{font-weight:600;color:var(--note)}
    .callout-tip{border-left-color:var(--tip)}.callout-tip .callout-title{color:var(--tip)}
    .callout-important{border-left-color:var(--important)}.callout-important .callout-title{color:var(--important)}
    .callout-warning{border-left-color:var(--warning)}.callout-warning .callout-title{color:var(--warning)}
    .callout-caution{border-left-color:var(--caution)}.callout-caution .callout-title{color:var(--caution)}
    table{border-collapse:collapse;margin:0 0 1em}
    th,td{border:1px solid var(--border);padding:6px 13px}
    img{max-width:100%}
    li>p{margin:0}
    hr{border:0;border-top:1px solid var(--border)}
    """
}
```

- [x] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh check`
Expected: 最後一行 `preview check: ok`。

- [x] **Step 5: 確認 app 仍能 build**

Run: `beat/changes/md-html-preview/dev.sh build`
Expected: `BUILD EXIT: 0`。

- [x] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/MarkdownHTML.swift App/scripts/preview-check.swift
git commit -m "feat(md-html-preview): 新增 MarkdownHTML，用 Foundation 把 Markdown 轉成 HTML

支援標題、清單、表格（含空格子與對齊）、程式碼區塊、引用、callout、連結、圖片；
所有文字跳脫，Markdown 裡的 HTML 顯示成文字；javascript: 連結拿掉。

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 3: PreviewSchemeHandler（`lmux-preview:` scheme）

**Files:**
- Create: `App/Sources/LmuxUI/PreviewScheme.swift`
- Create: `App/scripts/preview-webkit-check.swift`
- 可能修改：`App/Package.swift`（只有 Step 6 失敗時）

**Interfaces:**
- Consumes: `PreviewTarget.isMarkdown`、`MarkdownHTML.page`、`MarkdownHTML.missingPage`。
- Produces: `final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler`
  - `static let scheme = "lmux-preview"`
  - `static func url(for file: URL) -> URL`
  - `static func file(for url: URL) -> URL?`

- [x] **Step 1: 建立檢查腳本 `App/scripts/preview-webkit-check.swift`（整份照抄）**

```swift
// 預覽 tab 在真的 WKWebView 裡的自我檢查（scheme、資料夾監看、導覽規則）。不需要 libghostty，
// 不顯示任何視窗（視窗放在螢幕外），單獨編譯執行：
//   beat/changes/md-html-preview/dev.sh webkit
// 每一項印 PASS 或 FAIL；最後一行是 `WEBKIT CHECK: ok` 或 `WEBKIT CHECK: FAILED (n)`。

import AppKit
import WebKit

@main
enum PreviewWebKitCheck {
    @MainActor static var failures = 0

    @MainActor static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  -- \(detail)")")
    }

    /// 最多等 `seconds` 秒，直到 `cond` 成立。
    @MainActor static func wait(_ seconds: Double = 5, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    /// 在頁面裡執行 JavaScript，回傳結果（失敗回傳 nil）。
    @MainActor static func js(_ web: WKWebView, _ code: String) async -> Any? {
        try? await web.evaluateJavaScript(code)
    }

    /// 最多等 `seconds` 秒，直到頁面第一個 `<h1>` 的文字是 `text`。
    @MainActor static func waitH1(_ web: WKWebView, _ text: String, _ seconds: Double = 6) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let s = await js(web, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String,
               s == text { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// 測試用的資料夾：docs/a.md（圖片、連結）、docs/b.md、docs/img/flow.png、
    /// site/index.html（CSS、圖片、script、連到 c.md 與外部網址）、site/c.md、site/secret.txt。
    static func makeFixtures() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("preview-webkit-check-\(getpid())")
        let docs = root.appendingPathComponent("docs"), site = root.appendingPathComponent("site")
        try? FileManager.default.createDirectory(at: docs.appendingPathComponent("img"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        // 1x1 的 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try? png.write(to: docs.appendingPathComponent("img/flow.png"))
        try? png.write(to: site.appendingPathComponent("logo.png"))
        try? "# A 文件\n\n![流程](img/flow.png)\n\n[下一篇](b.md)\n\n<script>document.title='pwned'</script>\n"
            .write(to: docs.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try? "# B 文件\n".write(to: docs.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try? "# C 文件\n".write(to: site.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)
        try? "body{background:rgb(1, 2, 3)}".write(to: site.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try? "secret".write(to: site.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try? """
        <html><head><link rel="stylesheet" href="style.css"></head><body><img src="logo.png">
        <a id="md" href="c.md">c</a><a id="web" href="https://example.com/x">web</a>
        <script>window.ran = true; window.prev = localStorage.getItem('k'); localStorage.setItem('k', 'v');</script>
        </body></html>
        """.write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return root
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let root = makeFixtures()
            await schemeChecks(root)
            try? FileManager.default.removeItem(at: root)
            print(failures == 0 ? "WEBKIT CHECK: ok" : "WEBKIT CHECK: FAILED (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { print("WEBKIT CHECK: FAILED (timeout)"); exit(2) }
        app.run()
    }

    /// 一個放在螢幕外、不會顯示的視窗，裡面放 `view`。
    @MainActor static func host(_ view: NSView) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 700),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false  // close() 不釋放，交給 ARC（否則會釋放兩次而當掉）
        view.frame = win.contentView!.bounds
        win.contentView!.addSubview(view)
        return win
    }

    // MARK: - PreviewSchemeHandler

    // @feature: preview-tab.feature
    // @scenario: Markdown 用相對路徑引用的圖片顯示出來
    @MainActor static func schemeChecks(_ root: URL) async {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: PreviewSchemeHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        let win = host(web)
        defer { win.close() }
        let a = root.appendingPathComponent("docs/a.md")
        let url = PreviewSchemeHandler.url(for: a)
        check("scheme 網址是 lmux-preview:///<路徑>", url.absoluteString == "lmux-preview://" + a.path, url.absoluteString)
        check("scheme 網址換回檔案", PreviewSchemeHandler.file(for: url)?.path == a.path)
        web.load(URLRequest(url: url))
        check("Markdown 經 scheme 轉成 HTML", await waitH1(web, "A 文件"))
        let img = await js(web, "(function(){var i=document.images[0]; return i ? (i.complete && i.naturalWidth) : -1})()")
        check("相對路徑的圖片載入成功", (img as? Int) == 1, "\(String(describing: img))")
        let href = await js(web, "document.querySelector('a').href")
        check("相對連結解析成同一個 scheme",
              (href as? String) == PreviewSchemeHandler.url(for: root.appendingPathComponent("docs/b.md")).absoluteString,
              "\(String(describing: href))")
        web.load(URLRequest(url: PreviewSchemeHandler.url(for: root.appendingPathComponent("docs/missing.md"))))
        var missing = false
        for _ in 0..<60 {
            if let s = await js(web, "document.body && document.body.innerText") as? String, s.contains("檔案已不存在") { missing = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("不存在的 Markdown 顯示「檔案已不存在」", missing)
    }
}
```

- [x] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh webkit`
Expected: 編譯失敗，訊息含 `cannot find 'PreviewSchemeHandler' in scope`。

- [x] **Step 3: 建立 `App/Sources/LmuxUI/PreviewScheme.swift`（整份照抄）**

```swift
import Foundation
import UniformTypeIdentifiers
import WebKit

/// 提供 `lmux-preview:///<絕對路徑>` 給預覽 tab（beat: preview-tab.feature）：Markdown 檔回傳
/// `MarkdownHTML` 轉好的頁面，圖片原樣回傳（Markdown 頁面用相對路徑引用的圖片）。
///
/// 安全：這個 scheme 給得出任何路徑的檔案，所以
/// - 只回應「主頁面也是 lmux-preview」的請求。HTML 頁面（file://）用 iframe、script、img、fetch
///   要這個 scheme 時一律拒絕，否則它能讀任意本機檔案再送上網路（2026-11-13 實測過 iframe 可以）。
/// - Markdown 以外只給圖片，而且不給 SVG（SVG 可以帶 script）。
/// - 只讀一般檔案、最多 `maxBytes`：`/dev/zero` 或指向它的 symlink 不會讓主執行緒卡住。
/// - 這個 scheme 的頁面不執行 JavaScript（`PreviewView` 關掉，頁面也帶 CSP）。
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "lmux-preview"
    /// 一個請求最多讀多少位元組（Markdown 與圖片）。
    static let maxBytes = 20 * 1024 * 1024

    /// 檔案對應的 `lmux-preview:///<路徑>`。
    static func url(for file: URL) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = ""
        c.path = file.path
        return c.url ?? file
    }

    /// `lmux-preview:` 網址代表的檔案；其他網址回傳 nil。
    static func file(for url: URL) -> URL? {
        guard url.scheme == scheme else { return nil }
        return URL(fileURLWithPath: url.path)
    }

    /// Markdown 頁面可以載入的其他檔案：圖片，SVG 除外。
    static func isServableImage(_ file: URL) -> Bool {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// 一般檔案、而且不超過 `maxBytes` 才讀；資料夾、裝置檔（`/dev/zero`）、指向它們的 symlink 都回傳 nil。
    static func readRegularFile(_ file: URL) -> Data? {
        let real = file.resolvingSymlinksInPath()
        guard let values = try? real.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maxBytes else { return nil }
        return try? Data(contentsOf: real)
    }

    /// 這個 scheme 對 `file` 的回應：內容與 MIME type；不給的檔案回傳 nil。
    static func response(for file: URL) -> (data: Data, mime: String)? {
        if PreviewTarget.isMarkdown(file) {
            guard let data = readRegularFile(file) else {
                return (Data(MarkdownHTML.missingPage(path: file.path).utf8), "text/html")
            }
            let text = String(decoding: data, as: UTF8.self)
            return (Data(MarkdownHTML.page(text, title: file.lastPathComponent).utf8), "text/html")
        }
        guard isServableImage(file), let data = readRegularFile(file) else { return nil }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (data, mime)
    }

    // ponytail: 在主執行緒轉換；504 KB 的 Markdown 約 0.19 秒（2026-11-13 實測，-O build）。
    // 真的卡到再改成背景執行緒，並且不回應已經 stop 的 task。
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.file(for: url),
              task.request.mainDocumentURL?.scheme == Self.scheme,
              let (data, mime) = Self.response(for: file) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let charset = mime.hasPrefix("text/") ? "utf-8" : nil
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: charset))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
```

- [x] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh webkit`
Expected: 6 行 `PASS`，最後一行 `WEBKIT CHECK: ok`。

- [x] **Step 5: 確認 app 能 build（第一個用到 WebKit 的檔案）**

Run: `beat/changes/md-html-preview/dev.sh build`
Expected: `BUILD EXIT: 0`。

- [x] **Step 6: 只有 Step 5 出現 `Undefined symbols` 且提到 `WK` 時才做：連結 WebKit**

在 `App/Package.swift` 找到這一段：

```swift
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // plugin：sidebar 底部的通知 bar（掛在 LmuxUI 的 installSidebarAccessory）。
```

改成：

```swift
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        // plugin：sidebar 底部的通知 bar（掛在 LmuxUI 的 installSidebarAccessory）。
```

再跑一次 `beat/changes/md-html-preview/dev.sh build`，Expected: `BUILD EXIT: 0`。Step 5 本來就是 0 的話，跳過這一步。

- [x] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/PreviewScheme.swift App/scripts/preview-webkit-check.swift
git add App/Package.swift   # 只有 Step 6 有改時才有變動
git commit -m "feat(md-html-preview): 新增 lmux-preview scheme，Markdown 轉成頁面、相對路徑的圖片原樣回傳

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 4: PreviewWatcher（監看檔案所在資料夾）

**Files:**
- Create: `App/Sources/LmuxUI/PreviewWatcher.swift`
- Modify: `App/scripts/preview-webkit-check.swift`

**Interfaces:**
- Produces: `final class PreviewWatcher`
  - `init(file: URL, onChange: @escaping () -> Void)`：檔案被改寫、取代、刪除時在主執行緒呼叫 `onChange`
  - `func stop()`
  - `static func canonical(_ p: String) -> String`

- [x] **Step 1: 在檢查腳本加上監看的檢查**

在 `App/scripts/preview-webkit-check.swift` 找到：

```swift
            await schemeChecks(root)
```

改成：

```swift
            await schemeChecks(root)
            await watcherChecks(root)
```

再找到檔案結尾這三行：

```swift
        check("不存在的 Markdown 顯示「檔案已不存在」", missing)
    }
}
```

改成（`schemeChecks` 結束後、整個 enum 結束前，加入 `watcherChecks`）：

```swift
        check("不存在的 Markdown 顯示「檔案已不存在」", missing)
    }

    // MARK: - PreviewWatcher

    // @feature: preview-tab.feature
    // @scenario: 檔案內容改變後，預覽自動更新
    // @scenario: 以「寫暫存檔再改名」方式存檔，預覽也會更新
    // @scenario: 預覽中的檔案被刪除
    @MainActor static func watcherChecks(_ root: URL) async {
        let file = root.appendingPathComponent("docs/watched.md")
        try? "# 0\n".write(to: file, atomically: false, encoding: .utf8)
        var calls = 0
        let watcher = PreviewWatcher(file: file) { calls += 1 }
        defer { watcher.stop() }
        try? await Task.sleep(for: .milliseconds(300))
        // 直接改寫（不換檔）
        var before = calls
        if let fh = try? FileHandle(forWritingTo: file) {
            fh.truncateFile(atOffset: 0)
            fh.write(Data("# 1\n".utf8))
            try? fh.close()
        }
        check("直接改寫檔案時通知", await wait { calls > before }, "calls=\(calls)")
        // 寫暫存檔再改名蓋掉（replaceItemAt）
        before = calls
        let tmp = root.appendingPathComponent("docs/.watched.md.tmp")
        try? "# 2\n".write(to: tmp, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
        check("寫暫存檔再改名蓋掉時通知", await wait { calls > before }, "calls=\(calls)")
        // Foundation 的 atomically 寫入（同樣是暫存檔再改名），第二次也要收到
        before = calls
        try? "# 3\n".write(to: file, atomically: true, encoding: .utf8)
        check("改名蓋掉之後再改，仍然通知", await wait { calls > before }, "calls=\(calls)")
        // 刪除
        before = calls
        try? FileManager.default.removeItem(at: file)
        check("檔案被刪除時通知", await wait { calls > before }, "calls=\(calls)")
        // 同資料夾的其他檔案改變：不通知
        try? await Task.sleep(for: .milliseconds(300))
        before = calls
        try? "x".write(to: root.appendingPathComponent("docs/other.md"), atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(800))
        check("同資料夾的其他檔案改變時不通知", calls == before, "calls=\(calls) before=\(before)")
    }
}
```

- [x] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh webkit`
Expected: 編譯失敗，訊息含 `cannot find 'PreviewWatcher' in scope`。

- [x] **Step 3: 建立 `App/Sources/LmuxUI/PreviewWatcher.swift`（整份照抄）**

```swift
import CoreServices
import Foundation

/// `file` 被改寫、被取代（先寫暫存檔再改名蓋掉）或被刪除時，在主執行緒呼叫 `onChange`
/// （beat: preview-tab.feature 的自動更新）。用 FSEvents 監看檔案所在資料夾：只監看檔案本身的話，
/// 改名蓋掉之後就還盯著舊檔。
final class PreviewWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void

    init(file: URL, onChange: @escaping () -> Void) {
        // FSEvents 回報的是真實路徑（/private/var/…）；resolvingSymlinksInPath 只在檔案存在時拿掉
        // /private。兩邊都拿掉再比。
        path = Self.canonical(file.resolvingSymlinksInPath().path)
        self.onChange = onChange
        let folder = (path as NSString).deletingLastPathComponent
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<PreviewWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: { PreviewWatcher.canonical($0) == me.path }) {
                me.onChange()
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    /// `/private/var/x` → `/var/x`（`/private/tmp`、`/private/etc` 同理）；其他路徑不變。
    static func canonical(_ p: String) -> String {
        p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
    }

    deinit { stop() }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
```

- [x] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh webkit`
Expected: 11 行 `PASS`（scheme 6 行、監看 5 行），最後一行 `WEBKIT CHECK: ok`。

- [x] **Step 5: 確認 app 仍能 build**

Run: `beat/changes/md-html-preview/dev.sh build`
Expected: `BUILD EXIT: 0`。

- [x] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/PreviewWatcher.swift App/scripts/preview-webkit-check.swift
git commit -m "feat(md-html-preview): 新增 PreviewWatcher，用 FSEvents 監看檔案所在資料夾

直接改寫、寫暫存檔再改名、刪除都會通知；同資料夾的其他檔案不通知。

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 5: PreviewView（預覽 tab 的畫面）

**Files:**
- Create: `App/Sources/LmuxUI/PreviewView.swift`
- Modify: `App/scripts/preview-webkit-check.swift`

**Interfaces:**
- Consumes: `PreviewTarget`、`MarkdownHTML`、`PreviewSchemeHandler`、`PreviewWatcher`。
- Produces: `@MainActor public final class PreviewView: NSView, WKNavigationDelegate`
  - `public init(fileURL: URL)`
  - `public private(set) var fileURL: URL`：目前顯示的檔案
  - `public let webView: WKWebView`
  - `public var onFileChange: ((URL) -> Void)?`：顯示的檔案換了
  - `public var openExternal: ((URL) -> Void)?`：使用者點了 http(s) 連結
  - `public func show(_ file: URL)`
  - `public func close()`、`public private(set) var isClosed: Bool`：關閉 tab 時停止監看與載入
  - `func noteUserClick()`（測試用）：當作使用者剛在預覽裡按了滑鼠

- [x] **Step 1: 在檢查腳本加上 PreviewView 的檢查**

在 `App/scripts/preview-webkit-check.swift` 找到：

```swift
            await watcherChecks(root)
```

改成：

```swift
            await watcherChecks(root)
            await viewChecks(root)
            await securityChecks(root)
```

再找到檔案結尾這三行：

```swift
        check("同資料夾的其他檔案改變時不通知", calls == before, "calls=\(calls) before=\(before)")
    }
}
```

改成：

```swift
        check("同資料夾的其他檔案改變時不通知", calls == before, "calls=\(calls) before=\(before)")
    }

    // MARK: - PreviewView

    // @feature: preview-tab.feature
    // @scenario: Markdown 顯示成排版後的樣子
    // @scenario: Markdown 裡的 HTML 標籤顯示成文字，不執行
    // @scenario: HTML 讀得到同資料夾的 CSS 與圖片
    // @scenario: 重新開啟預覽時，不保留上一次的 cookie 與 storage
    // @scenario: 點相對路徑的 .md 連結，在同一個預覽 tab 換頁
    // @scenario: 點網址連結，照終端機裡點連結的規則處理
    // @scenario: 預覽中的檔案被刪除
    @MainActor static func viewChecks(_ root: URL) async {
        let a = root.appendingPathComponent("docs/a.md")
        var changes: [String] = []
        var external: [URL] = []
        let v = PreviewView(fileURL: a)
        v.onFileChange = { changes.append($0.lastPathComponent) }
        v.openExternal = { external.append($0) }
        let win = host(v)
        defer { win.close() }

        // Markdown
        check("Markdown 頁面顯示出來", await waitH1(v.webView, "A 文件"))
        check("Markdown 頁面走 lmux-preview scheme", v.webView.url?.scheme == PreviewSchemeHandler.scheme, v.webView.url?.absoluteString ?? "nil")
        check("Markdown 裡的 <script> 沒有執行", v.webView.title != "pwned", v.webView.title ?? "nil")
        check("開啟時通知檔案（a.md）", changes.last == "a.md", "\(changes)")

        // Markdown 頁面的 script 不會執行：插入一個帶 onerror 的圖片，onerror 不應該跑
        _ = await js(v.webView, "document.body.insertAdjacentHTML('beforeend', '<img src=\"nope.png\" onerror=\"document.title=\\'jsran\\'\">')")
        try? await Task.sleep(for: .milliseconds(500))
        check("Markdown 頁面裡的 script（onerror）不會執行", v.webView.title != "jsran", v.webView.title ?? "nil")

        // 換頁與返回：真的點頁面上的 b.md 連結
        _ = await js(v.webView, "document.querySelector('a').click()")
        check("點 b.md 連結後換到 b.md", await waitH1(v.webView, "B 文件"))
        check("換頁後 fileURL 與通知是 b.md", v.fileURL.lastPathComponent == "b.md" && changes.last == "b.md", "\(v.fileURL) \(changes)")
        v.webView.goBack()
        check("返回上一頁回到 a.md", await waitH1(v.webView, "A 文件"))
        check("返回後 fileURL 與通知是 a.md", v.fileURL.lastPathComponent == "a.md" && changes.last == "a.md", "\(v.fileURL) \(changes)")

        // HTML
        let index = root.appendingPathComponent("site/index.html")
        v.show(index)
        _ = await wait { v.webView.url?.lastPathComponent == "index.html" && !v.webView.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let bg = await js(v.webView, "getComputedStyle(document.body).backgroundColor")
        check("HTML 套用同資料夾的 CSS", (bg as? String) == "rgb(1, 2, 3)", "\(String(describing: bg))")
        let logo = await js(v.webView, "document.images[0].complete && document.images[0].naturalWidth")
        check("HTML 顯示同資料夾的圖片", (logo as? Int) == 1, "\(String(describing: logo))")
        let ran = await js(v.webView, "window.ran === true")
        check("HTML 的 script 有執行", (ran as? Bool) == true, "\(String(describing: ran))")
        let prev = await js(v.webView, "window.prev")
        check("第一次開啟時 storage 是空的", prev == nil || prev is NSNull, "\(String(describing: prev))")
        let fetched = try? await v.webView.callAsyncJavaScript(
            "try { const r = await fetch('secret.txt'); return await r.text() } catch (e) { return 'blocked' }",
            contentWorld: .page)
        check("HTML 的 script 讀不到同資料夾的其他檔案", (fetched as? String) == "blocked", "\(String(describing: fetched))")

        // 頁面的 script 自己點外部連結（使用者沒有點）：不開
        _ = await js(v.webView, "document.getElementById('web').click()")
        try? await Task.sleep(for: .milliseconds(500))
        check("script 自己點 https 連結時不開任何東西", external.isEmpty, "\(external)")
        // 使用者點了外部連結：交給 openExternal，頁面不變
        v.noteUserClick()
        _ = await js(v.webView, "document.getElementById('web').click()")
        check("使用者點 https 連結交給 openExternal", await wait { external.last?.absoluteString == "https://example.com/x" }, "\(external)")
        try? await Task.sleep(for: .milliseconds(300))
        check("點 https 連結後頁面不變", v.webView.url?.lastPathComponent == "index.html", v.webView.url?.absoluteString ?? "nil")

        // HTML 連到同資料夾的 Markdown：改走 scheme
        _ = await js(v.webView, "document.getElementById('md').click()")
        check("HTML 連到的 Markdown 經 scheme 顯示", await waitH1(v.webView, "C 文件"))
        check("HTML 連到的 Markdown 用 lmux-preview scheme", v.webView.url?.scheme == PreviewSchemeHandler.scheme, v.webView.url?.absoluteString ?? "nil")

        // 另一個 PreviewView 不共享 storage
        let v2 = PreviewView(fileURL: index)
        let win2 = host(v2)
        defer { win2.close() }
        _ = await wait { v2.webView.url?.lastPathComponent == "index.html" && !v2.webView.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        let prev2 = await js(v2.webView, "window.prev")
        check("新的預覽讀不到上一個預覽存的 storage", prev2 == nil || prev2 is NSNull, "\(String(describing: prev2))")

        // 自動更新與刪除
        let w = root.appendingPathComponent("docs/live.md")
        try? "# 版本一\n".write(to: w, atomically: true, encoding: .utf8)
        v.show(w)
        check("開啟 live.md", await waitH1(v.webView, "版本一"))
        try? await Task.sleep(for: .milliseconds(300))
        try? "# 版本二\n".write(to: w, atomically: true, encoding: .utf8)
        check("檔案改寫後自動顯示新內容", await waitH1(v.webView, "版本二"))
        try? FileManager.default.removeItem(at: w)
        var gone = false
        for _ in 0..<60 {
            if let s = await js(v.webView, "document.body && document.body.innerText") as? String,
               s.contains("檔案已不存在"), s.contains(w.path) { gone = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("檔案被刪除後顯示「檔案已不存在」與完整路徑", gone)
        try? "# 版本三\n".write(to: w, atomically: true, encoding: .utf8)
        check("檔案重新出現後，預覽恢復顯示檔案", await waitH1(v.webView, "版本三"))

        // 關閉：不再監看檔案
        v.close()
        check("close() 之後是關閉狀態", v.isClosed)
        try? "# 版本四\n".write(to: w, atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(1200))
        let after = await js(v.webView, "document.querySelector('h1') && document.querySelector('h1').textContent") as? String
        check("close() 之後檔案改變不再重新載入", after != "版本四", after ?? "nil")
    }

    // MARK: - 安全

    // @feature: preview-tab.feature
    // @scenario: Markdown 裡的 HTML 標籤顯示成文字，不執行
    // @scenario: 點網址連結，照終端機裡點連結的規則處理
    @MainActor static func securityChecks(_ root: URL) async {
        let site = root.appendingPathComponent("site"), docs = root.appendingPathComponent("docs")
        let other = root.appendingPathComponent("other")
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let secret = other.appendingPathComponent("secret.txt")
        try? "TOP-SECRET".write(to: secret, atomically: true, encoding: .utf8)
        let flow = docs.appendingPathComponent("img/flow.png").path
        // 惡意 HTML：用 iframe 嵌入 lmux-preview、直接 fetch lmux-preview、用 <img> 載入 lmux-preview
        try? """
        <html><body><img id="probe" src="lmux-preview://\(flow)"><script>
        window.leak = 'none'; window.direct = 'none';
        if (location.protocol === 'file:') {
          window.addEventListener('message', e => { window.leak = String(e.data); });
          const f = document.createElement('iframe'); f.src = 'lmux-preview://' + location.pathname; document.body.append(f);
          fetch('lmux-preview://\(secret.path)').then(r => r.text()).then(t => { window.direct = t }).catch(e => { window.direct = 'blocked' });
        } else {
          fetch('lmux-preview://\(secret.path)').then(r => r.text()).then(t => parent.postMessage(t, '*')).catch(e => parent.postMessage('blocked', '*'));
        }
        </script></body></html>
        """.write(to: site.appendingPathComponent("evil.html"), atomically: true, encoding: .utf8)
        try? "<html><head><meta http-equiv=\"refresh\" content=\"0;url=https://example.com/phish\"></head><body>r</body></html>"
            .write(to: site.appendingPathComponent("refresh.html"), atomically: true, encoding: .utf8)
        try? "# Zero\n\n![z](/dev/zero)\n".write(to: docs.appendingPathComponent("zero.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("link.md"),
                                                    withDestinationURL: URL(fileURLWithPath: "/dev/zero"))

        var external: [URL] = []
        let v = PreviewView(fileURL: site.appendingPathComponent("evil.html"))
        v.openExternal = { external.append($0) }
        let win = host(v)
        defer { win.close() }
        _ = await wait { v.webView.url?.lastPathComponent == "evil.html" && !v.webView.isLoading }
        try? await Task.sleep(for: .seconds(2))
        let leak = await js(v.webView, "window.leak") as? String ?? "nil"
        check("HTML 頁面用 iframe 讀不到其他資料夾的檔案", !leak.contains("TOP-SECRET"), leak)
        let direct = await js(v.webView, "window.direct") as? String ?? "nil"
        check("HTML 頁面直接 fetch lmux-preview 讀不到檔案", direct == "blocked", direct)
        let probe = await js(v.webView, "document.getElementById('probe').naturalWidth")
        check("HTML 頁面用 <img> 載入 lmux-preview 會失敗", (probe as? Int) == 0, "\(String(describing: probe))")

        v.show(site.appendingPathComponent("refresh.html"))
        _ = await wait { v.webView.url?.lastPathComponent == "refresh.html" && !v.webView.isLoading }
        try? await Task.sleep(for: .milliseconds(1500))
        check("meta refresh 不會把預覽換成網頁", v.webView.url?.lastPathComponent == "refresh.html" && external.isEmpty,
              "\(v.webView.url?.absoluteString ?? "nil") \(external)")

        v.show(docs.appendingPathComponent("zero.md"))
        check("Markdown 引用 /dev/zero 不會卡住", await waitH1(v.webView, "Zero"))
        v.show(docs.appendingPathComponent("link.md"))
        var linkMissing = false
        for _ in 0..<60 {
            if let s = await js(v.webView, "document.body && document.body.innerText") as? String, s.contains("檔案已不存在") { linkMissing = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        check("指向 /dev/zero 的 .md symlink 不讀，顯示「檔案已不存在」", linkMissing)
    }
}
```

- [x] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh webkit`
Expected: 編譯失敗，訊息含 `cannot find 'PreviewView' in scope`。

- [x] **Step 3: 建立 `App/Sources/LmuxUI/PreviewView.swift`（整份照抄）**

```swift
import AppKit
import WebKit

/// 預覽 tab 的內容（beat: preview-tab.feature）：一個 WKWebView，顯示 Markdown 檔（經
/// `PreviewSchemeHandler` 轉成 HTML）或 HTML 檔（原樣）。檔案改變時重新載入。
/// cookie 與 storage 只活在這個 view 裡（`nonPersistent`），關掉 tab 就清掉。
@MainActor
public final class PreviewView: NSView, WKNavigationDelegate {
    /// 目前顯示的檔案（點連結、返回上一頁時會換）。
    public private(set) var fileURL: URL
    public let webView: WKWebView
    /// 顯示的檔案換了（點連結、返回）：tab 標題跟著換。
    public var onFileChange: ((URL) -> Void)?
    /// 使用者點了 http(s) 連結：lmux 用終端機裡點連結的規則開啟。
    public var openExternal: ((URL) -> Void)?
    private var watcher: PreviewWatcher?
    /// 使用者最近一次在這個預覽裡按下滑鼠的時間。頁面的 script 自己觸發的點擊不算。
    private var lastUserClick: Date?
    private var clickMonitor: Any?
    /// 已經關閉（`close()`）：不再監看、不再回呼。
    public private(set) var isClosed = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: PreviewSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        addSubview(webView)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.window,
               self.webView.bounds.contains(self.webView.convert(event.locationInWindow, from: nil)) {
                self.lastUserClick = Date()
            }
            return event
        }
        show(fileURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }

    /// 載入 `file`：Markdown 走 scheme；HTML 從磁碟載入，只開放它所在的資料夾。
    public func show(_ file: URL) {
        if PreviewTarget.isMarkdown(file) {
            webView.load(URLRequest(url: PreviewSchemeHandler.url(for: file)))
        } else if FileManager.default.fileExists(atPath: file.path) {
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else {
            webView.loadHTMLString(MarkdownHTML.missingPage(path: file.path), baseURL: nil)
        }
    }

    /// 關閉預覽 tab 時呼叫：停止監看檔案、停止載入、移除滑鼠監看，之後不再回呼。
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        watcher?.stop()
        watcher = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        onFileChange = nil
        openExternal = nil
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    /// 使用者 1 秒內在預覽裡按過滑鼠才算，用掉就清掉：一次點擊最多開一個外部網址。
    func consumeUserClick() -> Bool {
        guard let t = lastUserClick, Date().timeIntervalSince(t) < 1 else { return false }
        lastUserClick = nil
        return true
    }

    /// 測試用：當作使用者剛在預覽裡按了一下滑鼠。
    func noteUserClick() { lastUserClick = Date() }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                        preferences: WKWebpagePreferences,
                        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if scheme == "http" || scheme == "https" {
            if mainFrame {
                // 使用者點了網頁連結：交給 lmux，跟終端機裡點連結一樣。script、meta refresh、表單
                // 想把預覽 tab 換成遠端網頁：一律擋掉。
                if action.navigationType == .linkActivated, consumeUserClick() { openExternal?(url) }
                decisionHandler(.cancel, preferences)
                return
            }
            decisionHandler(.allow, preferences)  // 頁面裡嵌入的網頁（例如影片）照常載入
            return
        }
        // lmux-preview 只能是整頁，不能被 iframe 嵌入（見 PreviewSchemeHandler 的安全說明）。
        if scheme == PreviewSchemeHandler.scheme, !mainFrame {
            decisionHandler(.cancel, preferences)
            return
        }
        // HTML 頁面連到 Markdown：改走 scheme（轉成 HTML）。Markdown 頁面連到 HTML：改從磁碟載入
        // （它的 script 在那裡執行，只讀得到它的資料夾）。
        if mainFrame, url.isFileURL, PreviewTarget.isMarkdown(url) {
            decisionHandler(.cancel, preferences)
            show(url)
            return
        }
        if mainFrame, let file = PreviewSchemeHandler.file(for: url), !PreviewTarget.isMarkdown(file) {
            decisionHandler(.cancel, preferences)
            if ["html", "htm"].contains(file.pathExtension.lowercased()) { show(file) }
            return
        }
        // 整頁只能是本機檔案、lmux-preview、或 lmux 自己產生的頁面（about:blank）。
        if mainFrame, !["file", PreviewSchemeHandler.scheme, "about"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            return
        }
        // Markdown 頁面不執行 JavaScript。
        if mainFrame { preferences.allowsContentJavaScript = scheme != PreviewSchemeHandler.scheme }
        decisionHandler(.allow, preferences)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let file = PreviewSchemeHandler.file(for: url) ?? (url.isFileURL ? url : nil)
        guard let file else { return }
        if file.standardizedFileURL != fileURL.standardizedFileURL || watcher == nil {
            fileURL = file
            onFileChange?(file)
            watch(file)
        }
    }

    private func watch(_ file: URL) {
        watcher?.stop()
        watcher = PreviewWatcher(file: file) { [weak self] in
            guard let self, !self.isClosed else { return }
            let exists = FileManager.default.fileExists(atPath: self.fileURL.path)
            if !exists, !PreviewTarget.isMarkdown(self.fileURL) {
                // HTML 被刪除：顯示「檔案已不存在」（Markdown 的這一頁由 scheme 自己回）。
                self.webView.loadHTMLString(MarkdownHTML.missingPage(path: self.fileURL.path), baseURL: nil)
            } else if self.webView.url?.scheme == "about" {
                // 正在顯示「檔案已不存在」，檔案又出現了：重新載入檔案本身。
                self.show(self.fileURL)
            } else {
                self.webView.reload()
            }
        }
    }
}
```

- [x] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh webkit`
Expected: 43 行 `PASS`（scheme 6、監看 5、PreviewView 26、安全 6）、沒有 `FAIL`，最後一行 `WEBKIT CHECK: ok`。

- [x] **Step 5: 確認 app 仍能 build**

Run: `beat/changes/md-html-preview/dev.sh build`
Expected: `BUILD EXIT: 0`。

- [x] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/PreviewView.swift App/scripts/preview-webkit-check.swift
git commit -m "feat(md-html-preview): 新增 PreviewView，用 WKWebView 顯示 Markdown 與 HTML

Markdown 走 lmux-preview scheme 並關掉 JavaScript；HTML 從磁碟載入、只開放所在資料夾；
使用者點的 http(s) 連結交給 openExternal，script、meta refresh 不能把預覽換成網頁；
HTML 頁面不能用 iframe、fetch、img 取用 lmux-preview；檔案改變自動重新載入，刪除時顯示
「檔案已不存在」，檔案回來後恢復；cookie 與 storage 不保存。

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

## 重構：`Pane.surface` 改成 optional（Task 6–19）

**這一段的規則（每個 task 都適用）：**
- Task 6 之後到 Task 18 之前，`dev.sh build` **一定會失敗**，因為還有檔案沒改。這是預期的。每個 task 只看 `dev.sh errors <這個 task 的檔案>` 的數字。
- 「原本」區塊要在檔案裡**一字不差**找到。找不到就停下來回報，不要猜。
- 只改「原本 → 改成」列出的地方。編譯錯誤列出其他行時，回報，不要自己改。
- 這一段不改變任何行為：預覽 tab 還沒有地方建立。

### Task 6: Model.swift — Pane 改成兩種內容

**Files:**
- Modify: `App/Sources/LmuxUI/Model.swift`

**Interfaces:**
- Consumes: `PreviewView`（Task 5）。
- Produces:
  - `public enum Pane.Content { case terminal(SurfaceView); case preview(PreviewView) }`
  - `public let content: Pane.Content`
  - `public var surface: SurfaceView?`（終端機 tab 才有）
  - `public var preview: PreviewView?`（預覽 tab 才有）
  - `public var foregroundPID: pid_t`（預覽 tab 是 0）
  - `init(id: String, surface: SurfaceView)`（原本就有）、`init(id: String, preview: PreviewView)`（新增）

- [x] **Step 1: 換掉 surface 的宣告**

原本：

```swift
    @ObservationIgnored public let surface: SurfaceView
```

改成：

```swift
    /// tab 顯示的內容：終端機，或一個檔案的預覽（beat: preview-tab.feature）。
    public enum Content {
        case terminal(SurfaceView)
        case preview(PreviewView)
    }
    @ObservationIgnored public let content: Content
    /// 終端機；預覽 tab 是 nil。
    public var surface: SurfaceView? {
        if case .terminal(let s) = content { return s }
        return nil
    }
    /// 預覽；終端機 tab 是 nil。
    public var preview: PreviewView? {
        if case .preview(let p) = content { return p }
        return nil
    }
    /// 終端機前景程式的 process group；預覽 tab 沒有程式，是 0（跟沒有前景程式的終端機一樣）。
    public var foregroundPID: pid_t { surface?.foregroundPID ?? 0 }
```

- [x] **Step 2: 換掉 init**

原本：

```swift
    init(id: String, surface: SurfaceView) {
        self.id = id
        self.surface = surface
    }
```

改成：

```swift
    init(id: String, surface: SurfaceView) {
        self.id = id
        self.content = .terminal(surface)
    }

    init(id: String, preview: PreviewView) {
        self.id = id
        self.content = .preview(preview)
    }
```

- [x] **Step 3: 確認 Model.swift 自己沒有錯誤**

Run: `beat/changes/md-html-preview/dev.sh errors Model.swift`
Expected: `ERRORS IN Model.swift: 0`。（其他檔案會有錯誤，這是預期的。）

- [x] **Step 4: Commit**

```bash
git add App/Sources/LmuxUI/Model.swift
git commit -m "refactor(md-html-preview): Pane 改成持有終端機或預覽，surface 改成 optional

build 會暫時失敗，後面的 task 逐檔修正。

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 7: Agent.swift、CodexSetup.swift、HooksHint.swift

**Files:**
- Modify: `App/Sources/LmuxUI/Agent.swift`、`App/Sources/LmuxUI/CodexSetup.swift`、`App/Sources/LmuxUI/HooksHint.swift`

**Interfaces:**
- Consumes: `Pane.foregroundPID`（Task 6）。

- [x] **Step 1: Agent.swift — 全部替換**

把檔案裡**每一個** `pane.surface.foregroundPID` 換成 `pane.foregroundPID`（共 9 處）。

確認：`grep -c 'surface.foregroundPID' App/Sources/LmuxUI/Agent.swift` → `0`；`grep -c 'pane.foregroundPID' App/Sources/LmuxUI/Agent.swift` → `9`。

- [x] **Step 2: Agent.swift — 標題那一行**

原本：

```swift
                if last?.interrupted == true || (n == 1 && (compacting || pane.surface.title.hasPrefix("✳"))) {
```

改成：

```swift
                if last?.interrupted == true || (n == 1 && (compacting || pane.surface?.title.hasPrefix("✳") == true)) {
```

- [x] **Step 3: CodexSetup.swift**

原本：

```swift
        let p = e.claudePID ?? ClaudeProcess.representative(ofGroup: pane.surface.foregroundPID)
```

改成：

```swift
        let p = e.claudePID ?? ClaudeProcess.representative(ofGroup: pane.foregroundPID)
```

- [x] **Step 4: HooksHint.swift**

原本：

```swift
        let fg = pane.surface.foregroundPID
```

改成：

```swift
        let fg = pane.foregroundPID
```

- [x] **Step 5: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors Agent.swift CodexSetup.swift HooksHint.swift`
Expected: `ERRORS TOTAL: 0`。

- [x] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/Agent.swift App/Sources/LmuxUI/CodexSetup.swift App/Sources/LmuxUI/HooksHint.swift
git commit -m "refactor(md-html-preview): Agent、CodexSetup、HooksHint 改用 Pane.foregroundPID

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 8: Controller.swift（第一部分：關閉、焦點同步、遮蔽、CLI 找 pane、丟棄、選 workspace）

**Files:**
- Modify: `App/Sources/LmuxUI/Controller.swift`

- [x] **Step 1: `shutdown()`**

原本：

```swift
            let fg = p.surface.foregroundPID
            if fg > 0 { killpg(fg, SIGHUP) }
            p.surface.close()
```

改成：

```swift
            let fg = p.foregroundPID
            if fg > 0 { killpg(fg, SIGHUP) }
            p.surface?.close()
```

- [x] **Step 2: `syncSurfaceFocus()`**

原本：

```swift
        for p in ws.panes { p.surface.focusDidChange(p.surface.windowIsKey && window.firstResponder === p.surface) }
```

改成：

```swift
        for p in ws.panes {
            guard let s = p.surface else { continue }
            s.focusDidChange(s.windowIsKey && window.firstResponder === s)
        }
```

- [x] **Step 3: `syncOcclusion()`**

原本：

```swift
                p.surface.setOcclusion(visible: shown && ws === model.selected && (ws.zoomedPane == nil || p === ws.zoomedPane))
```

改成：

```swift
                p.surface?.setOcclusion(visible: shown && ws === model.selected && (ws.zoomedPane == nil || p === ws.zoomedPane))
```

- [x] **Step 4: `windowDidEndSheet(_:)`**

原本：

```swift
                self.model.selected?.focusedPane?.surface.inputContext?.activate()
```

改成：

```swift
                self.model.selected?.focusedPane?.surface?.inputContext?.activate()
```

- [x] **Step 5: `panesNeedingQuitConfirmation`**

原本：

```swift
        model.workspaces.flatMap(\.panes).filter { $0.surface.needsConfirmQuit }
```

改成：

```swift
        model.workspaces.flatMap(\.panes).filter { $0.surface?.needsConfirmQuit == true }
```

- [x] **Step 6: `callerPane(token:peerPID:)`**

原本：

```swift
        return panesByID.values.first { $0.surface.foregroundPID == tpgid }
```

改成：

```swift
        return panesByID.values.first { $0.surface != nil && $0.foregroundPID == tpgid }
```

- [x] **Step 7: `discard(_:)`**

原本：

```swift
        panesBySurface[ObjectIdentifier(pane.surface)] = nil
        pane.view.removeFromSuperview()
        pane.surface.close()
```

改成：

```swift
        if let s = pane.surface { panesBySurface[ObjectIdentifier(s)] = nil }
        pane.view.removeFromSuperview()
        pane.surface?.close()
```

- [x] **Step 8: `newWorkspace(...)`**

原本：

```swift
        if select || model.selected == nil { self.select(ws) } else { pane.surface.setOcclusion(visible: false) }
```

改成：

```swift
        if select || model.selected == nil { self.select(ws) } else { pane.surface?.setOcclusion(visible: false) }
```

- [x] **Step 9: `select(_:focusing:)`**

原本：

```swift
                p.surface.focusDidChange(false)
                p.surface.setOcclusion(visible: false)
```

改成：

```swift
                p.surface?.focusDidChange(false)
                p.surface?.setOcclusion(visible: false)
```

- [x] **Step 10: 確認這 9 處都改好了**

Run: `grep -n 'p\.surface\.\|pane\.surface\.' App/Sources/LmuxUI/Controller.swift`
Expected: 正好 4 行，分別含 `setOcclusion(visible: windowShown && visible)`、`p.surface.focused`、`p.surface.inputHeld`、`p.surface.sendText`（都是 Task 9 要改的）。

- [x] **Step 11: Commit**

```bash
git add App/Sources/LmuxUI/Controller.swift
git commit -m "refactor(md-html-preview): Controller 第一部分處理沒有終端機的 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

（這個 task 不跑 `errors`：Controller.swift 還有 Task 9 的部分沒改。）

---

### Task 9: Controller.swift（第二部分）與 ControlServer.swift（`send` 回傳「不是終端機」）

**Files:**
- Modify: `App/Sources/LmuxUI/Controller.swift`、`App/Sources/LmuxUI/ControlServer.swift`

**Interfaces:**
- Produces: `SendResult.notTerminal`；CLI `send` 指到預覽 tab 時回傳 `{"ok": false, "error": "not a terminal: <id>"}`。

- [x] **Step 1: `splitLeaf(...)`**

原本：

```swift
            newPane.surface.setOcclusion(visible: false)
```

改成：

```swift
            newPane.surface?.setOcclusion(visible: false)
```

- [x] **Step 2: `rebuildContent()`**

原本：

```swift
            p.surface.setOcclusion(visible: windowShown && visible)
```

改成：

```swift
            p.surface?.setOcclusion(visible: windowShown && visible)
```

- [x] **Step 3: `focusCurrent()`**

原本：

```swift
            for p in ws.panes where p !== pane && p.surface.focused { p.surface.focusDidChange(false) }
        }
        if window.firstResponder !== pane.surface {
            window.makeFirstResponder(pane.surface)
        }
```

改成：

```swift
            for p in ws.panes where p !== pane && p.surface?.focused == true { p.surface?.focusDidChange(false) }
        }
        if let s = pane.surface, window.firstResponder !== s {
            window.makeFirstResponder(s)
        }
```

- [x] **Step 4: `ensureFocus()`**

原本：

```swift
        window.makeFirstResponder(pane.surface)
    }
```

（`ensureFocus()` 的最後兩行。檔案裡只有這一處是 `window.makeFirstResponder(pane.surface)` 後面緊接 `    }`。）

改成：

```swift
        if let s = pane.surface { window.makeFirstResponder(s) }
    }
```

- [x] **Step 5: `SendResult` 加一種結果**

原本：

```swift
    public enum SendResult: Equatable { case sent, noSuchPane, crossPaneDenied, externalDenied, paneBusy }
```

改成：

```swift
    public enum SendResult: Equatable { case sent, noSuchPane, notTerminal, crossPaneDenied, externalDenied, paneBusy }
```

- [x] **Step 6: `send(text:toPane:token:peerPID:)`**

原本：

```swift
        guard let p = panesByID[id] else { return .noSuchPane }
```

改成：

```swift
        guard let p = panesByID[id] else { return .noSuchPane }
        // 預覽 tab 沒有終端機，不能打字進去（beat: preview-tab.feature）。
        guard let surface = p.surface else { return .notTerminal }
```

再把同一個函式裡的：

```swift
        if p.surface.inputHeld { return .paneBusy }
        p.surface.sendText(text)
```

改成：

```swift
        if surface.inputHeld { return .paneBusy }
        surface.sendText(text)
```

- [x] **Step 7: ControlServer.swift 處理新的結果**

原本：

```swift
            case .paneBusy:
                return ["ok": false, "error": "that pane is busy rewinding Claude Code; try again in a moment"]
```

改成：

```swift
            case .paneBusy:
                return ["ok": false, "error": "that pane is busy rewinding Claude Code; try again in a moment"]
            case .notTerminal:
                return ["ok": false, "error": "not a terminal: \(pane)"]
```

- [x] **Step 8: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors Controller.swift ControlServer.swift`
Expected: `ERRORS TOTAL: 0`。

- [x] **Step 9: Commit**

```bash
git add App/Sources/LmuxUI/Controller.swift App/Sources/LmuxUI/ControlServer.swift
git commit -m "refactor(md-html-preview): Controller 第二部分；lmux send 指到預覽 tab 時回傳 not a terminal

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 10: MessageActions.swift

**Files:**
- Modify: `App/Sources/LmuxUI/MessageActions.swift`

- [x] **Step 1: 全部替換**

把檔案裡**每一個** `pane.surface.foregroundPID` 換成 `pane.foregroundPID`（共 2 處）。

確認：`grep -c 'surface.foregroundPID' App/Sources/LmuxUI/MessageActions.swift` → `0`。

- [x] **Step 2: `installMessageActions(_:)`**

原本：

```swift
        let s = pane.surface
```

改成：

```swift
        guard let s = pane.surface else { return }
```

- [x] **Step 3: `screenMap(_:maxAge:)`**

原本：

```swift
    func screenMap(_ pane: Pane, maxAge: TimeInterval = 0.4) -> HoverCache {
        if Date().timeIntervalSince(pane.hover.readAt) > maxAge || pane.hover.map == nil {
            let (rows, h) = pane.surface.viewportRows()
```

改成：

```swift
    func screenMap(_ pane: Pane, maxAge: TimeInterval = 0.4) -> HoverCache {
        guard let surface = pane.surface else { return HoverCache() }
        if Date().timeIntervalSince(pane.hover.readAt) > maxAge || pane.hover.map == nil {
            let (rows, h) = surface.viewportRows()
```

- [x] **Step 4: `updateHover(_:)`**

原本：

```swift
        let y = pane.surface.bounds.height - p.y
```

改成：

```swift
        guard let surface = pane.surface else { hideHoverActions(pane); return }
        let y = surface.bounds.height - p.y
```

- [x] **Step 5: `textRight(_:_:)`**

原本：

```swift
        return pane.surface.terminalPadding.width + CGFloat(cols) * max(1, pane.surface.cellSize.width)
```

改成：

```swift
        guard let surface = pane.surface else { return 0 }
        return surface.terminalPadding.width + CGFloat(cols) * max(1, surface.cellSize.width)
```

- [x] **Step 6: `freeRuns(_:)`**

原本：

```swift
    func freeRuns(_ pane: Pane) -> [(top: CGFloat, bottom: CGFloat)] {
        let (rows, h) = pane.surface.viewportRows()
```

改成：

```swift
    func freeRuns(_ pane: Pane) -> [(top: CGFloat, bottom: CGFloat)] {
        guard let surface = pane.surface else { return [] }
        let (rows, h) = surface.viewportRows()
```

- [x] **Step 7: `refreshInputLabel(_:)`**

原本：

```swift
        ov.inputLabel.background = pane.surface.terminalBackground ?? T.Colors.windowBackground.nsColor
        ov.inputLabel.adoptAppearance(on: pane.surface.terminalBackground)
        ov.inputRuleStart = pane.surface.terminalPadding.width
```

改成：

```swift
        ov.inputLabel.background = pane.surface?.terminalBackground ?? T.Colors.windowBackground.nsColor
        ov.inputLabel.adoptAppearance(on: pane.surface?.terminalBackground)
        ov.inputRuleStart = pane.surface?.terminalPadding.width ?? 0
```

- [x] **Step 8: `paneDrewFrame(_:)`**

原本：

```swift
        let y = pane.surface.cursorY
```

改成：

```swift
        guard let y = pane.surface?.cursorY else { return }
```

- [x] **Step 9: `showCard(...)` 與 `dismissCard(_:)`**

確認卡片（例如 Close Workspace）可能顯示在預覽 tab 上。預覽 tab 沒有終端機可以攔 ⏎／esc，改用 local monitor。

原本（`showCard` 的結尾）：

```swift
        pane.surface.keyInterceptor = { [weak card] event in
            guard let card else { return false }
            // A held key's auto-repeat (the Enter that raised the guard) never answers the card.
            if event.isARepeat { return true }
            switch event.keyCode {
            case 0x24, 0x4C: card.confirm.performClick(); return true
            case 0x35: card.cancel.performClick(); return true
            default:
                if event.modifierFlags.contains(.command) { return false }
                card.cancel.performClick()
                return false
            }
        }
    }
```

改成：

```swift
        let answer: (NSEvent) -> Bool = { [weak card] event in
            guard let card else { return false }
            // A held key's auto-repeat (the Enter that raised the guard) never answers the card.
            if event.isARepeat { return true }
            switch event.keyCode {
            case 0x24, 0x4C: card.confirm.performClick(); return true
            case 0x35: card.cancel.performClick(); return true
            default:
                if event.modifierFlags.contains(.command) { return false }
                card.cancel.performClick()
                return false
            }
        }
        if let surface = pane.surface {
            surface.keyInterceptor = answer
        } else {
            // 預覽 tab 沒有終端機可以攔按鍵：用 local monitor 接 ⏎／esc（beat: preview-tab.feature）。
            // ponytail: 卡片關掉後，下一個按鍵才把 monitor 移除；沒有按鍵就一直留著（不攔任何東西）。
            var monitor: Any?
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak card] event in
                guard let card, card.superview != nil else {
                    if let m = monitor {
                        NSEvent.removeMonitor(m)
                        monitor = nil
                    }
                    return event
                }
                return answer(event) ? nil : event
            }
        }
    }
```

原本（`dismissCard` 裡）：

```swift
        pane.surface.keyInterceptor = nil
```

改成：

```swift
        pane.surface?.keyInterceptor = nil
```

- [x] **Step 10: `returnKey(_:)`**

原本：

```swift
        if pane.surface.hasMarkedText(), !inputSourceLanguages().contains(where: { $0.hasPrefix("ko") }) { return }
```

改成：

```swift
        if pane.surface?.hasMarkedText() == true, !inputSourceLanguages().contains(where: { $0.hasPrefix("ko") }) { return }
```

- [x] **Step 11: `runningProcess(_:)`**

原本：

```swift
        return pane.surface.needsConfirmQuit ? "a process" : nil
```

改成：

```swift
        return pane.surface?.needsConfirmQuit == true ? "a process" : nil
```

- [x] **Step 12: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors MessageActions.swift`
Expected: `ERRORS TOTAL: 0`。

- [x] **Step 13: Commit**

```bash
git add App/Sources/LmuxUI/MessageActions.swift
git commit -m "refactor(md-html-preview): MessageActions 處理沒有終端機的 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 11: Rewind.swift

**Files:**
- Modify: `App/Sources/LmuxUI/Rewind.swift`

- [x] **Step 1: 全部替換（三種）**

- 每一個 `pane.surface.inputHeld = ` 換成 `pane.surface?.inputHeld = `（共 4 處）。
- 每一個 `pane.surface.alphaValue = 1` 換成 `pane.surface?.alphaValue = 1`（共 2 處）。
- `_ = pane.surface.performBindingAction("scroll_to_bottom")` 換成 `_ = pane.surface?.performBindingAction("scroll_to_bottom")`（1 處）。

- [x] **Step 2: `finishRewind(...)` 結尾**

原本：

```swift
        if let point = pane.surface.lastMousePoint { paneMouseMoved(pane, point) }
```

改成：

```swift
        if let point = pane.surface?.lastMousePoint { paneMouseMoved(pane, point) }
```

- [x] **Step 3: `freezeFrame(_:)`**

原本：

```swift
        guard let v = FrozenFrameView(surface: pane.surface) else { log("rewind: no frame to hold"); return }
```

改成：

```swift
        guard let surface = pane.surface, let v = FrozenFrameView(surface: surface) else { log("rewind: no frame to hold"); return }
```

同一個函式裡的：

```swift
        pane.surface.alphaValue = 0
```

改成：

```swift
        surface.alphaValue = 0
```

- [x] **Step 4: `screenRows(_:)`**

原本：

```swift
    func screenRows(_ pane: Pane) -> [String] { pane.surface.viewportRows().rows.map(\.text) }
```

改成：

```swift
    func screenRows(_ pane: Pane) -> [String] { pane.surface?.viewportRows().rows.map(\.text) ?? [] }
```

- [x] **Step 5: `send(_:_:_:control:shift:)`**

原本：

```swift
        pane.surface.sendKey(keyCode: keyCode, codepoint: codepoint, control: control, shift: shift)
```

改成：

```swift
        guard let surface = pane.surface else { return false }
        surface.sendKey(keyCode: keyCode, codepoint: codepoint, control: control, shift: shift)
```

- [x] **Step 6: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors Rewind.swift`
Expected: `ERRORS TOTAL: 0`。
另外：`grep -c 'pane\.surface\.' App/Sources/LmuxUI/Rewind.swift` → `0`。

- [x] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/Rewind.swift
git commit -m "refactor(md-html-preview): Rewind 處理沒有終端機的 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 12: Search.swift、Scrollback.swift

**Files:**
- Modify: `App/Sources/LmuxUI/Search.swift`、`App/Sources/LmuxUI/Scrollback.swift`

- [x] **Step 1: Search.swift — 尋找列的回呼**

把下面兩種各換掉（各 2 處）：
- `pane?.surface.inputHeld` → `pane?.surface?.inputHeld`
- `pane?.surface.performBindingAction(` → `pane?.surface?.performBindingAction(`

再把：

```swift
                _ = pane.surface.performBindingAction("end_search")
```

改成：

```swift
                _ = pane.surface?.performBindingAction("end_search")
```

- [x] **Step 2: Search.swift — `menuFind(_:)`**

原本：

```swift
        guard let p = model.selected?.focusedPane, !p.surface.inputHeld else { return }
        if !p.surface.performBindingAction("start_search") { searchStarted(p, needle: nil) }
```

改成：

```swift
        guard let p = model.selected?.focusedPane, let s = p.surface, !s.inputHeld else { return }
        if !s.performBindingAction("start_search") { searchStarted(p, needle: nil) }
```

- [x] **Step 3: Scrollback.swift — `savesScrollback(_:)`**

原本：

```swift
        guard Scrollback.fileName(p.id) != nil, !p.surface.needsConfirmQuit,
              let pid = ClaudeProcess.representative(ofGroup: p.surface.foregroundPID),
```

改成：

```swift
        guard Scrollback.fileName(p.id) != nil, let surface = p.surface, !surface.needsConfirmQuit,
              let pid = ClaudeProcess.representative(ofGroup: surface.foregroundPID),
```

- [x] **Step 4: Scrollback.swift — `saveScrollback()`**

原本：

```swift
            let text = Scrollback.trim(Scrollback.sanitize(p.surface.screenText(rows: Scrollback.maxLines)))
```

改成：

```swift
            guard let surface = p.surface else { continue }
            let text = Scrollback.trim(Scrollback.sanitize(surface.screenText(rows: Scrollback.maxLines)))
```

- [x] **Step 5: Scrollback.swift — `restoreScrollback(savedID:into:)`**

原本：

```swift
        pane.surface.printOutput(shown)
```

改成：

```swift
        pane.surface?.printOutput(shown)
```

- [x] **Step 6: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors Search.swift Scrollback.swift`
Expected: `ERRORS TOTAL: 0`。

- [x] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/Search.swift App/Sources/LmuxUI/Scrollback.swift
git commit -m "refactor(md-html-preview): Search、Scrollback 處理沒有終端機的 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 13: Tabs.swift、PaneViews.swift（PaneView 依內容放終端機或預覽）

**Files:**
- Modify: `App/Sources/LmuxUI/Tabs.swift`、`App/Sources/LmuxUI/PaneViews.swift`

**Interfaces:**
- Produces: `PaneView.scroller` 改成 `SurfaceScroller?`（預覽 tab 是 nil）。預覽 tab 的 `PaneView` 裡放 `PreviewView`，不放捲軸。

- [x] **Step 1: Tabs.swift — 全部替換（兩種）**

- 每一個 `tab.surface.` 換成 `tab.surface?.`（共 3 處）。
- 每一個 `old.surface.` 換成 `old.surface?.`（共 2 處）。
- 每一個 `shown?.surface.terminalBackground` 換成 `shown?.surface?.terminalBackground`（共 2 處）。

- [x] **Step 2: Tabs.swift — 拖曳放置的區域**

原本：

```swift
        let area = pane.surface.frame
```

改成：

```swift
        let area = pane.surface?.frame ?? pane.preview?.frame ?? pv.bounds
```

- [x] **Step 3: PaneViews.swift — scroller 的宣告**

原本：

```swift
    /// The scrollback's overlay scroller (over the terminal, under lmux's overlays).
    let scroller: SurfaceScroller
```

改成：

```swift
    /// The scrollback's overlay scroller (over the terminal, under lmux's overlays). 預覽 tab 沒有捲軸，是 nil。
    let scroller: SurfaceScroller?
```

- [x] **Step 4: PaneViews.swift — `init(pane:)`**

原本：

```swift
    init(pane: Pane) {
        self.pane = pane
        scroller = SurfaceScroller(surface: pane.surface)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        header.isHidden = true
        addSubview(header)
        addSubview(pane.surface)
        addSubview(scroller)
        addSubview(overlay)
        addSubview(ring)
        pane.surface.onDropTarget = { [weak self] on in self?.overlay.dropTarget = on }
        pane.surface.onLinkHover = { [weak self] url, pointer in self?.overlay.showLink(url, pointer: pointer) }
    }
```

改成：

```swift
    init(pane: Pane) {
        self.pane = pane
        scroller = pane.surface.map { SurfaceScroller(surface: $0) }
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        header.isHidden = true
        addSubview(header)
        switch pane.content {
        case .terminal(let surface):
            addSubview(surface)
            if let scroller { addSubview(scroller) }
            surface.onDropTarget = { [weak self] on in self?.overlay.dropTarget = on }
            surface.onLinkHover = { [weak self] url, pointer in self?.overlay.showLink(url, pointer: pointer) }
        case .preview(let preview):
            // 預覽 tab：放 WKWebView，不放捲軸（beat: preview-tab.feature）。
            addSubview(preview)
        }
        addSubview(overlay)
        addSubview(ring)
    }
```

- [x] **Step 5: PaneViews.swift — `layout()`**

原本：

```swift
        pane?.surface.frame = sf
        scroller.frame = sf
```

改成：

```swift
        pane?.surface?.frame = sf
        pane?.preview?.frame = sf
        scroller?.frame = sf
```

- [x] **Step 6: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors Tabs.swift PaneViews.swift`
Expected: `ERRORS TOTAL: 0`。

- [x] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/Tabs.swift App/Sources/LmuxUI/PaneViews.swift
git commit -m "refactor(md-html-preview): PaneView 依內容放終端機或預覽；Tabs 處理沒有終端機的 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 14: CmuxImport.swift、RootView.swift、Menu.swift

**Files:**
- Modify: `App/Sources/LmuxUI/CmuxImport.swift`、`App/Sources/LmuxUI/RootView.swift`、`App/Sources/LmuxUI/Menu.swift`

- [x] **Step 1: CmuxImport.swift**

四處，各換一次：

| 原本 | 改成 |
|---|---|
| `            pane.surface.setOcclusion(visible: false)` | `            pane.surface?.setOcclusion(visible: false)` |
| `                let fg = p.surface.foregroundPID` | `                let fg = p.foregroundPID` |
| `ws.panes.allSatisfy { !$0.surface.hadUserInput && onlyItsOwn($0) }` | `ws.panes.allSatisfy { $0.surface?.hadUserInput != true && onlyItsOwn($0) }` |
| `return p.startedPlain && !p.surface.hadUserInput && p.claudeSessionID == nil` | `return p.startedPlain && p.surface?.hadUserInput != true && p.claudeSessionID == nil` |

- [x] **Step 2: RootView.swift**

每一個 `focusedPane?.surface.terminalBackground` 換成 `focusedPane?.surface?.terminalBackground`（共 2 處）。

- [x] **Step 3: Menu.swift — `menuGhosttyBinding(_:)`**

原本：

```swift
        guard focusedPane?.surface.inputHeld != true else { NSSound.beep(); return }
        _ = focusedPane?.surface.performBindingAction(action)
```

改成：

```swift
        guard focusedPane?.surface?.inputHeld != true else { NSSound.beep(); return }
        _ = focusedPane?.surface?.performBindingAction(action)
```

- [x] **Step 4: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors CmuxImport.swift RootView.swift Menu.swift`
Expected: `ERRORS TOTAL: 0`。

- [x] **Step 5: Commit**

```bash
git add App/Sources/LmuxUI/CmuxImport.swift App/Sources/LmuxUI/RootView.swift App/Sources/LmuxUI/Menu.swift
git commit -m "refactor(md-html-preview): CmuxImport、RootView、Menu 處理沒有終端機的 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 15: Snapshot.swift、Persistence.swift、Attention.swift、Appearance.swift（各一行）

**Files:**
- Modify: `App/Sources/LmuxUI/Snapshot.swift`、`App/Sources/LmuxUI/Persistence.swift`、`App/Sources/LmuxUI/Attention.swift`、`App/Sources/LmuxUI/Appearance.swift`

- [ ] **Step 1: 四個檔案各改一行**

| 檔案 | 原本 | 改成 |
|---|---|---|
| Snapshot.swift | `            let s = pane.surface` | `            guard let s = pane.surface else { continue }` |
| Persistence.swift | `        restored.surface.setOcclusion(visible: false)` | `        restored.surface?.setOcclusion(visible: false)` |
| Attention.swift | `        let h = p.surface.activeTextHash()` | `        guard let h = p.surface?.activeTextHash() else { return }` |
| Appearance.swift | `focusedPane?.surface.terminalBackground` | `focusedPane?.surface?.terminalBackground` |

- [ ] **Step 2: 驗證 LmuxUI 全部沒有錯誤**

Run: `beat/changes/md-html-preview/dev.sh errors Snapshot.swift Persistence.swift Attention.swift Appearance.swift`
Expected: `ERRORS TOTAL: 0`。

Run: `beat/changes/md-html-preview/dev.sh build; grep -c 'Sources/LmuxUI/.*: error:' "${TMPDIR:-/tmp}/md-html-preview/build.log"`
Expected: 最後一行 `0`（LmuxUI 沒有錯誤；build 仍失敗是因為測試檔，下一個 task 處理）。

- [ ] **Step 3: Commit**

```bash
git add App/Sources/LmuxUI/Snapshot.swift App/Sources/LmuxUI/Persistence.swift App/Sources/LmuxUI/Attention.swift App/Sources/LmuxUI/Appearance.swift
git commit -m "refactor(md-html-preview): Snapshot、Persistence、Attention、Appearance 處理沒有終端機的 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### 測試檔的修正規則（Task 16–18 共用）

測試只建立終端機 tab，所以 `surface` 一定有值，用 `!` 就好。**只照編譯錯誤改，不要整檔搜尋取代**：`SurfaceView` 自己也有一個叫 `surface` 的屬性（libghostty 的指標），整檔取代會改錯。

照錯誤訊息的種類改「那一行」：

| 錯誤訊息 | 改法 | 例子 |
|---|---|---|
| `value of optional type 'SurfaceView?' must be unwrapped to refer to member 'X' ...` | 那一行的 `.surface.X` → `.surface!.X`；如果是 `?.surface.X` → `?.surface?.X` | `p0.surface.scrollbar` → `p0.surface!.scrollbar` |
| `value of optional type 'SurfaceView?' must be unwrapped to a value of type 'SurfaceView'` | 那一行當作值使用的 `.surface`（函式參數、`=` 右邊、`return` 後面）→ `.surface!` | `let s = p.surface` → `let s = p.surface!` |
| `value of optional type 'SurfaceScroller?' must be unwrapped ...` | 那一行的 `.view.scroller` → `.view.scroller!` | `hit(p0.view.scroller, …)` → `hit(p0.view.scroller!, …)` |
| 錯誤那一行**沒有** `.surface`／`.view.scroller`（例如 `s.bounds.height` 出錯） | 不要改這一行。往上找這個變數的宣告（`let s = ….surface` 或 `let sc = ….view.scroller`），在宣告那一行的 `.surface`／`.scroller` 後面加 `!` | `let s = p.surface` → `let s = p.surface!` |
| 其他提到 `SurfaceView?` 或 `SurfaceScroller?` 的錯誤 | 停下來，回報錯誤訊息全文 | — |

已知的「宣告」（第 4 種）在各 task 的 Step 1 直接列出，先改它們，再看編譯錯誤。

同一行有多個錯誤時，每個都要改。改完再跑一次，直到這個 task 的檔案都是 0。

---

### Task 16: 測試檔第一組（Tests、P2Tests、Compat）

**Files:**
- Modify: `App/Sources/lmux-apptest/Tests.swift`、`App/Sources/lmux-apptest/P2Tests.swift`、`App/Sources/lmux-apptest/Compat.swift`

- [ ] **Step 1: 先改已知的宣告（Compat.swift 兩處）**

| 原本 | 改成 |
|---|---|
| `        let s = p.surface` | `        let s = p.surface!` |
| `        let p = ws.panes[0], s = p.surface` | `        let p = ws.panes[0], s = p.surface!` |

- [ ] **Step 2: 列出錯誤，照「測試檔的修正規則」逐行修正**

Run: `beat/changes/md-html-preview/dev.sh errors Tests.swift P2Tests.swift Compat.swift`
Expected: 一串 error 行（數量不固定）。照規則修正後再跑，直到 `ERRORS TOTAL: 0`。

- [ ] **Step 3: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors Tests.swift P2Tests.swift Compat.swift`
Expected: `ERRORS TOTAL: 0`。

- [ ] **Step 4: 確認只加了 `!`（或 `?.` 的那一種）**

Run: `git diff -U0 -- App/Sources/lmux-apptest/Tests.swift App/Sources/lmux-apptest/P2Tests.swift App/Sources/lmux-apptest/Compat.swift | grep '^[-+][^-+]' | sed 's/^[-+]//; s/surface[!?]/surface/g; s/scroller!/scroller/g' | sort | uniq -u | head`
Expected: 沒有輸出（每一行改動拿掉 `!`／`?` 後都跟原本相同）。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/lmux-apptest/Tests.swift App/Sources/lmux-apptest/P2Tests.swift App/Sources/lmux-apptest/Compat.swift
git commit -m "test(md-html-preview): 測試檔第一組改用 surface!

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 17: 測試檔第二組（PaneTabs、ZoomClearReorder、ScrollbackTests、CodexReal、RealWindow）

**Files:**
- Modify: `App/Sources/lmux-apptest/PaneTabs.swift`、`ZoomClearReorder.swift`、`ScrollbackTests.swift`、`CodexReal.swift`、`RealWindow.swift`（都在 `App/Sources/lmux-apptest/`）

- [ ] **Step 1: 先改已知的宣告（RealWindow.swift 三處）**

| 原本 | 改成 |
|---|---|
| `        let s = pane.surface` | `        let s = pane.surface!` |
| `    let s1 = p1.surface` | `    let s1 = p1.surface!` |
| `        let s = p.surface` | `        let s = p.surface!` |

- [ ] **Step 2: 列出錯誤，照「測試檔的修正規則」逐行修正**

Run: `beat/changes/md-html-preview/dev.sh errors PaneTabs.swift ZoomClearReorder.swift ScrollbackTests.swift CodexReal.swift RealWindow.swift`
Expected: 一串 error 行（數量不固定）。照規則修正後再跑，直到 `ERRORS TOTAL: 0`。

- [ ] **Step 3: 驗證**

Run: `beat/changes/md-html-preview/dev.sh errors PaneTabs.swift ZoomClearReorder.swift ScrollbackTests.swift CodexReal.swift RealWindow.swift`
Expected: `ERRORS TOTAL: 0`。

- [ ] **Step 4: 確認只加了 `!`（或 `?.` 的那一種）**

Run: `git diff -U0 -- App/Sources/lmux-apptest/PaneTabs.swift App/Sources/lmux-apptest/ZoomClearReorder.swift App/Sources/lmux-apptest/ScrollbackTests.swift App/Sources/lmux-apptest/CodexReal.swift App/Sources/lmux-apptest/RealWindow.swift | grep '^[-+][^-+]' | sed 's/^[-+]//; s/surface[!?]/surface/g; s/scroller!/scroller/g' | sort | uniq -u | head`
Expected: 沒有輸出（每一行改動拿掉 `!`／`?` 後都跟原本相同）。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/lmux-apptest/PaneTabs.swift App/Sources/lmux-apptest/ZoomClearReorder.swift App/Sources/lmux-apptest/ScrollbackTests.swift App/Sources/lmux-apptest/CodexReal.swift App/Sources/lmux-apptest/RealWindow.swift
git commit -m "test(md-html-preview): 測試檔第二組改用 surface!

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 18: 測試檔第三組（其餘 18 個檔案）

**Files:**
- Modify（`App/Sources/lmux-apptest/`）：`StatusExtras.swift`、`NewUser.swift`、`E2E.swift`、`Agents.swift`、`Regressions.swift`、`EscIdle.swift`、`E2EHover.swift`、`Hero.swift`、`Parity.swift`、`ConfigTests.swift`、`RewindBench.swift`、`Readme.swift`、`GpuIdle.swift`、`Sidebar.swift`、`E2ERunning.swift`、`Polish.swift`、`Contrast.swift`
- Modify：`App/Sources/lmux-imetest/Checklist.swift`

說明：`lmux-imetest/Checklist.swift` 裡的 `.surface` 多半是 `SurfaceView` 自己的 libghostty 指標，預期 0 個錯誤、不用改。不要主動去找要改的地方，只看編譯錯誤。

- [ ] **Step 1: 先改已知的宣告（Parity.swift 四處、Readme.swift 一處、Contrast.swift 一處）**

| 檔案 | 原本 | 改成 |
|---|---|---|
| Parity.swift | `    let sc0 = p0.view.scroller` | `    let sc0 = p0.view.scroller!` |
| Parity.swift | `    let s = p.surface` | `    let s = p.surface!` |
| Parity.swift | `    let sc = p.view.scroller` | `    let sc = p.view.scroller!` |
| Parity.swift | `    let qs = q.surface` | `    let qs = q.surface!` |
| Readme.swift | `    let s = p.surface` | `    let s = p.surface!` |
| Contrast.swift | `        let s = ws.panes[0].surface` | `        let s = ws.panes[0].surface!` |

- [ ] **Step 2: 列出錯誤，照「測試檔的修正規則」逐行修正**

Run: `beat/changes/md-html-preview/dev.sh errors StatusExtras.swift NewUser.swift E2E.swift Agents.swift Regressions.swift EscIdle.swift E2EHover.swift Hero.swift Parity.swift ConfigTests.swift RewindBench.swift Readme.swift GpuIdle.swift Sidebar.swift E2ERunning.swift Polish.swift Contrast.swift Checklist.swift`
Expected: 一串 error 行（數量不固定）。照規則修正後再跑，直到 `ERRORS TOTAL: 0`。

- [ ] **Step 3: 驗證整個 package 能 build**

Run: `beat/changes/md-html-preview/dev.sh build`
Expected: `BUILD EXIT: 0`。
不是 0：看 `${TMPDIR:-/tmp}/md-html-preview/build.log` 的 error 行。是測試檔的 `SurfaceView?`／`SurfaceScroller?` 錯誤就照規則改；其他錯誤就停下來回報。

- [ ] **Step 4: 確認只加了 `!`（或 `?.` 的那一種）**

Run: `git diff -U0 HEAD -- App/Sources/lmux-apptest App/Sources/lmux-imetest | grep '^[-+][^-+]' | sed 's/^[-+]//; s/surface[!?]/surface/g; s/scroller!/scroller/g' | sort | uniq -u | head`
Expected: 沒有輸出。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/lmux-apptest App/Sources/lmux-imetest
git commit -m "test(md-html-preview): 其餘測試檔改用 surface!，整個 package 恢復可 build

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 19: 檢查點 — 重構後行為不變

**Files:** 無（只驗證）

- [ ] **Step 1: build**

Run: `beat/changes/md-html-preview/dev.sh build`
Expected: `BUILD EXIT: 0`。

- [ ] **Step 2: 完整回歸（很久，見「跑很久的指令」）**

Run: `beat/changes/md-html-preview/dev.sh apptest-full; beat/changes/md-html-preview/dev.sh new-failures full`
Expected: `NEW FAILURES: 0` 與 `MISSING CHECKS: 0`。
不是 0：先重跑一次 `apptest-full` 與 `new-failures full`，排除偶發失敗。還是不是 0：**停止**，回報列出的項目與 `${TMPDIR:-/tmp}/md-html-preview/full.log` 裡對應的行。重構不應該讓任何既有測試失敗或消失。

- [ ] **Step 3: 兩個檢查腳本仍通過**

Run: `beat/changes/md-html-preview/dev.sh check && beat/changes/md-html-preview/dev.sh webkit | tail -1`
Expected: `preview check: ok` 與 `WEBKIT CHECK: ok`。

（沒有改檔案，不 commit。）

---

## 接上預覽 tab（Task 20–29）

### Task 20: 建立預覽 tab（makePreviewPane、newPreviewTab）與 apptest 的 `--preview`

**Files:**
- Modify: `App/Sources/LmuxUI/Controller.swift`（加 `makePreviewPane`）
- Modify: `App/Sources/LmuxUI/Tabs.swift`（加 `newPreviewTab`）
- Create: `App/Sources/lmux-apptest/Preview.swift`
- Modify: `App/Sources/lmux-apptest/main.swift`、`App/scripts/apptest.sh`

**Interfaces:**
- Produces:
  - `func makePreviewPane(file: URL) -> Pane`（LmuxController，Controller.swift）
  - `@discardableResult public func newPreviewTab(_ file: URL, after pane: Pane) -> Pane?`（LmuxController，Tabs.swift）
  - apptest：`lmux-apptest --preview`、`func runPreview() async -> Int32`、`func previewSetup(_ c: LmuxController, dir: URL, file: URL) -> (ws: Workspace, a: Pane, p: Pane)`
  - `App/Sources/lmux-apptest/Preview.swift` 裡的插入點註解：`    // 新的檢查段落加在這一行上面（tasks.md 的 Task 21-28）`

- [ ] **Step 1: 建立 `App/Sources/lmux-apptest/Preview.swift`（整份照抄）**

```swift
import AppKit
import GhosttyKit
import LmuxTerminal
@testable import LmuxUI

// `lmux-apptest --preview`：預覽 tab 與 ⌘-click 的開啟選單（beat/changes/md-html-preview）。
// 開啟選單由 `LmuxController.openMenuTestHook` 回答，不會真的跳出；開啟檔案與網址由
// `GhosttyRuntime.openURL` 接住，不會真的打開任何東西。

/// 一個新的 workspace：終端機 tab A（目前目錄是 `dir`），A 右邊是 `file` 的預覽 tab P。
@MainActor
func previewSetup(_ c: LmuxController, dir: URL, file: URL) -> (ws: Workspace, a: Pane, p: Pane) {
    let ws = c.newWorkspace(cwd: dir.path)
    let a = ws.panes[0]
    a.cwd = dir.path  // 測試用的 shell 不回報目前目錄（OSC 7）：直接設定
    let p = c.newPreviewTab(file, after: a)!
    return (ws, a, p)
}

@MainActor
func runPreview() async -> Int32 {
    let r = Report()
    var opened: [URL] = []
    GhosttyRuntime.openURL = { opened.append($0) }
    let c = makeController()
    // 測試用的檔案：<LMUX_STATE_DIR>/preview-fixtures/docs/{design.md, b.md, notes.txt}
    let fx = URL(fileURLWithPath: env["LMUX_STATE_DIR"]!).appendingPathComponent("preview-fixtures", isDirectory: true)
    let docs = fx.appendingPathComponent("docs", isDirectory: true)
    try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try? "# Design\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n[b](b.md)\n"
        .write(to: docs.appendingPathComponent("design.md"), atomically: true, encoding: .utf8)
    try? "# B\n".write(to: docs.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
    try? "notes\n".write(to: docs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let design = docs.appendingPathComponent("design.md").standardizedFileURL

    // MARK: 建立預覽 tab（Task 20）
    // @feature: open-menu.feature
    // @scenario: 選「在新 tab 預覽」開出預覽 tab
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 的標題是檔名
    do {
        r.section = "preview-tab"
        let ws = c.newWorkspace(cwd: fx.path)
        let a = ws.panes[0]
        a.cwd = fx.path
        let b = c.newTab(a)!
        c.focus(a)
        let p = c.newPreviewTab(design, after: a)
        r.check("新 tab 預覽：開出沒有終端機的預覽 tab", p?.preview != nil && p?.surface == nil)
        if let p {
            r.check("預覽 tab 插在 A 與 B 之間", ws.root.find(a)?.tabs.map(\.id) == [a.id, p.id, b.id],
                    "\(ws.root.find(a)?.tabs.map(\.id) ?? [])")
            r.check("預覽 tab 成為 focused tab", ws.focusedPane === p)
            r.check("預覽 tab 的標題是檔名", p.headerTitle == "design.md", p.headerTitle)
            r.check("預覽 tab 的目前目錄是檔案所在資料夾", p.cwd == docs.standardizedFileURL.path, p.cwd ?? "nil")
            r.check("預覽 tab 顯示這個檔案", p.preview?.fileURL.standardizedFileURL == design)
            r.check("c.pane(id:) 找得到預覽 tab", c.pane(id: p.id) === p)
            let loaded = await waitFor(5) { p.preview?.webView.isLoading == false && p.preview?.webView.url != nil }
            let h1 = try? await p.preview?.webView.evaluateJavaScript("document.querySelector('h1').textContent")
            r.check("預覽 tab 顯示排版後的 Markdown", loaded && (h1 as? String) == "Design", "\(String(describing: h1))")
        }
    }

    // 新的檢查段落加在這一行上面（tasks.md 的 Task 21-28）
    return finish(r, c)
}
```

- [ ] **Step 2: main.swift 加上 `--preview`**

在 `App/Sources/lmux-apptest/main.swift` 找到：

```swift
            } else if args.contains("--parity") {
                code = await runParity()
```

改成：

```swift
            } else if args.contains("--preview") {
                code = await runPreview()
            } else if args.contains("--parity") {
                code = await runParity()
```

- [ ] **Step 3: apptest.sh 加上 `--preview`（兩處）**

找到：

```bash
if [ "${1:-}" = "--rewind" ]; then
  LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --rewind 2>/dev/null | filter || status=1
  exit $status
fi
```

在它**後面**加上：

```bash
if [ "${1:-}" = "--preview" ]; then
  mkdir -p "$T/preview"
  LMUX_STATE_DIR="$T/preview" LMUX_PANE_COMMAND="$T/sink.sh" LMUX_IGNORE_GHOSTTY_CONFIG=1 LMUX_CONFIG_FILE="$T/preview/lmux-config" \
    "$BIN/lmux-apptest" --preview 2>/dev/null | filter || status=1
  exit $status
fi
```

再找到：

```bash
LMUX_STATE_DIR="$T/parity" LMUX_PANE_COMMAND="$T/sink.sh" "$BIN/lmux-apptest" --parity 2>/dev/null | filter || status=1
```

在它**後面**加上：

```bash
# 預覽 tab 與 ⌘-click 的開啟選單（beat: md-html-preview）。不讀使用者的 Ghostty 設定（⌘T 沿用目錄的檢查）。
mkdir -p "$T/preview"
LMUX_STATE_DIR="$T/preview" LMUX_PANE_COMMAND="$T/sink.sh" LMUX_IGNORE_GHOSTTY_CONFIG=1 LMUX_CONFIG_FILE="$T/preview/lmux-config" \
  "$BIN/lmux-apptest" --preview 2>/dev/null | filter || status=1
```

- [ ] **Step 4: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh build; grep -c "no member 'newPreviewTab'" "${TMPDIR:-/tmp}/md-html-preview/build.log"`
Expected: 最後一行至少是 1（build 失敗，因為 `newPreviewTab` 還不存在）。

- [ ] **Step 5: Controller.swift 加 `makePreviewPane`**

在 `App/Sources/LmuxUI/Controller.swift` 找到 `makePane` 的結尾：

```swift
        panesByID[id] = pane
        panesBySurface[ObjectIdentifier(surface)] = pane
        paneIDByToken[token] = id
        return pane
    }
```

在它**後面**加上：

```swift

    /// 預覽 tab 的 Pane（beat: preview-tab.feature）：沒有終端機、不跑程式、沒有 LMUX_PANE_ID。
    /// 目前目錄是檔案所在資料夾：在它上面開新 tab 或分割時，新的終端機從那裡開始。
    func makePreviewPane(file: URL) -> Pane {
        let preview = PreviewView(fileURL: file)
        let pane = Pane(id: UUID().uuidString, preview: preview)
        pane.title = file.lastPathComponent
        let dir = file.deletingLastPathComponent().path
        pane.cwd = dir
        pane.branch = GitBranch.read(cwd: dir)
        panesByID[pane.id] = pane
        return pane
    }
```

- [ ] **Step 6: Tabs.swift 加 `newPreviewTab`**

在 `App/Sources/LmuxUI/Tabs.swift` 找到 `newTab` 的結尾：

```swift
        insert(tab, into: leaf, at: at, ws, select: select)
        return tab
    }
```

（檔案裡第一個這樣的三行，在 `public func newTab(` 裡。）在它**後面**加上：

```swift

    /// 開啟選單的「在新 tab 預覽」（beat: open-menu.feature）：`file` 的預覽 tab，插在 `pane` 的右邊
    /// （與 ⌘T 同位置），並成為 focused tab。
    @discardableResult
    public func newPreviewTab(_ file: URL, after pane: Pane) -> Pane? {
        guard let ws = pane.workspace, let leaf = ws.root.find(pane) else { return nil }
        let tab = makePreviewPane(file: file)
        let at = (leaf.tabs.firstIndex { $0 === pane } ?? leaf.tabs.count - 1) + 1
        insert(tab, into: leaf, at: at, ws, select: true)
        return tab
    }
```

- [ ] **Step 7: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 8 行 `PASS  [preview-tab]`、沒有 `FAIL`、`RESULT: PASS`、`APPTEST EXIT: 0`。

- [ ] **Step 8: Commit**

```bash
git add App/Sources/LmuxUI/Controller.swift App/Sources/LmuxUI/Tabs.swift App/Sources/lmux-apptest/Preview.swift App/Sources/lmux-apptest/main.swift App/scripts/apptest.sh
git commit -m "feat(md-html-preview): 可以開出預覽 tab；apptest 新增 --preview

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 21: 預覽 tab 的鍵盤焦點

**Files:**
- Modify: `App/Sources/LmuxUI/Controller.swift`（`focusCurrent`、`ensureFocus`）
- Modify: `App/Sources/lmux-apptest/Preview.swift`

- [ ] **Step 1: 加測試**

在 `App/Sources/lmux-apptest/Preview.swift` 找到：

```swift
    // 新的檢查段落加在這一行上面（tasks.md 的 Task 21-28）
```

在它**上面**加上：

```swift
    // MARK: 預覽 tab 的焦點（Task 21）
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上
    do {
        r.section = "preview-focus"
        let (_, a, p) = previewSetup(c, dir: fx, file: design)
        c.focus(p)
        let fr = c.window!.firstResponder
        r.check("預覽 tab 取得焦點：first responder 在它的 WKWebView 裡",
                (fr as? NSView)?.isDescendant(of: p.preview!.webView) == true, "\(String(describing: fr))")
        var chain: NSResponder? = fr
        var reachesTerminal = false
        while let x = chain {
            if x is SurfaceView { reachesTerminal = true }
            chain = x.nextResponder
        }
        r.check("預覽 tab 是 focused tab 時，打字與 Paste 不會進到終端機", !reachesTerminal)
        c.focus(a)
        r.check("回到終端機 tab：first responder 是它的終端機", c.window!.firstResponder === a.surface)
    }

```

- [ ] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: `FAIL  [preview-focus] 預覽 tab 取得焦點：first responder 在它的 WKWebView 裡`。

- [ ] **Step 3: `focusCurrent()`**

在 `App/Sources/LmuxUI/Controller.swift` 找到（Task 9 改過的）：

```swift
        if let s = pane.surface, window.firstResponder !== s {
            window.makeFirstResponder(s)
        }
```

改成：

```swift
        if let s = pane.surface, window.firstResponder !== s {
            window.makeFirstResponder(s)
        } else if let preview = pane.preview, (window.firstResponder as? NSView)?.isDescendant(of: preview.webView) != true {
            // 預覽 tab：焦點交給 WKWebView（beat: preview-tab.feature）。
            window.makeFirstResponder(preview.webView)
        }
```

- [ ] **Step 4: `ensureFocus()`**

找到（`ensureFocus()` 裡，Task 9 改過的）：

```swift
        if let s = fr as? SurfaceView, ws.visiblePanes.contains(where: { $0.surface === s }) { return }
        if let s = pane.surface { window.makeFirstResponder(s) }
    }
```

改成：

```swift
        if let s = fr as? SurfaceView, ws.visiblePanes.contains(where: { $0.surface === s }) { return }
        if let v = fr as? NSView, ws.visiblePanes.contains(where: { $0.preview.map { v.isDescendant(of: $0) } == true }) { return }
        if let s = pane.surface {
            window.makeFirstResponder(s)
        } else if let preview = pane.preview {
            window.makeFirstResponder(preview.webView)
        }
    }
```

- [ ] **Step 5: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 沒有 `FAIL`、`APPTEST EXIT: 0`。

- [ ] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "feat(md-html-preview): 預覽 tab 取得焦點時，鍵盤交給 WKWebView

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 22: 開啟選單（OpenMenu.swift）

**Files:**
- Create: `App/Sources/LmuxUI/OpenMenu.swift`
- Modify: `App/Sources/lmux-apptest/Preview.swift`

**Interfaces:**
- Consumes: `PreviewTarget.resolve`、`newPreviewTab`、`GhosttyRuntime.openTerminalURL`、`GhosttyRuntime.standardPasteboard`。
- Produces（都在 `extension LmuxController`）：
  - `public enum OpenChoice: Equatable { case preview, defaultApp, finder, copyPath }`
  - `static let openMenuItems: [(title: String, choice: OpenChoice)]`
  - `public static var openMenuTestHook: ((URL) -> OpenChoice?)?`
  - `public static var revealInFinder: (URL) -> Void`
  - `public func openTerminalLink(_ value: String, kind: ghostty_action_open_url_kind_e, pane: Pane?, view: SurfaceView?)`
  - `static func makeOpenMenu(_ file: URL, target: AnyObject?) -> NSMenu`、`static func shortPath(_ path: String, limit: Int = 90) -> String`

- [ ] **Step 1: 加測試**

在 `App/Sources/lmux-apptest/Preview.swift` 的插入點註解**上面**加上：

```swift
    // MARK: 開啟選單（Task 22）
    // @feature: open-menu.feature
    // @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單
    // @scenario: 路徑後面帶行號時，去掉行號再判斷
    // @scenario: OSC 8 連結指向本機的可預覽檔案時也跳出開啟選單
    // @scenario: 不是存在的可預覽檔案時，照原本流程
    // @scenario: shell 沒回報目前目錄時，相對路徑照原本流程
    // @scenario: 選「在新 tab 預覽」開出預覽 tab
    // @scenario: 選單的其他項目
    // @scenario: 不選任何項目就關掉選單
    do {
        r.section = "open-menu"
        var asked: [URL] = []
        var answer: LmuxController.OpenChoice?
        var revealed: [URL] = []
        var prompts: [UntrustedURLPrompt] = []
        LmuxController.openMenuTestHook = { asked.append($0); return answer }
        LmuxController.revealInFinder = { revealed.append($0) }
        UntrustedURLAlert.testHook = { prompts.append($0); return false }
        defer {
            LmuxController.openMenuTestHook = nil
            UntrustedURLAlert.testHook = nil
        }
        let ws = c.newWorkspace(cwd: fx.path)
        let a = ws.panes[0]
        a.cwd = fx.path
        let b = c.newTab(a)!
        c.focus(a)
        func click(_ value: String, _ kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN) {
            c.openTerminalLink(value, kind: kind, pane: a, view: a.surface)
        }
        /// 同一個值：經過 openTerminalLink，與直接走原本流程（GhosttyRuntime.openTerminalURL），開啟的東西與詢問都一樣。
        func sameAsBefore(_ value: String, _ kind: ghostty_action_open_url_kind_e = GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN) -> Bool {
            opened.removeAll(); prompts.removeAll()
            GhosttyRuntime.openTerminalURL(value, kind: kind, window: a.surface?.window)
            let before = (opened, prompts)
            opened.removeAll(); prompts.removeAll()
            click(value, kind)
            return opened == before.0 && prompts == before.1
        }
        func real(_ u: URL) -> String { u.resolvingSymlinksInPath().path }

        // 選單本身
        let menu = LmuxController.makeOpenMenu(design, target: nil)
        r.check("選單第 1 列是完整路徑，不能點", menu.items.first?.title == design.path && menu.items.first?.isEnabled == false,
                menu.items.first?.title ?? "nil")
        r.check("選單項目依序是 在新 tab 預覽、用預設 app 開、在 Finder 顯示、複製路徑",
                menu.items.dropFirst(2).map(\.title) == ["在新 tab 預覽", "用預設 app 開", "在 Finder 顯示", "複製路徑"],
                "\(menu.items.map(\.title))")
        let longPath = "/" + String(repeating: "abcdefgh/", count: 15) + "design.md"
        r.check("太長的路徑省略資料夾中間，檔名完整保留",
                LmuxController.shortPath(longPath).hasSuffix("/design.md") && LmuxController.shortPath(longPath).count <= 90,
                LmuxController.shortPath(longPath))

        // 跳出選單；關掉選單
        answer = nil
        c.window!.makeFirstResponder(nil)
        opened.removeAll()
        click("docs/design.md")
        r.check("⌘-click 可預覽檔案的路徑：跳出開啟選單，問的是這個檔案", asked == [design], "\(asked)")
        r.check("關掉選單：沒有開出預覽 tab，也沒有開啟任何東西",
                ws.panes.count == 2 && opened.isEmpty && revealed.isEmpty, "\(ws.panes.count) \(opened) \(revealed)")
        r.check("關掉選單：焦點回到終端機", c.window!.firstResponder === a.surface)
        asked.removeAll()
        click("docs/design.md:12")
        r.check("路徑帶行號：去掉行號後仍跳出選單", asked == [design], "\(asked)")
        asked.removeAll()
        click(design.absoluteString, GHOSTTY_ACTION_OPEN_URL_KIND_OSC8)
        r.check("OSC 8 的 file:// 連結：跳出選單", asked == [design], "\(asked)")

        // 照原本流程
        asked.removeAll()
        r.check("不是可預覽檔案：照原本流程開啟",
                sameAsBefore(docs.appendingPathComponent("notes.txt").path) && opened.count == 1, "\(opened)")
        r.check("檔案不存在：照原本流程", sameAsBefore("docs/missing.md"))
        r.check("網址：照原本流程開啟",
                sameAsBefore("https://example.com/readme.md") && opened == [URL(string: "https://example.com/readme.md")!],
                "\(opened)")
        a.cwd = nil
        r.check("shell 沒回報目前目錄：相對路徑照原本流程", sameAsBefore("docs/design.md"))
        a.cwd = fx.path
        r.check("設定檔類（text）的連結：照原本流程", sameAsBefore(design.path, GHOSTTY_ACTION_OPEN_URL_KIND_TEXT))
        r.check("照原本流程的這幾種都沒有跳出選單", asked.isEmpty, "\(asked)")

        // 選單項目
        answer = .defaultApp; opened.removeAll()
        click("docs/design.md")
        r.check("用預設 app 開：交給系統開這個檔案", opened.map(real) == [real(design)], "\(opened)")
        answer = .finder
        click("docs/design.md")
        r.check("在 Finder 顯示：交給 Finder 選取這個檔案", revealed == [design], "\(revealed)")
        answer = .copyPath
        click("docs/design.md")
        r.check("複製路徑：剪貼簿是完整路徑", GhosttyRuntime.standardPasteboard.string(forType: .string) == design.path,
                GhosttyRuntime.standardPasteboard.string(forType: .string) ?? "nil")
        r.check("其他項目都不開出預覽 tab", ws.panes.count == 2, "\(ws.panes.count)")
        answer = .preview
        click("docs/design.md")
        let leaf = ws.root.find(a)
        let p = leaf?.tabs.first { $0.preview != nil }
        r.check("在新 tab 預覽：插在 A 與 B 之間", leaf?.tabs.map(\.id) == [a.id, p?.id ?? "-", b.id],
                "\(leaf?.tabs.map(\.id) ?? [])")
        r.check("在新 tab 預覽：成為 focused tab", p != nil && ws.focusedPane === p)
    }

```

- [ ] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh build; grep -c "no member 'openMenuTestHook'" "${TMPDIR:-/tmp}/md-html-preview/build.log"`
Expected: 最後一行至少是 1（build 失敗，因為開啟選單還不存在）。

- [ ] **Step 3: 建立 `App/Sources/LmuxUI/OpenMenu.swift`（整份照抄）**

```swift
import AppKit
import GhosttyKit
import LmuxTerminal

/// 在終端機 ⌘-click 可預覽檔案的路徑時，跳出開啟選單讓使用者選擇開在哪裡（beat: open-menu.feature）。
extension LmuxController {
    /// 開啟選單的項目。
    public enum OpenChoice: Equatable {
        case preview, defaultApp, finder, copyPath
    }

    /// 選單的項目與順序（第 1 列的完整路徑不在這裡）。
    static let openMenuItems: [(title: String, choice: OpenChoice)] = [
        ("在新 tab 預覽", .preview),
        ("用預設 app 開", .defaultApp),
        ("在 Finder 顯示", .finder),
        ("複製路徑", .copyPath),
    ]

    /// 測試用：設定後不跳出選單，改由它回答（回傳 nil 表示使用者關掉選單）。
    public static var openMenuTestHook: ((URL) -> OpenChoice?)?
    /// 「在 Finder 顯示」實際做的事；測試換掉它，不真的打開 Finder。
    public static var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    /// 終端機送來的 OPEN_URL（⌘-click 的文字、OSC 8 連結）：可預覽檔案跳出開啟選單，其他照原本流程。
    /// `pane`、`view`：連結所在的終端機 tab 與它的終端機。
    public func openTerminalLink(_ value: String, kind: ghostty_action_open_url_kind_e, pane: Pane?, view: SurfaceView?) {
        let textOrFileLink = kind == GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN
            || (kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 && value.lowercased().hasPrefix("file://"))
        if textOrFileLink, let pane, let file = PreviewTarget.resolve(value, cwd: pane.cwd) {
            showOpenMenu(file, pane: pane, view: view)
            return
        }
        // 原本流程：與 GhosttyRuntime 收到 OPEN_URL 時做的事相同。
        let label = kind == GHOSTTY_ACTION_OPEN_URL_KIND_OSC8 ? view?.wordUnderMouse() : nil
        GhosttyRuntime.openTerminalURL(value, kind: kind, window: view?.window, label: label)
    }

    /// 跳出開啟選單，執行使用者選的項目。
    func showOpenMenu(_ file: URL, pane: Pane, view: SurfaceView?) {
        let choice: OpenChoice?
        if let hook = Self.openMenuTestHook {
            choice = hook(file)
        } else {
            // headless（測試、截圖）不顯示任何選單。
            guard !headless, let view, view.window != nil else { return }
            choice = popUpOpenMenu(file, in: view)
        }
        guard let choice else {
            focusCurrent()
            return
        }
        switch choice {
        case .preview:
            newPreviewTab(file, after: pane)
        case .defaultApp:
            // 選單第 1 列已經顯示真正的路徑，所以這裡不再比對 OSC 8 連結的文字。
            GhosttyRuntime.openTerminalURL(file.path, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN,
                                           window: view?.window ?? (window as NSWindow?))
            focusCurrent()
        case .finder:
            Self.revealInFinder(file)
            focusCurrent()
        case .copyPath:
            let pb = GhosttyRuntime.standardPasteboard
            pb.clearContents()
            pb.setString(file.path, forType: .string)
            focusCurrent()
        }
    }

    /// 開啟選單本身：第 1 列是完整路徑（不能點），接著是 `openMenuItems`（item 的 tag 是它在清單裡的位置）。
    static func makeOpenMenu(_ file: URL, target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: shortPath(file.path), action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.toolTip = file.path
        menu.addItem(header)
        menu.addItem(.separator())
        for (i, entry) in openMenuItems.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(OpenMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = i
            menu.addItem(item)
        }
        return menu
    }

    /// 在滑鼠位置顯示選單，等使用者選完才回來；回傳選到的項目，關掉選單回傳 nil。
    private func popUpOpenMenu(_ file: URL, in view: NSView) -> OpenChoice? {
        let target = OpenMenuTarget()
        let menu = Self.makeOpenMenu(file, target: target)
        let point = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        menu.popUp(positioning: nil, at: point, in: view)
        return target.picked.map { Self.openMenuItems[$0].choice }
    }

    /// 太長的路徑把資料夾的中間用 … 省略，檔名一定完整保留（完整路徑放在 tooltip）。
    static func shortPath(_ path: String, limit: Int = 90) -> String {
        guard path.count > limit else { return path }
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let room = max(10, limit - name.count - 2)
        guard dir.count > room else { return path }
        let head = room / 2
        return String(dir.prefix(head)) + "…" + String(dir.suffix(room - head)) + "/" + name
    }
}

/// 選單項目的 target：記下使用者選了哪一項（item 的 tag）。
private final class OpenMenuTarget: NSObject {
    var picked: Int?
    @objc func pick(_ item: NSMenuItem) { picked = item.tag }
}
```

- [ ] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: `[open-menu]` 的 20 行都是 `PASS`、沒有 `FAIL`、`APPTEST EXIT: 0`。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/LmuxUI/OpenMenu.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "feat(md-html-preview): ⌘-click 可預覽檔案時跳出開啟選單

選單：在新 tab 預覽、用預設 app 開、在 Finder 顯示、複製路徑；第 1 列是完整路徑。
其他路徑、網址、不存在的檔案照原本流程。

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 23: 讓 Ghostty 的 ⌘-click 走開啟選單

**Files:**
- Modify: `App/Sources/LmuxUI/Controller.swift`（`handleGhosttyAction`）
- Modify: `App/Sources/lmux-apptest/Preview.swift`

說明：`handleGhosttyAction` 是在 renderer 的鎖還拿著時被呼叫。一定要先把字串複製出來，到下一輪 run loop 再處理（`App/Sources/LmuxTerminal/GhosttyRuntime.swift:230-243` 也是延後處理）。這裡用 `RunLoop.main.perform`，不用 `DispatchQueue.main.async`：開啟選單會跑巢狀的 run loop，如果在 GCD 的 main block 裡跑，選單開著時其他 main queue 的工作（libghostty 的繪製）會全部停住。

- [ ] **Step 1: 加測試**

在 `App/Sources/lmux-apptest/Preview.swift` 的插入點註解**上面**加上：

```swift
    // MARK: Ghostty 的 OPEN_URL 走開啟選單（Task 23）
    // @feature: open-menu.feature
    // @scenario: ⌘-click 可預覽檔案的路徑跳出開啟選單
    do {
        r.section = "open-url-action"
        var asked: [URL] = []
        LmuxController.openMenuTestHook = { asked.append($0); return nil }
        defer { LmuxController.openMenuTestHook = nil }
        let ws = c.newWorkspace(cwd: fx.path)
        let a = ws.panes[0]
        a.cwd = fx.path
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        let handled: Bool? = "docs/design.md".withCString { ptr in
            action.action.open_url = ghostty_action_open_url_s(kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: ptr,
                                                               len: UInt(strlen(ptr)))
            return c.runtime.actionHandler?(ghostty_target_s(), action, a.surface)
        }
        r.check("Ghostty 的 OPEN_URL 由 lmux 處理", handled == true, "\(String(describing: handled))")
        r.check("Ghostty 的 OPEN_URL 跳出開啟選單", await waitFor(3) { asked == [design] }, "\(asked)")
    }

```

- [ ] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: `FAIL  [open-url-action] Ghostty 的 OPEN_URL 由 lmux 處理`。

- [ ] **Step 3: `handleGhosttyAction` 加上 OPEN_URL**

在 `App/Sources/LmuxUI/Controller.swift` 找到：

```swift
            guard pendingUndo != nil else { return false }
            onMain { _ = self.undoSend() }
            return true
        default:
            return nil
```

改成：

```swift
            guard pendingUndo != nil else { return false }
            onMain { _ = self.undoSend() }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // ⌘-click 的連結（beat: open-menu.feature）。這裡是在 renderer 的鎖還拿著時被呼叫：先複製字串，
            // 下一輪 run loop 再處理。用 RunLoop.perform 而不用 DispatchQueue.main.async：選單會跑巢狀的
            // run loop，在 GCD 的 main block 裡跑的話，選單開著時 libghostty 的繪製會停住。
            let v = action.action.open_url
            guard let ptr = v.url,
                  let str = String(data: Data(bytes: ptr, count: Int(v.len)), encoding: .utf8) else { return nil }
            let kind = v.kind
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.openTerminalLink(str, kind: kind, pane: pane, view: view) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            return true
        default:
            return nil
```

- [ ] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 沒有 `FAIL`、`APPTEST EXIT: 0`。

- [ ] **Step 5: 既有的連結測試不受影響**

Run: `beat/changes/md-html-preview/dev.sh apptest-quick; beat/changes/md-html-preview/dev.sh new-failures quick`
Expected: `NEW FAILURES: 0` 與 `MISSING CHECKS: 0`（`[parity]`、`[security]` 的連結檢查都還通過）。
不是 0：先重跑一次排除偶發失敗；還是不是 0 就**停止**，回報列出的項目。

- [ ] **Step 6: Commit**

```bash
git add App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "feat(md-html-preview): Ghostty 的 OPEN_URL 交給 openTerminalLink，可預覽檔案跳出開啟選單

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 24: 預覽換頁時標題跟著換；預覽裡點網址照終端機的規則

**Files:**
- Modify: `App/Sources/LmuxUI/Controller.swift`（`makePreviewPane`）
- Modify: `App/Sources/lmux-apptest/Preview.swift`

- [ ] **Step 1: 加測試**

在 `App/Sources/lmux-apptest/Preview.swift` 的插入點註解**上面**加上：

```swift
    // MARK: 預覽裡換頁與點網址（Task 24）
    // @feature: preview-tab.feature
    // @scenario: 點相對路徑的 .md 連結，在同一個預覽 tab 換頁
    // @scenario: 點網址連結，照終端機裡點連結的規則處理
    // @scenario: 預覽中的檔案被刪除
    do {
        r.section = "preview-links"
        let gone = docs.appendingPathComponent("gone.md")
        try? "# Gone\n".write(to: gone, atomically: true, encoding: .utf8)
        let (ws, _, p) = previewSetup(c, dir: fx, file: design)
        _ = await waitFor(5) { p.preview?.webView.isLoading == false }
        let count = ws.panes.count
        p.preview!.show(docs.appendingPathComponent("b.md"))
        r.check("預覽換頁後 tab 標題跟著換成 b.md", await waitFor(5) { p.headerTitle == "b.md" }, p.headerTitle)
        r.check("預覽換頁時沒有開出新的 tab", ws.panes.count == count, "\(ws.panes.count)")
        p.preview!.webView.goBack()
        r.check("返回上一頁後 tab 標題改回 design.md", await waitFor(5) { p.headerTitle == "design.md" }, p.headerTitle)
        opened.removeAll()
        p.preview!.openExternal?(URL(string: "https://example.com/y")!)
        r.check("預覽裡點網址：照終端機點連結的規則開啟", opened == [URL(string: "https://example.com/y")!], "\(opened)")
        p.preview!.show(gone)
        _ = await waitFor(5) { p.headerTitle == "gone.md" }
        try? FileManager.default.removeItem(at: gone)
        try? await Task.sleep(for: .milliseconds(800))
        r.check("檔案被刪除後，預覽 tab 仍然留著", ws.panes.contains { $0 === p })
    }

```

- [ ] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 有 `FAIL  [preview-links] 預覽換頁後 tab 標題跟著換成 b.md` 與 `FAIL  [preview-links] 預覽裡點網址：照終端機點連結的規則開啟`。

- [ ] **Step 3: `makePreviewPane` 接上兩個回呼**

在 `App/Sources/LmuxUI/Controller.swift` 的 `makePreviewPane` 裡找到：

```swift
        pane.branch = GitBranch.read(cwd: dir)
        panesByID[pane.id] = pane
        return pane
```

改成：

```swift
        pane.branch = GitBranch.read(cwd: dir)
        // 點連結換頁、返回上一頁：標題與目前目錄跟著換（目錄用既有的 paneDidChangeDirectory）。
        preview.onFileChange = { [weak self, weak pane] f in
            guard let self, let pane else { return }
            pane.title = f.lastPathComponent
            self.paneDidChangeDirectory(pane, f.deletingLastPathComponent().path)
            if let ws = pane.workspace, ws === self.model.selected {
                self.refreshHeaders(ws)
                self.root.updateHeader()
            }
        }
        // 預覽裡點網址：跟在終端機 ⌘-click 網址一樣。
        preview.openExternal = { [weak self] url in
            GhosttyRuntime.openTerminalURL(url.absoluteString, kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, window: self?.window)
        }
        panesByID[pane.id] = pane
        return pane
```

- [ ] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 沒有 `FAIL`、`APPTEST EXIT: 0`。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "feat(md-html-preview): 預覽換頁時 tab 標題跟著換；預覽裡點網址照終端機的規則開啟

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 25: 預覽 tab 上停用只對終端機有意義的選單項目

**Files:**
- Modify: `App/Sources/LmuxUI/SidebarSelection.swift`（`validateMenuItem`）
- Modify: `App/Sources/lmux-apptest/Preview.swift`

- [ ] **Step 1: 加測試**

在 `App/Sources/lmux-apptest/Preview.swift` 的插入點註解**上面**加上：

```swift
    // MARK: 預覽 tab 上的選單項目（Task 25）
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 上停用只對終端機有意義的功能
    do {
        r.section = "preview-menu"
        let (_, a, p) = previewSetup(c, dir: fx, file: design)
        func enabled(_ action: Selector) -> Bool {
            c.validateMenuItem(NSMenuItem(title: "x", action: action, keyEquivalent: ""))
        }
        c.focus(p)
        let off: [(String, Selector)] = [
            ("Find…", #selector(LmuxController.menuFind(_:))),
            ("Find Next", #selector(LmuxController.menuFindNext(_:))),
            ("Find Previous", #selector(LmuxController.menuFindPrevious(_:))),
            ("Undo Send", #selector(LmuxController.menuUndoSend(_:))),
            ("Copy Original Reply", #selector(LmuxController.menuCopyOriginal(_:))),
            ("Ghostty 的字級／Clear Screen", #selector(LmuxController.menuGhosttyBinding(_:))),
        ]
        for (name, sel) in off { r.check("預覽 tab 上停用 \(name)", !enabled(sel)) }
        r.check("預覽 tab 上 Close Pane 仍可用", enabled(#selector(LmuxController.menuClosePane(_:))))
        r.check("預覽 tab 上 Move Tab Right 仍可用", enabled(#selector(LmuxController.menuMoveTabRight(_:))))
        r.check("預覽 tab 上 Split Right 仍可用", enabled(#selector(LmuxController.menuSplitRight(_:))))
        c.focus(a)
        r.check("回到終端機 tab：Find… 可用", enabled(#selector(LmuxController.menuFind(_:))))
    }

```

- [ ] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 有 `FAIL  [preview-menu] 預覽 tab 上停用 Find…`（以及另外 5 個「停用」項目）。

- [ ] **Step 3: `validateMenuItem`**

在 `App/Sources/LmuxUI/SidebarSelection.swift` 找到這一行：

```swift
extension LmuxController: NSMenuItemValidation {
```

在它**下面**（下一行）加上：

```swift
    /// 只對終端機有意義的選單項目：預覽 tab 是 focused tab 時停用（beat: preview-tab.feature）。
    /// `menuGhosttyBinding` 是字級、Clear Screen 這類交給 Ghostty 的項目。
    static let terminalOnlyActions: [Selector] = [
        #selector(LmuxController.menuFind(_:)), #selector(LmuxController.menuFindNext(_:)),
        #selector(LmuxController.menuFindPrevious(_:)), #selector(LmuxController.menuUndoSend(_:)),
        #selector(LmuxController.menuCopyOriginal(_:)), #selector(LmuxController.menuGhosttyBinding(_:)),
    ]

```

再找到同一個函式的結尾：

```swift
        if item.action == #selector(menuToggleSplitZoom(_:)) { item.title = model.selected?.isZoomed == true ? "Unzoom Split" : "Zoom Split" }
        return true
    }
```

改成：

```swift
        if item.action == #selector(menuToggleSplitZoom(_:)) { item.title = model.selected?.isZoomed == true ? "Unzoom Split" : "Zoom Split" }
        if model.selected?.focusedPane?.preview != nil, let action = item.action, Self.terminalOnlyActions.contains(action) {
            return false
        }
        return true
    }
```

- [ ] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 沒有 `FAIL`、`APPTEST EXIT: 0`。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/LmuxUI/SidebarSelection.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "feat(md-html-preview): 預覽 tab 上停用 Find、Undo Send、Copy Original Reply、Ghostty 的字級與 Clear Screen

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 26: CLI：`lmux list` 不列出預覽 tab

**Files:**
- Modify: `App/Sources/LmuxUI/ControlServer.swift`
- Modify: `App/Sources/lmux-apptest/Preview.swift`

- [ ] **Step 1: 加測試**

在 `App/Sources/lmux-apptest/Preview.swift` 的插入點註解**上面**加上：

```swift
    // MARK: CLI（Task 26）
    // @feature: preview-tab.feature
    // @scenario: CLI 指定預覽 tab 時回傳錯誤
    do {
        r.section = "preview-cli"
        let (_, a, p) = previewSetup(c, dir: fx, file: design)
        r.check("lmux send 指定預覽 tab：回傳不是終端機", c.send(text: "x", toPane: p.id) == .notTerminal)
        let reply = c.handleControl(["cmd": "send", "pane": p.id, "text": "x"])
        r.check("CLI 的 send 錯誤訊息說明不是終端機", (reply["error"] as? String) == "not a terminal: \(p.id)", "\(reply)")
        let list = c.handleControl(["cmd": "list"])
        let ids = ((list["workspaces"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["panes"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["id"] as? String }
        r.check("lmux list 不列出預覽 tab，仍列出終端機 tab", !ids.contains(p.id) && ids.contains(a.id), "\(ids)")
    }

```

- [ ] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: `FAIL  [preview-cli] lmux list 不列出預覽 tab，仍列出終端機 tab`。前兩項（send）在 Task 9 已經做好，這裡是補測，應該是 PASS。

- [ ] **Step 3: `list` 跳過預覽 tab**

在 `App/Sources/LmuxUI/ControlServer.swift` 找到：

```swift
                 "panes": ws.panes.map { p in
```

改成：

```swift
                 "panes": ws.panes.filter { $0.surface != nil }.map { p in
```

- [ ] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 沒有 `FAIL`、`APPTEST EXIT: 0`。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/LmuxUI/ControlServer.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "feat(md-html-preview): lmux list 不列出預覽 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 27: 存檔時不存預覽 tab

**Files:**
- Modify: `App/Sources/LmuxUI/Persistence.swift`（`snapshotLayout`）
- Modify: `App/Sources/lmux-apptest/Preview.swift`

- [ ] **Step 1: 加測試**

在 `App/Sources/lmux-apptest/Preview.swift` 找到這兩行：

```swift
@MainActor
func runPreview() async -> Int32 {
```

在 `@MainActor` 那一行的**上面**加上（不要插在 `@MainActor` 與 `func runPreview` 之間）：

```swift
/// layout.json 一個節點底下所有 tab 的 id。
func layoutPaneIDs(_ n: LayoutFile.NodeState) -> [String] {
    if let children = n.children { return children.flatMap(layoutPaneIDs) }
    return n.leafPanes.map(\.id)
}

```

在插入點註解**上面**加上：

```swift
    // MARK: 存檔不存預覽 tab（Task 27）
    // @feature: preview-tab.feature
    // @scenario: 重開 lmux 不還原預覽 tab
    do {
        r.section = "preview-restore"
        let (ws, a, p) = previewSetup(c, dir: fx, file: design)
        let lone = c.newPreviewTab(docs.appendingPathComponent("b.md"), after: a)!
        c.moveTabToNewWorkspace(lone)
        let loneWS = lone.workspace!
        c.select(loneWS)  // 讓「只有預覽 tab 的 workspace」是選取中的 workspace
        let layout = c.snapshotLayout()
        let ids = layout.workspaces.first { $0.id == ws.id }.map { layoutPaneIDs($0.root) } ?? []
        r.check("存檔時不存預覽 tab，留下終端機 tab", !ids.contains(p.id) && ids.contains(a.id), "\(ids)")
        r.check("只有預覽 tab 的 workspace 不存", !layout.workspaces.contains { $0.id == loneWS.id })
        r.check("選取中的 workspace 沒存時，selected 改指向存下來的 workspace",
                layout.workspaces.contains { $0.id == layout.selected }, layout.selected ?? "nil")
    }

```

- [ ] **Step 2: 執行，確認失敗**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: `[preview-restore]` 有 `FAIL`。

- [ ] **Step 3: `snapshotLayout()` 的 `node` 函式**

在 `App/Sources/LmuxUI/Persistence.swift` 找到：

```swift
        func node(_ n: SplitNode) -> LayoutFile.NodeState {
            switch n.content {
            case .pane(let shown):
                guard n.hasTabs else { return .init(pane: state(shown)) }
                return .init(pane: state(shown), tabs: n.tabs.map(state), selectedTab: n.tabs.firstIndex { $0 === shown } ?? 0)
            case .split(let axis, let a, let b):
                return .init(axis: axis, ratio: Double(n.ratio), children: [node(a), node(b)])
            }
        }
```

改成：

```swift
        // 預覽 tab 不存（beat: preview-tab.feature）：格子只剩預覽 tab 就整格不存；分割只剩一邊就留下那一邊。
        func node(_ n: SplitNode) -> LayoutFile.NodeState? {
            switch n.content {
            case .pane(let shown):
                let tabs = n.tabs.filter { $0.surface != nil }
                guard !tabs.isEmpty else { return nil }
                guard tabs.count > 1 else { return .init(pane: state(tabs[0])) }
                let kept = tabs.contains { $0 === shown } ? shown : tabs[0]
                return .init(pane: state(kept), tabs: tabs.map(state), selectedTab: tabs.firstIndex { $0 === kept } ?? 0)
            case .split(let axis, let a, let b):
                let na = node(a)
                let nb = node(b)
                guard let na else { return nb }
                guard let nb else { return na }
                return .init(axis: axis, ratio: Double(n.ratio), children: [na, nb])
            }
        }
```

- [ ] **Step 4: `snapshotLayout()` 的 workspace 清單**

找到：

```swift
        f.workspaces = model.workspaces.map {
            .init(id: $0.id, customTitle: $0.customTitle, accent: $0.accent,
                  focusedPane: $0.focusedPane?.id, zoomedPane: $0.zoomedPane?.id, root: node($0.root))
        }
        f.selected = model.selectedID
```

改成：

```swift
        f.workspaces = model.workspaces.compactMap { ws -> LayoutFile.WorkspaceState? in
            guard let root = node(ws.root) else { return nil }  // 只有預覽 tab 的 workspace 不存
            let focused = ws.focusedPane?.surface != nil ? ws.focusedPane?.id : nil
            let zoomed = ws.zoomedPane?.surface != nil ? ws.zoomedPane?.id : nil
            return .init(id: ws.id, customTitle: ws.customTitle, accent: ws.accent,
                         focusedPane: focused, zoomedPane: zoomed, root: root)
        }
        f.selected = f.workspaces.contains { $0.id == model.selectedID } ? model.selectedID : f.workspaces.first?.id
```

- [ ] **Step 5: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 沒有 `FAIL`、`APPTEST EXIT: 0`。

- [ ] **Step 6: 既有的存檔與還原測試不受影響（很久，見「跑很久的指令」）**

Run: `beat/changes/md-html-preview/dev.sh apptest-full; beat/changes/md-html-preview/dev.sh new-failures full`
Expected: `NEW FAILURES: 0` 與 `MISSING CHECKS: 0`（`[restore]` 等還原檢查只在 full 裡跑）。
不是 0：先重跑一次排除偶發失敗；還是不是 0 就**停止**，回報列出的項目。

- [ ] **Step 7: Commit**

```bash
git add App/Sources/LmuxUI/Persistence.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "feat(md-html-preview): 存檔時不存預覽 tab；只有預覽 tab 的 workspace 也不存

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 28: 預覽 tab 的移動、分割、關閉、開新 tab；關閉時釋放預覽

**Files:**
- Modify: `App/Sources/LmuxUI/Controller.swift`（`discard`）
- Modify: `App/Sources/lmux-apptest/Preview.swift`

說明：前面的重構應該已經讓移動、分割、開新 tab 對預覽 tab 也成立；這個 task 只為它們加測試，失敗時**不要改正式程式**，停下來回報。唯一要改的程式是關閉時呼叫 `PreviewView.close()`（Step 3）。

- [ ] **Step 1: 加測試**

在插入點註解**上面**加上：

```swift
    // MARK: 移動、分割、關閉、開新 tab（Task 28）
    // @feature: preview-tab.feature
    // @scenario: 預覽 tab 可以像終端機 tab 一樣移動、分割與關閉
    // @scenario: 在預覽 tab 上開新 tab，新的終端機從檔案所在資料夾開始
    do {
        r.section = "preview-move"
        let (ws, a, p) = previewSetup(c, dir: fx, file: design)
        let fileBefore = p.preview!.fileURL
        c.moveTab(p, splitting: a, .right)
        r.check("預覽 tab 拖到右側分割後與 A 並排", ws.isSplit && ws.visiblePanes.contains { $0 === p } && ws.visiblePanes.contains { $0 === a })
        r.check("移動後仍顯示原本的檔案", p.preview!.fileURL == fileBefore)
        c.focus(p)
        let t = c.newTab(p)
        r.check("在預覽 tab 上開新 tab：新的終端機從檔案所在資料夾開始",
                t?.surface != nil && t?.cwd == docs.standardizedFileURL.path, "\(t?.cwd ?? "nil")")
        if let t { c.closePane(t) }
        c.closePane(p)
        r.check("關閉預覽 tab 後它消失", !ws.panes.contains { $0 === p })
        r.check("關閉預覽 tab 後 A 成為 focused tab", ws.focusedPane === a)
        r.check("關閉預覽 tab 時釋放它的預覽（停止監看與載入）", p.preview?.isClosed == true)
    }

```

- [ ] **Step 2: 執行，確認只有「釋放」那一項失敗**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: `[preview-move]` 只有一個 `FAIL`：`關閉預覽 tab 時釋放它的預覽（停止監看與載入）`。其他項目有 `FAIL`：停止，回報那幾行，不要改正式程式。

- [ ] **Step 3: `discard(_:)` 關閉預覽**

在 `App/Sources/LmuxUI/Controller.swift` 找到（Task 8 改過的）：

```swift
        pane.view.removeFromSuperview()
        pane.surface?.close()
```

改成：

```swift
        pane.view.removeFromSuperview()
        pane.surface?.close()
        pane.preview?.close()
```

- [ ] **Step 4: 執行，確認通過**

Run: `beat/changes/md-html-preview/dev.sh apptest-preview`
Expected: 沒有 `FAIL`、`APPTEST EXIT: 0`。

- [ ] **Step 5: Commit**

```bash
git add App/Sources/LmuxUI/Controller.swift App/Sources/lmux-apptest/Preview.swift
git commit -m "feat(md-html-preview): 關閉預覽 tab 時停止監看與載入；測試移動、分割、關閉、開新 tab

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

---

### Task 29: 完整回歸、標註 @covered-by、手動驗證清單

**Files:**
- Modify: `beat/changes/md-html-preview/features/open-menu.feature`、`beat/changes/md-html-preview/features/preview-tab.feature`
- Create: `beat/changes/md-html-preview/manual-verification.md`

- [ ] **Step 1: 完整回歸**

Run: `beat/changes/md-html-preview/dev.sh build && beat/changes/md-html-preview/dev.sh check && beat/changes/md-html-preview/dev.sh webkit | tail -1`
Expected: `BUILD EXIT: 0`、`preview check: ok`、`WEBKIT CHECK: ok`。

Run（很久，見「跑很久的指令」）: `beat/changes/md-html-preview/dev.sh apptest-full; beat/changes/md-html-preview/dev.sh new-failures full`
Expected: `NEW FAILURES: 0` 與 `MISSING CHECKS: 0`。不是 0：先重跑一次；還是不是 0 就停止回報。

- [ ] **Step 2: 在 feature 檔加上 `# @covered-by:`**

格式：在場景的 tag 行與 `場景:`／`場景大綱:` 行之間，加一行註解。依下表加（場景名稱要一字不差）：

| feature | 場景 | 加的那一行 |
|---|---|---|
| open-menu | ⌘-click 可預覽檔案的路徑跳出開啟選單 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（open-menu、open-url-action）` |
| open-menu | 路徑後面帶行號時，去掉行號再判斷 | `  # @covered-by: App/scripts/preview-check.swift、App/Sources/lmux-apptest/Preview.swift（open-menu）` |
| open-menu | OSC 8 連結指向本機的可預覽檔案時也跳出開啟選單 | `  # @covered-by: App/scripts/preview-check.swift、App/Sources/lmux-apptest/Preview.swift（open-menu）` |
| open-menu | 不是存在的可預覽檔案時，照原本流程 | `  # @covered-by: App/scripts/preview-check.swift、App/Sources/lmux-apptest/Preview.swift（open-menu）` |
| open-menu | shell 沒回報目前目錄時，相對路徑照原本流程 | `  # @covered-by: App/scripts/preview-check.swift、App/Sources/lmux-apptest/Preview.swift（open-menu）` |
| open-menu | 選「在新 tab 預覽」開出預覽 tab | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（preview-tab、open-menu）` |
| open-menu | 選單的其他項目 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（open-menu）` |
| open-menu | 不選任何項目就關掉選單 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（open-menu）` |
| preview-tab | Markdown 顯示成排版後的樣子 | `  # @covered-by: App/scripts/preview-check.swift、App/scripts/preview-webkit-check.swift` |
| preview-tab | callout 顯示成提示框 | `  # @covered-by: App/scripts/preview-check.swift` |
| preview-tab | 程式碼區塊不上色，mermaid 區塊顯示成一般程式碼區塊 | `  # @covered-by: App/scripts/preview-check.swift` |
| preview-tab | Markdown 裡的 HTML 標籤顯示成文字，不執行 | `  # @covered-by: App/scripts/preview-check.swift、App/scripts/preview-webkit-check.swift` |
| preview-tab | Markdown 用相對路徑引用的圖片顯示出來 | `  # @covered-by: App/scripts/preview-webkit-check.swift` |
| preview-tab | Markdown 預覽跟著 lmux 的外觀設定切換深淺色 | `  # @covered-by: manual — beat/changes/md-html-preview/manual-verification.md` |
| preview-tab | HTML 從網路載入的 script 正常執行 | `  # @covered-by: manual — beat/changes/md-html-preview/manual-verification.md` |
| preview-tab | HTML 讀得到同資料夾的 CSS 與圖片 | `  # @covered-by: App/scripts/preview-webkit-check.swift` |
| preview-tab | 重新開啟預覽時，不保留上一次的 cookie 與 storage | `  # @covered-by: App/scripts/preview-webkit-check.swift` |
| preview-tab | 檔案內容改變後，預覽自動更新 | `  # @covered-by: App/scripts/preview-webkit-check.swift` |
| preview-tab | 以「寫暫存檔再改名」方式存檔，預覽也會更新 | `  # @covered-by: App/scripts/preview-webkit-check.swift` |
| preview-tab | 預覽中的檔案被刪除 | `  # @covered-by: App/scripts/preview-webkit-check.swift` |
| preview-tab | 點相對路徑的 .md 連結，在同一個預覽 tab 換頁 | `  # @covered-by: App/scripts/preview-webkit-check.swift、App/Sources/lmux-apptest/Preview.swift（preview-links）` |
| preview-tab | 點網址連結，照終端機裡點連結的規則處理 | `  # @covered-by: App/scripts/preview-webkit-check.swift（含 script 自己點、meta refresh）、App/Sources/lmux-apptest/Preview.swift（preview-links）` |
| preview-tab | 預覽 tab 的標題是檔名 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（preview-tab）` |
| preview-tab | 預覽 tab 可以像終端機 tab 一樣移動、分割與關閉 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（preview-move）` |
| preview-tab | 在預覽 tab 上開新 tab，新的終端機從檔案所在資料夾開始 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（preview-move）` |
| preview-tab | 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（preview-focus）；⌘C 見 manual-verification.md` |
| preview-tab | 預覽 tab 上停用只對終端機有意義的功能 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（preview-menu、preview-focus）；Rewind 按鈕見 manual-verification.md` |
| preview-tab | CLI 指定預覽 tab 時回傳錯誤 | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（preview-cli）` |
| preview-tab | 重開 lmux 不還原預覽 tab | `  # @covered-by: App/Sources/lmux-apptest/Preview.swift（preview-restore，只驗存檔內容）；實際重開見 manual-verification.md` |


確認：`grep -c '@covered-by' beat/changes/md-html-preview/features/*.feature`
Expected（兩行）：`beat/changes/md-html-preview/features/open-menu.feature:8`、`beat/changes/md-html-preview/features/preview-tab.feature:21`。

- [ ] **Step 3: 建立 `beat/changes/md-html-preview/manual-verification.md`（整份照抄）**

```markdown
# 手動驗證：md-html-preview

自動測試涵蓋不到、要使用者在真的 lmux 視窗裡確認的項目。每項做完填「結果」。

先 build：`App/scripts/bundle.sh`（或照 memory 的 lmux-local-build-and-test-pitfalls 做法），開啟新的 lmux.app。

| # | 對應場景 | 步驟 | 預期 | 結果 |
|---|---|---|---|---|
| 1 | ⌘-click 可預覽檔案的路徑跳出開啟選單 | 在終端機 `cd` 到這個 repo，`echo beat/changes/md-html-preview/design.md`，按住 ⌘ 點那段文字 | 選單出現在滑鼠旁，第 1 列是完整路徑（灰色），下面 4 項 | |
| 2 | 選「在新 tab 預覽」開出預覽 tab | 選「在新 tab 預覽」 | 目前 tab 右邊多一個 tab，標題 `design.md`，內容是排版後的 Markdown | |
| 3 | 不選任何項目就關掉選單 | 再 ⌘-click 一次，按 Esc | 選單關閉，可以直接在終端機打字 | |
| 4 | Markdown 預覽跟著 lmux 的外觀設定切換深淺色 | Settings 把外觀改成 Dark，再改成 Light | 預覽的背景跟著變，不用重開 | |
| 5 | HTML 從網路載入的 script 正常執行 | ⌘-click `~/.obsidian/jamis/摘要報告/20261013_AI_Articles_Summary_recycled_paper.html` → 在新 tab 預覽，點一篇文章 | 文章內容顯示出來（靠 CDN 的 marked.js） | |
| 6 | 點相對路徑的 .md 連結，在同一個預覽 tab 換頁 | 在預覽裡點一個 `.md` 連結，再用觸控板兩指往右滑 | 同一個 tab 換頁、標題跟著換；滑動後回到上一頁 | |
| 7 | 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上 | 在預覽裡選一段文字按 ⌘C，貼到終端機 | 貼上的是選取的文字 | |
| 8 | 檔案內容改變後，預覽自動更新 | 預覽開著時，請 Claude 改那個 .md | 預覽自動顯示新內容 | |
| 9 | （design.md 的 spike S4） | 請 Claude 在回覆裡提到一個 .md 檔路徑，⌘-click 它 | 記錄：選單有沒有出現；路徑是純文字還是 OSC 8 連結（hover 時底部會顯示網址） | |
| 10 | （記憶體，未實測項目） | 開 3 個預覽 tab，看「活動監視器」的 lmux 與 WebKit 程序 | 記錄數字即可 | |
| 11 | Markdown 預覽跟著 lmux 的外觀設定切換深淺色 | Settings 外觀設成 System，再切換 macOS 的深淺色 | 預覽跟著 macOS 變 | |
| 12 | （design 未實測：Markdown 裡的網路圖片） | 預覽一個含 `![](https://…png)` 的 .md | 記錄：圖片有沒有顯示 | |
| 13 | 重開 lmux 不還原預覽 tab | 開一個預覽 tab，結束 lmux 再開 | 終端機 tab 都回來，預覽 tab 沒有回來 | |
| 14 | 預覽 tab 是 focused tab 時，鍵盤操作作用在預覽上 | 在預覽 tab 上打字 `ls` 按 Enter | 終端機沒有收到 `ls` | |
| 15 | 預覽 tab 上停用只對終端機有意義的功能 | 在預覽 tab 上把滑鼠移過內容 | 沒有出現 Rewind（訊息動作）按鈕 | |
| 16 | （review 發現：預覽 tab 上的確認卡片） | 讓預覽 tab 是 focused tab，按 ⇧⌘W（Close Workspace），再按 Enter | 卡片被確認（workspace 關閉）；重做一次改按 Esc，卡片取消 | |
| 17 | （已知限制） | 預覽 tab 是 focused tab 時，按 Ghostty 的分割方向鍵（例如 ⌘⌥→） | 記錄：沒有反應是已知限制；⌘[、⌘] 仍可切換 pane | |
```

- [ ] **Step 4: Commit**

```bash
git add beat/changes/md-html-preview/features/open-menu.feature beat/changes/md-html-preview/features/preview-tab.feature beat/changes/md-html-preview/manual-verification.md
git commit -m "test(md-html-preview): 標註 @covered-by，新增手動驗證清單

Co-Authored-By: Gemini 3.8 Flash <noreply@google.com>"
```

- [ ] **Step 5: 回報**

回報下面幾項。不要 push。
- 每個 task 的 commit：`git log --oneline main..HEAD`
- Task 0 的基準 FAIL 數：`grep -c '^FAIL' "${TMPDIR:-/tmp}/md-html-preview/baseline-full.log"`
- Task 19、29 的 `NEW FAILURES` 與 `MISSING CHECKS`
- 遇到但沒有改的地方
