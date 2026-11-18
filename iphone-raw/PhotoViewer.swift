import SwiftUI

/// Full-screen pager through the photos in capture order, with a filmstrip for
/// quick scrubbing and the edit panel. Swipe up on a photo to edit, down to close.
struct PhotoViewer: View {
    let photos: [URL]
    @Binding var current: URL?
    let edits: EditStore
    let onShowGrid: () -> Void
    let onDone: () -> Void

    @State private var showingEditor = false
    /// The photo under the filmstrip's centre while scrubbing; the pager only moves when scrubbing ends.
    @State private var scrubbed: URL?
    @State private var pager = ScrollPosition(idType: URL.self)
    /// Direction the current drag locked to, so one gesture can't both page and open the editor.
    @State private var dragAxis: Axis?
    @State private var isZooming = false
    @State private var showingLab = false
    @State private var isExporting = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(photos, id: \.self) { url in
                        PhotoPage(url: url, edits: edits, isCurrent: url == current, isZooming: $isZooming)
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
        .fullScreenCover(isPresented: $showingLab) {
            LabView(photo: current, edits: edits)
        }
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
                Button { showingLab = true } label: {
                    Image(systemName: "flask")
                }
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
/// preview renders. Pinch or double-tap to zoom, drag to pan while zoomed.
private struct PhotoPage: View {
    let url: URL
    /// Read here rather than passed in, so only this page redraws when its settings change.
    let edits: EditStore
    /// Whether this is the photo being viewed. Others drop their zoom.
    let isCurrent: Bool
    /// True while pinching or zoomed in, so the pager and editor swipe stay out of the way.
    @Binding var isZooming: Bool
    @State private var image: UIImage?
    @State private var zoom = Zoom()
    /// The zoom when the current pinch began.
    @State private var pinchStart: Zoom?
    /// The offset and drag translation when the current pan began (or resumed after a pinch).
    @State private var panStart: (offset: CGSize, translation: CGSize)?
    /// The point of the unzoomed photo under the fingers when the pinch began.
    @State private var pinchPoint = CGPoint.zero
    @State private var isPinching = false
    @State private var size = CGSize.zero
    /// Set on the first pinch, so zooming in shows full-resolution detail.
    @State private var wantsFullResolution = false

    private struct RenderRequest: Equatable {
        let settings: DevelopSettings
        let fullResolution: Bool
    }

    init(url: URL, edits: EditStore, isCurrent: Bool, isZooming: Binding<Bool>) {
        self.url = url
        self.edits = edits
        self.isCurrent = isCurrent
        _isZooming = isZooming
        // Start from a cached thumbnail so landing on a page never flashes empty.
        _image = State(initialValue: RawRenderer.cachedThumbnail(for: url, settings: edits.settings(for: url)))
    }

    private var settings: DevelopSettings { edits.settings(for: url) }
    /// Set once a full render has landed, so a slower thumbnail can't replace it.
    @State private var hasFullRender = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(zoom.scale)
                    .offset(zoom.offset)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(PinchZoom(onChange: pinch))
        .simultaneousGesture(pan, including: zoom.isZoomed ? .all : .none)
        .onTapGesture(count: 2, perform: toggleZoom)
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .onChange(of: isPinching || zoom.isZoomed) { _, zooming in isZooming = zooming }
        .onChange(of: isCurrent) { _, current in
            if !current { zoom = Zoom() }
        }
        .onChange(of: settings) { wantsFullResolution = zoom.isZoomed }
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

    // A point p of the unzoomed photo is shown at center + offset + scale × (p − center).
    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    /// Keeps the point first pinched under the fingers as they move and spread.
    private func pinch(_ phase: PinchZoom.Phase, scale: CGFloat, location: CGPoint?) {
        switch phase {
        case .began:
            guard let location else { return }
            pinchStart = zoom
            panStart = nil
            pinchPoint = CGPoint(x: center.x + (location.x - center.x - zoom.offset.width) / zoom.scale,
                                 y: center.y + (location.y - center.y - zoom.offset.height) / zoom.scale)
            isPinching = true
            wantsFullResolution = true
        case .changed:
            guard let start = pinchStart else { return }
            zoom.scale = min(max(start.scale * scale, 0.5), Zoom.maxScale)
            if let location { place(pinchPoint, at: location) }
        case .ended:
            pinchStart = nil
            isPinching = false
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { zoom = settled(zoom) }
        }
    }

    /// One-finger drag while zoomed, carrying on with the flick's momentum.
    private var pan: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isPinching else { return }
                let start = panStart ?? (zoom.offset, value.translation)
                panStart = start
                zoom.offset = CGSize(width: start.offset.width + value.translation.width - start.translation.width,
                                     height: start.offset.height + value.translation.height - start.translation.height)
            }
            .onEnded { value in
                guard !isPinching, let start = panStart else { return }
                panStart = nil
                var target = zoom
                target.offset = CGSize(width: start.offset.width + value.predictedEndTranslation.width - start.translation.width,
                                       height: start.offset.height + value.predictedEndTranslation.height - start.translation.height)
                withAnimation(.spring(duration: 0.4)) { zoom = settled(target) }
            }
    }

    /// Double-tap zooms in on the tapped point, or back out.
    private func toggleZoom(at location: CGPoint) {
        withAnimation(.spring(duration: 0.35)) {
            if zoom.isZoomed {
                zoom = Zoom()
            } else {
                wantsFullResolution = true
                zoom.scale = Zoom.doubleTapScale
                place(location, at: location)
                zoom = settled(zoom)
            }
        }
    }

    /// Sets the offset so `point` of the unzoomed photo shows at `location`.
    private func place(_ point: CGPoint, at location: CGPoint) {
        zoom.offset = CGSize(width: location.x - center.x - zoom.scale * (point.x - center.x),
                             height: location.y - center.y - zoom.scale * (point.y - center.y))
    }

    /// Back to the whole photo if zoomed out past it; otherwise kept from
    /// panning beyond the photo's edges.
    private func settled(_ zoom: Zoom) -> Zoom {
        guard zoom.scale > 1, let image else { return Zoom() }
        let fit = min(size.width / image.size.width, size.height / image.size.height)
        let limit = CGSize(width: max(0, (image.size.width * fit * zoom.scale - size.width) / 2),
                           height: max(0, (image.size.height * fit * zoom.scale - size.height) / 2))
        var settled = zoom
        settled.offset = CGSize(width: min(max(zoom.offset.width, -limit.width), limit.width),
                                height: min(max(zoom.offset.height, -limit.height), limit.height))
        return settled
    }
}

/// How far a page is zoomed and panned. The default is the whole photo.
private struct Zoom: Equatable {
    static let maxScale: CGFloat = 10
    static let doubleTapScale: CGFloat = 2.5

    var scale: CGFloat = 1
    var offset = CGSize.zero

    var isZoomed: Bool { scale > 1 }
}

/// UIKit's pinch, for the centre of the fingers, which SwiftUI's magnify gesture doesn't report.
private struct PinchZoom: UIGestureRecognizerRepresentable {
    enum Phase { case began, changed, ended }
    /// The phase, the fingers' scale since the pinch began, and their centre —
    /// `nil` while one finger is lifted, when the centre jumps to the other.
    let onChange: (Phase, CGFloat, CGPoint?) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPinchGestureRecognizer {
        UIPinchGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPinchGestureRecognizer, context: Context) {
        let location = recognizer.numberOfTouches >= 2 ? context.converter.localLocation : nil
        switch recognizer.state {
        case .began: onChange(.began, recognizer.scale, location)
        case .changed: onChange(.changed, recognizer.scale, location)
        default: onChange(.ended, recognizer.scale, location)
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
