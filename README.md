# iphone-raw

An iOS camera app that captures **Bayer RAW** DNGs — the sensor data before Apple's computational photography pipeline (Smart HDR, Deep Fusion, multi-frame noise reduction, Photographic Styles) touches it.

## Features

- Bayer RAW-only capture via `AVCapturePhotoOutput` — no processed companion image is requested
- Physical lenses only (virtual dual/triple cameras don't offer Bayer RAW)
- Saves DNGs to Photos and to the Files app (`On My iPhone › iPhone RAW`)
- Capabilities screen listing each lens's RAW formats and max resolution

## Requirements

- Physical iPhone running iOS 18+ (the simulator has no camera)
- Xcode 16+

## Build

1. Open `iphone-raw.xcodeproj` in Xcode.
2. Select the `iphone-raw` target → *Signing & Capabilities* → choose your development team (a free Apple ID works).
3. Connect your iPhone, enable Developer Mode on it (*Settings › Privacy & Security › Developer Mode*), and select it as the run destination.
4. Build and run (⌘R).

## Notes

- The live viewfinder comes from the video pipeline, so it's processed and won't match the RAW file.
- Lens shading and distortion corrections are stored as DNG opcodes rather than applied; RAW editors may apply them on import.
