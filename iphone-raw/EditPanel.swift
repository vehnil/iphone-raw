import SwiftUI

/// Develop and Film controls for one photo.
struct EditPanel: View {
    let url: URL
    let edits: EditStore

    private enum Tab { case develop, film }
    @State private var tab = Tab.film
    @State private var asShot: DevelopSettings?
    @State private var asShotFailed = false

    var body: some View {
        VStack(spacing: 12) {
            Picker("Controls", selection: $tab) {
                Text("Develop").tag(Tab.develop)
                Text("Film").tag(Tab.film)
            }
            .pickerStyle(.segmented)

            switch tab {
            case .develop:
                if let asShot {
                    DevelopControls(settings: edits.binding(for: url), asShot: asShot)
                } else if asShotFailed {
                    Text("This photo's RAW data couldn't be read.")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            case .film:
                FilmControls(url: url, settings: edits.binding(for: url))
            }
        }
        .font(.footnote)
        .padding()
        .task {
            asShot = await edits.asShotSettings(for: url)
            asShotFailed = asShot == nil && !Task.isCancelled
        }
    }
}

private struct DevelopControls: View {
    @Binding var settings: DevelopSettings
    let asShot: DevelopSettings

    var body: some View {
        VStack(spacing: 8) {
            SliderRow("Exposure", value: $settings.exposure, in: -3...3, format: "%+.1f EV")
            SliderRow("Temperature", value: optional($settings.temperature, fallback: 5000), in: 2000...10000, format: "%.0f K")
            SliderRow("Tint", value: optional($settings.tint, fallback: 0), in: -150...150, format: "%+.0f")
            SliderRow("Saturation", value: $settings.saturation, in: 0...2, format: "%.2f")

            Picker("Crop", selection: crop) {
                ForEach(CropAspect.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Apple processing", isOn: $settings.appleLook)
            Toggle("Lens correction", isOn: $settings.lensCorrection)

            Button("Reset to as-shot") { settings = resetSettings }
                .disabled(settings == resetSettings)
        }
    }

    private var crop: Binding<CropAspect> {
        Binding(get: { settings.crop ?? .fourThree },
                set: { settings.crop = $0 == .fourThree ? nil : $0 })
    }

    /// As-shot development, keeping the chosen film look and crop.
    private var resetSettings: DevelopSettings {
        var reset = asShot
        reset.film = settings.film
        reset.filmPresetID = settings.filmPresetID
        reset.crop = settings.crop
        return reset
    }

    private func optional(_ binding: Binding<Float?>, fallback: Float) -> Binding<Float> {
        Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = $0 })
    }
}

private struct FilmControls: View {
    let url: URL
    @Binding var settings: DevelopSettings
    @ObservedObject private var lab = LabStore.shared
    /// Chip previews: "Off" first, then each look.
    @State private var previews: [UIImage?] = []

    private struct PreviewKey: Equatable {
        let settings: DevelopSettings
        let looks: [FilmLook]
    }

    /// The built-in looks, then those saved in the Lab.
    private var looks: [(id: String, name: String, look: FilmLook)] {
        FilmLook.presets.map { ($0.id, $0.name, $0.look) } + lab.savedLooks
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    LookChip(name: "Off", image: preview(0), isSelected: settings.film == nil) {
                        settings.film = nil
                        settings.filmPresetID = nil
                    }
                    ForEach(Array(looks.enumerated()), id: \.element.id) { index, preset in
                        LookChip(name: preset.name, image: preview(index + 1),
                                 isSelected: settings.filmPresetID == preset.id) {
                            settings.film = preset.look
                            settings.filmPresetID = preset.id
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Previews only depend on the develop settings: the look sliders don't change them.
            .task(id: PreviewKey(settings: with(nil), looks: looks.map(\.look))) {
                previews = await RawRenderer.lookPreviews(url, settings: with(nil),
                                                          looks: [nil] + looks.map(\.look), maxPixel: 160)
            }

            if settings.film != nil {
                SliderRow("Strength", value: film(\.strength), in: 0...1, format: "%.2f")
                SliderRow("Grain", value: film(\.grain), in: 0...1, format: "%.2f")
                SliderRow("Halation", value: film(\.halation), in: 0...1, format: "%.2f")
                SliderRow("Bloom", value: film(\.bloom), in: 0...1, format: "%.2f")
                SliderRow("Roll-off", value: film(\.rolloff), in: 0...1, format: "%.2f")
                SliderRow("Fade", value: film(\.fade), in: 0...0.15, format: "%.2f")
            }
        }
    }

    /// This photo's development with a different look.
    private func with(_ look: FilmLook?) -> DevelopSettings {
        var preview = settings
        preview.film = look
        preview.filmPresetID = nil
        return preview
    }

    private func preview(_ index: Int) -> UIImage? {
        previews.indices.contains(index) ? previews[index] : nil
    }

    private func film(_ keyPath: WritableKeyPath<FilmLook, Float>) -> Binding<Float> {
        Binding(get: { settings.film?[keyPath: keyPath] ?? 0 },
                set: { settings.film?[keyPath: keyPath] = $0 })
    }
}

private struct LookChip: View {
    let name: String
    let image: UIImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Color.gray.opacity(0.2)
                    .frame(width: 64, height: 64)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                    }
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String

    init(_ label: String, value: Binding<Float>, in range: ClosedRange<Float>, format: String) {
        self.label = label
        _value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }
}
