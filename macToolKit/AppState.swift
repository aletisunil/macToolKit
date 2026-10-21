import SwiftUI
import Combine

enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case windowSwitcher, windowBehavior, mouse, rewritely, finder, display, audioPriority
    case general, about

    var id: String { rawValue }

    /// Sidebar layout: feature panes grouped by what they act on, then the
    /// app's own panes.
    static let sections: [(title: String, tabs: [SettingsTab])] = [
        ("Windows", [.windowSwitcher, .windowBehavior]),
        ("Mouse & Keyboard", [.mouse, .rewritely]),
        ("Finder", [.finder]),
        ("System", [.display, .audioPriority]),
        ("App", [.general, .about]),
    ]

    var title: String {
        switch self {
        case .general: "General"
        case .display: "Color Temperature"
        case .rewritely: "Rewritely"
        case .mouse: "Mouse & Trackpad"
        case .windowSwitcher: "Window Switcher"
        case .windowBehavior: "Window Behavior"
        case .finder: "Finder"
        case .audioPriority: "Audio Priority"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .display: "sun.max.fill"
        case .rewritely: "wand.and.stars"
        case .mouse: "computermouse.fill"
        case .windowSwitcher: "rectangle.stack"
        case .windowBehavior: "macwindow"
        case .finder: "folder.fill"
        case .audioPriority: "headphones"
        case .about: "info.circle"
        }
    }

    /// Used by the onboarding feature list.
    var tint: Color {
        switch self {
        case .general: .gray
        case .display: .orange
        case .rewritely: .purple
        case .mouse: .teal
        case .windowSwitcher: .indigo
        case .windowBehavior: .green
        case .finder: .blue
        case .audioPriority: Color(nsColor: .darkGray)
        case .about: .gray
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Appearance, dock icon and permissions."
        case .display: "Warms the display in the evening so it's easier on the eyes. Manual slider or fully automatic."
        case .rewritely: "Type a trigger word at the end of any text field and the text is rewritten in place."
        case .mouse: "Scroll direction per device, and side buttons that go back and forward."
        case .windowSwitcher: "Hold ⌥ and press Tab to switch between windows. Previews, minimized windows and all."
        case .windowBehavior: "How windows close, fill the screen and take focus."
        case .finder: "Look inside folders and archives, and move files with cut and paste."
        case .audioPriority: "Rank your speakers and microphones. The best one that's plugged in becomes the default."
        case .about: "Version and credits."
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let colorTemperature = ColorTemperatureController()
    let scrollReverser = ScrollTap()
    let rewritely = RewritelyController()
    let windowSwitcher = WindowSwitcherController()
    let audioPriority = AudioPriorityController()
    let quitOnClose = QuitOnCloseController()
    let maximizeWindows = MaximizeController()
    let focusFollowsMouse = FocusFollowsMouseController()
    let sideButtons = SideButtonsController()
    let finderCutPaste = FinderCutPasteController()

    @Published var settingsTab: SettingsTab = .general

    /// Published rather than read straight from `UserDefaults`, because the
    /// menu bar offers "Finish Setup…" while this is false and has to drop it
    /// the moment the welcome flow completes.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    // MARK: Persisted feature toggles

    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: "showInDock")
            DockIconManager.apply(showInDock: showInDock)
        }
    }

    @Published var colorTemperatureEnabled: Bool {
        didSet {
            defaults.set(colorTemperatureEnabled, forKey: "colorTemperatureEnabled")
            colorTemperatureEnabled ? colorTemperature.start() : colorTemperature.stop()
        }
    }

    @Published var scrollReverserEnabled: Bool {
        didSet {
            defaults.set(scrollReverserEnabled, forKey: "scrollReverserEnabled")
            scrollReverserEnabled ? scrollReverser.start() : scrollReverser.stop()
        }
    }

    @Published var rewritelyEnabled: Bool {
        didSet {
            defaults.set(rewritelyEnabled, forKey: "rewritelyEnabled")
            rewritelyEnabled ? rewritely.start() : rewritely.stop()
        }
    }

    @Published var windowSwitcherEnabled: Bool {
        didSet {
            defaults.set(windowSwitcherEnabled, forKey: "windowSwitcherEnabled")
            windowSwitcherEnabled ? windowSwitcher.start() : windowSwitcher.stop()
        }
    }

    @Published var audioPriorityEnabled: Bool {
        didSet {
            defaults.set(audioPriorityEnabled, forKey: "audioPriorityEnabled")
            audioPriorityEnabled ? audioPriority.start() : audioPriority.stop()
        }
    }

    @Published var quitOnCloseEnabled: Bool {
        didSet {
            defaults.set(quitOnCloseEnabled, forKey: "quitOnCloseEnabled")
            quitOnCloseEnabled ? quitOnClose.start() : quitOnClose.stop()
        }
    }

    @Published var maximizeWindowsEnabled: Bool {
        didSet {
            defaults.set(maximizeWindowsEnabled, forKey: "maximizeWindowsEnabled")
            maximizeWindowsEnabled ? maximizeWindows.start() : maximizeWindows.stop()
        }
    }

    @Published var focusFollowsMouseEnabled: Bool {
        didSet {
            defaults.set(focusFollowsMouseEnabled, forKey: "focusFollowsMouseEnabled")
            focusFollowsMouseEnabled ? focusFollowsMouse.start() : focusFollowsMouse.stop()
        }
    }

    @Published var sideButtonsEnabled: Bool {
        didSet {
            defaults.set(sideButtonsEnabled, forKey: "sideButtonsEnabled")
            sideButtonsEnabled ? sideButtons.start() : sideButtons.stop()
        }
    }

    @Published var finderCutPasteEnabled: Bool {
        didSet {
            defaults.set(finderCutPasteEnabled, forKey: "finderCutPasteEnabled")
            finderCutPasteEnabled ? finderCutPaste.start() : finderCutPaste.stop()
        }
    }

    @Published var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    func applyAppearance() {
        switch appearanceMode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "showInDock": true,
        ])
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        showInDock = defaults.bool(forKey: "showInDock")
        colorTemperatureEnabled = defaults.bool(forKey: "colorTemperatureEnabled")
        scrollReverserEnabled = defaults.bool(forKey: "scrollReverserEnabled")
        rewritelyEnabled = defaults.bool(forKey: "rewritelyEnabled")
        windowSwitcherEnabled = defaults.bool(forKey: "windowSwitcherEnabled")
        audioPriorityEnabled = defaults.bool(forKey: "audioPriorityEnabled")
        quitOnCloseEnabled = defaults.bool(forKey: "quitOnCloseEnabled")
        maximizeWindowsEnabled = defaults.bool(forKey: "maximizeWindowsEnabled")
        focusFollowsMouseEnabled = defaults.bool(forKey: "focusFollowsMouseEnabled")
        sideButtonsEnabled = defaults.bool(forKey: "sideButtonsEnabled")
        finderCutPasteEnabled = defaults.bool(forKey: "finderCutPasteEnabled")
        appearanceMode = AppearanceMode(
            rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
    }

    /// Dock icon and appearance, applied at every launch regardless of
    /// whether onboarding has run yet.
    func applyLaunchAppearance() {
        DockIconManager.apply(showInDock: showInDock)
        applyAppearance()
    }

    /// Start whatever was enabled in the previous session. Called at launch
    /// once onboarding is complete, or right after onboarding finishes, so
    /// no feature can fire a permission prompt before the user has seen the
    /// welcome flow.
    func startEnabledFeatures() {
        if colorTemperatureEnabled { colorTemperature.start() }
        if scrollReverserEnabled { scrollReverser.start() }
        if rewritelyEnabled { rewritely.start() }
        if windowSwitcherEnabled { windowSwitcher.start() }
        if audioPriorityEnabled { audioPriority.start() }
        if quitOnCloseEnabled { quitOnClose.start() }
        if maximizeWindowsEnabled { maximizeWindows.start() }
        if focusFollowsMouseEnabled { focusFollowsMouse.start() }
        if sideButtonsEnabled { sideButtons.start() }
        if finderCutPasteEnabled { finderCutPaste.start() }
    }

    /// Tear down anything that mutates global system state. Called at quit.
    func shutdown() {
        colorTemperature.stop()
        scrollReverser.stop()
        rewritely.stop()
        windowSwitcher.stop()
        audioPriority.stop()
        quitOnClose.stop()
        maximizeWindows.stop()
        focusFollowsMouse.stop()
        sideButtons.stop()
        finderCutPaste.stop()
    }
}
