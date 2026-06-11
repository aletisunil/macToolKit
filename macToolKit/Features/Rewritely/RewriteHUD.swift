import AppKit
import SwiftUI

/// Tiny floating "Rewriting…" panel near the mouse pointer.
@MainActor
final class RewriteHUD {
    static let shared = RewriteHUD()

    private var panel: NSPanel?

    func show(_ text: String) {
        hide()
        let label = NSHostingController(rootView:
            Text(text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        )
        let panel = NSPanel(contentViewController: label)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x + 16, y: mouse.y + 16))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func flash(_ text: String, seconds: TimeInterval = 1.6) {
        show(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
