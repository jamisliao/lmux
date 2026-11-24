import Foundation

/// A condensed digest of one conversation turn extracted locally without LLM calls.
public struct TranscriptTurnDigest: Sendable, Equatable {
    public var index: Int
    public var promptSummary: String
    public var replySummary: String?

    public init(index: Int, promptSummary: String, replySummary: String?) {
        self.index = index
        self.promptSummary = promptSummary
        self.replySummary = replySummary
    }
}

/// Zero-token conversation context summary derived from local Claude or Codex transcripts.
public struct TranscriptContextSummary: Sendable, Equatable {
    public var sessionTitle: String?
    public var initialGoal: String?
    public var recentTurns: [TranscriptTurnDigest]
    public var touchedFiles: [String]

    public init(
        sessionTitle: String? = nil,
        initialGoal: String? = nil,
        recentTurns: [TranscriptTurnDigest] = [],
        touchedFiles: [String] = []
    ) {
        self.sessionTitle = sessionTitle
        self.initialGoal = initialGoal
        self.recentTurns = recentTurns
        self.touchedFiles = touchedFiles
    }
}

/// Extracts structured, sanitized context summaries from indexed Claude/Codex turns.
public enum TranscriptContextExtractor {
    private static let maxGoalCharacters = 200
    private static let maxTurnTextCharacters = 220
    private static let maxTouchedFiles = 12

    public static func extract(
        title: String?,
        turns: [TranscriptIndex.Turn],
        maxRecentTurns: Int = 3,
        maxFileTurns: Int = 5
    ) -> TranscriptContextSummary {
        let cleanTitle = sanitizeSingleLine(title)

        let goalTurn = turns.first { !(sanitizeSingleLine($0.prompt) ?? "").isEmpty }
        let initialGoal = goalTurn.flatMap { sanitizeSingleLine($0.prompt) }.map {
            String($0.prefix(maxGoalCharacters))
        }

        let remainingTurns: ArraySlice<TranscriptIndex.Turn>
        if let goalTurn {
            remainingTurns = turns.drop { $0.index <= goalTurn.index }
        } else {
            remainingTurns = turns[...]
        }

        let recentSlice = maxRecentTurns > 0 ? remainingTurns.suffix(maxRecentTurns) : remainingTurns.prefix(0)
        let recentTurns: [TranscriptTurnDigest] = recentSlice.compactMap { turn in
            guard let prompt = sanitizeSingleLine(turn.prompt) else { return nil }
            let reply = sanitizeSingleLine(turn.replyHead).map { String($0.prefix(maxTurnTextCharacters)) }
            return TranscriptTurnDigest(
                index: turn.index,
                promptSummary: String(prompt.prefix(maxTurnTextCharacters)),
                replySummary: reply
            )
        }

        let fileTurns = maxFileTurns > 0 ? turns.suffix(maxFileTurns) : turns.prefix(0)
        var touchedFiles: [String] = []
        var seenFiles: Set<String> = []
        for turn in fileTurns {
            for rawPath in turn.editedFiles + turn.createdFiles {
                guard let path = sanitizePath(rawPath), seenFiles.insert(path).inserted else { continue }
                touchedFiles.append(path)
                if touchedFiles.count >= maxTouchedFiles {
                    return TranscriptContextSummary(
                        sessionTitle: cleanTitle,
                        initialGoal: initialGoal,
                        recentTurns: recentTurns,
                        touchedFiles: touchedFiles
                    )
                }
            }
        }

        return TranscriptContextSummary(
            sessionTitle: cleanTitle,
            initialGoal: initialGoal,
            recentTurns: recentTurns,
            touchedFiles: touchedFiles
        )
    }

    private static func sanitizeSingleLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let stripped = replacingUnsafeScalars(text, collapseWhitespace: true)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizePath(_ path: String) -> String? {
        let stripped = replacingUnsafeScalars(path, collapseWhitespace: false)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Strips C0/C1 control characters and directional override/isolate scalars.
    private static func replacingUnsafeScalars(_ value: String, collapseWhitespace: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in value.unicodeScalars {
            if isUnsafeScalar(scalar) { continue }
            if collapseWhitespace && CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasSpace {
                    scalars.append(" ")
                    previousWasSpace = true
                }
                continue
            }
            previousWasSpace = false
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v == 0x09 || v == 0x0A || v == 0x0D { return false }
        if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) { return true }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) { return true }
        return v == 0x200E || v == 0x200F || v == 0x061C
    }
}
