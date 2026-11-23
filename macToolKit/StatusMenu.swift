import AppKit
import Combine

/// The menu bar icon and its menu.
///
/// Built on AppKit rather than a SwiftUI `MenuBarExtra`: choosing a menu item
/// ends menu tracking, so a menu of feature toggles closed after every flip.
/// A click inside an item's custom view does not end tracking, so every
/// feature row is a view - drawn exactly like a checkmark item - and several
/// features can be switched in one visit, with the left or the right button.
/// The view stays put for as long as the menu is open: swapping it for a
/// plain item as the highlight moves left the old highlight drawn on screen.
/// A view-backed item gets none of a plain item's keyboard and accessibility
/// handling, so the row supplies its own: Return, Enter and Space flip the
/// feature and close the menu, as choosing a plain item would, and VoiceOver
/// reads and presses it as a checkbox.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let shared = StatusMenuController()

    private struct Feature {
        let title: String
        let isOn: ReferenceWritableKeyPath<AppState, Bool>
    }

    /// Same grouping as the Settings sidebar. Peek has no toggle here: macOS
    /// manages Quick Look extensions.
    private static let sections: [(title: String, features: [Feature])] = [
        ("Windows", [
            Feature(title: "Window Switcher", isOn: \.windowSwitcherEnabled),
            Feature(title: "Quit on Close", isOn: \.quitOnCloseEnabled),
            Feature(title: "Maximize Windows", isOn: \.maximizeWindowsEnabled),
        ]),
        ("Mouse & Keyboard", [
            Feature(title: "Smooth Scrolling", isOn: \.smoothScrollingEnabled),
            Feature(title: "Scroll Reverser", isOn: \.scrollReverserEnabled),
            Feature(title: "Side Buttons", isOn: \.sideButtonsEnabled),
            Feature(title: "Rewritely", isOn: \.rewritelyEnabled),
        ]),
        ("Finder", [
            Feature(title: "Cut & Paste", isOn: \.finderCutPasteEnabled),
        ]),
        ("System", [
            Feature(title: "Color Temperature", isOn: \.colorTemperatureEnabled),
            Feature(title: "Audio Priority", isOn: \.audioPriorityEnabled),
        ]),
    ]

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private struct Row {
        let item: NSMenuItem
        let view: MenuToggleRowView
        let isOn: KeyPath<AppState, Bool>
    }

    /// The feature rows of the menu as last built, refreshed in place when a
    /// feature changes from elsewhere (Settings, a permission being denied)
    /// while the menu is open.
    private var rows: [Row] = []
    private var subscriptions = Set<AnyCancellable>()

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu

        UpdaterManager.shared.$pendingUpdateVersion
            .sink { [weak item] version in
                item?.button?.image = Self.icon(badged: version != nil)
            }
            .store(in: &subscriptions)

        // objectWillChange fires before the new value lands; the main queue
        // runs during menu tracking, so the refresh reaches an open menu too.
        AppState.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshRows() }
            .store(in: &subscriptions)
    }

    /// The menu bar glyph, optionally carrying the dot that says a background
    /// update is waiting. Drawn into a canvas with room for the dot so the
    /// menu bar clips neither it nor the symbol's outer strokes.
    private static func icon(badged: Bool) -> NSImage {
        let symbol = NSImage(systemSymbolName: "rectangle.3.group",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .bold))
            ?? NSImage()
        let dot: CGFloat = 4
        let size = NSSize(width: symbol.size.width + dot,
                          height: symbol.size.height + dot)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(at: NSPoint(x: 0, y: dot / 2),
                        from: .zero, operation: .sourceOver, fraction: 1)
            if badged {
                // Template images keep only alpha, so the fill colour is
                // irrelevant - the menu bar tints it for light and dark.
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - dot,
                                            y: size.height - dot,
                                            width: dot, height: dot)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badged ? "macToolKit, update available" : "macToolKit"
        return image
    }

    // MARK: Building

    /// Rebuilt at every open, so onboarding, update and permission state are
    /// always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let appState = AppState.shared
        let updater = UpdaterManager.shared
        menu.removeAllItems()
        rows.removeAll()

        // Onboarding is skipped at login launches, so this is the way back to
        // it. Nothing is started until it has run, and the toggles are
        // disabled to match: left live they would report a feature as on
        // while it is stopped, and flipping one would fire a permission
        // prompt before the user has seen the welcome flow that explains it.
        let onboarded = appState.hasCompletedOnboarding
        if !onboarded {
            menu.addItem(button("Finish Setup…", #selector(finishSetup)))
            menu.addItem(.separator())
        }

        for (index, section) in Self.sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: section.title))
            for feature in section.features {
                menu.addItem(toggleItem(feature, enabled: onboarded))
            }
        }

        menu.addItem(.separator())

        // A background check found this one; the menu is where the badge on
        // the menu bar icon leads. Clicking it opens Sparkle's update alert.
        if let version = updater.pendingUpdateVersion {
            menu.addItem(button("Update to \(version)…", #selector(checkForUpdates)))
        }
        let check = button("Check for Updates…", #selector(checkForUpdates))
        check.isEnabled = updater.canCheckForUpdates
        menu.addItem(check)

        menu.addItem(.separator())
        menu.addItem(button("Settings…", #selector(openSettings), key: ","))
        menu.addItem(button("Quit macToolKit", #selector(quit), key: "q"))
    }

    private func button(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        // macOS 27 picks a symbol for some well-known titles (a gear for
        // Settings…); one lone icon would push its title out of line.
        if #available(macOS 27, *) { item.preferredImageVisibility = .hidden }
        return item
    }

    private func toggleItem(_ feature: Feature, enabled: Bool) -> NSMenuItem {
        let isOn = feature.isOn
        let item = FeatureMenuItem(title: feature.title, action: #selector(toggleFeature(_:)),
                                   keyEquivalent: "")
        item.target = self
        item.representedObject = isOn
        item.isEnabled = enabled
        item.state = AppState.shared[keyPath: isOn] ? .on : .off
        let view = MenuToggleRowView(title: feature.title,
                                     isOn: AppState.shared[keyPath: isOn]) { [weak self] newValue in
            AppState.shared[keyPath: isOn] = newValue
            // A feature may refuse (a permission it needs is missing) and
            // turn itself back off; show what actually happened.
            self?.refreshRows()
        }
        item.view = view
        rows.append(Row(item: item, view: view, isOn: isOn))
        return item
    }

    private func refreshRows() {
        for row in rows {
            let isOn = AppState.shared[keyPath: row.isOn]
            row.item.state = isOn ? .on : .off
            row.view.isOn = isOn
        }
    }

    // MARK: Highlighting

    /// Hands the keyboard to the row the menu highlights. The menu moves the
    /// highlight itself (arrow keys, type-select, the pointer), but passes
    /// Return, Enter and Space on a view-backed item to the first responder
    /// of its window, and the row turns those into a flip.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let event = NSApp.currentEvent?.type
        // The menu drops the highlight of a view item it was clicked in; the
        // row keeps showing it, and keeps the keyboard, until the highlight
        // goes somewhere else.
        guard ![.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(event)
        else { return }
        for row in rows { row.view.holdsHighlight = false }
        let view = rows.first { $0.item === item }?.view
        rows.first?.view.window?.makeFirstResponder(view)
    }

    // MARK: Actions

    @objc private func toggleFeature(_ sender: NSMenuItem) {
        guard let isOn = sender.representedObject as? ReferenceWritableKeyPath<AppState, Bool>
        else { return }
        AppState.shared[keyPath: isOn].toggle()
    }

    @objc private func finishSetup() { OnboardingWindowController.shared.show() }
    @objc private func checkForUpdates() { UpdaterManager.shared.checkForUpdates() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// A feature row's item. Pressed through accessibility - a script's `click
/// menu item`, VoiceOver - a view-backed item only closes the menu; this one
/// chooses itself first, as a plain item would.
private final class FeatureMenuItem: NSMenuItem {
    // NSMenuItem is not main-actor isolated, but accessibility calls in on
    // the main thread only.
    override func accessibilityPerformPress() -> Bool {
        nonisolated(unsafe) let item = self
        return MainActor.assumeIsolated {
            guard item.isEnabled, let action = item.action else { return false }
            NSApp.sendAction(action, to: item.target, from: item)
            item.menu?.cancelTracking()
            return true
        }
    }
}

/// A feature row: drawn exactly like a checkmark menu item, but a click lands
/// in the view, so the menu stays open.
final class MenuToggleRowView: NSView {
    // Measured against plain items of the same menu (macOS 27): titles,
    // checkmarks and the selection match them pixel for pixel.
    fileprivate enum Metrics {
        static let height: CGFloat = 24
        static let checkX: CGFloat = 12
        static let titleX: CGFloat = 29
        static let trailing: CGFloat = 14
        static let selectionInset: CGFloat = 5
        static let selectionRadius: CGFloat = 7
        static var font: NSFont { .menuFont(ofSize: 0) }
    }

    private let onChange: (Bool) -> Void
    /// The system's own selection fill: accent coloured, and kept active
    /// although an accessory app's menu belongs to an inactive app.
    private let selection = NSVisualEffectView()
    /// Title and checkmark, above the selection.
    private let content: MenuToggleRowContent

    var isOn: Bool {
        get { content.isOn }
        set {
            guard newValue != content.isOn else { return }
            content.isOn = newValue
            setAccessibilityValue(newValue)
        }
    }

    /// Set after a click toggled the row; see the menu delegate.
    var holdsHighlight = false {
        didSet { if holdsHighlight != oldValue { needsDisplay = true } }
    }

    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        content = MenuToggleRowContent(title: title, isOn: isOn)
        self.onChange = onChange
        // The menu sizes itself to the widest item, reading a view's width as
        // what its item needs, then widens every view to the menu's width.
        let titleWidth = (title as NSString).size(withAttributes: [.font: Metrics.font]).width
        let width = (Metrics.titleX + titleWidth + Metrics.trailing).rounded(.up)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.height))
        autoresizingMask = .width

        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.wantsLayer = true
        selection.layer?.cornerRadius = Metrics.selectionRadius
        selection.isHidden = true
        selection.frame = bounds.insetBy(dx: Metrics.selectionInset, dy: 0)
        selection.autoresizingMask = .width
        addSubview(selection)

        content.frame = bounds
        content.autoresizingMask = .width
        addSubview(content)

        // A view-backed item reports no checkmark, so the row is the
        // accessible control: "Rewritely, checkbox, checked".
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        guard enclosingMenuItem?.isEnabled ?? false else { return false }
        toggle()
        return true
    }

    override func isAccessibilityEnabled() -> Bool {
        enclosingMenuItem?.isEnabled ?? true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The menu marks a view-backed item highlighted as the pointer or the
    // arrow keys reach it, and redraws the view; the look is the view's job.
    override func viewWillDraw() {
        let enabled = enclosingMenuItem?.isEnabled ?? true
        selection.isHidden = !showsHighlight
        content.color = !enabled ? .disabledControlTextColor
            : showsHighlight ? .selectedMenuItemTextColor : .labelColor
        super.viewWillDraw()
    }

    /// Whether the row looks selected - the one the keyboard acts on.
    private var showsHighlight: Bool {
        (enclosingMenuItem?.isEnabled ?? true)
            && (holdsHighlight || enclosingMenuItem?.isHighlighted == true)
    }

    override var acceptsFirstResponder: Bool { true }

    // Return, Enter and Space choose a plain item, which flips it and closes
    // the menu; the row does the same. Anything else goes back to the menu.
    override func keyDown(with event: NSEvent) {
        let chooses = event.specialKey == .carriageReturn || event.specialKey == .enter
            || event.charactersIgnoringModifiers == " "
        guard chooses, showsHighlight else {
            super.keyDown(with: event)
            return
        }
        toggle()
        enclosingMenuItem?.menu?.cancelTracking()
    }

    // Acts on release like any menu item; the press may have started on the
    // menu bar icon (press, drag down, release).
    override func mouseUp(with event: NSEvent) {
        guard enclosingMenuItem?.isEnabled ?? false,
              bounds.contains(convert(event.locationInWindow, from: nil))
        else { return }
        holdsHighlight = true
        toggle()
    }

    // A plain menu item takes a right-click release like a left one.
    override func rightMouseUp(with event: NSEvent) {
        mouseUp(with: event)
    }

    private func toggle() {
        isOn.toggle()
        onChange(isOn)
    }
}

private final class MenuToggleRowContent: NSView {
    private typealias Metrics = MenuToggleRowView.Metrics
    private let title: String

    var isOn: Bool { didSet { if isOn != oldValue { needsDisplay = true } } }
    var color: NSColor = .labelColor { didSet { if color != oldValue { needsDisplay = true } } }

    init(title: String, isOn: Bool) {
        self.title = title
        self.isOn = isOn
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // Clicks belong to the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Metrics.font,
                                                         .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: Metrics.titleX,
                                             y: ((bounds.height - size.height) / 2).rounded()),
                                 withAttributes: attributes)

        // The glyph NSMenu draws for an "on" state. A palette colour with
        // alpha comes out applied twice, so the glyph is opaque and the alpha
        // goes in as the draw fraction.
        let resolved = color.usingColorSpace(.sRGB) ?? color
        guard isOn,
              let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Metrics.font.pointSize, weight: .bold,
                                               scale: .small)
                    .applying(.init(paletteColors: [resolved.withAlphaComponent(1)])))
        else { return }
        check.draw(in: NSRect(x: Metrics.checkX,
                              y: ((bounds.height - check.size.height) / 2).rounded(),
                              width: check.size.width, height: check.size.height),
                   from: .zero, operation: .sourceOver, fraction: resolved.alphaComponent,
                   respectFlipped: true, hints: nil)
    }
}
