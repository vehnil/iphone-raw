import AVFoundation
import AVKit
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var showingSettings = false
    @State private var showingGallery = false
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("flash") private var flash = FlashOption.off
    @AppStorage("timer") private var timer = TimerOption.off
    @AppStorage("crop") private var crop = CropAspect.fourThree
    @AppStorage(CameraSettingsView.gridKey) private var showsGrid = false
    @AppStorage(CameraSettingsView.levelKey) private var showsLevel = false

    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var shutterBlink = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                Viewfinder(camera: camera, crop: crop, showsGrid: showsGrid, showsLevel: showsLevel && isCameraShowing)
                    .overlay {
                        if let countdown {
                            Text("\(countdown)")
                                .font(.system(size: 96, weight: .thin))
                                .contentTransition(.numericText(countsDown: true))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        // Only problems are shown; a successful capture just blinks.
                        if !camera.status.isEmpty {
                            Text(camera.status)
                                .font(.footnote)
                                .padding(8)
                                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                                .padding(8)
                        }
                    }
                    .overlay {
                        Color.black.opacity(shutterBlink ? 1 : 0).allowsHitTesting(false)
                    }
                Spacer(minLength: 0)

                HStack {
                    lensMenu.frame(maxWidth: .infinity)
                    shutterButton
                    galleryButton.frame(maxWidth: .infinity)
                }
                .padding(.vertical, 24)
            }
            .foregroundStyle(.white)
        }
        .task { camera.start() }
        // The gallery covers the camera without removing it, so stop it explicitly.
        .onChange(of: isCameraShowing) { _, showing in camera.setActive(showing) }
        // Either volume button takes the picture.
        .onCameraCaptureEvent(isEnabled: !showingGallery && !showingSettings) { event in
            if event.phase == .ended { shutter() }
        }
        .onChange(of: camera.shutterCount) {
            shutterBlink = true
            withAnimation(.easeOut(duration: 0.25)) { shutterBlink = false }
        }
        .sheet(isPresented: $showingSettings) {
            CameraSettingsView(info: camera.info)
        }
        .fullScreenCover(isPresented: $showingGallery) {
            GalleryView()
        }
    }

    private var isCameraShowing: Bool { !showingGallery && scenePhase != .background }

    private var canCapture: Bool { !camera.isCapturing && camera.info.hasBayer }

    /// Takes the picture, after the timer if one is set. Pressing again cancels a countdown.
    private func shutter() {
        if let countdownTask {
            countdownTask.cancel()
            self.countdownTask = nil
            countdown = nil
            return
        }
        guard canCapture else { return }
        guard timer != .off else {
            camera.capture(flash: flash.mode, crop: crop)
            return
        }
        countdownTask = Task {
            for remaining in stride(from: timer.rawValue, to: 0, by: -1) {
                withAnimation { countdown = remaining }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            countdown = nil
            countdownTask = nil
            camera.capture(flash: flash.mode, crop: crop)
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            if camera.info.hasFlash {
                Menu {
                    Picker("Flash", selection: $flash) {
                        ForEach(FlashOption.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
                    }
                } label: {
                    Image(systemName: flash.symbol)
                        .foregroundStyle(flash == .off ? Color.white : .yellow)
                        .frame(maxWidth: .infinity)
                }
            }

            Menu {
                Picker("Timer", selection: $timer) {
                    ForEach(TimerOption.allCases) { Text($0.name).tag($0) }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "timer")
                    if timer != .off { Text(timer.name).font(.footnote.monospacedDigit()) }
                }
                .foregroundStyle(timer == .off ? Color.white : .yellow)
                .frame(maxWidth: .infinity)
            }

            Menu {
                Picker("Aspect ratio", selection: $crop) {
                    ForEach(CropAspect.allCases) { Text($0.name).tag($0) }
                }
            } label: {
                Text(crop.name)
                    .font(.footnote.monospacedDigit().bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white, lineWidth: 1))
                    .frame(maxWidth: .infinity)
            }

            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").frame(maxWidth: .infinity)
            }
        }
        .font(.title3)
        .frame(height: 44)
        .padding(.horizontal)
    }

    private var galleryButton: some View {
        Button { showingGallery = true } label: {
            Image(systemName: "photo.on.rectangle")
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.15), in: Circle())
        }
    }

    private var shutterButton: some View {
        Button(action: shutter) {
            Circle()
                .strokeBorder(.white, lineWidth: 4)
                .background(Circle().fill(camera.isCapturing ? .gray : .white).padding(8))
                .overlay {
                    if countdown != nil {
                        RoundedRectangle(cornerRadius: 4).fill(.red).frame(width: 26, height: 26)
                    }
                }
                .frame(width: 76, height: 76)
        }
        .disabled(!canCapture && countdownTask == nil)
    }

    private var lensMenu: some View {
        Menu {
            ForEach(camera.lenses, id: \.uniqueID) { lens in
                Button(lens.localizedName) { camera.select(lens) }
            }
        } label: {
            Image(systemName: "camera.rotate")
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.15), in: Circle())
        }
    }
}

/// Options that stay set, like those in Settings › Camera.
struct CameraSettingsView: View {
    static let gridKey = "showsGrid"
    static let levelKey = "showsLevel"

    let info: CaptureInfo
    @AppStorage(gridKey) private var showsGrid = false
    @AppStorage(levelKey) private var showsLevel = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Grid", isOn: $showsGrid)
                    Toggle("Level", isOn: $showsLevel)
                } footer: {
                    Text("Tap to focus and expose, then drag up or down to adjust exposure. Press and hold to lock focus and exposure. Either volume button takes a photo.")
                }
                Section {
                    NavigationLink("Lens capabilities") { CapabilitiesView(info: info) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
