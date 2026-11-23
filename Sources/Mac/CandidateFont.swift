import CoreText
import SwiftUI

enum CandidateFont {
    struct Face {
        let name: String
        let characters: CharacterSet
    }

    private static let simplifiedFace = systemFace(named: "PingFangSC-Medium")
    private static let traditionalFace = systemFace(named: "PingFangTC-Medium")
    private static let bundledFaces = Bundle.main.url(forResource: "WAWubiHan", withExtension: "ttc")
        .map(loadFaces) ?? []

    private static func systemFace(named name: String) -> Face? {
        let font = CTFontCreateWithName(name as CFString, 19, nil)
        guard CTFontCopyPostScriptName(font) as String == name else { return nil }
        return Face(name: name, characters: CTFontCopyCharacterSet(font) as CharacterSet)
    }

    static func loadFaces(from url: URL) -> [Face] {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return descriptors.map { descriptor in
            let font = CTFontCreateWithFontDescriptor(descriptor, 19, nil)
            return Face(name: CTFontCopyPostScriptName(font) as String,
                        characters: CTFontCopyCharacterSet(font) as CharacterSet)
        }
    }

    static func label(_ word: String, size: Double, traditional: Bool = false) -> AttributedString {
        let preferred = traditional ? traditionalFace : simplifiedFace
        var label = AttributedString()
        var run = ""
        var runName: String?
        for character in word {
            let name = character.unicodeScalars.first.flatMap { first in
                if first.properties.isIdeographic, let preferred, preferred.characters.contains(first) {
                    return preferred.name
                }
                // The bundled collection splits rare characters across multiple faces.
                return bundledFaces.first { $0.characters.contains(first) }?.name
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
