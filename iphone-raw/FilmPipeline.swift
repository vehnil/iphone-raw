import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies a `FilmLook` to a neutral, scene-linear RAW decode.
///
/// Order follows the physical process: colour and optics (vignette, halation,
/// bloom) act on light before it reaches the film, so they run in linear light
/// before the tone curve; grain belongs to the emulsion, so it comes last.
enum FilmPipeline {
    /// Compiled Core Image kernels; overridable so the pipeline can run outside the app bundle.
    static var libraryURL = Bundle.main.url(forResource: "default", withExtension: "metallib")

    private static let library: Data? = libraryURL.flatMap { try? Data(contentsOf: $0) }
    private static let toneKernel = library.flatMap { try? CIColorKernel(functionName: "filmTone", fromMetalLibraryData: $0) }
    private static let grainKernel = library.flatMap { try? CIColorKernel(functionName: "filmGrain", fromMetalLibraryData: $0) }
    private static let sourceKernel = library.flatMap { try? CIColorKernel(functionName: "scatterSource", fromMetalLibraryData: $0) }
    private static let haloKernel = library.flatMap { try? CIColorKernel(functionName: "addHalo", fromMetalLibraryData: $0) }

    // Glow shape: blur radius (fraction of the long edge), the share of each
    // pixel's light that scatters at slider 1, and how many times over fully
    // clipped light counts. There's no threshold: scattered light is a small
    // share of everything, so it only shows where something is far brighter
    // than its surroundings (lights, glints, a window), as on film. A threshold
    // can't tell those apart in a RAW decode, where a white wall and a lamp
    // both sit near 1.0; only the lamp clips in every channel.
    enum HalationTuning { static let radius: CGFloat = 0.006, amount: Float = 0.12, clipGain: Float = 4 }
    enum BloomTuning { static let radius: CGFloat = 0.03, amount: Float = 0.1, clipGain: Float = 4 }

    /// Long edge, in pixels, that effect sizes are tuned for (full-resolution capture).
    private static let referenceLongEdge: CGFloat = 4000

    /// The pipeline's steps, so the Lab can switch each off to see what it does.
    struct Stages: OptionSet, Codable, Hashable {
        let rawValue: Int
        static let color = Stages(rawValue: 1 << 0)
        static let vignette = Stages(rawValue: 1 << 1)
        static let halation = Stages(rawValue: 1 << 2)
        static let bloom = Stages(rawValue: 1 << 3)
        static let tone = Stages(rawValue: 1 << 4)
        static let grain = Stages(rawValue: 1 << 5)
        static let all: Stages = [.color, .vignette, .halation, .bloom, .tone, .grain]

        /// In pipeline order, with names for the UI.
        static let named: [(stage: Stages, name: String)] = [
            (.color, "Colour"), (.vignette, "Vignette"), (.halation, "Halation"),
            (.bloom, "Bloom"), (.tone, "Tone"), (.grain, "Grain"),
        ]
    }

    /// `seed` keeps the grain pattern stable for a given photo.
    static func apply(_ look: FilmLook, to neutral: CIImage, seed: UInt64 = 0, stages: Stages = .all) -> CIImage {
        guard look.strength > 0 else { return neutral }
        let extent = neutral.extent
        let longEdge = max(extent.width, extent.height)

        var image = stages.contains(.color) ? color(look, neutral) : neutral
        if look.vignette > 0, stages.contains(.vignette) {
            image = vignette(image, amount: look.vignette)
        }
        if look.halation > 0, stages.contains(.halation) {
            // Light scattered back from the film base re-exposes mostly the red
            // layer: a tight red-orange halo around the brightest highlights.
            image = addGlow(to: image, radius: HalationTuning.radius * longEdge, tint: (1, 0.3, 0.08),
                            amount: HalationTuning.amount * look.halation, clipGain: HalationTuning.clipGain)
        }
        if look.bloom > 0, stages.contains(.bloom) {
            // Light scattered in the lens and emulsion: a wide, soft, neutral glow.
            image = addGlow(to: image, radius: BloomTuning.radius * longEdge, tint: (1, 1, 1),
                            amount: BloomTuning.amount * look.bloom, clipGain: BloomTuning.clipGain)
        }
        if stages.contains(.tone) {
            image = tone(look, image)
        }
        if look.grain > 0, stages.contains(.grain) {
            image = grain(image, amount: look.grain, size: look.grainSize, seed: seed)
        }

        guard look.strength < 1 else { return image }
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = neutral
        blend.targetImage = image
        blend.time = look.strength
        return blend.outputImage ?? image
    }

    /// Channel mix and warmth, in linear light.
    private static func color(_ look: FilmLook, _ image: CIImage) -> CIImage {
        let m = look.colorMatrix
        // Warmth scales red up and blue down (or the reverse) after the mix.
        let r = 1 + 0.3 * look.warmth
        let b = 1 - 0.3 * look.warmth

        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: CGFloat(m[0] * r), y: CGFloat(m[1] * r), z: CGFloat(m[2] * r), w: 0)
        filter.gVector = CIVector(x: CGFloat(m[3]), y: CGFloat(m[4]), z: CGFloat(m[5]), w: 0)
        filter.bVector = CIVector(x: CGFloat(m[6] * b), y: CGFloat(m[7] * b), z: CGFloat(m[8] * b), w: 0)
        return filter.outputImage ?? image
    }

    private static func vignette(_ image: CIImage, amount: Float) -> CIImage {
        let extent = image.extent
        let filter = CIFilter.vignetteEffect()
        filter.inputImage = image
        filter.center = CGPoint(x: extent.midX, y: extent.midY)
        filter.radius = Float(max(extent.width, extent.height) * 0.45)
        filter.intensity = amount
        filter.falloff = 0.6
        return filter.outputImage ?? image
    }

    /// Scatters `amount` of each pixel's light, tinted, over `radius`, and adds
    /// what spreads past where it came from.
    private static func addGlow(to image: CIImage, radius: CGFloat, tint: (r: CGFloat, g: CGFloat, b: CGFloat),
                                amount: Float, clipGain: Float) -> CIImage {
        guard let sourceKernel, let haloKernel else { return image }
        let extent = image.extent
        // Alpha stays 1: Core Image filters premultiply their output, so alpha 0 would zero the glow.
        guard let source = sourceKernel.apply(extent: extent, arguments: [image, CIVector(x: tint.r, y: tint.g, z: tint.b),
                                                                          amount, clipGain]) else { return image }
        let glow = source
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: extent)
        return haloKernel.apply(extent: extent, arguments: [image, glow, source]) ?? image
    }

    private static func tone(_ look: FilmLook, _ image: CIImage) -> CIImage {
        guard let toneKernel else { return image }
        let arguments: [Any] = [
            image,
            look.contrast,
            look.rolloff,
            look.fade,
            look.saturation,
            vector(look.shadowTint),
            vector(look.highlightTint),
        ]
        return toneKernel.apply(extent: image.extent, arguments: arguments) ?? image
    }

    private static func grain(_ image: CIImage, amount: Float, size: Float, seed: UInt64) -> CIImage {
        guard let grainKernel else { return image }
        let extent = image.extent
        // Grain cell size in this render's pixels; frame-relative so it matches across resolutions.
        let cell = CGFloat(size) * 1.5 * max(extent.width, extent.height) / referenceLongEdge

        let fine = noise(cell: cell, seed: seed, channel: 0)
        let coarse = noise(cell: cell * 2.5, seed: seed &+ 7919, channel: 1)

        // Grain finer than a pixel averages out, so it shrinks in small renders.
        let visible = amount * 0.28 * fine.amplitude
        return grainKernel.apply(extent: extent, arguments: [image, fine.image, coarse.image, visible]) ?? image
    }

    /// Zero-centred noise in .r, taken from one channel of the random generator
    /// so the fine and coarse layers are independent, with clumps about `cell` pixels across.
    private static func noise(cell: CGFloat, seed: UInt64, channel: Int) -> (image: CIImage, amplitude: Float) {
        let offset = CGAffineTransform(translationX: -CGFloat(seed % 4096), y: -CGFloat((seed / 4096) % 4096))
        // The generator randomises alpha too; make it opaque before any filter unpremultiplies it.
        var random = CIFilter.randomGenerator().outputImage!.settingAlphaOne(in: .infinite).transformed(by: offset)
        if cell > 1 {
            random = random
                .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
                .applyingGaussianBlur(sigma: Double(cell * 0.4))
        }

        let pick = CIFilter.colorMatrix()
        pick.inputImage = random
        let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
        pick.rVector = CIVector(x: channel == 0 ? 1 : 0, y: channel == 1 ? 1 : 0, z: 0, w: 0)
        pick.gVector = zero
        pick.bVector = zero
        // Opaque: Core Image premultiplies filter output, so alpha 0 would zero the noise.
        pick.aVector = zero
        pick.biasVector = CIVector(x: -0.5, y: 0, z: 0, w: 1)
        return (pick.outputImage!, Float(min(cell, 1)))
    }

    private static func vector(_ values: [Float]) -> CIVector {
        CIVector(x: CGFloat(values[0]), y: CGFloat(values[1]), z: CGFloat(values[2]))
    }
}
