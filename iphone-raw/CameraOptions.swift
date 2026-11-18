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
