import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// Contact sheet: one row per input (DNG or test chart), one column per
// configuration, labelled. Run through Tools/contact-sheet.sh, which builds
// this with the app's Develop, FilmPipeline and TestCharts sources.

struct Options {
    var kernels: URL?
    var output = URL(fileURLWithPath: "contact-sheet.jpg")
    var configs: URL?
    var size: CGFloat = 600
    var stages = FilmPipeline.Stages.all
    var inputs: [String] = []
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parse() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst()
    func value(_ flag: String) -> String {
        guard let next = args.popFirst() else { fail("\(flag) needs a value") }
        return next
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--kernels": options.kernels = URL(fileURLWithPath: value(arg))
        case "-o": options.output = URL(fileURLWithPath: value(arg))
        case "-c": options.configs = URL(fileURLWithPath: value(arg))
        case "-s": options.size = CGFloat(Double(value(arg)) ?? 600)
        case "--stages":
            let names = value(arg).lowercased().split(separator: ",").map(String.init)
            options.stages = FilmPipeline.Stages.named.reduce(into: []) { stages, entry in
                let name = entry.name.lowercased()
                if names.contains(name) || (name == "colour" && names.contains("color")) { stages.insert(entry.stage) }
            }
        case "charts": options.inputs += TestChart.allCases.map { "chart:\($0.rawValue)" }
        default: options.inputs.append(arg)
        }
    }
    if options.inputs.isEmpty { options.inputs = TestChart.allCases.map { "chart:\($0.rawValue)" } }
    return options
}

let options = parse()
if let kernels = options.kernels { FilmPipeline.libraryURL = kernels }
let context = CIContext(options: [.workingColorSpace: TestChart.linear])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

let configs: [LabConfig]
if let file = options.configs {
    guard let data = try? Data(contentsOf: file),
          let loaded = try? JSONDecoder().decode([LabConfig].self, from: data) else { fail("Couldn't read configs from \(file.path)") }
    configs = loaded
} else {
    configs = [LabConfig.neutral] + LabConfig.presets
}

/// The input developed with `settings` and the configuration's look, scaled to fit `size`.
func render(_ input: String, _ config: LabConfig) -> CIImage? {
    let base: CIImage?
    let seed: UInt64
    if input.hasPrefix("chart:") {
        guard let chart = TestChart(rawValue: String(input.dropFirst(6))) else { fail("Unknown chart \(input)") }
        base = Develop.chart(chart, settings: config.settings, longEdge: options.size)
        seed = Develop.hash(chart.rawValue)
    } else {
        let url = URL(fileURLWithPath: input)
        base = Develop.image(url, settings: config.settings, maxPixel: options.size, draft: false)
        seed = Develop.hash(url.lastPathComponent)
    }
    guard var image = base else { return nil }
    if let film = config.settings.film {
        image = FilmPipeline.apply(film, to: image, seed: seed, stages: options.stages)
    }
    return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
}

func label(_ text: String, size: CGFloat) -> CIImage {
    let generator = CIFilter.textImageGenerator()
    generator.text = text
    generator.fontName = "Helvetica"
    generator.fontSize = Float(size)
    generator.scaleFactor = 1
    // White, whatever colour the generator draws in.
    let white = CIFilter.colorMatrix()
    white.inputImage = generator.outputImage
    white.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    white.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    white.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
    white.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
    return white.outputImage ?? CIImage.empty()
}

let cell = options.size
let gap: CGFloat = 8
let header: CGFloat = 36
let rows = options.inputs.map { input in configs.map { render(input, $0) } }
// Rows are as tall as their tallest image (portrait photos are taller than charts).
let rowHeights = rows.map { row in row.compactMap { $0?.extent.height }.max() ?? cell * 0.75 }
let width = CGFloat(configs.count) * (cell + gap) + gap
let height = header + rowHeights.reduce(0) { $0 + $1 + gap + header } + gap

func flip(_ y: CGFloat, _ h: CGFloat) -> CGFloat { height - y - h }

var sheet = CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.08)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
func put(_ image: CIImage, x: CGFloat, top: CGFloat) {
    let moved = image.transformed(by: CGAffineTransform(translationX: x - image.extent.minX, y: flip(top, image.extent.height) - image.extent.minY))
    sheet = moved.composited(over: sheet)
}

for (column, config) in configs.enumerated() {
    put(label(config.name, size: 20), x: gap + CGFloat(column) * (cell + gap), top: 8)
}
var top = header
for (index, (input, row)) in zip(options.inputs, rows).enumerated() {
    let name = input.hasPrefix("chart:") ? (TestChart(rawValue: String(input.dropFirst(6)))?.name ?? input) : URL(fileURLWithPath: input).lastPathComponent
    put(label(name, size: 16), x: gap, top: top + 8)
    top += header
    let rowHeight = rowHeights[index]
    for (column, image) in row.enumerated() {
        guard let image else { continue }
        // Centred in its cell.
        put(image, x: gap + CGFloat(column) * (cell + gap) + (cell - image.extent.width) / 2, top: top + (rowHeight - image.extent.height) / 2)
    }
    top += rowHeight + gap
}

do {
    try FileManager.default.createDirectory(at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try context.writeJPEGRepresentation(of: sheet, to: options.output, colorSpace: sRGB,
                                        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
    print("Wrote \(options.output.path): \(options.inputs.count) inputs × \(configs.count) configs")
} catch {
    fail("Couldn't write \(options.output.path): \(error.localizedDescription)")
}
