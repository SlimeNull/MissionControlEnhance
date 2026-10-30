import AppKit
import ApplicationServices

/// Dumps Dock's full accessibility tree to a log file, for adapting to new macOS releases.
enum DockTreeExporter {
    static func export(after delay: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
            guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: MissionControlMonitor.dockBundleID).first else { return }
            var lines = ["macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", ""]
            dump(AXUIElementCreateApplication(dock.processIdentifier), depth: 0, into: &lines)

            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MissionControlEnhance")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = dir.appendingPathComponent("dock-ax-\(formatter.string(from: Date())).txt")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private static func dump(_ element: AXUIElement, depth: Int, into lines: inout [String]) {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        let skipped: Set<String> = [kAXChildrenAttribute, kAXParentAttribute, kAXTopLevelUIElementAttribute, kAXWindowAttribute]
        let attributes = ((names as? [String]) ?? []).filter { !skipped.contains($0) }.map { "\($0)=\(describe(AX.attribute(element, $0)))" }
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        lines.append(String(repeating: "  ", count: depth) + attributes.joined(separator: " | ") + "  actions=\((actions as? [String]) ?? [])")
        guard depth < 12 else { return }
        for child in AX.children(element) {
            dump(child, depth: depth + 1, into: &lines)
        }
    }

    private static func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            return String(describing: value)
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "<element>" }
        if let array = value as? [Any] { return "[\(array.count) items]" }
        return String(describing: value)
    }
}
