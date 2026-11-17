import AppKit
import CoreText

enum CandidateGlyphs {
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 4096
        return cache
    }()

    // Use the same system font and weight as the candidate window.
    private static let font = NSFont.systemFont(ofSize: 19, weight: .medium)

    static func canDisplay(_ word: String) -> Bool {
        let key = word as NSString
        if let known = cache.object(forKey: key) { return known.boolValue }

        let text = NSAttributedString(string: word, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(text)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        let available = runs.allSatisfy { run in
            // LastResort draws a placeholder with a nonzero glyph ID.
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName] as? NSFont,
                  !runFont.fontName.localizedCaseInsensitiveContains("LastResort") else { return false }
            let count = CTRunGetGlyphCount(run)
            if let glyphs = CTRunGetGlyphsPtr(run) {
                return !UnsafeBufferPointer(start: glyphs, count: count).contains(0)
            }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return !glyphs.contains(0)
        }
        cache.setObject(NSNumber(value: available), forKey: key)
        return available
    }
}
