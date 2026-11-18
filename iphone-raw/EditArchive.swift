import Foundation

/// Saved develop settings per photo, keyed by file name, in `edits.json`. Lives
/// in Application Support, which isn't exposed in the Files app; the DNGs are
/// never modified.
///
/// The one owner of the file: it's read once, kept in memory, and every change
/// (the editor, a new capture's crop) goes through `shared`, so no writer can
/// overwrite another's changes. Nothing that was saved is dropped on the way
/// back out: an entry that doesn't decode is written back untouched, and a
/// file that isn't readable at all is moved aside rather than replaced.
final class EditArchive: @unchecked Sendable {
    static let shared = EditArchive(url: URL.applicationSupportDirectory.appending(path: "edits.json"))

    private let url: URL
    private let lock = NSLock()
    private var photos: [String: DevelopSettings] = [:]
    /// Entries that didn't decode (say, from a newer version of the app), as raw JSON.
    private var unreadable: [String: Any] = [:]
    private var saveScheduled = false
    private let saveQueue = DispatchQueue(label: "iphoneraw.edits", qos: .utility)

    init(url: URL) {
        self.url = url
        load()
    }

    func settings(for name: String) -> DevelopSettings? {
        lock.withLock { photos[name] }
    }

    /// `nil` removes the photo's entry.
    func set(_ settings: DevelopSettings?, for name: String) {
        lock.withLock {
            photos[name] = settings
            unreadable[name] = nil
        }
        scheduleSave()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["photos"] as? [String: Any] else {
            setAside()
            return
        }
        for (name, entry) in entries {
            if let json = try? JSONSerialization.data(withJSONObject: entry),
               let settings = try? JSONDecoder().decode(DevelopSettings.self, from: json) {
                photos[name] = settings
            } else {
                unreadable[name] = entry
            }
        }
    }

    /// Keeps a file that couldn't be read, so starting afresh doesn't destroy it.
    private func setAside() {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let destination = url.deletingLastPathComponent().appending(path: "edits-unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    /// Coalesces bursts of changes (slider drags) into one write.
    private func scheduleSave() {
        let shouldSchedule = lock.withLock {
            defer { saveScheduled = true }
            return !saveScheduled
        }
        guard shouldSchedule else { return }
        saveQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
            let (photos, unreadable) = lock.withLock {
                saveScheduled = false
                return (self.photos, self.unreadable)
            }
            write(photos, unreadable)
        }
    }

    private func write(_ photos: [String: DevelopSettings], _ unreadable: [String: Any]) {
        var entries = unreadable
        for (name, settings) in photos {
            if let json = try? JSONEncoder().encode(settings),
               let entry = try? JSONSerialization.jsonObject(with: json) {
                entries[name] = entry
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["photos": entries], options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
