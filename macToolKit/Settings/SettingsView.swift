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
                case .windowSwitcher: WindowSwitcherPane()
                case .folderPeek: FolderPeekPane()
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

/// Neutral status for integrations whose enablement is controlled by macOS.
struct ManagedStatusColumn: View {
    let title: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(1.1)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Managed by macOS")
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

/// Explains why a tap-backed feature is enabled but not running.
///
/// `tapActive == false` has two very different causes and they need
/// different things from the user: Accessibility hasn't been granted yet
/// (go grant it), or it has been granted and macOS still refused the event
/// tap (nothing to grant — it retries on its own). Reporting both as
/// "waiting for permission" sent people to a settings pane where everything
/// already looked correct.
struct TapStatusCard: View {
    let featureName: String
    let isEnabled: Bool
    let tapActive: Bool

    var body: some View {
        // The permission check only runs when there is already a problem to
        // explain, so it stays off the normal render path.
        if isEnabled, !tapActive {
            Card {
                if Permissions.accessibilityGranted {
                    WarningRow(
                        text: "\(featureName) has Accessibility access, but macOS didn't let it start. Retrying automatically. If it doesn't recover, quit and reopen macToolKit.",
                        icon: "arrow.triangle.2.circlepath")
                } else {
                    WarningRow(
                        text: "Waiting for Accessibility permission. \(featureName) starts automatically once it's granted.")
                }
            }
        }
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
        TapStatusCard(featureName: "Rewritely",
                      isEnabled: appState.rewritelyEnabled,
                      tapActive: rewritely.tapActive)

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

        TapStatusCard(featureName: "Scroll Reverser",
                      isEnabled: appState.scrollReverserEnabled,
                      tapActive: scroll.tapActive)

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

// MARK: - Window Switcher

private struct WindowSwitcherPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var switcher = AppState.shared.windowSwitcher
    @ObservedObject private var shortcuts = AppState.shared.windowSwitcher.shortcuts
    @ObservedObject private var blacklist = AppState.shared.windowSwitcher.blacklist
    @State private var screenRecordingGranted = Permissions.screenRecordingGranted

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HeroCard(tab: .windowSwitcher) {
            StatusColumn(title: "Status", isOn: appState.windowSwitcherEnabled) {
                appState.windowSwitcherEnabled.toggle()
            }
        }

        TapStatusCard(featureName: "The window switcher",
                      isEnabled: appState.windowSwitcherEnabled,
                      tapActive: switcher.tapActive)

        SectionHeader(title: "Shortcuts",
                      actionTitle: shortcuts.slots.count < ShortcutStore.maxSlots
                          ? "Add shortcut" : nil) {
            shortcuts.slots.append(ShortcutSlot())
        }

        Text("Hold the modifier and press the key to open; keep pressing to cycle, ⇧ cycles backwards, Esc cancels, release the modifier to switch. Set ⌘ + ⇥ to replace the system Cmd-Tab switcher.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        let conflicts = shortcuts.conflictingSlotIDs
        ForEach($shortcuts.slots) { $slot in
            ShortcutSlotCard(
                slot: $slot,
                index: shortcuts.slots.firstIndex(where: { $0.id == slot.id }) ?? 0,
                removable: shortcuts.slots.count > 1,
                conflicted: conflicts.contains(slot.id)
            ) {
                shortcuts.slots.removeAll { $0.id == slot.id }
            }
        }

        SectionHeader(title: "Windows")

        Card {
            includeToggle("Minimized windows",
                          caption: "Shown with a badge at the end of the list.",
                          isOn: $switcher.includeMinimized)
            RowDivider()
            includeToggle("Windows of hidden apps",
                          caption: "Apps hidden with ⌘H stay switchable.",
                          isOn: $switcher.includeHidden)
            RowDivider()
            includeToggle("Windows on other Spaces",
                          caption: PrivateCGS.available
                              ? "Badged with their Space number."
                              : "Unavailable on this macOS version.",
                          isOn: $switcher.includeOtherSpaces)
            RowDivider()
            includeToggle("Fullscreen windows",
                          caption: nil,
                          isOn: $switcher.includeFullscreen)
        }

        SectionHeader(title: "Behavior")

        Card {
            CardRow(title: "Show after",
                    caption: "Quick chords still switch during the delay; only the panel waits.") {
                Picker("", selection: $switcher.showDelay) {
                    Text("Instantly").tag(0.0)
                    Text("0.1 s").tag(0.1)
                    Text("0.2 s").tag(0.2)
                    Text("0.5 s").tag(0.5)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            RowDivider()
            CardRow(title: "Appears on", caption: nil) {
                Picker("", selection: $switcher.screenChoice) {
                    ForEach(SwitcherScreenChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
        }

        SectionHeader(title: "Appearance")

        Card {
            CardRow(title: "Size", caption: nil) {
                Picker("", selection: $switcher.thumbnailSize) {
                    ForEach(ThumbnailSize.allCases) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            RowDivider()
            CardRow(title: "Alignment", caption: nil) {
                Picker("", selection: $switcher.alignment) {
                    ForEach(SwitcherAlignment.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            RowDivider()
            CardRow(title: "Theme", caption: nil) {
                Picker("", selection: $switcher.theme) {
                    ForEach(SwitcherTheme.allCases) { value in
                        Text(value.label).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
            RowDivider()
            CardRow(title: "Fade in", caption: nil) {
                Toggle("", isOn: $switcher.fadeIn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            RowDivider()
            CardRow(title: "VoiceOver focus",
                    caption: "The switcher takes keyboard focus while open so VoiceOver can read the tiles.") {
                Toggle("", isOn: $switcher.assistiveFocus)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }

        SectionHeader(title: "Blacklist", actionTitle: "Add app…") {
            addBlacklistApp()
        }

        if blacklist.entries.isEmpty {
            Card {
                Text("Hide an app's windows from the switcher, or let it keep the real shortcut (useful for VMs and remote desktops).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Card {
                ForEach(blacklist.entries) { entry in
                    BlacklistRow(entry: entry, store: blacklist)
                    if entry.id != blacklist.entries.last?.id {
                        RowDivider()
                    }
                }
            }
        }

        SectionHeader(title: "Window previews")

        Card {
            CardRow(title: "Screen Recording",
                    caption: "Needed for window previews. Without it the switcher shows app icons instead.") {
                if screenRecordingGranted {
                    StatusChip(isOn: true, label: ("Granted", "Not granted"))
                } else {
                    Button("Grant…") {
                        Permissions.requestScreenRecording()
                        Permissions.openScreenRecordingSettings()
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            screenRecordingGranted = Permissions.screenRecordingGranted
        }
    }

    private func includeToggle(_ title: String, caption: String?,
                               isOn: Binding<Bool>) -> some View {
        CardRow(title: title, caption: caption) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private func addBlacklistApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.message = "Choose apps to blacklist from the window switcher."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            blacklist.add(bundleID: bundleID, name: name)
        }
    }
}

/// Editor for one of the nine shortcut slots: trigger chord, style, filters.
private struct ShortcutSlotCard: View {
    @Binding var slot: ShortcutSlot
    let index: Int
    let removable: Bool
    /// An earlier slot already uses this chord, so this one never fires.
    var conflicted = false
    let onRemove: () -> Void

    var body: some View {
        Card {
            HStack {
                Text("Shortcut \(index + 1)")
                    .font(.callout.weight(.medium))
                Spacer()
                ValueBadge(text: slot.chordDescription)
                if removable {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove shortcut")
                }
            }
            if conflicted {
                WarningRow(
                    text: "Another shortcut already uses \(slot.chordDescription). This one won't fire until you change it.",
                    icon: "exclamationmark.triangle.fill")
            }
            RowDivider()
            CardRow(title: "Hold", caption: nil) {
                Picker("", selection: $slot.holdModifier) {
                    ForEach(HoldModifier.allCases) { modifier in
                        Text(modifier.symbol).tag(modifier)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }
            CardRow(title: "Then press", caption: nil) {
                Picker("", selection: $slot.key) {
                    ForEach(TriggerKey.allCases) { key in
                        Text(key.symbol).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
            CardRow(title: "Style", caption: nil) {
                Picker("", selection: $slot.style) {
                    ForEach(SwitcherStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            RowDivider()
            CardRow(title: "Only windows on the active Space", caption: nil) {
                miniToggle($slot.activeSpaceOnly)
            }
            CardRow(title: "Only windows on the switcher's screen", caption: nil) {
                miniToggle($slot.currentScreenOnly)
            }
            CardRow(title: "Only windows of the frontmost app", caption: nil) {
                miniToggle($slot.sameAppOnly)
            }
        }
    }

    private func miniToggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
    }
}

private struct BlacklistRow: View {
    let entry: BlacklistEntry
    @ObservedObject var store: BlacklistStore

    private var binding: Binding<BlacklistEntry>? {
        guard let index = store.entries.firstIndex(where: { $0.id == entry.id })
        else { return nil }
        return $store.entries[index]
    }

    var body: some View {
        if let binding {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.callout.weight(.medium))
                    Text(entry.bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 12)
                Toggle("Hide windows", isOn: binding.hideWindows)
                    .toggleStyle(.checkbox)
                    .font(.footnote)
                Toggle("Don't intercept", isOn: binding.dontIntercept)
                    .toggleStyle(.checkbox)
                    .font(.footnote)
                Button {
                    store.entries.removeAll { $0.id == entry.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from blacklist")
            }
        }
    }
}

// MARK: - Folder Peek

private struct FolderPeekPane: View {
    @StateObject private var preferences = FolderPeekPreferences()

    var body: some View {
        HeroCard(tab: .folderPeek) {
            ManagedStatusColumn(title: "Integration")
        }

        Text("Select a folder in Finder or on the Desktop and press Space. Finder opens Folder Peek in its native Quick Look window; Space or Esc closes it. Files keep their normal previews.")
            .font(.footnote)
            .foregroundStyle(.secondary)

        SectionHeader(title: "Quick Look Extension")

        Card {
            CardRow(
                title: "Folder previews",
                caption: "Installed with macToolKit. No Accessibility, Automation, Screen Recording or Full Disk Access is required."
            ) {
                Button("Extension Settings…") {
                    Permissions.openExtensionsSettings()
                }
            }
        }

        SectionHeader(title: "Contents")

        Card {
            CardRow(
                title: "Show hidden files",
                caption: "Include items whose names begin with a dot and files marked hidden."
            ) {
                Toggle("", isOn: $preferences.showHiddenFiles)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            RowDivider()
            CardRow(
                title: "Depth level",
                caption: "Automatically show nested folders up to this many levels."
            ) {
                Stepper(value: $preferences.depthLevel, in: 1...10) {
                    Text("\(preferences.depthLevel)")
                        .monospacedDigit()
                        .frame(width: 22)
                }
                .fixedSize()
            }
            RowDivider()
            CardRow(
                title: "Show path bar",
                caption: "Display the folder's location at the bottom of the preview."
            ) {
                Toggle("", isOn: $preferences.showPathBar)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }

        SectionHeader(title: "Appearance")

        Card {
            CardRow(title: "Icon size", caption: nil) {
                Picker("", selection: $preferences.iconSize) {
                    ForEach(FolderPeekIconSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 250)
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updater = UpdaterManager.shared
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

        SectionHeader(title: "Updates")

        Card {
            CardRow(title: "Automatically check for updates",
                    caption: "Checks in the background about once a day.") {
                Toggle("", isOn: $updater.automaticallyChecksForUpdates)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
            RowDivider()
            CardRow(title: "Check for updates",
                    caption: "Version \(Bundle.main.shortVersion) installed.") {
                Button("Check Now…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
        }

        SectionHeader(title: "Permissions")

        Card {
            CardRow(title: "Accessibility",
                    caption: "Used by Scroll Reverser, Rewritely and Window Switcher. Color Temperature and Folder Peek work without it.") {
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
            Text("Version \(Bundle.main.shortVersion)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 3)

            Text("A small toolbox for your Mac")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 22)

            AboutSection("Tools") {
                Text("Color Temperature · Rewritely · Scroll Reverser · Window Switcher · Folder Peek")
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

extension Bundle {
    /// Marketing version shown in General and About panes.
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
