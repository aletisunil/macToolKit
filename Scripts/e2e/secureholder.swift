// A test app that turns macOS Secure Input on at launch and keeps it on for
// as long as it runs, like a browser that keeps a password field's Secure
// Input after it loses focus. It shows one small window so it can come to
// the front and be switched to.
//
//   SecureHolder.app [--background]   --background: no window, never in front
import AppKit
import Carbon.HIToolbox

let background = CommandLine.arguments.contains("--background")
let app = NSApplication.shared
app.setActivationPolicy(background ? .accessory : .regular)

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !background {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 120),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "SecureHolder"
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApp.activate()
        }
        EnableSecureEventInput()
    }
}

let delegate = Delegate()
app.delegate = delegate
app.run()
