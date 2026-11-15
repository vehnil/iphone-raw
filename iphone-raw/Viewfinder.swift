import AVFoundation
import CoreMotion
import SwiftUI

/// The live preview at the sensor's 4:3 shape, with the crop, grid, level and
/// focus box drawn over it. Tap to focus and expose, drag up or down after a
/// tap to adjust exposure, press and hold to lock focus and exposure.
struct Viewfinder: View {
    @ObservedObject var camera: CameraController
    let crop: CropAspect
    let showsGrid: Bool
    let showsLevel: Bool

    @State private var preview = PreviewHandle()
    @State private var focus: FocusIndicator?
    @State private var bias: Float = 0
    @State private var press: Press?
    @State private var lockTimer: Task<Void, Never>?
    @State private var dimTimer: Task<Void, Never>?

    private struct FocusIndicator: Equatable {
        var point: CGPoint
        var isLocked: Bool
        var isBright = true
    }

    private struct Press {
        var startBias: Float
        var moved = false
        var handled = false
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = crop.rect(in: geometry.size)
            ZStack {
                CameraPreview(session: camera.session, handle: preview)
                CropMask(frame: frame)
                if showsGrid {
                    GridLines(frame: frame)
                }
                if showsLevel {
                    LevelIndicator()
                        .position(x: frame.midX, y: frame.midY)
                }
                if let focus {
                    FocusBox(bias: bias, isBright: focus.isBright, isLocked: focus.isLocked)
                        .position(focus.point)
                        .allowsHitTesting(false)
                }
                if focus?.isLocked == true {
                    Text("AE/AF LOCK")
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow, in: RoundedRectangle(cornerRadius: 3))
                        .position(x: frame.midX, y: frame.minY + 20)
                }
            }
            .contentShape(Rectangle())
            .gesture(pressGesture)
        }
        .aspectRatio(3.0 / 4, contentMode: .fit)
        .clipped()
        .sensoryFeedback(.impact(weight: .medium), trigger: focus?.isLocked == true) { _, locked in locked }
        .onChange(of: camera.focusResets) { clearFocus() }
        .onChange(of: camera.currentLens) { clearFocus() }
    }

    /// One gesture for tap, hold and exposure drag, so they can't fight each other.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if press == nil {
                    press = Press(startBias: bias)
                    let start = value.startLocation
                    lockTimer = Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled, press?.moved == false else { return }
                        press?.handled = true
                        setFocus(at: start, lock: true)
                    }
                }
                let dx = value.translation.width, dy = value.translation.height
                if press?.moved == false, hypot(dx, dy) > 10 {
                    press?.moved = true
                    lockTimer?.cancel()
                }
                guard let press, press.moved, focus != nil else { return }
                // Up brightens, as in the Camera app.
                bias = min(max(press.startBias - Float(dy / 120), -2), 2)
                camera.setExposureBias(bias)
                focus?.isBright = true
                dimTimer?.cancel()
            }
            .onEnded { value in
                lockTimer?.cancel()
                if let press, !press.moved, !press.handled {
                    setFocus(at: value.startLocation, lock: false)
                }
                press = nil
                scheduleDim()
            }
    }

    private func setFocus(at point: CGPoint, lock: Bool) {
        guard let devicePoint = preview.devicePoint(fromViewPoint: point) else { return }
        bias = 0
        focus = FocusIndicator(point: point, isLocked: lock)
        camera.focus(at: devicePoint, lock: lock)
        scheduleDim()
    }

    private func scheduleDim() {
        dimTimer?.cancel()
        dimTimer = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation { focus?.isBright = false }
        }
    }

    private func clearFocus() {
        focus = nil
        bias = 0
    }
}

/// Lets the view convert touches to the camera's focus coordinates.
final class PreviewHandle {
    weak var layer: AVCaptureVideoPreviewLayer?

    func devicePoint(fromViewPoint point: CGPoint) -> CGPoint? {
        layer?.captureDevicePointConverted(fromLayerPoint: point)
    }
}

private struct FocusBox: View {
    let bias: Float
    let isBright: Bool
    let isLocked: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .strokeBorder(.yellow, lineWidth: 1)
                .frame(width: 72, height: 72)
            // Exposure slider: the sun rides up and down the line with the bias.
            Rectangle()
                .fill(.yellow)
                .frame(width: 1, height: 100)
                .opacity(isBright ? 1 : 0)
                .offset(x: 52)
            Image(systemName: "sun.max.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)
                .offset(x: 52, y: CGFloat(-bias) * 24)
                .opacity(isBright || bias != 0 ? 1 : 0)
        }
        .opacity(isBright ? 1 : 0.5)
        .scaleEffect(isLocked && isBright ? 1.1 : 1)
        .animation(.snappy, value: isLocked)
    }
}

/// Darkens what the crop leaves out.
private struct CropMask: View {
    let frame: CGRect

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: geometry.size))
                path.addRect(frame)
            }
            .fill(.black.opacity(0.7), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }
}

/// Rule of thirds.
private struct GridLines: View {
    let frame: CGRect

    var body: some View {
        Path { path in
            for third in [1.0 / 3, 2.0 / 3] {
                let x = frame.minX + frame.width * third
                let y = frame.minY + frame.height * third
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
                path.move(to: CGPoint(x: frame.minX, y: y))
                path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.45), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
}

/// Horizon level, like the Camera app's: a broken line that straightens and
/// turns yellow when the phone is level. Works held upright or sideways.
private struct LevelIndicator: View {
    @StateObject private var motion = LevelMotion()

    var body: some View {
        ZStack {
            if let tilt = motion.tilt {
                let isLevel = abs(tilt.offset) < .pi / 180
                ZStack {
                    HStack(spacing: isLevel ? 0 : 100) {
                        segment(width: 24, isLevel: isLevel)
                        segment(width: 24, isLevel: isLevel)
                    }
                    segment(width: isLevel ? 148 : 100, isLevel: isLevel)
                        .rotationEffect(.radians(-tilt.offset))
                }
                .rotationEffect(.radians(-tilt.quarter))
                .sensoryFeedback(.impact(weight: .light), trigger: isLevel) { _, level in level }
            }
        }
        .allowsHitTesting(false)
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
    }

    private func segment(width: CGFloat, isLevel: Bool) -> some View {
        Rectangle()
            .fill(isLevel ? Color.yellow : .white)
            .frame(width: width, height: 1.5)
    }
}

@MainActor
private final class LevelMotion: ObservableObject {
    struct Tilt {
        /// The nearest upright or sideways orientation, in radians.
        var quarter: Double
        /// How far the phone is rotated from it.
        var offset: Double
    }

    /// `nil` when the phone is too far off level, or lying flat.
    @Published private(set) var tilt: Tilt?
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            MainActor.assumeIsolated { self?.update(gravity) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        tilt = nil
    }

    private func update(_ gravity: CMAcceleration) {
        guard abs(gravity.z) < 0.8 else { tilt = nil; return }
        // Clockwise roll of the phone, seen from the back.
        let angle = atan2(gravity.x, -gravity.y)
        let quarter = (angle / (.pi / 2)).rounded() * (.pi / 2)
        let offset = angle - quarter
        tilt = abs(offset) < .pi / 12 ? Tilt(quarter: quarter, offset: offset) : nil
    }
}
