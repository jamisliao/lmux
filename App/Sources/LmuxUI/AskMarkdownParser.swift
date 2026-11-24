import Foundation

/// Block-level AST nodes parsed from question Markdown strings for native SwiftUI rendering.
public enum AskMarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletItem(String)
    case numberedItem(prefix: String, text: String)
    case blockquote(String)
    case codeBlock(language: String?, code: String)
    case diffBlock([GitDiffLine])
}

/// Pure Swift block-level Markdown parser supporting paragraphs, lists, quotes, headings, code, and unified diff fences.
public enum AskMarkdownParser {
    private static let numberedRE = try? NSRegularExpression(pattern: #"^(\d+[.)])\s+(.+)$"#)

    public static func parse(_ text: String) -> [AskMarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var blocks: [AskMarkdownBlock] = []
        var paragraphLines: [String] = []
        var inFence = false
        var fenceLang: String?
        var fenceLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let joined = paragraphLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushFence() {
            let lang = fenceLang?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLang = (lang?.isEmpty == false) ? lang?.lowercased() : nil
            let rawCode = fenceLines.joined(separator: "\n")
            if normalizedLang == "diff" || normalizedLang == "patch" {
                blocks.append(.diffBlock(parseDiffLines(fenceLines)))
            } else {
                blocks.append(.codeBlock(language: normalizedLang, code: rawCode))
            }
            inFence = false
            fenceLang = nil
            fenceLines.removeAll(keepingCapacity: true)
        }

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if inFence {
                if trimmed.hasPrefix("```") {
                    flushFence()
                } else {
                    fenceLines.append(rawLine)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                inFence = true
                let langPart = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fenceLang = langPart.isEmpty ? nil : langPart
                fenceLines.removeAll(keepingCapacity: true)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let quote = parseBlockquote(trimmed) {
                flushParagraph()
                blocks.append(.blockquote(quote))
                continue
            }

            if let bullet = parseBullet(trimmed) {
                flushParagraph()
                blocks.append(.bulletItem(bullet))
                continue
            }

            if let numbered = parseNumbered(trimmed) {
                flushParagraph()
                blocks.append(.numberedItem(prefix: numbered.prefix, text: numbered.text))
                continue
            }

            paragraphLines.append(rawLine)
        }

        if inFence {
            flushFence()
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var hashes = 0
        for ch in line {
            if ch == "#" && hashes < 6 {
                hashes += 1
            } else {
                break
            }
        }
        guard hashes > 0, line.count > hashes else { return nil }
        let restStart = line.index(line.startIndex, offsetBy: hashes)
        guard line[restStart] == " " else { return nil }
        let text = String(line[line.index(after: restStart)...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func parseBlockquote(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private static func parseBullet(_ line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") else { return nil }
        let body = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private static func parseNumbered(_ line: String) -> (prefix: String, text: String)? {
        guard let re = numberedRE else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = re.firstMatch(in: line, range: range),
              let r1 = Range(match.range(at: 1), in: line),
              let r2 = Range(match.range(at: 2), in: line) else {
            return nil
        }
        let body = String(line[r2]).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : (String(line[r1]), body)
    }

    private static func parseDiffLines(_ lines: [String]) -> [GitDiffLine] {
        var out: [GitDiffLine] = []
        var seenHunk = false
        for (idx, line) in lines.enumerated() {
            if !seenHunk && (line.hasPrefix("diff --git ") || line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")) {
                continue
            }
            let kind: GitDiffLine.Kind
            if line.hasPrefix("@@") {
                seenHunk = true
                kind = .hunkHeader
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .context
            }
            out.append(GitDiffLine(id: idx + 1, kind: kind, text: line))
        }
        return out
    }
}
