import AppKit
import ApplicationServices
import os

/// Quits an app when its last window closes, the way apps behave on Windows.
///
/// Every regular (Dock) app gets an AXObserver: `kAXWindowCreated` and
/// `kAXFocusedWindowChanged` on the app, `kAXUIElementDestroyed` on each of
/// its standard windows and dialogs. Focus changes catch windows that never
/// announce themselves - a background tab of a native tab group is hidden
/// from Accessibility until it's selected.
/// When one of those windows goes away, the app is checked a moment later -
/// long enough for a window that replaces it (the next tab of a native tab
/// group, a document reopened) to show up - and quit if nothing is left.
///
/// "Nothing left" errs on the side of keeping the app: minimized and hidden
/// windows count, windows on other Spaces count (Accessibility can't see
/// those, so they come from the window list), and an app that doesn't
/// answer the Accessibility query is never quit.
@MainActor
final class QuitOnCloseController: ObservableObject {
    /// Apps that keep running after their last window closes.
    let exceptions = AppListStore(key: "quitOnCloseExceptions")

    /// Finder can't be quit normally and owns the desktop; this app quits
    /// itself only from its menu.
    static let alwaysKept: Set<String> = [
        "com.apple.finder",
        Bundle.main.bundleIdentifier ?? "",
    ]

    /// Observers are installed. False while waiting for Accessibility.
    @Published private(set) var isActive = false

    private static let log = Logger.feature("QuitOnClose")
    /// How long a closed window's app gets to show a replacement window.
    private static let settleDelay: TimeInterval = 0.6

    private var running = false
    private var watchers: [pid_t: AppWindowWatcher] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var permissionPoll: Timer?
    /// pids with a check already scheduled, so closing several windows at
    /// once (Close All) checks once.
    private var pendingChecks: Set<pid_t> = []

    func start() {
        guard !running else { return }
        running = true
        guard Permissions.accessibilityGranted else {
            Permissions.requestAccessibility()
            permissionPoll = Permissions.whenAccessibilityGranted { [weak self] in
                guard let self, self.running else { return }
                self.permissionPoll = nil
                self.install()
            }
            return
        }
        install()
    }

    func stop() {
        running = false
        permissionPoll?.invalidate()
        permissionPoll = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        watchers.values.forEach { $0.invalidate() }
        watchers.removeAll()
        pendingChecks.removeAll()
        isActive = false
    }

    private func install() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
                AppState.shared.quitOnClose.watch(app)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                AppState.shared.quitOnClose.unwatch(pid)
            }
        })
        NSWorkspace.shared.runningApplications.forEach(watch)
        isActive = true
    }

    private func watch(_ app: NSRunningApplication) {
        guard running, app.activationPolicy == .regular,
              app.processIdentifier != getpid(),
              watchers[app.processIdentifier] == nil
        else { return }
        let pid = app.processIdentifier
        watchers[pid] = AppWindowWatcher(pid: pid) { [weak self] in
            self?.scheduleCheck(pid)
        }
    }

    private func unwatch(_ pid: pid_t) {
        watchers.removeValue(forKey: pid)?.invalidate()
        pendingChecks.remove(pid)
    }

    private func scheduleCheck(_ pid: pid_t) {
        guard pendingChecks.insert(pid).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingChecks.remove(pid) != nil else { return }
                self.quitIfWindowless(pid)
            }
        }
    }

    private func quitIfWindowless(_ pid: pid_t) {
        guard running,
              let app = NSRunningApplication(processIdentifier: pid),
              !app.isTerminated
        else { return }
        let bundleID = app.bundleIdentifier ?? ""
        guard !Self.alwaysKept.contains(bundleID),
              !exceptions.bundleIDs.contains(bundleID)
        else { return }
        guard let remaining = Self.remainingWindowCount(pid: pid) else {
            Self.log.log("\(bundleID, privacy: .public): window count unknown, keeping it")
            return
        }
        guard remaining == 0 else { return }
        Self.log.log("\(bundleID, privacy: .public): last window closed, quitting")
        app.terminate()
    }

    /// Windows the app still has anywhere, or nil when it can't be told.
    private static func remainingWindowCount(pid: pid_t) -> Int? {
        guard let windows = AXWindow.windowsIfAnswered(of: AXWindow.appElement(for: pid))
        else { return nil }
        return windows.filter(AXWindow.isSwitchable).count + otherSpaceWindowCount(pid: pid)
    }

    /// Standard-layer windows the app owns on Spaces other than the current
    /// one. Some apps leave stale window-list entries behind for closed
    /// windows; those keep the app running, which is the safe mistake.
    private static func otherSpaceWindowCount(pid: pid_t) -> Int {
        guard PrivateCGS.available,
              let list = CGWindowListCopyWindowInfo(
                  [.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return 0 }
        let spaces = PrivateCGS.spaces()
        return list.filter { entry in
            guard entry[kCGWindowOwnerPID as String] as? pid_t == pid,
                  entry[kCGWindowLayer as String] as? Int == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary)
                      .flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.width >= 60, bounds.height >= 60
            else { return false }
            let windowSpaces = PrivateCGS.spaceIDs(of: id)
            return !windowSpaces.isEmpty
                && !windowSpaces.contains { spaces[$0]?.isCurrent == true }
        }.count
    }
}

/// The AXObserver for one app. Lives on the main run loop, so its callback
/// arrives on the main thread.
///
/// An app that has only just launched often turns registrations down
/// (`kAXErrorCannotComplete`) until it has finished starting up, so every
/// failed registration is retried, with backoff, for about half a minute.
@MainActor
private final class AppWindowWatcher {
    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
    ]
    /// Delays before each retry, in seconds.
    private static let retryDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8, 16]

    private let app: AXUIElement
    private var observer: AXObserver?
    private var watched: Set<AXUIElement> = []
    /// App-level notifications not registered yet.
    private var pendingAppNotifications = Set(appNotifications)
    private var retryScheduled = false
    private let onWindowClosed: () -> Void

    init(pid: pid_t, onWindowClosed: @escaping () -> Void) {
        app = AXWindow.appElement(for: pid)
        self.onWindowClosed = onWindowClosed

        var observer: AXObserver?
        guard AXObserverCreate(pid, appWindowWatcherCallback, &observer) == .success,
              let observer
        else { return }
        self.observer = observer
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer), .defaultMode)
        if !register() { scheduleRetry(attempt: 0) }
    }

    private var refcon: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// Removing the source first guarantees no callback can reach this
    /// object (passed unretained) after it's gone.
    func invalidate() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        watched.removeAll()
    }

    /// Registers whatever isn't registered yet: the app notifications and
    /// every switchable window. Returns whether everything is now in place.
    private func register() -> Bool {
        guard let observer else { return true }
        for name in pendingAppNotifications where Self.added(
            AXObserverAddNotification(observer, app, name as CFString, refcon)) {
            pendingAppNotifications.remove(name)
        }
        guard let windows = AXWindow.windowsIfAnswered(of: app) else { return false }
        var complete = pendingAppNotifications.isEmpty
        for window in windows where watchIfSwitchable(window) == .failed {
            complete = false
        }
        return complete
    }

    private func scheduleRetry(attempt: Int) {
        guard !retryScheduled, attempt < Self.retryDelays.count else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.observer != nil else { return }
                self.retryScheduled = false
                if !self.register() { self.scheduleRetry(attempt: attempt + 1) }
            }
        }
    }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification:
            // A new window may not have its subrole yet, or may not take the
            // registration yet; the retry catches it.
            if watchIfSwitchable(element) != .watched { scheduleRetry(attempt: 0) }
        case kAXUIElementDestroyedNotification:
            guard watched.remove(element) != nil else { return }
            onWindowClosed()
        default:
            break
        }
    }

    private enum WatchResult { case watched, skipped, failed }

    /// Only standard windows and dialogs: a tooltip or popover closing in an
    /// app that happens to have no windows must not quit it.
    private func watchIfSwitchable(_ window: AXUIElement) -> WatchResult {
        guard let observer else { return .skipped }
        if watched.contains(window) { return .watched }
        guard AXWindow.isSwitchable(window) else { return .skipped }
        guard Self.added(AXObserverAddNotification(
            observer, window, kAXUIElementDestroyedNotification as CFString, refcon))
        else { return .failed }
        watched.insert(window)
        return .watched
    }

    private static func added(_ result: AXError) -> Bool {
        result == .success || result == .notificationAlreadyRegistered
    }
}

private func appWindowWatcherCallback(observer: AXObserver,
                                      element: AXUIElement,
                                      notification: CFString,
                                      refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<AppWindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // The observer's source is on the main run loop, so this is the main
    // thread; AXUIElement just isn't marked Sendable.
    nonisolated(unsafe) let element = element
    MainActor.assumeIsolated {
        watcher.handle(name, element: element)
    }
}
