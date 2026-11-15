import Foundation

/// Parameters for a film look, applied on top of the neutral RAW decode.
/// See NOTES/film-look.md for what each stage emulates.
struct FilmLook: Codable, Equatable {
    /// 0 = neutral render, 1 = the full look.
    var strength: Float = 1

    // Colour — applied to scene-linear light, before the tone curve.

    /// Row-major 3×3 channel mix: dye-layer crosstalk and the stock's palette.
    var colorMatrix: [Float] = [1, 0, 0,
                                0, 1, 0,
                                0, 0, 1]
    /// Negative = cooler, positive = warmer.
    var warmth: Float = 0

    // Tone — a per-channel sigmoid in log exposure (the characteristic curve).

    /// Mid-tone slope; 1 is roughly a standard print.
    var contrast: Float = 1
    /// 0 = highlights compress like shadows; 1 = long, gentle shoulder.
    var rolloff: Float = 0.5
    /// Lifts blacks and lowers whites, like a faded print.
    var fade: Float = 0

    // Print / scan character — applied after the tone curve, in display space.

    var saturation: Float = 1
    /// RGB offsets added to shadows and highlights (split toning).
    var shadowTint: [Float] = [0, 0, 0]
    var highlightTint: [Float] = [0, 0, 0]
}
