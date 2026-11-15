import Foundation

/// The DNGs this app has saved to its Documents folder, oldest first.
final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [URL] = []

    func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: .documentsDirectory, includingPropertiesForKeys: nil)) ?? []
        // File names are timestamps, so sorting by name sorts by capture time.
        photos = contents
            .filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Removes the app's copy only; the one in Photos is untouched.
    func delete(_ urls: some Collection<URL>) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        refresh()
    }

    private static let nameFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "'RAW_'yyyyMMdd_HHmmss"
        return formatter
    }()

    /// Capture time, from the file name.
    static func captureDate(of url: URL) -> Date? {
        nameFormat.date(from: url.deletingPathExtension().lastPathComponent)
    }
}
