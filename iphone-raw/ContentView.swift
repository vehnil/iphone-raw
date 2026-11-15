import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @State private var showingInfo = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session)

            VStack {
                HStack {
                    Text(camera.info.hasBayer ? "BAYER RAW" : "NO RAW")
                        .font(.caption.monospaced().bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(camera.info.hasBayer ? Color.green.opacity(0.8) : Color.red.opacity(0.8), in: Capsule())
                    Spacer()
                    Button { showingInfo = true } label: {
                        Image(systemName: "info.circle").font(.title2)
                    }
                }
                .padding()

                Spacer()

                if !camera.status.isEmpty {
                    Text(camera.status)
                        .font(.footnote)
                        .padding(8)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    lensMenu.frame(maxWidth: .infinity)
                    shutterButton
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
                .padding(.vertical, 24)
            }
            .foregroundStyle(.white)
        }
        .task { camera.start() }
        .sheet(isPresented: $showingInfo) {
            CapabilitiesView(info: camera.info)
        }
    }

    private var shutterButton: some View {
        Button { camera.capture() } label: {
            Circle()
                .strokeBorder(.white, lineWidth: 4)
                .background(Circle().fill(camera.isCapturing ? .gray : .white).padding(8))
                .frame(width: 76, height: 76)
        }
        .disabled(camera.isCapturing || !camera.info.hasBayer)
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
