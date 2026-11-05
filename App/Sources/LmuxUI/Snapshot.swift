import AppKit
import CoreImage
import IOSurface
import LmuxTerminal

extension LmuxController {
    /// Render the whole window to a PNG without showing it: AppKit/SwiftUI
    /// chrome via `cacheDisplay`, terminal pixels straight from each surface's
    /// IOSurface, rings drawn last. In headless mode (borderless window) the
    /// traffic lights are drawn as placeholders at their real positions.
    public func snapshotPNG(to url: URL, scale: CGFloat = 2) throws {
        guard let image = snapshotImage(scale: scale), let rootView = window.contentView else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = rootView.bounds.size
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The same render as `snapshotPNG`, as an image (README GIF frames).
    public func snapshotImage(scale: CGFloat = 2) -> CGImage? {
        guard let rootView = window.contentView else { return nil }
        rootView.layoutSubtreeIfNeeded()
        let size = rootView.bounds.size
        let W = Int(size.width * scale), H = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        // Window background, then the chrome.
        rootView.effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor((window.backgroundColor ?? .black).cgColor)
        }
        ctx.fill(CGRect(origin: .zero, size: size))
        draw(rootView, in: ctx, scale: scale)

        // Terminal pixels.
        let ci = CIContext()
        for pane in model.selected?.panes ?? [] {
            let s = pane.surface
            guard s.window != nil, let contents = s.layer?.contents else { continue }
            let surf = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            let img = CIImage(ioSurface: surf)
            guard let cg = ci.createCGImage(img, from: img.extent) else { continue }
            let r = s.convert(s.bounds, to: nil)
            ctx.draw(cg, in: r)
        }
        // In-pane overlays (hover actions, input label, cards, toasts) over the terminals.
        for pane in model.selected?.panes ?? [] where !pane.view.overlay.isEmpty {
            draw(pane.view.overlay, in: ctx, scale: scale)
        }
        // Rings over the terminals.
        for pane in model.selected?.panes ?? [] where pane.view.ring.shown {
            draw(pane.view.ring, in: ctx, scale: scale)
        }

        if headless {
            // Placeholder traffic lights (12pt, 8pt gap, centered in the titlebar).
            let colors: [NSColor] = [NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1),
                                     NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),
                                     NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
            let cy = size.height - root.titlebarHeight / 2
            for (i, c) in colors.enumerated() {
                ctx.setFillColor(c.cgColor)
                ctx.fillEllipse(in: CGRect(x: 14 + CGFloat(i) * 20, y: cy - 6, width: 12, height: 12))
            }
        }

        return ctx.makeImage()
    }

    /// Draw `view` (and its subviews) into `ctx` at its window position.
    private func draw(_ view: NSView, in ctx: CGContext, scale: CGFloat) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { return }
        ctx.draw(cg, in: view.convert(view.bounds, to: nil))
    }
}
