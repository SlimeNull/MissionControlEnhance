import AppKit

enum InputSource {
    case leftClick, middleClick, threeFingerClick
}

enum TargetKind: Equatable {
    case button(ButtonKind)
    case quick(QuickAction)
}

/// Input that changes what Mission Control shows without going through a thumbnail.
enum Disruption {
    /// Click outside our targets, Esc, Return, ⌃↑: usually closes Mission Control.
    case closingInput
    /// ⌃← / ⌃→: slides to another desktop.
    case spaceSwitchKey
    /// Three/four-finger swipe: windows follow the fingers until it ends.
    case swipeBegan
    case swipeEnded
}

struct InputTarget: Equatable {
    let key: ElementKey
    let kind: TargetKind
}

/// Session-level event tap that is only enabled while Mission Control is open.
///
/// Clicks that land on one of our targets are swallowed — Dock never sees them, so
/// Mission Control stays open — and the action fires on mouse-up if the pointer is
/// still on the same target. Everything else passes through untouched.
@MainActor
final class InputInterceptor {
    var target: (CGPoint, InputSource) -> InputTarget? = { _, _ in nil }
    var onHover: (CGPoint) -> Void = { _ in }
    var onActivate: (InputTarget, CGEventFlags) -> Void = { _, _ in }
    /// Reported for input we let through that moves or closes Mission Control's content.
    var onDisruption: (Disruption) -> Void = { _ in }
    var isThreeFingerPress: () -> Bool = { false }

    var isEnabled = false {
        didSet {
            pending = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: isEnabled) }
        }
    }

    private var tap: CFMachPort?
    private var pending: (target: InputTarget, source: InputSource, upType: CGEventType)?

    /// NSEvent.EventType.pressure — Force Touch stages that accompany a trackpad click.
    private static let pressureEventType: UInt32 = 34
    /// Private CGS "dock control" events, which carry the system's trackpad swipes to Dock.
    private static let dockControlEventType: UInt32 = 30
    private static let gestureHIDTypeField = CGEventField(rawValue: 110)!
    private static let gesturePhaseField = CGEventField(rawValue: 132)!
    /// kIOHIDEventTypeDockSwipe: Mission Control / desktop-switching swipes.
    private static let dockSwipeHIDType: Int64 = 23

    private static func disruption(forKey event: CGEvent) -> Disruption? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
        switch (keyCode, flags) {
        case (53, []), (36, []), (76, []): return .closingInput      // Esc, Return, keypad Enter
        case (126, .maskControl): return .closingInput               // ⌃↑ toggles Mission Control
        case (123, .maskControl), (124, .maskControl): return .spaceSwitchKey
        default: return nil
        }
    }

    private static func disruption(forDockControl event: CGEvent) -> Disruption? {
        guard event.getIntegerValueField(gestureHIDTypeField) == dockSwipeHIDType else { return nil }
        switch event.getIntegerValueField(gesturePhaseField) {
        case 1: return .swipeBegan
        case 4, 8: return .swipeEnded       // ended, cancelled
        default: return nil
        }
    }

    func install() -> Bool {
        let types: [UInt32] = [
            CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .keyDown,
        ].map(\.rawValue) + [Self.pressureEventType, Self.dockControlEventType]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1)) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.input.error("CGEvent.tapCreate failed")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: isEnabled)
        self.tap = tap
        return true
    }

    /// Returns true to swallow the event.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isEnabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard isEnabled else { return false }
        let point = event.location

        switch type {
        case .mouseMoved:
            onHover(point)
            return false

        case .leftMouseDown:
            onHover(point)
            if let hit = target(point, .leftClick) {
                pending = (hit, .leftClick, .leftMouseUp)
                return true
            }
            if isThreeFingerPress(), let hit = target(point, .threeFingerClick) {
                pending = (hit, .threeFingerClick, .leftMouseUp)
                return true
            }
            return false

        case .otherMouseDown:
            guard event.getIntegerValueField(.mouseEventButtonNumber) == 2,
                  let hit = target(point, .middleClick) else { return false }
            pending = (hit, .middleClick, .otherMouseUp)
            return true

        case .leftMouseUp, .otherMouseUp:
            guard let pending, pending.upType == type else {
                if type == .leftMouseUp { onDisruption(.closingInput) }
                return false
            }
            self.pending = nil
            if target(point, pending.source) == pending.target {
                onActivate(pending.target, event.flags)
            }
            return true

        case .keyDown:
            if let disruption = Self.disruption(forKey: event) { onDisruption(disruption) }
            return false

        case .leftMouseDragged, .otherMouseDragged:
            if pending != nil { return true }
            onHover(point)
            return false

        default:
            if type.rawValue == Self.dockControlEventType {
                if let disruption = Self.disruption(forDockControl: event) { onDisruption(disruption) }
                return false
            }
            // Pressure stages of a click we already own.
            return pending != nil
        }
    }
}

private func inputTapCallback(proxy _: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<InputInterceptor>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { interceptor.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
