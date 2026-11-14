// A one-window app for the Smooth Scrolling E2E checks: a large scrollable
// canvas that records what an app actually experiences when the wheel turns.
//
//   ScrollView.app/Contents/MacOS/ScrollView <log-file>
//
// The log gets one line per event, timestamps in milliseconds since launch:
//   E <ms> <phase> <momentum> <precise 0|1> <scrollingDeltaX> <scrollingDeltaY> <modifiers>
//     <linesX> <linesY> <deltaX> <deltaY>
//       a scroll-wheel NSEvent the window received. linesX/Y are the whole
//       lines in the event (what Carbon and CGEvent readers see), deltaX/Y
//       NSEvent's fractional lines (what a terminal turns into wheel reports)
//   P <ms> <x> <y>
//       the visible origin of the canvas after it moved
//
// The canvas starts in the middle so it can move in every direction.
// input-features.sh builds it into ScrollView.app (bundle id
// com.sunilaleti.e2e.scrollview).
import AppKit

let logPath = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
    ?? NSTemporaryDirectory() + "scrollview.log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath)!
let start = Date()

func log(_ line: String) {
    let ms = String(format: "%.1f", Date().timeIntervalSince(start) * 1000)
    logHandle.write("\(line.prefix(1)) \(ms)\(line.dropFirst(1))\n".data(using: .utf8)!)
}

final class RecordingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        var mods: [String] = []
        if event.modifierFlags.contains(.command) { mods.append("cmd") }
        if event.modifierFlags.contains(.option) { mods.append("opt") }
        if event.modifierFlags.contains(.control) { mods.append("ctrl") }
        if event.modifierFlags.contains(.shift) { mods.append("shift") }
        let cg = event.cgEvent
        let linesX: Int64 = cg?.getIntegerValueField(.scrollWheelEventDeltaAxis2) ?? 0
        let linesY: Int64 = cg?.getIntegerValueField(.scrollWheelEventDeltaAxis1) ?? 0
        let lineFields = "\(linesX) \(linesY) \(Double(event.deltaX)) \(Double(event.deltaY))"
        log("E \(event.phase.rawValue) \(event.momentumPhase.rawValue) "
            + "\(event.hasPreciseScrollingDeltas ? 1 : 0) "
            + "\(event.scrollingDeltaX) \(event.scrollingDeltaY) "
            + (mods.isEmpty ? "-" : mods.joined(separator: "+")) + " " + lineFields)
        super.scrollWheel(with: event)
    }
}

final class Canvas: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Stripes, so a person watching can see motion and judderiness.
        // Only the dirty rows: walking all 5000 every frame makes the app
        // slow enough that the window server merges queued scroll events.
        let first = Int(dirtyRect.minY) / 40 * 40
        for row in stride(from: first, to: Int(dirtyRect.maxY), by: 40) {
            (row / 40 % 2 == 0 ? NSColor.systemTeal : NSColor.systemIndigo)
                .withAlphaComponent(0.25).setFill()
            NSRect(x: 0, y: CGFloat(row), width: bounds.width, height: 40).fill()
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 500),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Scroll View"

        let scroll = RecordingScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let canvas = Canvas(frame: NSRect(x: 0, y: 0, width: 20_000, height: 200_000))
        scroll.documentView = canvas
        window.contentView = scroll

        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                log("P \(clip.bounds.origin.x) \(clip.bounds.origin.y)")
            }
        }
        clip.scroll(to: NSPoint(x: 10_000, y: 100_000))
        scroll.reflectScrolledClipView(clip)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Delegate()
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
