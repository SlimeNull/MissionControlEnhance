import AppKit

/// Converts between AppKit coordinates (bottom-left origin) and AX / CGEvent
/// coordinates (top-left origin of the primary display).
enum CoordinateSpace {
    static var primaryMaxY: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func axFrame(of screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
    }

    static func axPoint(fromCocoa point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }
}
