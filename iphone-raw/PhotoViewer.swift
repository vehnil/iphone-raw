import SwiftUI

/// Full-screen pager through the photos in capture order, with a filmstrip for
/// quick scrubbing and the edit panel. Swipe up on a photo to edit, down to close.
struct PhotoViewer: View {
    let photos: [URL]
    @Binding var current: URL?
    @ObservedObject var edits: EditStore
    let onShowGrid: () -> Void
    let onDone: () -> Void

    @State private var showingEditor = false
    /// The photo under the filmstrip's centre while scrubbing; the pager only moves when scrubbing ends.
    @State private var scrubbed: URL?
    @State private var pager = ScrollPosition(idType: URL.self)
    /// Direction the current drag locked to, so one gesture can't both page and open the editor.
    @State private var dragAxis: Axis?
    @State private var isZooming = false
    @State private var isExporting = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(photos, id: \.self) { url in
                        PhotoPage(url: url, settings: edits.settings(for: url), isZooming: $isZooming)
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition($pager)
            .scrollDisabled(dragAxis == .vertical || isZooming)
            .scrollIndicators(.hidden)
            .background(Color.black)
            .overlay {
                if let scrubbed {
                    ScrubPreview(url: scrubbed, settings: edits.settings(for: scrubbed))
                }
            }

            if showingEditor, let current {
                EditPanel(url: current, edits: edits)
                    .id(current)
                    .background(.bar)
                    .transition(.move(edge: .bottom))
            } else {
                Filmstrip(photos: photos, settings: photos.map(edits.settings(for:)), current: current,
                          onScrub: { scrubbed = $0 }, onSelect: { current = $0 })
                    .frame(height: FilmstripLayout.height)
                    .padding(.vertical, 6)
            }
        }
        // On the whole viewer, so a downward swipe over the edit panel closes it too.
        .simultaneousGesture(editorSwipe)
        .onAppear {
            if let current { pager.scrollTo(id: current) }
        }
        .onChange(of: pager.viewID(type: URL.self)) { _, url in
            if let url, url != current { current = url }
        }
        .onChange(of: current) { _, url in
            if let url, url != pager.viewID(type: URL.self) { pager.scrollTo(id: url) }
        }
        .task(id: current) { await prefetchThumbnails(around: current) }
        .overlay(alignment: .top) {
            if let message {
                Text(message)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onShowGrid) {
                    Image(systemName: "square.grid.3x3")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if showingEditor {
                    // Finishes editing and stays on the photo; edits are already saved.
                    Button { setEditor(false) } label: {
                        Image(systemName: "checkmark")
                    }
                } else {
                    Button("Done", action: onDone)
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if let current {
                    Menu {
                        ShareLink("Share DNG", item: current)
                        Section("Save to Photos with edits") {
                            ForEach(ExportFormat.allCases) { format in
                                Button("Save as \(format.name)") { export(current, as: format) }
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(isExporting)
                }
                Spacer()
                Button { setEditor(!showingEditor) } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
    }

    /// Swiping up opens the editor and down closes it, as soon as the drag has
    /// moved far enough. A drag locks to its first direction: vertical ones stop
    /// the pager (and put it back on the photo), horizontal ones are left alone.
    private var editorSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isZooming else { return }
                let dx = value.translation.width, dy = value.translation.height
                if dragAxis == nil {
                    dragAxis = abs(dy) > abs(dx) ? .vertical : .horizontal
                }
                guard dragAxis == .vertical else { return }
                if dy < -24, !showingEditor { setEditor(true) }
                if dy > 24, showingEditor { setEditor(false) }
            }
            .onEnded { _ in
                if dragAxis == .vertical, let current {
                    withAnimation(.snappy) { pager.scrollTo(id: current) }
                }
                dragAxis = nil
            }
    }

    /// Warms thumbnails nearest the current photo first, so scrubbing finds them ready.
    private func prefetchThumbnails(around url: URL?) async {
        guard let url, let center = photos.firstIndex(of: url) else { return }
        let nearby = photos.indices.sorted { abs($0 - center) < abs($1 - center) }.prefix(40)
        for index in nearby {
            guard !Task.isCancelled else { return }
            _ = await RawRenderer.thumbnail(for: photos[index], settings: edits.settings(for: photos[index]))
        }
    }

    private func setEditor(_ visible: Bool) {
        withAnimation(.snappy(duration: 0.25)) { showingEditor = visible }
    }

    private func export(_ url: URL, as format: ExportFormat) {
        isExporting = true
        show("Exporting \(format.name)…", for: nil)
        Task {
            defer { isExporting = false }
            guard let data = await RawRenderer.export(url, settings: edits.settings(for: url), as: format) else {
                show("Export failed")
                return
            }
            let name = url.deletingPathExtension().lastPathComponent + "." + (format.type.preferredFilenameExtension ?? format.rawValue)
            do {
                try await PhotosExport.save(data, filename: name)
                show("Saved \(format.name) to Photos")
            } catch {
                show("Couldn't save: \(error.localizedDescription)")
            }
        }
    }

    private func show(_ text: String, for seconds: Double? = 2) {
        withAnimation { message = text }
        guard let seconds else { return }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            withAnimation { if message == text { message = nil } }
        }
    }

    private var title: String {
        guard let shown = scrubbed ?? current, let date = PhotoLibrary.captureDate(of: shown) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// One photo, rendered with its settings. Shows the thumbnail while the full
/// preview renders. Pinch to zoom; letting go springs back, as in Photos.
private struct PhotoPage: View {
    let url: URL
    let settings: DevelopSettings
    @Binding var isZooming: Bool
    @State private var image: UIImage?
    @State private var zoom: Zoom?
    @State private var size = CGSize.zero
    /// Set on the first pinch, so zooming in shows full-resolution detail.
    @State private var wantsFullResolution = false

    private struct RenderRequest: Equatable {
        let settings: DevelopSettings
        let fullResolution: Bool
    }

    init(url: URL, settings: DevelopSettings, isZooming: Binding<Bool>) {
        self.url = url
        self.settings = settings
        _isZooming = isZooming
        // Start from a cached thumbnail so landing on a page never flashes empty.
        _image = State(initialValue: RawRenderer.cachedThumbnail(for: url, settings: settings))
    }
    /// Set once a full render has landed, so a slower thumbnail can't replace it.
    @State private var hasFullRender = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(zoom?.scale ?? 1)
                    .offset(zoomOffset)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(PinchZoom(zoom: $zoom) { zooming in
            isZooming = zooming
            if zooming { wantsFullResolution = true }
        })
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .onChange(of: settings) { wantsFullResolution = false }
        .task {
            guard image == nil else { return }
            let thumbnail = await RawRenderer.thumbnail(for: url, settings: settings)
            if !hasFullRender { image = thumbnail }
        }
        .task(id: RenderRequest(settings: settings, fullResolution: wantsFullResolution)) {
            // Short delay so dragging a slider doesn't queue a render per tick.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let maxPixel: CGFloat = wantsFullResolution ? .infinity : 2000
            if let rendered = await RawRenderer.render(url, settings: settings, maxPixel: maxPixel) {
                image = rendered
                hasFullRender = true
            }
        }
    }

    /// Keeps the point first pinched under the fingers as they move and spread.
    private var zoomOffset: CGSize {
        guard let zoom else { return .zero }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return CGSize(width: zoom.location.x - center.x - zoom.scale * (zoom.anchor.x - center.x),
                      height: zoom.location.y - center.y - zoom.scale * (zoom.anchor.y - center.y))
    }
}

private struct Zoom: Equatable {
    /// Where the pinch started, and where the fingers are now.
    var anchor: CGPoint
    var location: CGPoint
    var scale: CGFloat
}

/// UIKit's pinch, for the centre of the fingers, which SwiftUI's magnify gesture doesn't report.
private struct PinchZoom: UIGestureRecognizerRepresentable {
    @Binding var zoom: Zoom?
    /// Called once when a pinch starts and once when it ends.
    let onZooming: (Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        UIPinchGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        let location = context.converter.localLocation
        let scale = min(max(recognizer.scale, 0.5), 10)
        switch recognizer.state {
        case .began:
            zoom = Zoom(anchor: location, location: location, scale: scale)
            onZooming(true)
        case .changed:
            zoom?.scale = scale
            // With one finger lifted the centre jumps to the other, so hold still.
            if recognizer.numberOfTouches >= 2 { zoom?.location = location }
        default:
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { zoom = nil }
            onZooming(false)
        }
    }
}

/// What the photo area shows while scrubbing: the cached thumbnail, instantly.
/// Keeps the previous photo up if the next one isn't cached yet, so it never flashes.
private struct ScrubPreview: View {
    let url: URL
    let settings: DevelopSettings
    @State private var loaded: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image = RawRenderer.cachedThumbnail(for: url, settings: settings) ?? loaded {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }
        .task(id: url) {
            if let image = await RawRenderer.thumbnail(for: url, settings: settings) {
                loaded = image
            }
        }
    }
}
