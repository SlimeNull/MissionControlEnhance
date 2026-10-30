import AppKit
import QuartzCore

/// Everything the overlay needs to draw one thumbnail.
struct OverlayItem {
    let key: ElementKey
    let frame: CGRect
    let icon: NSImage?
    let buttons: [ButtonKind]
    let hoveredButton: ButtonKind?
    let armedQuit: Bool
    let notice: String?
    let debugText: String?
    let confidence: MatchConfidence
}

/// Owns one transparent, click-through panel per screen, floating above Mission Control.
@MainActor
final class OverlayController {
    private var panels: [OverlayPanel] = []
    private var screenToken: NSObjectProtocol?

    init() {
        rebuildPanels()
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
    }

    /// Removes everything at once and hides the canvas; called the moment Mission Control starts closing.
    func clear() {
        panels.forEach { $0.clear() }
    }

    /// Hides without discarding anything, so `reveal()` can bring it back.
    func suspend() {
        panels.forEach { $0.suspend() }
    }

    /// Shows what has been rendered since the last `clear()`.
    func reveal() {
        panels.forEach { $0.reveal() }
    }

    func render(_ items: [OverlayItem], style: OverlayStyle) {
        for panel in panels {
            let mine = items.filter { panel.screenAXFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            panel.render(mine, style: style)
        }
    }

    private func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { OverlayPanel(screen: $0) }
        // Kept ordered in permanently: being present before Mission Control opens is what keeps
        // them above it. Fully transparent and click-through while idle.
        panels.forEach { $0.orderFrontRegardless() }
    }
}

private final class OverlayPanel: NSPanel {
    let screenAXFrame: CGRect
    private let canvas = CALayer()
    private let scale: CGFloat
    private var itemLayers: [ElementKey: ItemLayers] = [:]

    init(screen: NSScreen) {
        screenAXFrame = CoordinateSpace.axFrame(of: screen)
        scale = screen.backingScaleFactor
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        canvas.frame = view.bounds
        canvas.contentsScale = scale
        view.layer?.addSublayer(canvas)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.removeAllAnimations()
        canvas.isHidden = true
        itemLayers.values.forEach { $0.root.removeFromSuperlayer() }
        itemLayers.removeAll()
        CATransaction.commit()
    }

    func suspend() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.removeAllAnimations()
        canvas.isHidden = true
        CATransaction.commit()
    }

    func reveal() {
        guard canvas.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.isHidden = false
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.1
        canvas.add(fade, forKey: "reveal")
        CATransaction.commit()
    }

    func render(_ items: [OverlayItem], style: OverlayStyle) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let live = Set(items.map(\.key))
        for (key, layers) in itemLayers where !live.contains(key) {
            layers.root.removeFromSuperlayer()
            itemLayers[key] = nil
        }
        for item in items {
            let isNew = itemLayers[item.key] == nil
            let layers = itemLayers[item.key] ?? {
                let created = ItemLayers(scale: scale)
                created.root.frame = canvas.bounds
                canvas.addSublayer(created.root)
                itemLayers[item.key] = created
                return created
            }()
            layers.update(item, style: style, toLocal: local)
            if isNew {
                layers.fadeIn()
            }
        }
    }

    /// AX global rect -> canvas coordinates (bottom-left origin), snapped to the device pixel grid.
    /// Layouts produce fractional points (e.g. the icon's 0.3 × size overhang); a bitmap placed
    /// off-grid gets resampled by the compositor and looks visibly soft.
    private func local(_ rect: CGRect) -> CGRect {
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let x = snap(rect.minX - screenAXFrame.minX)
        let y = snap(screenAXFrame.maxY - rect.maxY)
        return CGRect(x: x, y: y, width: snap(rect.width), height: snap(rect.height))
    }
}

/// Layers for one thumbnail, all positioned in canvas coordinates.
@MainActor
private final class ItemLayers {
    private static let hoverScale: CGFloat = 1.15
    let root = CALayer()
    private let icon = CALayer()
    private var buttons: [ButtonKind: CALayer] = [:]
    private let notice = CATextLayer()
    private let debugBorder = CALayer()
    private let debugLabel = CATextLayer()
    private let scale: CGFloat
    private var iconSource: (image: NSImage, size: CGFloat)?

    init(scale: CGFloat) {
        self.scale = scale
        icon.contentsScale = scale
        icon.contentsGravity = .resize
        icon.shadowColor = NSColor.black.cgColor
        icon.shadowOpacity = 0.4
        icon.shadowRadius = 3
        icon.shadowOffset = CGSize(width: 0, height: -1)

        notice.contentsScale = scale
        notice.alignmentMode = .center
        notice.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        notice.cornerRadius = 6
        notice.isWrapped = true

        debugBorder.borderWidth = 2
        debugLabel.contentsScale = scale
        debugLabel.fontSize = 10
        debugLabel.foregroundColor = NSColor.white.cgColor
        debugLabel.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        debugLabel.isWrapped = true

        for layer in [debugBorder, debugLabel, icon, notice] {
            root.addSublayer(layer)
        }
    }

    func update(_ item: OverlayItem, style: OverlayStyle, toLocal: (CGRect) -> CGRect) {
        let layout = ThumbnailLayout(frame: item.frame, style: style, buttons: item.buttons)

        if let image = item.icon {
            if iconSource?.image !== image || iconSource?.size != style.iconSize {
                icon.contents = ImageRasterizer.cgImage(image, size: CGSize(width: style.iconSize, height: style.iconSize), scale: scale)
                iconSource = (image, style.iconSize)
            }
            icon.frame = toLocal(layout.iconFrame)
            icon.isHidden = false
        } else {
            icon.isHidden = true
        }

        let wanted = Dictionary(uniqueKeysWithValues: layout.buttons.map { ($0.kind, $0.frame) })
        for (kind, layer) in buttons where wanted[kind] == nil {
            layer.removeFromSuperlayer()
            buttons[kind] = nil
        }
        for (kind, frame) in wanted {
            let layer = buttons[kind] ?? {
                let created = CALayer()
                created.contentsScale = scale
                root.insertSublayer(created, below: notice)
                buttons[kind] = created
                return created
            }()
            let highlighted = kind == item.hoveredButton
            layer.contents = ButtonArt.image(kind, armed: kind == .quit && item.armedQuit, highlighted: highlighted, size: style.buttonSize, scale: scale)
            // Frame is only well defined under an identity transform.
            let scaleUp = CATransform3DMakeScale(Self.hoverScale, Self.hoverScale, 1)
            let wasHighlighted = !CATransform3DIsIdentity(layer.transform)
            layer.transform = CATransform3DIdentity
            layer.frame = toLocal(frame)
            if highlighted {
                layer.transform = scaleUp
            }
            if highlighted != wasHighlighted {
                let grow = CABasicAnimation(keyPath: "transform")
                grow.fromValue = highlighted ? CATransform3DIdentity : scaleUp
                grow.toValue = layer.transform
                grow.duration = 0.1
                layer.add(grow, forKey: "hover")
            }
        }

        if let text = item.notice {
            let font = NSFont.systemFont(ofSize: 12, weight: .medium)
            notice.font = font
            notice.fontSize = 12
            notice.string = text
            notice.foregroundColor = NSColor.white.cgColor
            let textWidth = (text as NSString).size(withAttributes: [.font: font]).width + 20
            let width = min(item.frame.width - 16, textWidth)
            let height: CGFloat = textWidth > width ? 40 : 22
            let box = CGRect(x: item.frame.midX - width / 2, y: item.frame.midY - height / 2, width: width, height: height)
            notice.frame = toLocal(box)
            notice.isHidden = false
        } else {
            notice.isHidden = true
        }

        if let text = item.debugText {
            let color: NSColor = switch item.confidence {
            case .window: .systemGreen
            case .app: .systemYellow
            case .none: .systemRed
            }
            debugBorder.borderColor = color.cgColor
            debugBorder.frame = toLocal(item.frame)
            debugLabel.string = text
            debugLabel.frame = toLocal(CGRect(x: item.frame.minX, y: item.frame.maxY - 28, width: item.frame.width, height: 28))
            debugBorder.isHidden = false
            debugLabel.isHidden = false
        } else {
            debugBorder.isHidden = true
            debugLabel.isHidden = true
        }
    }

    func fadeIn() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        root.add(fade, forKey: "fade")
    }
}
