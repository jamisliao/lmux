import AppKit
import LmuxTokens
import LmuxUI
import SwiftUI

private typealias T = LmuxTokens

/// 通知 bar 清單裡的一則通知，最多 4 行：任務名稱與經過時間、workspace 名稱、訊息（最多 2 行）。
/// 沒有任務名稱時，第 1 行改成 workspace 名稱，不顯示第 2 行；第 2 行與第 1 行相同時也不顯示。
struct NotificationCard: View {
    let entry: NotificationEntry
    let model: AppModel
    let age: String
    /// 反白：來自 focused tab 的**最新**一則通知（同一個 tab 的舊通知不反白，由 NotificationList 決定）。
    let highlighted: Bool
    let open: () -> Void
    @State private var hover = false
    @Environment(\.controlActiveState) private var activeState

    /// 圓角底色的位置比照 sidebar 的 workspace 列（外距 rowInsetX）；文字與摘要列、plugin 列對齊（x = 32）。
    static let outerPaddingX: CGFloat = T.Layout.rowInsetX
    static let innerPaddingX: CGFloat = 4
    static let innerPaddingY: CGFloat = 6
    static let outerPaddingY: CGFloat = 2

    /// 一行文字實際佔的高度：中文會改用 PingFang 顯示，行高比 SF 高，取兩者較大的值。
    @MainActor static func lineHeight(_ size: CGFloat) -> CGFloat {
        let lm = NSLayoutManager()
        let sf = lm.defaultLineHeight(for: .systemFont(ofSize: size))
        let cjk = NSFont(name: "PingFangTC-Regular", size: size).map { lm.defaultLineHeight(for: $0) } ?? sf
        return ceil(max(sf, cjk))
    }

    /// 4 行都有時的高度：通知 bar 的最小高度要放得下一張完整的卡片。
    @MainActor static let maxHeight: CGFloat = outerPaddingY * 2 + innerPaddingY * 2
        + lineHeight(T.Typography.rowTitle.size) + lineHeight(T.Typography.rowMeta.size)
        + lineHeight(T.Typography.rowSubtitle.size) * 2 + T.Layout.rowLineGap * 3

    var body: some View {
        let workspace = workspaceName(entry, in: model)
        let task = taskTitle(entry, in: model)
        let first = task ?? workspace
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(entry.read ? Color.clear : T.Colors.accent.color)
                .frame(width: 6, height: 6)
                .frame(width: 14, height: Self.lineHeight(T.Typography.rowTitle.size))
            VStack(alignment: .leading, spacing: T.Layout.rowLineGap) {
                HStack(spacing: 4) {
                    Text(first)
                        .font(.system(size: T.Typography.rowTitle.size, weight: entry.read ? .regular : .medium))
                        .foregroundStyle((entry.read ? T.Colors.textSecondary : T.Colors.textPrimary).color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(age)
                        .font(T.Typography.rowMeta.font.monospacedDigit())
                        .foregroundStyle(T.Colors.textTertiary.color)
                }
                if task != nil, workspace != first {
                    Text(workspace)
                        .font(T.Typography.rowMeta.font)
                        .foregroundStyle(T.Colors.textTertiary.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(plainMessage(entry.message))
                    .font(T.Typography.rowSubtitle.font)
                    .foregroundStyle((entry.read ? T.Colors.textTertiary : T.Colors.textSecondary).color)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Self.innerPaddingX)
        .padding(.vertical, Self.innerPaddingY)
        .background(
            RoundedRectangle(cornerRadius: T.Radius.row, style: .continuous)
                .fill(background)
        )
        .padding(.horizontal, Self.outerPaddingX)
        .padding(.vertical, Self.outerPaddingY)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(entry.read ? "" : "unread")
    }

    /// 反白：與 sidebar 選取列同色（視窗不在前景時用淡的那個）。反白時 hover 不改變底色。
    private var background: Color {
        if highlighted { return (activeState == .inactive ? T.Colors.rowSelectedInactive : T.Colors.rowSelected).color }
        return hover ? T.Colors.rowHover.color : .clear
    }
}

/// 通知來自的 tab；tab 已關閉時是 nil。在所有 workspace 裡找，tab 被移到別的 workspace 也找得到。
@MainActor
func sourcePane(_ e: NotificationEntry, in model: AppModel) -> Pane? {
    guard let id = e.paneID else { return nil }
    for ws in model.workspaces {
        if let pane = ws.panes.first(where: { $0.id == id }) { return pane }
    }
    return nil
}

/// 通知來自的 tab 目前的任務名稱（Claude 的 session 標題，清理規則與 tab 列、sidebar 相同）。
/// tab 已關閉、或沒有 session 標題時是 nil。讀的是現在的值：tab 換了 session，舊通知也顯示新的任務名稱。
@MainActor
func taskTitle(_ e: NotificationEntry, in model: AppModel) -> String? {
    guard let pane = sourcePane(e, in: model), let raw = pane.titleState.title, !raw.isEmpty else { return nil }
    let t = pane.headerTitle
    return t.isEmpty ? nil : t
}

/// 卡片上代表通知來源的名稱：workspace 的手動名稱；否則 tab 工作目錄的資料夾名稱；否則通知當時的名稱。
/// 不用 lmux 的自動名稱：沒有手動名稱時，它是 focused tab 的任務名稱，會顯示成另一個 tab 的任務。
@MainActor
func workspaceName(_ e: NotificationEntry, in model: AppModel) -> String {
    let pane = sourcePane(e, in: model)
    let ws = pane?.workspace ?? model.workspaces.first { $0.id == e.workspaceID }
    if let ws, let custom = ws.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
        return ws.title
    }
    if let cwd = pane?.cwd, !cwd.isEmpty {
        let folder = (cwd as NSString).lastPathComponent
        if !folder.isEmpty { return folder }
    }
    return e.title
}

/// 去掉訊息開頭的 Markdown 標記（`#`、`*`、`-`、`>`）與空白，以及成對的 `**`。
// ponytail: 只處理開頭與 `**`；訊息若真的以 "-" 開頭（例如 "-1 failed"）也會被拿掉，需要時再改成只拿掉 "- "。
func plainMessage(_ s: String) -> String {
    let t = s.replacingOccurrences(of: "**", with: "")
    return String(t.drop { "#*-> \t".contains($0) })
}
