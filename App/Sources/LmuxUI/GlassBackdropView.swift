import AppKit
import LmuxTokens

private typealias T = LmuxTokens

/// Tapered 1pt horizontal specular edge (`transparent -> highlight -> transparent`),
/// matching `--glass-specular-highlight` edge treatment.
@MainActor
public final class SpecularHighlightView: NSView {
    private let gradient = CAGradientLayer()
    public var color: NSColor { didSet { refreshColors() } }

    public init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0, 0.2, 0.8, 1]
        layer?.addSublayer(gradient)
        refreshColors()
    }

    public required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        var resolved: CGColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = self.color.cgColor
        }
        let edge = resolved.copy(alpha: 0) ?? NSColor.clear.cgColor
        gradient.colors = [edge, resolved, resolved, edge]
    }
}

/// Shared translucent glass backdrop (`NSVisualEffectView` + tint overlay + 1pt top specular edge)
/// with automatic Reduce Transparency and drag-resize opaque fallback, plus observer cleanup in `deinit`.
@MainActor
public class GlassBackdropView: NSView {
    public let material = NSVisualEffectView()
    let tint: ColorView
    let specular = SpecularHighlightView(T.Colors.specularHighlight.nsColor)
    private let bottomHairline: ColorView?

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
        opaqueTint: LmuxTokens.DynamicColor,
        showsBottomHairline: Bool = false
    ) {
        self.translucentTint = translucentTint
        self.opaqueTint = opaqueTint
        self.tint = ColorView(translucentTint.nsColor)
        self.bottomHairline = showsBottomHairline ? ColorView(T.Colors.glassBorder.nsColor) : nil
        super.init(frame: frame)
        self.material.material = materialStyle
        self.material.blendingMode = .behindWindow
        self.material.state = .followsWindowActiveState
        addSubview(self.material)
        addSubview(self.tint)
        addSubview(self.specular)
        if let bottomHairline { addSubview(bottomHairline) }
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
        bottomHairline?.color = T.Colors.glassBorder.nsColor
    }

    public override func layout() {
        super.layout()
        material.frame = bounds
        tint.frame = bounds
        specular.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: min(1, bounds.height))
        bottomHairline?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: min(1, bounds.height))
    }
}
