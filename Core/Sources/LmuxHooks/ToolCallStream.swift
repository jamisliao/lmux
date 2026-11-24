import Foundation

public enum ToolCategory: String, Sendable, Equatable, CaseIterable {
    case read
    case edit
    case bash
    case search
    case other

    public static func from(name: String) -> ToolCategory {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        switch n {
        case "read", "view":
            return .read
        case "edit", "write", "multiedit", "notebookedit":
            return .edit
        case "bash", "run":
            return .bash
        case "grep", "glob", "search", "websearch", "webfetch", "toolsearch", "searchtools":
            return .search
        default:
            return .other
        }
    }
}

public enum ToolStatus: String, Sendable, Equatable {
    case running
    case succeeded
    case failed
    case interrupted
}

public struct ToolCallEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var toolUseID: String?
    public var name: String
    public var category: ToolCategory
    public var argument: String?
    public var status: ToolStatus
    public var startedAtNanos: UInt64
    public var durationMs: Int?

    public init(
        id: String,
        name: String,
        category: ToolCategory,
        argument: String? = nil,
        status: ToolStatus = .running,
        startedAtNanos: UInt64,
        durationMs: Int? = nil,
        toolUseID: String? = nil
    ) {
        self.id = id
        self.toolUseID = toolUseID
        self.name = name
        self.category = category
        self.argument = argument
        self.status = status
        self.startedAtNanos = startedAtNanos
        self.durationMs = durationMs
    }
}

public struct ToolCallStream: Sendable, Equatable {
    public private(set) var entries: [ToolCallEntry] = []
    public static let cap = 50
    public private(set) var turnCount: Int = 0

    public init() {}

    /// Marks any `.running` entries with `finalStatus` and records elapsed durations.
    public mutating func finalizeRunning(as finalStatus: ToolStatus, at nowNanos: UInt64? = nil) {
        let resolvedNow = nowNanos ?? unixNanosNow()
        for i in entries.indices where entries[i].status == .running {
            entries[i].status = finalStatus
            if entries[i].durationMs == nil {
                let dur = resolvedNow >= entries[i].startedAtNanos ? resolvedNow - entries[i].startedAtNanos : 0
                entries[i].durationMs = Int(dur / 1_000_000)
            }
        }
    }

    public mutating func record(_ event: HookEvent) {
        let kind = event.kind
        if kind == .userPromptSubmit {
            turnCount += 1
            return
        }

        let nowNanos = event.sentAtNanos ?? event.receivedAtNanos ?? unixNanosNow()

        if kind == .preToolUse {
            let name = event.toolName ?? "unknown"
            let cat = ToolCategory.from(name: name)
            let rawID = event.toolUseID?.isEmpty == false ? event.toolUseID : nil
            let id = (rawID.flatMap { candidate in entries.contains(where: { $0.id == candidate }) ? nil : candidate }) ?? UUID().uuidString
            let entry = ToolCallEntry(
                id: id,
                name: name,
                category: cat,
                argument: event.toolArgument,
                status: .running,
                startedAtNanos: nowNanos,
                toolUseID: rawID
            )
            entries.append(entry)
            if entries.count > Self.cap {
                entries.removeFirst(entries.count - Self.cap)
            }
            return
        }

        if kind == .postToolUse || kind == .postToolUseFailure {
            let status: ToolStatus = (kind == .postToolUseFailure || event.name == HookEvent.Kind.postToolUseFailure.rawValue) ? .failed : .succeeded
            let matchIndex: Int? = {
                if let uid = event.toolUseID, !uid.isEmpty {
                    return entries.lastIndex(where: { $0.status == .running && ($0.toolUseID == uid || $0.id == uid) })
                        ?? entries.lastIndex(where: { $0.toolUseID == uid || $0.id == uid })
                }
                if let name = event.toolName {
                    return entries.lastIndex(where: { $0.status == .running && $0.name.caseInsensitiveCompare(name) == .orderedSame })
                }
                return entries.lastIndex(where: { $0.status == .running })
            }()

            if let idx = matchIndex {
                let dur = nowNanos >= entries[idx].startedAtNanos ? nowNanos - entries[idx].startedAtNanos : 0
                entries[idx].durationMs = Int(dur / 1_000_000)
                entries[idx].status = status
                if (entries[idx].argument ?? "").isEmpty, let arg = event.toolArgument, !arg.isEmpty {
                    entries[idx].argument = arg
                }
            }
            return
        }

        if kind == .interrupt || (!event.isSubagent && (kind == .stop || kind == .stopFailure)) {
            let finalStatus: ToolStatus = kind == .interrupt ? .interrupted : (kind == .stopFailure ? .failed : .succeeded)
            finalizeRunning(as: finalStatus, at: nowNanos)
            return
        }
    }
}
