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
    var hasFlash = false

    var hasBayer: Bool { rawFormats.contains { $0.isBayer } }
}

/// Owns the capture session and captures Bayer RAW only — never ProRAW,
/// never a processed HEIC/JPEG alongside it.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var lenses: [AVCaptureDevice] = []
    @Published private(set) var currentLens: AVCaptureDevice?
    @Published private(set) var info = CaptureInfo()
    @Published fileprivate(set) var status = ""
    @Published fileprivate(set) var isCapturing = false
    /// Goes up as each shot is taken, for the shutter blink.
    @Published fileprivate(set) var shutterCount = 0
    /// Goes up when the scene changes after a tap to focus and focus returns to automatic.
    @Published private(set) var focusResets = 0

    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "iphoneraw.session")
    private var input: AVCaptureDeviceInput?
    private var subjectObserver: NSObjectProtocol?
    /// Session-queue state: whether the camera screen is showing, and shots
    /// still being processed. The session only stops once both allow it.
    private var wantsRunning = true
    private var capturesInFlight = 0

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

    /// Runs the camera only while its screen is showing. Stopping waits for
    /// shots in flight, so opening the gallery right after the shutter can't lose one.
    func setActive(_ active: Bool) {
        sessionQueue.async { [self] in
            wantsRunning = active
            updateRunning()
        }
    }

    /// Session queue only.
    private func updateRunning() {
        if wantsRunning, input != nil, !session.isRunning {
            session.startRunning()
        } else if !wantsRunning, capturesInFlight == 0, session.isRunning {
            session.stopRunning()
        }
    }

    func select(_ device: AVCaptureDevice) {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .photo

            let previous = input
            if let previous { session.removeInput(previous) }
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(newInput) else { throw CocoaError(.featureUnsupported) }
                session.addInput(newInput)
                input = newInput
            } catch {
                // Keep shooting with the lens we had.
                if let previous, session.canAddInput(previous) {
                    session.addInput(previous)
                } else {
                    input = nil
                }
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
            updateRunning()

            // RAW formats are only reported once the output is attached to a configured session.
            var info = CaptureInfo()
            info.lensName = device.localizedName
            info.rawFormats = output.availableRawPhotoPixelFormatTypes.map {
                .init(code: $0, isBayer: AVCapturePhotoOutput.isBayerRAWPixelFormat($0))
            }
            info.maxDimensions = "\(output.maxPhotoDimensions.width) × \(output.maxPhotoDimensions.height)"
            info.proRAWSupported = output.isAppleProRAWSupported
            info.hasFlash = output.supportedFlashModes.contains(.on)

            if let subjectObserver { NotificationCenter.default.removeObserver(subjectObserver) }
            subjectObserver = NotificationCenter.default.addObserver(
                forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: .main
            ) { [weak self] _ in self?.subjectAreaChanged() }

            publish {
                $0.currentLens = device
                $0.info = info
                $0.status = info.hasBayer ? "" : "\(device.localizedName) doesn't offer Bayer RAW."
            }
        }
    }

    /// Focuses and meters at `point` (in device coordinates, 0–1). A lock holds
    /// both once set; otherwise they follow the subject until the scene changes.
    func focus(at point: CGPoint, lock: Bool) {
        focus(at: point, lock: lock, watchSubject: !lock)
    }

    private func focus(at point: CGPoint, lock: Bool, watchSubject: Bool) {
        sessionQueue.async { [self] in
            guard let device = input?.device else { return }
            configure(device) {
                let focusMode: AVCaptureDevice.FocusMode = lock ? .autoFocus : .continuousAutoFocus
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) {
                    device.focusPointOfInterest = point
                    device.focusMode = focusMode
                }
                // autoExpose meters once and then locks.
                let exposureMode: AVCaptureDevice.ExposureMode = lock ? .autoExpose : .continuousAutoExposure
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(exposureMode) {
                    device.exposurePointOfInterest = point
                    device.exposureMode = exposureMode
                }
                device.setExposureTargetBias(0)
                device.isSubjectAreaChangeMonitoringEnabled = watchSubject
            }
        }
    }

    /// Exposure compensation in EV. It changes the actual exposure, so the RAW gets it too.
    func setExposureBias(_ bias: Float) {
        sessionQueue.async { [self] in
            guard let device = input?.device else { return }
            configure(device) {
                device.setExposureTargetBias(min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias))
            }
        }
    }

    private func subjectAreaChanged() {
        // Back to automatic across the whole frame, as the Camera app does.
        focus(at: CGPoint(x: 0.5, y: 0.5), lock: false, watchSubject: false)
        focusResets += 1
    }

    private func configure(_ device: AVCaptureDevice, _ change: () -> Void) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        change()
        device.unlockForConfiguration()
    }

    func capture(flash: AVCaptureDevice.FlashMode, crop: CropAspect) {
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
            settings.flashMode = output.supportedFlashModes.contains(flash) ? flash : .off

            publish {
                $0.isCapturing = true
                $0.status = ""
            }
            capturesInFlight += 1
            output.capturePhoto(with: settings, delegate: Capture(camera: self, crop: crop))
        }
    }

    fileprivate func publish(_ update: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async { update(self) }
    }
}

/// One shot in flight. The output holds its delegate only weakly, so each
/// capture keeps itself alive until it's done.
private final class Capture: NSObject, AVCapturePhotoCaptureDelegate {
    private static var inFlight: Set<Capture> = []
    private static let lock = NSLock()

    let camera: CameraController
    let crop: CropAspect

    init(camera: CameraController, crop: CropAspect) {
        self.camera = camera
        self.crop = crop
        super.init()
        Self.lock.withLock { _ = Self.inFlight.insert(self) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        camera.publish { $0.shutterCount += 1 }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            camera.publish { $0.status = "Capture failed: \(error.localizedDescription)" }
            return
        }
        guard photo.isRawPhoto, let dng = photo.fileDataRepresentation(with: MetadataAllowlist()) else {
            camera.publish { $0.status = "Capture didn't return RAW data." }
            return
        }
        camera.save(dng, crop: crop)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        camera.publish { $0.isCapturing = false }
        camera.captureFinished()
        Self.lock.withLock { _ = Self.inFlight.remove(self) }
    }
}

extension CameraController {
    fileprivate func captureFinished() {
        sessionQueue.async { [self] in
            capturesInFlight -= 1
            updateRunning()
        }
    }

    /// Writes the DNG to the app's Documents folder (visible in the Files app)
    /// and adds it to the photo library as a RAW + HEIC pair.
    fileprivate func save(_ dng: Data, crop: CropAspect) {
        let url = PhotoLibrary.newCaptureURL()
        let name = url.lastPathComponent

        do {
            try dng.write(to: url, options: .withoutOverwriting)
        } catch {
            publish { $0.status = "Couldn't write \(name): \(error.localizedDescription)" }
            return
        }
        // A crop is the only setting a capture starts with; looks are added later.
        var settings = DevelopSettings()
        if crop != .fourThree {
            settings.crop = crop
            EditArchive.update { $0.photos[name] = settings }
        }
        Task {
            // Photos develops a DNG with Apple's own processing when it displays it,
            // so it gets our neutral render to show, with the DNG attached as the RAW.
            let rendered = await RawRenderer.export(url, settings: settings, as: .heic)
            do {
                try await PhotosExport.saveRAW(url, rendered: rendered)
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
