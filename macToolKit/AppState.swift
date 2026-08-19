import SwiftUI
import Combine

enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    // Feature panes (sidebar "FEATURES" section)
    case display, rewritely, scrolling, windowSwitcher, peek, audioPriority
    // App panes (sidebar "APP" section)
    case general, about

    var id: String { rawValue }

    static var featureTabs: [SettingsTab] {
        [.display, .rewritely, .scrolling, .windowSwitcher, .peek, .audioPriority]
    }
    static var appTabs: [SettingsTab] { [.general, .about] }

    var title: String {
        switch self {
        case .general: "General"
        case .display: "Color Temperature"
        case .rewritely: "Rewritely"
        case .scrolling: "Scroll Reverser"
        case .windowSwitcher: "Window Switcher"
        case .peek: "Peek"
        case .audioPriority: "Audio Priority"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .display: "sun.max.fill"
        case .rewritely: "wand.and.stars"
        case .scrolling: "computermouse.fill"
        case .windowSwitcher: "rectangle.stack"
        case .peek: "text.magnifyingglass"
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
        case .scrolling: .teal
        case .windowSwitcher: .indigo
        case .peek: .blue
        case .audioPriority: Color(nsColor: .darkGray)
        case .about: .gray
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Appearance, dock icon and permissions."
        case .display: "Warms the display in the evening so it's easier on the eyes. Manual slider or fully automatic."
        case .rewritely: "Type a trigger word at the end of any text field and the text is rewritten in place."
        case .scrolling: "Flip the scroll direction independently for the trackpad and a mouse wheel."
        case .windowSwitcher: "Hold ⌥ and press Tab to switch between windows. Previews, minimized windows and all."
        case .peek: "Press Space on a folder or a .zip in Finder to browse what's inside - Quick Look, but useful."
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
    }

    /// Tear down anything that mutates global system state. Called at quit.
    func shutdown() {
        colorTemperature.stop()
        scrollReverser.stop()
        rewritely.stop()
        windowSwitcher.stop()
        audioPriority.stop()
    }
}
