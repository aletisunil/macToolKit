import CoreGraphics
import Foundation

/// The modifier held down for the duration of a switch; releasing it commits.
enum HoldModifier: String, Codable, CaseIterable, Identifiable {
    case option, command, control, function

    var id: String { rawValue }

    var cgFlag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .command: .maskCommand
        case .control: .maskControl
        case .function: .maskSecondaryFn
        }
    }

    var symbol: String {
        switch self {
        case .option: "⌥"
        case .command: "⌘"
        case .control: "⌃"
        case .function: "fn"
        }
    }
}

/// The key pressed (while holding the modifier) to open and cycle.
enum TriggerKey: String, Codable, CaseIterable, Identifiable {
    case tab, backtick

    var id: String { rawValue }

    var keyCode: Int64 {
        switch self {
        case .tab: 48
        case .backtick: 50
        }
    }

    var symbol: String {
        switch self {
        case .tab: "⇥"
        case .backtick: "`"
        }
    }
}

/// How the switcher renders its windows.
enum SwitcherStyle: String, Codable, CaseIterable, Identifiable {
    case thumbnails, appIcons, titles

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thumbnails: "Thumbnails"
        case .appIcons: "App icons"
        case .titles: "Titles"
        }
    }
}

/// One of up to nine independent switcher shortcuts, each with its own
/// trigger chord, window filters and style. Setting the modifier to ⌘ with
/// the Tab key makes that slot a full Cmd-Tab replacement (the trigger is
/// swallowed before the system switcher sees it).
struct ShortcutSlot: Codable, Identifiable, Equatable {
    var id: UUID
    var holdModifier: HoldModifier
    var key: TriggerKey
    var style: SwitcherStyle
    /// Only windows on the currently visible Space(s).
    var activeSpaceOnly: Bool
    /// Only windows on the screen the switcher appears on.
    var currentScreenOnly: Bool
    /// Only windows of the frontmost app.
    var sameAppOnly: Bool

    init(id: UUID = UUID(),
         holdModifier: HoldModifier = .option,
         key: TriggerKey = .tab,
         style: SwitcherStyle = .thumbnails,
         activeSpaceOnly: Bool = false,
         currentScreenOnly: Bool = false,
         sameAppOnly: Bool = false) {
        self.id = id
        self.holdModifier = holdModifier
        self.key = key
        self.style = style
        self.activeSpaceOnly = activeSpaceOnly
        self.currentScreenOnly = currentScreenOnly
        self.sameAppOnly = sameAppOnly
    }

    var chordDescription: String { holdModifier.symbol + " " + key.symbol }
}

@MainActor
final class ShortcutStore: ObservableObject {
    static let maxSlots = 9

    @Published var slots: [ShortcutSlot] {
        didSet { save() }
    }

    private static let key = "switcherShortcuts"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([ShortcutSlot].self, from: data),
           !saved.isEmpty {
            slots = Array(saved.prefix(Self.maxSlots))
        } else {
            slots = [ShortcutSlot()]
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(slots) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Ids of slots whose chord is already claimed by an earlier slot. The tap
    /// matches the first trigger for a chord, so a duplicate slot is dead —
    /// the settings pane flags these instead of letting it fail silently.
    var conflictingSlotIDs: Set<UUID> {
        var seen: Set<String> = []
        var conflicts: Set<UUID> = []
        for slot in slots {
            let chord = "\(slot.holdModifier.rawValue)+\(slot.key.rawValue)"
            if !seen.insert(chord).inserted {
                conflicts.insert(slot.id)
            }
        }
        return conflicts
    }
}
