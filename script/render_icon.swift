import AppKit

let size = NSSize(width: 36, height: 36)
let image = NSImage(size: size, flipped: false) { _ in
    NSColor.black.setStroke()
    for (x1, y1, x2, y2) in [(6.0, 30.0, 30.0, 30.0), (9, 21, 26, 21),
                             (17, 30, 13, 7), (26, 21, 25, 7), (4, 7, 32, 7)] {
        let line = NSBezierPath()
        line.lineWidth = 2.8
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: x1, y: y1))
        line.line(to: NSPoint(x: x2, y: y2))
        line.stroke()
    }
    return true
}
guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
