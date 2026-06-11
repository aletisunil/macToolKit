import AppKit

@MainActor
enum DockIconManager {
    /// App ships as LSUIElement (accessory). Promote to .regular when the user
    /// wants a dock icon; the menu bar items remain either way.
    static func apply(showInDock: Bool) {
        let target: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
    }
}
