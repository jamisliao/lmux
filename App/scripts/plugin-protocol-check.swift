// sidebar plugin 協定（App/Sources/LmuxNotificationBar/PluginProtocol.swift）的自我檢查。
// 不需要 libghostty 也不會碰 apptest，單獨編譯執行：
//   swiftc -parse-as-library -o /tmp/plugin-protocol-check \
//     App/Sources/LmuxNotificationBar/PluginProtocol.swift App/scripts/plugin-protocol-check.swift \
//     && /tmp/plugin-protocol-check

import Foundation

@main
enum PluginProtocolCheck {
    static func feed(_ r: inout PluginLineReader, _ s: String) -> PluginMessage? { r.feed(Data(s.utf8)) }

    static func main() {
        var r = PluginLineReader()

        // 合法的 set（四個欄位都有）
        let full = feed(&r, #"{"set":{"icon":"clock","text":"standup 10:00","tone":"done","badge":"3"}}"# + "\n")
        precondition(full == .set(PluginRowContent(icon: "clock", text: "standup 10:00", tone: .done, badge: "3")))

        // 只有 text；未知的 tone 當成沒給
        let minimal = feed(&r, #"{"set":{"text":"hi","tone":"purple"}}"# + "\n")
        precondition(minimal == .set(PluginRowContent(icon: nil, text: "hi", tone: nil, badge: nil)))

        // clear
        precondition(feed(&r, #"{"clear":true}"# + "\n") == .clear)

        // 壞掉的 JSON、沒有 text 的 set、不認得的訊息：略過
        precondition(feed(&r, "not json\n") == nil)
        precondition(feed(&r, #"{"set":{"icon":"x"}}"# + "\n") == nil)
        precondition(feed(&r, #"{"hello":1}"# + "\n") == nil)

        // 同一批有多行：只取最後一個合法的訊息
        let batch = feed(&r, #"{"set":{"text":"a"}}"# + "\n" + #"{"set":{"text":"b"}}"# + "\nbroken\n")
        precondition(batch == .set(PluginRowContent(icon: nil, text: "b", tone: nil, badge: nil)))

        // 一行分成兩次送來：第一次沒有完整的行，第二次才解析
        precondition(feed(&r, #"{"set":{"te"#) == nil)
        precondition(feed(&r, #"xt":"split"}}"# + "\n") == .set(PluginRowContent(icon: nil, text: "split", tone: nil, badge: nil)))

        // 超過上限的行整行丟掉（包括跨好幾次送來的），之後的行照常解析
        let long = String(repeating: "x", count: PluginLineReader.maxLineBytes + 10)
        precondition(feed(&r, #"{"set":{"text":""# + long) == nil)
        precondition(feed(&r, long + #""}}"# + "\n" + #"{"set":{"text":"after"}}"# + "\n")
               == .set(PluginRowContent(icon: nil, text: "after", tone: nil, badge: nil)))
        precondition(r.bufferedBytes == 0)

        // 沒有換行、一直送：buffer 不會超過上限
        var flood = PluginLineReader()
        for _ in 0..<10 { _ = feed(&flood, long) }
        precondition(flood.bufferedBytes <= PluginLineReader.maxLineBytes)

        print("plugin protocol check: ok")
    }
}
