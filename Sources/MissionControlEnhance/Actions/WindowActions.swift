import AppKit
import ApplicationServices

enum WindowAction {
    case close
    case minimize
    case quit(force: Bool)
}

enum ActionOutcome {
    /// The window is gone (closed or minimized).
    case windowGone
    case appTerminated(pid_t)
    /// Nothing visible happened; carries a message for the user.
    case unchanged(String)
}

/// Performs window / app actions off the main thread and reports whether they took effect.
///
/// Verification matters: Dock's Mission Control tree is a snapshot that is never updated
/// after a window closes, so the coordinator relies on these outcomes to hide overlays.
final class WindowActions: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MissionControlEnhance.actions", qos: .userInitiated)

    func perform(_ action: WindowAction, window: WindowInfo?, pid: pid_t?, completion: @escaping @MainActor (ActionOutcome) -> Void) {
        let finish: (ActionOutcome) -> Void = { outcome in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(outcome) } }
        }
        switch action {
        case .close:
            guard let window else { return }
            queue.async {
                guard let button = AX.element(window.element, kAXCloseButtonAttribute),
                      AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                else {
                    finish(.unchanged(String(localized: "This window can't be closed")))
                    return
                }
                let gone = Self.waitUntil(timeout: 1.5) { Self.isGone(window) }
                finish(gone ? .windowGone : .unchanged(String(localized: "Window not closed; it may be waiting on a save dialog")))
            }

        case .minimize:
            guard let window else { return }
            queue.async {
                guard AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success else {
                    finish(.unchanged(String(localized: "This window can't be minimized")))
                    return
                }
                let done = Self.waitUntil(timeout: 1.0) { AX.bool(window.element, kAXMinimizedAttribute) == true || Self.isGone(window) }
                finish(done ? .windowGone : .unchanged(String(localized: "Window could not be minimized")))
            }

        case .quit(let force):
            guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
            let sent = force ? app.forceTerminate() : app.terminate()
            guard sent else {
                finish(.unchanged(String(localized: "Unable to quit this app")))
                return
            }
            queue.async {
                let terminated = Self.waitUntil(timeout: 3.0) { app.isTerminated }
                finish(terminated ? .appTerminated(pid) : .unchanged(String(localized: "App didn't quit; it may be waiting for confirmation")))
            }
        }
    }

    private static func isGone(_ window: WindowInfo) -> Bool {
        guard AX.isAlive(window.element) else { return true }
        let siblings = AX.elements(AXUIElementCreateApplication(window.pid), kAXWindowsAttribute)
        return !siblings.contains { CFEqual($0, window.element) }
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }
}
