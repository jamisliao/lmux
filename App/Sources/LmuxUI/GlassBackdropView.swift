import AppKit
import LmuxTokens

private typealias T = LmuxTokens

/// Shared translucent glass backdrop (`NSVisualEffectView` + tint overlay + 1pt top specular edge)
/// with automatic Reduce Transparency and drag-resize opaque fallback, plus observer cleanup in `deinit`.
@MainActor
public class GlassBackdropView: NSView {
    public let material = NSVisualEffectView()
    let tint: ColorView
    let specular = ColorView(T.Colors.specularHighlight.nsColor)

    public var translucentTint: LmuxTokens.DynamicColor { didSet { update() } }
    public var opaqueTint: LmuxTokens.DynamicColor { didSet { update() } }

    /// Forced opaque (headless snapshots, tests).
    public var forceOpaque = false { didSet { update() } }
    /// Set while dragging resize handles / split dividers or during window live resize to pause blur recomputation.
    public var isResizing = false { didSet { if isResizing != oldValue { update() } } }

    private var accessibilityObserver: NSObjectProtocol?

    public init(
        frame: NSRect = .zero,
        materialStyle: NSVisualEffectView.Material = .sidebar,
        translucentTint: LmuxTokens.DynamicColor,
        opaqueTint: LmuxTokens.DynamicColor
    ) {
        self.translucentTint = translucentTint
        self.opaqueTint = opaqueTint
        self.tint = ColorView(translucentTint.nsColor)
        super.init(frame: frame)
        self.material.material = materialStyle
        self.material.blendingMode = .behindWindow
        self.material.state = .followsWindowActiveState
        addSubview(self.material)
        addSubview(self.tint)
        addSubview(self.specular)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    public required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public var isOpaqueFallback: Bool {
        forceOpaque || isResizing || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    func update() {
        let opaque = isOpaqueFallback
        material.isHidden = opaque
        specular.isHidden = opaque
        tint.color = (opaque ? opaqueTint : translucentTint).nsColor
        specular.color = T.Colors.specularHighlight.nsColor
    }

    public override func layout() {
        super.layout()
        material.frame = bounds
        tint.frame = bounds
        specular.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: min(1, bounds.height))
    }
}
