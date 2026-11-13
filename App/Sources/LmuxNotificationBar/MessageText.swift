import Foundation

/// 去掉通知訊息開頭的 Markdown 標記：標題（`#`…）、清單與引用（`- `、`* `、`> `）、粗體（`**…**`，連同結尾那一組）。
/// 標記可以疊加（`## **標題**`、`- **結論**：好`），一層一層拿掉。
/// 只處理開頭：訊息中間的 `**`（例如 `src/**/*.swift`）與不帶空白的 `-1`、`*args` 都保留。
func plainMessage(_ s: String) -> String {
    var t = Substring(s)
    func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\u{3000}" }
    func trimLeadingSpace() { while let c = t.first, isSpace(c) { t.removeFirst() } }

    /// 拿掉一層開頭的標記；沒有可拿的就回 false。
    func stripOneMarker() -> Bool {
        // **粗體**：後面不能是空白（`** 說明` 不是粗體）。連同它的結尾 ** 一起拿掉（找不到結尾就只拿掉開頭那一組）。
        if t.hasPrefix("**"), let next = t.dropFirst(2).first, !isSpace(next) {
            t.removeFirst(2)
            if let close = t.range(of: "**") { t.removeSubrange(close) }
            return true
        }
        // 標題 `#`…`######`，後面要有空白。
        let hashes = t.prefix { $0 == "#" }
        if (1...6).contains(hashes.count), let after = t.dropFirst(hashes.count).first, isSpace(after) {
            t.removeFirst(hashes.count)
            return true
        }
        // 清單與引用，後面要有空白。
        if let c = t.first, "-*>".contains(c), let after = t.dropFirst().first, isSpace(after) {
            t.removeFirst()
            return true
        }
        return false
    }

    trimLeadingSpace()
    while stripOneMarker() { trimLeadingSpace() }
    return String(t)
}
