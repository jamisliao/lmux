import Foundation

/// 預覽 tab 的 Markdown 轉 HTML（beat: preview-tab.feature）。只用 Foundation 內建的解析器，不加依賴。
/// 所有文字都跳脫：Markdown 裡寫的 HTML 一律顯示成文字，不執行。
enum MarkdownHTML {
    private static let calloutRE = try? NSRegularExpression(
        pattern: #"<blockquote>(<p>)?\[!([A-Za-z]+)\][+-]?[ \t]*([^\n]*?)(?:\n|<br>|(?=</p>))"#,
        options: [])

    private static func shellPage(title: String?, bodyHTML: String, csp pageCSP: String = csp) -> String {
        let titleTag = title.map { "<title>\(escape($0))</title>" } ?? ""
        return "<!doctype html><html><head><meta charset=\"utf-8\">" + pageCSP
            + "<meta name=\"color-scheme\" content=\"light dark\">"
            + titleTag + "<style>\(css)</style></head>"
            + "<body><article>\(bodyHTML)</article></body></html>"
    }

    /// 整頁：`<head>` 放樣式表，`<body>` 放轉好的 Markdown。
    static func page(_ markdown: String, title: String) -> String {
        shellPage(title: title, bodyHTML: body(markdown))
    }

    /// 純文字檔的整頁（beat: plain-text-preview.feature）：內容全部跳脫，放進等寬字型、會自動換行的 `<pre>`。
    /// 用比 Markdown 更嚴的 CSP：純文字頁用不到圖片，連圖片都不載入。
    static func textPage(_ text: String, title: String) -> String {
        shellPage(title: title, bodyHTML: "<pre class=\"plain\"><code>\(escape(text))</code></pre>", csp: textCSP)
    }

    /// 預覽中的檔案不存在時顯示的頁面。
    static func missingPage(path: String) -> String {
        shellPage(title: nil, bodyHTML: "<h2>檔案已不存在</h2><p><code>\(escape(path))</code></p>")
    }

    /// 預覽中的檔案存在、但載入失敗（沒有讀取權限、內容不合法）時顯示的頁面。
    static func unreadablePage(path: String) -> String {
        shellPage(title: nil, bodyHTML: "<h2>無法讀取檔案</h2><p><code>\(escape(path))</code></p>")
    }

    /// 預覽檔案超過大小上限時顯示的頁面。
    static func tooLargePage(path: String, maxMB: Int) -> String {
        shellPage(title: nil, bodyHTML: "<h2>檔案太大，無法預覽（超過 \(maxMB) MB）</h2><p><code>\(escape(path))</code></p>")
    }

    /// 頁面的內容安全政策：不執行任何 script、不嵌入任何東西；圖片可以是本機（lmux-preview）、網路或 data:，
    /// 樣式只用頁面自己的。即使 JavaScript 沒被關掉，也多一層保護。
    static let csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
        + "img-src lmux-preview: https: http: data:; style-src 'unsafe-inline'\">"

    /// 純文字頁的內容安全政策：什麼都不載入，只允許頁面自己的樣式。
    static let textCSP = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">"

    /// 轉好的 Markdown（HTML 片段）。
    static func body(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let (source, linkedImages) = extractLinkedImages(markdown)
        guard let doc = try? AttributedString(markdown: source, options: options) else {
            return "<pre><code>\(escape(markdown))</code></pre>"
        }
        var r = Renderer()
        for run in doc.runs {
            let text = String(doc[run.range].characters)
            r.add(text: text, blocks: Array((run.presentationIntent?.components ?? []).reversed()),
                  inline: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL)
        }
        r.closeAll()
        return restoreLinkedImages(callouts(r.out), linkedImages)
    }

    // Foundation 的解析器在連結裡會丟掉圖片網址（`[![badge](x.svg)](url)` 只剩 alt 文字），
    // 所以先把「整個連結文字就是一張圖片」這種常見寫法（README 的 badge）換成佔位字，輸出時再換回 <img>。
    // 不在這裡猜哪些行是程式碼（縮排、引用內的 fence 都猜不準）：每一行都換，輸出時再看佔位字落在不在
    // <pre>／<code> 裡——在的話還原成原本的 Markdown 原文，不在才換成 <img>。最多換 200 個。
    private static let linkedImagePattern = try? NSRegularExpression(
        pattern: #"\[!\[([^\[\]]*)\]\(([^()\s]+)\)\]\(([^()\s]+)\)"#)
    private static let tokenOrCodeTag = try? NSRegularExpression(
        pattern: "\u{E000}LMUXIMG(\\d+)\u{E001}|<(/?)(?:pre|code)\\b[^>]*>")

    private static func linkedImageToken(_ i: Int) -> String { "\u{E000}LMUXIMG\(i)\u{E001}" }

    static func extractLinkedImages(_ markdown: String) -> (source: String, images: [(tag: String, raw: String, alt: String)]) {
        guard let pattern = linkedImagePattern, markdown.contains("[![") else { return (markdown, []) }
        var images: [(tag: String, raw: String, alt: String)] = []
        var lines: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            guard line.contains("[![") else { lines.append(line); continue }
            var out = ""
            var last = line.startIndex
            let ns = line as NSString
            for m in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard images.count < 200, let whole = Range(m.range, in: line) else { break }
                let alt = ns.substring(with: m.range(at: 1))
                let src = ns.substring(with: m.range(at: 2))
                let imgTag = URL(string: src).flatMap { safeImageURL($0) }
                    .map { "<img src=\"\($0)\" alt=\"\(escape(alt))\">" } ?? escape(alt)
                out += line[last..<whole.lowerBound] + "[\(linkedImageToken(images.count))](\(ns.substring(with: m.range(at: 3))))"
                images.append((imgTag, "![\(alt)](\(src))", escape(alt)))
                last = whole.upperBound
            }
            lines.append(out + line[last...])
        }
        return (lines.joined(separator: "\n"), images)
    }

    /// `location` 是不是落在某個標籤的 `<` 和 `>` 之間（屬性值裡）：往回找最近的 `<` 或 `>`，先遇到 `<` 就是在標籤裡。
    /// 屬性值裡的 `<`、`>` 都已經被 `escape` 換掉，所以最近的角括號一定是真的標籤邊界。
    private static func isInsideTag(_ html: NSString, at location: Int) -> Bool {
        var i = location - 1
        while i >= 0 {
            let c = html.character(at: i)
            if c == 0x3C { return true }   // <
            if c == 0x3E { return false }  // >
            i -= 1
        }
        return false
    }

    /// 標題的 id 不能含佔位字（`# [![x](a.svg)](b) Title` 要得到 `title`）。
    static func removingLinkedImageTokens(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{E000}") else { return text }
        return text.replacingOccurrences(of: "\u{E000}LMUXIMG[0-9]+\u{E001}", with: "", options: .regularExpression)
    }

    /// 一次掃過整份 HTML（線性，不是每張圖各掃一次）：佔位字換回 <img>；落在 <pre>／<code> 裡的還原成原文。
    private static func restoreLinkedImages(_ html: String, _ images: [(tag: String, raw: String, alt: String)]) -> String {
        guard !images.isEmpty, let re = tokenOrCodeTag else { return html }
        let ns = html as NSString
        var out = ""
        var last = 0
        var codeDepth = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let number = m.range(at: 1)
            if number.location != NSNotFound {
                let i = Int(ns.substring(with: number)) ?? -1
                if images.indices.contains(i) {
                    if Self.isInsideTag(ns, at: m.range.location) {
                        out += images[i].alt  // 外層圖片的 alt="…" 之類的屬性裡：只放（已跳脫的）文字，不能放整個 <img>
                    } else {
                        out += codeDepth == 0 ? images[i].tag : escape(images[i].raw)
                    }
                } else {
                    out += ns.substring(with: m.range)
                }
            } else {
                codeDepth = m.range(at: 2).length > 0 ? max(0, codeDepth - 1) : codeDepth + 1
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// `&`、`<`、`>`、`"`、`'` 換成 HTML entity。
    static func escape(_ s: String) -> String {
        // 逐 Unicode scalar 處理：`"` 後面接組合符號（U+0301）時，String 會把它們當成同一個 Character，逐 Character 比對會漏跳脫。
        var o = ""
        o.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.unicodeScalars.append(u)
            }
        }
        return o
    }

    /// 連結網址轉成屬性值；scheme 不在允許清單（例如 `javascript:`、`data:`）時回傳 nil，整個拿掉。
    /// 本機 `file://` 連結改寫為 `lmux-preview://`，避免 `WKWebView` 因跨 scheme 擋掉點擊；遠端主機的 `file://` 一律拿掉。
    static func safeURL(_ url: URL) -> String? {
        if url.isFileURL { return previewLink(url) }
        let allowed: Set<String> = ["http", "https", "mailto", "lmux-preview"]
        if let scheme = url.scheme?.lowercased(), !allowed.contains(scheme) { return nil }
        return escape(url.absoluteString)
    }

    /// 圖片網址轉成屬性值；除了一般網址與本機預覽 scheme，僅額外允許點陣圖 `data:` URL（排除 SVG 與 HTML）。
    static func safeImageURL(_ url: URL) -> String? {
        if url.isFileURL { return previewLink(url) }
        guard let scheme = url.scheme?.lowercased() else { return escape(url.absoluteString) }
        if ["http", "https", "lmux-preview"].contains(scheme) {
            return escape(url.absoluteString)
        }
        guard scheme == "data",
              let comma = url.absoluteString.firstIndex(of: ",") else { return nil }
        let header = url.absoluteString[..<comma].dropFirst("data:".count).lowercased()
        let mime = header.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let rasterMIMEs: Set<String> = ["image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"]
        guard rasterMIMEs.contains(mime) else { return nil }
        return escape(url.absoluteString)
    }

    private static func previewLink(_ url: URL) -> String? {
        guard url.port == nil, PreviewTarget.isLocalFileHost(url.host) else { return nil }
        var c = URLComponents()
        c.scheme = "lmux-preview"
        c.host = ""
        c.path = url.path
        c.fragment = url.fragment
        return c.url.map { escape($0.absoluteString) }
    }

    /// `<blockquote><p>[!類型] 標題`（GitHub／Obsidian 的 callout）換成有標題的提示框。
    static func callouts(_ html: String) -> String {
        guard let re = calloutRE else { return html }
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
            last = m.range.location + m.range.length
            let nextIsCloseP = hadP && (ns.length - last >= 4)
                && ns.substring(with: NSRange(location: last, length: 4)) == "</p>"
            out += "<blockquote class=\"callout callout-\(kind)\"><p class=\"callout-title\">\(title)</p>"
            if nextIsCloseP {
                last += 4
            } else if hadP {
                out += "<p>"
            }
        }
        out += ns.substring(from: last)
        return out
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
        var headingLevel: Int?
        var headingSavedOut: String?
        var headingPlain = ""
        var usedHeadingIDs: [String: Int] = [:]
        var assignedHeadingIDs: Set<String> = []

        mutating func add(text: String, blocks: [PresentationIntent.IntentType],
                          inline: InlinePresentationIntent, link: URL?, image: URL?) {
            var common = 0
            while common < open.count, common < blocks.count,
                  open[common].intent.identity == blocks[common].identity { common += 1 }
            while open.count > common { closeLast() }
            let opening = Array(blocks[common...])
            for (i, b) in opening.enumerated() { openBlock(b, next: i + 1 < opening.count ? opening[i + 1] : nil) }
            // 解析器把分隔線寫成文字「⸻」：有 <hr> 就夠了。
            if case .thematicBreak = blocks.last?.kind { return }
            if blocks.isEmpty, !text.isEmpty {
                out += "<p>" + MarkdownHTML.escape(text) + "</p>"
                return
            }
            if headingLevel != nil { headingPlain += MarkdownHTML.removingLinkedImageTokens(text) }
            let inCode = blocks.contains { if case .codeBlock = $0.kind { return true }; return false }
            out += inCode ? MarkdownHTML.escape(text) : Self.inlineHTML(text, inline, link: link, image: image)
        }

        mutating func closeAll() { while !open.isEmpty { closeLast() } }

        private mutating func closeLast() {
            let last = open.removeLast()
            if case .header = last.intent.kind, let level = headingLevel, var before = headingSavedOut {
                headingSavedOut = nil  // 先放掉另一份參考，下面的附加才能就地進行（否則每個標題都複製整份 HTML）
                let idAttr = nextHeadingID(for: headingPlain).map { " id=\"\(MarkdownHTML.escape($0))\"" } ?? ""
                before += "<h\(level)\(idAttr)>"
                before += out
                before += "</h\(level)>"
                out = before
                headingLevel = nil
                headingSavedOut = nil
                headingPlain = ""
                return
            }
            if case .tableHeaderRow = last.intent.kind { padRow(headerRow: true) }
            if case .tableRow = last.intent.kind { padRow(headerRow: false) }
            out += last.close
        }

        private mutating func nextHeadingID(for text: String) -> String? {
            var slug = ""
            var lastHyphen = false
            for ch in text.lowercased() {
                if ch == "_" || ch.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                    slug.append(ch)
                    lastHyphen = false
                } else if (ch == " " || ch == "-" || ch == "\t"), !slug.isEmpty, !lastHyphen {
                    slug.append("-")
                    lastHyphen = true
                }
            }
            while slug.hasSuffix("-") { slug.removeLast() }
            guard !slug.isEmpty else { return nil }
            let candidate: String
            if usedHeadingIDs[slug, default: 0] == 0, !assignedHeadingIDs.contains(slug) {
                candidate = slug
                usedHeadingIDs[slug] = 1
            } else {
                var n = max(1, usedHeadingIDs[slug, default: 1])
                while assignedHeadingIDs.contains("\(slug)-\(n)") { n += 1 }
                candidate = "\(slug)-\(n)"
                usedHeadingIDs[slug] = n + 1
            }
            assignedHeadingIDs.insert(candidate)
            return candidate
        }

        /// 空的格子不會有任何 run：補上空格子，欄位才不會錯位。
        private mutating func padRow(headerRow: Bool) {
            while nextCell < columns.count {
                out += headerRow ? "<th></th>" : "<td></td>"
                nextCell += 1
            }
        }

        private mutating func openBlock(_ b: PresentationIntent.IntentType, next: PresentationIntent.IntentType?) {
            switch b.kind {
            case .paragraph: out += "<p>"; open.append((b, "</p>"))
            case .header(let level):
                let n = min(max(level, 1), 6)
                headingLevel = n
                headingPlain = ""
                headingSavedOut = out
                out = ""
                open.append((b, "</h\(n)>"))
            case .orderedList:
                // 不是從 1 開始的編號清單（例如 5. 6.）要保留起始號碼。
                if case .listItem(let first)? = next?.kind, first != 1 { out += "<ol start=\"\(first)\">" } else { out += "<ol>" }
                open.append((b, "</ol>"))
            case .unorderedList: out += "<ul>"; open.append((b, "</ul>"))
            case .listItem: out += "<li>"; open.append((b, "</li>"))
            case .codeBlock(let lang):
                let cls = lang.map { " class=\"language-\(MarkdownHTML.escape($0))\"" } ?? ""
                out += "<pre><code\(cls)>"; open.append((b, "</code></pre>"))
            case .blockQuote: out += "<blockquote>"; open.append((b, "</blockquote>"))
            case .thematicBreak: out += "<hr>"; open.append((b, ""))
            case .table(let cols):
                columns = cols
                out += "<table>"; open.append((b, "</table>"))
            case .tableHeaderRow:
                nextCell = 0
                out += "<thead><tr>"; open.append((b, "</tr></thead>"))
            case .tableRow: nextCell = 0; out += "<tr>"; open.append((b, "</tr>"))
            case .tableCell(let column):
                let header = open.last.map { if case .tableHeaderRow = $0.intent.kind { return true }; return false } ?? false
                let tag = header ? "th" : "td"
                while nextCell < column { out += "<\(tag)></\(tag)>"; nextCell += 1 }
                nextCell = column + 1
                out += "<\(tag)\(align(column))>"; open.append((b, "</\(tag)>"))
            default: out += "<div>"; open.append((b, "</div>"))
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
                guard let src = MarkdownHTML.safeImageURL(image) else { return s }
                s = "<img src=\"\(src)\" alt=\"\(s)\">"
            } else {
                if i.contains(.code) { s = "<code>\(s)</code>" }
                if i.contains(.strikethrough) { s = "<del>\(s)</del>" }
                if i.contains(.emphasized) { s = "<em>\(s)</em>" }
                if i.contains(.stronglyEmphasized) { s = "<strong>\(s)</strong>" }
            }
            if let link, let href = MarkdownHTML.safeURL(link) { s = "<a href=\"\(href)\">\(s)</a>" }
            return s
        }
    }

    /// 樣式表：淺色與深色兩組顏色，跟著 `prefers-color-scheme` 切換（WKWebView 跟著 lmux 的外觀設定）。
    static let css = """
    :root{--bg:#ffffff;--fg:#24292f;--muted:#57606a;--border:#d0d7de;--code-bg:#f6f8fa;--link:#0969da;--note:#0969da;--tip:#1a7f37;--important:#8250df;--warning:#9a6700;--caution:#cf222e}
    @media (prefers-color-scheme: dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#8d96a0;--border:#30363d;--code-bg:#161b22;--link:#4493f8;--note:#4493f8;--tip:#3fb950;--important:#ab7df8;--warning:#d29922;--caution:#f85149}}
    html{background:var(--bg);color:var(--fg)}body{margin:0;font:15px/1.6 -apple-system,"PingFang TC",sans-serif}article{max-width:880px;margin:0 auto;padding:24px 32px}
    a{color:var(--link)}h1,h2{border-bottom:1px solid var(--border);padding-bottom:.3em}
    code{font:13px ui-monospace,Menlo,monospace;background:var(--code-bg);padding:.1em .3em;border-radius:4px}
    pre{background:var(--code-bg);padding:12px 16px;border-radius:6px;overflow:auto}pre code{padding:0;background:none}
    blockquote{margin:0 0 1em;padding:0 1em;color:var(--muted);border-left:4px solid var(--border)}
    .callout{color:var(--fg);border-left-color:var(--note)}.callout-title{font-weight:600;color:var(--note)}
    .callout-tip{border-left-color:var(--tip)}.callout-tip .callout-title{color:var(--tip)}.callout-important{border-left-color:var(--important)}.callout-important .callout-title{color:var(--important)}
    .callout-warning{border-left-color:var(--warning)}.callout-warning .callout-title{color:var(--warning)}.callout-caution{border-left-color:var(--caution)}.callout-caution .callout-title{color:var(--caution)}
    pre.plain{white-space:pre-wrap;overflow-wrap:anywhere;overflow:visible}pre.plain code{white-space:inherit}
    table{border-collapse:collapse;margin:0 0 1em}th,td{border:1px solid var(--border);padding:6px 13px}img{max-width:100%}li>p{margin:0}hr{border:0;border-top:1px solid var(--border)}
    """
}
