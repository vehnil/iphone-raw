import SwiftUI

/// Development settings for each photo, persisted in an `EditArchive`.
@MainActor
final class EditStore: ObservableObject {
    @Published private var archive = EditArchive.load()
    private var asShot: [URL: DevelopSettings] = [:]
    private var pendingSave: Task<Void, Never>?
    /// Photos changed here since the last save. Only these are written, so the
    /// store never overwrites entries saved elsewhere (a new capture's crop).
    private var changed: Set<String> = []

    func settings(for url: URL) -> DevelopSettings {
        archive.photos[url.lastPathComponent] ?? DevelopSettings()
    }

    func binding(for url: URL) -> Binding<DevelopSettings> {
        Binding(get: { self.settings(for: url) }, set: { self.update(url, $0) })
    }

    func forget(_ urls: some Collection<URL>) {
        for url in urls {
            archive.photos[url.lastPathComponent] = nil
            changed.insert(url.lastPathComponent)
        }
        scheduleSave()
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
        archive.photos[url.lastPathComponent] = settings
        changed.insert(url.lastPathComponent)
        scheduleSave()
    }

    /// Coalesces slider drags into one write.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [archive, changed] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            EditArchive.update { saved in
                for name in changed { saved.photos[name] = archive.photos[name] }
            }
            self.changed.subtract(changed)
        }
    }
}
