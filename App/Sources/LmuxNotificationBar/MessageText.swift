import Foundation

/// 去掉通知訊息開頭的 Markdown 標記：標題（`#`…）、清單與引用（`- `、`* `、`> `）、粗體（`**…**`，連同結尾那一組）。
/// 只處理開頭：訊息中間的 `**`（例如 `src/**/*.swift`）與不帶空白的 `-1`、`*args` 都保留。
func plainMessage(_ s: String) -> String {
    var t = Substring(s)
    func trimLeadingSpace() { while let c = t.first, c == " " || c == "\t" { t.removeFirst() } }
    trimLeadingSpace()
    // 開頭的 **粗體**：連同它的結尾 ** 一起拿掉（找不到結尾就只拿掉開頭那一組）。
    if t.hasPrefix("**") {
        t.removeFirst(2)
        if let close = t.range(of: "**") { t.removeSubrange(close) }
        trimLeadingSpace()
    }
    // 標題 `#`…`######`，後面要有空白。
    let hashes = t.prefix { $0 == "#" }
    if (1...6).contains(hashes.count), t.dropFirst(hashes.count).first == " " {
        t.removeFirst(hashes.count)
        trimLeadingSpace()
    }
    // 清單與引用，後面要有空白。
    if let c = t.first, "-*>".contains(c), t.dropFirst().first == " " {
        t.removeFirst()
        trimLeadingSpace()
    }
    return String(t)
}
