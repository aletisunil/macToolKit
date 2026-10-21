import AppKit
import ApplicationServices
import Synchronization
import os

/// ⌘X then ⌘V moves files in Finder.
///
/// Finder has no Cut for files; it has Copy (⌘C) and, with ⌥ held, "Move
/// Item Here" (⌘⌥V). So in Finder, ⌘X is replaced by ⌘C and remembered, and
/// the next ⌘V becomes ⌘⌥V - as long as the clipboard still holds exactly
/// what that ⌘X put there. Copying anything else in between turns it back
/// into an ordinary paste. Text fields (renaming, search) keep their normal
/// cut and paste.
@MainActor
final class FinderCutPasteController: ObservableObject {
    @Published private(set) var tapActive = false

    private let cutPaste = FinderCutPaste()
    private let tap: EventTap
    private var activationObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?

    init() {
        let cutPaste = cutPaste
        tap = EventTap(name: "FinderCutPasteTap", events: [.keyDown, .keyUp]) { type, event in
            cutPaste.handle(type, event)
        }
        tap.$isActive.assign(to: &$tapActive)
    }

    func start() {
        tap.start()
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.bundleIdentifier == Self.finderBundleID ? app?.processIdentifier : nil
            MainActor.assumeIsolated {
                let cutPaste = AppState.shared.finderCutPaste.cutPaste
                cutPaste.setFinderFrontmost(pid: pid)
                if pid != nil { cutPaste.rebuildCopyKeystroke() }
            }
        }
        // A layout switch while Finder stays frontmost moves the C key too.
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppState.shared.finderCutPaste.cutPaste.rebuildCopyKeystroke()
            }
        }
        cutPaste.rebuildCopyKeystroke()
        let front = NSWorkspace.shared.frontmostApplication
        cutPaste.setFinderFrontmost(
            pid: front?.bundleIdentifier == Self.finderBundleID ? front?.processIdentifier : nil)
    }

    func stop() {
        tap.stop()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        }
        activationObserver = nil
        inputSourceObserver = nil
        cutPaste.reset()
    }

    nonisolated static let finderBundleID = "com.apple.finder"
}

/// Tap-thread logic. The clipboard is only ever read on the main thread
/// (NSPasteboard isn't thread-safe): it arms a cut once Finder has put the
/// files on it, and while armed it watches for anything else being copied.
/// The tap thread only reads the armed flag.
/// Unchecked because CGEvent isn't marked Sendable; the prebuilt keystroke is
/// only ever copied, under its lock.
private final class FinderCutPaste: @unchecked Sendable {
    private static let log = Logger.feature("FinderCutPaste")
    /// The Accessibility query runs while the key event waits. Finder
    /// answers in a few milliseconds; a busier Finder gets its keys as typed.
    private static let queryTimeout: Float = 0.1
    /// How often the clipboard is checked while a cut is armed.
    private static let clipboardPoll: TimeInterval = 0.1
    /// Marks the ⌘C this feature posts, so its own tap lets it through.
    private static let syntheticMarker: Int64 = 0x6d746b43 // "mtkC"

    private struct State {
        /// Finder's pid while it is the frontmost app.
        var finderPID: pid_t?
        /// Clipboard change count right after a ⌘X; a ⌘V moves only while
        /// the clipboard is still at this count. Set and cleared on main.
        var armedChangeCount: Int?
        var armedItemCount = 0
        /// The key whose ⌘X key-down became ⌘C: its key-up must become the
        /// ⌘C key-up, whatever other keys are released in between.
        var replacedXKeyCode: Int64?
    }

    private let state = Mutex(State())

    /// ⌘C as the current keyboard layout types it: key-down and key-up.
    /// Built on the main thread - a key event created on any other thread
    /// before the main thread has loaded the layout carries no characters,
    /// and AppKit matches menu shortcuts on characters, not key codes.
    private let copyKeystrokeLock = NSLock()
    private var copyKeystroke: (down: CGEvent, up: CGEvent)?

    /// Main thread only.
    nonisolated(unsafe) private var clipboardWatch: Timer?

    func setFinderFrontmost(pid: pid_t?) {
        state.withLock { $0.finderPID = pid }
    }

    @MainActor
    func reset() {
        disarm()
        state.withLock { $0 = State() }
    }

    /// Finds the key that types "c" in the current layout, starting with
    /// ANSI C, so a Dvorak or AZERTY layout gets its own C key.
    @MainActor
    func rebuildCopyKeystroke() {
        let built = ([CGKeyCode(8)] + (0..<128).map(CGKeyCode.init)).lazy.compactMap { keyCode in
            CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
                .flatMap { Self.character(of: $0) == "c" ? keyCode : nil }
        }.first.flatMap { keyCode -> (CGEvent, CGEvent)? in
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
            else { return nil }
            return (down, up)
        }
        copyKeystrokeLock.withLock { copyKeystroke = built }
    }

    /// A fresh copy of the prebuilt ⌘C half, with `template`'s modifiers.
    private func copyKeyEvent(like template: CGEvent, down: Bool) -> CGEvent? {
        let event = copyKeystrokeLock.withLock {
            (down ? copyKeystroke?.down : copyKeystroke?.up)?.copy()
        }
        event?.flags = template.flags
        event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        return event
    }

    /// Tap thread. Returns false to swallow the event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker,
              let finderPID = state.withLock({ $0.finderPID })
        else { return true }

        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let replace = state.withLock { state in
                guard state.replacedXKeyCode == keyCode else { return false }
                state.replacedXKeyCode = nil
                return true
            }
            guard replace, let copyUp = copyKeyEvent(like: event, down: false)
            else { return true }
            // Through main, behind the key-down posted there.
            nonisolated(unsafe) let up = copyUp
            DispatchQueue.main.async { up.post(tap: .cghidEventTap) }
            return false
        }

        let modifiers = event.flags.intersection(
            [.maskCommand, .maskAlternate, .maskControl, .maskShift])
        guard modifiers == .maskCommand,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        else { return true }

        switch Self.character(of: event) {
        case "x":
            guard Self.isEditingText(finderPID) == false,
                  let copyDown = copyKeyEvent(like: event, down: true)
            else { return true }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            state.withLock {
                $0.replacedXKeyCode = keyCode
                $0.armedChangeCount = nil
            }
            // The clipboard is read before the ⌘C goes out, so Finder's copy
            // can't land first. Posted at the HID level, behind keys that are
            // still in other apps' taps, so it can't overtake them.
            nonisolated(unsafe) let down = copyDown
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated {
                    disarm()
                    let before = NSPasteboard.general.changeCount
                    down.post(tap: .cghidEventTap)
                    armWhenCopied(after: before, attempt: 0)
                }
            }
            return false
        case "c":
            // A copy in Finder replaces the cut right away, before the
            // clipboard watch would notice.
            state.withLock { $0.armedChangeCount = nil }
        case "v":
            let armed = state.withLock { $0.armedChangeCount != nil }
            guard armed, Self.isEditingText(finderPID) == false else { return true }
            event.flags.insert(.maskAlternate)
            let items = state.withLock { state in
                state.armedChangeCount = nil
                return state.armedItemCount
            }
            Self.log.log("moving \(items) items")
        default:
            break
        }
        return true
    }

    /// Waits for Finder to put the copied files on the clipboard, then arms
    /// the move. Nothing selected means no clipboard change and no arming.
    @MainActor
    private func armWhenCopied(after before: Int, attempt: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != before else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                    MainActor.assumeIsolated { armWhenCopied(after: before, attempt: attempt + 1) }
                }
            }
            return
        }
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        let changeCount = pasteboard.changeCount
        state.withLock {
            $0.armedChangeCount = changeCount
            $0.armedItemCount = urls.count
        }
        watchClipboard(armedAt: changeCount)
        Self.log.log("cut \(urls.count) items")
        PointerHUD.shared.flash(urls.count == 1
            ? "Cut 1 item - ⌘V to move it"
            : "Cut \(urls.count) items - ⌘V to move them")
    }

    /// Anything copied after the cut, in any app, turns ⌘V back into an
    /// ordinary paste.
    @MainActor
    private func watchClipboard(armedAt changeCount: Int) {
        clipboardWatch?.invalidate()
        clipboardWatch = Timer.scheduledTimer(withTimeInterval: Self.clipboardPoll,
                                              repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stillArmed = self.state.withLock { $0.armedChangeCount == changeCount }
                guard stillArmed, NSPasteboard.general.changeCount == changeCount else {
                    self.disarm()
                    return
                }
            }
        }
    }

    @MainActor
    private func disarm() {
        clipboardWatch?.invalidate()
        clipboardWatch = nil
        state.withLock { $0.armedChangeCount = nil }
    }

    // MARK: Helpers

    /// The character a shortcut matches on, so ⌘X follows the keyboard
    /// layout rather than the key's position.
    private static func character(of event: CGEvent) -> String {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: chars.count,
                                       actualStringLength: &length,
                                       unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length).lowercased()
    }

    /// Renaming a file or typing in the search field: cut and paste are
    /// about text there. Nil when Finder didn't answer in time; callers then
    /// leave the keys alone, which is what Finder would get without this
    /// feature.
    private static func isEditingText(_ pid: pid_t) -> Bool? {
        let app = AXWindow.appElement(for: pid, timeout: queryTimeout)
        var focused: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                             &focused) {
        case .success: break
        case .noValue: return false
        default: return nil
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, queryTimeout)
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
        return AXWindow.stringAttribute(element, kAXRoleAttribute).map(textRoles.contains) ?? false
    }
}
