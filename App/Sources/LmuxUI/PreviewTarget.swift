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
