import AVFoundation

/// What the current lens can deliver, for the capabilities screen.
struct CaptureInfo {
    struct RawFormat: Identifiable {
        let code: OSType
        let isBayer: Bool
        var id: OSType { code }
        var name: String { fourCC(code) }
    }

    var lensName = "—"
    var rawFormats: [RawFormat] = []
    var maxDimensions = "—"
    var proRAWSupported = false

    var hasBayer: Bool { rawFormats.contains { $0.isBayer } }
}

/// Owns the capture session and captures Bayer RAW only — never ProRAW,
/// never a processed HEIC/JPEG alongside it.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var lenses: [AVCaptureDevice] = []
    @Published private(set) var currentLens: AVCaptureDevice?
    @Published private(set) var info = CaptureInfo()
    @Published private(set) var status = ""
    @Published private(set) var isCapturing = false

    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "iphoneraw.session")
    private var input: AVCaptureDeviceInput?

    func start() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                publish { $0.status = "Camera access denied — enable it in Settings." }
                return
            }
            // Physical lenses only: virtual multi-camera devices (dual/triple)
            // don't offer Bayer RAW and would switch lenses behind our back.
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
                mediaType: .video,
                position: .unspecified
            )
            let devices = discovery.devices
            publish { $0.lenses = devices }

            let preferred = devices.first { $0.position == .back && $0.deviceType == .builtInWideAngleCamera } ?? devices.first
            guard let preferred else {
                publish { $0.status = "No camera found (the simulator has none)." }
                return
            }
            select(preferred)
        }
    }

    func select(_ device: AVCaptureDevice) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .photo

            if let input { session.removeInput(input) }
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(newInput) else { throw CocoaError(.featureUnsupported) }
                session.addInput(newInput)
                input = newInput
            } catch {
                session.commitConfiguration()
                publish { $0.status = "Couldn't open \(device.localizedName): \(error.localizedDescription)" }
                return
            }

            if !session.outputs.contains(output), session.canAddOutput(output) {
                session.addOutput(output)
            }
            output.maxPhotoQualityPrioritization = .speed

            // Largest still size this lens's active format supports.
            if let largest = device.activeFormat.supportedMaxPhotoDimensions
                .max(by: { $0.width * $0.height < $1.width * $1.height }) {
                output.maxPhotoDimensions = largest
            }

            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }

            // RAW formats are only reported once the output is attached to a configured session.
            var info = CaptureInfo()
            info.lensName = device.localizedName
            info.rawFormats = output.availableRawPhotoPixelFormatTypes.map {
                .init(code: $0, isBayer: AVCapturePhotoOutput.isBayerRAWPixelFormat($0))
            }
            info.maxDimensions = "\(output.maxPhotoDimensions.width) × \(output.maxPhotoDimensions.height)"
            info.proRAWSupported = output.isAppleProRAWSupported

            publish {
                $0.currentLens = device
                $0.info = info
                $0.status = info.hasBayer ? "" : "\(device.localizedName) doesn't offer Bayer RAW."
            }
        }
    }

    func capture() {
        sessionQueue.async { [self] in
            guard let format = output.availableRawPhotoPixelFormatTypes
                .first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat) else {
                publish { $0.status = "No Bayer RAW format on this lens." }
                return
            }
            // RAW-only settings: no processed companion image is requested, so
            // Smart HDR / Deep Fusion / Photographic Styles have nothing to work on.
            let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            settings.maxPhotoDimensions = output.maxPhotoDimensions
            settings.photoQualityPrioritization = .speed
            settings.flashMode = .off

            publish { $0.isCapturing = true }
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func publish(_ update: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async { update(self) }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        defer { publish { $0.isCapturing = false } }

        if let error {
            publish { $0.status = "Capture failed: \(error.localizedDescription)" }
            return
        }
        guard photo.isRawPhoto, let dng = photo.fileDataRepresentation(with: MetadataAllowlist()) else {
            publish { $0.status = "Capture didn't return RAW data." }
            return
        }
        save(dng)
    }

    /// Writes the DNG to the app's Documents folder (visible in the Files app)
    /// and adds it to the photo library as a RAW + HEIC pair.
    private func save(_ dng: Data) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "RAW_\(formatter.string(from: Date())).dng"
        let url = URL.documentsDirectory.appending(path: name)

        do {
            try dng.write(to: url)
        } catch {
            publish { $0.status = "Couldn't write \(name): \(error.localizedDescription)" }
            return
        }
        Task {
            // Photos develops a DNG with Apple's own processing when it displays it,
            // so it gets our neutral render to show, with the DNG attached as the RAW.
            let rendered = await RawRenderer.export(url, settings: DevelopSettings(), as: .heic)
            do {
                try await PhotosExport.saveRAW(url, rendered: rendered)
                publish { $0.status = "Saved \(name)" }
            } catch is PhotosExport.NoAccess {
                publish { $0.status = "Saved \(name) to Files (no Photos access)." }
            } catch {
                publish { $0.status = "Saved to Files, Photos failed: \(error.localizedDescription)" }
            }
        }
    }
}

/// Renders a pixel format code as its four-character name, e.g. 'bgg4'.
func fourCC(_ code: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    let text = String(bytes: bytes, encoding: .ascii) ?? ""
    let hex = String(format: "0x%08X", code)
    let printable = bytes.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    return printable ? "'\(text)' (\(hex))" : hex
}
