import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

public struct InspectorDiffView: View {
    public enum DisplayState: Equatable {
        case notGitRepo
        case clean(branch: String?)
        case diff(branch: String?, fileCount: Int, added: Int, deleted: Int)
    }

    public let snapshot: GitDiffSnapshot
    public var onOpenPreview: ((URL) -> Void)?

    public init(snapshot: GitDiffSnapshot, onOpenPreview: ((URL) -> Void)? = nil) {
        self.snapshot = snapshot
        self.onOpenPreview = onOpenPreview
    }

    public static func displayState(for snapshot: GitDiffSnapshot) -> DisplayState {
        guard snapshot.isGitRepo else { return .notGitRepo }
        guard !snapshot.files.isEmpty else { return .clean(branch: snapshot.branch) }
        return .diff(branch: snapshot.branch, fileCount: snapshot.files.count, added: snapshot.totalAdded, deleted: snapshot.totalDeleted)
    }

    public static func resolvePreviewURL(file: String, cwd: String?) -> URL? {
        guard let url = PreviewTarget.resolve(file, cwd: cwd) else { return nil }
        if let cwd, !cwd.isEmpty {
            guard GitDiffService.isPathContained(url, inDirectory: cwd) else { return nil }
        }
        return url
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    headerSummary
                    Divider().overlay(T.Colors.glassBorder.color)
                    switch Self.displayState(for: snapshot) {
                    case .notGitRepo: emptyState(icon: "folder.badge.questionmark", text: "非 Git 版本控制目錄")
                    case .clean(let branch): emptyState(icon: "checkmark.circle", text: "工作樹乾淨無變更", branch: branch)
                    case .diff: filesList
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(T.Colors.glassCard.color)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [T.Colors.glassHighlightBorder.color, T.Colors.glassBorder.color],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerSummary: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(T.Colors.textSecondary.color)
            Text(snapshot.branch ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(T.Colors.textPrimary.color)
                .lineLimit(1)
            Spacer()
            if snapshot.isGitRepo && !snapshot.files.isEmpty {
                Text("\(snapshot.files.count) 檔案")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(T.Colors.textTertiary.color)
                HStack(spacing: 4) {
                    Text("+\(snapshot.totalAdded)").foregroundColor(T.Colors.diffAddedFg.color)
                    Text("-\(snapshot.totalDeleted)").foregroundColor(T.Colors.diffRemovedFg.color)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(T.Colors.glassSurfaceRecessed.color)
                .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func emptyState(icon: String, text: String, branch: String? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .light))
                .foregroundColor(T.Colors.textTertiary.color)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(T.Colors.textSecondary.color)
            if let b = branch, !b.isEmpty {
                Text("分支：\(b)")
                    .font(.system(size: 11))
                    .foregroundColor(T.Colors.textTertiary.color)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 12)
    }

    private var filesList: some View {
        LazyVStack(spacing: 8) {
            ForEach(snapshot.files) { file in
                fileDiffCard(file)
            }
        }
        .padding(10)
    }

    private func fileDiffCard(_ file: GitDiffFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)
            Divider().overlay(T.Colors.glassBorder.color.opacity(0.5))
            diffLines(file.lines)
            if file.truncated {
                Text(file.lines.isEmpty ? "差異過大，已省略內容" : "已截斷顯示前 \(GitDiffService.maxDiffLinesPerFile) 行…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(T.Colors.textTertiary.color)
                    .padding(6)
            }
        }
        .background(T.Colors.glassSurfaceRecessed.color.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(T.Colors.glassHighlightBorder.color, lineWidth: 0.5)
        )
        .cornerRadius(8)
    }

    private func openPreview(for file: GitDiffFile) {
        let baseDir = snapshot.repoRoot ?? snapshot.cwd
        if let liveURL = Self.resolvePreviewURL(file: file.path, cwd: baseDir) {
            onOpenPreview?(liveURL)
        }
    }

    private func fileHeader(_ file: GitDiffFile) -> some View {
        HStack(spacing: 6) {
            Text(file.status)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(statusColor(file.status))
                .frame(width: 14)

            if file.previewURL != nil {
                Button {
                    openPreview(for: file)
                } label: {
                    Text(file.path)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(T.Colors.textPrimary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("在即時預覽中開啟")
            } else {
                Text(file.path)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(T.Colors.textPrimary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            if file.previewURL != nil {
                Button {
                    openPreview(for: file)
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 10))
                        .foregroundColor(T.Colors.textSecondary.color)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("在預覽中開啟")
                .accessibilityLabel("在即時預覽開啟 \(file.path)")
            }

            HStack(spacing: 4) {
                Text("+\(file.added)").foregroundColor(T.Colors.diffAddedFg.color)
                Text("-\(file.deleted)").foregroundColor(T.Colors.diffRemovedFg.color)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(T.Colors.glassCardSelected.color.opacity(0.3))
    }

    private func diffLines(_ lines: [GitDiffLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                HStack(spacing: 0) {
                    Text(line.text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(lineTextColor(line.kind))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                    Spacer()
                }
                .background(lineBgColor(line.kind))
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        (status == "A" || status == "??") ? T.Colors.diffAddedFg.color : (status == "D" ? T.Colors.diffRemovedFg.color : T.Colors.stateNeedsInput.color)
    }

    private func lineTextColor(_ kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: return T.Colors.diffAddedFg.color
        case .removed: return T.Colors.diffRemovedFg.color
        case .hunkHeader: return T.Colors.textTertiary.color
        case .context: return T.Colors.textPrimary.color
        }
    }

    private func lineBgColor(_ kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: return T.Colors.diffAddedBg.color
        case .removed: return T.Colors.diffRemovedBg.color
        case .hunkHeader: return T.Colors.glassSurfaceRecessed.color.opacity(0.45)
        case .context: return Color.clear
        }
    }
}
