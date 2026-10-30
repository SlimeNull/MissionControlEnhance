import AppKit
import Combine

/// Where the app icon sits on a thumbnail, in reading order of a 3×3 grid.
enum IconPosition: String, CaseIterable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    /// -1, 0, 1 for left, centered, right.
    var column: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .top, .center, .bottom: 0
        case .topRight, .right, .bottomRight: 1
        }
    }

    /// -1, 0, 1 for top, centered, bottom.
    var row: Int {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .left, .center, .right: 0
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }

    var title: String {
        switch self {
        case .topLeft: "左上"
        case .top: "上边"
        case .topRight: "右上"
        case .left: "左边"
        case .center: "中间"
        case .right: "右边"
        case .bottomLeft: "左下"
        case .bottom: "下边"
        case .bottomRight: "右下"
        }
    }
}

enum ButtonKind: String, CaseIterable, Identifiable {
    case close, minimize, quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .close: "关闭窗口"
        case .minimize: "最小化窗口"
        case .quit: "退出应用（按住 ⌥ 强制退出）"
        }
    }
}

/// What a middle click or three-finger click on a thumbnail does.
enum QuickAction: String, CaseIterable, Identifiable {
    case none, close, minimize, quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "无"
        case .close: "关闭窗口"
        case .minimize: "最小化窗口"
        case .quit: "退出应用"
        }
    }
}

struct OverlayStyle: Equatable {
    var iconSize: CGFloat
    var iconPosition: IconPosition
    var buttonSize: CGFloat = 20
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var iconSize: Double { didSet { defaults.set(iconSize, forKey: "iconSize") } }
    // Stored under the key from when only corners were supported.
    @Published var iconPosition: IconPosition { didSet { defaults.set(iconPosition.rawValue, forKey: "iconCorner") } }
    @Published var showButtons: Bool { didSet { defaults.set(showButtons, forKey: "showButtons") } }
    @Published var showCloseButton: Bool { didSet { defaults.set(showCloseButton, forKey: "showCloseButton") } }
    @Published var showMinimizeButton: Bool { didSet { defaults.set(showMinimizeButton, forKey: "showMinimizeButton") } }
    @Published var showQuitButton: Bool { didSet { defaults.set(showQuitButton, forKey: "showQuitButton") } }
    /// All buttons, left to right, including hidden ones.
    @Published var buttonOrder: [ButtonKind] { didSet { defaults.set(buttonOrder.map(\.rawValue), forKey: "buttonOrder") } }
    @Published var confirmQuit: Bool { didSet { defaults.set(confirmQuit, forKey: "confirmQuit") } }
    @Published var middleClickEnabled: Bool { didSet { defaults.set(middleClickEnabled, forKey: "middleClickEnabled") } }
    @Published var middleClickAction: QuickAction { didSet { defaults.set(middleClickAction.rawValue, forKey: "middleClickAction") } }
    @Published var threeFingerClickEnabled: Bool { didSet { defaults.set(threeFingerClickEnabled, forKey: "threeFingerClickEnabled") } }
    @Published var threeFingerClickAction: QuickAction { didSet { defaults.set(threeFingerClickAction.rawValue, forKey: "threeFingerClickAction") } }
    @Published var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: "excludedBundleIDs") } }
    @Published var debugMode: Bool { didSet { defaults.set(debugMode, forKey: "debugMode") } }

    private init() {
        defaults.register(defaults: [
            "enabled": true,
            "iconSize": 36.0,
            "iconCorner": IconPosition.topLeft.rawValue,
            "showButtons": true,
            "showCloseButton": true,
            "showMinimizeButton": true,
            "showQuitButton": true,
            "confirmQuit": true,
            "buttonOrder": ButtonKind.allCases.map(\.rawValue),
            "middleClickEnabled": false,
            "middleClickAction": QuickAction.close.rawValue,
            "threeFingerClickEnabled": false,
            "threeFingerClickAction": QuickAction.close.rawValue,
            "excludedBundleIDs": [String](),
            "debugMode": false,
        ])
        enabled = defaults.bool(forKey: "enabled")
        iconSize = defaults.double(forKey: "iconSize")
        iconPosition = IconPosition(rawValue: defaults.string(forKey: "iconCorner") ?? "") ?? .topLeft
        showButtons = defaults.bool(forKey: "showButtons")
        showCloseButton = defaults.bool(forKey: "showCloseButton")
        showMinimizeButton = defaults.bool(forKey: "showMinimizeButton")
        showQuitButton = defaults.bool(forKey: "showQuitButton")
        confirmQuit = defaults.bool(forKey: "confirmQuit")
        let storedOrder = (defaults.stringArray(forKey: "buttonOrder") ?? []).compactMap(ButtonKind.init(rawValue:))
        var order: [ButtonKind] = []
        for kind in storedOrder + ButtonKind.allCases where !order.contains(kind) {
            order.append(kind)
        }
        buttonOrder = order
        middleClickEnabled = defaults.bool(forKey: "middleClickEnabled")
        middleClickAction = QuickAction(rawValue: defaults.string(forKey: "middleClickAction") ?? "") ?? .close
        threeFingerClickEnabled = defaults.bool(forKey: "threeFingerClickEnabled")
        threeFingerClickAction = QuickAction(rawValue: defaults.string(forKey: "threeFingerClickAction") ?? "") ?? .close
        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        debugMode = defaults.bool(forKey: "debugMode")
    }

    var overlayStyle: OverlayStyle {
        OverlayStyle(iconSize: CGFloat(iconSize), iconPosition: iconPosition)
    }

    /// Buttons the user wants, in display order (left to right).
    var enabledButtons: [ButtonKind] {
        guard showButtons else { return [] }
        return buttonOrder.filter(isButtonShown)
    }

    func isButtonShown(_ kind: ButtonKind) -> Bool {
        switch kind {
        case .close: showCloseButton
        case .minimize: showMinimizeButton
        case .quit: showQuitButton
        }
    }

    func setButton(_ kind: ButtonKind, shown: Bool) {
        switch kind {
        case .close: showCloseButton = shown
        case .minimize: showMinimizeButton = shown
        case .quit: showQuitButton = shown
        }
    }

    /// Moves a button one slot left (-1) or right (+1).
    func moveButton(_ kind: ButtonKind, by offset: Int) {
        guard let i = buttonOrder.firstIndex(of: kind), buttonOrder.indices.contains(i + offset) else { return }
        buttonOrder.swapAt(i, i + offset)
    }
}
