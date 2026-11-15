import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case heic
    case jpeg

    var id: Self { self }
    var name: String { rawValue.uppercased() }
    var type: UTType { self == .heic ? .heic : .jpeg }
}

/// User-adjustable development of a Bayer DNG. The defaults are "neutral":
/// none of Apple's look (boost, local tone mapping, sharpening, noise
/// reduction, lens correction) is applied.
struct DevelopSettings: Codable, Equatable {
    var exposure: Float = 0
    /// Kelvin. `nil` means the as-shot white balance stored in the DNG.
    var temperature: Float?
    var tint: Float?
    var saturation: Float = 1
    var appleLook = false
    var lensCorrection = false
    var film: FilmLook?
    /// The preset `film` started from, for highlighting it in the UI.
    var filmPresetID: String?
}

enum RawRenderer {
    enum Priority {
        /// Grid thumbnails and look previews.
        case thumbnail
        /// The photo being viewed.
        case preview
    }

    private static let context = CIContext()
    private static let thumbnails = NSCache<NSString, UIImage>()

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

    static func thumbnail(for url: URL, settings: DevelopSettings = DevelopSettings()) async -> UIImage? {
        let key = cacheKey(url, settings)
        if let cached = thumbnails.object(forKey: key) { return cached }
        let image = await render(url, settings: settings, maxPixel: 400, priority: .thumbnail)
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }

    static func render(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat, priority: Priority = .preview) async -> UIImage? {
        await run(on: priority == .preview ? previewQueue : thumbnailQueue) {
            renderSync(url, settings: settings, maxPixel: maxPixel)
        }
    }

    /// Runs `work` on `queue`, skipping it if the calling task was cancelled
    /// while waiting — e.g. a page swiped past before its turn came.
    private static func run<T>(on queue: DispatchQueue, _ work: @escaping () -> T?) async -> T? {
        let cancelled = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: cancelled.isSet ? nil : work()) }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    private static func cacheKey(_ url: URL, _ settings: DevelopSettings) -> NSString {
        let encoded = (try? JSONEncoder().encode(settings)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(url.lastPathComponent)|\(encoded)" as NSString
    }

    private static func renderSync(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat) -> UIImage? {
        renderCGImage(url, settings: settings, maxPixel: maxPixel).map(UIImage.init(cgImage:))
    }

    /// Full-resolution HEIC or JPEG with the photo's settings applied.
    static func export(_ url: URL, settings: DevelopSettings, as format: ExportFormat) async -> Data? {
        await run(on: previewQueue) {
            guard let image = renderCGImage(url, settings: settings, maxPixel: .infinity) else { return nil }
            return encode(image, as: format, source: url)
        }
    }

    private static func encode(_ image: CGImage, as format: ExportFormat, source: URL) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { return nil }

        // Same allowlist as captures. The render is already upright and no longer RAW.
        let sourceProperties = CGImageSourceCreateWithURL(source as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        var properties = MetadataAllowlist.filter(sourceProperties)
        properties[kCGImagePropertyDNGDictionary as String] = nil
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = image.width
            exif[kCGImagePropertyExifPixelYDimension as String] = image.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func renderCGImage(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat) -> CGImage? {
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
            // Colour noise blotches look digital, not like film, so film looks keep
            // Apple's colour noise reduction; grain replaces the luminance noise.
            if raw.isColorNoiseReductionSupported && settings.film == nil { raw.colorNoiseReductionAmount = 0 }
        }

        guard var image = raw.outputImage else { return nil }

        // Saturation isn't a RAW decode parameter, so it's applied afterwards.
        if settings.saturation != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.saturation = settings.saturation
            image = controls.outputImage ?? image
        }

        if let film = settings.film {
            image = FilmPipeline.apply(film, to: image, seed: grainSeed(for: url))
        }

        return context.createCGImage(image, from: image.extent)
    }

    /// Stable per-photo seed (FNV-1a of the file name) so grain doesn't change between renders.
    private static func grainSeed(for url: URL) -> UInt64 {
        url.lastPathComponent.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
