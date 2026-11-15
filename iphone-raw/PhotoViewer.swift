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
    @State private var isExporting = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(photos, id: \.self) { url in
                        PhotoPage(url: url, settings: edits.settings(for: url))
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollIndicators(.hidden)
            .background(Color.black)
            .simultaneousGesture(editorSwipe)

            if showingEditor, let current {
                EditPanel(url: current, edits: edits)
                    .id(current)
                    .background(.bar)
                    .transition(.move(edge: .bottom))
            } else {
                Filmstrip(photos: photos, current: $current, edits: edits)
                    .padding(.vertical, 6)
            }
        }
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

    /// Vertical swipes on the photo open (up) or close (down) the editor;
    /// horizontal ones are left to the pager.
    private var editorSwipe: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            guard abs(dy) > abs(dx) * 1.5 else { return }
            setEditor(dy < 0)
        }
    }

    private func setEditor(_ visible: Bool) {
        withAnimation(.snappy) { showingEditor = visible }
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
        guard let current, let date = PhotoLibrary.captureDate(of: current) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// One photo, rendered with its settings. Shows the thumbnail while the full preview renders.
private struct PhotoPage: View {
    let url: URL
    let settings: DevelopSettings
    @State private var image: UIImage?
    /// Set once a full render has landed, so a slower thumbnail can't replace it.
    @State private var hasFullRender = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task {
            guard image == nil else { return }
            let thumbnail = await RawRenderer.thumbnail(for: url, settings: settings)
            if !hasFullRender { image = thumbnail }
        }
        .task(id: settings) {
            // Short delay so dragging a slider doesn't queue a render per tick.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            if let rendered = await RawRenderer.render(url, settings: settings, maxPixel: 2000) {
                image = rendered
                hasFullRender = true
            }
        }
    }
}

/// Photos-style scrubber: narrow slices of every photo, with the current one
/// centred and expanded to its real shape. Dragging updates the photo live as
/// each slice crosses the centre; tapping jumps; swiping the photo moves the strip.
private struct Filmstrip: View {
    let photos: [URL]
    @Binding var current: URL?
    @ObservedObject var edits: EditStore

    /// True while the user drags or flings the strip; the strip then drives `current`.
    @State private var isScrubbing = false

    static let height: CGFloat = 42
    static let sliceWidth: CGFloat = 22
    private static let spacing: CGFloat = 2
    private static let pitch = sliceWidth + spacing

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: Self.spacing) {
                        ForEach(photos, id: \.self) { url in
                            let expanded = url == current && !isScrubbing
                            StripThumbnail(url: url, settings: edits.settings(for: url), expanded: expanded)
                                .padding(.horizontal, expanded ? 6 : 0)
                                .id(url)
                                .onTapGesture { current = url }
                        }
                    }
                    // Lets the first and last photos reach the centre.
                    .padding(.horizontal, max(0, (proxy.size.width - Self.sliceWidth) / 2))
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(SliceSnapping(pitch: Self.pitch))
                .onScrollPhaseChange { _, phase in
                    let scrubbing = phase == .tracking || phase == .interacting || phase == .decelerating
                    if scrubbing != isScrubbing {
                        withAnimation(.snappy) { isScrubbing = scrubbing }
                    }
                    if phase == .idle, let current {
                        withAnimation(.snappy) { reader.scrollTo(current, anchor: .center) }
                    }
                }
                // While scrubbing every slice has the same width, so the slice
                // under the centre is just the offset divided by the pitch.
                .onScrollGeometryChange(for: Int.self) { geometry in
                    Int((geometry.contentOffset.x / Self.pitch).rounded())
                } action: { _, index in
                    guard isScrubbing else { return }
                    let url = photos[min(max(index, 0), photos.count - 1)]
                    if url != current { current = url }
                }
                .onChange(of: current) { _, url in
                    guard !isScrubbing, let url else { return }
                    withAnimation(.snappy) { reader.scrollTo(url, anchor: .center) }
                }
                .onAppear {
                    if let current { reader.scrollTo(current, anchor: .center) }
                }
            }
        }
        .frame(height: Self.height)
        .sensoryFeedback(.selection, trigger: current) { _, _ in isScrubbing }
    }
}

/// Snaps a fling so a slice ends up centred.
private struct SliceSnapping: ScrollTargetBehavior {
    let pitch: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = (target.rect.minX / pitch).rounded() * pitch
    }
}

private struct StripThumbnail: View {
    let url: URL
    let settings: DevelopSettings
    let expanded: Bool
    @State private var image: UIImage?

    private var width: CGFloat {
        guard expanded else { return Filmstrip.sliceWidth }
        let aspect = image.map { $0.size.width / $0.size.height } ?? 0.75
        return Filmstrip.height * aspect
    }

    var body: some View {
        Color.gray.opacity(0.2)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(width: width, height: Filmstrip.height)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .task(id: settings) {
                if let rendered = await RawRenderer.thumbnail(for: url, settings: settings) {
                    image = rendered
                }
            }
    }
}
