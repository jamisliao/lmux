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
