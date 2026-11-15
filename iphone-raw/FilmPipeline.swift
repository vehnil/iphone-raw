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
    private static let lightKernel = library.flatMap { try? CIColorKernel(functionName: "addLight", fromMetalLibraryData: $0) }
    private static let haloKernel = library.flatMap { try? CIColorKernel(functionName: "addHalo", fromMetalLibraryData: $0) }

    // Glow shape: luminance threshold, blur radius (fraction of the long edge), and gain at slider 1.
    enum HalationTuning { static let threshold: CGFloat = 0.7, radius: CGFloat = 0.006, strength: Float = 1.2 }
    enum BloomTuning { static let threshold: CGFloat = 0.45, radius: CGFloat = 0.03, strength: Float = 0.5 }

    /// Long edge, in pixels, that effect sizes are tuned for (full-resolution capture).
    private static let referenceLongEdge: CGFloat = 4000
    private static let luma = (r: CGFloat(0.2126), g: CGFloat(0.7152), b: CGFloat(0.0722))

    /// `seed` keeps the grain pattern stable for a given photo.
    static func apply(_ look: FilmLook, to neutral: CIImage, seed: UInt64 = 0) -> CIImage {
        guard look.strength > 0 else { return neutral }
        let extent = neutral.extent
        let longEdge = max(extent.width, extent.height)

        var image = color(look, neutral)
        if look.vignette > 0 {
            image = vignette(image, amount: look.vignette)
        }
        if look.halation > 0 {
            // Light scattered back from the film base re-exposes mostly the red
            // layer: a tight red-orange halo around the brightest highlights.
            image = addGlow(to: image, threshold: HalationTuning.threshold, radius: HalationTuning.radius * longEdge,
                            tint: (1, 0.3, 0.08), strength: HalationTuning.strength * look.halation, haloOnly: true)
        }
        if look.bloom > 0 {
            // Light scattered in the lens and emulsion: a wide, soft, neutral glow.
            image = addGlow(to: image, threshold: BloomTuning.threshold, radius: BloomTuning.radius * longEdge,
                            tint: (1, 1, 1), strength: BloomTuning.strength * look.bloom, haloOnly: false)
        }
        image = tone(look, image)
        if look.grain > 0 {
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

    /// Takes the light whose luminance is over `threshold`, tints and blurs it,
    /// and adds it back. The excess is scaled so a clipped highlight (1.0, as
    /// a RAW decode delivers blown areas) counts fully, however high the threshold.
    /// `haloOnly` adds just the light spread past the highlights' edges.
    private static func addGlow(to image: CIImage, threshold: CGFloat, radius: CGFloat,
                                tint: (r: CGFloat, g: CGFloat, b: CGFloat), strength: Float, haloOnly: Bool) -> CIImage {
        guard let lightKernel, let haloKernel else { return image }
        let extent = image.extent

        // tint × k × (luminance − threshold), with k = strength / (1 − threshold).
        // Alpha stays 1: Core Image filters premultiply their output, so alpha 0 would zero the glow.
        let k = CGFloat(strength) / (1 - threshold)
        func row(_ t: CGFloat) -> CIVector { CIVector(x: luma.r * t * k, y: luma.g * t * k, z: luma.b * t * k, w: 0) }
        let over = CIFilter.colorMatrix()
        over.inputImage = image
        over.rVector = row(tint.r)
        over.gVector = row(tint.g)
        over.bVector = row(tint.b)
        over.biasVector = CIVector(x: -tint.r * k * threshold, y: -tint.g * k * threshold, z: -tint.b * k * threshold, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = over.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 64, y: 64, z: 64, w: 1)

        guard let source = clamp.outputImage else { return image }
        let glow = source
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: extent)

        if haloOnly {
            return haloKernel.apply(extent: extent, arguments: [image, glow, source]) ?? image
        }
        return lightKernel.apply(extent: extent, arguments: [image, glow]) ?? image
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
