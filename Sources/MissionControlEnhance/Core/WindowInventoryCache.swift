import AppKit
import ApplicationServices

/// Keeps every app's window list current, so thumbnails can be matched the moment Mission
/// Control opens instead of after a full AX sweep (which takes longer than the animation).
///
/// Per-app AXObservers mark an app dirty; dirty apps are re-queried after a short debounce.
/// The window lists themselves live on `queue`, the same serial queue the coordinator scans on.
final class WindowInventoryCache: @unchecked Sendable {
    private static let debounce: TimeInterval = 0.15
    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    private static let windowNotifications = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification]

    let queue: DispatchQueue

    // Main thread only.
    private var observers: [pid_t: AXObserver] = [:]
    private var dirty: Set<pid_t> = []
    private var flushScheduled = false
    private var workspaceTokens: [NSObjectProtocol] = []

    // `queue` only.
    private var windowsByPID: [pid_t: [WindowInfo]] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    @MainActor
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.track(app.processIdentifier) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Also retries observer creation for apps that were not AX-ready at launch.
            MainActor.assumeIsolated { self?.track(app.processIdentifier) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.untrack(app.processIdentifier) }
        })
        refreshAll()
    }

    /// Re-queries every app. Results land on `queue` before any later scan runs.
    @MainActor
    func refreshAll() {
        let pids = WindowInventory.candidatePIDs()
        pids.forEach(observe)
        queue.async {
            let windows = WindowInventory.snapshot(pids: pids)
            self.windowsByPID = Dictionary(grouping: windows, by: \.pid)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.observeWindows(windows) } }
        }
    }

    /// Current windows of all apps. Call on `queue`.
    func windowsOnQueue() -> [WindowInfo] {
        dispatchPrecondition(condition: .onQueue(queue))
        return windowsByPID.values.flatMap { $0 }
    }

    /// Drops an app's windows immediately, e.g. after quitting it. Call on the main thread.
    func forget(_ pid: pid_t) {
        queue.async { self.windowsByPID[pid] = nil }
    }

    @MainActor
    private func track(_ pid: pid_t) {
        guard WindowInventory.candidatePIDs().contains(pid) else { return }
        observe(pid)
        markDirty(pid)
    }

    @MainActor
    private func untrack(_ pid: pid_t) {
        if let observer = observers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        dirty.remove(pid)
        forget(pid)
    }

    @MainActor
    private func observe(_ pid: pid_t) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, inventoryCallback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for name in Self.appNotifications {
            if AXObserverAddNotification(observer, app, name as CFString, refcon) == .success { registered = true }
        }
        // Apps still launching reject observers; they are retried on activation.
        guard registered else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    @MainActor
    private func observeWindows(_ windows: [WindowInfo]) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in windows {
            guard let observer = observers[window.pid] else { continue }
            for name in Self.windowNotifications {
                AXObserverAddNotification(observer, window.element, name as CFString, refcon)
            }
        }
    }

    @MainActor
    fileprivate func markDirty(_ pid: pid_t) {
        dirty.insert(pid)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    @MainActor
    private func flush() {
        flushScheduled = false
        let pids = Array(dirty)
        dirty.removeAll()
        queue.async {
            var refreshed: [WindowInfo] = []
            for pid in pids {
                let windows = WindowInventory.windows(of: pid)
                self.windowsByPID[pid] = windows
                refreshed += windows
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.observeWindows(refreshed) } }
        }
    }
}

private func inventoryCallback(_: AXObserver, element: AXUIElement, notification _: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let cache = Unmanaged<WindowInventoryCache>.fromOpaque(refcon).takeUnretainedValue()
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return }
    MainActor.assumeIsolated { cache.markDirty(pid) }
}
