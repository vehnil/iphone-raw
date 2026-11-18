import Observation
import SwiftUI

/// Development settings for each photo, for the gallery's views. A view model
/// over `EditArchive.shared`, which holds and saves the settings.
///
/// Observed per photo: a view redraws only when the settings of photos it
/// reads change, so dragging a slider redraws the photo being edited and
/// nothing else.
@MainActor
@Observable
final class EditStore {
    @ObservationIgnored private let archive = EditArchive.shared
    /// Made on first use. Not observed itself; each entry is.
    @ObservationIgnored private var entries: [String: PhotoEntry] = [:]
    @ObservationIgnored private var asShot: [URL: DevelopSettings] = [:]

    func settings(for url: URL) -> DevelopSettings {
        entry(for: url).settings
    }

    func binding(for url: URL) -> Binding<DevelopSettings> {
        Binding(get: { self.settings(for: url) }, set: { self.update(url, $0) })
    }

    func forget(_ urls: some Collection<URL>) {
        for url in urls {
            entry(for: url).settings = DevelopSettings()
            archive.set(nil, for: url.lastPathComponent)
        }
    }

    /// The camera's white balance with neutral settings. Also fills in the
    /// photo's white balance so the sliders start from real values.
    func asShotSettings(for url: URL) async -> DevelopSettings? {
        if let cached = asShot[url] { return cached }
        guard let loaded = await RawRenderer.asShotSettings(for: url) else { return nil }
        asShot[url] = loaded

        var current = settings(for: url)
        if current.temperature == nil || current.tint == nil {
            current.temperature = current.temperature ?? loaded.temperature
            current.tint = current.tint ?? loaded.tint
            update(url, current)
        }
        return loaded
    }

    private func update(_ url: URL, _ settings: DevelopSettings) {
        entry(for: url).settings = settings
        archive.set(settings, for: url.lastPathComponent)
    }

    private func entry(for url: URL) -> PhotoEntry {
        let name = url.lastPathComponent
        if let entry = entries[name] { return entry }
        let entry = PhotoEntry(settings: archive.settings(for: name) ?? DevelopSettings())
        entries[name] = entry
        return entry
    }
}

/// One photo's settings, observed on its own.
@Observable
private final class PhotoEntry {
    var settings: DevelopSettings

    init(settings: DevelopSettings) {
        self.settings = settings
    }
}
