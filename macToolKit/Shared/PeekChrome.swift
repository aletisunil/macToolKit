import CoreGraphics

/// Quick Look draws its own close and full-screen buttons over the top-left
/// corner of whatever the extension renders. There is no API to hide or query
/// them — the window belongs to the host process, and the extension's view is
/// remote-hosted — so the header reserves room for them and has to know when
/// that room is no longer needed.
enum PeekChrome {
    /// Room reserved for the host's buttons while the preview is a panel.
    static let panelInset: CGFloat = 34
    /// In full screen the buttons ride the menu bar strip and auto-hide, so
    /// only ordinary padding is wanted.
    static let fullScreenInset: CGFloat = 12

    static let panelHeaderHeight: CGFloat = 96
    static let fullScreenHeaderHeight: CGFloat = 62

    /// Horizontal inset a `.plain` SwiftUI `List` adds to every row on macOS.
    /// Undocumented and not reachable through `contentMargins`, so the rows
    /// cancel it with a negative `listRowInsets` to keep the columns lined up
    /// with the header. Measured against the previous LazyVStack layout.
    static let listRowInset: CGFloat = 8

    /// A Quick Look panel is a window, so it can never grow past the screen's
    /// visible frame — the area below the menu bar. Content taller than that
    /// is therefore full screen, with no margin to guess at.
    static func isFullScreen(contentHeight: CGFloat, visibleFrameHeight: CGFloat) -> Bool {
        guard visibleFrameHeight > 0 else { return false }
        return contentHeight > visibleFrameHeight
    }

    static func headerInset(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? fullScreenInset : panelInset
    }

    static func headerHeight(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? fullScreenHeaderHeight : panelHeaderHeight
    }
}
