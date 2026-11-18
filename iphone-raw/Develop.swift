import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// The RAW development step, kept free of UIKit so the Mac contact-sheet tool
// (Tools/contact-sheet.sh) renders exactly what the app does.

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

/// A centred crop of the 4:3 sensor frame. The DNG always keeps the full
/// frame; the crop is a develop setting, so it can be changed later.
enum CropAspect: String, Codable, CaseIterable, Identifiable {
    case fourThree = "4:3"
    case square = "1:1"
    case sixteenNine = "16:9"

    var id: Self { self }
    var name: String { rawValue }

    /// Long edge over short edge.
    var ratio: CGFloat {
        switch self {
        case .fourThree: 4.0 / 3
        case .square: 1
        case .sixteenNine: 16.0 / 9
        }
    }

    /// The crop of an image of `size`, centred.
    func rect(in size: CGSize) -> CGRect {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        guard long > 0, short > 0 else { return CGRect(origin: .zero, size: size) }
        // Wider than the frame keeps the long edge; narrower keeps the short one.
        let (newLong, newShort) = ratio >= long / short ? (long, long / ratio) : (short * ratio, short)
        let cropped = size.width >= size.height
            ? CGSize(width: newLong, height: newShort)
            : CGSize(width: newShort, height: newLong)
        return CGRect(x: (size.width - cropped.width) / 2, y: (size.height - cropped.height) / 2,
                      width: cropped.width, height: cropped.height)
    }
}

enum Develop {
    /// The RAW decoded with `settings`, cropped and saturated, before any film look.
    static func image(_ url: URL, settings: DevelopSettings, maxPixel: CGFloat, draft: Bool) -> CIImage? {
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
    static func hash(_ string: String) -> UInt64 {
        string.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}
