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
    /// `nil` is the full 4:3 frame.
    var crop: CropAspect?
}

extension DevelopSettings {
    /// Missing keys fall back to defaults, so saved edits survive new settings being added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DevelopSettings()
        exposure = try c.decodeIfPresent(Float.self, forKey: .exposure) ?? d.exposure
        temperature = try c.decodeIfPresent(Float.self, forKey: .temperature)
        tint = try c.decodeIfPresent(Float.self, forKey: .tint)
        saturation = try c.decodeIfPresent(Float.self, forKey: .saturation) ?? d.saturation
        appleLook = try c.decodeIfPresent(Bool.self, forKey: .appleLook) ?? d.appleLook
        lensCorrection = try c.decodeIfPresent(Bool.self, forKey: .lensCorrection) ?? d.lensCorrection
        film = try c.decodeIfPresent(FilmLook.self, forKey: .film)
        filmPresetID = try c.decodeIfPresent(String.self, forKey: .filmPresetID)
        crop = try? c.decodeIfPresent(CropAspect.self, forKey: .crop)
    }
}

enum RawRenderer {
    enum Priority {
        /// Grid thumbnails and look previews.
        case thumbnail
        /// The photo being viewed.
        case preview
    }

    private static let context = CIContext()
    private static let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 << 20
        return cache
    }()
    /// Rendered thumbnails persist here (one folder per photo) so they load instantly next time.
    private static let thumbnailDirectory = URL.cachesDirectory.appending(path: "thumbnails")
    /// Reading a cached JPEG is cheap and safe to do in parallel, unlike a RAW decode.
    private static let diskQueue = DispatchQueue(label: "iphoneraw.thumbnails.disk", qos: .userInitiated, attributes: .concurrent)
    /// The disk cache is trimmed back to `thumbnailTrimTarget` once it passes this.
    private static let thumbnailDiskLimit = 200 << 20
    private static let thumbnailTrimTarget = 150 << 20
    /// Memory-cache keys for each photo, so its thumbnails can be evicted when
    /// it's deleted; NSCache can't be enumerated.
    private static let memoryKeysLock = NSLock()
    private static var memoryKeys: [String: Set<NSString>] = [:]

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

    /// A thumbnail already in memory, without waiting — for scrubbing.
    static func cachedThumbnail(for url: URL, settings: DevelopSettings) -> UIImage? {
        thumbnails.object(forKey: cacheKey(url, settings))
    }

    /// Memory, then disk, then a fresh (draft-quality) RAW decode.
    static func thumbnail(for url: URL, settings: DevelopSettings = DevelopSettings()) async -> UIImage? {
        let key = cacheKey(url, settings)
        if let cached = thumbnails.object(forKey: key) { return cached }

        let file = thumbnailDirectory.appending(path: url.lastPathComponent).appending(path: "\(fnv1a(key as String)).jpg")
        var image = await run(on: diskQueue) {
            let image = (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))?.preparingForDisplay()
            // Marks it recently used, for trimming.
            if image != nil { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
            return image
        }
        if image == nil {
            image = await run(on: thumbnailQueue) {
                renderSync(url, settings: settings, maxPixel: 400, draft: true)
            }
            if let data = image?.jpegData(compressionQuality: 0.85) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file)
            }
        }
        if let image {
            thumbnails.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
            memoryKeysLock.withLock { _ = memoryKeys[url.lastPathComponent, default: []].insert(key) }
        }
        return image
    }

    static func removeCachedThumbnails(for url: URL) {
        let keys = memoryKeysLock.withLock { memoryKeys.removeValue(forKey: url.lastPathComponent) ?? [] }
        for key in keys { thumbnails.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: thumbnailDirectory.appending(path: url.lastPathComponent))
    }

    /// Removes cached thumbnails of photos that are gone, then the least
    /// recently used ones while the cache is over its limit.
    static func trimThumbnailCache(keeping photos: [URL]) {
        DispatchQueue.global(qos: .utility).async {
            let manager = FileManager.default
            let keep = Set(photos.map(\.lastPathComponent))
            let folders = (try? manager.contentsOfDirectory(at: thumbnailDirectory, includingPropertiesForKeys: nil)) ?? []
            for folder in folders where !keep.contains(folder.lastPathComponent) {
                try? manager.removeItem(at: folder)
            }

            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            var files: [(url: URL, size: Int, used: Date)] = []
            for folder in folders where keep.contains(folder.lastPathComponent) {
                for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [] {
                    let values = try? file.resourceValues(forKeys: Set(keys))
                    files.append((file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
                }
            }
            var total = files.reduce(0) { $0 + $1.size }
            guard total > thumbnailDiskLimit else { return }
            for file in files.sorted(by: { $0.used < $1.used }) where total > thumbnailTrimTarget {
                try? manager.removeItem(at: file.url)
                total -= file.size
            }
        }
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

    /// Bump when rendering changes, so cached thumbnails are made again.
    /// 2: grain, halation and bloom render (they were blank before).
    /// 3: halation and bloom thresholds work with clipped highlights.
    private static let renderVersion = 3

    private static func cacheKey(_ url: URL, _ settings: DevelopSettings) -> NSString {
        let encoded = (try? JSONEncoder().encode(settings)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(url.lastPathComponent)|v\(renderVersion)|\(encoded)" as NSString
    }

    private static func renderSync(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat, draft: Bool = false) -> UIImage? {
        renderCGImage(url, settings: settings, maxPixel: maxPixel, draft: draft).map(UIImage.init(cgImage:))
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

        CGImageDestinationAddImage(destination, opaque(image), properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Core Image renders with an alpha channel, but photos are opaque; without
    /// one, ImageIO doesn't have to strip it (and complain) on every save.
    private static func opaque(_ image: CGImage) -> CGImage {
        guard ![.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo),
              let space = image.colorSpace,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// `draft` trades demosaic quality for speed; fine at thumbnail size.
    private static func renderCGImage(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat, draft: Bool = false) -> CGImage? {
        guard var image = developed(url, settings: settings, maxPixel: maxPixel, draft: draft) else { return nil }
        if let film = settings.film {
            image = FilmPipeline.apply(film, to: image, seed: fnv1a(url.lastPathComponent))
        }
        return context.createCGImage(image, from: image.extent)
    }

    /// The photo with each look (`nil` for none) on top of `settings`, for the
    /// look chips. The RAW is decoded once and shared by every look.
    static func lookPreviews(_ url: URL, settings: DevelopSettings, looks: [FilmLook?], maxPixel: CGFloat) async -> [UIImage?] {
        await run(on: thumbnailQueue) {
            var neutral = settings
            neutral.film = nil
            guard let decoded = developed(url, settings: neutral, maxPixel: maxPixel, draft: true),
                  let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                  let bitmap = context.createCGImage(decoded, from: decoded.extent, format: .RGBAh, colorSpace: linear)
            else { return nil }
            // Rendered to a float bitmap so the looks reuse it instead of each re-running the decode.
            let base = CIImage(cgImage: bitmap)
            let seed = fnv1a(url.lastPathComponent)
            return looks.map { look in
                let image = look.map { FilmPipeline.apply($0, to: base, seed: seed) } ?? base
                return context.createCGImage(image, from: image.extent).map(UIImage.init(cgImage:))
            }
        } ?? looks.map { _ in nil }
    }

    /// The RAW decoded with `settings`, cropped and saturated, before any film look.
    private static func developed(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat, draft: Bool) -> CIImage? {
        guard let raw = CIRAWFilter(imageURL: url) else { return nil }

        let longest = max(raw.nativeSize.width, raw.nativeSize.height)
        if longest > maxPixel { raw.scaleFactor = Float(maxPixel / longest) }
        raw.isDraftModeEnabled = draft

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

        // Crop first, so the vignette and grain are framed by the crop.
        if let crop = settings.crop {
            let rect = crop.rect(in: image.extent.size).offsetBy(dx: image.extent.minX, dy: image.extent.minY).integral
            image = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }

        // Saturation isn't a RAW decode parameter, so it's applied afterwards.
        if settings.saturation != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.saturation = settings.saturation
            image = controls.outputImage ?? image
        }
        return image
    }

    /// Stable hash (FNV-1a): the per-photo grain seed, so grain doesn't change
    /// between renders, and thumbnail cache file names.
    private static func fnv1a(_ string: String) -> UInt64 {
        string.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
