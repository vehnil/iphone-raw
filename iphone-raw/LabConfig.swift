import Foundation

/// A named develop + film configuration, compared in the Lab and rendered in
/// contact sheets. Lab exports are arrays of these, which the Mac tool reads.
struct LabConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var settings: DevelopSettings
}

extension LabConfig {
    static let neutral = LabConfig(name: "Neutral", settings: DevelopSettings())

    /// The built-in looks, on otherwise neutral settings.
    static var presets: [LabConfig] {
        FilmLook.presets.map { preset in
            var settings = DevelopSettings()
            settings.film = preset.look
            settings.filmPresetID = preset.id
            return LabConfig(name: preset.name, settings: settings)
        }
    }

    /// Prefix of `DevelopSettings.filmPresetID` for looks saved in the Lab.
    static let savedLookPrefix = "lab:"
}
