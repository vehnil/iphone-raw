import SwiftUI

struct GalleryView: View {
    @StateObject private var library = PhotoLibrary()
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if library.photos.isEmpty {
                    ContentUnavailableView("No photos yet", systemImage: "camera", description: Text("RAW captures from this app show up here."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(library.photos, id: \.self) { url in
                                NavigationLink(value: url) {
                                    Thumbnail(url: url)
                                }
                                .contextMenu {
                                    ShareLink(item: url)
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        library.delete(url)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: URL.self) { PhotoDetailView(url: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { library.refresh() }
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task { image = await RawRenderer.thumbnail(for: url) }
    }
}
