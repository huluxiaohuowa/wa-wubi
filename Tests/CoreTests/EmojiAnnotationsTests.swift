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
        let cases: [(String, String, Set<String>)] = [
            ("ifii", "潜水", ["🤿"]), ("tmbb", "笛子", ["🪈"]), ("fkwb", "吉他", ["🎸"]),
            ("frlg", "救护车", ["🚑"]), ("nuda", "飞碟", ["🛸"]), ("oomm", "火山", ["🌋"]),
            ("rult", "拼图", ["🧩"]), ("whtr", "企鹅", ["🐧"]), ("yfqu", "望远镜", ["🔭"]),
            ("awxb", "花", ["🌹", "🌸", "💐"]), ("iijs", "水果", ["🍎", "🍌", "🍉"]),
            ("qyng", "鸟", ["🐦", "🕊️", "🦜"]), ("gdrn", "天气", ["☀️", "⛅️", "☁️"]),
            ("fcfc", "运动", ["🏃", "⚽️", "🏀"]), ("qnou", "饮料", ["🥤", "🧃", "🧋"]),
            ("yeeb", "衣服", ["👕", "👔", "👗"])
        ]
        for (code, word, emojis) in cases {
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
            let shown = Set(composition.visible.filter(\.isEmojiSuggestion).map(\.word))
            XCTAssertTrue(emojis.isSubset(of: shown), "\(code) \(shown)")
        }
    }

    func testTraditionalAnnotationsAndExactWordMatching() {
        XCTAssertEqual(EmojiAnnotations.emojis(for: "拼圖").first, "🧩")
        XCTAssertEqual(EmojiAnnotations.emojis(for: "飛碟").first, "🛸")
        XCTAssertTrue(Set(["🎂", "🍰"]).isSubset(of: EmojiAnnotations.emojis(for: "蛋糕")))
        XCTAssertTrue(EmojiAnnotations.emojis(for: "潛水艇艙門").isEmpty)
    }
}
