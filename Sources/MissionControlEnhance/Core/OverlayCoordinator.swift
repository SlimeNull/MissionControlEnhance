import AppKit
@preconcurrency import ApplicationServices
import Combine

/// Runs one overlay session per Mission Control invocation:
/// scan Dock → match windows → render → handle input → perform actions.
@MainActor
final class OverlayCoordinator {
    private let prefs: Preferences
    private let monitor = MissionControlMonitor()
    private let overlay = OverlayController()
    private let input = InputInterceptor()
    private let actions = WindowActions()
    private let adapter: DockLayoutAdapter = IdentifierDockLayout()
    private let inventory: WindowInventoryCache

    private var isActive = false
    /// Incremented per session so late async results from a previous session are dropped.
    private var session = 0
    private var windows: [WindowInfo] = []
    private var cgWindows: [CGWindowSummary] = []
    private var lastThumbnails: [Thumbnail] = []
    private var items: [ResolvedThumbnail] = []
    private var dismissed: Set<ElementKey> = []
    private var notices: [ElementKey: String] = [:]
    private var noticeTokens: [ElementKey: Int] = [:]
    private var nextToken = 0
    private var armedQuit: ElementKey?
    private var hovered: ElementKey?
    private var hoveredButton: ButtonKind?
    private var iconCache: [pid_t: NSImage] = [:]

    /// Whether overlays are on screen; input targets only exist while they are.
    private var isVisible = false
    /// Reveal (again) as soon as the next scan lands.
    private var revealOnNextScan = false
    private var isSwiping = false
    private var suspendToken = 0
    private var pollTimer: Timer?
    private var pollCount = 0
    private var scanInFlight = false
    private var holdsFingerTracker = false
    private var cancellables: Set<AnyCancellable> = []

    init(prefs: Preferences) {
        self.prefs = prefs
        inventory = WindowInventoryCache(queue: DispatchQueue(label: "MissionControlEnhance.ax", qos: .userInteractive))
    }

    func start() {
        inventory.start()

        monitor.onShown = { [weak self] in self?.enter() }
        monitor.onHidden = { [weak self] in self?.exit() }
        monitor.start()

        input.target = { [weak self] point, source in self?.target(at: point, source: source) }
        input.onHover = { [weak self] point in self?.hover(at: point) }
        input.onActivate = { [weak self] target, flags in self?.activate(target, flags: flags) }
        input.onDisruption = { [weak self] disruption in self?.handle(disruption) }
        input.isThreeFingerPress = { FingerCountTracker.shared.currentCount == 3 }
        if !input.install() {
            Log.input.error("Event tap unavailable; buttons and quick actions are disabled")
        }

        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.isActive else { return }
                if !self.prefs.enabled { self.exit() } else { self.rematch() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Session lifecycle

    /// Mission Control has finished zooming in (`AXExposeShowAllWindows` arrives right after the
    /// animation). Overlays are rendered hidden and revealed once the first match is in.
    private func enter() {
        guard prefs.enabled, !isActive else { return }
        isActive = true
        session += 1
        windows = []
        cgWindows = []
        lastThumbnails = []
        items = []
        dismissed = []
        notices = [:]
        armedQuit = nil
        hovered = nil
        hoveredButton = nil
        iconCache = [:]

        overlay.clear()
        isVisible = false
        revealOnNextScan = true
        isSwiping = false
        input.isEnabled = true
        if prefs.threeFingerClickEnabled, prefs.threeFingerClickAction != .none, FingerCountTracker.shared.isAvailable {
            FingerCountTracker.shared.acquire()
            holdsFingerTracker = true
        }

        // Match immediately against the warm cache so icons show without delay, then
        // refresh everything in the background in case the cache was stale.
        scan()
        inventory.refreshAll()
        scan(force: true)

        // Dock occasionally reports pre-layout frames right after opening, so poll quickly at
        // first and slowly afterwards.
        pollCount = 0
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Mission Control has started zooming out: overlays disappear immediately.
    private func exit() {
        guard isActive else { return }
        isActive = false
        isVisible = false
        isSwiping = false
        session += 1
        pollTimer?.invalidate()
        pollTimer = nil
        input.isEnabled = false
        if holdsFingerTracker {
            FingerCountTracker.shared.release()
            holdsFingerTracker = false
        }
        overlay.clear()
        items = []
        windows = []
        cgWindows = []
    }

    /// Hides overlays the moment input starts moving Mission Control's windows, instead of
    /// waiting for Dock. If Mission Control is still open once things settle (a swipe that was
    /// let go, a window dropped back onto the grid, a desktop switch), thumbnails are re-scanned
    /// — they may belong to another desktop now — and overlays come back.
    private func handle(_ disruption: Disruption) {
        guard isActive else { return }
        switch disruption {
        case .closingInput:
            suspend(revealAfter: 0.3)
        case .spaceSwitchKey:
            suspend(revealAfter: 0.45)
        case .swipeBegan:
            isSwiping = true
            suspend(revealAfter: nil)
        case .swipeEnded:
            // Covers the ~0.25s spring-back of a released swipe.
            isSwiping = false
            suspend(revealAfter: 0.35)
        }
    }

    private func suspend(revealAfter delay: TimeInterval?) {
        overlay.suspend()
        isVisible = false
        revealOnNextScan = false
        suspendToken += 1
        guard let delay else { return }
        let token = suspendToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.suspendToken == token, !self.isSwiping else { return }
                self.revealOnNextScan = true
                self.scan(force: true)
            }
        }
    }

    private func poll() {
        pollCount += 1
        if pollCount <= 10 || pollCount % 5 == 0 {
            scan()
        }
    }

    // MARK: - Scanning and matching

    /// Reads Dock's thumbnails, the cached window inventory and the window server's bounds on
    /// the AX queue. Scans are queued behind any pending inventory refresh, so they always see
    /// the latest windows; the bounds are re-read every time because they only equal the
    /// thumbnail frames while Mission Control is showing them.
    private func scan(force: Bool = false) {
        guard let dock = monitor.dockElement else { return }
        if scanInFlight, !force { return }
        scanInFlight = true
        let session = self.session
        let adapter = self.adapter
        let inventory = self.inventory
        inventory.queue.async { [weak self] in
            let thumbnails = adapter.thumbnails(dock: dock)
            let windows = inventory.windowsOnQueue()
            let cg = WindowInventory.cgWindows()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishScan(session: session, thumbnails: thumbnails, windows: windows, cgWindows: cg)
                }
            }
        }
    }

    private func finishScan(session: Int, thumbnails: [Thumbnail]?, windows: [WindowInfo], cgWindows: [CGWindowSummary]) {
        scanInFlight = false
        guard isActive, session == self.session, let thumbnails else { return }
        self.windows = windows
        self.cgWindows = cgWindows
        lastThumbnails = thumbnails
        rematch()
        if revealOnNextScan, !isSwiping {
            revealOnNextScan = false
            isVisible = true
            overlay.reveal()
        }
    }

    private func rematch() {
        let excluded = Set(prefs.excludedBundleIDs)
        items = WindowMatcher.resolve(lastThumbnails, windows: windows, cgWindows: cgWindows).filter { item in
            guard !dismissed.contains(item.key) else { return false }
            guard let pid = item.pid, let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return true }
            return !excluded.contains(bundleID)
        }
        render()
    }

    // MARK: - Rendering

    private func render() {
        guard isActive else { return }
        let overlayItems = items.map { item in
            OverlayItem(
                key: item.key,
                frame: item.thumbnail.frame,
                icon: item.confidence >= .app ? item.pid.flatMap(icon(for:)) : nil,
                buttons: hovered == item.key ? availableButtons(for: item) : [],
                hoveredButton: hovered == item.key ? hoveredButton : nil,
                armedQuit: armedQuit == item.key,
                notice: notices[item.key],
                debugText: prefs.debugMode ? debugText(for: item) : nil,
                confidence: item.confidence
            )
        }
        overlay.render(overlayItems, style: prefs.overlayStyle)
    }

    private func icon(for pid: pid_t) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        iconCache[pid] = icon
        return icon
    }

    private func availableButtons(for item: ResolvedThumbnail) -> [ButtonKind] {
        prefs.enabledButtons.filter { button in
            switch button {
            case .close, .minimize: item.confidence == .window
            case .quit: item.confidence >= .app
            }
        }
    }

    private func allows(_ action: QuickAction, on item: ResolvedThumbnail) -> Bool {
        switch action {
        case .none: false
        case .close, .minimize: item.confidence == .window
        case .quit: item.confidence >= .app
        }
    }

    private func debugText(for item: ResolvedThumbnail) -> String {
        let app = item.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "?"
        let cost = item.cost.map { String(format: "%.3f", $0) } ?? "-"
        let fingers = holdsFingerTracker ? String(localized: " · Fingers \(FingerCountTracker.shared.currentCount)") : ""
        return " \(app) · \(item.confidence) · \(cost)\(fingers)\n \(item.thumbnail.title ?? String(localized: "<untitled>"))"
    }

    // MARK: - Input

    private func item(at point: CGPoint) -> ResolvedThumbnail? {
        items.first { $0.thumbnail.frame.contains(point) }
    }

    private func hover(at point: CGPoint) {
        let item = self.item(at: point)
        let button = item.flatMap { buttonLayout(for: $0).button(at: point) }
        guard item?.key != hovered || button != hoveredButton else { return }
        hovered = item?.key
        hoveredButton = button
        render()
    }

    private func buttonLayout(for item: ResolvedThumbnail) -> ThumbnailLayout {
        ThumbnailLayout(frame: item.thumbnail.frame, style: prefs.overlayStyle, buttons: availableButtons(for: item))
    }

    private func target(at point: CGPoint, source: InputSource) -> InputTarget? {
        guard isVisible, let item = item(at: point) else { return nil }
        switch source {
        case .leftClick:
            return buttonLayout(for: item).button(at: point).map { InputTarget(key: item.key, kind: .button($0)) }
        case .middleClick:
            let action = prefs.middleClickAction
            return prefs.middleClickEnabled && allows(action, on: item) ? InputTarget(key: item.key, kind: .quick(action)) : nil
        case .threeFingerClick:
            let action = prefs.threeFingerClickAction
            return prefs.threeFingerClickEnabled && allows(action, on: item) ? InputTarget(key: item.key, kind: .quick(action)) : nil
        }
    }

    private func activate(_ target: InputTarget, flags: CGEventFlags) {
        guard let item = items.first(where: { $0.key == target.key }) else { return }
        switch target.kind {
        case .button(.close), .quick(.close):
            perform(.close, on: item)
        case .button(.minimize), .quick(.minimize):
            perform(.minimize, on: item)
        case .button(.quit), .quick(.quit):
            requestQuit(item, force: flags.contains(.maskAlternate))
        case .quick(.none):
            break
        }
    }

    private func requestQuit(_ item: ResolvedThumbnail, force: Bool) {
        if prefs.confirmQuit, armedQuit != item.key {
            armedQuit = item.key
            let name = item.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? String(localized: "App")
            showNotice(force ? String(localized: "Click again to force quit \(name)") : String(localized: "Click again to quit \(name)"), on: item.key, duration: 2) { [weak self] in
                if self?.armedQuit == item.key { self?.armedQuit = nil }
            }
            return
        }
        armedQuit = nil
        perform(.quit(force: force), on: item)
    }

    private func perform(_ action: WindowAction, on item: ResolvedThumbnail) {
        let session = self.session
        actions.perform(action, window: item.window, pid: item.pid) { [weak self] outcome in
            guard let self, self.isActive, session == self.session else { return }
            switch outcome {
            case .windowGone:
                self.dismissed.insert(item.key)
                if let window = item.window {
                    self.windows.removeAll { CFEqual($0.element, window.element) }
                }
            case .appTerminated(let pid):
                for other in self.items where other.pid == pid {
                    self.dismissed.insert(other.key)
                }
                self.windows.removeAll { $0.pid == pid }
                self.inventory.forget(pid)
            case .unchanged(let message):
                self.showNotice(message, on: item.key, duration: 2.5)
            }
            self.rematch()
        }
    }

    private func showNotice(_ text: String, on key: ElementKey, duration: TimeInterval, onExpire: (() -> Void)? = nil) {
        nextToken += 1
        let token = nextToken
        notices[key] = text
        noticeTokens[key] = token
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeTokens[key] == token else { return }
                self.notices[key] = nil
                self.noticeTokens[key] = nil
                onExpire?()
                self.render()
            }
        }
    }
}
