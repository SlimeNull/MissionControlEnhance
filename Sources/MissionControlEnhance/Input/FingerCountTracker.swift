import Foundation

/// Tracks how many fingers rest on each trackpad, via the private MultitouchSupport framework.
///
/// A physical three-finger click arrives as an ordinary left mouse-down, so the event tap
/// asks this tracker how many fingers were down at that moment. Loaded with dlopen so a
/// missing or changed framework only disables the feature.
final class FingerCountTracker: @unchecked Sendable {
    static let shared = FingerCountTracker()

    fileprivate typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32
    private typealias CreateList = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer?, ContactCallback?) -> Void
    private typealias StartDevice = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias StopDevice = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private struct Symbols {
        let createList: CreateList
        let register: RegisterCallback
        let unregister: RegisterCallback
        let start: StartDevice
        let stop: StopDevice
    }

    /// Frames older than this are treated as "no fingers"; resting fingers report continuously.
    private static let freshness: TimeInterval = 0.25

    private let symbols: Symbols?
    private let lock = NSLock()
    private var frames: [UnsafeMutableRawPointer: (count: Int, time: TimeInterval)] = [:]
    private var devices: CFArray?
    private var clients = 0

    var isAvailable: Bool { symbols != nil }

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createList = dlsym(handle, "MTDeviceCreateList"),
              let register = dlsym(handle, "MTRegisterContactFrameCallback"),
              let unregister = dlsym(handle, "MTUnregisterContactFrameCallback"),
              let start = dlsym(handle, "MTDeviceStart"),
              let stop = dlsym(handle, "MTDeviceStop")
        else {
            symbols = nil
            return
        }
        symbols = Symbols(
            createList: unsafeBitCast(createList, to: CreateList.self),
            register: unsafeBitCast(register, to: RegisterCallback.self),
            unregister: unsafeBitCast(unregister, to: RegisterCallback.self),
            start: unsafeBitCast(start, to: StartDevice.self),
            stop: unsafeBitCast(stop, to: StopDevice.self)
        )
    }

    /// Starts listening while at least one client holds the tracker.
    func acquire() {
        lock.lock()
        clients += 1
        let shouldStart = clients == 1
        lock.unlock()
        if shouldStart { startDevices() }
    }

    func release() {
        lock.lock()
        clients = max(clients - 1, 0)
        let shouldStop = clients == 0
        lock.unlock()
        if shouldStop { stopDevices() }
    }

    /// Highest finger count across trackpads with a recent frame.
    var currentCount: Int {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        return frames.values.filter { now - $0.time < Self.freshness }.map(\.count).max() ?? 0
    }

    fileprivate func record(device: UnsafeMutableRawPointer, count: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        frames[device] = (count, now)
        lock.unlock()
    }

    private func startDevices() {
        guard let symbols, let list = symbols.createList()?.takeRetainedValue() else { return }
        for device in Self.pointers(in: list) {
            symbols.register(device, contactFrameCallback)
            symbols.start(device, 0)
        }
        lock.lock()
        devices = list
        lock.unlock()
    }

    private func stopDevices() {
        lock.lock()
        let list = devices
        devices = nil
        frames.removeAll()
        lock.unlock()
        guard let symbols, let list else { return }
        for device in Self.pointers(in: list) {
            symbols.unregister(device, contactFrameCallback)
            symbols.stop(device)
        }
    }

    private static func pointers(in list: CFArray) -> [UnsafeMutableRawPointer] {
        (0..<CFArrayGetCount(list)).compactMap { CFArrayGetValueAtIndex(list, $0).map { UnsafeMutableRawPointer(mutating: $0) } }
    }
}

private let contactFrameCallback: FingerCountTracker.ContactCallback = { device, _, count, _, _ in
    if let device {
        FingerCountTracker.shared.record(device: device, count: Int(count))
    }
    return 0
}
