import CoreText
import Foundation

@MainActor enum MobileCandidateGlyphs {
    private static let font = CTFontCreateUIFontForLanguage(.system, 19, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, 19, nil)
    private static let support: NSCache<NSNumber, NSNumber> = {
        let cache = NSCache<NSNumber, NSNumber>()
        cache.countLimit = 2048
        return cache
    }()

    static func clearCache() { support.removeAllObjects() }

    static func hasMissingExtensionGlyphs(in word: String) -> Bool {
        // Only probe extension characters during lookup. Visible labels still check all CJK glyphs.
        word.unicodeScalars.contains { scalar in
            !(0x4E00...0x9FFF).contains(scalar.value) && needsGlyphCheck(scalar) && !canDraw(scalar)
        }
    }

    static func missingCodePoints(in word: String) -> [UInt32] {
        word.unicodeScalars.compactMap { scalar in
            needsGlyphCheck(scalar) && !canDraw(scalar) ? scalar.value : nil
        }
    }

    private static func needsGlyphCheck(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: true
        default: false
        }
    }

    private static func canDraw(_ scalar: Unicode.Scalar) -> Bool {
        let key = NSNumber(value: scalar.value)
        if let cached = support.object(forKey: key) { return cached.boolValue }
        let supported = autoreleasepool {
            let attribute = NSAttributedString.Key(kCTFontAttributeName as String)
            let text = NSAttributedString(string: String(scalar), attributes: [attribute: font])
            let line = CTLineCreateWithAttributedString(text)
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            return runs.contains { run in
                guard CTRunGetGlyphCount(run) > 0 else { return false }
                let face = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                guard !(CTFontCopyPostScriptName(face) as String).localizedCaseInsensitiveContains("LastResort")
                else { return false }
                var glyph: CGGlyph = 0
                CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
                return glyph != 0
            }
        }
        support.setObject(NSNumber(value: supported), forKey: key)
        return supported
    }
}
