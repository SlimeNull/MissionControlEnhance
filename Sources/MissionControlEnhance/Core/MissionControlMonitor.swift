import AppKit
import ApplicationServices

/// Tells the overlay when Mission Control is fully expanded and when it starts closing.
///
/// Measured on macOS 26: `AXExposeShowAllWindows` arrives right after the zoom-in animation
/// finishes, which is exactly when overlays should appear. `AXExposeExit`, however, only
/// arrives after the zoom-out has finished — too late — while the `mc` group disappears from
/// Dock's AX tree within a frame of the zoom-out starting. So closing is detected by polling
/// Dock, and only while Mission Control is open; nothing is polled while idle.
@MainActor
final class MissionControlMonitor {
    nonisolated static let dockBundleID = "com.apple.dock"

    var onShown: () -> Void = {}
    var onHidden: () -> Void = {}

    private(set) var dockElement: AXUIElement?
    private(set) var isShown = false
    private var observer: AXObserver?
    private var workspaceTokens: [NSObjectProtocol] = []
    private let poller = DockPoller()

    private static let shownNotifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"]
    private static let hiddenNotifications = ["AXExposeExit", "AXExposeShowDesktop"]

    func start() {
        poller.onClosed = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.hide() }
            }
        }
        attach()

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard Self.isDock(note) else { return }
            MainActor.assumeIsolated {
                Log.monitor.info("Dock relaunched, reattaching")
                self?.attach()
            }
        })
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        poller.stop()
        onHidden()
    }

    private nonisolated static func isDock(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == dockBundleID
    }

    private func attach() {
        detach()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else {
            Log.monitor.error("Dock is not running")
            return
        }
        let pid = dock.processIdentifier
        var created: AXObserver?
        guard AXObserverCreate(pid, monitorCallback, &created) == .success, let observer = created else {
            Log.monitor.error("AXObserverCreate failed for Dock")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.shownNotifications + Self.hiddenNotifications {
            let result = AXObserverAddNotification(observer, element, name as CFString, refcon)
            if result != .success {
                Log.monitor.error("Failed to observe \(name, privacy: .public): \(result.rawValue)")
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = observer
        dockElement = element
    }

    private func detach() {
        hide()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockElement = nil
    }

    fileprivate func handle(_ notification: String) {
        Log.monitor.debug("Dock notification \(notification, privacy: .public)")
        if Self.shownNotifications.contains(notification) {
            guard !isShown, let dockElement else { return }
            isShown = true
            poller.start(dock: dockElement)
            onShown()
        } else if Self.hiddenNotifications.contains(notification) {
            hide()
        }
    }
}

private func monitorCallback(_: AXObserver, _: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let monitor = Unmanaged<MissionControlMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated { monitor.handle(name) }
}

/// Watches for Dock's `mc` group to vanish, off the main thread. Each poll is one AX round
/// trip (~0.2ms) for the child count; identifiers are only inspected when that count changes.
private final class DockPoller: @unchecked Sendable {
    /// One poll per frame on a 120Hz display; only runs while Mission Control is open.
    private static let interval: TimeInterval = 1.0 / 120

    var onClosed: () -> Void = {}

    private let queue = DispatchQueue(label: "MissionControlEnhance.monitor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var dock: AXUIElement?
    private var lastCount = -1

    func start(dock: AXUIElement) {
        queue.async {
            self.dock = dock
            self.lastCount = -1
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(2))
            // The cycle through the handler is broken when the timer is cancelled.
            timer.setEventHandler { self.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.dock = nil
        }
    }

    private func poll() {
        guard let dock else { return }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(dock, kAXChildrenAttribute as CFString, &count) == .success else { return }
        guard count != lastCount else { return }
        lastCount = count
        guard !AX.children(dock).contains(where: { AX.identifier($0) == "mc" }) else { return }
        timer?.cancel()
        timer = nil
        self.dock = nil
        onClosed()
    }
}
