import SwiftUI
import Combine

enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    // Feature panes (sidebar "FEATURES" section)
    case finder, display, rewritely, scrolling
    // App panes (sidebar "APP" section)
    case general, about

    var id: String { rawValue }

    static var featureTabs: [SettingsTab] { [.finder, .display, .rewritely, .scrolling] }
    static var appTabs: [SettingsTab] { [.general, .about] }

    var title: String {
        switch self {
        case .general: "General"
        case .finder: "Finder Tools"
        case .display: "Color Temperature"
        case .rewritely: "Rewritely"
        case .scrolling: "Scroll Reverser"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .finder: "folder.fill"
        case .display: "sun.max.fill"
        case .rewritely: "wand.and.stars"
        case .scrolling: "computermouse.fill"
        case .about: "info.circle"
        }
    }

    /// Used by the onboarding feature list.
    var tint: Color {
        switch self {
        case .general: .gray
        case .finder: .blue
        case .display: .orange
        case .rewritely: .purple
        case .scrolling: .teal
        case .about: .gray
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Appearance, dock icon and permissions."
        case .finder: "Create files and copy folder paths straight from Finder's right-click menu."
        case .display: "Warms the display in the evening so it's easier on the eyes. Manual slider or fully automatic."
        case .rewritely: "Type a trigger word at the end of any text field and the text is rewritten in place."
        case .scrolling: "Flip the scroll direction independently for the trackpad and a mouse wheel."
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

    @Published var settingsTab: SettingsTab = .general

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
        showInDock = defaults.bool(forKey: "showInDock")
        colorTemperatureEnabled = defaults.bool(forKey: "colorTemperatureEnabled")
        scrollReverserEnabled = defaults.bool(forKey: "scrollReverserEnabled")
        rewritelyEnabled = defaults.bool(forKey: "rewritelyEnabled")
        appearanceMode = AppearanceMode(
            rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
    }

    /// Start whatever was enabled in the previous session. Called once at launch.
    func startEnabledFeatures() {
        DockIconManager.apply(showInDock: showInDock)
        applyAppearance()
        if colorTemperatureEnabled { colorTemperature.start() }
        if scrollReverserEnabled { scrollReverser.start() }
        if rewritelyEnabled { rewritely.start() }
    }

    /// Tear down anything that mutates global system state. Called at quit.
    func shutdown() {
        colorTemperature.stop()
        scrollReverser.stop()
        rewritely.stop()
    }
}
