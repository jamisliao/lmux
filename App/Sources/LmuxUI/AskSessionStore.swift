import Foundation
import Observation
import LmuxTranscript
import Security

/// Locally loaded file snippet referenced by an ask question.
public struct AskFileRefResult: Sendable, Equatable, Identifiable {
    public var id: String
    public var raw: String
    public var relativePath: String
    public var resolvedURL: URL?
    public var startLine: Int?
    public var endLine: Int?
    public var lines: [String]
    public var truncated: Bool
    public var errorMessage: String?

    public init(
        id: String,
        raw: String,
        relativePath: String,
        resolvedURL: URL? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        lines: [String] = [],
        truncated: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.raw = raw
        self.relativePath = relativePath
        self.resolvedURL = resolvedURL
        self.startLine = startLine
        self.endLine = endLine
        self.lines = lines
        self.truncated = truncated
        self.errorMessage = errorMessage
    }
}

/// Locally loaded git diff hunks referenced by an ask question.
public struct AskGitDiffRefResult: Sendable, Equatable, Identifiable {
    public var id: String
    public var relativePath: String
    public var lines: [GitDiffLine]
    public var truncated: Bool
    public var errorMessage: String?

    public init(
        id: String,
        relativePath: String,
        lines: [GitDiffLine] = [],
        truncated: Bool = false,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.lines = lines
        self.truncated = truncated
        self.errorMessage = errorMessage
    }
}

/// Zero-token session context assembled locally for display alongside an ask form.
public struct AskSessionContext: Sendable, Equatable {
    public var sessionTitle: String?
    public var initialGoal: String?
    public var recentTurns: [TranscriptTurnDigest]
    public var touchedFiles: [String]
    public var recentTools: [String]
    public var gitBranch: String?
    public var gitChangedCount: Int

    public init(
        sessionTitle: String? = nil,
        initialGoal: String? = nil,
        recentTurns: [TranscriptTurnDigest] = [],
        touchedFiles: [String] = [],
        recentTools: [String] = [],
        gitBranch: String? = nil,
        gitChangedCount: Int = 0
    ) {
        self.sessionTitle = sessionTitle
        self.initialGoal = initialGoal
        self.recentTurns = recentTurns
        self.touchedFiles = touchedFiles
        self.recentTools = recentTools
        self.gitBranch = gitBranch
        self.gitChangedCount = gitChangedCount
    }

    public var isEmpty: Bool {
        sessionTitle == nil
            && initialGoal == nil
            && recentTurns.isEmpty
            && touchedFiles.isEmpty
            && recentTools.isEmpty
            && gitBranch == nil
            && gitChangedCount == 0
    }
}

/// Terminal outcome delivered to a waiting `ask-wait` client.
public struct AskWaitOutcome: Sendable, Equatable {
    public var status: String
    public var answers: [AskAnswer]
    public var note: String?

    public init(status: String, answers: [AskAnswer] = [], note: String? = nil) {
        self.status = status
        self.answers = answers
        self.note = note
    }
}

/// Errors thrown when creating an ask session fails capacity or identity checks.
public enum AskSessionError: Error, Equatable, CustomStringConvertible {
    case paneCapacityExceeded(Int)
    case globalCapacityExceeded(Int)
    case duplicateSessionID(String)

    public var description: String {
        switch self {
        case .paneCapacityExceeded(let cap):
            return "pending ask limit reached for this pane (\(cap))"
        case .globalCapacityExceeded(let cap):
            return "global pending ask limit reached (\(cap))"
        case .duplicateSessionID(let id):
            return "duplicate ask session id: \(id)"
        }
    }
}

/// Observable ask session bound to a single pane with editable answer drafts.
@MainActor
@Observable
public final class AskSession: Identifiable {
    public let id: String
    public let paneID: String
    public let createdInsidePane: Bool
    public let spec: AskSpec
    public var context: AskSessionContext?
    public var isLoadingContext: Bool
    public var loadedFileRefs: [String: [AskFileRefResult]]
    public var loadedGitDiffs: [String: [AskGitDiffRefResult]]
    public var draftSelected: [String: [String]]
    public var draftFreeText: [String: String]

    public init(
        id: String,
        paneID: String,
        createdInsidePane: Bool,
        spec: AskSpec,
        isLoadingContext: Bool = false
    ) {
        self.id = id
        self.paneID = paneID
        self.createdInsidePane = createdInsidePane
        self.spec = spec
        self.isLoadingContext = isLoadingContext
        self.loadedFileRefs = [:]
        self.loadedGitDiffs = [:]
        self.draftSelected = [:]
        self.draftFreeText = [:]
    }

    public func isQuestionAnswered(_ q: AskQuestion) -> Bool {
        if !(draftSelected[q.id] ?? []).isEmpty { return true }
        if q.allowFreeText {
            let trimmed = (draftFreeText[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return true }
        }
        return false
    }

    public var answeredCount: Int {
        spec.questions.reduce(0) { $0 + (isQuestionAnswered($1) ? 1 : 0) }
    }

    public var isAllAnswered: Bool {
        !spec.questions.isEmpty && answeredCount == spec.questions.count
    }

    public var firstUnansweredQuestionID: String? {
        spec.questions.first { !isQuestionAnswered($0) }?.id
    }

    public func buildAnswers() -> [AskAnswer] {
        spec.questions.map { q in
            AskAnswer(
                id: q.id,
                header: q.header,
                question: q.question,
                selected: draftSelected[q.id] ?? [],
                freeText: (draftFreeText[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

/// Coordinates per-pane FIFO ask queues, waiter attachment, cancellation, and short-lived outcome caching.
@MainActor
@Observable
public final class AskSessionStore {
    public static let maxPendingPerPane = 16
    public static let maxPendingGlobal = 64
    public static let cacheTTL: TimeInterval = 600
    public static let maxCachedOutcomes = 32

    private struct Waiter {
        let token: UUID
        let reply: (AskWaitOutcome) -> Void
    }

    private struct CachedOutcome {
        let sessionID: String
        let paneID: String
        let createdInsidePane: Bool
        let outcome: AskWaitOutcome
        let recordedAt: Date
    }

    private var paneQueues: [String: [String]] = [:]
    private var sessionsByID: [String: AskSession] = [:]
    private var waitersByID: [String: Waiter] = [:]
    private var cachedOutcomes: [CachedOutcome] = []
    private let now: () -> Date

    public var onChange: (() -> Void)?

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public var totalPendingCount: Int {
        sessionsByID.count
    }

    public func pendingCount(for paneID: String) -> Int {
        paneQueues[paneID]?.count ?? 0
    }

    public func activeSession(for paneID: String) -> AskSession? {
        guard let firstID = paneQueues[paneID]?.first else { return nil }
        return sessionsByID[firstID]
    }

    public func session(id: String) -> AskSession? {
        sessionsByID[id]
    }

    public func cachedOutcomeMeta(sessionID: String) -> (paneID: String, createdInsidePane: Bool)? {
        pruneExpiredCache()
        guard let hit = cachedOutcomes.first(where: { $0.sessionID == sessionID }) else { return nil }
        return (hit.paneID, hit.createdInsidePane)
    }

    public static func randomSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func create(
        spec: AskSpec,
        paneID: String,
        createdInsidePane: Bool,
        sessionID: String? = nil
    ) throws -> AskSession {
        let id = sessionID ?? Self.randomSessionID()
        guard sessionsByID[id] == nil else {
            throw AskSessionError.duplicateSessionID(id)
        }
        guard (paneQueues[paneID]?.count ?? 0) < Self.maxPendingPerPane else {
            throw AskSessionError.paneCapacityExceeded(Self.maxPendingPerPane)
        }
        guard sessionsByID.count < Self.maxPendingGlobal else {
            throw AskSessionError.globalCapacityExceeded(Self.maxPendingGlobal)
        }
        let session = AskSession(id: id, paneID: paneID, createdInsidePane: createdInsidePane, spec: spec)
        sessionsByID[id] = session
        paneQueues[paneID, default: []].append(id)
        onChange?()
        return session
    }

    /// Attaches a waiter to `sessionID` or delivers an unclaimed cached outcome immediately.
    /// Returns a detach closure that cleans up only this waiter handle without removing the form.
    @discardableResult
    public func attachWaiter(
        sessionID: String,
        reply: @escaping (AskWaitOutcome) -> Void
    ) -> (() -> Void)? {
        pruneExpiredCache()
        if let cachedIdx = cachedOutcomes.firstIndex(where: { $0.sessionID == sessionID }) {
            let entry = cachedOutcomes.remove(at: cachedIdx)
            reply(entry.outcome)
            return nil
        }

        guard sessionsByID[sessionID] != nil else {
            reply(AskWaitOutcome(status: "not_found", note: "Session not found or expired"))
            return nil
        }

        if let previous = waitersByID.removeValue(forKey: sessionID) {
            previous.reply(AskWaitOutcome(status: "superseded", note: "Waiter superseded by newer request"))
        }

        let token = UUID()
        waitersByID[sessionID] = Waiter(token: token, reply: reply)
        return { [weak self] in
            self?.detachWaiter(sessionID: sessionID, token: token)
        }
    }

    @discardableResult
    public func submit(sessionID: String) -> Bool {
        guard let session = sessionsByID[sessionID], session.isAllAnswered else { return false }
        let outcome = AskWaitOutcome(status: "submitted", answers: session.buildAnswers())
        resolveSession(sessionID, outcome: outcome)
        return true
    }

    public func cancel(sessionID: String, note: String = "User cancelled the ask prompt.") {
        guard sessionsByID[sessionID] != nil else { return }
        resolveSession(sessionID, outcome: AskWaitOutcome(status: "cancelled", note: note))
    }

    public func markPaneClosed(_ paneID: String) {
        let ids = paneQueues[paneID] ?? []
        for id in ids {
            resolveSession(id, outcome: AskWaitOutcome(status: "lost", note: "Source pane closed before submission."))
        }
    }

    public func markAllLost() {
        let ids = Array(sessionsByID.keys)
        for id in ids {
            resolveSession(id, outcome: AskWaitOutcome(status: "lost", note: "Application terminated before submission."))
        }
    }

    private func detachWaiter(sessionID: String, token: UUID) {
        guard waitersByID[sessionID]?.token == token else { return }
        waitersByID.removeValue(forKey: sessionID)
    }

    private func resolveSession(_ sessionID: String, outcome: AskWaitOutcome) {
        guard let session = sessionsByID.removeValue(forKey: sessionID) else { return }
        if var queue = paneQueues[session.paneID] {
            queue.removeAll { $0 == sessionID }
            if queue.isEmpty {
                paneQueues.removeValue(forKey: session.paneID)
            } else {
                paneQueues[session.paneID] = queue
            }
        }
        if let waiter = waitersByID.removeValue(forKey: sessionID) {
            waiter.reply(outcome)
        } else {
            recordCachedOutcome(
                sessionID: sessionID,
                paneID: session.paneID,
                createdInsidePane: session.createdInsidePane,
                outcome: outcome
            )
        }
        onChange?()
    }

    private func recordCachedOutcome(sessionID: String, paneID: String, createdInsidePane: Bool, outcome: AskWaitOutcome) {
        pruneExpiredCache()
        cachedOutcomes.removeAll { $0.sessionID == sessionID }
        while cachedOutcomes.count >= Self.maxCachedOutcomes {
            cachedOutcomes.removeFirst()
        }
        cachedOutcomes.append(CachedOutcome(
            sessionID: sessionID,
            paneID: paneID,
            createdInsidePane: createdInsidePane,
            outcome: outcome,
            recordedAt: now()
        ))
    }

    private func pruneExpiredCache() {
        let cutoff = now().addingTimeInterval(-Self.cacheTTL)
        cachedOutcomes.removeAll { $0.recordedAt < cutoff }
    }
}
