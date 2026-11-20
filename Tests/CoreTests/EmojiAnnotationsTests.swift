import Foundation
import XCTest
@testable import WubiCore

final class EmojiAnnotationsTests: XCTestCase {
    func testBundledWubiCodesShowEmojiOnFirstPage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dictionary = try String(contentsOf: root.appendingPathComponent("Resources/wubi86.dict.yaml"),
                                    encoding: .utf8)
        let lexicon = Lexicon.bundled(dictionary)
        let cases = [
            ("ifii", "潜水", "🤿"), ("tmbb", "笛子", "🪈"), ("fkwb", "吉他", "🎸"),
            ("frlg", "救护车", "🚑"), ("nuda", "飞碟", "🛸"), ("oomm", "火山", "🌋"),
            ("rult", "拼图", "🧩"), ("whtr", "企鹅", "🐧"), ("yfqu", "望远镜", "🔭")
        ]
        for (code, word, emoji) in cases {
            var composition = Composition()
            var preferences = Preferences()
            preferences.autoCommit = false
            preferences.candidateCount = 9
            for letter in code {
                _ = composition.handle(.letter(letter), preferences: preferences, lookup: { _, code in
                    lexicon.exact(code)
                })
            }
            XCTAssertTrue(composition.visible.contains { $0.word == word }, code)
            XCTAssertTrue(composition.visible.contains { $0.word == emoji && $0.isEmojiSuggestion }, code)
        }
    }

    func testTraditionalAnnotationsAndExactWordMatching() {
        XCTAssertEqual(EmojiAnnotations.emoji(for: "拼圖"), "🧩")
        XCTAssertEqual(EmojiAnnotations.emoji(for: "飛碟"), "🛸")
        XCTAssertNil(EmojiAnnotations.emoji(for: "潛水艇艙門"))
    }
}
