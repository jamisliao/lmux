// 通知卡片訊息的清理（App/Sources/LmuxNotificationBar/MessageText.swift）的自我檢查。
// 不需要 libghostty，單獨編譯執行：
//   swiftc -parse-as-library -o /tmp/message-text-check \
//     App/Sources/LmuxNotificationBar/MessageText.swift App/scripts/message-text-check.swift \
//     && /tmp/message-text-check

import Foundation

@main
enum MessageTextCheck {
    static func check(_ input: String, _ expected: String, _ line: UInt = #line) {
        let got = plainMessage(input)
        precondition(got == expected, "plainMessage(\(input.debugDescription)) = \(got.debugDescription), 預期 \(expected.debugDescription)（第 \(line) 行）")
    }

    // @feature: notification-cards.feature
    // @scenario: 訊息開頭的 Markdown 符號不顯示
    // @scenario: 訊息中間的 ** 與沒有空白的符號保留
    static func main() {
        // 開頭的標記拿掉
        check("## 結論", "結論")
        check("# 標題", "標題")
        check("###### 六級標題", "六級標題")
        check("- 項目", "項目")
        check("* 項目", "項目")
        check("> 引用", "引用")
        check("**完成**：測試通過", "完成：測試通過")
        check("**完成", "完成")          // 沒有結尾的 ** 也只拿掉開頭那一組
        check("  ## 前面有空白", "前面有空白")

        // 標記疊加（Claude 的回覆常這樣寫）：一層一層拿掉
        check("## **標題**", "標題")
        check("- **結論**：好", "結論：好")
        check("> **注意** 事項", "注意 事項")
        check("**粗** 然後 src/**/x", "粗 然後 src/**/x")
        check("\u{3000}## 全形空白開頭", "全形空白開頭")
        check("** 說明 src/**/x", "** 說明 src/**/x")  // ** 後面是空白，不是粗體

        // 訊息中間的 ** 保留（glob、程式碼）
        check("改了 src/**/*.swift", "改了 src/**/*.swift")
        check("a**b", "a**b")

        // 沒有空白的符號保留
        check("-1 failed", "-1 failed")
        check("*args 是參數", "*args 是參數")
        check("#65458 已 merge", "#65458 已 merge")
        check("####### 七個", "####### 七個")  // 超過六級不是標題

        // 沒有標記的原樣
        check("ClaudeCode: 完成", "ClaudeCode: 完成")
        check("", "")
        check("##", "##")                 // 只有符號、後面沒有空白

        print("message text check: ok")
    }
}
