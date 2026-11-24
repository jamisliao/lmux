import AppKit
import GhosttyKit
import LmuxTerminal
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

/// Zero-token session context summary card with adaptive default disclosure state.
public struct AskContextCardView: View {
    public let context: AskSessionContext?
    public let isLoading: Bool
    @State private var isExpanded: Bool

    public init(context: AskSessionContext?, isLoading: Bool, lenient: Bool, intro: String) {
        self.context = context
        self.isLoading = isLoading
        _isExpanded = State(initialValue: Self.defaultExpanded(lenient: lenient, intro: intro))
    }

    public static func defaultExpanded(lenient: Bool, intro: String) -> Bool {
        lenient || intro.count < 80
    }

    public static func hasVisibleContent(_ context: AskSessionContext?) -> Bool {
        guard let context else { return false }
        return !context.isEmpty
    }

    public var body: some View {
        if isLoading || Self.hasVisibleContent(context) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Session 上下文補充")
                            .font(.system(size: 11, weight: .semibold))
                        if let branch = context?.gitBranch {
                            Text(branch)
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(T.Colors.glassSurfaceRecessed.color))
                                .foregroundColor(T.Colors.textSecondary.color)
                        }
                        if let count = context?.gitChangedCount, count > 0 {
                            Text("\(count) 變更")
                                .font(.system(size: 10))
                                .foregroundColor(T.Colors.stateNeedsInput.color)
                        }
                        Spacer()
                    }
                    .foregroundColor(T.Colors.textPrimary.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    if let ctx = context, !ctx.isEmpty {
                        expandedDetails(ctx)
                    } else if isLoading {
                        Text("正在抽取本地對話與工作區脈絡…")
                            .font(.system(size: 11))
                            .foregroundColor(T.Colors.textTertiary.color)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.Colors.glassCard.color))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func expandedDetails(_ ctx: AskSessionContext) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = ctx.sessionTitle {
                Text("任務：\(title)").font(.system(size: 11, weight: .medium)).foregroundColor(T.Colors.textPrimary.color)
            }
            if let goal = ctx.initialGoal {
                Text("目標：\(goal)").font(.system(size: 11)).foregroundColor(T.Colors.textSecondary.color).lineLimit(3)
            }
            if !ctx.touchedFiles.isEmpty {
                Text("異動檔：\(ctx.touchedFiles.prefix(6).joined(separator: "、"))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(T.Colors.textSecondary.color)
            }
            if !ctx.recentTools.isEmpty {
                Text("近期工具：\(ctx.recentTools.joined(separator: " · "))")
                    .font(.system(size: 10.5))
                    .foregroundColor(T.Colors.textTertiary.color)
                    .lineLimit(2)
            }
            ForEach(ctx.recentTurns, id: \.index) { turn in
                VStack(alignment: .leading, spacing: 1) {
                    Text("#\(turn.index) \(turn.promptSummary)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(T.Colors.textSecondary.color)
                        .lineLimit(2)
                    if let reply = turn.replySummary {
                        Text(reply).font(.system(size: 10)).foregroundColor(T.Colors.textTertiary.color).lineLimit(2)
                    }
                }
            }
        }
    }
}

/// Renders parsed Markdown blocks purely natively with inline links routed through `GhosttyRuntime`.
public struct AskMarkdownBlocksView: View {
    public let blocks: [AskMarkdownBlock]

    public init(_ markdown: String) {
        self.blocks = AskMarkdownParser.parse(markdown)
    }

    public static func isAllowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            return false
        }
        if (scheme == "http" || scheme == "https"), (url.host?.isEmpty ?? true) {
            return false
        }
        return !url.path.lowercased().hasSuffix(".app")
    }

    public static func handleOpenURL(
        _ url: URL,
        window: NSWindow?,
        opener: (String, ghostty_action_open_url_kind_e, NSWindow?) -> Void = { value, kind, win in
            GhosttyRuntime.openTerminalURL(value, kind: kind, window: win)
        }
    ) -> OpenURLAction.Result {
        guard isAllowedURL(url) else { return .handled }
        opener(url.absoluteString, GHOSTTY_ACTION_OPEN_URL_KIND_OSC8, window)
        return .handled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            Self.handleOpenURL(url, window: NSApp.keyWindow ?? NSApp.mainWindow)
        })
    }

    @ViewBuilder
    private func blockView(_ block: AskMarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: level <= 2 ? 12.5 : 11.5, weight: .semibold))
                .foregroundColor(T.Colors.textPrimary.color)
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 11.5))
                .foregroundColor(T.Colors.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        case .bulletItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").font(.system(size: 11, weight: .bold)).foregroundColor(T.Colors.textTertiary.color)
                inlineText(text).font(.system(size: 11.5)).foregroundColor(T.Colors.textSecondary.color)
            }
        case .numberedItem(let prefix, let text):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(prefix).font(.system(size: 11, design: .monospaced)).foregroundColor(T.Colors.textTertiary.color)
                inlineText(text).font(.system(size: 11.5)).foregroundColor(T.Colors.textSecondary.color)
            }
        case .blockquote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(T.Colors.accent.color.opacity(0.6)).frame(width: 2)
                inlineText(text).font(.system(size: 11)).foregroundColor(T.Colors.textSecondary.color)
            }
        case .codeBlock(let lang, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let lang { Text(lang).font(.system(size: 9.5, design: .monospaced)).foregroundColor(T.Colors.textTertiary.color) }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(.system(size: 10.5, design: .monospaced)).foregroundColor(T.Colors.textPrimary.color)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.Colors.glassSurfaceRecessed.color))
        case .diffBlock(let lines):
            AskDiffLinesView(lines: lines)
        }
    }

    private func inlineText(_ raw: String) -> Text {
        if let attr = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(raw)
    }
}

struct AskDiffLinesView: View {
    let lines: [GitDiffLine]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(fg(line.kind))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bg(line.kind))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(T.Colors.glassSurfaceRecessed.color.opacity(0.5)))
    }

    private func fg(_ kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: return T.Colors.diffAddedFg.color
        case .removed: return T.Colors.diffRemovedFg.color
        case .hunkHeader: return T.Colors.textTertiary.color
        case .context: return T.Colors.textPrimary.color
        }
    }

    private func bg(_ kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: return T.Colors.diffAddedBg.color
        case .removed: return T.Colors.diffRemovedBg.color
        case .hunkHeader: return T.Colors.glassSurfaceRecessed.color.opacity(0.45)
        case .context: return .clear
        }
    }
}

/// Renders either local file snippet references (`refs`) or single-file diffs (`gitDiff`).
public struct AskRefCardView: View {
    public let fileRef: AskFileRefResult?
    public let gitDiffRef: AskGitDiffRefResult?
    public var onOpenPreview: ((URL) -> Void)?
    @State private var unsupportedHint = false

    public init(fileRef: AskFileRefResult, onOpenPreview: ((URL) -> Void)? = nil) {
        self.fileRef = fileRef
        self.gitDiffRef = nil
        self.onOpenPreview = onOpenPreview
    }

    public init(gitDiffRef: AskGitDiffRefResult) {
        self.fileRef = nil
        self.gitDiffRef = gitDiffRef
        self.onOpenPreview = nil
    }

    @discardableResult
    public static func handlePreviewTap(for ref: AskFileRefResult, onOpenPreview: ((URL) -> Void)?) -> Bool {
        guard let url = ref.resolvedURL, PreviewTarget.kind(url) != nil else { return false }
        onOpenPreview?(url)
        return true
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fileRef {
                HStack {
                    Button {
                        unsupportedHint = !Self.handlePreviewTap(for: fileRef, onOpenPreview: onOpenPreview)
                    } label: {
                        Text(fileRef.raw)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(fileRef.resolvedURL != nil ? T.Colors.accent.color : T.Colors.textSecondary.color)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                if let err = fileRef.errorMessage {
                    Text(err).font(.system(size: 10.5)).foregroundColor(T.Colors.stateNeedsInput.color)
                } else {
                    if unsupportedHint {
                        Text("此檔案格式不支援右側預覽").font(.system(size: 10)).foregroundColor(T.Colors.textTertiary.color)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(fileRef.lines.enumerated()), id: \.offset) { idx, line in
                                let lineNo = (fileRef.startLine ?? 1) + idx
                                Text("\(lineNo)  \(line)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(T.Colors.textPrimary.color)
                            }
                        }
                    }
                    if fileRef.truncated {
                        Text("已截斷至前 120 行").font(.system(size: 9.5)).foregroundColor(T.Colors.textTertiary.color)
                    }
                }
            } else if let gitDiffRef {
                Text("diff: \(gitDiffRef.relativePath)")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(T.Colors.textSecondary.color)
                if let err = gitDiffRef.errorMessage {
                    Text(err).font(.system(size: 10.5)).foregroundColor(T.Colors.stateNeedsInput.color)
                } else {
                    AskDiffLinesView(lines: gitDiffRef.lines)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.Colors.glassSurfaceRecessed.color.opacity(0.6)))
    }
}

/// Collapsible monospace Mermaid source card with clipboard copy (zero WebView usage).
public struct AskMermaidCardView: View {
    public let code: String
    @State private var isExpanded = false
    @State private var copied = false

    public init(code: String) {
        self.code = code
    }

    public static func copyMermaid(_ code: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9.5))
                        Text("Mermaid 圖表語法").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(T.Colors.textSecondary.color)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    Self.copyMermaid(code)
                    copied = true
                } label: {
                    Text(copied ? "已複製" : "複製語法")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(T.Colors.accent.color)
                }
                .buttonStyle(.plain)
            }
            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(.system(size: 10.5, design: .monospaced)).foregroundColor(T.Colors.textPrimary.color)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(T.Colors.glassSurfaceRecessed.color.opacity(0.6)))
    }
}
