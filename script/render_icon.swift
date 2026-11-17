import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func curve(_ path: NSBezierPath, _ x: CGFloat, _ y: CGFloat,
           _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) {
    path.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: a, y: b), controlPoint2: NSPoint(x: c, y: d))
}

func line(_ x: CGFloat, _ y: CGFloat, _ toX: CGFloat, _ toY: CGFloat, width: CGFloat, ink: NSColor) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: y))
    path.line(to: NSPoint(x: toX, y: toY))
    path.lineWidth = width
    path.lineCapStyle = .round
    ink.setStroke()
    path.stroke()
}

func draw(_ template: Bool) {
    let ink = color(0.085, 0.082, 0.17)
    let electric = color(0.77, 0.99, 0.57)
    if !template {
        let tile = NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 90, height: 90), xRadius: 22, yRadius: 22)
        ink.setFill()
        tile.fill()
    }

    let gourd = NSBezierPath()
    gourd.move(to: NSPoint(x: 52, y: 79))
    curve(gourd, 67, 60, 62, 79, 69, 70)
    curve(gourd, 71, 51, 66, 55, 68, 53)
    curve(gourd, 79, 33, 77, 46, 79, 40)
    curve(gourd, 56, 16, 79, 21, 68, 16)
    gourd.line(to: NSPoint(x: 44, y: 16))
    curve(gourd, 21, 33, 32, 16, 21, 21)
    curve(gourd, 29, 51, 21, 40, 23, 46)
    curve(gourd, 33, 60, 32, 53, 34, 55)
    curve(gourd, 48, 79, 31, 70, 38, 79)
    gourd.close()
    (template ? NSColor.black : electric).setFill()
    gourd.fill()

    let context = NSGraphicsContext.current?.cgContext
    context?.saveGState()
    if template { context?.setBlendMode(.clear) }
    let cut = template ? NSColor.black : ink
    let weight: CGFloat = template ? 5 : 4.4
    line(37, 47, 63, 47, width: weight, ink: cut)
    line(48, 47, 44, 26, width: weight, ink: cut)
    line(39, 38, 61, 38, width: weight, ink: cut)
    line(61, 38, 59, 26, width: weight, ink: cut)
    line(33, 26, 67, 26, width: weight, ink: cut)
    context?.restoreGState()
}

func render(size: Int, template: Bool = false, artwork: NSImage? = nil, normalize: Bool = false) throws -> Data {
    guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: pixels) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / (template ? 72 : 100)
    context.cgContext.scaleBy(x: scale, y: scale)
    if template { context.cgContext.translateBy(x: -14, y: -11) }
    if let artwork {
        if normalize {
            let frame = NSRect(x: 5, y: 5, width: 90, height: 90)
            let tile = NSBezierPath(roundedRect: frame, xRadius: 23, yRadius: 23)
            tile.addClip()
            color(0.95, 0.93, 0.91).setFill()
            tile.fill()
        }
        artwork.draw(in: NSRect(x: 0, y: 0, width: 100, height: 100), from: .zero, operation: .sourceOver, fraction: 1)
    } else {
        draw(template)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = pixels.representation(using: .png, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
    }
    return png
}

let brand = output.appendingPathComponent("BrandIcon.png")
if CommandLine.arguments.count == 4 {
    guard let sample = NSImage(contentsOfFile: CommandLine.arguments[3]) else { throw CocoaError(.fileReadCorruptFile) }
    try render(size: 1024, artwork: sample, normalize: true).write(to: brand)
}
guard let artwork = NSImage(contentsOf: brand) else { throw CocoaError(.fileReadCorruptFile) }
try render(size: 18, template: true).write(to: output.appendingPathComponent("InputIcon.png"))
try render(size: 36, template: true).write(to: output.appendingPathComponent("InputIcon@2x.png"))
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: point * scale, artwork: artwork).write(to: iconset.appendingPathComponent("icon_\(point)x\(point)\(suffix).png"))
    }
}
