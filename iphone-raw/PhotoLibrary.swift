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
            RawRenderer.removeCachedThumbnails(for: url)
        }
        refresh()
    }

    // Captures are named RAW_yyyyMMdd_HHmmss_SSS.dng; older ones have no
    // milliseconds. Both sort by name in capture order.
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
    private static let nameFormat = formatter("'RAW_'yyyyMMdd_HHmmss_SSS")
    private static let secondsNameFormat = formatter("'RAW_'yyyyMMdd_HHmmss")

    /// A Documents URL for a new capture that no existing file uses.
    static func newCaptureURL(at date: Date = Date()) -> URL {
        let base = nameFormat.string(from: date)
        var url = URL.documentsDirectory.appending(path: "\(base).dng")
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = URL.documentsDirectory.appending(path: "\(base)_\(copy).dng")
            copy += 1
        }
        return url
    }

    /// Capture time, from the file name.
    static func captureDate(of url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        // "RAW_yyyyMMdd_HHmmss" is 19 characters, plus "_SSS" in newer names.
        return nameFormat.date(from: String(name.prefix(23))) ?? secondsNameFormat.date(from: String(name.prefix(19)))
    }
}
