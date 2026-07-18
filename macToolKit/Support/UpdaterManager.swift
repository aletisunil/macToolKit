import Combine
import Sparkle

/// Owns the Sparkle updater for the app's lifetime and republishes the
/// pieces of its state the UI binds to. Created once at launch so
/// scheduled background checks run even if settings is never opened.
@MainActor
final class UpdaterManager: ObservableObject {
    static let shared = UpdaterManager()

    /// False while a check is already in progress; drives button enablement.
    @Published private(set) var canCheckForUpdates = false

    /// Persisted by Sparkle itself (SUEnableAutomaticChecks seeds the
    /// default). Mirrored here via KVO so any writer (this setter or
    /// Sparkle internally) refreshes bound UI.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            if controller.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    /// User-initiated check: shows Sparkle's UI, including "no update" alerts.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
