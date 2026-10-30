import AppKit
import ApplicationServices

/// Collects the windows Mission Control can show, straight from each application's AX tree.
enum WindowInventory {
    /// Apps worth asking for windows. Must be called on the main thread.
    @MainActor
    static func candidatePIDs() -> [pid_t] {
        let me = getpid()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && $0.processIdentifier != me && $0.bundleIdentifier != MissionControlMonitor.dockBundleID }
            .map(\.processIdentifier)
    }

    static func snapshot(pids: [pid_t]) -> [WindowInfo] {
        var perApp = [[WindowInfo]](repeating: [], count: pids.count)
        perApp.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: pids.count) { i in
                base[i] = windows(of: pids[i])
            }
        }
        return perApp.flatMap { $0 }
    }

    static func windows(of pid: pid_t) -> [WindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        return AX.elements(app, kAXWindowsAttribute).compactMap { window in
            guard AX.role(window) == kAXWindowRole,
                  AX.bool(window, kAXMinimizedAttribute) != true,
                  let frame = AX.frame(window), frame.width > 1, frame.height > 1
            else { return nil }
            return WindowInfo(
                pid: pid,
                element: window,
                title: AX.string(window, kAXTitleAttribute),
                frame: frame,
                windowID: AX.windowID(window)
            )
        }
    }

    /// Other apps' on-screen, normal-level windows from the window server.
    static func cgWindows() -> [CGWindowSummary] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let me = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            let name = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return CGWindowSummary(windowID: id, pid: pid, name: name, bounds: bounds)
        }
    }
}
