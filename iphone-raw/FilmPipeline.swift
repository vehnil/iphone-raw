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
            // Light scattered back from the film base re-exposes mostly the red layer.
            image = addGlow(to: image, threshold: 0.9, radius: 0.004 * longEdge,
                            tint: (1, 0.25, 0.05), strength: 0.8 * look.halation)
        }
        if look.bloom > 0 {
            image = addGlow(to: image, threshold: 0.5, radius: 0.02 * longEdge,
                            tint: (1, 1, 1), strength: 0.25 * look.bloom)
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

    /// Takes the light above `threshold`, tints and blurs it, and adds it back.
    private static func addGlow(to image: CIImage, threshold: CGFloat, radius: CGFloat,
                                tint: (r: CGFloat, g: CGFloat, b: CGFloat), strength: Float) -> CIImage {
        let extent = image.extent

        let over = CIFilter.colorMatrix()
        over.inputImage = image
        over.biasVector = CIVector(x: -threshold, y: -threshold, z: -threshold, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = over.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 64, y: 64, z: 64, w: 1)

        // Luminance of the highlights, tinted; alpha 0 so the addition keeps the image's alpha.
        let s = CGFloat(strength)
        let tinted = CIFilter.colorMatrix()
        tinted.inputImage = clamp.outputImage
        tinted.rVector = CIVector(x: luma.r * tint.r * s, y: luma.g * tint.r * s, z: luma.b * tint.r * s, w: 0)
        tinted.gVector = CIVector(x: luma.r * tint.g * s, y: luma.g * tint.g * s, z: luma.b * tint.g * s, w: 0)
        tinted.bVector = CIVector(x: luma.r * tint.b * s, y: luma.g * tint.b * s, z: luma.b * tint.b * s, w: 0)
        tinted.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)

        guard let glow = tinted.outputImage?
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: extent) else { return image }

        let add = CIFilter.additionCompositing()
        add.inputImage = glow
        add.backgroundImage = image
        return add.outputImage ?? image
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
        let add = CIFilter.additionCompositing()
        add.inputImage = fine.image
        add.backgroundImage = coarse.image
        guard let combined = add.outputImage?.cropped(to: extent) else { return image }

        // Grain finer than a pixel averages out, so it shrinks in small renders.
        let visible = amount * 0.28 * fine.amplitude
        return grainKernel.apply(extent: extent, arguments: [image, combined, visible]) ?? image
    }

    /// Zero-centred noise in one channel, with clumps about `cell` pixels across.
    private static func noise(cell: CGFloat, seed: UInt64, channel: Int) -> (image: CIImage, amplitude: Float) {
        let offset = CGAffineTransform(translationX: -CGFloat(seed % 4096), y: -CGFloat((seed / 4096) % 4096))
        var random = CIFilter.randomGenerator().outputImage!.transformed(by: offset)
        if cell > 1 {
            random = random
                .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
                .applyingGaussianBlur(sigma: Double(cell * 0.4))
        }

        let pick = CIFilter.colorMatrix()
        pick.inputImage = random
        let one = CIVector(x: channel == 0 ? 1 : 0, y: channel == 0 ? 0 : 1, z: 0, w: 0)
        pick.rVector = channel == 0 ? one : CIVector(x: 0, y: 0, z: 0, w: 0)
        pick.gVector = channel == 1 ? one : CIVector(x: 0, y: 0, z: 0, w: 0)
        pick.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        pick.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        pick.biasVector = CIVector(x: channel == 0 ? -0.5 : 0, y: channel == 1 ? -0.5 : 0, z: 0, w: 0)
        return (pick.outputImage!, Float(min(cell, 1)))
    }

    private static func vector(_ values: [Float]) -> CIVector {
        CIVector(x: CGFloat(values[0]), y: CGFloat(values[1]), z: CGFloat(values[2]))
    }
}
