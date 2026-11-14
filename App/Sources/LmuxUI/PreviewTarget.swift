import Foundation

/// 終端機裡 ⌘-click 的連結指向的檔案，是預覽 tab 能顯示的檔案時才有值（beat: open-menu.feature）。
enum PreviewTarget {
    /// 可預覽檔案的副檔名（小寫）。
    static let extensions: Set<String> = ["md", "markdown", "html", "htm"]

    private static let lineSuffixRE = try? NSRegularExpression(pattern: #":\d+(:\d+)?$"#)

    static func isUnsafeScalar(_ u: Unicode.Scalar) -> Bool {
        u.properties.generalCategory == .control
            || (u.properties.generalCategory == .format && u.value != 0x200D) // 保留 U+200D (ZWJ) 支援複合 emoji 檔名
            || (0x2028...0x2029).contains(u.value)
            || u.value == 0x3164
    }

    static func hasUnsafeScalar(_ s: String) -> Bool {
        s.unicodeScalars.contains(where: isUnsafeScalar)
    }

    static func replacingUnsafeScalars(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars where !isUnsafeScalar(u) { scalars.append(u) }
        return String(scalars)
    }

    /// 拿掉 macOS 的 `/private` 前綴（`/var`、`/tmp` 皆為指向 `/private/...` 的 symlink）。
    static func canonicalPath(_ p: String) -> String {
        p.hasPrefix("/private/") ? String(p.dropFirst("/private".count)) : p
    }

    /// 解析 symlink；若目標檔案尚不存在，往上找到最深的存在祖先目錄解開 symlink 後再接回尾端路徑。
    static func resolvingPath(_ url: URL, fileManager: FileManager = .default) -> URL {
        let standardized = url.standardizedFileURL
        if fileManager.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath()
        }
        var missing: [String] = []
        var cur = standardized
        while cur.path != "/", !fileManager.fileExists(atPath: cur.path) {
            missing.append(cur.lastPathComponent)
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        var resolved = cur.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved
    }

    /// 若 `url` 或其任一祖先目錄經過 symlink，回傳 `resolved`；否則維持原本正規化路徑。
    static func resolvingSymlinksAnywhere(_ url: URL, resolved: URL) -> URL {
        let standardized = url.standardizedFileURL
        return canonicalPath(standardized.path) != canonicalPath(resolved.path) ? resolved : standardized
    }

    /// `file://` 網址的 host 是否指向本機（空值、`localhost`、或本機 hostname，容許 `.local` 差異）。
    static func isLocalFileHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty, h != "localhost" else { return true }
        let local = ProcessInfo.processInfo.hostName.lowercased()
        if h == local { return true }
        func stripLocal(_ s: String) -> String { s.hasSuffix(".local") ? String(s.dropLast(6)) : s }
        let bareLocal = stripLocal(local)
        return !bareLocal.isEmpty && stripLocal(h) == bareLocal
    }

    private static let nonFileSchemes = ["mailto:", "tel:", "sms:", "facetime:", "data:", "javascript:"]

    /// Ghostty 交來的 `value`（絕對路徑、相對於 shell 目前目錄的路徑、`~/…`、或 `file://` 網址），
    /// 去掉結尾的 `:行號` 或 `:行號:欄號`。指向存在的可預覽檔案才回傳，否則 nil。
    /// `cwd`：這個 tab 的目前目錄，用來補相對路徑。
    static func resolve(_ value: String, cwd: String?, fileManager: FileManager = .default) -> URL? {
        // 看不見的控制／隔離／排版字元（例如 U+202E、U+2028/2029、U+3164）：不預覽，走原本流程（UntrustedURL 會擋）。
        if hasUnsafeScalar(value) {
            return nil
        }
        var path = value
        let lowered = path.lowercased()
        if lowered.hasPrefix("file://") {
            // 只接受本機的 file://（沒有 host、`localhost`、或本機 hostname；拒絕 port）。
            guard let u = URL(string: path), u.isFileURL,
                  u.port == nil, isLocalFileHost(u.host),
                  !hasUnsafeScalar(u.path) else { return nil }
            path = u.path
        } else if path.contains("://") || nonFileSchemes.contains(where: { lowered.hasPrefix($0) }) {
            return nil
        }
        path = stripLineSuffix(path)
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        guard !hasUnsafeScalar(path) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !hasUnsafeScalar(url.path) else { return nil }
        guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
        // 只預覽一般檔案，且 symlink 目標的真實副檔名與路徑字元也必須符合規定。
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let canonical = url.resolvingSymlinksInPath()
        guard !hasUnsafeScalar(canonical.path),
              extensions.contains(canonical.pathExtension.lowercased()),
              let values = try? canonical.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return resolvingSymlinksAnywhere(url, resolved: canonical)
    }

    /// `a.md:12` → `a.md`，`a.md:12:5` → `a.md`；其他不變。
    static func stripLineSuffix(_ s: String) -> String {
        guard let re = lineSuffixRE else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                           withTemplate: "")
    }

    /// Markdown（由 `MarkdownHTML` 轉成 HTML），不是 HTML（直接載入）。
    static func isMarkdown(_ url: URL) -> Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }

    /// HTML 檔案（由 WebView 直接載入）。
    static func isHTML(_ url: URL) -> Bool { ["html", "htm"].contains(url.pathExtension.lowercased()) }
}
