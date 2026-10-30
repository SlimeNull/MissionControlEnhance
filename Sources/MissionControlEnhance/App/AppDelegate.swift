import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Posted by a second launch so the instance already running opens its settings.
    private static let showSettingsNotification = Notification.Name("com.slimenull.MissionControlEnhance.showSettings")

    private let prefs = Preferences.shared
    private var coordinator: OverlayCoordinator?
    private var menuBar: MenuBarController?
    private lazy var settings = SettingsWindowController(prefs: prefs)
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        if let running = Self.otherInstance() {
            DistributedNotificationCenter.default().postNotificationName(Self.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
            running.activate()
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.showSettingsNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.show() }
        }

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

    /// Opening the app from Finder while it runs (Launch Services reuses the instance).
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        settings.show()
        return false
    }

    /// Another copy with the same bundle ID, e.g. launched from a different path.
    private static func otherInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { $0.processIdentifier != me }
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
