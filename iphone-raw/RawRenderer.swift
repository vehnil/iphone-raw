import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// User-adjustable development of a Bayer DNG. The defaults are "neutral":
/// none of Apple's look (boost, local tone mapping, sharpening, noise
/// reduction, lens correction) is applied.
struct DevelopSettings: Equatable {
    var exposure: Float = 0
    /// Kelvin. `nil` means the as-shot white balance stored in the DNG.
    var temperature: Float?
    var tint: Float?
    var saturation: Float = 1
    var appleLook = false
    var lensCorrection = false
}

enum RawRenderer {
    private static let context = CIContext()
    private static let thumbnails = NSCache<NSURL, UIImage>()

    // RAW decodes block their thread until done. Run on Swift's cooperative
    // pool (one thread per core), a gallery's worth of them occupies every
    // thread and they never finish. Dedicated queues keep them off the pool;
    // being serial also bounds memory use. Previews get their own queue so
    // opening a photo doesn't wait behind a grid of thumbnails.
    private static let thumbnailQueue = DispatchQueue(label: "iphoneraw.thumbnails", qos: .utility)
    private static let previewQueue = DispatchQueue(label: "iphoneraw.preview", qos: .userInitiated)

    /// Neutral settings with the white balance the camera recorded.
    static func asShotSettings(for url: URL) async -> DevelopSettings? {
        await run(on: previewQueue) {
            guard let raw = CIRAWFilter(imageURL: url) else { return nil }
            return DevelopSettings(temperature: raw.neutralTemperature, tint: raw.neutralTint)
        }
    }

    static func thumbnail(for url: URL) async -> UIImage? {
        if let cached = thumbnails.object(forKey: url as NSURL) { return cached }
        let image = await run(on: thumbnailQueue) {
            renderSync(url, settings: DevelopSettings(), maxPixel: 400)
        }
        if let image { thumbnails.setObject(image, forKey: url as NSURL) }
        return image
    }

    static func render(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat) async -> UIImage? {
        await run(on: previewQueue) {
            renderSync(url, settings: settings, maxPixel: maxPixel)
        }
    }

    private static func run<T>(on queue: DispatchQueue, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private static func renderSync(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat) -> UIImage? {
        guard let raw = CIRAWFilter(imageURL: url) else { return nil }

        let longest = max(raw.nativeSize.width, raw.nativeSize.height)
        if longest > maxPixel { raw.scaleFactor = Float(maxPixel / longest) }

        raw.exposure = settings.exposure
        if let temperature = settings.temperature { raw.neutralTemperature = temperature }
        if let tint = settings.tint { raw.neutralTint = tint }
        if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = settings.lensCorrection }

        if !settings.appleLook {
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
            if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
            if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0 }
        }

        guard var image = raw.outputImage else { return nil }

        // Saturation isn't a RAW decode parameter, so it's applied afterwards.
        if settings.saturation != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.saturation = settings.saturation
            image = controls.outputImage ?? image
        }

        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
