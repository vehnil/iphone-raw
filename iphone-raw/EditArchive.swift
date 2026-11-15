import Foundation

/// Saved develop settings per photo (keyed by file name), plus the last film
/// look used so new captures can start with it. Lives in Application Support,
/// which isn't exposed in the Files app.
struct EditArchive: Codable {
    var photos: [String: DevelopSettings] = [:]
    var lastFilm: FilmLook?
    var lastFilmPresetID: String?

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

    /// Gives a new capture the last film look used, if any.
    static func startNewPhoto(named name: String) {
        var archive = load()
        guard let film = archive.lastFilm else { return }
        archive.photos[name] = DevelopSettings(film: film, filmPresetID: archive.lastFilmPresetID)
        archive.save()
    }
}
