import AppKit
import SwiftUI

/// Tiny floating status capsule near the mouse pointer ("Rewriting…",
/// "Cut 3 items").
@MainActor
final class PointerHUD {
    static let shared = PointerHUD()

    private var panel: NSPanel?
    /// Bumped on every show/hide so a pending flash hide can't take down a
    /// panel that was shown after it was scheduled.
    private var generation = 0

    func show(_ text: String) {
        hide()
        let label = NSHostingView(rootView:
            Text(text)
                .font(.callout.weight(.medium))
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        )
        // Sized from the content up front: a panel built around a hosting
        // controller never grows past its initial, near-zero frame, which
        // clipped the capsule to nothing.
        let size = label.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = label
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        // Up and to the right of the pointer, kept on its screen.
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y + 16)
        if let visible = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func flash(_ text: String, seconds: TimeInterval = 1.6) {
        show(text)
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.hide()
        }
    }

    func hide() {
        generation += 1
        panel?.orderOut(nil)
        panel = nil
    }
}
