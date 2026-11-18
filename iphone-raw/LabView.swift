import SwiftUI

/// Saved Lab configurations, in Application Support. Saved ones with a look
/// also show up in the editor's Film tab.
@MainActor
final class LabStore: ObservableObject {
    static let shared = LabStore()

    @Published private(set) var configs: [LabConfig] = []
    private let url = URL.applicationSupportDirectory.appending(path: "lab-configs.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([LabConfig].self, from: data) {
            configs = saved
        }
    }

    /// Saved looks for the editor, with the preset ID that marks them.
    var savedLooks: [(id: String, name: String, look: FilmLook)] {
        configs.compactMap { config in
            config.settings.film.map { (LabConfig.savedLookPrefix + config.id.uuidString, config.name, $0) }
        }
    }

    /// Adds `config`, or replaces the saved one with its ID.
    func save(_ config: LabConfig) {
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        write()
    }

    func delete(_ config: LabConfig) {
        configs.removeAll { $0.id == config.id }
        write()
    }

    /// A JSON file of `configs`, for sharing to the Mac's contact-sheet tool.
    func exportFile(_ configs: [LabConfig]) -> URL? {
        let file = URL.temporaryDirectory.appending(path: "lab-configs.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configs), (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    private func write() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(configs).write(to: url, options: .atomic)
    }
}

/// The testing wing: two configurations side by side on a photo or a test
/// chart, with every film stage switchable and the tone response plotted.
struct LabView: View {
    /// The photo the Lab was opened on, if any; charts are always available.
    let photo: URL?
    let edits: EditStore

    @ObservedObject private var store = LabStore.shared
    @Environment(\.dismiss) private var dismiss

    enum Side: String, CaseIterable, Identifiable {
        case a = "A", b = "B"
        var id: Self { self }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case wipe = "Wipe", split = "Split", flip = "Flip"
        var id: Self { self }
    }

    @State private var source: LabSource
    @State private var configA: LabConfig
    @State private var configB: LabConfig
    @State private var editing = Side.b
    @State private var stages = FilmPipeline.Stages.all
    @State private var mode = Mode.wipe
    @State private var wipe: CGFloat = 0.5
    @State private var showingB = false
    /// Detail shows a full-resolution crop around `detailCenter` (0–1, top-left origin).
    @State private var detail = false
    @State private var detailCenter = CGPoint(x: 0.5, y: 0.5)
    @State private var panStart: CGPoint?

    @State private var images: [UIImage?] = [nil, nil]
    @State private var curves: [[SIMD3<Float>]] = []
    @State private var isRendering = false
    @State private var naming: LabConfig?
    @State private var newName = ""

    init(photo: URL?, edits: EditStore) {
        self.photo = photo
        self.edits = edits
        _source = State(initialValue: photo.map(LabSource.photo) ?? .chart(.greyRamp))
        // A: the photo as it's edited now. B: the first preset on the same development.
        let current = photo.map(edits.settings(for:)) ?? DevelopSettings()
        var neutral = current
        neutral.film = nil
        neutral.filmPresetID = nil
        _configA = State(initialValue: LabConfig(name: current.film == nil ? "Neutral" : "Current edit", settings: current))
        var b = neutral
        if let first = FilmLook.presets.first {
            b.film = first.look
            b.filmPresetID = first.id
        }
        _configB = State(initialValue: LabConfig(name: FilmLook.presets.first?.name ?? "B", settings: b))
    }

    private struct RenderKey: Equatable {
        let source: LabSource
        let a: DevelopSettings
        let b: DevelopSettings
        let stages: FilmPipeline.Stages
        let region: CGRect?
    }

    private struct CurveKey: Equatable {
        let a: DevelopSettings
        let b: DevelopSettings
        let stages: FilmPipeline.Stages
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                compareArea
                    .frame(maxHeight: .infinity)
                    .background(Color.black)
                    .clipped()
                ScrollView {
                    controls.padding()
                }
                .frame(height: 340)
                .background(.bar)
            }
            .navigationTitle("Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) { sourceMenu }
            }
            .task(id: RenderKey(source: source, a: configA.settings, b: configB.settings, stages: stages, region: region)) {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                isRendering = true
                let rendered = await RawRenderer.labRender(source, configs: [configA.settings, configB.settings],
                                                           stages: stages, maxPixel: detail ? .infinity : 1600, region: region)
                guard !Task.isCancelled else { return }
                images = rendered
                isRendering = false
            }
            .task(id: CurveKey(a: configA.settings, b: configB.settings, stages: stages)) {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                curves = await RawRenderer.labCurves(configs: [DevelopSettings(), configA.settings, configB.settings],
                                                     stages: stages, samples: 96)
            }
            .alert("Save configuration", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if var config = naming {
                        config.name = newName.isEmpty ? config.name : newName
                        store.save(config)
                        set(editing, config)
                    }
                    naming = nil
                }
                Button("Cancel", role: .cancel) { naming = nil }
            } message: {
                Text("Saved configurations with a look also appear in the editor's Film tab.")
            }
        }
    }

    // MARK: Compare

    private var region: CGRect? {
        guard detail, let size = baseSize else { return nil }
        // A square region a quarter of the width across, in image pixels.
        let width: CGFloat = 0.25
        let height = min(1, width * size.width / size.height)
        let x = min(max(detailCenter.x - width / 2, 0), 1 - width)
        let y = min(max(detailCenter.y - height / 2, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The overview's size, remembered so detail can work out its region.
    @State private var baseSize: CGSize?

    private var compareArea: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                switch mode {
                case .wipe:
                    picture(0)
                    picture(1)
                        .mask(alignment: .leading) {
                            HStack(spacing: 0) {
                                Color.clear.frame(width: size.width * wipe)
                                Color.black
                            }
                        }
                    wipeHandle(in: size)
                case .split:
                    VStack(spacing: 2) {
                        picture(0)
                        picture(1)
                    }
                case .flip:
                    picture(showingB ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in toggleDetail(at: location, in: size) }
            .onTapGesture { if mode == .flip { showingB.toggle() } }
            .gesture(detailPan(in: size), including: detail ? .all : .none)
            .overlay(alignment: .top) { labels }
            .overlay {
                if isRendering, images.allSatisfy({ $0 == nil }) { ProgressView() }
            }
            .overlay(alignment: .bottomTrailing) {
                if detail {
                    Text("Detail · 1:1").font(.caption2.bold()).padding(6)
                        .background(.black.opacity(0.6), in: Capsule()).padding(8)
                }
            }
        }
    }

    private func picture(_ index: Int) -> some View {
        Group {
            if let image = images[index] {
                Image(uiImage: image).resizable().interpolation(detail ? .none : .medium).scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var labels: some View {
        HStack {
            tag("A", configA.name, highlighted: mode == .flip && !showingB)
            Spacer()
            if mode != .flip || showingB { tag("B", configB.name, highlighted: mode == .flip) }
        }
        .padding(8)
    }

    private func tag(_ side: String, _ name: String, highlighted: Bool) -> some View {
        Text("\(side) · \(name)")
            .font(.caption.bold())
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(highlighted ? .yellow : .white)
    }

    private func wipeHandle(in size: CGSize) -> some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 1.5)
            Circle().fill(.white).frame(width: 28, height: 28)
                .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.black))
        }
        .frame(width: 44)
        .contentShape(Rectangle())
        .position(x: size.width * wipe, y: size.height / 2)
        .frame(height: size.height)
        .gesture(DragGesture().onChanged { value in
            wipe = min(max(value.location.x / size.width, 0), 1)
        })
    }

    /// The fitted picture's frame in the compare area, for mapping taps to the image.
    private func pictureFrame(in size: CGSize) -> CGRect? {
        // In detail the pictures are the crop; otherwise the whole image.
        let shown = images.compactMap { $0?.size }.first
        guard let imageSize = detail ? shown : (baseSize ?? shown) else { return nil }
        let area = mode == .split ? CGSize(width: size.width, height: (size.height - 2) / 2) : size
        let scale = min(area.width / imageSize.width, area.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (area.width - fitted.width) / 2, y: (area.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Double-tap: look at the tapped point at full resolution, or go back.
    private func toggleDetail(at location: CGPoint, in size: CGSize) {
        if detail {
            detail = false
            return
        }
        guard let frame = pictureFrame(in: size) else { return }
        baseSize = images.compactMap { $0?.size }.first
        // In split view the lower picture maps the same way as the upper one.
        let y = mode == .split && location.y > size.height / 2 ? location.y - size.height / 2 - 1 : location.y
        detailCenter = CGPoint(x: min(max((location.x - frame.minX) / frame.width, 0), 1),
                               y: min(max((y - frame.minY) / frame.height, 0), 1))
        detail = true
    }

    /// Drag to move around in detail; renders again where it's let go.
    private func detailPan(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { _ in if panStart == nil { panStart = detailCenter } }
            .onEnded { value in
                guard let start = panStart, let region, let frame = pictureFrame(in: size) else { panStart = nil; return }
                panStart = nil
                detailCenter = CGPoint(x: min(max(start.x - value.translation.width / frame.width * region.width, 0), 1),
                                       y: min(max(start.y - value.translation.height / frame.height * region.height, 0), 1))
            }
    }

    // MARK: Controls

    private var sourceMenu: some View {
        Menu {
            Picker("Source", selection: $source) {
                if let photo {
                    Label("This photo", systemImage: "photo").tag(LabSource.photo(photo))
                }
                ForEach(TestChart.allCases) { chart in
                    Label(chart.name, systemImage: "square.grid.3x3.square").tag(LabSource.chart(chart))
                }
            }
        } label: {
            Label(source.name, systemImage: "photo.stack")
                .labelStyle(.titleAndIcon)
        }
        .onChange(of: source) {
            detail = false
            baseSize = nil
            images = [nil, nil]
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .chart(let chart) = source {
                Text(chart.summary).font(.caption).foregroundStyle(.secondary)
            }

            Picker("Compare", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            ResponseCurves(curves: curves)
                .frame(height: 120)

            VStack(alignment: .leading, spacing: 6) {
                Text("Stages").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(FilmPipeline.Stages.named, id: \.name) { entry in
                            let on = stages.contains(entry.stage)
                            Button(entry.name) {
                                if on { stages.remove(entry.stage) } else { stages.insert(entry.stage) }
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(on ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(on ? .primary : .secondary)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack {
                Picker("Editing", selection: $editing) {
                    ForEach(Side.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                configMenu
            }

            ConfigControls(settings: binding(editing).settings)
        }
        .font(.footnote)
    }

    private var configMenu: some View {
        Menu {
            Section("Load") {
                Button("Neutral") { load(LabConfig.neutral) }
                ForEach(LabConfig.presets) { preset in
                    Button(preset.name) { load(preset) }
                }
            }
            if !store.configs.isEmpty {
                Section("Saved") {
                    ForEach(store.configs) { saved in
                        Button(saved.name) { set(editing, saved) }
                    }
                }
            }
            Section {
                Button("Save \(editing.rawValue)…", systemImage: "square.and.arrow.down") {
                    var config = config(editing)
                    // Saving a loaded preset makes a new configuration; a saved one is updated.
                    if !store.configs.contains(where: { $0.id == config.id }) { config.id = UUID() }
                    newName = config.name
                    naming = config
                }
                Button("Copy \(editing.rawValue) to \(other.rawValue)", systemImage: "doc.on.doc") {
                    var copy = config(editing)
                    copy.id = UUID()
                    set(other, copy)
                }
                Button("Swap A and B", systemImage: "arrow.left.arrow.right") {
                    (configA, configB) = (configB, configA)
                }
                if let photo {
                    Button("Use \(editing.rawValue)'s look on this photo", systemImage: "checkmark.circle") {
                        var settings = edits.settings(for: photo)
                        settings.film = config(editing).settings.film
                        let saved = store.configs.contains { $0.id == config(editing).id }
                        settings.filmPresetID = saved ? LabConfig.savedLookPrefix + config(editing).id.uuidString
                                                      : config(editing).settings.filmPresetID
                        edits.binding(for: photo).wrappedValue = settings
                    }
                }
            }
            Section {
                if let file = store.exportFile([configA, configB] + store.configs) {
                    ShareLink(item: file) {
                        Label("Export for contact sheets", systemImage: "square.and.arrow.up")
                    }
                }
                if store.configs.contains(where: { $0.id == config(editing).id }) {
                    Button("Delete saved \(config(editing).name)", systemImage: "trash", role: .destructive) {
                        store.delete(config(editing))
                    }
                }
            }
        } label: {
            HStack {
                Text(config(editing).name).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var other: Side { editing == .a ? .b : .a }

    private func config(_ side: Side) -> LabConfig { side == .a ? configA : configB }

    private func binding(_ side: Side) -> Binding<LabConfig> { side == .a ? $configA : $configB }

    private func set(_ side: Side, _ config: LabConfig) {
        if side == .a { configA = config } else { configB = config }
    }

    /// Loads a built-in configuration's look and exposure onto this side's
    /// development, so a photo keeps its white balance and crop.
    private func load(_ config: LabConfig) {
        var loaded = config
        var settings = self.config(editing).settings
        settings.film = config.settings.film
        settings.filmPresetID = config.settings.filmPresetID
        loaded.settings = settings
        set(editing, loaded)
    }
}

/// Every parameter of one configuration.
private struct ConfigControls: View {
    @Binding var settings: DevelopSettings

    var body: some View {
        VStack(spacing: 8) {
            SliderRow("Exposure", value: $settings.exposure, in: -3...3, format: "%+.1f EV")
            if settings.film == nil {
                Button("Add a look to adjust") { settings.film = FilmLook() }
                    .frame(maxWidth: .infinity)
            } else {
                Group {
                    SliderRow("Strength", value: film(\.strength), in: 0...1, format: "%.2f")
                    SliderRow("Warmth", value: film(\.warmth), in: -1...1, format: "%+.2f")
                    SliderRow("Contrast", value: film(\.contrast), in: 0.5...1.6, format: "%.2f")
                    SliderRow("Roll-off", value: film(\.rolloff), in: 0...1, format: "%.2f")
                    SliderRow("Fade", value: film(\.fade), in: 0...0.15, format: "%.2f")
                    SliderRow("Saturation", value: film(\.saturation), in: 0...1.6, format: "%.2f")
                }
                Group {
                    SliderRow("Halation", value: film(\.halation), in: 0...1, format: "%.2f")
                    SliderRow("Bloom", value: film(\.bloom), in: 0...1, format: "%.2f")
                    SliderRow("Grain", value: film(\.grain), in: 0...1, format: "%.2f")
                    SliderRow("Grain size", value: film(\.grainSize), in: 0.5...2.5, format: "%.2f")
                    SliderRow("Vignette", value: film(\.vignette), in: 0...1, format: "%.2f")
                }
                Button("Remove look", role: .destructive) {
                    settings.film = nil
                    settings.filmPresetID = nil
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func film(_ keyPath: WritableKeyPath<FilmLook, Float>) -> Binding<Float> {
        Binding(get: { settings.film?[keyPath: keyPath] ?? 0 },
                set: {
                    settings.film?[keyPath: keyPath] = $0
                    // Edited, so no longer exactly the preset it came from.
                    settings.filmPresetID = nil
                })
    }
}

/// Display value against exposure for mid grey, per channel: neutral (grey),
/// A (solid) and B (dashed). Shows contrast, shoulder, toe, black and white
/// points, and colour casts as the channels separating.
private struct ResponseCurves: View {
    /// Neutral, A, B.
    let curves: [[SIMD3<Float>]]

    var body: some View {
        Canvas { context, size in
            let stops = RawRenderer.labCurveStops
            let span = stops.upperBound - stops.lowerBound
            func x(_ ev: Double) -> CGFloat { CGFloat((ev - stops.lowerBound) / span) * size.width }
            func y(_ value: Float) -> CGFloat { size.height * (1 - CGFloat(min(max(value, 0), 1.05)) / 1.05) }

            // Stop lines, with 0 EV (mid grey) stronger.
            for ev in Int(stops.lowerBound)...Int(stops.upperBound) {
                var line = Path()
                line.move(to: CGPoint(x: x(Double(ev)), y: 0))
                line.addLine(to: CGPoint(x: x(Double(ev)), y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(ev == 0 ? 0.6 : 0.15)), lineWidth: ev == 0 ? 1 : 0.5)
            }
            var white = Path()
            white.move(to: CGPoint(x: 0, y: y(1)))
            white.addLine(to: CGPoint(x: size.width, y: y(1)))
            context.stroke(white, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            let channels: [(KeyPath<SIMD3<Float>, Float>, Color)] = [(\.x, .red), (\.y, .green), (\.z, .blue)]
            for (index, curve) in curves.enumerated() where curve.count > 1 {
                for (channel, color) in channels {
                    var path = Path()
                    for (i, value) in curve.enumerated() {
                        let point = CGPoint(x: CGFloat(i) / CGFloat(curve.count - 1) * size.width, y: y(value[keyPath: channel]))
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    switch index {
                    case 0: context.stroke(path, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                    case 1: context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.5)
                    default: context.stroke(path, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    // Neutral is the same in every channel; draw it once.
                    if index == 0 { break }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text("Response · grey −8 to +4 EV").font(.caption2).foregroundStyle(.secondary).padding(4)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("— A   - - B   grey: neutral").font(.caption2).foregroundStyle(.secondary).padding(4)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
