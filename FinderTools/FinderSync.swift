import AppKit
import FinderSync

/// Finder context-menu items: "New File ▸" quick-create plus "Copy Path".
/// The extension is sandboxed, so file creation is delegated to the main app
/// through the mactoolkit:// URL scheme (which also launches it on demand).
class FinderSync: FIFinderSync {
    /// Menu item tags map into this array, rebuilt on every menu request.
    /// representedObject does not survive the trip through Finder.
    private var menuTemplates: [FileTemplate] = []

    override init() {
        super.init()
        // Observe everything so the menu appears in every folder.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer
            || menuKind == .contextualMenuForItems
        else { return nil }

        let menu = NSMenu(title: "")

        let newFileItem = NSMenuItem(title: "New File", action: nil, keyEquivalent: "")
        newFileItem.submenu = buildNewFileSubmenu()
        menu.addItem(newFileItem)

        if menuKind == .contextualMenuForItems {
            menu.addItem(NSMenuItem(title: "Copy Path",
                                    action: #selector(copyPath(_:)),
                                    keyEquivalent: ""))
        }
        return menu
    }

    private func buildNewFileSubmenu() -> NSMenu {
        menuTemplates = SharedDefaults.loadTemplates()

        let submenu = NSMenu(title: "New File")
        for (index, template) in menuTemplates.enumerated() {
            let item = NSMenuItem(title: template.menuTitle,
                                  action: #selector(newFile(_:)),
                                  keyEquivalent: "")
            item.tag = index
            submenu.addItem(item)
        }
        // Finder rebuilds extension menus and renders real separator items as
        // an empty row, so fake the divider with a disabled line of dashes.
        let divider = NSMenuItem(title: "──────────────", action: nil, keyEquivalent: "")
        divider.isEnabled = false
        submenu.addItem(divider)
        submenu.addItem(NSMenuItem(title: "Configure Templates…",
                                   action: #selector(configureTemplates(_:)),
                                   keyEquivalent: ""))
        return submenu
    }

    // MARK: Actions

    @objc private func newFile(_ sender: NSMenuItem) {
        guard menuTemplates.indices.contains(sender.tag) else { return }
        let template = menuTemplates[sender.tag]
        guard let directory = targetDirectory(),
              let url = AppURL.newFile(in: directory, templateID: template.id)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        let items = FIFinderSyncController.default().selectedItemURLs() ?? []
        let paths = items.map(\.path)
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func configureTemplates(_ sender: NSMenuItem) {
        guard let url = AppURL.configureTemplates else { return }
        NSWorkspace.shared.open(url)
    }

    /// Right-clicking a single selected folder creates inside it; otherwise
    /// use the folder being shown.
    private func targetDirectory() -> URL? {
        let controller = FIFinderSyncController.default()
        if let selected = controller.selectedItemURLs(), selected.count == 1,
           let url = selected.first,
           (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return url
        }
        return controller.targetedURL()
    }
}
