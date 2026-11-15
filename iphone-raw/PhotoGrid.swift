import SwiftUI

/// Chronological grid (newest at the bottom) with multi-select, bulk share and delete.
struct PhotoGrid: View {
    @ObservedObject var library: PhotoLibrary
    let edits: EditStore
    let onOpen: (URL) -> Void
    let onDone: () -> Void

    @State private var isSelecting = false
    @State private var selection: Set<URL> = []
    @State private var confirmingDelete = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(library.photos, id: \.self) { url in
                    cell(for: url)
                }
            }
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle(isSelecting ? selectionTitle : "Photos")
        .toolbar { toolbar }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(selection)
                edits.forget(selection)
                endSelecting()
            }
        } message: {
            Text("Copies already saved to Photos are not affected.")
        }
    }

    @ViewBuilder
    private func cell(for url: URL) -> some View {
        let thumbnail = Thumbnail(url: url, settings: edits.settings(for: url))
        if isSelecting {
            Button { toggle(url) } label: {
                thumbnail
                    .overlay(alignment: .bottomTrailing) {
                        SelectionMark(isSelected: selection.contains(url))
                    }
                    .opacity(selection.contains(url) ? 0.7 : 1)
            }
            .buttonStyle(.plain)
        } else {
            Button { onOpen(url) } label: { thumbnail }
                .buttonStyle(.plain)
                .contextMenu {
                    ShareLink(item: url)
                    Button("Select", systemImage: "checkmark.circle") {
                        isSelecting = true
                        selection = [url]
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        library.delete([url])
                        edits.forget([url])
                    }
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == library.photos.count ? "Deselect All" : "Select All") {
                    selection = selection.count == library.photos.count ? [] : Set(library.photos)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Cancel") { endSelecting() }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                ShareLink(items: Array(selection)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button("Select") { isSelecting = true }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? "Select Items" : "\(selection.count) Selected"
    }

    private var deleteTitle: String {
        selection.count == 1 ? "Delete 1 photo?" : "Delete \(selection.count) photos?"
    }

    private func toggle(_ url: URL) {
        if selection.contains(url) {
            selection.remove(url)
        } else {
            selection.insert(url)
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }
}

private struct Thumbnail: View {
    let url: URL
    let settings: DevelopSettings
    @State private var image: UIImage?

    init(url: URL, settings: DevelopSettings) {
        self.url = url
        self.settings = settings
        // Start from a cached thumbnail so cells don't flash grey while scrolling.
        _image = State(initialValue: RawRenderer.cachedThumbnail(for: url, settings: settings))
    }

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: settings) {
                if let rendered = await RawRenderer.thumbnail(for: url, settings: settings) {
                    image = rendered
                }
            }
    }
}

private struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, isSelected ? Color.accentColor : .black.opacity(0.3))
            .padding(6)
    }
}
