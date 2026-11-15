# What's adjustable, and where

Two separate layers: what the camera does at capture, and how the DNG is developed afterwards.

## Capture time — `AVCaptureDevice`

Physical camera settings. These change the sensor data itself.

| Control | API | Notes |
|---|---|---|
| Shutter + ISO | `setExposureModeCustom(duration:iso:)` | Range from `activeFormat.min/maxExposureDuration`, `min/maxISO` |
| Exposure compensation | `setExposureTargetBias(_:)` | Only in auto exposure |
| Focus | `setFocusModeLocked(lensPosition:)` | 0 = near, 1 = far |
| White balance | `setWhiteBalanceModeLocked(with: gains)` | **Metadata only for Bayer RAW** — sensor data is unaffected |
| Torch / flash | `torchMode`, `AVCapturePhotoSettings.flashMode` | |

Not yet wired up in the app (next step).

## Development time — `CIRAWFilter`

Applied when rendering the DNG. Non-destructive; the file never changes.

| Control | Property | Neutral value |
|---|---|---|
| Exposure | `exposure` | 0 |
| White balance | `neutralTemperature`, `neutralTint` (or `neutralChromaticity`) | as-shot |
| Apple "boost" (tone curve) | `boostAmount`, `boostShadowAmount` | 0 |
| Local tone mapping | `localToneMapAmount` | 0 |
| Contrast | `contrastAmount` | — |
| Sharpening | `sharpnessAmount`, `detailAmount` | 0 |
| Noise reduction | `luminanceNoiseReductionAmount`, `colorNoiseReductionAmount` | 0 |
| Moiré reduction | `moireReductionAmount` | 0 |
| Lens correction | `isLensCorrectionEnabled` | off |
| Highlight / EDR headroom | `extendedDynamicRangeAmount` | 0 |
| Custom linear processing | `linearSpaceFilter` | — insert any `CIFilter` before tone mapping |

**Not a RAW parameter:** saturation, vibrance, curves, white/black point — apply with regular Core Image filters after decoding (`CIColorControls`, `CIToneCurve`, `CIVibrance`, …).

## Truly raw values

`AVCapturePhoto.pixelBuffer` on a Bayer capture is the undemosaiced mosaic (one value per photosite, ~10–14 bit). That's the lowest level available — useful for histograms, clipping checks, or a custom demosaic.
