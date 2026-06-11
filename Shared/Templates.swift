import Foundation

/// A quick-create file template shown in the Finder "New File" context menu.
struct FileTemplate: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var ext: String
    var content: String

    init(id: UUID = UUID(), name: String, ext: String, content: String = "") {
        self.id = id
        self.name = name
        self.ext = ext
        self.content = content
    }

    var menuTitle: String { "\(name) (.\(ext))" }
}

enum SharedDefaults {
    static let appGroupID = "5432YAY2UX.com.sunilaleti.mactoolkit"
    static let pinnedTemplatesKey = "pinnedTemplates"
    static let starterTemplatesSeededKey = "starterTemplatesSeeded"

    static var suite: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// Starter presets seeded into the editable template list on first load.
    /// Stable IDs so the extension and main app resolve the same template
    /// across processes.
    static let starterTemplates: [FileTemplate] = [
        FileTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                     name: "Text Document", ext: "txt"),
        FileTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                     name: "Python Script", ext: "py",
                     content: "#!/usr/bin/env python3\n\n"),
        FileTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                     name: "Markdown", ext: "md"),
        FileTemplate(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                     name: "JavaScript", ext: "js"),
    ]

    /// All templates, every one of them user-editable. Migrates the starter
    /// presets into stored templates the first time either process loads them.
    static func loadTemplates() -> [FileTemplate] {
        var templates: [FileTemplate] = []
        if let data = suite.data(forKey: pinnedTemplatesKey),
           let stored = try? JSONDecoder().decode([FileTemplate].self, from: data) {
            templates = stored
        }
        if !suite.bool(forKey: starterTemplatesSeededKey) {
            templates = starterTemplates + templates.filter { pinned in
                !starterTemplates.contains { $0.id == pinned.id }
            }
            saveTemplates(templates)
            suite.set(true, forKey: starterTemplatesSeededKey)
        }
        return templates
    }

    static func saveTemplates(_ templates: [FileTemplate]) {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        suite.set(data, forKey: pinnedTemplatesKey)
    }

    static func template(withID id: UUID) -> FileTemplate? {
        loadTemplates().first { $0.id == id }
    }
}

/// URLs used by the FinderSync extension to reach the main app.
enum AppURL {
    static let scheme = "mactoolkit"

    static func newFile(in directory: URL, templateID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "newfile"
        components.queryItems = [
            URLQueryItem(name: "dir", value: directory.path),
            URLQueryItem(name: "id", value: templateID.uuidString),
        ]
        return components.url
    }

    static var configureTemplates: URL? {
        URL(string: "\(scheme)://settings/finder")
    }
}
