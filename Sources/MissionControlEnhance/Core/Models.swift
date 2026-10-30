import ApplicationServices

/// A window thumbnail as reported by Dock's Mission Control accessibility tree.
struct Thumbnail {
    let element: AXUIElement
    let title: String?
    /// Global AX coordinates.
    let frame: CGRect
    /// Frame of the `mc.display` group the thumbnail belongs to, in AX coordinates.
    let displayFrame: CGRect

    var key: ElementKey { ElementKey(element: element) }
}

/// A window owned by a running application, as seen through that application's AX tree.
struct WindowInfo {
    let pid: pid_t
    let element: AXUIElement
    let title: String?
    let frame: CGRect
    let windowID: CGWindowID?
}

/// An on-screen window from the window server. While Mission Control is open, `bounds` is
/// the window's thumbnail frame. Reading bounds, owner and ID needs no extra permission;
/// `name` is only filled in with Screen Recording access.
struct CGWindowSummary {
    let windowID: CGWindowID
    let pid: pid_t
    let name: String?
    let bounds: CGRect
}

enum MatchConfidence: Int, Comparable {
    /// Unknown owner: show nothing.
    case none
    /// Owning app is certain but the exact window is not: show icon and quit only.
    case app
    /// Exact window is certain: everything is allowed.
    case window

    static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ResolvedThumbnail {
    let thumbnail: Thumbnail
    let pid: pid_t?
    let window: WindowInfo?
    let confidence: MatchConfidence
    let cost: Double?

    var key: ElementKey { thumbnail.key }
}
