import AVFoundation
import CoreGraphics

enum FlashOption: String, CaseIterable, Identifiable {
    case off, auto, on

    var id: Self { self }
    var name: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        }
    }
    var mode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }
}

enum TimerOption: Int, CaseIterable, Identifiable {
    case off = 0, three = 3, ten = 10

    var id: Self { self }
    var name: String { self == .off ? "Off" : "\(rawValue)s" }
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
