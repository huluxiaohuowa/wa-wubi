import AppKit

struct Poster {
    let file: String
    let title: String
    let detail: String
}

let posters = [
    Poster(file: "iphone17-01-messages", title: "打字，就用熟悉的五笔", detail: "在常用 App 里切到 WA 五笔，输入 86 五笔编码。"),
    Poster(file: "iphone-duo-inner-01-split", title: "展开，双手打五笔", detail: "iPhone Duo 内屏左右分区，把按键放在拇指够得到的地方。"),
    Poster(file: "iphone-duo-inner-02-floating", title: "一捏，变成浮动键盘", detail: "双指捏合缩小，拖动底部手柄，把键盘挪到顺手的位置。"),
    Poster(file: "ipad13-01-files-split", title: "大屏五笔，两手都顺手", detail: "iPad 左右分区，保留熟悉的 26 键位置和清晰候选。"),
    Poster(file: "ipad13-02-settings", title: "键盘和词库，按你的习惯", detail: "可设置按键校正、自动加词，也能导入和管理自己的词库。"),
    Poster(file: "ipad13-03-files-number-pad", title: "左手找符号，右手输数字", detail: "切换符号页时，右侧数字小键盘始终在原位。")
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func draw(_ text: String, at origin: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color
    ]
    (text as NSString).draw(at: origin, withAttributes: attributes)
}

func render(_ poster: Poster, source: URL, destination: URL) throws {
    let input = source.appendingPathComponent(poster.file + ".jpg")
    guard let screenshot = NSImage(contentsOf: input),
          let original = NSBitmapImageRep(data: try Data(contentsOf: input)),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: original.pixelsWide,
                                       pixelsHigh: original.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let width = CGFloat(original.pixelsWide)
    let height = CGFloat(original.pixelsHigh)
    let landscape = width > height
    let unit = min(width / 1206, height / 1800)
    let inset = width * (landscape ? 0.065 : 0.075)
    let scaledWidth = min(width - 2 * inset, (height - 350 * unit) * width / height)
    let scaledHeight = scaledWidth * height / width
    let frame = CGRect(x: (width - scaledWidth) / 2, y: 41 * unit, width: scaledWidth, height: scaledHeight)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    let background = NSGradient(starting: color(0x38243F), ending: color(0x1D1726))
    background?.draw(in: canvas, angle: -72)

    let textX = frame.minX
    let top = height - 67 * unit
    draw("WA 五笔", at: CGPoint(x: textX, y: top - 31 * unit),
         size: 34 * unit, weight: .semibold, color: color(0xD8EEA9))
    draw(poster.title, at: CGPoint(x: textX, y: top - 152 * unit),
         size: (landscape ? 68 : 64) * unit, weight: .bold, color: color(0xFBF8F7))
    draw(poster.detail, at: CGPoint(x: textX, y: top - 216 * unit),
         size: (landscape ? 34 : 30) * unit, weight: .medium, color: color(0xE1D8E4))

    let card = NSBezierPath(roundedRect: frame, xRadius: 25 * unit, yRadius: 25 * unit)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.46)
    shadow.shadowBlurRadius = 28 * unit
    shadow.shadowOffset = CGSize(width: 0, height: -8 * unit)
    shadow.set()
    color(0xEEE9EF).setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    card.addClip()
    screenshot.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.91]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: destination.appendingPathComponent(poster.file + ".jpg"), options: .atomic)
}

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift script/make_ios_posters.swift SCREENSHOT_DIR POSTER_DIR\n", stderr)
    exit(2)
}
let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for poster in posters {
    try render(poster, source: source, destination: destination)
}
