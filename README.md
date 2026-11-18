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

## Film Lab

For testing film looks without reference film scans.

- **In the app:** the flask button on a photo (or *Settings › Film Lab* on the camera) compares two configurations on that photo or on synthetic test charts: wipe, split or flip, every pipeline stage switchable, a response-curve plot, and double-tap for a full-resolution crop. Configurations can be saved; saved ones with a look also appear in the editor's Film tab.
- **On the Mac:** `Tools/contact-sheet.sh` renders DNGs and charts through configurations into one labelled image, using the app's own develop and film code:

  ```sh
  Tools/contact-sheet.sh -o sheet.jpg                    # all charts × built-in looks
  Tools/contact-sheet.sh -c lab-configs.json photo.dng   # configs exported from the Lab
  Tools/contact-sheet.sh --stages colour,tone charts     # only some stages
  ```
