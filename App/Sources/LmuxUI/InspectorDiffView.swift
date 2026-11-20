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
        VStack(spacing: 0) {
            headerSummary
            Divider().overlay(T.Colors.glassBorder.color)
            switch Self.displayState(for: snapshot) {
            case .notGitRepo: emptyState(icon: "folder.badge.questionmark", text: "非 Git 版本控制目錄")
            case .clean(let branch): emptyState(icon: "checkmark.circle", text: "工作樹乾淨無變更", branch: branch)
            case .diff: filesList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.Colors.windowBackground.color.opacity(0.2))
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
        .frame(height: 34)
    }

    private func emptyState(icon: String, text: String, branch: String? = nil) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(T.Colors.textTertiary.color)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(T.Colors.textSecondary.color)
            if let b = branch, !b.isEmpty {
                Text("分支：\(b)")
                    .font(.system(size: 11))
                    .foregroundColor(T.Colors.textTertiary.color)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filesList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                ForEach(snapshot.files) { file in
                    fileDiffCard(file)
                }
            }
            .padding(10)
        }
    }

    private func fileDiffCard(_ file: GitDiffFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)
            Divider().overlay(T.Colors.glassBorder.color.opacity(0.5))
            diffLines(file.lines)
            if file.truncated {
                Text("已截斷顯示前 \(GitDiffService.maxDiffLinesPerFile) 行…")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(T.Colors.textTertiary.color)
                    .padding(6)
            }
        }
        .background(T.Colors.glassSurfaceRecessed.color.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(T.Colors.glassBorder.color, lineWidth: 0.5)
        )
        .cornerRadius(6)
    }

    private func fileHeader(_ file: GitDiffFile) -> some View {
        HStack(spacing: 6) {
            Text(file.status)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(statusColor(file.status))
                .frame(width: 14)

            Text(file.path)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(T.Colors.textPrimary.color)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if file.previewURL != nil {
                Button {
                    if let liveURL = Self.resolvePreviewURL(file: file.path, cwd: snapshot.cwd) {
                        onOpenPreview?(liveURL)
                    }
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 10))
                        .foregroundColor(T.Colors.textSecondary.color)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("在預覽中開啟")
            }

            Text("+\(file.added) -\(file.deleted)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(T.Colors.textTertiary.color)
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
        status == "A" ? T.Colors.diffAddedFg.color : (status == "D" ? T.Colors.diffRemovedFg.color : T.Colors.stateNeedsInput.color)
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
        case .added: return T.Colors.diffAddedBg.color.opacity(0.4)
        case .removed: return T.Colors.diffRemovedBg.color.opacity(0.4)
        case .hunkHeader: return T.Colors.glassSurfaceRecessed.color.opacity(0.3)
        case .context: return Color.clear
        }
    }
}
