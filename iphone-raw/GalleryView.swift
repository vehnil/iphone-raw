import SwiftUI

/// Opens on the most recent photo; swipe right for older ones, or switch to the grid.
struct GalleryView: View {
    @StateObject private var library = PhotoLibrary()
    @StateObject private var edits = EditStore()
    @Environment(\.dismiss) private var dismiss

    @State private var showingGrid = false
    @State private var current: URL?

    var body: some View {
        NavigationStack {
            Group {
                if library.photos.isEmpty {
                    ContentUnavailableView("No photos yet", systemImage: "camera", description: Text("RAW captures from this app show up here."))
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                } else if showingGrid {
                    PhotoGrid(library: library, edits: edits, onOpen: { url in
                        current = url
                        showingGrid = false
                    }, onDone: { dismiss() })
                } else {
                    PhotoViewer(photos: library.photos, current: $current, edits: edits,
                                onShowGrid: { showingGrid = true }, onDone: { dismiss() })
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            library.refresh()
            current = library.photos.last
        }
        .onChange(of: library.photos) { _, photos in
            if let current, photos.contains(current) { return }
            current = photos.last
        }
    }
}
