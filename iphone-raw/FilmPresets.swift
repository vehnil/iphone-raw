import Foundation

extension FilmLook {
    struct Preset: Identifiable {
        let id: String
        let name: String
        let look: FilmLook
    }

    // Colour matrix rows each sum to 1 so neutral greys stay neutral.
    static let presets: [Preset] = [
        Preset(id: "warm-negative", name: "Warm Negative", look: FilmLook(
            colorMatrix: [0.92, 0.06, 0.02,
                          0.04, 0.92, 0.04,
                          0.02, 0.08, 0.90],
            warmth: 0.35,
            contrast: 0.85,
            rolloff: 0.85,
            fade: 0.02,
            saturation: 0.95,
            shadowTint: [0, 0.005, 0.01],
            highlightTint: [0.02, 0.01, -0.01]
        )),
        Preset(id: "vivid-slide", name: "Vivid Slide", look: FilmLook(
            colorMatrix: [1.06, -0.03, -0.03,
                          -0.03, 1.06, -0.03,
                          -0.02, -0.04, 1.06],
            contrast: 1.2,
            rolloff: 0.25,
            saturation: 1.1,
            shadowTint: [0, 0, 0.01]
        )),
        Preset(id: "tungsten-800", name: "Tungsten 800", look: FilmLook(
            colorMatrix: [0.95, 0.04, 0.01,
                          0.03, 0.94, 0.03,
                          0.01, 0.05, 0.94],
            warmth: -0.45,
            contrast: 1.0,
            rolloff: 0.6,
            fade: 0.01,
            saturation: 0.95,
            shadowTint: [-0.015, 0.01, 0.03],
            highlightTint: [0.02, 0, -0.01]
        )),
        Preset(id: "faded-print", name: "Faded Print", look: FilmLook(
            colorMatrix: [0.90, 0.07, 0.03,
                          0.05, 0.90, 0.05,
                          0.03, 0.07, 0.90],
            warmth: 0.15,
            contrast: 0.75,
            rolloff: 0.7,
            fade: 0.08,
            saturation: 0.75,
            shadowTint: [0, 0.01, 0.015],
            highlightTint: [0.03, 0.015, -0.01]
        )),
    ]
}
