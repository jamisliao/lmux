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
        let badCwd = docs.appendingPathComponent("bad\u{202E}dir/sub", isDirectory: true)
        try? FileManager.default.createDirectory(at: badCwd, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: badCwd.appendingPathComponent("nested.md"))
        for name in ["design.md", "page.html", "notes.txt", "UPPER.MD", "a\u{202E}b.md", "u\u{2028}v.md", "u\u{2029}w.md", "u\u{3164}z.md"] {
            FileManager.default.createFile(atPath: docs.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("zero.md"),
                                                    withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("alias-txt.md"),
                                                    withDestinationURL: docs.appendingPathComponent("notes.txt"))
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("alias-bidi.md"),
                                                    withDestinationURL: docs.appendingPathComponent("a\u{202E}b.md"))
        try? FileManager.default.createSymbolicLink(at: docs.appendingPathComponent("alias-md.md"),
                                                    withDestinationURL: docs.appendingPathComponent("design.md"))
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

        // 安全：控制／隔離／排版字元（U+202E、U+2028、U+2029、U+3164，含 file:// 與 cwd）、遠端主機 file://、指向 /dev/zero 的 symlink 都不預覽
        expect(PreviewTarget.resolve("docs/a\u{202E}b.md", cwd: rootPath) == nil, "含 U+202E 的路徑（檔案存在）")
        expect(PreviewTarget.resolve("docs/u\u{2028}v.md", cwd: rootPath) == nil, "含 U+2028 的路徑（檔案存在）")
        expect(PreviewTarget.resolve("docs/u\u{2029}w.md", cwd: rootPath) == nil, "含 U+2029 的路徑（檔案存在）")
        expect(PreviewTarget.resolve("docs/u\u{3164}z.md", cwd: rootPath) == nil, "含 U+3164 的路徑（檔案存在）")
        expect(PreviewTarget.resolve("sub/nested.md", cwd: docs.appendingPathComponent("bad\u{202E}dir").path) == nil, "cwd 含 U+202E 的相對路徑")
        expect(PreviewTarget.resolve("../design.md", cwd: docs.appendingPathComponent("bad\u{202E}dir").path) == nil, "cwd 含 U+202E 即便經 .. 正規化仍擋")
        let bidiFileURL = "file://" + docs.standardizedFileURL.path + "/a%E2%80%AEb.md"
        expect(PreviewTarget.resolve(bidiFileURL, cwd: nil) == nil, "percent-encoded U+202E 的 file:// 連結")
        let lineSepFileURL = "file://" + docs.standardizedFileURL.path + "/u%E2%80%A8v.md"
        expect(PreviewTarget.resolve(lineSepFileURL, cwd: nil) == nil, "percent-encoded U+2028 的 file:// 連結")
        let hangulFileURL = "file://" + docs.standardizedFileURL.path + "/u%E3%85%A4z.md"
        expect(PreviewTarget.resolve(hangulFileURL, cwd: nil) == nil, "percent-encoded U+3164 的 file:// 連結")
        expect(PreviewTarget.resolve("file://remotehost" + design, cwd: nil) == nil, "遠端主機的 file://")
        expect(PreviewTarget.resolve("file://localhost" + design, cwd: nil)?.path == design, "localhost 的 file://")
        let localHost = ProcessInfo.processInfo.hostName
        expect(PreviewTarget.resolve("file://\(localHost)" + design, cwd: nil)?.path == design, "本機 hostName 的 file://")
        let bareHost = localHost.lowercased().hasSuffix(".local") ? String(localHost.dropLast(6)) : localHost + ".local"
        expect(PreviewTarget.resolve("file://\(bareHost)" + design, cwd: nil)?.path == design, "本機 host (.local 差異) 的 file://")
        expect(PreviewTarget.resolve("file://evil.local" + design, cwd: nil) == nil, "不同 .local 主機仍拒收")
        expect(PreviewTarget.resolve("tel:12345", cwd: rootPath) == nil, "tel: URI 不當作相對路徑")
        expect(PreviewTarget.resolve("docs/zero.md", cwd: rootPath) == nil, "指向 /dev/zero 的 symlink")
        expect(PreviewTarget.resolve("docs/alias-txt.md", cwd: rootPath) == nil, "指向非預覽檔（.txt）的 .md symlink")
        expect(PreviewTarget.resolve("docs/alias-bidi.md", cwd: rootPath) == nil, "指向含 U+202E 檔案的 .md symlink")
        expect(PreviewTarget.resolve("docs/alias-md.md", cwd: rootPath)?.path == URL(fileURLWithPath: design).resolvingSymlinksInPath().path,
               "合法 .md symlink 回傳 canonical 真實路徑")
        let symDir = root.appendingPathComponent("symdocs")
        try? FileManager.default.createSymbolicLink(at: symDir, withDestinationURL: docs)
        expect(PreviewTarget.resolve("symdocs/design.md", cwd: rootPath)?.path == URL(fileURLWithPath: design).resolvingSymlinksInPath().path,
               "父目錄為 symlink 時回傳 canonical 真實路徑")
        let emojiFile = docs.appendingPathComponent("👨\u{200D}👩\u{200D}👧.md")
        FileManager.default.createFile(atPath: emojiFile.path, contents: Data("x".utf8))
        expect(PreviewTarget.resolve("docs/👨\u{200D}👩\u{200D}👧.md", cwd: rootPath) != nil, "含 ZWJ 的 emoji 檔名可解析")
        expect(PreviewTarget.hasUnsafeScalar("a\u{200B}b.md"), "U+200B 仍判定為不安全字元")

        expect(PreviewTarget.isMarkdown(URL(fileURLWithPath: design)), "isMarkdown .md")
        expect(!PreviewTarget.isMarkdown(docs.appendingPathComponent("page.html")), "isMarkdown .html")
        expect(PreviewTarget.isHTML(docs.appendingPathComponent("page.html")), "isHTML .html")
        expect(!PreviewTarget.isHTML(URL(fileURLWithPath: design)), "isHTML .md")

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
        expect(doc.contains("<h1 id=\"標題\">標題</h1>"), "標題：\(doc)")
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

        // 空的表格格子不讓欄位錯位（含表頭尾端空格）
        let empty = html("| a | b | c |\n|---|---|---|\n|  | 2 |  |\n")
        expect(empty.contains("<tr><td></td><td>2</td><td></td></tr>"), "空格子：\(empty)")
        let emptyHead = html("| a |  |\n|---|---|\n| 1 | 2 |\n")
        expect(emptyHead.contains("<thead><tr><th>a</th><th></th></tr></thead>"), "空表頭格子：\(emptyHead)")

        // 行內格式、連結、圖片
        let inline = html("**粗** *斜* `碼` ~~刪~~ [下一篇](b.md) ![圖](img/flow.png)")
        expect(inline.contains("<strong>粗</strong>"), "粗體：\(inline)")
        expect(inline.contains("<em>斜</em>"), "斜體：\(inline)")
        expect(inline.contains("<code>碼</code>"), "行內程式碼：\(inline)")
        expect(inline.contains("<del>刪</del>"), "刪除線：\(inline)")
        expect(inline.contains("<a href=\"b.md\">下一篇</a>"), "相對連結：\(inline)")
        expect(inline.contains("<img src=\"img/flow.png\" alt=\"圖\">"), "圖片：\(inline)")
        expect(!html("[x](javascript:alert(1))").contains("javascript"), "javascript: 連結被拿掉")
        expect(!html("[x](data:text/html,hi)").contains("href="), "data: 連結被拿掉")
        expect(!html("![x](javascript:alert(1))").contains("<img"), "javascript: 圖片被拿掉")
        expect(html("![x](https://example.com/a.png)").contains("<img src=\"https://example.com/a.png\" alt=\"x\">"), "https: 圖片保留")
        expect(html("![x](data:image/png;base64,iVBORw0KGgo=)").contains("<img src=\"data:image/png;base64,iVBORw0KGgo=\" alt=\"x\">"),
               "點陣圖 data: URL 圖片保留")
        expect(!html("![x](data:image/svg+xml;base64,PHN2Zy8+)").contains("<img"), "SVG data: URL 圖片被拿掉")
        expect(!html("![x](data:text/html,%3Cscript%3E)").contains("<img"), "text/html data: URL 圖片被拿掉")
        expect(html("[loc](file:///tmp/a.html#s1)").contains("<a href=\"lmux-preview:///tmp/a.html#s1\">loc</a>"),
               "本機 file:// 連結改寫成 lmux-preview://（保留錨點）")
        expect(!html("[rem](file://remotehost/tmp/a.html)").contains("href="), "遠端主機 file:// 連結被拿掉")
        expect(html("![pic](file:///tmp/a.png)").contains("<img src=\"lmux-preview:///tmp/a.png\" alt=\"pic\">"),
               "本機 file:// 圖片改寫成 lmux-preview://")

        // @scenario: callout 顯示成提示框
        let note = html("> [!NOTE]\n> 內文")
        expect(note.contains("<blockquote class=\"callout callout-note\"><p class=\"callout-title\">Note</p>"), "NOTE：\(note)")
        expect(note.contains("內文") && !note.contains("[!"), "NOTE 內文：\(note)")
        let warn = html("> [!warning] 小心\n> 第二行")
        expect(warn.contains("<blockquote class=\"callout callout-warning\"><p class=\"callout-title\">小心</p>"), "warning：\(warn)")
        expect(warn.contains("第二行") && !warn.contains("[!"), "warning 內文：\(warn)")
        let styledCallout = html("> [!warning] **重要**\n> 內容")
        expect(styledCallout.contains("<blockquote class=\"callout callout-warning\"><p class=\"callout-title\"><strong>重要</strong></p>"),
               "含行內格式的 callout 標題：\(styledCallout)")
        let hardBreakEmptyTitle = html("> [!NOTE]  \n> 內文")
        expect(hardBreakEmptyTitle.contains("<blockquote class=\"callout callout-note\"><p class=\"callout-title\">Note</p><p>內文</p>"),
               "callout 標題後接硬換行（預設標題）：\(hardBreakEmptyTitle)")
        let hardBreakTitled = html("> [!warning] 小心  \n> 第一行\n> 第二行")
        expect(hardBreakTitled.contains("<blockquote class=\"callout callout-warning\"><p class=\"callout-title\">小心</p><p>第一行"),
               "callout 標題後接硬換行（自訂標題不吞內文）：\(hardBreakTitled)")
        let other = html("> [!todo] 待辦")
        expect(other.contains("callout callout-note") && other.contains(">待辦</p>"), "不認得的類型用 note：\(other)")
        let splitCallout = html("> [!NOTE] 標題\n>\n> 內文")
        expect(splitCallout.contains("<p class=\"callout-title\">標題</p><p>內文</p>") && !splitCallout.contains("<p></p>"),
               "callout 單行標題接獨立段落不產生空 <p></p>：\(splitCallout)")
        let emptyHeadPara = html("> [!NOTE]\n>\n> 第二段")
        expect(emptyHeadPara.contains("<p class=\"callout-title\">Note</p><p>第二段</p>") && !emptyHeadPara.contains("<p></p>"),
               "callout 無標題接獨立段落不產生空 <p></p>：\(emptyHeadPara)")
        final class CustomFM: FileManager {}
        expect(PreviewTarget.resolvingPath(symDir.appendingPathComponent("design.md"), fileManager: CustomFM()).resolvingSymlinksInPath().path
               == URL(fileURLWithPath: design).resolvingSymlinksInPath().path,
               "resolvingPath 使用傳入的 fileManager")

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

        let headingsHTML = MarkdownHTML.body("# Hello World\n\n## Hello `World`\n\n### 中文 標題\n\n[跳](#hello-world)\n")
        expect(headingsHTML.contains("<h1 id=\"hello-world\">Hello World</h1>")
               && headingsHTML.contains("<h2 id=\"hello-world-1\">Hello <code>World</code></h2>")
               && headingsHTML.contains("<h3 id=\"中文-標題\">中文 標題</h3>")
               && headingsHTML.contains("<a href=\"#hello-world\">"),
               "S8 headings: \(headingsHTML)")

        print("preview check: ok")
    }
}
