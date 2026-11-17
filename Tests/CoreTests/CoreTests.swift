import Foundation
import XCTest
@testable import WubiCore

final class CoreTests: XCTestCase {
    private let lexicon = Lexicon.bundled(try! String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/wubi86.dict.yaml"), encoding: .utf8))

    func testEveryFourKeyNameOccupiesSecondSlot() {
        XCTAssertEqual(Lexicon.roots.count, 25)
        for (key, name) in Lexicon.roots {
            let code = String(repeating: String(key), count: 4)
            let candidates = lexicon.exact(code, extra: [Entry("测试词", code, weight: Int.max)],
                                           edits: [name: WordEdit(name, pinned: true, hidden: true)])
            XCTAssertEqual(candidates.dropFirst().first?.word, name, code)
            XCTAssertEqual(candidates.filter { $0.word == name }.count, 1)
            var state = Composition()
            var preferences = Preferences()
            preferences.autoCommit = true
            for _ in 0..<4 {
                XCTAssertEqual(state.handle(.letter(key), preferences: preferences) { _, code in self.lexicon.exact(code) }.text, "")
            }
            XCTAssertEqual(state.handle(.semicolon, preferences: preferences) { _, _ in [] }.text, name)
        }
    }

    func testShiftAndTemporaryEnglish() {
        var state = Composition()
        let keys: (Composition.Mode, String) -> [Candidate] = { _, code in self.lexicon.exact(code) }
        let prefs = Preferences()
        XCTAssertTrue(state.handle(.semicolon, preferences: prefs, lookup: keys).handled)
        for key in "Mac" { _ = state.handle(.letter(key), preferences: prefs, lookup: keys) }
        XCTAssertEqual(state.handle(.space, preferences: prefs, lookup: keys), .init(false, "Mac"))
        _ = state.toggleEnglish()
        XCTAssertFalse(state.handle(.letter("a"), preferences: prefs, lookup: keys).handled)
        _ = state.toggleEnglish()
        XCTAssertTrue(state.handle(.letter("a"), preferences: prefs, lookup: keys).handled)
    }

    func testTextAndSCELImport() throws {
        let tsv = "水火\tiioo\t10\ntest\t测试\t3"
        let text = try DictionaryImport.read(Data(tsv.utf8), extension: "txt", lexicon: lexicon)
        XCTAssertEqual(text.entries, [Entry("水火", "iioo", weight: 10), Entry("测试", "test", weight: 3)])
        var scel = Data(repeating: 0, count: 0x2628)
        scel.replaceSubrange(0..<8, with: [0x40, 0x15, 0, 0, 0x44, 0x43, 0x53, 1])
        scel.append(contentsOf: [1, 0, 2, 0, 0, 0, 4, 0])
        scel.append("水火".data(using: .utf16LittleEndian)!)
        scel.append(contentsOf: [0, 0])
        let words = try DictionaryImport.read(scel, extension: "scel", lexicon: lexicon)
        XCTAssertEqual(words.entries, [Entry("水火", "iioo")])
        XCTAssertThrowsError(try DictionaryImport.read(scel.dropLast(), extension: "scel", lexicon: lexicon))
    }

    func testIndependentOfflineChangesMergeAndRemovalPersists() {
        var first = Snapshot()
        var second = Snapshot()
        first.set("pref/opacity", to: Data("0.8".utf8), device: "a")
        second.set("pref/fontSize", to: Data("21".utf8), device: "b")
        second.set("personal/i/词", to: Data("词".utf8), device: "b")
        XCTAssertTrue(first.merge(second))
        first.set("personal/i/词", to: nil, device: "a")
        XCTAssertTrue(second.merge(first))
        XCTAssertNil(second.values["personal/i/词"]?.value)
        XCTAssertNotNil(second.values["personal/i/词"])
        XCTAssertEqual(second.values["pref/opacity"]?.value, Data("0.8".utf8))
        XCTAssertEqual(second.values["pref/fontSize"]?.value, Data("21".utf8))
        XCTAssertFalse(first.merge(second))
    }
}
