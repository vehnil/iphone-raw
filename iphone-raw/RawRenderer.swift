import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import OSLog
import UIKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case heic
    case jpeg

    var id: Self { self }
    var name: String { rawValue.uppercased() }
    var type: UTType { self == .heic ? .heic : .jpeg }
}

enum RawRenderer {
    /// Timings for finding what's slow; in Xcode's console, filter by "perf".
    static let perf = Logger(subsystem: "iphone-raw", category: "perf")
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
    /// Warming ahead of the gallery runs here, below anything the gallery asks for.
    private static let warmQueue = DispatchQueue(label: "iphoneraw.thumbnails.warm", qos: .background)
    /// Long edge of thumbnails, in pixels.
    private static let thumbnailSize: CGFloat = 400

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
        await thumbnail(for: url, settings: settings, disk: diskQueue, decode: thumbnailQueue, keep: true)
    }

    /// Gets thumbnails ready before the gallery opens, in order: the first
    /// `inMemory` loaded into memory (from disk where cached), and any missing
    /// from disk decoded and saved. One at a time at background priority, so
    /// it stays out of the way of the camera and of the gallery itself.
    static func warmThumbnails(_ photos: [(url: URL, settings: DevelopSettings)], inMemory: Int) async {
        let start = Date()
        perf.info("warm-up: started, \(photos.count) photos")
        defer { perf.info("warm-up: stopped after \(Self.ms(since: start)) ms") }
        for (index, photo) in photos.enumerated() {
            guard !Task.isCancelled else { return }
            if index % 20 == 0 { perf.info("warm-up: at photo \(index), \(Self.ms(since: start)) ms") }
            let keep = index < inMemory
            let key = cacheKey(photo.url, photo.settings)
            if !keep, FileManager.default.fileExists(atPath: thumbnailFile(photo.url, key: key).path) { continue }
            _ = await thumbnail(for: photo.url, settings: photo.settings, disk: warmQueue, decode: warmQueue, keep: keep)
        }
    }

    /// `keep` puts the result in the memory cache.
    private static func thumbnail(for url: URL, settings: DevelopSettings,
                                  disk: DispatchQueue, decode: DispatchQueue, keep: Bool) async -> UIImage? {
        let key = cacheKey(url, settings)
        if let cached = thumbnails.object(forKey: key) { return cached }

        let start = Date()
        let file = thumbnailFile(url, key: key)
        var image = await run(on: disk) {
            let image = (try? Data(contentsOf: file)).flatMap(UIImage.init(data:))?.preparingForDisplay()
            // Marks it recently used, for trimming.
            if image != nil { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
            return image
        }
        if image == nil {
            image = await run(on: decode) {
                renderSync(url, settings: settings, maxPixel: thumbnailSize, draft: true)
            }
            if let image { save(image, to: file) }
            perf.info("thumbnail \(url.lastPathComponent): decoded, \(Self.ms(since: start)) ms (\(decode.label))")
        } else {
            perf.info("thumbnail \(url.lastPathComponent): from disk, \(Self.ms(since: start)) ms")
        }
        if let image, keep { remember(image, key: key, url: url) }
        return image
    }

    private static func thumbnailFile(_ url: URL, key: NSString) -> URL {
        thumbnailDirectory.appending(path: url.lastPathComponent).appending(path: "\(Develop.hash(key as String)).jpg")
    }

    private static func save(_ thumbnail: UIImage, to file: URL) {
        guard let data = thumbnail.jpegData(compressionQuality: 0.85) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file)
    }

    private static func remember(_ thumbnail: UIImage, key: NSString, url: URL) {
        thumbnails.setObject(thumbnail, forKey: key, cost: Int(thumbnail.size.width * thumbnail.size.height * thumbnail.scale * thumbnail.scale * 4))
        memoryKeysLock.withLock { _ = memoryKeys[url.lastPathComponent, default: []].insert(key) }
    }

    /// Keeps a thumbnail of a render that's already been made (a capture's
    /// HEIC for Photos, an export), so the gallery doesn't decode the RAW again.
    private static func storeThumbnail(from image: CGImage, for url: URL, settings: DevelopSettings) {
        let scale = min(1, thumbnailSize / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return }
        bitmap.interpolationQuality = .high
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = bitmap.makeImage() else { return }

        let thumbnail = UIImage(cgImage: small)
        let key = cacheKey(url, settings)
        save(thumbnail, to: thumbnailFile(url, key: key))
        remember(thumbnail, key: key, url: url)
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
        let start = Date()
        let image = await run(on: priority == .preview ? previewQueue : thumbnailQueue) {
            renderSync(url, settings: settings, maxPixel: maxPixel)
        }
        perf.info("render \(url.lastPathComponent) at \(maxPixel == .infinity ? "full" : "\(Int(maxPixel))") px: \(Self.ms(since: start)) ms, waiting included")
        return image
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
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

    /// Bump when rendering changes, so cached thumbnails are made again. Kept
    /// apart so a change to the looks doesn't remake every neutral thumbnail.
    /// Neutral 3 (versions before it were shared).
    private static let neutralRenderVersion = 3
    /// Film 2: grain, halation and bloom render. 3: halation and bloom work with
    /// clipped highlights. 4: halation and bloom tuned on real photos. 5: halation
    /// and bloom scatter a share of all light, with no threshold.
    private static let filmRenderVersion = 5

    private static func cacheKey(_ url: URL, _ settings: DevelopSettings) -> NSString {
        let encoded = (try? JSONEncoder().encode(settings)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let version = settings.film == nil ? neutralRenderVersion : filmRenderVersion
        return "\(url.lastPathComponent)|v\(version)|\(encoded)" as NSString
    }

    private static func renderSync(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat, draft: Bool = false) -> UIImage? {
        renderCGImage(url, settings: settings, maxPixel: maxPixel, draft: draft).map(UIImage.init(cgImage:))
    }

    /// Full-resolution HEIC or JPEG with the photo's settings applied.
    static func export(_ url: URL, settings: DevelopSettings, as format: ExportFormat) async -> Data? {
        await run(on: previewQueue) {
            guard let image = renderCGImage(url, settings: settings, maxPixel: .infinity) else { return nil }
            storeThumbnail(from: image, for: url, settings: settings)
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
        guard var image = Develop.image(url, settings: settings, maxPixel: maxPixel, draft: draft) else { return nil }
        if let film = settings.film {
            image = FilmPipeline.apply(film, to: image, seed: Develop.hash(url.lastPathComponent))
        }
        return context.createCGImage(image, from: image.extent)
    }

    /// The photo with each look (`nil` for none) on top of `settings`, for the
    /// look chips. The RAW is decoded once and shared by every look.
    static func lookPreviews(_ url: URL, settings: DevelopSettings, looks: [FilmLook?], maxPixel: CGFloat) async -> [UIImage?] {
        await run(on: thumbnailQueue) {
            var neutral = settings
            neutral.film = nil
            guard let decoded = Develop.image(url, settings: neutral, maxPixel: maxPixel, draft: true),
                  let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
                  let bitmap = context.createCGImage(decoded, from: decoded.extent, format: .RGBAh, colorSpace: linear)
            else { return nil }
            // Rendered to a float bitmap so the looks reuse it instead of each re-running the decode.
            let base = CIImage(cgImage: bitmap)
            let seed = Develop.hash(url.lastPathComponent)
            return looks.map { look in
                let image = look.map { FilmPipeline.apply($0, to: base, seed: seed) } ?? base
                return context.createCGImage(image, from: image.extent).map(UIImage.init(cgImage:))
            }
        } ?? looks.map { _ in nil }
    }

}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

// MARK: Lab

/// What the Lab is looking at.
enum LabSource: Hashable {
    case photo(URL)
    case chart(TestChart)

    var name: String {
        switch self {
        case .photo: "This photo"
        case .chart(let chart): chart.name
        }
    }
}

extension RawRenderer {
    /// Bases (develop done, before the look) for the Lab, so switching looks or
    /// stages doesn't decode the RAW again. Used on `previewQueue` only.
    private static var labBases: [(key: String, image: CIImage)] = []

    /// `source` rendered with each of `configs` and `stages`. `region` (0–1,
    /// top-left origin) crops the result, for the Lab's detail view.
    static func labRender(_ source: LabSource, configs: [DevelopSettings], stages: FilmPipeline.Stages,
                          maxPixel: CGFloat, region: CGRect?) async -> [UIImage?] {
        await run(on: previewQueue) {
            configs.map { settings -> UIImage? in
                guard var image = labBase(source, settings: settings, maxPixel: maxPixel) else { return nil }
                if let film = settings.film {
                    image = FilmPipeline.apply(film, to: image, seed: labSeed(source), stages: stages)
                }
                if let region {
                    let e = image.extent
                    let rect = CGRect(x: e.minX + region.minX * e.width, y: e.maxY - region.maxY * e.height,
                                      width: region.width * e.width, height: region.height * e.height).integral
                    image = image.cropped(to: rect)
                }
                return context.createCGImage(image, from: image.extent).map(UIImage.init(cgImage:))
            }
        } ?? configs.map { _ in nil }
    }

    /// Each configuration's response to mid grey from −8 to +4 EV, as display
    /// values, `samples` points. Spatial stages (vignette, glows, grain) are left out.
    static func labCurves(configs: [DevelopSettings], stages: FilmPipeline.Stages, samples: Int) async -> [[SIMD3<Float>]] {
        await run(on: thumbnailQueue) {
            let ramp = TestChart.exposureRamp(samples: samples, stops: labCurveStops)
            let display = CGColorSpace(name: CGColorSpace.extendedSRGB)!
            return configs.map { settings in
                var image = ramp.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
                if let film = settings.film {
                    image = FilmPipeline.apply(film, to: image, stages: stages.intersection([.color, .tone]))
                }
                var pixels = [Float](repeating: 0, count: samples * 4)
                context.render(image, toBitmap: &pixels, rowBytes: samples * 16, bounds: ramp.extent,
                               format: .RGBAf, colorSpace: display)
                return (0..<samples).map { SIMD3(pixels[$0 * 4], pixels[$0 * 4 + 1], pixels[$0 * 4 + 2]) }
            }
        } ?? []
    }

    static let labCurveStops: ClosedRange<Double> = -8...4

    private static func labSeed(_ source: LabSource) -> UInt64 {
        switch source {
        case .photo(let url): Develop.hash(url.lastPathComponent)
        case .chart(let chart): Develop.hash(chart.rawValue)
        }
    }

    private static func labBase(_ source: LabSource, settings: DevelopSettings, maxPixel: CGFloat) -> CIImage? {
        switch source {
        case .chart(let chart):
            // Cheap to make; charts aren't cached.
            return Develop.chart(chart, settings: settings, longEdge: min(maxPixel, 2400))
        case .photo(let url):
            // Only whether there's a look matters to the decode (colour noise reduction).
            var develop = settings
            develop.film = settings.film == nil ? nil : FilmLook()
            develop.filmPresetID = nil
            let encoded = (try? JSONEncoder().encode(develop)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let key = "\(url.lastPathComponent)|\(maxPixel)|\(encoded)"
            if let cached = labBases.first(where: { $0.key == key }) { return cached.image }

            guard let decoded = Develop.image(url, settings: develop, maxPixel: maxPixel, draft: false),
                  let bitmap = context.createCGImage(decoded, from: decoded.extent, format: .RGBAh, colorSpace: TestChart.linear)
            else { return nil }
            let image = CIImage(cgImage: bitmap)
            // Two is enough for A and B; full-resolution bases are large.
            labBases.append((key, image))
            if labBases.count > 2 { labBases.removeFirst() }
            return image
        }
    }
}
