import Photos

enum PhotosExport {
    struct NoAccess: LocalizedError {
        var errorDescription: String? { "Photos access is off. Allow adding photos in Settings." }
    }

    static func save(_ data: Data, filename: String) async throws {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else { throw NoAccess() }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
        }
    }
}
