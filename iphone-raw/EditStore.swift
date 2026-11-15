import SwiftUI

/// Development settings for each photo.
@MainActor
final class EditStore: ObservableObject {
    @Published private var edits: [URL: DevelopSettings] = [:]
    private var asShot: [URL: DevelopSettings] = [:]

    func settings(for url: URL) -> DevelopSettings {
        edits[url] ?? DevelopSettings()
    }

    func binding(for url: URL) -> Binding<DevelopSettings> {
        Binding(get: { self.settings(for: url) }, set: { self.edits[url] = $0 })
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
            edits[url] = current
        }
        return loaded
    }
}
