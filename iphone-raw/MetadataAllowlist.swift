import AVFoundation
import ImageIO

/// Rewrites a capture's metadata to an allowlist before the file is written:
/// capture time, camera/lens and exposure settings are kept; everything else
/// iOS adds (Apple's MakerNote with uptime, accelerometer and per-photo IDs,
/// iOS version, subject/face areas, GPS if it were ever present, …) is dropped.
/// Being an allowlist, anything new a future iOS adds is dropped too.
final class MetadataAllowlist: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    static let tiff: Set<CFString> = [
        kCGImagePropertyTIFFMake,
        kCGImagePropertyTIFFModel,
        kCGImagePropertyTIFFDateTime,
        kCGImagePropertyTIFFOrientation,
    ]

    static let exif: Set<CFString> = [
        // Time
        kCGImagePropertyExifDateTimeOriginal,
        kCGImagePropertyExifDateTimeDigitized,
        kCGImagePropertyExifSubsecTimeOriginal,
        kCGImagePropertyExifSubsecTimeDigitized,
        // Lens
        kCGImagePropertyExifLensMake,
        kCGImagePropertyExifLensModel,
        kCGImagePropertyExifLensSpecification,
        kCGImagePropertyExifFocalLength,
        kCGImagePropertyExifFocalLenIn35mmFilm,
        // Exposure
        kCGImagePropertyExifExposureTime,
        kCGImagePropertyExifFNumber,
        kCGImagePropertyExifISOSpeedRatings,
        kCGImagePropertyExifExposureProgram,
        kCGImagePropertyExifExposureMode,
        kCGImagePropertyExifExposureBiasValue,
        kCGImagePropertyExifMeteringMode,
        kCGImagePropertyExifShutterSpeedValue,
        kCGImagePropertyExifApertureValue,
        kCGImagePropertyExifFlash,
        kCGImagePropertyExifWhiteBalance,
        // Image structure
        kCGImagePropertyExifPixelXDimension,
        kCGImagePropertyExifPixelYDimension,
        kCGImagePropertyExifCFAPattern,
        kCGImagePropertyExifVersion,
    ]

    static let exifAux: Set<CFString> = [
        kCGImagePropertyExifAuxLensInfo,
        kCGImagePropertyExifAuxLensModel,
    ]

    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var metadata = Self.filter(photo.metadata)
        // The DNG writer refuses to produce a file without a TIFF Software tag,
        // so blank it instead of leaking the iOS version.
        var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFSoftware as String] = ""
        metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        return metadata
    }

    /// Also used for HEIC/JPEG exports.
    static func filter(_ metadata: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let orientation = metadata[kCGImagePropertyOrientation as String] {
            result[kCGImagePropertyOrientation as String] = orientation
        }
        // Technical DNG tags (colour matrices, black/white levels) are needed to decode the RAW.
        if let dng = metadata[kCGImagePropertyDNGDictionary as String] {
            result[kCGImagePropertyDNGDictionary as String] = dng
        }
        copy(kCGImagePropertyTIFFDictionary, keys: tiff, from: metadata, into: &result)
        copy(kCGImagePropertyExifDictionary, keys: exif, from: metadata, into: &result)
        copy(kCGImagePropertyExifAuxDictionary, keys: exifAux, from: metadata, into: &result)
        return result
    }

    private static func copy(_ dictionary: CFString, keys: Set<CFString>, from metadata: [String: Any], into result: inout [String: Any]) {
        guard let source = metadata[dictionary as String] as? [String: Any] else { return }
        let allowed = Set(keys.map { $0 as String })
        let kept = source.filter { allowed.contains($0.key) }
        if !kept.isEmpty { result[dictionary as String] = kept }
    }
}
