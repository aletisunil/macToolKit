// A one-window app for the E2E tests: its window can't grow past a maximum
// size, and it has no Window menu, so it has none of the system's tiling
// commands (Fill, Return to Previous Size). That's the case Maximize Windows
// handles by setting the frame itself.
//
// input-features.sh builds it into TestWindow.app (bundle id
// com.sunilaleti.e2e.testwindow).
//
// With --slow-activation (open … --args --slow-activation) the main thread
// is busy for 0.4 s each time the app becomes active, so its window is
// raised well after the system announces the activation, and its AX
// requests time out meanwhile. cmux raises its window late in the same way
// (switcher-selection.sh).
import AppKit

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 500, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Test Window"
        window.contentMaxSize = NSSize(width: 900, height: 600)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        if CommandLine.arguments.contains("--slow-activation") { usleep(400_000) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
// An app menu only: no Window menu, so no tiling commands.
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                         keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu
app.run()
