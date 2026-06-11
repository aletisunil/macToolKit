import AppKit

/// Handles mactoolkit:// URLs sent by the FinderSync extension. The extension
/// is sandboxed and cannot write into arbitrary folders, so file creation is
/// delegated to this (non-sandboxed) app. Opening the URL also launches the
/// app if it is not running.
@MainActor
enum FinderBridge {
    static func handle(_ url: URL) {
        guard url.scheme == AppURL.scheme else { return }
        switch url.host() {
        case "newfile":
            handleNewFile(url)
        case "settings":
            let tabName = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            AppState.shared.settingsTab = SettingsTab(rawValue: tabName) ?? .general
            SettingsWindowController.shared.show()
        default:
            break
        }
    }

    private static func handleNewFile(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dirPath = components.queryItems?.first(where: { $0.name == "dir" })?.value,
              let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let templateID = UUID(uuidString: idString),
              let template = SharedDefaults.template(withID: templateID)
        else { return }

        let directory = URL(fileURLWithPath: dirPath, isDirectory: true)
        guard let fileURL = availableURL(in: directory, template: template) else { return }

        do {
            try template.content.write(to: fileURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } catch {
            NSSound.beep()
        }
    }

    /// "Untitled.txt", "Untitled 2.txt", … first name that doesn't exist yet.
    private static func availableURL(in directory: URL, template: FileTemplate) -> URL? {
        let fm = FileManager.default
        for index in 1...1000 {
            let base = index == 1 ? "Untitled" : "Untitled \(index)"
            let candidate = directory.appendingPathComponent(base)
                .appendingPathExtension(template.ext)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
