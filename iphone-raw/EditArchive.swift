import Foundation

/// Saved develop settings per photo, keyed by file name. Lives in Application
/// Support, which isn't exposed in the Files app; the DNGs are never modified.
struct EditArchive: Codable {
    var photos: [String: DevelopSettings] = [:]

    private static let url = URL.applicationSupportDirectory.appending(path: "edits.json")

    static func load() -> EditArchive {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(EditArchive.self, from: data) else { return EditArchive() }
        return archive
    }

    func save() {
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}
