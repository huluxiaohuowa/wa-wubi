import CoreText
import SwiftUI

enum CandidateFont {
    struct Face {
        let name: String
        let characters: CharacterSet
    }

    private static let bundledFaces = Bundle.main.url(forResource: "WAWubiHan", withExtension: "ttc")
        .map(loadFaces) ?? []

    static func loadFaces(from url: URL) -> [Face] {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return descriptors.map { descriptor in
            let font = CTFontCreateWithFontDescriptor(descriptor, 19, nil)
            return Face(name: CTFontCopyPostScriptName(font) as String,
                        characters: CTFontCopyCharacterSet(font) as CharacterSet)
        }
    }

    static func label(_ word: String, size: Double) -> AttributedString {
        var label = AttributedString()
        var run = ""
        var runName: String?
        for character in word {
            // OpenType collections store different Unicode ranges in separate faces of the same font.
            let name = character.unicodeScalars.first.flatMap { first in
                bundledFaces.first { $0.characters.contains(first) }?.name
            }
            if name != runName, !run.isEmpty {
                label.append(formatted(run, font: runName, size: size))
                run = ""
            }
            run.append(character)
            runName = name
        }
        if !run.isEmpty { label.append(formatted(run, font: runName, size: size)) }
        return label
    }

    private static func formatted(_ word: String, font: String?, size: Double) -> AttributedString {
        var text = AttributedString(word)
        text.font = font.map { .custom($0, size: size) } ?? .system(size: size, weight: .medium)
        return text
    }
}
