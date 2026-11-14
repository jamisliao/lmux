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
