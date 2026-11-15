# What makes a photo look like film

Film isn't "raw" — it's heavily processed, just chemically. A neutral Bayer RAW render is flat, linear, and clean; film's look comes from the response of the emulsion, development, and printing/scanning. Our RAW data is actually the ideal starting point for emulating it: it's linear, scene-referred, and has highlight headroom a JPEG has thrown away.

## Ingredients, roughly in order of impact

1. **Tone curve (characteristic / H&D curve).** Film responds to log exposure with an S-curve: a soft *toe* (shadows compress gently) and a long *shoulder* (highlights roll off instead of clipping). Colour negative tolerates several stops of overexposure. Digital clips hard — this is the biggest visible difference.
2. **Colour response.** Three dye layers with overlapping spectral sensitivities → channel crosstalk, hue shifts that depend on density, and *subtractive* saturation (denser = more saturated, highlights desaturate). Each stock (and the print stock / scanner) has its own palette: warm skin, cyan-leaning shadows, muted or punchy greens, etc.
3. **Grain.** Random clusters of silver/dye clouds, not uniform Gaussian noise. Multi-scale, luminance-dependent (most visible in midtones), size tied to film speed and format.
4. **Halation.** Bright light passes through the emulsion, reflects off the base/pressure plate, and re-exposes mostly the red-sensitive layer → red-orange glow around highlights. Strong on stocks without anti-halation backing.
5. **Diffusion / softness.** Lower resolving power, no digital sharpening, slight bloom around highlights.
6. **Optics and format.** Vignetting, vintage-lens softness and CA. Shallow depth of field from a 35mm frame — *not* reproducible from a phone sensor without computational blur.
7. **Artifacts (optional).** Dust, light leaks, gate weave, frame borders. Easy to overdo.

## Ways to do it

| Approach | Fidelity | Effort |
|---|---|---|
| Hand-tuned: tone curve + colour matrix + split toning + grain + halation | Good, stylised | Low |
| 3D LUT per look (`CIColorCubeWithColorSpace`) + grain/halation passes | Good; colour depends on LUT quality | Medium |
| Spectral / physically based (datasheet curves → negative → print → scan) | Best | High |

Reference implementation for the physical approach: **spektrafilm** (Andrea Volpato, Python, open source) and its **darktable** module — models negative, print, grain, halation and scanner stages from manufacturer data. Its author notes datasheet curves alone aren't enough; empirical corrections are added on top.

## In this app (Core Image)

```
CIRAWFilter (neutral, linear)
  → exposure / white balance
  → colour: 3×3 crosstalk matrix or CIColorCubeWithColorSpace (film LUT)
  → tone: per-channel sigmoid in log exposure (Metal CIColorKernel) or CIToneCurve
  → halation: threshold highlights → Gaussian blur → tint red/orange → add
  → bloom: same, wider and neutral, low strength
  → grain: CIRandomGenerator at 1–2 scales, blurred, modulated by luminance (Metal kernel)
  → vignette: CIVignetteEffect
```

All of it runs in real time on-device. Custom kernels are written in Metal (Core Image Kernel Language is deprecated). Keep it non-destructive: the DNG stays untouched, looks are render settings, export renders a HEIC/JPEG.

Grain and halation sizes should scale with image resolution so a look is consistent between thumbnail, preview and export.
