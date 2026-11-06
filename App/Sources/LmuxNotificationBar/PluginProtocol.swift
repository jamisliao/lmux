import Foundation

// sidebar plugin 協定：plugin 往 stdout 每行寫一個 JSON，lmux 從 plugin 的 stdin 每行送一個事件。
//   plugin → lmux  {"set":{"text":"build #42 passed","icon":"checkmark.circle","tone":"done","badge":"3"}}
//                  {"clear":true}
//   lmux → plugin  {"event":"click"}
// 只依賴 Foundation，方便用 App/scripts/plugin-protocol-check.swift 單獨檢查。

/// plugin 那一行要顯示的內容。`text` 必填，其他可省略。
struct PluginRowContent: Equatable {
    /// 只能用 lmux 現有的狀態色（LmuxTokens.Colors 的 stateDone／stateFailed／stateNeedsInput／accent）。
    enum Tone: String { case done, failed, needsInput, accent }
    var icon: String?
    var text: String
    var tone: Tone?
    var badge: String?
}

enum PluginMessage: Equatable {
    case set(PluginRowContent)
    case clear
}

/// 把 plugin stdout 的位元組切成行並解析。同一批資料裡有多行時，只回傳最後一個合法的訊息：
/// 中間的狀態反正馬上會被蓋掉，不必每個都重畫。
struct PluginLineReader {
    /// 單行上限；超過的整行丟掉，plugin 送再多也撐不大 lmux 的記憶體。
    static let maxLineBytes = 4096
    private var buffer = Data()
    /// 正在丟棄一行超過上限的內容，直到下一個換行為止。
    private var discarding = false

    var bufferedBytes: Int { buffer.count }

    mutating func feed(_ data: Data) -> PluginMessage? {
        var last: PluginMessage?
        var rest = data[...]
        while let nl = rest.firstIndex(of: 0x0A) {
            let line = rest[rest.startIndex..<nl]
            rest = rest[(nl + 1)...]
            if discarding {
                discarding = false
                continue
            }
            buffer.append(line)
            if buffer.count <= Self.maxLineBytes, let m = Self.parse(buffer) { last = m }
            buffer.removeAll(keepingCapacity: true)
        }
        if !discarding {
            buffer.append(rest)
            if buffer.count > Self.maxLineBytes {
                discarding = true
                buffer.removeAll()
            }
        }
        return last
    }

    /// 一行 JSON；不合法或不認得就回傳 nil（略過那一行）。
    static func parse(_ line: Data) -> PluginMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if obj["clear"] as? Bool == true { return .clear }
        guard let set = obj["set"] as? [String: Any], let text = set["text"] as? String else { return nil }
        return .set(PluginRowContent(icon: set["icon"] as? String,
                                     text: text,
                                     tone: (set["tone"] as? String).flatMap(PluginRowContent.Tone.init(rawValue:)),
                                     badge: set["badge"] as? String))
    }
}
