import AppKit
import Carbon.HIToolbox
import IOKit

/// macOS Secure Input, which hides every key press from every event tap.
/// While another app holds it, the window switcher, Rewritely and Finder Cut
/// & Paste see no keys, and the Dock's own Cmd-Tab shows instead of ours.
/// Browsers turn it on for a focused password field and sometimes leave it
/// on after they lose focus.
enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }

    /// The app macOS names as the holder, or nil when Secure Input is off or
    /// the holder is not an app.
    ///
    /// Read from the I/O Registry's console users (what `ioreg` shows):
    /// `CGSessionCopyCurrentDictionary` carries the same key but always
    /// names the frontmost app. The registry is right for an app that turned
    /// Secure Input on while in front and then lost focus - the stuck
    /// password field. For a process that turned it on from the background,
    /// it too names the frontmost app, so callers should say "probably".
    static var holder: NSRunningApplication? {
        guard isOn,
              let users = IORegistryEntryCreateCFProperty(
                  IORegistryGetRootEntry(kIOMainPortDefault),
                  "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? [[String: Any]]
        else { return nil }
        let uid = getuid()
        let session = users.first {
            ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid
                && $0["kCGSSessionSecureInputPID"] != nil
        }
        guard let pid = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }
}
