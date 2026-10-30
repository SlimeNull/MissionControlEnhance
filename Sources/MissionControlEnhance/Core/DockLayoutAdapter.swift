import ApplicationServices

/// Reads window thumbnails out of Dock's accessibility tree while Mission Control is open.
/// Isolated behind a protocol because the tree layout is private and may change between macOS releases.
protocol DockLayoutAdapter: Sendable {
    /// Returns nil when Mission Control is not showing.
    func thumbnails(dock: AXUIElement) -> [Thumbnail]?
}

/// Layout observed on macOS 26:
/// `AXApplication(Dock) > AXGroup#mc > AXGroup#mc.display > AXGroup#mc.windows > AXButton(title, frame)`.
struct IdentifierDockLayout: DockLayoutAdapter {
    func thumbnails(dock: AXUIElement) -> [Thumbnail]? {
        guard let mc = find(in: dock, identifier: "mc", depth: 2) else { return nil }
        var result: [Thumbnail] = []
        for display in descendants(of: mc, identifier: "mc.display", depth: 2) {
            let displayFrame = AX.frame(display) ?? .zero
            for group in descendants(of: display, identifier: "mc.windows", depth: 2) {
                for button in AX.children(group) where AX.role(button) == kAXButtonRole {
                    guard let frame = AX.frame(button), frame.width > 1, frame.height > 1 else { continue }
                    result.append(Thumbnail(
                        element: button,
                        title: AX.string(button, kAXTitleAttribute),
                        frame: frame,
                        displayFrame: displayFrame
                    ))
                }
            }
        }
        return result
    }

    private func find(in element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
        descendants(of: element, identifier: identifier, depth: depth).first
    }

    private func descendants(of element: AXUIElement, identifier: String, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var found: [AXUIElement] = []
        for child in AX.children(element) {
            // Dock items live in an AXList and never contain Mission Control content.
            if AX.role(child) == kAXListRole { continue }
            if AX.identifier(child) == identifier {
                found.append(child)
            } else {
                found += descendants(of: child, identifier: identifier, depth: depth - 1)
            }
        }
        return found
    }
}
