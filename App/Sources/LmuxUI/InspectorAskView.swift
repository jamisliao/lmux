import AppKit
import LmuxTokens
import SwiftUI

private typealias T = LmuxTokens

/// Pure native SwiftUI multi-question form displayed inside the dynamic `.ask` Inspector tab.
public struct InspectorAskView: View {
    public struct Presentation: Equatable, Sendable {
        public let queuePosition: Int
        public let queueCount: Int
        public let answeredCount: Int
        public let totalCount: Int
        public let unansweredCount: Int
        public let canSubmit: Bool
        public let submitLabel: String
    }

    @Bindable public var session: AskSession
    public let queueCount: Int
    public var onOpenPreview: ((URL) -> Void)?
    public var onSubmit: () -> Void
    public var onCancel: () -> Void

    public init(
        session: AskSession,
        queueCount: Int,
        onOpenPreview: ((URL) -> Void)? = nil,
        onSubmit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.queueCount = queueCount
        self.onOpenPreview = onOpenPreview
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public static func presentation(for session: AskSession, queueCount: Int) -> Presentation {
        let total = session.spec.questions.count
        let answered = session.answeredCount
        let unanswered = max(0, total - answered)
        let canSubmit = session.isAllAnswered
        let label = canSubmit ? "送出全部回答 (⌘↩)" : "還有 \(unanswered) 題未答"
        return Presentation(
            queuePosition: queueCount > 0 ? 1 : 0,
            queueCount: queueCount,
            answeredCount: answered,
            totalCount: total,
            unansweredCount: unanswered,
            canSubmit: canSubmit,
            submitLabel: label
        )
    }

    public static func toggleOption(_ label: String, in question: AskQuestion, session: AskSession) {
        var current = session.draftSelected[question.id] ?? []
        if question.multiSelect {
            if let idx = current.firstIndex(of: label) {
                current.remove(at: idx)
            } else {
                current.append(label)
            }
        } else {
            current = (current == [label]) ? [] : [label]
        }
        session.draftSelected[question.id] = current
    }

    public var body: some View {
        let pres = Self.presentation(for: session, queueCount: queueCount)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        headerSection(pres)
                        AskContextCardView(
                            context: session.context,
                            isLoading: session.isLoadingContext,
                            lenient: session.spec.lenient,
                            intro: session.spec.intro
                        )
                        if session.spec.questions.count > 1 {
                            jumpChips(proxy: proxy)
                        }
                        ForEach(Array(session.spec.questions.enumerated()), id: \.element.id) { idx, question in
                            questionCard(index: idx + 1, question: question)
                                .id(question.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.scrollToQuestionID) { _, targetID in
                    guard let targetID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(targetID, anchor: .top)
                    }
                    session.scrollToQuestionID = nil
                }
            }

            Divider().overlay(T.Colors.glassBorder.color)
            footerBar(pres)
        }
    }

    private func headerSection(_ pres: Presentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !session.spec.eyebrow.isEmpty {
                    Text(session.spec.eyebrow)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(T.Colors.accent.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(T.Colors.accent.color.opacity(0.14)))
                }
                if pres.queueCount > 1 {
                    Text("佇列 \(pres.queuePosition) / \(pres.queueCount)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(T.Colors.textSecondary.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(T.Colors.glassSurfaceRecessed.color))
                }
                Spacer()
                Text("\(pres.answeredCount)/\(pres.totalCount)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundColor(T.Colors.textSecondary.color)
            }

            Text(session.spec.title.isEmpty ? "待確認問題" : session.spec.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(T.Colors.textPrimary.color)

            AskMarkdownBlocksView(session.spec.intro)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.Colors.glassCard.color))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5))
    }

    private func jumpChips(proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(session.spec.questions.enumerated()), id: \.element.id) { idx, q in
                    let done = session.isQuestionAnswered(q)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(q.id, anchor: .top)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 9.5))
                                .foregroundColor(done ? T.Colors.diffAddedFg.color : T.Colors.textTertiary.color)
                            Text(q.header.isEmpty ? "Q\(idx + 1)" : q.header)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(T.Colors.textPrimary.color)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(T.Colors.glassCard.color))
                        .overlay(Capsule().strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func questionCard(index: Int, question: AskQuestion) -> some View {
        let selected = session.draftSelected[question.id] ?? []
        let freeBinding = Binding<String>(
            get: { session.draftFreeText[question.id] ?? "" },
            set: { session.draftFreeText[question.id] = $0 }
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Q\(index)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundColor(T.Colors.textSecondary.color)
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(T.Colors.accent.color)
                }
                Spacer()
                Text(question.multiSelect ? "多選" : (question.options.isEmpty ? "開放" : "單選"))
                    .font(.system(size: 9.5))
                    .foregroundColor(T.Colors.textTertiary.color)
            }

            Text(question.question)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(T.Colors.textPrimary.color)

            if !question.detail.isEmpty {
                AskMarkdownBlocksView(question.detail)
            }
            if let mermaid = question.mermaid {
                AskMermaidCardView(code: mermaid)
            }
            ForEach(session.loadedFileRefs[question.id] ?? []) { ref in
                AskRefCardView(fileRef: ref, onOpenPreview: onOpenPreview)
            }
            ForEach(session.loadedGitDiffs[question.id] ?? []) { diff in
                AskRefCardView(gitDiffRef: diff)
            }

            if !question.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(question.options, id: \.label) { opt in
                        optionRow(opt, selected: selected.contains(opt.label), multiSelect: question.multiSelect) {
                            Self.toggleOption(opt.label, in: question, session: session)
                        }
                    }
                }
            }

            if question.allowFreeText {
                VStack(alignment: .leading, spacing: 4) {
                    Text("補充說明")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(T.Colors.textSecondary.color)
                    TextEditor(text: freeBinding)
                        .font(.system(size: 11.5))
                        .frame(minHeight: 54, maxHeight: 110)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(T.Colors.glassSurfaceRecessed.color))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.Colors.glassCard.color))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.Colors.glassBorder.color, lineWidth: 0.5))
    }

    private func optionRow(
        _ opt: AskOption,
        selected: Bool,
        multiSelect: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: multiSelect
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 12))
                    .foregroundColor(selected ? T.Colors.accent.color : T.Colors.textTertiary.color)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(opt.label)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                            .foregroundColor(T.Colors.textPrimary.color)
                        if opt.recommended {
                            Text("推薦")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(T.Colors.accent.color.opacity(0.18)))
                                .foregroundColor(T.Colors.accent.color)
                        }
                    }
                    if !opt.description.isEmpty {
                        Text(opt.description)
                            .font(.system(size: 10.5))
                            .foregroundColor(T.Colors.textSecondary.color)
                    }
                }
                Spacer()
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? T.Colors.glassCardSelected.color : T.Colors.glassSurfaceRecessed.color.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? T.Colors.accent.color.opacity(0.6) : T.Colors.glassBorder.color, lineWidth: 0.75)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func footerBar(_ pres: Presentation) -> some View {
        HStack(spacing: 8) {
            Button("取消", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)

            Spacer()

            Button(pres.submitLabel, action: onSubmit)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!pres.canSubmit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(T.Colors.glassSurfaceRecessed.color.opacity(0.35))
    }
}
