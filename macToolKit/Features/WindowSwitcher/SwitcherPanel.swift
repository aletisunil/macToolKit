import AppKit
import SwiftUI

/// Borderless, non-activating panel hosting the switcher UI. It never
/// becomes key — keyboard input arrives through the event tap — so the
/// frontmost app keeps focus until a window is committed. Mouse hover and
/// clicks still work on a non-key panel. The exception is the opt-in
/// assistive mode, where the panel does become key so VoiceOver can land
/// on the tiles.
@MainActor
final class SwitcherPanel {
    struct Options {
        var screen: NSScreen?
        var fadeIn = true
        var appearance: NSAppearance?
        var becomeKey = false
    }

    private var panel: NSPanel?
    private var options = Options()

    func show(content: some View, options: Options) {
        hide()
        self.options = options

        let hosting = NSHostingController(rootView: content)
        let panel = KeyablePanel(contentViewController: hosting)
        panel.allowsKey = options.becomeKey
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.appearance = options.appearance

        // Size to fit the SwiftUI content, positioned upper-middle like the
        // system switcher, on the screen the controller picked.
        panel.setContentSize(hosting.view.fittingSize)
        place(panel)

        if options.fadeIn {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
        if options.becomeKey {
            panel.makeKey()
        }
        self.panel = panel
    }

    /// Re-centers after a content-driven size change (list refresh landing).
    func recenter() {
        guard let panel else { return }
        guard let contentView = panel.contentViewController?.view else { return }
        let fitting = contentView.fittingSize
        guard fitting != panel.frame.size else { return }
        panel.setContentSize(fitting)
        place(panel)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func place(_ panel: NSPanel) {
        let screen = options.screen ?? Self.screenWithMouse()
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + (frame.height - size.height) * 0.55))
    }

    private static func screenWithMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

/// Borderless panels refuse key status by default; assistive mode needs it.
private final class KeyablePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}
