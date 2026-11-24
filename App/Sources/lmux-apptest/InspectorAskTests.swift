// @feature: inspector-ask-panel.feature

import Foundation
import AppKit
@testable import LmuxUI

@MainActor
func runInspectorAsk() async -> Int32 {
    let r = Report()
    r.section = "inspector-ask"

    await runAskSpecTests(r)
    await runAskSessionStoreTests(r)

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

@MainActor
private func runAskSessionStoreTests(_ r: Report) async {
    let paneA = UUID()
    let paneB = UUID()
    func makeSpec(id: String = "q1", allowFreeText: Bool = false) -> AskSpec {
        AskSpec(
            title: "確認",
            eyebrow: "",
            intro: "請確認這組設定選項的細節與影響範圍。",
            questions: [
                AskQuestion(id: id, question: "請選一個", detail: "", allowFreeText: allowFreeText,
                            options: [AskOption(label: "A"), AskOption(label: "B")])
            ],
            lenient: true
        )
    }

    var now = Date(timeIntervalSince1970: 1_000_000)
    let store = AskSessionStore(now: { now })

    // 1. Per-pane FIFO preserves active session draft when second arrives
    guard let s1 = try? store.create(spec: makeSpec(id: "q1"), paneID: paneA, createdInsidePane: true),
          let s2 = try? store.create(spec: makeSpec(id: "q2"), paneID: paneA, createdInsidePane: true) else {
        r.check("AskSessionStore creates queued sessions", false)
        return
    }
    s1.draftSelected["q1"] = ["A"]
    r.check("AskSessionStore per-pane FIFO keeps s1 active with draft while s2 waits",
            store.activeSession(for: paneA)?.id == s1.id
            && store.pendingCount(for: paneA) == 2
            && s1.draftSelected["q1"] == ["A"])

    // 2. Unanswered question blocks submit and exposes firstUnansweredQuestionID
    s1.draftSelected["q1"] = []
    r.check("AskSessionStore blocks submit when unanswered and identifies question",
            !s1.isAllAnswered && s1.firstUnansweredQuestionID == "q1" && !store.submit(sessionID: s1.id))

    // 3. Submit without waiter stores in cache; attachWaiter later delivers & pops cache
    s1.draftSelected["q1"] = ["B"]
    r.check("AskSessionStore submit succeeds when answered even before waiter attaches",
            s1.isAllAnswered && s1.answeredCount == 1 && store.submit(sessionID: s1.id))
    r.check("AskSessionStore advances FIFO to s2 after s1 submits",
            store.activeSession(for: paneA)?.id == s2.id && store.pendingCount(for: paneA) == 1)

    var deliveredOutcome: AskWaitOutcome?
    let cancel1 = store.attachWaiter(sessionID: s1.id) { outcome in
        deliveredOutcome = outcome
    }
    r.check("AskSessionStore cached outcome delivered immediately and cleared afterwards",
            cancel1 == nil
            && deliveredOutcome?.status == "submitted"
            && deliveredOutcome?.answers.first?.selected == ["B"]
            && deliveredOutcome?.answers.first?.freeText == "")
    var secondAttempt: AskWaitOutcome?
    _ = store.attachWaiter(sessionID: s1.id) { secondAttempt = $0 }
    r.check("AskSessionStore cached outcome consumed once (second lookup sees nil/notFound)",
            secondAttempt?.status == "not_found")

    // 4. Supersede old waiter cleanly; detach does not destroy form
    var oldOutcome: AskWaitOutcome?
    var newOutcome: AskWaitOutcome?
    let detachOld = store.attachWaiter(sessionID: s2.id) { oldOutcome = $0 }
    let detachNew = store.attachWaiter(sessionID: s2.id) { newOutcome = $0 }
    r.check("AskSessionStore supersedes earlier waiter with superseded error",
            oldOutcome?.status == "superseded" && newOutcome == nil && store.activeSession(for: paneA)?.id == s2.id)
    detachOld?()
    detachNew?()
    r.check("AskSessionStore detaching waiter keeps pending form alive",
            store.activeSession(for: paneA)?.id == s2.id)

    // 5. Cancel delivers cancelled with non-empty note
    var cancelOutcome: AskWaitOutcome?
    _ = store.attachWaiter(sessionID: s2.id) { cancelOutcome = $0 }
    store.cancel(sessionID: s2.id)
    r.check("AskSessionStore cancel delivers cancelled outcome with note",
            cancelOutcome?.status == "cancelled"
            && !(cancelOutcome?.note ?? "").isEmpty
            && store.pendingCount(for: paneA) == 0)

    // 6. markPaneClosed & markAllLost notify active waiters
    if let s3 = try? store.create(spec: makeSpec(id: "q3"), paneID: paneB, createdInsidePane: false),
       let s4 = try? store.create(spec: makeSpec(id: "q4"), paneID: paneA, createdInsidePane: true) {
        var o3: AskWaitOutcome?
        var o4: AskWaitOutcome?
        _ = store.attachWaiter(sessionID: s3.id) { o3 = $0 }
        _ = store.attachWaiter(sessionID: s4.id) { o4 = $0 }
        store.markPaneClosed(paneB)
        r.check("AskSessionStore markPaneClosed ends only that pane's sessions with lost+note",
                o3?.status == "lost" && !(o3?.note ?? "").isEmpty && o4 == nil && store.pendingCount(for: paneA) == 1)
        store.markAllLost()
        r.check("AskSessionStore markAllLost clears remaining sessions with lost+note",
                o4?.status == "lost" && !(o4?.note ?? "").isEmpty && store.totalPendingCount == 0)
    }

    // 7. Outcome cache TTL (10m) & LRU cap (32)
    for i in 1...34 {
        let sid = "cache-\(i)"
        if let s = try? store.create(spec: makeSpec(id: "qc", allowFreeText: true), paneID: paneA, createdInsidePane: true, sessionID: sid) {
            s.draftFreeText["qc"] = "note \(i)"
            _ = store.submit(sessionID: sid)
        }
    }
    var evictedOutcome: AskWaitOutcome?
    _ = store.attachWaiter(sessionID: "cache-1") { evictedOutcome = $0 }
    r.check("AskSessionStore evicts oldest cached outcome beyond 32 entries",
            evictedOutcome?.status == "not_found")
    now.addTimeInterval(AskSessionStore.cacheTTL + 1)
    var expiredOutcome: AskWaitOutcome?
    _ = store.attachWaiter(sessionID: "cache-34") { expiredOutcome = $0 }
    r.check("AskSessionStore expires cached outcome after 10 minutes",
            expiredOutcome?.status == "not_found")

    // 8. Per-pane cap (16) and global cap (64) fail closed
    var createdOnA = 0
    for _ in 0..<20 {
        if (try? store.create(spec: makeSpec(), paneID: paneA, createdInsidePane: true)) != nil {
            createdOnA += 1
        }
    }
    r.check("AskSessionStore caps per-pane pending at 16", createdOnA == AskSessionStore.maxPendingPerPane)
    var globalTotal = store.totalPendingCount
    for idx in 0..<6 {
        let p = UUID()
        for _ in 0..<16 {
            if (try? store.create(spec: makeSpec(), paneID: p, createdInsidePane: true)) != nil {
                globalTotal += 1
            } else if idx >= 3 {
                break
            }
        }
    }
    r.check("AskSessionStore caps global pending at 64",
            store.totalPendingCount == AskSessionStore.maxPendingGlobal)
    store.markAllLost()
}
