import SwiftUI
import FinderSync

/// Six-page welcome flow: a welcome overview, one how-to page per feature,
/// and a final permissions page. Nothing asks the system for access until
/// the user reaches the last page and clicks a button there.
struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var page = 0

    private static let pageCount = 6
    private var isLastPage: Bool { page == Self.pageCount - 1 }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0:
                    WelcomePage()
                case 1:
                    FeaturePage(
                        tab: .finder,
                        headline: "Create files and copy paths without leaving Finder.",
                        steps: [
                            "Right-click inside any folder in Finder.",
                            "Use the macToolKit menu items to create a new file on the spot or copy the folder's path.",
                        ],
                        footnote: "Needs the Finder extension — you'll switch it on at the last step.")
                case 2:
                    FeaturePage(
                        tab: .display,
                        headline: "Warms the display in the evening so it's easier on the eyes.",
                        steps: [
                            "Turn it on from the wrench icon in the menu bar.",
                            "Drag the slider for a fixed warmth, or pick Automatic to follow sunset and sunrise.",
                            "Automatic mode can use your location for exact sun times — macOS asks only if you choose it.",
                        ],
                        footnote: "No permissions needed for manual mode.")
                case 3:
                    FeaturePage(
                        tab: .rewritely,
                        headline: "Rewrite text in place with Apple Intelligence.",
                        steps: [
                            "Type anywhere — an email, a chat, a document.",
                            "End with a trigger word like ;;fix.",
                            "The text is rewritten right where it is. Add your own triggers in Settings.",
                        ],
                        footnote: "Uses Accessibility access to read and replace the text — granted at the last step.")
                case 4:
                    FeaturePage(
                        tab: .scrolling,
                        headline: "Flip scroll direction per device.",
                        steps: [
                            "Turn it on from the wrench icon in the menu bar.",
                            "Choose what to flip: the trackpad and Magic Mouse, a mouse wheel, or both.",
                            "Each keeps its own direction — natural on the trackpad, classic on the wheel.",
                        ],
                        footnote: "Uses Accessibility access to see scroll events — granted at the last step.")
                default:
                    SetupPage()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 10) {
                PageDots(count: Self.pageCount, current: page)

                Button {
                    if isLastPage {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        OnboardingWindowController.shared.close()
                        appState.startEnabledFeatures()
                    } else {
                        page += 1
                    }
                } label: {
                    Text(isLastPage ? "Done" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                HStack {
                    if page > 0 {
                        Button("Back") { page -= 1 }
                    }
                    Spacer()
                    if !isLastPage {
                        Button("Skip tour") { page = Self.pageCount - 1 }
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
                // Keeps the layout height stable across pages.
                .frame(height: 18)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
        .frame(width: 460, height: 560)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary : Color.primary.opacity(0.2))
                    .frame(width: 7, height: 7)
            }
        }
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
                Text("Four small tools for your Mac. Here's the quick tour.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(tab: .finder,
                           title: "Finder tools",
                           detail: "Create files and copy folder paths straight from Finder's right-click menu.")
                FeatureRow(tab: .display,
                           title: "Color temperature",
                           detail: "Warms the display in the evening so it's easier on the eyes.")
                FeatureRow(tab: .rewritely,
                           title: "Rewritely",
                           detail: "End any text with a trigger word and Apple Intelligence rewrites it in place.")
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
            IconTile(icon: tab.icon, tint: tab.tint, side: 30)
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

// MARK: - Pages 2–5: one feature each

private struct FeaturePage: View {
    let tab: SettingsTab
    let headline: String
    let steps: [String]
    let footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 12) {
                IconTile(icon: tab.icon, tint: tab.tint, side: 60)
                Text(tab.title)
                    .font(.title.weight(.semibold))
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 20) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.tertiary))
                            .frame(width: 30)
                        Text(step)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 3)
                    }
                }
            }
            .padding(.horizontal, 44)

            Spacer()

            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Page 6: permissions

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
