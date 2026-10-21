import AppKit

/// The window a click at a point would land on.
///
/// Walking `CGWindowListCopyWindowInfo` front to back is not enough: the Dock
/// owns a transparent, screen-sized window at the Dock level that sits above
/// every app window but only takes events over the Dock itself. The window
/// list has no notion of that event shape; the window server's own hit test
/// does. Callers are event-tap threads, so this never touches the main actor.
enum WindowHitTest {
    struct Hit: Sendable {
        let windowID: CGWindowID
        let pid: pid_t
        let layer: Int
        /// Global display coordinates, origin at the top left of the main
        /// display - the same space as `CGEvent.location`.
        let bounds: CGRect
    }

    /// `point` in `CGEvent.location` coordinates.
    static func window(at point: CGPoint) -> Hit? {
        if let id = PrivateCGS.windowID(at: point) {
            return (CGWindowListCopyWindowInfo(.optionIncludingWindow, id)
                as? [[String: Any]])?.first.flatMap(hit)
        }
        return fromWindowList(at: point)
    }

    /// Fallback without the private hit test: the frontmost window whose
    /// frame contains the point, skipping the Dock's screen-sized overlay.
    private static func fromWindowList(at point: CGPoint) -> Hit? {
        guard let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                  as? [[String: Any]]
        else { return nil }
        let displays = activeDisplayBounds()
        return list.lazy.compactMap(hit).first { hit in
            guard hit.bounds.contains(point) else { return false }
            let isDockOverlay = NSRunningApplication(processIdentifier: hit.pid)?
                .bundleIdentifier == "com.apple.dock" && displays.contains(hit.bounds)
            return !isDockOverlay
        }
    }

    private static func hit(_ info: [String: Any]) -> Hit? {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                  .flatMap({ CGRect(dictionaryRepresentation: $0) })
        else { return nil }
        return Hit(windowID: id, pid: pid,
                   layer: info[kCGWindowLayer as String] as? Int ?? 0,
                   bounds: bounds)
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }
}
