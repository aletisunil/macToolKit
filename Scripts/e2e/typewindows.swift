// A two-window editor for the E2E tests, so typing checks never touch the
// user's documents. Each window holds a text view; its text is mirrored to
// <dir>/<title>.txt on every change, and the key window's title to <dir>/key.txt.
//
//   TypeWindows <dir> <x y w h of "left"> <x y w h of "right">
//
// Frames are global, top-left origin (as `hid` prints them), on any display.
// input-features.sh builds it into TypeWindows.app (bundle id
// com.sunilaleti.e2e.typewindows).
import AppKit

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    let dir: URL
    let frames: [(title: String, frame: CGRect)]
    var windows: [NSWindow] = []

    init(arguments: [String]) {
        let numbers = arguments.dropFirst(2).compactMap(Double.init)
        guard arguments.count > 1, numbers.count == 8 else {
            FileHandle.standardError.write(Data("usage: TypeWindows <dir> <left x y w h> <right x y w h>\n".utf8))
            exit(1)
        }
        dir = URL(fileURLWithPath: arguments[1])
        frames = [("left", CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])),
                  ("right", CGRect(x: numbers[4], y: numbers[5], width: numbers[6], height: numbers[7]))]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainHeight = NSScreen.screens[0].frame.height
        for (title, frame) in frames {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = title
            window.delegate = self
            window.isReleasedWhenClosed = false
            let textView = NSTextView()
            textView.delegate = self
            textView.font = .systemFont(ofSize: 18)
            window.contentView = textView
            window.setFrame(CGRect(x: frame.minX, y: mainHeight - frame.maxY,
                                   width: frame.width, height: frame.height), display: true)
            window.makeFirstResponder(textView)
            write("", to: title)
            windows.append(window)
        }
        windows[1].orderFront(nil)
        windows[0].makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        write(window.title, to: "key")
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let title = textView.window?.title else { return }
        write(textView.string, to: title)
    }

    private func write(_ text: String, to name: String) {
        try? text.write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Delegate(arguments: CommandLine.arguments)
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                         keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu
app.run()
