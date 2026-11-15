import CoreImage
import CoreImage.CIFilterBuiltins

/// Applies a `FilmLook` to a neutral, scene-linear RAW decode.
enum FilmPipeline {
    /// Compiled Core Image kernels; overridable so the pipeline can run outside the app bundle.
    static var libraryURL = Bundle.main.url(forResource: "default", withExtension: "metallib")

    private static let toneKernel: CIColorKernel? = {
        guard let url = libraryURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? CIColorKernel(functionName: "filmTone", fromMetalLibraryData: data)
    }()

    static func apply(_ look: FilmLook, to neutral: CIImage) -> CIImage {
        guard look.strength > 0 else { return neutral }

        var image = color(look, neutral)
        image = tone(look, image)

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

    private static func vector(_ values: [Float]) -> CIVector {
        CIVector(x: CGFloat(values[0]), y: CGFloat(values[1]), z: CGFloat(values[2]))
    }
}
