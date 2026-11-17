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
    let dark = color(0.070, 0.162, 0.143)
    let mint = color(0.75, 0.94, 0.83)
    let gold = color(0.91, 0.70, 0.40)
    if !template {
        let tile = NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 90, height: 90), xRadius: 23, yRadius: 23)
        dark.setFill()
        tile.fill()
        let edge = NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 88, height: 88), xRadius: 22, yRadius: 22)
        color(0.15, 0.29, 0.25).setStroke()
        edge.lineWidth = 1.1
        edge.stroke()
    }

    let gourd = NSBezierPath()
    gourd.move(to: NSPoint(x: 50, y: 73))
    curve(gourd, 64, 56, 60, 73, 67, 65)
    curve(gourd, 67, 48, 62, 52, 63, 50)
    curve(gourd, 72, 28, 73, 43, 76, 36)
    curve(gourd, 50, 17, 69, 19, 60, 17)
    curve(gourd, 28, 28, 40, 17, 31, 19)
    curve(gourd, 33, 48, 24, 36, 27, 43)
    curve(gourd, 36, 56, 37, 50, 38, 52)
    curve(gourd, 50, 73, 33, 65, 40, 73)
    gourd.close()
    let contour = template ? NSColor.black : mint
    if !template {
        color(0.101, 0.242, 0.199).setFill()
        gourd.fill()
    }
    contour.setStroke()
    gourd.lineWidth = template ? 5.2 : 2.8
    gourd.stroke()
    line(50, 74, 54, 82, width: template ? 5 : 2.6, ink: contour)
    if !template {
        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: 54, y: 80))
        curve(leaf, 67, 84, 57, 87, 63, 87)
        curve(leaf, 54, 80, 65, 79, 59, 77)
        leaf.close()
        gold.setFill()
        leaf.fill()
    }

    let weight: CGFloat = template ? 3.7 : 2.9
    line(41, 43, 59, 43, width: weight, ink: contour)
    line(48, 42, 46, 28, width: weight, ink: contour)
    line(41, 37, 56, 37, width: weight, ink: contour)
    line(56, 37, 55, 28, width: weight, ink: contour)
    line(37, 28, 63, 28, width: weight, ink: contour)
}

func render(size: Int, template: Bool = false) throws -> Data {
    guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: pixels) else {
        throw CocoaError(.coderInvalidValue)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(size) / (template ? 77 : 100)
    context.cgContext.scaleBy(x: scale, y: scale)
    if template { context.cgContext.translateBy(x: -11.5, y: -10.5) }
    draw(template)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = pixels.representation(using: .png, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
    }
    return png
}

try render(size: 512).write(to: output.appendingPathComponent("BrandIcon.png"))
try render(size: 36, template: true).write(to: output.appendingPathComponent("InputIcon.png"))
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size: point * scale).write(to: iconset.appendingPathComponent("icon_\(point)x\(point)\(suffix).png"))
    }
}
