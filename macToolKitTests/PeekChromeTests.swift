import Foundation
import Testing

@testable import macToolKit

/// The header reserves room for Quick Look's own close and full-screen
/// buttons. Nothing in the extension can ask the host where those buttons are,
/// so the panel/full-screen call is made from the geometry alone.
struct PeekChromeTests {
    /// 1080p with a menu bar: a panel is capped at the visible frame, so
    /// anything taller than it can only be full screen.
    private let visible: CGFloat = 1042

    @Test func contentTallerThanTheVisibleFrameIsFullScreen() {
        #expect(PeekChrome.isFullScreen(contentHeight: 1080, visibleFrameHeight: visible))
    }

    @Test func aPanelFillingTheVisibleFrameIsNotFullScreen() {
        #expect(!PeekChrome.isFullScreen(contentHeight: visible, visibleFrameHeight: visible))
        #expect(!PeekChrome.isFullScreen(contentHeight: 640, visibleFrameHeight: visible))
    }

    /// `NSScreen` can report a zero frame while a display is waking or being
    /// reconfigured; guessing "full screen" there would jump the layout.
    @Test func unknownScreenGeometryStaysAPanel() {
        #expect(!PeekChrome.isFullScreen(contentHeight: 1080, visibleFrameHeight: 0))
    }

    @Test func fullScreenDropsTheReservedGapAndShortensTheHeader() {
        #expect(PeekChrome.headerInset(isFullScreen: false) == PeekChrome.panelInset)
        #expect(PeekChrome.headerInset(isFullScreen: true) == PeekChrome.fullScreenInset)
        #expect(PeekChrome.fullScreenInset < PeekChrome.panelInset)
        #expect(PeekChrome.headerHeight(isFullScreen: true)
            < PeekChrome.headerHeight(isFullScreen: false))
    }

    /// The header has to stay taller than the gap it reserves, or the icon and
    /// title have nowhere to sit.
    @Test func headerAlwaysLeavesRoomBelowTheReservedGap() {
        for fullScreen in [true, false] {
            #expect(PeekChrome.headerHeight(isFullScreen: fullScreen)
                > PeekChrome.headerInset(isFullScreen: fullScreen) + 40)
        }
    }
}
