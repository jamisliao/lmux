import Foundation

/// A single selectable option within a structured question.
public struct AskOption: Sendable, Equatable {
    public var label: String
    public var description: String
    public var recommended: Bool

    public init(label: String, description: String = "", recommended: Bool = false) {
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}

/// A single question in an ask session specification.
public struct AskQuestion: Sendable, Equatable, Identifiable {
    public var id: String
    public var header: String
    public var question: String
    public var detail: String
    public var mermaid: String?
    public var multiSelect: Bool
    public var allowFreeText: Bool
    public var options: [AskOption]
    public var refs: [String]
    public var gitDiff: [String]

    public init(
        id: String,
        header: String = "",
        question: String,
        detail: String = "",
        mermaid: String? = nil,
        multiSelect: Bool = false,
        allowFreeText: Bool = false,
        options: [AskOption] = [],
        refs: [String] = [],
        gitDiff: [String] = []
    ) {
        self.id = id
        self.header = header
        self.question = question
        self.detail = detail
        self.mermaid = mermaid
        self.multiSelect = multiSelect
        self.allowFreeText = allowFreeText
        self.options = options
        self.refs = refs
        self.gitDiff = gitDiff
    }
}

/// Normalized structured question sheet submitted to `lmux ask`.
public struct AskSpec: Sendable, Equatable {
    public static let maxQuestions = 12
    public static let maxRefsPerQuestion = 8
    public static let maxGitDiffsPerQuestion = 8
    public static let minStrictIntroLength = 25
    public static let minStrictDetailLength = 20

    public var title: String
    public var eyebrow: String
    public var intro: String
    public var questions: [AskQuestion]
    public var lenient: Bool

    public init(
        title: String = "",
        eyebrow: String = "",
        intro: String,
        questions: [AskQuestion],
        lenient: Bool = false
    ) {
        self.title = title
        self.eyebrow = eyebrow
        self.intro = intro
        self.questions = questions
        self.lenient = lenient
    }

    /// Parses and validates a raw JSON object into an `AskSpec`.
    public static func parse(jsonObject: [String: Any], lenient: Bool = false) throws -> AskSpec {
        let effectiveLenient = lenient || (jsonObject["lenient"] as? Bool ?? false)
        let title = sanitizeSingleLine(jsonObject["title"] as? String ?? "")
        let eyebrow = sanitizeSingleLine(jsonObject["eyebrow"] as? String ?? "")
        let intro = sanitizeMultiline(jsonObject["intro"] as? String ?? "")

        guard !intro.isEmpty else {
            throw AskSpecError.invalidField("intro is required and cannot be empty")
        }
        if !effectiveLenient && intro.count < minStrictIntroLength {
            throw AskSpecError.strictViolation("intro must be at least \(minStrictIntroLength) characters (got \(intro.count))")
        }

        guard let rawQuestions = jsonObject["questions"] as? [[String: Any]], !rawQuestions.isEmpty else {
            throw AskSpecError.invalidField("questions must be a non-empty array")
        }
        guard rawQuestions.count <= maxQuestions else {
            throw AskSpecError.invalidField("questions count (\(rawQuestions.count)) exceeds maximum of \(maxQuestions)")
        }

        var questions: [AskQuestion] = []
        var seenIDs: Set<String> = []
        questions.reserveCapacity(rawQuestions.count)

        for (index, rawQ) in rawQuestions.enumerated() {
            let q = try parseQuestion(rawQ, index: index, lenient: effectiveLenient)
            guard seenIDs.insert(q.id).inserted else {
                throw AskSpecError.duplicateQuestionID(q.id)
            }
            questions.append(q)
        }

        return AskSpec(title: title, eyebrow: eyebrow, intro: intro, questions: questions, lenient: effectiveLenient)
    }

    private static func parseQuestion(_ raw: [String: Any], index: Int, lenient: Bool) throws -> AskQuestion {
        let rawID = sanitizeSingleLine(raw["id"] as? String ?? "")
        let id = rawID.isEmpty ? "q\(index + 1)" : rawID
        let header = sanitizeSingleLine(raw["header"] as? String ?? "")
        let question = sanitizeSingleLine(raw["question"] as? String ?? "")
        guard !question.isEmpty else {
            throw AskSpecError.invalidField("question \(id) text cannot be empty")
        }

        let detail = sanitizeMultiline(raw["detail"] as? String ?? "")
        let mermaidRaw = (raw["mermaid"] as? String).map { sanitizeMultiline($0) }
        let mermaid = (mermaidRaw?.isEmpty == false) ? mermaidRaw : nil
        let multiSelect = raw["multiSelect"] as? Bool ?? false

        let rawOptions = raw["options"] as? [Any] ?? []
        var options: [AskOption] = []
        var seenLabels: Set<String> = []
        for item in rawOptions {
            let opt = try parseOption(item, questionID: id)
            guard seenLabels.insert(opt.label).inserted else {
                throw AskSpecError.duplicateOptionLabel(questionID: id, label: opt.label)
            }
            options.append(opt)
        }

        if !lenient && !options.isEmpty && detail.count < minStrictDetailLength {
            throw AskSpecError.strictViolation("question \(id) detail must be at least \(minStrictDetailLength) characters when options are provided")
        }

        let allowFreeText = (raw["allowFreeText"] as? Bool)
            ?? (raw["freeText"] as? Bool)
            ?? options.isEmpty
        if options.isEmpty && !allowFreeText {
            throw AskSpecError.invalidField("question \(id) has no options and allowFreeText is false")
        }

        let refs = try parseStringArray(raw["refs"], field: "refs", limit: maxRefsPerQuestion, questionID: id)
        let gitDiff = try parseStringArray(raw["gitDiff"], field: "gitDiff", limit: maxGitDiffsPerQuestion, questionID: id)

        return AskQuestion(
            id: id,
            header: header,
            question: question,
            detail: detail,
            mermaid: mermaid,
            multiSelect: multiSelect,
            allowFreeText: allowFreeText,
            options: options,
            refs: refs,
            gitDiff: gitDiff
        )
    }

    private static func parseOption(_ raw: Any, questionID: String) throws -> AskOption {
        let rawLabel: String
        let rawDesc: String
        let explicitRecommended: Bool

        if let str = raw as? String {
            rawLabel = str
            rawDesc = ""
            explicitRecommended = false
        } else if let dict = raw as? [String: Any], let labelStr = dict["label"] as? String {
            rawLabel = labelStr
            rawDesc = dict["description"] as? String ?? ""
            explicitRecommended = dict["recommended"] as? Bool ?? false
        } else {
            throw AskSpecError.invalidField("invalid option in question \(questionID)")
        }

        let cleanedLabel = sanitizeSingleLine(rawLabel)
        let (strippedLabel, detectedRecommended) = stripRecommendedSuffix(cleanedLabel)
        guard !strippedLabel.isEmpty else {
            throw AskSpecError.invalidField("empty option label in question \(questionID)")
        }

        return AskOption(
            label: strippedLabel,
            description: sanitizeMultiline(rawDesc),
            recommended: explicitRecommended || detectedRecommended
        )
    }

    private static func parseStringArray(_ raw: Any?, field: String, limit: Int, questionID: String) throws -> [String] {
        guard let raw else { return [] }
        guard let arr = raw as? [String] else {
            throw AskSpecError.invalidField("\(field) in question \(questionID) must be an array of strings")
        }
        guard arr.count <= limit else {
            throw AskSpecError.tooManyEntries(field: field, questionID: questionID, count: arr.count, limit: limit)
        }
        return arr.map { sanitizeSingleLine($0) }.filter { !$0.isEmpty }
    }

    private static let recommendedSuffixRE = try? NSRegularExpression(
        pattern: #"(?:\s*(?:\(recommended\)|（推薦）|\(推薦\)|（建議）|\(建議\)|\[recommended\]))+$"#,
        options: [.caseInsensitive]
    )

    private static func stripRecommendedSuffix(_ label: String) -> (String, Bool) {
        guard let re = recommendedSuffixRE else { return (label, false) }
        let range = NSRange(label.startIndex..<label.endIndex, in: label)
        guard let match = re.firstMatch(in: label, range: range),
              let swiftRange = Range(match.range, in: label) else {
            return (label, false)
        }
        let stripped = String(label[..<swiftRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped, true)
    }

    /// Removes unsafe control/BiDi scalars and collapses newlines for single-line fields.
    static func sanitizeSingleLine(_ value: String) -> String {
        let singleLine = value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let stripped = PreviewTarget.replacingUnsafeScalars(singleLine)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes unsafe control/BiDi scalars while preserving tabs and line breaks for Markdown content.
    static func sanitizeMultiline(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D {
                scalars.append(scalar)
                continue
            }
            if !PreviewTarget.isUnsafeScalar(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Answer payload produced for one question when the user submits.
public struct AskAnswer: Sendable, Equatable {
    public var id: String
    public var header: String
    public var question: String
    public var selected: [String]
    public var freeText: String

    public init(id: String, header: String = "", question: String, selected: [String], freeText: String = "") {
        self.id = id
        self.header = header
        self.question = question
        self.selected = selected
        self.freeText = freeText
    }

    public func toJSONObject() -> [String: Any] {
        [
            "id": id,
            "header": header,
            "question": question,
            "selected": selected,
            "freeText": freeText
        ]
    }
}

/// Validation errors thrown when parsing an `AskSpec`.
public enum AskSpecError: Error, Equatable, CustomStringConvertible {
    case invalidField(String)
    case strictViolation(String)
    case duplicateQuestionID(String)
    case duplicateOptionLabel(questionID: String, label: String)
    case tooManyEntries(field: String, questionID: String, count: Int, limit: Int)

    public var description: String {
        switch self {
        case .invalidField(let msg): return msg
        case .strictViolation(let msg): return msg
        case .duplicateQuestionID(let id): return "duplicate question id: \(id)"
        case .duplicateOptionLabel(let qid, let label): return "duplicate option label '\(label)' in question \(qid)"
        case .tooManyEntries(let field, let qid, let count, let limit):
            return "\(field) in question \(qid) has \(count) items (maximum \(limit))"
        }
    }
}
