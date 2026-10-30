import CoreGraphics

/// Maps Mission Control thumbnails back to real windows.
///
/// Primary: while Mission Control is open the window server reports each window's bounds as
/// its thumbnail frame, so a thumbnail's frame identifies exactly one window ID and owner, and
/// the ID identifies the AX window (via `_AXUIElementGetWindow`). No titles involved — which
/// matters because AX titles can differ from what Mission Control shows (Chromium browsers
/// append " - Microsoft Edge" and profile names).
///
/// Fallback, for thumbnails no window's bounds match: windows with an identical title, ranked
/// by aspect ratio (Mission Control scales uniformly) and rough position. Ambiguous matches are
/// downgraded rather than guessed.
enum WindowMatcher {
    /// Points of slack when comparing window-server bounds to thumbnail frames.
    static let boundsTolerance: CGFloat = 1
    /// Maximum |log(aspect ratio)| difference for a window to be considered at all.
    static let aspectTolerance = 0.08
    /// Weight of normalized center distance relative to aspect difference.
    static let positionWeight = 0.25
    /// How much cheaper the chosen window must be than every alternative to count as certain.
    static let confidenceMargin = 0.05

    static func resolve(_ thumbnails: [Thumbnail], windows: [WindowInfo], cgWindows: [CGWindowSummary]) -> [ResolvedThumbnail] {
        let windowsByID = Dictionary(windows.compactMap { w in w.windowID.map { ($0, w) } }, uniquingKeysWith: { a, _ in a })
        var resolved: [Int: ResolvedThumbnail] = [:]
        var claimed = Set<CGWindowID>()
        for (t, thumb) in thumbnails.enumerated() {
            let hits = cgWindows.filter { sameFrame($0.bounds, thumb.frame) }
            guard hits.count == 1, let hit = hits.first else { continue }
            claimed.insert(hit.windowID)
            let window = windowsByID[hit.windowID]
            resolved[t] = ResolvedThumbnail(
                thumbnail: thumb,
                pid: hit.pid,
                window: window,
                // Owner is certain; the exact window only once its AX element is known.
                confidence: window != nil ? .window : .app,
                cost: 0
            )
        }

        let rest = thumbnails.indices.filter { resolved[$0] == nil }
        let remainingWindows = windows.filter { $0.windowID.map { !claimed.contains($0) } ?? true }
        for (t, item) in zip(rest, resolveByTitle(rest.map { thumbnails[$0] }, windows: remainingWindows, cgWindows: cgWindows)) {
            resolved[t] = item
        }
        return thumbnails.indices.map { resolved[$0]! }
    }

    private static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= boundsTolerance && abs(a.minY - b.minY) <= boundsTolerance
            && abs(a.width - b.width) <= boundsTolerance && abs(a.height - b.height) <= boundsTolerance
    }

    private static func resolveByTitle(_ thumbnails: [Thumbnail], windows: [WindowInfo], cgWindows: [CGWindowSummary]) -> [ResolvedThumbnail] {
        struct Pair { let thumb: Int; let window: Int; let cost: Double }

        let windowsByTitle = Dictionary(grouping: windows.indices, by: { normalize(windows[$0].title) })
        var candidates = [[Pair]](repeating: [], count: thumbnails.count)
        for (t, thumb) in thumbnails.enumerated() {
            for w in windowsByTitle[normalize(thumb.title)] ?? [] {
                if let c = cost(thumb, windows[w]) {
                    candidates[t].append(Pair(thumb: t, window: w, cost: c))
                }
            }
            candidates[t].sort { $0.cost < $1.cost }
        }

        // Greedy global assignment, cheapest pairs first.
        var assigned: [Int: Pair] = [:]
        var usedWindows = Set<Int>()
        for pair in candidates.flatMap({ $0 }).sorted(by: { $0.cost < $1.cost })
        where assigned[pair.thumb] == nil && !usedWindows.contains(pair.window) {
            assigned[pair.thumb] = pair
            usedWindows.insert(pair.window)
        }

        return thumbnails.enumerated().map { t, thumb in
            guard let pair = assigned[t] else {
                return fallback(thumb, cgWindows: cgWindows)
            }
            let window = windows[pair.window]
            let alternatives = candidates[t].filter { $0.window != pair.window }
            let confidence: MatchConfidence
            if alternatives.allSatisfy({ $0.cost - pair.cost >= confidenceMargin }) {
                confidence = .window
            } else if alternatives.allSatisfy({ windows[$0.window].pid == window.pid }) {
                confidence = .app
            } else {
                confidence = .none
            }
            return ResolvedThumbnail(
                thumbnail: thumb,
                pid: confidence >= .app ? window.pid : nil,
                window: confidence == .window ? window : nil,
                confidence: confidence,
                cost: pair.cost
            )
        }
    }

    /// Owner-only match through window server names, used when the app exposes no matching AX window.
    private static func fallback(_ thumb: Thumbnail, cgWindows: [CGWindowSummary]) -> ResolvedThumbnail {
        let title = normalize(thumb.title)
        let owners = Set(cgWindows.filter { !title.isEmpty && $0.name == title }.map(\.pid))
        if owners.count == 1, let pid = owners.first {
            return ResolvedThumbnail(thumbnail: thumb, pid: pid, window: nil, confidence: .app, cost: nil)
        }
        return ResolvedThumbnail(thumbnail: thumb, pid: nil, window: nil, confidence: .none, cost: nil)
    }

    private static func cost(_ thumb: Thumbnail, _ window: WindowInfo) -> Double? {
        let aspect = aspectDifference(thumb.frame, window.frame)
        guard aspect < aspectTolerance else { return nil }
        let display = thumb.displayFrame.isEmpty ? thumb.frame : thumb.displayFrame
        let a = normalizedCenter(thumb.frame, in: display)
        let b = normalizedCenter(window.frame, in: display)
        return aspect + positionWeight * hypot(a.x - b.x, a.y - b.y)
    }

    private static func aspectDifference(_ a: CGRect, _ b: CGRect) -> Double {
        guard a.height > 0, b.height > 0, a.width > 0, b.width > 0 else { return .infinity }
        return abs(log((a.width / a.height) / (b.width / b.height)))
    }

    private static func normalizedCenter(_ rect: CGRect, in container: CGRect) -> CGPoint {
        CGPoint(x: (rect.midX - container.minX) / max(container.width, 1),
                y: (rect.midY - container.minY) / max(container.height, 1))
    }

    private static func normalize(_ title: String?) -> String {
        title ?? ""
    }
}
