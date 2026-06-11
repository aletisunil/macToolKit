import AppKit

extension NSColor {
    /// Window background: warm off-white (#FAF9F6) in light mode, the
    /// standard window background in dark mode.
    static let appWindowBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return .windowBackgroundColor
        }
        return NSColor(srgbRed: 250 / 255, green: 249 / 255, blue: 246 / 255, alpha: 1)
    }

    /// Elevated card surface for the settings panes.
    static let appCardBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(calibratedWhite: 1, alpha: 0.055)
        }
        return .white
    }

    /// Sidebar strip — a step darker than the window background.
    static let appSidebarBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(calibratedWhite: 0, alpha: 0.22)
        }
        return NSColor(srgbRed: 241 / 255, green: 240 / 255, blue: 236 / 255, alpha: 1)
    }
}
