import AppKit
import ApplicationServices

/// Maintains the list of switchable windows in most-recently-used order.
///
/// On-screen windows come from `CGWindowListCopyWindowInfo`, whose
/// front-to-back z-order doubles as focus recency. Minimized windows and the
/// windows of hidden apps are invisible to CGWindowList, so they come from
/// each app's AX window list and are appended in app-MRU order (tracked via
/// activation notifications). Windows on other Spaces are invisible to the
/// AX API too; they come from a CGWindowList pass over *all* windows,
/// classified by Space through the private CGS API — with a silent fallback
/// to current-space-only when that API is unavailable. Enumeration runs off
/// the main thread — AX round-trips to a hung app block for up to the
/// messaging timeout.
///
/// The cache refreshes on app activation/launch/termination and again on
/// every switcher invocation, so the panel can render instantly from the
/// cache while a fresh snapshot lands milliseconds later.
@MainActor
final class WindowTracker: ObservableObject {
    @Published private(set) var windows: [WindowInfo] = []

    var includeMinimized = true
    var includeHidden = true
    var includeOtherSpaces = true
    var includeFullscreen = true
    /// Bundle ids whose windows never appear (blacklist "hide" entries).
    var hiddenBundleIDs: Set<String> = []

    /// pids, most recently activated first.
    private var appMRU: [pid_t] = []
    /// CG window ids known to be leftover entries for closed windows (see
    /// the ghost bookkeeping in `otherSpaceWindows`). Carried across
    /// refreshes: a ghost is only detectable while its Space is current.
    private var ghostIDs: Set<CGWindowID> = []
    private var observers: [NSObjectProtocol] = []
    private var refreshInFlight = false
    private var refreshQueued = false

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Only Sendable values may cross into the isolated closure.
                let activatedPID = name == NSWorkspace.didActivateApplicationNotification
                    ? (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication)?.processIdentifier
                    : nil
                MainActor.assumeIsolated {
                    let tracker = AppState.shared.windowSwitcher.tracker
                    if let activatedPID {
                        tracker.noteActivated(activatedPID)
                    }
                    tracker.refresh()
                }
            })
        }
        // Seed MRU with the current front-to-back app order.
        appMRU = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { $0.isActive && !$1.isActive }
            .map(\.processIdentifier)
        refresh()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        windows = []
    }

    private func noteActivated(_ pid: pid_t) {
        appMRU.removeAll { $0 == pid }
        appMRU.insert(pid, at: 0)
    }

    /// Rebuilds the window list on a background task. Coalesces: one refresh
    /// in flight, at most one queued.
    func refresh() {
        if refreshInFlight {
            refreshQueued = true
            return
        }
        refreshInFlight = true

        // App metadata is gathered on the main actor; the background pass
        // only does CGWindowList + AX + CGS calls.
        let apps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular && !app.isTerminated
                    && (includeHidden || !app.isHidden)
                    && !(app.bundleIdentifier.map(hiddenBundleIDs.contains) ?? false)
            }
            .map {
                AppMeta(pid: $0.processIdentifier,
                        bundleID: $0.bundleIdentifier,
                        name: $0.localizedName ?? "App",
                        icon: $0.icon,
                        isHidden: $0.isHidden)
            }
        let options = Options(includeMinimized: includeMinimized,
                              includeOtherSpaces: includeOtherSpaces,
                              includeFullscreen: includeFullscreen,
                              appMRU: appMRU,
                              knownGhosts: ghostIDs)

        Task.detached(priority: .userInitiated) {
            let (snapshot, ghosts) = WindowTracker.snapshot(apps: apps, options: options)
            await MainActor.run {
                self.windows = snapshot
                self.ghostIDs = ghosts
                self.refreshInFlight = false
                if self.refreshQueued {
                    self.refreshQueued = false
                    self.refresh()
                }
            }
        }
    }

    // MARK: Background snapshot

    private struct AppMeta: @unchecked Sendable {
        let pid: pid_t
        let bundleID: String?
        let name: String
        let icon: NSImage?
        let isHidden: Bool
    }

    private struct Options: Sendable {
        let includeMinimized: Bool
        let includeOtherSpaces: Bool
        let includeFullscreen: Bool
        let appMRU: [pid_t]
        let knownGhosts: Set<CGWindowID>
    }

    private nonisolated static func snapshot(
        apps: [AppMeta],
        options: Options
    ) -> (windows: [WindowInfo], ghosts: Set<CGWindowID>) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let appsByPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0) })

        // Z-ordered (front to back) IDs of normal-layer on-screen windows.
        var onScreenOrder: [CGWindowID] = []
        if let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                      let number = entry[kCGWindowNumber as String] as? CGWindowID,
                      let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                      ownerPID != ownPID
                else { continue }
                onScreenOrder.append(number)
            }
        }
        let onScreenIDs = Set(onScreenOrder)

        // AX pass per app: titles, minimized/hidden/fullscreen state and the
        // raise handle. Mostly the current Space — but from a fullscreen
        // Space, AX still exposes other apps' windows on regular Spaces, so
        // each window's real Space is resolved via CGS: focusing one of
        // those must switch Spaces explicitly (setFront/makeKey alone never
        // leaves a fullscreen Space).
        let spaces = PrivateCGS.available ? PrivateCGS.spaces() : [:]
        var byID: [CGWindowID: WindowInfo] = [:]
        var offscreenByApp: [pid_t: [WindowInfo]] = [:]
        for app in apps where app.pid != ownPID {
            let element = AXWindow.appElement(for: app.pid)
            for window in AXWindow.windows(of: element) {
                guard AXWindow.isSwitchable(window),
                      let id = AXWindow.windowID(of: window)
                else { continue }
                let isMinimized = AXWindow.isMinimized(window)
                if isMinimized && !options.includeMinimized { continue }
                let isFullscreen = AXWindow.isFullscreen(window)
                if isFullscreen && !options.includeFullscreen { continue }

                // nil for current-space, minimized (no Space membership)
                // and unresolvable windows — those focus without switching.
                let otherSpace: (id: PrivateCGS.SpaceID, number: Int?)? =
                    PrivateCGS.spaceID(of: id).flatMap { sid in
                        guard let space = spaces[sid], !space.isCurrent
                        else { return nil }
                        return (sid, space.number)
                    }

                let info = WindowInfo(
                    id: id,
                    axWindow: window,
                    pid: app.pid,
                    bundleID: app.bundleID,
                    appName: app.name,
                    icon: app.icon,
                    title: AXWindow.title(of: window),
                    isMinimized: isMinimized,
                    isHidden: app.isHidden,
                    isFullscreen: isFullscreen,
                    spaceNumber: otherSpace?.number,
                    spaceID: otherSpace?.id,
                    isOnActiveSpace: otherSpace == nil,
                    frame: AXWindow.frame(of: window))
                if onScreenIDs.contains(id) {
                    byID[id] = info
                } else {
                    offscreenByApp[app.pid, default: []].append(info)
                }
            }
        }

        // Visible windows in z-order, then minimized/hidden ones in app-MRU
        // order.
        var result = onScreenOrder.compactMap { byID[$0] }
        var seen = Set(result.map(\.id))
        let orderedPIDs = options.appMRU
            + offscreenByApp.keys.filter { !options.appMRU.contains($0) }
        for pid in orderedPIDs {
            for info in offscreenByApp[pid] ?? [] where !seen.contains(info.id) {
                seen.insert(info.id)
                result.append(info)
            }
        }

        // Other-space windows: CGWindowList over all windows, classified by
        // Space via private CGS. Unavailable API → current-space fallback.
        var ghosts = options.knownGhosts
        if options.includeOtherSpaces && PrivateCGS.available {
            result.append(contentsOf: otherSpaceWindows(
                appsByPID: appsByPID, seen: seen, ownPID: ownPID,
                includeFullscreen: options.includeFullscreen,
                ghosts: &ghosts))
        }
        return (result, ghosts)
    }

    private nonisolated static func otherSpaceWindows(
        appsByPID: [pid_t: AppMeta],
        seen: Set<CGWindowID>,
        ownPID: pid_t,
        includeFullscreen: Bool,
        ghosts: inout Set<CGWindowID>
    ) -> [WindowInfo] {
        let spaces = PrivateCGS.spaces()
        guard !spaces.isEmpty,
              let list = CGWindowListCopyWindowInfo(
                  [.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var found: [WindowInfo] = []
        var allIDs = Set<CGWindowID>()
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ownPID,
                  let app = appsByPID[ownerPID],
                  let spaceID = PrivateCGS.spaceID(of: id),
                  let space = spaces[spaceID]
            else { continue }
            allIDs.insert(id)

            // Ghost bookkeeping. Some apps (Notes, Chrome popups) keep
            // CGWindowList entries for windows that no longer exist — from
            // another Space they'd show as unfocusable phantom tiles, and no
            // CG attribute distinguishes them there. But while their Space is
            // current the truth is visible: a real window is either on screen
            // or known to AX (minimized/hidden). Remember the leftovers and
            // skip them once their Space is no longer current. Self-healing:
            // a window seen real again drops off the list.
            if space.isCurrent {
                let isOnscreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
                if isOnscreen || seen.contains(id) {
                    ghosts.remove(id)
                } else {
                    ghosts.insert(id)
                }
                continue
            }
            guard !seen.contains(id), !ghosts.contains(id) else { continue }
            if space.isFullscreen && !includeFullscreen { continue }

            // No AX subrole available here; a minimum size keeps panels and
            // status overlays out.
            var frame = CGRect.zero
            if let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] {
                frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            }
            guard frame.width >= 100, frame.height >= 50 else { continue }

            // A fullscreen Space's real windows are display-height (Split
            // View halves included); anything shorter is a companion overlay
            // (Chrome's hover tab strip, the exit-fullscreen bubble) that
            // would show up as a phantom duplicate entry.
            if space.isFullscreen,
               frame.height < 0.75 * displayHeight(containing: frame) { continue }

            // kCGWindowName is only populated with Screen Recording access;
            // the app name stands in otherwise.
            let title = entry[kCGWindowName as String] as? String ?? ""
            found.append(WindowInfo(
                id: id,
                axWindow: nil,
                pid: ownerPID,
                bundleID: app.bundleID,
                appName: app.name,
                icon: app.icon,
                title: title,
                isMinimized: false,
                isHidden: app.isHidden,
                isFullscreen: space.isFullscreen,
                spaceNumber: space.number,
                spaceID: spaceID,
                isOnActiveSpace: false,
                frame: frame))
        }
        // Windows that vanished entirely take their ghost record with them.
        ghosts.formIntersection(allIDs)
        return found.sorted { ($0.spaceNumber ?? .max) < ($1.spaceNumber ?? .max) }
    }

    /// Height of the display best containing `frame` (largest intersection),
    /// falling back to the main display. CGWindow bounds and CGDisplayBounds
    /// share the same global top-left coordinate space. CoreGraphics rather
    /// than NSScreen because the snapshot runs off the main thread.
    private nonisolated static func displayHeight(containing frame: CGRect) -> CGFloat {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(UInt32(displays.count), &displays, &count)
        let best = displays.prefix(Int(count))
            .map { CGDisplayBounds($0) }
            .max { a, b in
                a.intersection(frame).area < b.intersection(frame).area
            }
        return best?.height ?? CGDisplayBounds(CGMainDisplayID()).height
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
