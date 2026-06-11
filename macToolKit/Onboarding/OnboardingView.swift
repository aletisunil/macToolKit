import SwiftUI
import FinderSync

/// Two-step welcome flow: what the app does, then the setup actions that
/// need the user's hand (Finder extension, Accessibility, Apple Intelligence).
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if page == 0 {
                    WelcomePage()
                } else {
                    SetupPage()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 8) {
                Button {
                    if page == 0 {
                        page = 1
                    } else {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        OnboardingWindowController.shared.close()
                    }
                } label: {
                    Text(page == 0 ? "Continue" : "Done")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                if page == 1 {
                    Button("Back") { page = 0 }
                        .buttonStyle(.link)
                        .font(.callout)
                } else {
                    // Keeps the layout height stable across pages.
                    Text(" ").font(.callout)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(width: 460, height: 560)
    }
}

// MARK: - Page 1: what's in the box

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                Text("Welcome to macToolKit")
                    .font(.title.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 22) {
                FeatureRow(tab: .finder,
                           title: "Finder tools",
                           detail: "Create files and copy folder paths straight from Finder's right-click menu.")
                FeatureRow(tab: .display,
                           title: "Color temperature",
                           detail: "Warms the display in the evening so it's easier on the eyes. Manual slider or fully automatic.")
                FeatureRow(tab: .rewritely,
                           title: "Rewritely",
                           detail: "End any text with a trigger word like ;;fix and Apple Intelligence rewrites it in place.")
                FeatureRow(tab: .scrolling,
                           title: "Scroll Reverser",
                           detail: "Flip scroll direction independently for the trackpad and a mouse wheel.")
            }
            .padding(.horizontal, 44)
        }
    }
}

private struct FeatureRow: View {
    let tab: SettingsTab
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: tab.icon)
                .font(.system(size: 22))
                .foregroundStyle(tab.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Page 2: setup

private struct SetupPage: View {
    @EnvironmentObject private var appState: AppState
    @State private var accessibilityGranted = Permissions.accessibilityGranted
    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                Text("Set up macToolKit")
                    .font(.title.weight(.semibold))
                Text("Two quick steps. Everything else works out of the box.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 24) {
                SetupRow(
                    step: "1",
                    title: "Enable the Finder extension",
                    detail: "System Settings → General → Login Items & Extensions → Finder, then turn on “macToolKit Finder Tools”.",
                    done: extensionEnabled, showsStatus: true
                ) {
                    Button("Open Extension Settings…") {
                        Permissions.openExtensionsSettings()
                    }
                }
                SetupRow(
                    step: "2",
                    title: "Grant Accessibility access",
                    detail: "Used by Scroll Reverser and Rewritely to read scroll events and replace text. The features start on their own once access is granted.",
                    done: accessibilityGranted, showsStatus: true
                ) {
                    Button("Open Accessibility Settings…") {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
                if let reason = RewriteEngine.availabilityDescription() {
                    SetupRow(
                        step: "!",
                        title: "Apple Intelligence",
                        detail: reason,
                        done: false, showsStatus: false
                    ) {
                        EmptyView()
                    }
                }
            }
            .padding(.horizontal, 40)

            Spacer()

            Text("Features can be turned on and off any time from the wrench icon in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
                .padding(.bottom, 8)
        }
        .onReceive(timer) { _ in
            accessibilityGranted = Permissions.accessibilityGranted
            extensionEnabled = FIFinderSyncController.isExtensionEnabled
        }
    }
}

private struct SetupRow<Action: View>: View {
    let step: String
    let title: String
    let detail: String
    let done: Bool
    let showsStatus: Bool
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                    .frame(width: 30)
            } else {
                Text(step)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(.tertiary))
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    if showsStatus && done {
                        Text("Granted")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    action
                }
            }
        }
    }
}
