import AppKit
import SwiftUI
import LmuxTokens

private typealias T = LmuxTokens

// MARK: - Footer Backdrop (1:1 Apple Liquid Glass)

@MainActor
public final class FooterBackdrop: NSView {
    let material = NSVisualEffectView()
    let tint = ColorView(T.Colors.sidebarBackground.nsColor)
    let specular = ColorView(T.Colors.specularHighlight.nsColor)

    public var forceOpaque = false { didSet { update() } }
    public var isResizing = false { didSet { if isResizing != oldValue { update() } } }

    public var isOpaqueFallback: Bool {
        forceOpaque || isResizing || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        material.material = .sidebar
        material.blendingMode = .behindWindow
        material.state = .followsWindowActiveState
        addSubview(material)
        addSubview(tint)
        addSubview(specular)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func update() {
        let opaque = isOpaqueFallback
        material.isHidden = opaque
        specular.isHidden = opaque
        tint.color = (opaque ? T.Colors.sidebarBackground : T.Colors.rightSidebarTint).nsColor
        specular.color = T.Colors.specularHighlight.nsColor
    }

    public override func layout() {
        super.layout()
        material.frame = bounds
        tint.frame = bounds
        specular.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: min(1, bounds.height))
    }
}

// MARK: - Footer Presentation Model

public struct FooterPresentation: Equatable {
    public let modelText: String
    public let turnsText: String
    public let rendererText: String
    public let contextPercentText: String
    public let contextRatio: Double?
    public let gitBranchText: String
    public let gitChangesText: String

    public init(
        modelText: String,
        turnsText: String,
        rendererText: String,
        contextPercentText: String,
        contextRatio: Double?,
        gitBranchText: String,
        gitChangesText: String
    ) {
        self.modelText = modelText
        self.turnsText = turnsText
        self.rendererText = rendererText
        self.contextPercentText = contextPercentText
        self.contextRatio = contextRatio
        self.gitBranchText = gitBranchText
        self.gitChangesText = gitChangesText
    }
}

// MARK: - Window Footer View

public struct WindowFooterView: View {
    @Bindable var model: AppModel
    var telemetry: PaneTelemetryDisplay?
    var git: GitDiffSnapshot?
    var onInspectTab: ((InspectorTab) -> Void)?
    var onToggleInspector: (() -> Void)?

    public init(
        model: AppModel,
        telemetry: PaneTelemetryDisplay? = nil,
        git: GitDiffSnapshot? = nil,
        onInspectTab: ((InspectorTab) -> Void)? = nil,
        onToggleInspector: (() -> Void)? = nil
    ) {
        self.model = model
        self.telemetry = telemetry
        self.git = git
        self.onInspectTab = onInspectTab
        self.onToggleInspector = onToggleInspector
    }

    public static func presentation(telemetry: PaneTelemetryDisplay?, git: GitDiffSnapshot?) -> FooterPresentation {
        let model = telemetry?.model ?? "—"
        let turns: String
        if let t = telemetry, t.turnCount > 0 {
            turns = "Turn \(t.turnCount)"
        } else {
            turns = "—"
        }
        let renderer = "Metal"
        let percentText: String
        let ratio: Double?
        if let t = telemetry, t.contextLimitTokens > 0 {
            percentText = "\(Int(t.contextPercent))%"
            ratio = Double(t.contextPercent) / 100.0
        } else {
            percentText = "—"
            ratio = nil
        }
        let branch = (git?.isGitRepo == true && git?.branch != nil) ? git!.branch! : "—"
        let changes = (git?.isGitRepo == true) ? "+\(git?.totalAdded ?? 0) -\(git?.totalDeleted ?? 0)" : "—"

        return FooterPresentation(
            modelText: model,
            turnsText: turns,
            rendererText: renderer,
            contextPercentText: percentText,
            contextRatio: ratio,
            gitBranchText: branch,
            gitChangesText: changes
        )
    }

    public var body: some View {
        let telem = telemetry ?? model.telemetryStore?.display(for: model.selected?.focusedPane)
        let g = git ?? model.gitDiffService.snapshot
        let pres = Self.presentation(telemetry: telem, git: g)
        HStack(spacing: 8) {
            // Left: Agent + Renderer
            HStack(spacing: 6) {
                Button {
                    onInspectTab?(.trace)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10))
                        Text(pres.modelText)
                            .font(.system(size: 10, weight: .medium))
                        if pres.turnsText != "—" {
                            Text(pres.turnsText)
                                .font(.system(size: 9))
                                .foregroundColor(T.Colors.textSecondary.color)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(T.Colors.glassSurfaceRecessed.color.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("執行記錄：\(pres.modelText)")

                HStack(spacing: 3) {
                    Circle()
                        .fill(T.Colors.stateDone.color)
                        .frame(width: 4, height: 4)
                    Text(pres.rendererText)
                        .font(.system(size: 10))
                        .foregroundColor(T.Colors.textSecondary.color)
                }
            }

            Spacer(minLength: 4)

            // Center: Context window gauge
            Button {
                onInspectTab?(.trace)
            } label: {
                HStack(spacing: 5) {
                    Text("Context")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(T.Colors.textSecondary.color)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(T.Colors.glassSurfaceRecessed.color)
                                .frame(height: 6)
                            if let ratio = pres.contextRatio {
                                Capsule()
                                    .fill(T.Colors.activePaneRing.color)
                                    .frame(width: max(0, min(geo.size.width * CGFloat(ratio), geo.size.width)), height: 6)
                            }
                        }
                    }
                    .frame(width: 60, height: 6)

                    Text(pres.contextPercentText)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(T.Colors.textPrimary.color)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(T.Colors.glassSurfaceRecessed.color.opacity(0.4))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Context 負載：\(pres.contextPercentText)")

            Spacer(minLength: 4)

            // Right: Git + Preview + Inspector toggle
            HStack(spacing: 6) {
                Button {
                    onInspectTab?(.diff)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text(pres.gitBranchText)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                        if pres.gitChangesText != "—" {
                            Text(pres.gitChangesText)
                                .font(.system(size: 9))
                                .foregroundColor(T.Colors.textSecondary.color)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(T.Colors.glassSurfaceRecessed.color.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Git 變更：\(pres.gitBranchText)")

                Button {
                    onInspectTab?(.preview)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                        Text("即時預覽")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(T.Colors.glassSurfaceRecessed.color.opacity(0.6))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("即時預覽")

                Button {
                    if let onToggle = onToggleInspector {
                        onToggle()
                    } else {
                        model.inspectorVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(model.inspectorVisible ? T.Colors.textPrimary.color : T.Colors.textTertiary.color)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切換右側欄 (⌥⌘B)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity)
    }
}
