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

    // Optical and emulsion effects. Sizes are relative to the frame, so a look
    // matches between thumbnail, preview and full-resolution export.

    /// Red-orange glow around highlights.
    var halation: Float = 0
    /// Soft, neutral glow around highlights.
    var bloom: Float = 0
    /// Grain strength; strongest in the mid-tones.
    var grain: Float = 0
    /// 1 ≈ ISO 400 35mm; larger is coarser.
    var grainSize: Float = 1
    /// Darkening towards the corners.
    var vignette: Float = 0
}

extension FilmLook {
    /// Missing keys fall back to defaults, so saved looks survive new parameters being added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilmLook()
        strength = try c.decodeIfPresent(Float.self, forKey: .strength) ?? d.strength
        colorMatrix = try c.decodeIfPresent([Float].self, forKey: .colorMatrix) ?? d.colorMatrix
        warmth = try c.decodeIfPresent(Float.self, forKey: .warmth) ?? d.warmth
        contrast = try c.decodeIfPresent(Float.self, forKey: .contrast) ?? d.contrast
        rolloff = try c.decodeIfPresent(Float.self, forKey: .rolloff) ?? d.rolloff
        fade = try c.decodeIfPresent(Float.self, forKey: .fade) ?? d.fade
        saturation = try c.decodeIfPresent(Float.self, forKey: .saturation) ?? d.saturation
        shadowTint = try c.decodeIfPresent([Float].self, forKey: .shadowTint) ?? d.shadowTint
        highlightTint = try c.decodeIfPresent([Float].self, forKey: .highlightTint) ?? d.highlightTint
        halation = try c.decodeIfPresent(Float.self, forKey: .halation) ?? d.halation
        bloom = try c.decodeIfPresent(Float.self, forKey: .bloom) ?? d.bloom
        grain = try c.decodeIfPresent(Float.self, forKey: .grain) ?? d.grain
        grainSize = try c.decodeIfPresent(Float.self, forKey: .grainSize) ?? d.grainSize
        vignette = try c.decodeIfPresent(Float.self, forKey: .vignette) ?? d.vignette
    }
}
