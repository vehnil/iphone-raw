import Photos

enum PhotosExport {
    struct NoAccess: LocalizedError {
        var errorDescription: String? { "Photos access is off. Allow adding photos in Settings." }
    }

    static func save(_ data: Data, filename: String) async throws {
        try await requestAccess()
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options(filename))
        }
    }

    /// Saves a DNG as a RAW + HEIC pair: Photos displays `rendered` and keeps the
    /// DNG as the RAW original ("Use RAW as Original" in Photos, or any RAW editor).
    /// Without a rendering, the DNG is saved alone.
    static func saveRAW(_ dng: URL, rendered: Data?) async throws {
        try await requestAccess()
        let base = dng.deletingPathExtension().lastPathComponent
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            if let rendered {
                request.addResource(with: .photo, data: rendered, options: options(base + ".heic"))
                request.addResource(with: .alternatePhoto, fileURL: dng, options: options(dng.lastPathComponent))
            } else {
                request.addResource(with: .photo, fileURL: dng, options: options(dng.lastPathComponent))
            }
        }
    }

    private static func requestAccess() async throws {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { throw NoAccess() }
    }

    private static func options(_ filename: String) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = filename
        return options
    }
}
