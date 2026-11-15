import SwiftUI

/// Full-screen pager through the photos in capture order, with the edit panel.
struct PhotoViewer: View {
    let photos: [URL]
    @Binding var current: URL?
    @ObservedObject var edits: EditStore
    let onShowGrid: () -> Void
    let onDone: () -> Void

    @State private var showingEditor = false

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

            if showingEditor, let current {
                EditPanel(url: current, edits: edits)
                    .id(current)
                    .background(.bar)
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
                Button("Done", action: onDone)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if let current {
                    ShareLink(item: current)
                }
                Spacer()
                Button { showingEditor.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
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

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task {
            if image == nil {
                image = await RawRenderer.thumbnail(for: url, settings: settings)
            }
        }
        .task(id: settings) {
            // Short delay so dragging a slider doesn't queue a render per tick.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            if let rendered = await RawRenderer.render(url, settings: settings, maxPixel: 2000) {
                image = rendered
            }
        }
    }
}
