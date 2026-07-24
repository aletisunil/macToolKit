import AppKit
import Combine
import SwiftUI

/// Which screen the switcher panel appears on.
enum SwitcherScreenChoice: String, CaseIterable, Identifiable {
    case mouse, active
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mouse: "Screen with mouse"
        case .active: "Active screen"
        }
    }
}

/// Thumbnail tile scale for the thumbnails style.
enum ThumbnailSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var scale: CGFloat {
        switch self {
        case .small: 0.8
        case .medium: 1.0
        case .large: 1.3
        }
    }
}

/// Panel appearance override.
enum SwitcherTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Title/label alignment inside the switcher tiles and rows.
enum SwitcherAlignment: String, CaseIterable, Identifiable {
    case leading, center
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// AltTab-style window switcher: hold a trigger modifier (⌥ by default, ⌘
/// as an opt-in Cmd-Tab replacement) and press Tab to cycle through open
/// windows; release the modifier to focus the selected one, Escape to
/// cancel. Up to nine shortcut slots with per-slot filters and style,
/// window actions while open, blacklist, other-space windows via private
/// CGS APIs, and appearance preferences.
/// Requires Accessibility permission for the event tap and window control.
@MainActor
final class WindowSwitcherController: ObservableObject {
    // MARK: Preferences

    @Published var includeMinimized: Bool {
        didSet { defaults.set(includeMinimized, forKey: "switcherIncludeMinimized")
                 syncTracker() }
    }
    @Published var includeHidden: Bool {
        didSet { defaults.set(includeHidden, forKey: "switcherIncludeHidden")
                 syncTracker() }
    }
    @Published var includeOtherSpaces: Bool {
        didSet { defaults.set(includeOtherSpaces, forKey: "switcherIncludeOtherSpaces")
                 syncTracker() }
    }
    @Published var includeFullscreen: Bool {
        didSet { defaults.set(includeFullscreen, forKey: "switcherIncludeFullscreen")
                 syncTracker() }
    }
    /// Seconds before the panel becomes visible. A quick chord within the
    /// delay still switches — only the UI is delayed, never the semantics.
    @Published var showDelay: Double {
        didSet { defaults.set(showDelay, forKey: "switcherShowDelay") }
    }
    @Published var screenChoice: SwitcherScreenChoice {
        didSet { defaults.set(screenChoice.rawValue, forKey: "switcherScreen") }
    }
    @Published var thumbnailSize: ThumbnailSize {
        didSet { defaults.set(thumbnailSize.rawValue, forKey: "switcherThumbnailSize") }
    }
    @Published var alignment: SwitcherAlignment {
        didSet { defaults.set(alignment.rawValue, forKey: "switcherAlignment") }
    }
    @Published var fadeIn: Bool {
        didSet { defaults.set(fadeIn, forKey: "switcherFadeIn") }
    }
    @Published var theme: SwitcherTheme {
        didSet { defaults.set(theme.rawValue, forKey: "switcherTheme") }
    }
    /// VoiceOver support: the panel becomes the key window while open so the
    /// cursor can land on the tiles. Focus returns to the target on commit.
    @Published var assistiveFocus: Bool {
        didSet { defaults.set(assistiveFocus, forKey: "switcherAssistiveFocus") }
    }

    // MARK: Switcher state

    @Published private(set) var tapActive = false
    /// The filtered list rendered while the switcher is up.
    @Published private(set) var visibleWindows: [WindowInfo] = []
    @Published private(set) var activeStyle: SwitcherStyle = .thumbnails
    @Published var selection = 0 {
        didSet {
            let count = visibleWindows.count
            if count == 0 {
                if selection != 0 { selection = 0 }
            } else if !(0..<count).contains(selection) {
                selection = max(0, min(selection, count - 1))
            }
        }
    }

    let tracker = WindowTracker()
    let thumbnails = ThumbnailService()
    let shortcuts = ShortcutStore()
    let blacklist = BlacklistStore()

    private let defaults = UserDefaults.standard
    private let tap = SwitcherTap()
    private let panel = SwitcherPanel()
    private var permissionPoll: Timer?
    private var sinks: [AnyCancellable] = []
    private var trackerSink: AnyCancellable?
    private var frontmostObserver: NSObjectProtocol?
    private var shown = false
    private var running = false

    /// Snapshot of the whole tracker list at show time, before slot filters
    /// narrow it down to `visibleWindows`.
    private var baseWindows: [WindowInfo] = []
    private var activeSlot = ShortcutSlot()
    private var frontmostPID: pid_t?
    private var targetScreen: NSScreen?
    /// Invalidates a pending delayed panel reveal.
    private var showGeneration = 0
    /// Mouse location when the panel was revealed. Hover only takes over the
    /// selection once the pointer has actually moved past `hoverSlop` — the
    /// panel opens centered under a stationary cursor, and SwiftUI fires
    /// `onHover` on appearance, which would otherwise replace the alt-tab
    /// target with whatever tile happens to be under the pointer.
    private var mouseAnchor: CGPoint?
    private static let hoverSlop: CGFloat = 6

    init() {
        defaults.register(defaults: [
            "switcherIncludeMinimized": true,
            "switcherIncludeHidden": true,
            "switcherIncludeOtherSpaces": true,
            "switcherIncludeFullscreen": true,
            "switcherShowDelay": 0.0,
            "switcherScreen": SwitcherScreenChoice.mouse.rawValue,
            "switcherThumbnailSize": ThumbnailSize.medium.rawValue,
            "switcherAlignment": SwitcherAlignment.leading.rawValue,
            "switcherFadeIn": true,
            "switcherTheme": SwitcherTheme.system.rawValue,
            "switcherAssistiveFocus": false,
        ])
        includeMinimized = defaults.bool(forKey: "switcherIncludeMinimized")
        includeHidden = defaults.bool(forKey: "switcherIncludeHidden")
        includeOtherSpaces = defaults.bool(forKey: "switcherIncludeOtherSpaces")
        includeFullscreen = defaults.bool(forKey: "switcherIncludeFullscreen")
        showDelay = defaults.double(forKey: "switcherShowDelay")
        screenChoice = SwitcherScreenChoice(
            rawValue: defaults.string(forKey: "switcherScreen") ?? "") ?? .mouse
        thumbnailSize = ThumbnailSize(
            rawValue: defaults.string(forKey: "switcherThumbnailSize") ?? "") ?? .medium
        alignment = SwitcherAlignment(
            rawValue: defaults.string(forKey: "switcherAlignment") ?? "") ?? .leading
        fadeIn = defaults.bool(forKey: "switcherFadeIn")
        theme = SwitcherTheme(
            rawValue: defaults.string(forKey: "switcherTheme") ?? "") ?? .system
        assistiveFocus = defaults.bool(forKey: "switcherAssistiveFocus")

        syncTracker()
        // Shortcut or blacklist edits reach the tap thread immediately.
        sinks.append(shortcuts.$slots.dropFirst().sink { [weak self] _ in
            self?.pushTapConfig()
        })
        sinks.append(blacklist.$entries.dropFirst().sink { [weak self] _ in
            self?.syncTracker()
            self?.pushTapConfig()
        })
    }

    private func syncTracker() {
        tracker.includeMinimized = includeMinimized
        tracker.includeHidden = includeHidden
        tracker.includeOtherSpaces = includeOtherSpaces
        tracker.includeFullscreen = includeFullscreen
        tracker.hiddenBundleIDs = blacklist.hiddenBundleIDs
        if running { tracker.refresh() }
    }

    private func pushTapConfig() {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        tap.setConfig(SwitcherTapConfig(
            triggers: shortcuts.slots.enumerated().map { index, slot in
                .init(slot: index, holdFlag: slot.holdModifier.cgFlag,
                      keyCode: slot.key.keyCode)
            },
            suppressTrigger: frontmost.map(blacklist.dontInterceptBundleIDs.contains)
                ?? false))
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        guard Permissions.accessibilityGranted else {
            Permissions.requestAccessibility()
            // Keep checking so the switcher comes up as soon as the user
            // grants access — no need to toggle the feature off and on again.
            if permissionPoll == nil {
                permissionPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    Task { @MainActor in
                        let switcher = AppState.shared.windowSwitcher
                        guard AppState.shared.windowSwitcherEnabled else {
                            switcher.cancelPermissionPoll()
                            return
                        }
                        if Permissions.accessibilityGranted {
                            switcher.cancelPermissionPoll()
                            switcher.start()
                        }
                    }
                }
            }
            return
        }
        cancelPermissionPoll()
        running = true

        tracker.start()
        trackerSink = tracker.$windows.dropFirst().sink { [weak self] windows in
            self?.trackerUpdated(windows)
        }
        // The don't-intercept blacklist needs the frontmost app at all times.
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppState.shared.windowSwitcher.pushTapConfig()
            }
        }
        pushTapConfig()
        tap.start(handler: { [weak self] event in
            self?.handle(event)
        }, completion: { [weak self] ok in
            self?.tapActive = ok
        })
    }

    func cancelPermissionPoll() {
        permissionPoll?.invalidate()
        permissionPoll = nil
    }

    func stop() {
        cancelPermissionPoll()
        hideSwitcher()
        trackerSink = nil
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
            self.frontmostObserver = nil
        }
        tap.stop()
        tracker.stop()
        thumbnails.clearCache()
        tapActive = false
        running = false
    }

    // MARK: Event handling

    private func handle(_ event: SwitcherKeyEvent) {
        // Keep the published flag honest — the watchdog only runs every 2 s.
        tapActive = tap.tapActive

        switch event {
        case .show(let slot, let reverse):
            guard !shown else { return }
            show(slotIndex: slot, reverse: reverse)
        case .cycle(let delta):
            guard shown, !visibleWindows.isEmpty else { return }
            let count = visibleWindows.count
            selection = ((selection + delta) % count + count) % count
        case .commit:
            guard shown else { return }
            commit()
        case .cancel:
            hideSwitcher()
        case .action(let action):
            guard shown else { return }
            perform(action)
        }
    }

    private func show(slotIndex: Int, reverse: Bool) {
        tracker.refresh() // fresh snapshot streams in while we render the cache
        activeSlot = shortcuts.slots.indices.contains(slotIndex)
            ? shortcuts.slots[slotIndex] : ShortcutSlot()
        activeStyle = activeSlot.style
        frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        targetScreen = Self.screen(for: screenChoice)
        baseWindows = tracker.windows
        applyFilters(keepSelection: false)
        guard !visibleWindows.isEmpty else {
            tap.switcherVisible = false
            return
        }
        // Index 0 is the frontmost window; alt-tab semantics start on the
        // previous one.
        selection = reverse ? visibleWindows.count - 1 : min(1, visibleWindows.count - 1)
        shown = true
        showGeneration += 1
        let generation = showGeneration

        if showDelay > 0 {
            // Swallowing/cycling is live immediately; only the UI waits, so
            // a quick chord flips to the previous window with no flash.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.showDelay ?? 0) * 1e9))
                guard let self, self.shown, self.showGeneration == generation else { return }
                self.revealPanel()
            }
        } else {
            revealPanel()
        }
    }

    /// Whether a hover should be allowed to move the selection. False until
    /// the pointer leaves the position it was in when the panel appeared.
    func hoverCanSelect() -> Bool {
        guard let anchor = mouseAnchor else { return true }
        let mouse = NSEvent.mouseLocation
        guard hypot(mouse.x - anchor.x, mouse.y - anchor.y) > Self.hoverSlop else {
            return false
        }
        mouseAnchor = nil // pointer moved for real; hover is live from here on
        return true
    }

    private func revealPanel() {
        mouseAnchor = NSEvent.mouseLocation
        panel.show(
            content: SwitcherView(controller: self, thumbnails: thumbnails),
            options: SwitcherPanel.Options(screen: targetScreen,
                                           fadeIn: fadeIn,
                                           appearance: theme.appearance,
                                           becomeKey: assistiveFocus))
        thumbnails.refresh(for: visibleWindows)
    }

    /// Slot filters over the frozen base list.
    private func applyFilters(keepSelection: Bool) {
        let selectedID = keepSelection && (0..<visibleWindows.count).contains(selection)
            ? visibleWindows[selection].id : nil

        var filtered = baseWindows
        if activeSlot.activeSpaceOnly {
            filtered = filtered.filter(\.isOnActiveSpace)
        }
        if activeSlot.currentScreenOnly, let screen = targetScreen {
            // AX/CG window frames are top-left based; compare against the
            // screen's CG rect.
            let screenRect = Self.cgRect(of: screen)
            filtered = filtered.filter {
                $0.frame.isEmpty || screenRect.intersects($0.frame)
            }
        }
        if activeSlot.sameAppOnly, let pid = frontmostPID {
            filtered = filtered.filter { $0.pid == pid }
        }
        visibleWindows = filtered

        if let selectedID, let index = filtered.firstIndex(where: { $0.id == selectedID }) {
            selection = index
        } else {
            selection = min(selection, max(0, filtered.count - 1))
        }
    }

    /// Focuses the selected window and dismisses. Also the click path from
    /// the tiles, so it clears the tap's swallow state itself.
    func commit() {
        let target = (0..<visibleWindows.count).contains(selection)
            ? visibleWindows[selection] : nil
        hideSwitcher()
        target?.focus()
    }

    /// W/M/H/Q or a hover button: act on a window, keep the switcher open.
    /// The tracker refreshes shortly after so the list reflects the result.
    func perform(_ action: WindowAction, on window: WindowInfo? = nil) {
        guard let window = window ?? ((0..<visibleWindows.count).contains(selection)
            ? visibleWindows[selection] : nil) else { return }
        switch action {
        case .close: window.close()
        case .minimize: window.toggleMinimized()
        case .hide: window.hideApp()
        case .quit: window.quitApp()
        }
        // AX side effects land asynchronously in the target app.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.tracker.refresh()
        }
    }

    private func hideSwitcher() {
        shown = false
        showGeneration += 1
        mouseAnchor = nil
        panel.hide()
        tap.switcherVisible = false
    }

    /// A background snapshot landed while the switcher is up: swap the list,
    /// keep the selected window selected, and re-fit the panel.
    private func trackerUpdated(_ windows: [WindowInfo]) {
        guard shown else { return }
        let before = visibleWindows.map(\.id)
        baseWindows = windows
        applyFilters(keepSelection: true)
        guard !visibleWindows.isEmpty else {
            hideSwitcher()
            return
        }
        if visibleWindows.map(\.id) != before {
            thumbnails.refresh(for: visibleWindows)
            // Recenter after SwiftUI has re-laid-out the hosting view.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.panel.recenter() }
            }
        }
    }

    // MARK: Helpers

    private static func screen(for choice: SwitcherScreenChoice) -> NSScreen? {
        switch choice {
        case .mouse:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                ?? NSScreen.main
        case .active:
            // The screen with the key window of the frontmost app.
            return NSScreen.main
        }
    }

    /// Converts an NSScreen (bottom-left origin) frame to CG coordinates
    /// (top-left origin), the space window frames live in.
    private static func cgRect(of screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        var rect = screen.frame
        rect.origin.y = primaryHeight - rect.maxY
        return rect
    }
}
