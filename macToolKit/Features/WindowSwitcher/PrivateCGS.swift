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

    /// The space a window is on; nil when unavailable or ambiguous.
    static func spaceID(of window: CGWindowID) -> SpaceID? {
        guard let mainConnection, let copySpacesForWindows,
              let spaces = copySpacesForWindows(
                  mainConnection(), allSpacesMask, [window] as CFArray)?
                  .takeRetainedValue() as? [SpaceID]
        else { return nil }
        return spaces.first
    }
}
