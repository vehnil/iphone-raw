import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Synthetic scenes in scene-linear light, standing in for reference photos.
/// Each isolates something a film look has to get right. Mid grey is 0.18,
/// as in a normally exposed RAW decode.
enum TestChart: String, CaseIterable, Identifiable, Codable {
    case greyRamp = "grey-ramp"
    case colorChecker = "color-checker"
    case highlights
    case gradients

    var id: Self { self }

    var name: String {
        switch self {
        case .greyRamp: "Grey ramp"
        case .colorChecker: "Colour checker"
        case .highlights: "Highlights"
        case .gradients: "Gradients"
        }
    }

    var summary: String {
        switch self {
        case .greyRamp: "Half-stop steps from −7 to +3 EV above a smooth ramp from −8 to +4 EV: contrast, shoulder, toe, and whether greys stay neutral."
        case .colorChecker: "Classic 24-patch chart at −2, 0, +1.5 and +3 EV: colour rendering, and how colour holds up under and over exposure."
        case .highlights: "Lights from 0.5× to 32× white on a dark scene, coloured lights, a window and a thin line: halation and bloom."
        case .gradients: "Grey, skin, sky, foliage, red and blue, each from −6 to +3 EV: hue shifts, banding and clipping into highlights."
        }
    }

    /// 4:3 landscape, `longEdge` pixels wide.
    func image(longEdge: CGFloat) -> CIImage {
        let size = CGSize(width: longEdge.rounded(), height: (longEdge * 3 / 4).rounded())
        let canvas = CGRect(origin: .zero, size: size)
        switch self {
        case .greyRamp: return Self.greyRamp(canvas)
        case .colorChecker: return Self.colorChecker(canvas)
        case .highlights: return Self.highlights(canvas)
        case .gradients: return Self.gradients(canvas)
        }
    }

    // MARK: Charts

    private static func greyRamp(_ canvas: CGRect) -> CIImage {
        let margin = canvas.height * 0.08
        let rowHeight = (canvas.height - margin * 3) / 2
        let width = Int(canvas.width - margin * 2)
        let steps = 21
        let stepped = strip(width: width) { t in
            let step = min(Int(t * Double(steps)), steps - 1)
            return grey(ev: -7 + 0.5 * Double(step))
        }
        let smooth = strip(width: width) { t in grey(ev: -8 + 12 * t) }
        return [
            place(stepped, in: CGRect(x: margin, y: margin * 2 + rowHeight, width: CGFloat(width), height: rowHeight)),
            place(smooth, in: CGRect(x: margin, y: margin, width: CGFloat(width), height: rowHeight)),
        ].reduce(background(canvas, 0.03)) { $1.composited(over: $0) }
    }

    /// sRGB values of the 24 patches, as published for the X-Rite ColorChecker Classic.
    private static let checker: [(Double, Double, Double)] = [
        (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
        (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
        (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
        (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
    ]

    private static func colorChecker(_ canvas: CGRect) -> CIImage {
        let exposures: [Double] = [-2, 0, 1.5, 3]
        let gap = canvas.width * 0.03
        let chartWidth = (canvas.width - gap * 3) / 2
        let patch = chartWidth / 6
        let chartHeight = patch * 4
        let top = (canvas.height - chartHeight * 2 - gap) / 2
        var image = background(canvas, 0.03)
        for (index, ev) in exposures.enumerated() {
            let originX = gap + CGFloat(index % 2) * (chartWidth + gap)
            // Top-left chart first; Core Image's y axis points up.
            let originY = canvas.height - top - chartHeight - CGFloat(index / 2) * (chartHeight + gap)
            for (n, srgb) in checker.enumerated() {
                let scale = pow(2, ev)
                let color = (decode(srgb.0) * scale, decode(srgb.1) * scale, decode(srgb.2) * scale)
                let inset = patch * 0.06
                let rect = CGRect(x: originX + CGFloat(n % 6) * patch + inset,
                                  y: originY + CGFloat(3 - n / 6) * patch + inset,
                                  width: patch - inset * 2, height: patch - inset * 2)
                image = solid(color, rect).composited(over: image)
            }
        }
        return image
    }

    private static func highlights(_ canvas: CGRect) -> CIImage {
        let w = canvas.width, h = canvas.height
        // A dim room with a gentle falloff, so glows have something to spread over.
        var image = strip(width: Int(w)) { t in grey(ev: -3.5 - 1.5 * abs(t - 0.5)) }
        image = place(image, in: canvas)

        // Window: bright panes split by dark bars, the classic halation edge.
        let window = CGRect(x: w * 0.06, y: h * 0.42, width: w * 0.3, height: h * 0.5)
        image = solid((4, 4, 3.6), window).composited(over: image)
        for bar in [CGRect(x: window.midX - w * 0.006, y: window.minY, width: w * 0.012, height: window.height),
                    CGRect(x: window.minX, y: window.midY - w * 0.006, width: window.width, height: w * 0.012)] {
            image = solid((0.02, 0.02, 0.02), bar).composited(over: image)
        }

        // Point lights, 0.5× to 32× diffuse white.
        let intensities: [Double] = [0.5, 1, 2, 4, 8, 16, 32]
        for (i, intensity) in intensities.enumerated() {
            let center = CGPoint(x: w * (0.45 + 0.08 * CGFloat(i)), y: h * 0.78)
            image = disc(center: center, radius: w * 0.012, color: (intensity, intensity, intensity)).composited(over: image)
        }
        // Coloured lights at 8×: red, orange sodium, tungsten, green, blue, cool white.
        let colors: [(Double, Double, Double)] = [(8, 0.3, 0.2), (8, 3.5, 0.4), (8, 5, 2.6), (0.4, 8, 0.6), (0.4, 0.8, 8), (6.5, 7.5, 8)]
        for (i, color) in colors.enumerated() {
            let center = CGPoint(x: w * (0.47 + 0.08 * CGFloat(i)), y: h * 0.52)
            image = disc(center: center, radius: w * 0.018, color: color).composited(over: image)
        }
        // A thin neon line, and a lit face-toned card to see glow over a mid-tone.
        image = solid((6, 1.2, 2.4), CGRect(x: w * 0.45, y: h * 0.3, width: w * 0.48, height: max(2, h * 0.006))).composited(over: image)
        image = solid((0.34, 0.2, 0.15), CGRect(x: w * 0.06, y: h * 0.08, width: w * 0.3, height: h * 0.26)).composited(over: image)
        image = disc(center: CGPoint(x: w * 0.21, y: h * 0.21), radius: w * 0.01, color: (16, 16, 16)).composited(over: image)
        return image
    }

    private static func gradients(_ canvas: CGRect) -> CIImage {
        let hues: [(Double, Double, Double)] = [
            (1, 1, 1),            // grey
            (0.45, 0.25, 0.19),   // light skin
            (0.12, 0.2, 0.34),    // sky
            (0.09, 0.15, 0.05),   // foliage
            (0.6, 0.03, 0.03),    // saturated red
            (0.03, 0.06, 0.6),    // saturated blue
        ]
        let margin = canvas.height * 0.05
        let rowHeight = (canvas.height - margin * CGFloat(hues.count + 1)) / CGFloat(hues.count)
        let width = Int(canvas.width - margin * 2)
        var image = background(canvas, 0.03)
        for (i, hue) in hues.enumerated() {
            // Same luminance at 0 EV for every row: mid grey.
            let scale = 0.18 / (0.2126 * hue.0 + 0.7152 * hue.1 + 0.0722 * hue.2)
            let row = strip(width: width) { t in
                let k = scale * pow(2, -6 + 9 * t)
                return (hue.0 * k, hue.1 * k, hue.2 * k)
            }
            let y = canvas.height - margin - CGFloat(i + 1) * rowHeight - CGFloat(i) * margin
            image = place(row, in: CGRect(x: margin, y: y, width: CGFloat(width), height: rowHeight)).composited(over: image)
        }
        return image
    }

    // MARK: Exposure ramp for curves

    /// Mid grey from `stops.lowerBound` to `stops.upperBound` EV, one pixel per
    /// sample, for reading a look's response curve.
    static func exposureRamp(samples: Int, stops: ClosedRange<Double>) -> CIImage {
        strip(width: samples) { t in grey(ev: stops.lowerBound + (stops.upperBound - stops.lowerBound) * t) }
    }

    // MARK: Building blocks

    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static func grey(ev: Double) -> (Double, Double, Double) {
        let v = 0.18 * pow(2, ev)
        return (v, v, v)
    }

    /// sRGB 0–255 to linear.
    private static func decode(_ value: Double) -> Double {
        let c = value / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func background(_ canvas: CGRect, _ value: Double) -> CIImage {
        solid((value, value, value), canvas)
    }

    private static func solid(_ c: (Double, Double, Double), _ rect: CGRect) -> CIImage {
        // Values over 1 are fine: the working space is extended linear.
        let color = CIColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: 1, colorSpace: linear)!
        return CIImage(color: color).cropped(to: rect)
    }

    private static func disc(center: CGPoint, radius: CGFloat, color: (Double, Double, Double)) -> CIImage {
        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(radius)
        gradient.radius1 = Float(radius + 1.5)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: linear)!
        gradient.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0, colorSpace: linear)!
        // Scale the white disc to the light's intensity, keeping its soft edge in alpha.
        let tint = CIFilter.colorMatrix()
        tint.inputImage = gradient.outputImage
        tint.rVector = CIVector(x: CGFloat(color.0), y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: CGFloat(color.1), z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: CGFloat(color.2), w: 0)
        let box = CGRect(x: center.x - radius - 2, y: center.y - radius - 2, width: (radius + 2) * 2, height: (radius + 2) * 2)
        return tint.outputImage!.cropped(to: box)
    }

    /// A one-pixel-high image, `width` wide, with `color(t)` for t from 0 to 1, in linear light.
    private static func strip(width: Int, _ color: (Double) -> (Double, Double, Double)) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * 4)
        for x in 0..<width {
            let c = color(width > 1 ? Double(x) / Double(width - 1) : 0)
            pixels[x * 4] = Float(c.0)
            pixels[x * 4 + 1] = Float(c.1)
            pixels[x * 4 + 2] = Float(c.2)
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: 1),
                       format: .RGBAf, colorSpace: linear)
    }

    /// Stretches a strip to fill `rect`.
    private static func place(_ strip: CIImage, in rect: CGRect) -> CIImage {
        strip
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: rect.width / strip.extent.width, y: rect.height))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
            .cropped(to: rect)
    }
}

extension Develop {
    /// A test chart with the parts of `settings` that apply to a synthetic
    /// scene: exposure and saturation.
    static func chart(_ chart: TestChart, settings: DevelopSettings, longEdge: CGFloat) -> CIImage {
        var image = chart.image(longEdge: longEdge)
        if settings.exposure != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = settings.exposure
            image = exposure.outputImage ?? image
        }
        if settings.saturation != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.saturation = settings.saturation
            image = controls.outputImage ?? image
        }
        return image
    }
}
