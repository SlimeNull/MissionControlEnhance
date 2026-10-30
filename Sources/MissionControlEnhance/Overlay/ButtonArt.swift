import AppKit

/// Draws the circular action buttons, rasterized for the target display scale.
@MainActor
enum ButtonArt {
    private static var cache: [String: CGImage] = [:]

    static func image(_ kind: ButtonKind, armed: Bool, highlighted: Bool, size: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(kind.rawValue)-\(armed)-\(highlighted)-\(size)-\(scale)"
        if let cached = cache[key] { return cached }

        let (base, symbol): (NSColor, String) = switch kind {
        case .close: (.systemRed, "xmark")
        case .minimize: (.systemYellow, "minus")
        case .quit: (armed ? .systemRed : NSColor(white: 0.3, alpha: 1), "power")
        }
        let color = highlighted ? base.blended(withFraction: 0.25, of: .white) ?? base : base
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 0.5
            circle.stroke()
            if highlighted {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                NSColor.white.withAlphaComponent(0.8).setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }

            let config = NSImage.SymbolConfiguration(pointSize: size * 0.48, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        let rendered = ImageRasterizer.cgImage(image, size: image.size, scale: scale)
        cache[key] = rendered
        return rendered
    }
}
