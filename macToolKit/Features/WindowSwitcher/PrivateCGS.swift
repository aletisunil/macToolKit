import AppKit

/// Quarantine file for the private CoreGraphics Server (SkyLight) APIs the
/// switcher uses to see windows on other Spaces and to number Space badges.
/// Every symbol is resolved with `dlsym` into an optional — if Apple removes
/// or renames one, everything here degrades silently to "current space only"
/// instead of failing to link. Safe for a non-sandboxed Developer ID app.
enum PrivateCGS {
    typealias ConnectionID = UInt32
    typealias SpaceID = UInt64

    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias CopySpacesForWindowsFn =
        @convention(c) (ConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn =
        @convention(c) (ConnectionID) -> Unmanaged<CFArray>?
    private typealias GetProcessForPIDFn =
        @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessWithOptionsFn =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    private typealias PostEventRecordToFn =
        @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias SetCurrentSpaceFn =
        @convention(c) (ConnectionID, CFString, SpaceID) -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let address = dlsym(dlopen(nil, RTLD_LAZY), name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    private static let mainConnection =
        symbol("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let copySpacesForWindows =
        symbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let copyManagedDisplaySpaces =
        symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    private static let getProcessForPID =
        symbol("GetProcessForPID", as: GetProcessForPIDFn.self)
    private static let setFrontProcessWithOptions =
        symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptionsFn.self)
    private static let postEventRecordTo =
        symbol("SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
            ?? symbol("_SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    private static let setCurrentSpace =
        symbol("CGSManagedDisplaySetCurrentSpace", as: SetCurrentSpaceFn.self)

    /// All symbols resolved — other-space windows and space badges work.
    static var available: Bool {
        mainConnection != nil && copySpacesForWindows != nil
            && copyManagedDisplaySpaces != nil
    }

    /// kCGSAllSpacesMask — current, other and fullscreen spaces.
    private static let allSpacesMask: Int32 = 7

    struct SpaceInfo {
        /// 1-based user-visible number (Mission Control order); nil for
        /// fullscreen spaces, which macOS doesn't number.
        let number: Int?
        let isCurrent: Bool
        let isFullscreen: Bool
    }

    /// Snapshot of every space across all displays, keyed by space id.
    /// Empty when the private API is unavailable.
    static func spaces() -> [SpaceID: SpaceInfo] {
        guard let mainConnection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(mainConnection())?
                  .takeRetainedValue() as? [[String: Any]]
        else { return [:] }

        var result: [SpaceID: SpaceInfo] = [:]
        var number = 0
        for display in displays {
            let currentID = (display["Current Space"] as? [String: Any])?["id64"]
                as? SpaceID
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["id64"] as? SpaceID else { continue }
                // type 0 = user space, 4 = fullscreen app space.
                let isFullscreen = (space["type"] as? Int ?? 0) == 4
                if !isFullscreen { number += 1 }
                result[id] = SpaceInfo(number: isFullscreen ? nil : number,
                                       isCurrent: id == currentID,
                                       isFullscreen: isFullscreen)
            }
        }
        return result
    }

    /// Forces a process frontmost as if the user clicked one of its windows
    /// (kCPSUserGenerated), bypassing macOS 14's cooperative-activation
    /// rules — which decline plain `NSRunningApplication.activate()` calls
    /// from a background app like this one. Returns false when the private
    /// symbols are missing so the caller can fall back to the public API.
    static func setFrontProcess(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcessWithOptions else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        let kCPSUserGenerated: UInt32 = 0x200
        return setFrontProcessWithOptions(&psn, windowID, kCPSUserGenerated) == .success
    }

    /// Switches the owning display to `spaceID`. The only reliable way in:
    /// fronting/keying a window never *enters* a fullscreen Space (it does
    /// carry macOS *out* of one), so cross-Space focus switches explicitly
    /// first. Returns false when the API is unavailable or the space is gone.
    static func switchToSpace(_ spaceID: SpaceID) -> Bool {
        guard let mainConnection, let copyManagedDisplaySpaces, let setCurrentSpace,
              let displays = copyManagedDisplaySpaces(mainConnection())?
                  .takeRetainedValue() as? [[String: Any]]
        else { return false }
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  (display["Spaces"] as? [[String: Any]] ?? [])
                      .contains(where: { $0["id64"] as? SpaceID == spaceID })
            else { continue }
            setCurrentSpace(mainConnection(), identifier as CFString, spaceID)
            return true
        }
        return false
    }

    /// Makes `windowID` its app's key window by posting a synthetic
    /// left-click (down + up) addressed to the window id, with the click
    /// point at (-1,-1) — outside the frame, so no content is hit. This is
    /// the step that actually makes the WindowServer key a specific window
    /// and complete a cross-Space jump; `setFrontProcess` alone only fronts
    /// the process. Ported from AltTab/yabai's window_manager_make_key_window.
    static func makeKeyWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPID, let postEventRecordTo else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }

        // CGSEventRecord is 0xf8 bytes; newer WindowServers read past a
        // tight buffer, so allocate 0x100 like yabai does.
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8 // record length
        bytes[0x3a] = 0x10 // required, undocumented
        var point = CGPoint(x: -1, y: -1) // window-relative click location
        withUnsafeBytes(of: &point) { bytes.replaceSubrange(0x20..<0x30, with: $0) }
        var id = windowID
        withUnsafeBytes(of: &id) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }

        bytes[0x08] = 0x01 // left mouse down
        let down = postEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02 // left mouse up
        let up = postEventRecordTo(&psn, &bytes)
        return down == .success && up == .success
    }

    /// Every space a window is on — more than one for sticky
    /// (join-all-spaces) windows. Empty when unavailable.
    static func spaceIDs(of window: CGWindowID) -> [SpaceID] {
        guard let mainConnection, let copySpacesForWindows,
              let spaces = copySpacesForWindows(
                  mainConnection(), allSpacesMask, [window] as CFArray)?
                  .takeRetainedValue() as? [SpaceID]
        else { return [] }
        return spaces
    }

    /// The space a window is on; nil when unavailable or ambiguous.
    static func spaceID(of window: CGWindowID) -> SpaceID? {
        spaceIDs(of: window).first
    }
}
