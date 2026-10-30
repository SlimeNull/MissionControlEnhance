import CoreGraphics

/// Geometry of everything drawn on one thumbnail, in global AX coordinates.
/// Shared by the renderer and by hit testing so the two can never disagree.
struct ThumbnailLayout {
    static let buttonGap: CGFloat = 6
    static let buttonInset: CGFloat = 8
    /// Extra hit slop around buttons.
    static let hitSlop: CGFloat = 3

    let frame: CGRect
    let iconFrame: CGRect
    let buttons: [(kind: ButtonKind, frame: CGRect)]

    init(frame: CGRect, style: OverlayStyle, buttons kinds: [ButtonKind]) {
        self.frame = frame

        // The icon straddles the chosen edge or corner so it stays readable on small thumbnails;
        // centered axes sit fully inside the thumbnail.
        let size = style.iconSize
        let overhang = size * 0.3
        let position = style.iconPosition
        let iconX: CGFloat = switch position.column {
        case -1: frame.minX - overhang
        case 1: frame.maxX - size + overhang
        default: frame.midX - size / 2
        }
        let iconY: CGFloat = switch position.row {
        case -1: frame.minY - overhang
        case 1: frame.maxY - size + overhang
        default: frame.midY - size / 2
        }
        iconFrame = CGRect(x: iconX, y: iconY, width: size, height: size)

        // Buttons sit along the top edge, on the left only when the icon is on the right.
        let b = style.buttonSize
        let total = CGFloat(kinds.count) * b + CGFloat(max(kinds.count - 1, 0)) * Self.buttonGap
        let startX = position.column == 1 ? frame.minX + Self.buttonInset : frame.maxX - Self.buttonInset - total
        let y = frame.minY + Self.buttonInset
        buttons = kinds.enumerated().map { i, kind in
            (kind, CGRect(x: startX + CGFloat(i) * (b + Self.buttonGap), y: y, width: b, height: b))
        }
    }

    func button(at point: CGPoint) -> ButtonKind? {
        buttons.first { $0.frame.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(point) }?.kind
    }
}
