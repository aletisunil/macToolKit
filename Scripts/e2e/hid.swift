// HID driver for the end-to-end tests: posts real input events at the HID
// level (so they pass through the app's event taps exactly like hardware
// input) and reads back window state through Accessibility.
//
// The process running this needs Accessibility access - `hid trust` checks.
//
//   hid trust                       Accessibility / event-posting access
//   hid key <keycode> [cmd|opt|shift|ctrl ...]
//   hid move <x> <y>                warp the pointer
//   hid glide <x1> <y1> <x2> <y2>   real pointer motion in 20 steps
//   hid keys <keycode>[+cmd]:d|u ...
//                                   post key downs/ups in order, print the
//                                   key events apps receive (e.g. "8d 0u 8u")
//   hid click <x> <y> [opt]         left click, optionally with ⌥
//   hid side back|forward           mouse button 4 or 5 at the pointer
//   hid buttons <n>:d|g|u ...       other-mouse down/drag/up of zero-based button
//                                   n at the pointer, print what apps receive
//                                   (e.g. "3d 3g 3u")
//   hid scroll wheel|trackpad       post a +3 scroll, print the delta apps see
//   hid button <bundle-id> close|min|zoom
//                                   center of the focused window's traffic
//                                   light, and whether it is full screen
//   hid frame <bundle-id>           focused window frame: x y w h
//   hid frames <bundle-id> <ms>     sample the focused window's on-screen
//                                   frame for ms; print how many distinct
//                                   frames it went through (1 = a jump)
//   hid popover                     whether the green button's Move & Resize
//                                   menu is on screen: open|closed
//   hid front                       frontmost app's bundle id
//   hid clipboard                   names of the files on the pasteboard
//                                   ("-" when it holds no files)
//   hid visible                     main screen's visible frame: x y w h
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement,
                           _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

let args = CommandLine.arguments
guard args.count > 1 else { fail("usage: see header") }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func number(_ index: Int) -> Double {
    guard args.count > index, let value = Double(args[index]) else { fail("missing number") }
    return value
}

func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags = [],
          button: CGMouseButton = .left, buttonNumber: Int64? = nil) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: point, mouseButton: button)
    else { fail("cannot create mouse event") }
    event.flags = flags
    if let buttonNumber {
        event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
    }
    event.post(tap: .cghidEventTap)
}

func pointer() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func focusedWindow(_ bundleID: String) -> AXUIElement {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    else { fail("\(bundleID) is not running") }
    let element = AXUIElementCreateApplication(app.processIdentifier)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString,
                                        &window) == .success, let window
    else { fail("\(bundleID) has no focused window") }
    return window as! AXUIElement
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func frame(of element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero
    var size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute) {
        AXValueGetValue(value as! AXValue, .cgPoint, &origin)
    }
    if let value = attribute(element, kAXSizeAttribute) {
        AXValueGetValue(value as! AXValue, .cgSize, &size)
    }
    return CGRect(origin: origin, size: size)
}

func printRect(_ rect: CGRect) {
    print(Int(rect.minX.rounded()), Int(rect.minY.rounded()),
          Int(rect.width.rounded()), Int(rect.height.rounded()))
}

switch args[1] {
case "trust":
    print(AXIsProcessTrusted() && CGPreflightPostEventAccess() ? "trusted" : "untrusted")

case "key":
    var flags: CGEventFlags = []
    for modifier in args.dropFirst(3) {
        switch modifier {
        case "cmd": flags.insert(.maskCommand)
        case "opt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        default: fail("unknown modifier \(modifier)")
        }
    }
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(number(2)), keyDown: down)
        else { fail("cannot create key event") }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(20_000)
    }

case "move":
    post(.mouseMoved, at: CGPoint(x: number(2), y: number(3)))

case "glide":
    let (x1, y1, x2, y2) = (number(2), number(3), number(4), number(5))
    for step in 0...20 {
        let t = Double(step) / 20
        post(.mouseMoved, at: CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t))
        usleep(10_000)
    }

case "keys":
    // Same listener as "scroll": a tail-appended session tap sees what apps
    // get, after every HID-level tap had its say.
    let steps: [(CGKeyCode, Bool, CGEventFlags)] = args.dropFirst(2).map { spec in
        let parts = spec.split(separator: ":")
        guard parts.count == 2 else { fail("bad key spec \(spec)") }
        let key = parts[0].split(separator: "+")
        guard let code = CGKeyCode(key[0]) else { fail("bad keycode in \(spec)") }
        return (code, parts[1] == "d", key.contains("cmd") ? .maskCommand : [])
    }
    let seen = NSMutableArray()
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, refcon in
        let seen = Unmanaged<NSMutableArray>.fromOpaque(refcon!).takeUnretainedValue()
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            seen.add("\(code)\(type == .keyDown ? "d" : "u")")
        }
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: callback,
                                      userInfo: Unmanaged.passUnretained(seen).toOpaque())
    else { fail("cannot create listener tap") }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    // Built on the main thread: a key event made on any other thread before
    // the main thread has loaded the keyboard layout carries no characters.
    let source = CGEventSource(stateID: .hidSystemState)
    for (index, (code, down, flags)) in steps.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + 0.03 * Double(index)) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else { fail("cannot create key event") }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + 0.03 * Double(steps.count)) {
        print(seen.componentsJoined(by: " "))
        exit(0)
    }
    CFRunLoopRun()

case "click":
    let point = CGPoint(x: number(2), y: number(3))
    let flags: CGEventFlags = args.count > 4 && args[4] == "opt" ? .maskAlternate : []
    post(.mouseMoved, at: point)
    usleep(50_000)
    post(.leftMouseDown, at: point, flags: flags)
    usleep(30_000)
    post(.leftMouseUp, at: point, flags: flags)

case "side":
    let buttonNumber: Int64 = args.count > 2 && args[2] == "back" ? 3 : 4
    for type in [CGEventType.otherMouseDown, .otherMouseUp] {
        post(type, at: pointer(), button: .center, buttonNumber: buttonNumber)
        usleep(40_000)
    }

case "buttons":
    let steps: [(Int64, CGEventType)] = args.dropFirst(2).map { spec in
        let parts = spec.split(separator: ":")
        guard parts.count == 2, let number = Int64(parts[0]) else { fail("bad button spec \(spec)") }
        let type: CGEventType = switch parts[1] {
        case "d": .otherMouseDown
        case "g": .otherMouseDragged
        default: .otherMouseUp
        }
        return (number, type)
    }
    let seen = NSMutableArray()
    let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue
        | 1 << CGEventType.otherMouseDragged.rawValue | 1 << CGEventType.otherMouseUp.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, refcon in
        let seen = Unmanaged<NSMutableArray>.fromOpaque(refcon!).takeUnretainedValue()
        let code = switch type {
        case .otherMouseDown: "d"
        case .otherMouseDragged: "g"
        case .otherMouseUp: "u"
        default: "?"
        }
        seen.add("\(event.getIntegerValueField(.mouseEventButtonNumber))\(code)")
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: callback,
                                      userInfo: Unmanaged.passUnretained(seen).toOpaque())
    else { fail("cannot create listener tap") }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    for (index, (number, type)) in steps.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + 0.04 * Double(index)) {
            post(type, at: pointer(), button: .center, buttonNumber: number)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + 0.04 * Double(steps.count)) {
        print(seen.componentsJoined(by: " "))
        exit(0)
    }
    CFRunLoopRun()

case "scroll":
    // A tail-appended session tap sees events after every HID-level tap -
    // which is what apps receive.
    let continuous = args.count > 2 && args[2] == "trackpad"
    let marker: Int64 = 4242
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .scrollWheel, event.getIntegerValueField(.eventSourceUserData) == 4242 {
            print(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            exit(0)
        }
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: callback, userInfo: nil)
    else { fail("cannot create listener tap") }
    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                       CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: continuous ? .pixel : .line, wheelCount: 1,
                                  wheel1: 3, wheel2: 0, wheel3: 0)
        else { fail("cannot create scroll event") }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { fail("scroll event never arrived") }
    CFRunLoopRun()

case "button":
    guard args.count > 3 else { fail("usage: hid button <bundle-id> close|min|zoom") }
    let window = focusedWindow(args[2])
    let name = switch args[3] {
    case "close": kAXCloseButtonAttribute
    case "min": kAXMinimizeButtonAttribute
    default: kAXFullScreenButtonAttribute
    }
    guard let button = attribute(window, name) else { fail("no \(args[3]) button") }
    let rect = frame(of: button as! AXUIElement)
    let fullScreen = attribute(window, "AXFullScreen") as? Bool ?? false
    print(Int(rect.midX), Int(rect.midY), fullScreen)

case "frame":
    guard args.count > 2 else { fail("usage: hid frame <bundle-id>") }
    printRect(frame(of: focusedWindow(args[2])))

case "frames":
    guard args.count > 3 else { fail("usage: hid frames <bundle-id> <ms>") }
    var id: CGWindowID = 0
    guard _AXUIElementGetWindow(focusedWindow(args[2]), &id) == .success else { fail("no window id") }
    let end = Date().addingTimeInterval(number(3) / 1000)
    var frames: [CGRect] = []
    while Date() < end {
        if let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
           let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
               .flatMap({ CGRect(dictionaryRepresentation: $0) }),
           bounds != frames.last {
            frames.append(bounds)
        }
        usleep(2000)
    }
    print(frames.count)

case "popover":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    print(list.contains { $0[kCGWindowOwnerName as String] as? String == "ThemeWidgetControlViewService" }
          ? "open" : "closed")

case "front":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")

case "clipboard":
    let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    print(urls.isEmpty ? "-" : urls.map(\.lastPathComponent).sorted().joined(separator: " "))

case "visible":
    guard let screen = NSScreen.screens.first else { fail("no screen") }
    let visible = screen.visibleFrame
    printRect(CGRect(x: visible.minX, y: screen.frame.height - visible.maxY,
                     width: visible.width, height: visible.height))

default:
    fail("unknown command \(args[1])")
}
