import SwiftUI
import ServiceManagement

// Layout modeled on Dictify: dark slim sidebar with uppercase section labels
// and quiet gray selection, detail pane of large rounded cards — hero card
// with circular icon + status chip, section headers with trailing link
// actions, generous padding throughout.

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        .frame(width: 840)
        .frame(minHeight: 560)
        .background(Color(nsColor: .appWindowBackground))
        .ignoresSafeArea()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("macToolKit")
                        .font(.headline)
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 36)
            .padding(.bottom, 14)

            SidebarSectionLabel("Features")
            ForEach(SettingsTab.featureTabs) { tab in
                SidebarRow(tab: tab, selected: appState.settingsTab == tab) {
                    appState.settingsTab = tab
                }
            }

            SidebarSectionLabel("App")
                .padding(.top, 16)
            ForEach(SettingsTab.appTabs) { tab in
                SidebarRow(tab: tab, selected: appState.settingsTab == tab) {
                    appState.settingsTab = tab
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 204)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .appSidebarBackground))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
                .frame(width: 1)
        }
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch appState.settingsTab {
                case .display: DisplayPane()
                case .rewritely: RewritelyPane()
                case .scrolling: ScrollingPane()
                case .general: GeneralPane()
                case .about: AboutPane()
                }
            }
            .id(appState.settingsTab)
            .transition(.opacity)
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.18), value: appState.settingsTab)
        // Dictify uses compact macOS controls throughout the detail pane.
        .controlSize(.small)
    }
}

// MARK: - Building blocks

struct SidebarSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(1.1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

struct SidebarRow: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var rowBackground: AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.accentColor) }
        if hovering { return AnyShapeStyle(.quaternary.opacity(0.5)) }
        return AnyShapeStyle(.clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                IconTile(icon: tab.icon, tint: tab.tint, side: 20)
                Text(tab.title)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Large rounded card surface.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .appCardBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4))
        )
    }
}

/// Hero card: tinted gradient icon tile, title, blurb, trailing status chip.
struct HeroCard<Trailing: View>: View {
    let tab: SettingsTab
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Card {
            HStack(spacing: 12) {
                IconTile(icon: tab.icon, tint: tab.tint, side: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title)
                        .font(.headline)
                    Text(tab.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailing
            }
        }
    }
}

/// Bordered status chip, optionally clickable (toggles the feature).
struct StatusChip: View {
    let isOn: Bool
    var label: (on: String, off: String) = ("Enabled", "Disabled")
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { chipBody }
                    .buttonStyle(.plain)
            } else {
                chipBody
            }
        }
    }

    private var chipBody: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 6, height: 6)
            Text(isOn ? label.on : label.off)
                .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}

/// "STATUS" eyebrow + chip stacked, used in hero cards.
struct StatusColumn: View {
    let title: String
    let isOn: Bool
    var label: (on: String, off: String) = ("Enabled", "Disabled")
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(1.1)
                .foregroundStyle(.secondary)
            StatusChip(isOn: isOn, label: label, action: action)
        }
    }
}

/// Section header with an optional trailing link action.
struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
            }
        }
        .padding(.top, 6)
    }
}

/// Title + caption row with a trailing control.
struct CardRow<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().opacity(0.5)
    }
}

struct ValueBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.monospaced().weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.7))
            )
    }
}

struct WarningRow: View {
    let text: String
    var icon: String = "hourglass"

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote)
            .foregroundStyle(.orange)
    }
}

// MARK: - Display

private struct DisplayPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var controller = AppState.shared.colorTemperature

    var body: some View {
        HeroCard(tab: .display) {
            StatusColumn(title: "Status", isOn: appState.colorTemperatureEnabled) {
                appState.colorTemperatureEnabled.toggle()
            }
        }

        Card {
            CardRow(title: "Mode",
                    caption: controller.mode == .manual
                        ? "The display stays at the temperature you set below."
                        : "The display warms automatically in the evening and returns to normal in the morning.") {
                Picker("", selection: $controller.mode) {
                    Text("Manual").tag(ColorTemperatureMode.manual)
                    Text("Automatic").tag(ColorTemperatureMode.auto)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }

        Card {
            CardRow(title: controller.mode == .manual ? "Temperature" : "Night temperature",
                    caption: "Lower is warmer. Daylight is 6500 K.") {
                ValueBadge(text: "\(Int(controller.kelvin)) K")
            }
            HStack(spacing: 12) {
                Text("Warm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $controller.kelvin,
                       in: ColorTemperatureController.minKelvin...ColorTemperatureController.maxKelvin,
                       step: 50)
                Text("Daylight")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if controller.mode == .auto {
            Card {
                CardRow(title: "Use location",
                        caption: "Computes sunrise and sunset for your location.") {
                    Toggle("", isOn: $controller.useLocation)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                if !controller.useLocation {
                    RowDivider()
                    CardRow(title: "Evening starts", caption: nil) {
                        MinutePicker(label: "", minutes: $controller.fallbackSunsetMinutes)
                            .labelsHidden()
                            .frame(width: 110)
                    }
                    RowDivider()
                    CardRow(title: "Morning starts", caption: nil) {
                        MinutePicker(label: "", minutes: $controller.fallbackSunriseMinutes)
                            .labelsHidden()
                            .frame(width: 110)
                    }
                }
                Text("Nights use the temperature above, fading over 30 minutes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct MinutePicker: View {
    let label: String
    @Binding var minutes: Int

    var body: some View {
        Picker(label, selection: $minutes) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { value in
                Text(String(format: "%02d:%02d", value / 60, value % 60)).tag(value)
            }
        }
    }
}

// MARK: - Rewritely

private struct RewritelyPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var rewritely = AppState.shared.rewritely
    @ObservedObject private var triggers = AppState.shared.rewritely.triggers
    @State private var editingTrigger: RewriteTrigger?

    var body: some View {
        HeroCard(tab: .rewritely) {
            StatusColumn(title: "Status", isOn: appState.rewritelyEnabled) {
                appState.rewritelyEnabled.toggle()
            }
        }

        if let reason = RewriteEngine.availabilityDescription() {
            Card {
                WarningRow(text: reason, icon: "exclamationmark.triangle.fill")
            }
        }
        if appState.rewritelyEnabled && !rewritely.tapActive {
            Card {
                WarningRow(text: "Waiting for Accessibility permission. Rewritely starts automatically once it's granted.")
            }
        }

        SectionHeader(title: "Triggers", actionTitle: "Add Trigger") {
            editingTrigger = RewriteTrigger(
                word: "",
                prompt: "Rewrite the following text.\n\n{{text}}")
        }

        Card {
            ForEach(triggers.triggers) { trigger in
                HStack(spacing: 14) {
                    ValueBadge(text: trigger.word)
                    Text(trigger.prompt.replacingOccurrences(of: "\n", with: " "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        Button("Edit") { editingTrigger = trigger }
                        Button("Remove", role: .destructive) {
                            triggers.triggers.removeAll { $0.id == trigger.id }
                        }
                    }
                }
                if trigger.id != triggers.triggers.last?.id {
                    RowDivider()
                }
            }
            if triggers.triggers.isEmpty {
                Text("No triggers yet. Add one, then type it at the end of any text field.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        Text("Use {{text}} in a prompt to mark where the field's text goes.")
            .font(.caption)
            .foregroundStyle(.tertiary)

        Color.clear.frame(height: 0)
            .sheet(item: $editingTrigger) { trigger in
                TriggerEditorSheet(trigger: trigger) { updated in
                    if let index = triggers.triggers.firstIndex(where: { $0.id == updated.id }) {
                        triggers.triggers[index] = updated
                    } else {
                        triggers.triggers.append(updated)
                    }
                }
            }
    }
}

// MARK: - Scrolling

private struct ScrollingPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var scroll = AppState.shared.scrollReverser

    var body: some View {
        HeroCard(tab: .scrolling) {
            StatusColumn(title: "Status", isOn: appState.scrollReverserEnabled) {
                appState.scrollReverserEnabled.toggle()
            }
        }

        if appState.scrollReverserEnabled && !scroll.tapActive {
            Card {
                WarningRow(text: "Waiting for Accessibility permission. Scroll Reverser starts automatically once it's granted.")
            }
        }

        Card {
            CardRow(title: "Trackpad and Magic Mouse",
                    caption: "Reverse two-finger and Magic Mouse scrolling.") {
                Toggle("", isOn: $scroll.reverseTrackpad)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            RowDivider()
            CardRow(title: "Mouse wheel",
                    caption: "Reverse scrolling from a regular mouse wheel.") {
                Toggle("", isOn: $scroll.reverseMouse)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }

        Card {
            CardRow(title: "Vertical scrolling", caption: nil) {
                Toggle("", isOn: $scroll.reverseVertical)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            RowDivider()
            CardRow(title: "Horizontal scrolling", caption: nil) {
                Toggle("", isOn: $scroll.reverseHorizontal)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var accessibilityGranted = Permissions.accessibilityGranted

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HeroCard(tab: .general) {
            EmptyView()
        }

        Card {
            CardRow(title: "Appearance", caption: nil) {
                Picker("", selection: $appState.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            RowDivider()
            CardRow(title: "Show in Dock",
                    caption: "The menu bar icon stays either way.") {
                Toggle("", isOn: $appState.showInDock)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            RowDivider()
            CardRow(title: "Launch at login", caption: nil) {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, enable in
                        do {
                            if enable {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }

        SectionHeader(title: "Permissions")

        Card {
            CardRow(title: "Accessibility",
                    caption: "Used by Scroll Reverser and Rewritely. Color Temperature works without it.") {
                if accessibilityGranted {
                    StatusChip(isOn: true, label: ("Granted", "Not granted"))
                } else {
                    Button("Grant…") {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            accessibilityGranted = Permissions.accessibilityGranted
        }
    }
}

// MARK: - About

/// Centered About layout: glowing app icon, name + version, then eyebrow
/// sections (Powered by / Feedback & Support / Getting started) and a
/// copyright footer pinned at the bottom.
private struct AboutPane: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .shadow(color: Color.accentColor.opacity(0.45), radius: 22)

            Text("macToolKit")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 14)
            Text("Version \(version)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            Text("A small toolbox for your Mac")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 22)

            AboutSection("Tools") {
                Text("Color Temperature · Rewritely · Scroll Reverser")
                    .font(.footnote)
            }

            Spacer(minLength: 28)

            Text("© 2026 Sunil Aleti")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 440)
    }
}

private struct AboutSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.top, 20)
    }
}

// MARK: - Editor sheets

/// Edits a trigger in local state and commits on Save.
struct TriggerEditorSheet: View {
    @State private var word: String
    @State private var prompt: String
    private let id: UUID
    private let isNew: Bool
    private let onSave: (RewriteTrigger) -> Void
    @Environment(\.dismiss) private var dismiss

    init(trigger: RewriteTrigger, onSave: @escaping (RewriteTrigger) -> Void) {
        _word = State(initialValue: trigger.word)
        _prompt = State(initialValue: trigger.prompt)
        id = trigger.id
        isNew = trigger.word.isEmpty
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Trigger" : "Edit Trigger")
                .font(.headline)
            TextField("Trigger word", text: $word, prompt: Text("fxx"))
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
            Text("Prompt — {{text}} marks where the field's text goes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 110)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = word.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    onSave(RewriteTrigger(id: id, word: trimmed, prompt: prompt))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
