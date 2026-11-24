// @feature: inspector-ask-panel.feature

import Foundation
import AppKit
@testable import LmuxUI

@MainActor
func runInspectorAsk() async -> Int32 {
    let r = Report()
    r.section = "inspector-ask"

    await runAskSpecTests(r)

    print("inspector-ask summary: \(r.passed) passed, \(r.failed) failed")
    return r.failed == 0 ? 0 : 1
}

@MainActor
private func runAskSpecTests(_ r: Report) async {
    let longIntro = "這是一段超過二十五個字的前情提要說明，用來確認嚴格模式檢核能夠通過。"
    let longDetail = "這是一段超過二十個字的詳細背景說明文字。"

    // 1. Shorthand string options & recommended suffix stripping
    let rawShorthand: [String: Any] = [
        "title": "  架構\u{202E}確認\u{0007}  ",
        "eyebrow": "決策\u{200F}點",
        "intro": longIntro,
        "questions": [
            [
                "id": "q1",
                "header": "選型",
                "question": "請選擇儲存引擎",
                "detail": longDetail,
                "options": ["方案 A (Recommended)", "方案 B（推薦）", "方案 C"],
                "refs": ["src/App.swift:1-10"],
                "gitDiff": ["src/App.swift"]
            ]
        ]
    ]
    do {
        let spec = try AskSpec.parse(jsonObject: rawShorthand)
        r.check("AskSpec parses shorthand options and strips recommended markers",
                spec.questions.count == 1
                && spec.questions[0].options.count == 3
                && spec.questions[0].options[0].label == "方案 A"
                && spec.questions[0].options[0].recommended
                && spec.questions[0].options[1].label == "方案 B"
                && spec.questions[0].options[1].recommended
                && spec.questions[0].options[2].label == "方案 C"
                && !spec.questions[0].options[2].recommended)
        r.check("AskSpec sanitizes unsafe BiDi and control scalars while preserving multiline intro/detail",
                spec.title == "架構確認" && spec.eyebrow == "決策點")
    } catch {
        r.check("AskSpec parses valid shorthand spec", false, "\(error)")
    }

    // 2. Multiline detail preserves newlines while stripping BiDi
    let multilineObj: [String: Any] = [
        "intro": "第一行\n第二行與更多說明文字補足二十五個字的長度需求。",
        "questions": [
            [
                "id": "qm",
                "question": "是否繼續？",
                "detail": "說明第一行\u{202E}\n- 清單項目補充至少二十個字元",
                "options": ["繼續 (Recommended)", "取消"]
            ]
        ]
    ]
    if let ms = try? AskSpec.parse(jsonObject: multilineObj) {
        r.check("AskSpec preserves newlines in intro/detail while stripping unsafe scalars",
                ms.intro.contains("\n") && ms.questions[0].detail.contains("\n") && !ms.questions[0].detail.contains("\u{202E}"))
    } else {
        r.check("AskSpec multiline spec parse succeeds", false)
    }

    // 3. Strict validation rejections
    func expectsError(_ name: String, _ obj: [String: Any], lenient: Bool = false) {
        do {
            _ = try AskSpec.parse(jsonObject: obj, lenient: lenient)
            r.check(name, false, "expected error but succeeded")
        } catch is AskSpecError {
            r.check(name, true)
        } catch {
            r.check(name, false, "unexpected error \(error)")
        }
    }

    expectsError("AskSpec strict rejects short intro (<25 chars)", [
        "intro": "太短",
        "questions": [["id": "q1", "question": "問題", "detail": longDetail, "options": ["A", "B"]]]
    ])

    expectsError("AskSpec strict rejects short detail (<20 chars) when options present", [
        "intro": longIntro,
        "questions": [["id": "q1", "question": "問題", "detail": "太短", "options": ["A", "B"]]]
    ])

    expectsError("AskSpec rejects duplicate question ids", [
        "intro": longIntro,
        "questions": [
            ["id": "dup", "question": "Q1", "detail": longDetail, "options": ["A", "B"]],
            ["id": "dup", "question": "Q2", "detail": longDetail, "options": ["C", "D"]]
        ]
    ])

    expectsError("AskSpec rejects duplicate normalized option labels", [
        "intro": longIntro,
        "questions": [
            ["id": "q1", "question": "Q1", "detail": longDetail, "options": ["方案 A (Recommended)", "方案 A"]]
        ]
    ])

    expectsError("AskSpec rejects 0 questions", [
        "intro": longIntro,
        "questions": []
    ])

    let thirteen = (1...13).map { i in
        ["id": "q\(i)", "question": "題目 \(i)", "allowFreeText": true] as [String: Any]
    }
    expectsError("AskSpec rejects >12 questions", [
        "intro": longIntro,
        "questions": thirteen
    ])

    let nineRefs = (1...9).map { "f\($0).swift" }
    expectsError("AskSpec rejects >8 refs per question without silent truncation", [
        "intro": longIntro,
        "questions": [["id": "q1", "question": "Q1", "allowFreeText": true, "refs": nineRefs]]
    ])

    expectsError("AskSpec rejects >8 gitDiff per question without silent truncation", [
        "intro": longIntro,
        "questions": [["id": "q1", "question": "Q1", "allowFreeText": true, "gitDiff": nineRefs]]
    ])

    // 4. Lenient mode allows short intro and empty detail, still requires non-empty intro & question
    do {
        let lSpec = try AskSpec.parse(jsonObject: [
            "intro": "簡短確認",
            "questions": [["id": "ql", "question": "同意嗎？", "detail": "", "options": ["好"]]]
        ], lenient: true)
        r.check("AskSpec lenient allows short intro and empty detail",
                lSpec.lenient && lSpec.intro == "簡短確認" && lSpec.questions[0].detail.isEmpty)
    } catch {
        r.check("AskSpec lenient parses short intro", false, "\(error)")
    }
    expectsError("AskSpec lenient still rejects empty question", [
        "intro": "ok",
        "questions": [["id": "q1", "question": "   ", "allowFreeText": true]]
    ], lenient: true)

    // 5. AskAnswer serialization guarantees fixed keys
    let ans = AskAnswer(id: "q1", header: "", question: "Q1", selected: ["方案 A"], freeText: "")
    let json = ans.toJSONObject()
    r.check("AskAnswer.toJSONObject outputs header and freeText keys even when empty",
            (json["id"] as? String) == "q1"
            && (json["header"] as? String) == ""
            && (json["freeText"] as? String) == ""
            && (json["selected"] as? [String]) == ["方案 A"])
}
