import AppKit

/// Renders an NSImage into a bitmap with exactly `size × scale` pixels.
///
/// Handing an NSImage straight to a layer lets Core Animation pick a representation for the
/// layer's contentsScale (1 by default), which on a Retina display means a 1x bitmap stretched
/// to 2x — visibly blurry. Rasterizing at the target pixel size lets NSImage choose its best
/// representation (or re-run a drawing handler) for the real resolution.
enum ImageRasterizer {
    static func cgImage(_ image: NSImage, size: CGSize, scale: CGFloat) -> CGImage? {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return nil }
        // Point size on a pixel-sized bitmap gives the context the right backing scale.
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        return rep.cgImage
    }
}
