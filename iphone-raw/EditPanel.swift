import SwiftUI

/// Develop and Film controls for one photo.
struct EditPanel: View {
    let url: URL
    @ObservedObject var edits: EditStore

    private enum Tab { case develop, film }
    @State private var tab = Tab.film
    @State private var asShot: DevelopSettings?

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
                } else {
                    ProgressView()
                }
            case .film:
                FilmControls(url: url, settings: edits.binding(for: url))
            }
        }
        .font(.footnote)
        .padding()
        .task { asShot = await edits.asShotSettings(for: url) }
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

            Toggle("Apple processing", isOn: $settings.appleLook)
            Toggle("Lens correction", isOn: $settings.lensCorrection)

            Button("Reset to as-shot") { settings = resetSettings }
                .disabled(settings == resetSettings)
        }
    }

    /// As-shot development, keeping the chosen film look.
    private var resetSettings: DevelopSettings {
        var reset = asShot
        reset.film = settings.film
        reset.filmPresetID = settings.filmPresetID
        return reset
    }

    private func optional(_ binding: Binding<Float?>, fallback: Float) -> Binding<Float> {
        Binding(get: { binding.wrappedValue ?? fallback }, set: { binding.wrappedValue = $0 })
    }
}

private struct FilmControls: View {
    let url: URL
    @Binding var settings: DevelopSettings

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    LookChip(name: "Off", url: url, settings: with(nil), isSelected: settings.film == nil) {
                        settings.film = nil
                        settings.filmPresetID = nil
                    }
                    ForEach(FilmLook.presets) { preset in
                        LookChip(name: preset.name, url: url, settings: with(preset.look),
                                 isSelected: settings.filmPresetID == preset.id) {
                            settings.film = preset.look
                            settings.filmPresetID = preset.id
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            if settings.film != nil {
                SliderRow("Strength", value: film(\.strength), in: 0...1, format: "%.2f")
                SliderRow("Grain", value: film(\.grain), in: 0...1, format: "%.2f")
                SliderRow("Halation", value: film(\.halation), in: 0...1, format: "%.2f")
                SliderRow("Roll-off", value: film(\.rolloff), in: 0...1, format: "%.2f")
                SliderRow("Fade", value: film(\.fade), in: 0...0.15, format: "%.2f")
            }
        }
    }

    /// This photo's development with a different look, for the chip previews.
    private func with(_ look: FilmLook?) -> DevelopSettings {
        var preview = settings
        preview.film = look
        preview.filmPresetID = nil
        return preview
    }

    private func film(_ keyPath: WritableKeyPath<FilmLook, Float>) -> Binding<Float> {
        Binding(get: { settings.film?[keyPath: keyPath] ?? 0 },
                set: { settings.film?[keyPath: keyPath] = $0 })
    }
}

private struct LookChip: View {
    let name: String
    let url: URL
    let settings: DevelopSettings
    let isSelected: Bool
    let action: () -> Void

    @State private var image: UIImage?

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
        .task(id: settings) {
            image = await RawRenderer.render(url, settings: settings, maxPixel: 160, priority: .thumbnail)
        }
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
