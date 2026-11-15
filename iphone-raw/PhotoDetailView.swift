import SwiftUI

/// Shows one DNG, developed neutrally by default, with controls for the
/// parameters Core Image's RAW decoder exposes.
struct PhotoDetailView: View {
    let url: URL

    @State private var asShot: DevelopSettings?
    @State private var settings = DevelopSettings()
    @State private var image: UIImage?
    @State private var showingControls = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }

            if showingControls, let asShot {
                DevelopControls(settings: $settings, asShot: asShot)
                    .padding()
                    .background(.bar)
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingControls.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                ShareLink(item: url)
            }
        }
        .task {
            guard asShot == nil, let loaded = await RawRenderer.asShotSettings(for: url) else { return }
            asShot = loaded
            settings = loaded
        }
        .task(id: settings) {
            // Short delay so dragging a slider doesn't queue a render per tick.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            image = await RawRenderer.render(url, settings: settings, maxPixel: 2000)
        }
    }
}

private struct DevelopControls: View {
    @Binding var settings: DevelopSettings
    let asShot: DevelopSettings

    var body: some View {
        VStack(spacing: 8) {
            row("Exposure", value: $settings.exposure, range: -3...3, format: "%+.1f EV")
            row("Temperature", value: optional($settings.temperature, fallback: 5000), range: 2000...10000, format: "%.0f K")
            row("Tint", value: optional($settings.tint, fallback: 0), range: -150...150, format: "%+.0f")
            row("Saturation", value: $settings.saturation, range: 0...2, format: "%.2f")

            Toggle("Apple processing", isOn: $settings.appleLook)
            Toggle("Lens correction", isOn: $settings.lensCorrection)

            Button("Reset to as-shot") { settings = asShot }
                .disabled(settings == asShot)
        }
        .font(.footnote)
    }

    private func row(_ label: String, value: Binding<Float>, range: ClosedRange<Float>, format: String) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func optional(_ binding: Binding<Float?>, fallback: Float) -> Binding<Float> {
        Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = $0 })
    }
}
