import Combine
import Sparkle

/// Owns the Sparkle updater for the app's lifetime and republishes the
/// pieces of its state the UI binds to. Created once at launch so
/// scheduled background checks run even if settings is never opened.
@MainActor
final class UpdaterManager: NSObject, ObservableObject {
    static let shared = UpdaterManager()

    /// False while a check is already in progress; drives button enablement.
    @Published private(set) var canCheckForUpdates = false

    /// Set while a background check has found an update the user has not
    /// looked at yet. Drives the menu bar badge and the menu's update item,
    /// which are this app's gentle reminder - see the user driver delegate
    /// below.
    @Published private(set) var pendingUpdateVersion: String?

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

    /// Assigned during init: the controller takes its user driver delegate at
    /// construction, so `self` has to exist first. Never nil afterwards.
    private var controller: SPUStandardUpdaterController!

    private override init() {
        // Placeholder: the real value comes off the updater once it exists,
        // which cannot happen until `self` does.
        automaticallyChecksForUpdates = false
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: self)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    /// User-initiated check: shows Sparkle's UI, including "no update" alerts.
    /// Also the way a pending background update is brought into focus.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

// MARK: - Gentle reminders

/// macToolKit has no dock icon and no windows of its own, so Sparkle's default
/// scheduled-update alert would open behind whatever the user is working in and
/// go unnoticed. Instead the app handles scheduled updates itself: it badges the
/// menu bar icon and offers an update item in the menu, and only shows Sparkle's
/// alert once the user asks for it.
extension UpdaterManager: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Never let the standard driver put an alert on screen unprompted -
        // even "in immediate focus" it interrupts whatever is in front.
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // True for user-initiated checks, where Sparkle's own UI is already
        // the reminder.
        guard !handleShowingUpdate else { return }
        MainActor.assumeIsolated {
            pendingUpdateVersion = update.displayVersionString
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }
}
