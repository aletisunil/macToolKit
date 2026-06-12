import AppKit

extension NSColor {
    /// Window background: cream (#F6F1E7) in light mode, the standard
    /// window background in dark mode.
    static let appWindowBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return .windowBackgroundColor
        }
        return NSColor(srgbRed: 246 / 255, green: 241 / 255, blue: 231 / 255, alpha: 1)
    }

    /// Elevated card surface for the settings panes — cream-white in light
    /// mode so cards stay a step brighter than the window without reading
    /// as pure white.
    static let appCardBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(calibratedWhite: 1, alpha: 0.055)
        }
        return NSColor(srgbRed: 253 / 255, green: 251 / 255, blue: 245 / 255, alpha: 1)
    }

    /// Sidebar strip — a step darker than the window background.
    static let appSidebarBackground = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(calibratedWhite: 0, alpha: 0.22)
        }
        return NSColor(srgbRed: 237 / 255, green: 231 / 255, blue: 217 / 255, alpha: 1)
    }
}
