import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private var coordinator: OverlayCoordinator?
    private var menuBar: MenuBarController?
    private lazy var settings = SettingsWindowController(prefs: prefs)
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        // Bounds every AX round trip, so one hung app cannot stall a scan.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        menuBar = MenuBarController(prefs: prefs, openSettings: { [weak self] in self?.settings.show() })

        if Permissions.isAccessibilityTrusted {
            startCoordinator()
        } else {
            Permissions.requestAccessibility()
            waitForAccessibility()
        }
    }

    private func waitForAccessibility() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard Permissions.isAccessibilityTrusted else { return }
                timer.invalidate()
                self?.startCoordinator()
            }
        }
    }

    private func startCoordinator() {
        guard coordinator == nil else { return }
        let coordinator = OverlayCoordinator(prefs: prefs)
        coordinator.start()
        self.coordinator = coordinator
    }
}
