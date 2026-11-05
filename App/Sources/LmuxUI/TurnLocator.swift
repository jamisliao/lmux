import Foundation

/// Maps the visible rows of a pane running Claude Code to the session's turns.
///
/// Claude Code draws a past prompt as a marker (`>`/`❯`) followed by the prompt's first
/// line (a `!` shell command as `! cmd`), its continuation rows indented below it, and replies as `●`/`⏺` bullets. The
/// screen alone can't tell a prompt from a permission menu (`❯ 1. Yes`) or the input box
/// (`> draft…`), so a marker row only counts as a prompt when its text matches a turn's
/// prompt from the transcript. Matching runs bottom-up with strictly decreasing turn
/// indices, so repeated prompts ("continue") resolve to the right turn and the order on
/// screen always agrees with the transcript. The input box (marker row right below a
/// `────` rule) is never a prompt. A row drawn like a past prompt (the marker in the first column)
/// that matches no turn's text is that turn only when the order leaves no doubt (one turn missing
/// between two matched prompts, one such row); otherwise it ends the turn above it, so a turn's
/// rows never take in another prompt's.
public struct TurnLocator {
    public struct PromptTurn: Equatable, Sendable {
        public let index: Int
        public let prompt: String
        public let hasReply: Bool
        public init(index: Int, prompt: String, hasReply: Bool) {
            self.index = index
            self.prompt = prompt
            self.hasReply = hasReply
        }
    }

    public enum Role: Equatable, Sendable {
        case none
        /// A row of the prompt of turn `turn`; `head` is the row its marker is on.
        case prompt(turn: Int, head: Int)
        /// A reply bullet (or its continuation) inside turn `turn`.
        case reply(turn: Int)
        /// Claude's input box.
        case input
    }

    public struct Map: Equatable, Sendable {
        public var roles: [Role]
        /// Row of the rule above the input box (where the "sending to" label goes).
        public var inputRule: Int?
        /// Row of the input line itself.
        public var inputRow: Int?
        /// The turn every row belongs to (its prompt, tool calls, output and reply, up to the next
        /// prompt); nil for the input box and rows no visible prompt accounts for.
        public var turnOfRow: [Int?] = []

        /// The visible rows of `turn`: its first and last non-blank row.
        public func block(of turn: Int, rows: [String]) -> (first: Int, last: Int)? {
            var first: Int?, last: Int?
            for (i, t) in turnOfRow.enumerated() where t == turn && !rows[i].trimmingCharacters(in: .whitespaces).isEmpty {
                if first == nil { first = i }
                last = i
            }
            guard let first, let last else { return nil }
            return (first, last)
        }

        public func promptHeads() -> [(row: Int, turn: Int)] {
            roles.enumerated().compactMap { i, r in
                if case .prompt(let t, let h) = r, h == i { return (i, t) }
                return nil
            }
        }
    }

    static let promptMarkers: Set<Character> = [">", "❯", "›"]
    static let replyMarkers: Set<Character> = ["●", "⏺"]

    /// `(marker, text after it)` if the row starts (after up to 2 spaces or a box edge) with a marker and a space.
    static func marked(_ row: String, _ markers: Set<Character>) -> String? {
        var s = Substring(row)
        if s.first == "│" { s = s.dropFirst() }
        let lead = s.prefix { $0 == " " }
        guard lead.count <= 2 else { return nil }
        s = s.dropFirst(lead.count)
        guard let m = s.first, markers.contains(m) else { return nil }
        s = s.dropFirst()
        guard s.first == " " || s.first == "\u{00A0}" else { return nil }
        var t = String(s.dropFirst())
        if t.hasSuffix("│") { t.removeLast() }
        return t
    }

    static func isRule(_ row: String) -> Bool {
        let t = row.trimmingCharacters(in: .whitespaces)
        guard t.count >= 8 else { return false }
        let rule = t.filter { "─━╭╮╰╯".contains($0) }.count
        return rule * 10 >= t.count * 8
    }

    /// Takes two terminal cells (East Asian wide: Hangul, CJK, fullwidth forms).
    static func isWide(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
             0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    static func norm(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// A transcript prompt as the hook reported it: its text without the "[image]" / "[document]"
    /// line each attachment block adds (the hook's prompt has only the text, `[Image #1] …`).
    static func normText(_ prompt: String) -> String {
        norm(prompt.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !["[image]", "[document]"].contains($0) }.joined(separator: "\n"))
    }

    /// The row text (possibly cut by wrapping) is the start of the prompt's first line.
    static func matches(row: String, prompt: String) -> Bool {
        let r = norm(row)
        guard !r.isEmpty else { return false }
        // A prompt with an image is its text plus "[image]" per image block, and Claude Code may put
        // the image block first; the screen shows the text (`[Image #1] …`), so placeholders are skipped.
        let first = norm(prompt.split(separator: "\n", omittingEmptySubsequences: true)
            .first { !["[image]", "[document]"].contains($0) }.map(String.init) ?? "")
        guard !first.isEmpty else { return false }
        if r == first { return true }
        // Wrapped: a row that is a strict prefix must be long enough to be meaningful.
        return r.count >= 8 && first.hasPrefix(r)
    }

    /// Claude Code's line under a finished turn: "✻ Crunched for 3s · done Wednesday 11:42 PM".
    static func isDoneLine(_ row: String) -> Bool {
        guard let m = row.first, !m.isWhitespace, !m.isLetter, !replyMarkers.contains(m), !promptMarkers.contains(m),
              row.dropFirst().first == " " else { return false }
        return row.contains(" for ") && row.contains(" · done ")
    }

    static let toolCall = try! NSRegularExpression(pattern: #"^[A-Z][A-Za-z0-9_]*(\(|$)"#)

    public static func locate(rows: [String], turns: [PromptTurn]) -> Map {
        let n = rows.count
        var roles = [Role](repeating: .none, count: n)
        var turnOfRow = [Int?](repeating: nil, count: n)

        // Input box: the last marker row whose previous row is a rule.
        var inputRow: Int?, inputRule: Int?
        for i in stride(from: n - 1, through: 1, by: -1) where marked(rows[i], promptMarkers) != nil && isRule(rows[i - 1]) {
            inputRow = i; inputRule = i - 1; break
        }
        let limit = inputRule ?? n
        if let ir = inputRule { for i in ir..<n { roles[i] = .input } }

        // Prompt heads, bottom-up, strictly decreasing turn index.
        var bound = Int.max
        var heads: [(row: Int, turn: Int)] = []
        // Rows drawn like a past prompt (the marker in the first column) that match no turn: a prompt
        // the turn list doesn't have, a slash command, a queued message. Whatever came before ends there.
        var unmatched: Set<Int> = []
        for i in stride(from: limit - 1, through: 0, by: -1) {
            // A `!` shell command is drawn as "! cmd" (no prompt marker); it only matches such a turn.
            let shell = marked(rows[i], ["!"])
            guard let text = marked(rows[i], promptMarkers) ?? shell else { continue }
            let candidates = turns.filter { $0.index < bound && RewindMenu.isShellCommand($0.prompt) == (shell != nil) }
            if let t = candidates.filter({ matches(row: text, prompt: shell == nil ? $0.prompt : String(RewindMenu.shown($0.prompt).dropFirst(2))) })
                .max(by: { $0.index < $1.index }) {
                heads.append((i, t.index))
                bound = t.index
            } else if let m = rows[i].first, promptMarkers.contains(m) || m == "!" {
                unmatched.insert(i)
            }
        }
        heads.reverse()
        // An unmatched row is a turn's after all when the turn list has exactly as many turns between
        // the matched prompts around it as there are such rows (a pasted prompt drawn as "[Pasted text
        // #1 …]", a slash command), of the same kind ("! cmd" only for a shell command), in order.
        // Above the first matched prompt, the turns right before it; below the last, the turns after it.
        // Anything else stays unmatched.
        if !heads.isEmpty, !unmatched.isEmpty {
            let indices = turns.map(\.index)
            let byIndex = Dictionary(uniqueKeysWithValues: turns.map { ($0.index, $0) })
            var found: [(row: Int, turn: Int)] = []
            for k in 0...heads.count {
                let lo = k == 0 ? -1 : heads[k - 1].row, hi = k == heads.count ? limit : heads[k].row
                let gap = unmatched.filter { $0 > lo && $0 < hi }.sorted()
                guard !gap.isEmpty else { continue }
                var missing: [Int]
                if k == 0 {
                    missing = Array(indices.filter { $0 < heads[0].turn }.suffix(gap.count))
                } else if k == heads.count {
                    missing = indices.filter { $0 > heads[k - 1].turn }
                } else {
                    missing = indices.filter { $0 > heads[k - 1].turn && $0 < heads[k].turn }
                }
                guard missing.count == gap.count, missing.last.map({ k == 0 ? $0 == heads[0].turn - 1 : true }) ?? false,
                      zip(gap, missing).allSatisfy({ (rows[$0].first == "!") == RewindMenu.isShellCommand(byIndex[$1]?.prompt ?? "") })
                else { continue }
                found += zip(gap, missing).map { ($0, $1) }
            }
            for f in found { unmatched.remove(f.row) }
            heads = (heads + found).sorted { $0.row < $1.row }
        }

        // Prompt blocks: the head plus the rows right below it that are indented and
        // non-empty (wrapped or multi-line prompt), up to the first blank or bullet row.
        var promptEnd: [Int: Int] = [:]
        for h in heads {
            var j = h.row + 1
            while j < limit, !rows[j].trimmingCharacters(in: .whitespaces).isEmpty,
                  rows[j].hasPrefix("  "), marked(rows[j], replyMarkers) == nil, marked(rows[j], promptMarkers) == nil {
                j += 1
            }
            for k in h.row..<j { roles[k] = .prompt(turn: h.turn, head: h.row) }
            promptEnd[h.row] = j
        }

        // Replies: text bullets (not tool calls) and their indented continuation, owned by
        // the nearest prompt above; rows above the first visible prompt belong to the turn before it.
        let byTurn = Dictionary(uniqueKeysWithValues: turns.map { ($0.index, $0) })
        var owner: Int? = heads.first.flatMap { h in unmatched.contains { $0 < h.row } ? nil : h.turn - 1 }
        var inReply = false
        var headIdx = 0
        var i = 0
        while i < limit {
            if headIdx < heads.count, heads[headIdx].row == i {
                owner = heads[headIdx].turn
                let end = promptEnd[i] ?? (i + 1)
                for k in i..<end { turnOfRow[k] = owner }
                i = end
                headIdx += 1
                inReply = false
                continue
            }
            let row = rows[i]
            if unmatched.contains(i) {
                owner = nil
                inReply = false
                i += 1
                continue
            }
            if let text = marked(row, replyMarkers) {
                let tool = toolCall.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                inReply = !tool
            } else if row.trimmingCharacters(in: .whitespaces).isEmpty {
                // Blank rows inside a reply (paragraph breaks) keep it open.
            } else if !row.hasPrefix("  ") {
                inReply = false
            }
            if inReply, let o = owner, byTurn[o]?.hasReply == true, !row.trimmingCharacters(in: .whitespaces).isEmpty {
                roles[i] = .reply(turn: o)
            }
            if let o = owner, byTurn[o] != nil { turnOfRow[i] = o }
            // "✻ Crunched for 3s · done 11:42 PM" closes a turn (2.1.280). What follows before the next
            // prompt is no turn's: after `claude --resume`, Claude also draws the replies of turns a
            // rewind removed there, which lmux's turns (the live branch) don't have.
            if Self.isDoneLine(row) { owner = nil; inReply = false }
            i += 1
        }
        // Claude's right-aligned notes right above its input box ("● high · /effort": indented, ending
        // where the rule ends) belong to no turn.
        if let ir = inputRule {
            func cells(_ s: String) -> Int {
                var t = Substring(s)
                while t.last == " " { t.removeLast() }
                return t.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
            }
            let ruleEnd = cells(rows[ir])
            var j = ir - 1
            while j >= max(0, ir - 2), rows[j].prefix(while: { $0 == " " }).count >= 8, !rows[j].trimmingCharacters(in: .whitespaces).isEmpty,
                  cells(rows[j]) >= ruleEnd - 4 {
                roles[j] = .none
                turnOfRow[j] = nil
                j -= 1
            }
        }
        return Map(roles: roles, inputRule: inputRule, inputRow: inputRow, turnOfRow: turnOfRow)
    }
}
