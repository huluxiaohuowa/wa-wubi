import Foundation
import XCTest
@testable import WubiCore

final class CoreTests: XCTestCase {
    private let lexicon = Lexicon.bundled(try! String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/wubi86.dict.yaml"), encoding: .utf8))

    #if os(macOS)
    func testCompiledLexiconPreservesCandidatesAndLearningCodes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = Lexicon([
            Entry("你", "wq", weight: 5), Entry("您", "wq", weight: 5),
            Entry("你", "wqiy", weight: 2), Entry("好", "vb", weight: 3),
            Entry("你好", "wqvb", weight: 4), Entry("您", "wqin", weight: 2)
        ], stems: ["好": "vbg"])
        try source.writeCompiledDatabase(to: url)
        let compiled = try XCTUnwrap(Lexicon(compiledAt: url))

        XCTAssertEqual(compiled.exact("wq"), source.exact("wq"))
        XCTAssertEqual(compiled.exact("wq", includeContinuations: false).map(\.word), ["你", "您"])
        let edits = ["你": WordEdit("你", hidden: true), "好": WordEdit("好", pinned: true)]
        XCTAssertEqual(compiled.exact("wq", extra: [Entry("个人词", "wq")], edits: edits),
                       source.exact("wq", extra: [Entry("个人词", "wq")], edits: edits))
        XCTAssertEqual(compiled.existingCode(for: "你"), "wqiy")
        XCTAssertEqual(compiled.fullCode(for: "你好"), "wqvb")
        XCTAssertEqual(compiled.pinyinIndex(), source.pinyinIndex())
        XCTAssertEqual(compiled.compiledPinyinCandidates(for: "ni"), source.pinyinIndex()["ni"])
        XCTAssertTrue(compiled.compiledPinyinCandidates(for: "not-a-spelling").isEmpty)
    }
    #endif

    func testKeyNameOrderingAndSemicolon() {
        XCTAssertEqual(Lexicon.roots.count, 25)
        let keys: (Composition.Mode, String) -> [Candidate] = { _, code in self.lexicon.exact(code) }
        let prefs = Preferences()
        for (key, name) in Lexicon.roots {
            let short = String(key)
            let full = String(repeating: short, count: 4)
            let hiddenRoot = [name: WordEdit(name, pinned: true, hidden: true)]
            let shortRows = lexicon.exact(short, extra: [Entry(name, short)], edits: hiddenRoot)
            let position = ["a", "w"].contains(short) ? 0 : 1
            XCTAssertEqual(shortRows[position].word, name, short)
            XCTAssertEqual(shortRows[position].hint, "", short)
            XCTAssertEqual(shortRows.filter { $0.word == name }.count, 1, short)
            let fullRows = lexicon.exact(full, extra: [Entry(name, full)], edits: hiddenRoot)
            XCTAssertEqual(fullRows.first?.word, name, full)
            XCTAssertEqual(fullRows.filter { $0.word == name }.count, 1, full)
            var state = Composition()
            _ = state.handle(.letter(key), preferences: prefs, lookup: keys)
            XCTAssertEqual(state.handle(.semicolon, preferences: prefs, lookup: keys).text, name, short)
            for _ in 0..<4 {
                XCTAssertEqual(state.handle(.letter(key), preferences: prefs, lookup: keys).text, "")
            }
            XCTAssertEqual(state.handle(.space, preferences: prefs, lookup: keys).text, name, full)
        }
        XCTAssertEqual(lexicon.exact("i").prefix(2).map(\.word), ["不", "水"])
        XCTAssertEqual(lexicon.exact("o").prefix(2).map(\.word), ["为", "火"])
    }

    func testCandidateLearningKeepsDefaultProtectedPositions() {
        let baseline = Array(lexicon.exact("i").prefix(4))
        let name = baseline[1].word
        let related = baseline[3].word
        let scores = [name: 20, related: 10]
        let normal = lexicon.ranked(baseline, code: "i", scores: scores, edits: [:], includesFixed: false)
        XCTAssertEqual(normal.prefix(2), baseline.prefix(2))
        XCTAssertEqual(normal[2].word, related)
        let all = lexicon.ranked(baseline, code: "i", scores: scores, edits: [:], includesFixed: true)
        XCTAssertEqual(all.first?.word, name)
        let pinned = lexicon.ranked(baseline, code: "i", scores: scores,
                                    edits: [baseline[0].word: WordEdit(baseline[0].word, pinned: true)],
                                    includesFixed: true)
        XCTAssertEqual(pinned.first?.word, baseline[0].word)
    }

    func testMixedCodesAndCandidateSelectionRecords() {
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, code in self.lexicon.exact(code) }
        var state = Composition()
        let prefs = Preferences()
        for (code, expected) in [("i", "不"), ("ia", "江"), ("dwt", "秦"), ("ggtt", "五笔")] {
            for letter in code {
                _ = state.handle(.letter(letter), preferences: prefs, lookup: lookup)
                XCTAssertFalse(state.candidates.isEmpty, state.code)
            }
            let result = state.handle(.space, preferences: prefs, lookup: lookup)
            XCTAssertEqual(result.text, expected, code)
            XCTAssertEqual(result.selections.first?.code, code)
            XCTAssertEqual(result.selections.first?.word, expected)
        }
    }

    func testDeletingEmptyCodeEnglishFallbackRestoresWubiCandidates() throws {
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, code in self.lexicon.exact(code) }
        var preferences = Preferences()
        preferences.emptyToEnglish = true
        preferences.fifthKeyCommits = true
        var state = Composition()
        let mistyped = "kkskskskskskssk"
        let expected = try XCTUnwrap(lexicon.exact("kk").first)

        for letter in mistyped {
            _ = state.handle(.letter(letter), preferences: preferences, lookup: lookup)
        }
        XCTAssertEqual(state.code, mistyped)
        XCTAssertEqual(state.mode, .english)
        XCTAssertTrue(state.candidates.isEmpty)

        for length in stride(from: mistyped.count - 1, through: 1, by: -1) {
            XCTAssertTrue(state.handle(.backspace, preferences: preferences, lookup: lookup).handled)
            let prefix = String(mistyped.prefix(length))
            XCTAssertEqual(state.code, prefix)
            if length > 4 {
                XCTAssertEqual(state.mode, .english)
                XCTAssertTrue(state.candidates.isEmpty)
            } else {
                XCTAssertEqual(state.mode, .wubi)
                XCTAssertEqual(state.candidates, lexicon.exact(prefix), prefix)
            }
        }

        XCTAssertTrue(state.handle(.backspace, preferences: preferences, lookup: lookup).handled)
        XCTAssertFalse(state.active)
        for letter in "kk" {
            _ = state.handle(.letter(letter), preferences: preferences, lookup: lookup)
        }
        XCTAssertEqual(state.visible.first, expected)
    }

    func testFifthKeyStillCommitsRawEmptyCode() {
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, code in self.lexicon.exact(code) }
        var preferences = Preferences()
        preferences.fifthKeyCommits = true
        var state = Composition()
        for letter in "kksk" {
            XCTAssertTrue(state.handle(.letter(letter), preferences: preferences, lookup: lookup).text.isEmpty)
        }
        XCTAssertEqual(state.code, "kksk")
        XCTAssertTrue(state.candidates.isEmpty)

        let result = state.handle(.letter("s"), preferences: preferences, lookup: lookup)
        XCTAssertEqual(result.text, "kksk")
        XCTAssertEqual(state.code, "s")
        XCTAssertEqual(state.candidates, lexicon.exact("s"))
    }

    func testEmojiFollowsFirstCandidateAndCommitsWithoutLearning() {
        var first = Candidate("猫")
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, code in
            code == "qt" ? [first, Candidate("猿"), Candidate("狐"), Candidate("猎手"),
                            Candidate("云候选", source: .cloud)] : []
        }
        var preferences = Preferences()
        preferences.candidateCount = 4
        var state = Composition()
        for char in "qt" { _ = state.handle(.letter(char), preferences: preferences, lookup: lookup) }
        XCTAssertEqual(state.visible.map(\.word), ["猫", "猿", "狐", "🐱"])
        XCTAssertFalse(lexicon.canMoveCandidate(state.visible[3], at: 3, code: "qt"))

        first = Candidate("狗")
        state.refresh(lookup)
        XCTAssertEqual(state.visible.map(\.word), ["狗", "猿", "狐", "🐶"])
        let result = state.accept(index: 3)
        XCTAssertEqual(result.text, "🐶")
        XCTAssertTrue(result.selections.isEmpty)
    }

    func testFourWubiLettersSuggestEmojiFromEveryExactCandidate() {
        let words = [
            Candidate("独苗"), Candidate("猫"), Candidate("小猫"), Candidate("狗"),
            Candidate("熊猫", hint: "a"), Candidate("兔子", source: .pinyin),
            Candidate("苹果", source: .cloud)
        ]
        let expanded = EmojiSuggestions.adding(to: words, mode: .wubi, code: "qtal", pageSize: 9)
        XCTAssertEqual(expanded.map(\.word),
                       ["独苗", "猫", "小猫", "🐱", "🐶", "狗", "熊猫", "兔子", "苹果"])
        XCTAssertEqual(expanded.filter { !$0.isEmojiSuggestion }, words)
        XCTAssertEqual(EmojiSuggestions.adding(to: words, mode: .wubi, code: "qta", pageSize: 9), words)
        XCTAssertEqual(EmojiSuggestions.adding(to: words, mode: .pinyin, code: "long", pageSize: 9), words)

        let bundled = lexicon.exact("qnbb")
        XCTAssertEqual(bundled.first?.word, "包子")
        XCTAssertTrue(bundled.contains { $0.word == "饺子" && $0.hint.isEmpty })
        let bundledWithEmoji = EmojiSuggestions.adding(to: bundled, mode: .wubi, code: "qnbb", pageSize: 9)
        XCTAssertEqual(bundledWithEmoji.first?.word, "包子")
        XCTAssertTrue(bundledWithEmoji.prefix(9).contains { $0.word == "🥟" && $0.isEmojiSuggestion })
    }

    func testEmojiPreservesWubiShortcutsKeyNamesAndAutoCommit() {
        let rows = [Candidate("火"), Candidate("炎")]
        XCTAssertEqual(EmojiSuggestions.adding(to: rows, mode: .wubi, code: "o", pageSize: 9), rows)
        XCTAssertEqual(EmojiSuggestions.adding(to: rows, mode: .wubi, code: "oooo", pageSize: 9), rows)
        let alreadyHasEmoji = [Candidate("猫"), Candidate("🐱")]
        XCTAssertEqual(EmojiSuggestions.adding(to: alreadyHasEmoji, mode: .wubi, code: "qt", pageSize: 9), alreadyHasEmoji)
        XCTAssertTrue(EmojiSuggestions.adding(to: [], mode: .wubi, code: "kksk", pageSize: 9).isEmpty)

        var preferences = Preferences()
        preferences.autoCommit = true
        var state = Composition()
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, code in code == "qtae" ? [Candidate("猫")] : [] }
        for char in "qta" { _ = state.handle(.letter(char), preferences: preferences, lookup: lookup) }
        let result = state.handle(.letter("e"), preferences: preferences, lookup: lookup)
        XCTAssertEqual(result.text, "猫")
        XCTAssertEqual(result.automaticSelection?.word, "猫")
        XCTAssertFalse(state.active)
    }

    func testContinuousPhraseLearningUsesFullCodesAndWholeCommittedWords() {
        let words = Lexicon([
            Entry("甲", "aabc"), Entry("乙", "bbcd"), Entry("丙", "ccde"),
            Entry("丁", "ddef"), Entry("戊", "eefg")
        ])
        var learning = ContinuousPhraseLearning()
        func commit(_ text: String, maxLength: Int = 4) -> [Entry] {
            let selection = Composition.Selection(code: "z", word: text)
            return learning.record(.init(true, text, selections: [selection]), lexicon: words, maxLength: maxLength)
        }
        XCTAssertEqual(commit("甲乙"), [])
        XCTAssertEqual(commit("丙"), [Entry("甲乙丙", "abcc")])
        XCTAssertEqual(commit("丁"), [Entry("甲乙丙丁", "abcd"), Entry("丙丁", "ccdd")])
        XCTAssertEqual(commit("戊"), [Entry("丙丁戊", "cdee"), Entry("丁戊", "ddee")])

        _ = learning.record(.init(true, "，"), lexicon: words, maxLength: 4)
        XCTAssertEqual(commit("甲"), [])
        _ = learning.record(.init(false), lexicon: words, maxLength: 4)
        XCTAssertEqual(commit("乙"), [])
        XCTAssertEqual(commit("丙", maxLength: 2), [Entry("乙丙", "bbcc")])
    }

    func testMixedPinyinAndCloudSelectionsDoNotSupplyWubiLearning() throws {
        var state = Composition()
        let pinyin = Candidate("开", hint: "ga", source: .pinyin)
        let oldOrderItem = try JSONDecoder().decode(Candidate.self, from: Data(#"{"word":"开","hint":"ga"}"#.utf8))
        XCTAssertEqual(oldOrderItem, pinyin)
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, _ in
            [Candidate("开发"), pinyin, Candidate("开发计划", hint: "云联想", source: .cloud)]
        }
        let prefs = Preferences()
        _ = state.handle(.letter("g"), preferences: prefs, lookup: lookup)
        let pinyinResult = state.handle(.number(2), preferences: prefs, lookup: lookup)
        XCTAssertEqual(pinyinResult.text, "开")
        XCTAssertTrue(pinyinResult.selections.isEmpty)

        _ = state.handle(.letter("g"), preferences: prefs, lookup: lookup)
        let cloudResult = state.handle(.number(3), preferences: prefs, lookup: lookup)
        XCTAssertEqual(cloudResult.text, "开发计划")
        XCTAssertTrue(cloudResult.selections.isEmpty)

        _ = state.handle(.letter("g"), preferences: prefs, lookup: lookup)
        _ = state.handle(.forward, preferences: prefs, lookup: lookup)
        _ = state.handle(.forward, preferences: prefs, lookup: lookup)
        XCTAssertEqual(state.handle(.punctuation("，"), preferences: prefs, lookup: lookup).text, "开发")
    }

    func testInputSchemesKeepPinyinActiveBetweenWords() {
        var settings = Preferences()
        settings.mixedPinyin = true
        XCTAssertEqual(settings.inputScheme, .mixed)
        settings.inputScheme = .pinyin
        XCTAssertFalse(settings.mixedPinyin)
        var state = Composition()
        let lookup: (Composition.Mode, String) -> [Candidate] = { mode, code in
            guard mode == .pinyin, code == "ni" else { return [] }
            return [Candidate("你")]
        }
        for _ in 0..<2 {
            _ = state.handle(.letter("n"), preferences: settings, lookup: lookup)
            _ = state.handle(.letter("i"), preferences: settings, lookup: lookup)
            XCTAssertEqual(state.mode, .pinyin)
            XCTAssertEqual(state.handle(.space, preferences: settings, lookup: lookup).text, "你")
        }
        settings.inputScheme = .wubi
        _ = state.handle(.letter("n"), preferences: settings, lookup: lookup)
        XCTAssertEqual(state.mode, .wubi)
    }

    func testContinuationsAppearBeforeFullCodeWithRemainingLetters() {
        let rows = lexicon.exact("ij")
        XCTAssertEqual(rows.first?.word, "浊")
        XCTAssertGreaterThanOrEqual(rows.count, 9)
        XCTAssertTrue(rows.dropFirst().contains { !$0.hint.isEmpty })
        XCTAssertEqual(lexicon.exact("ij", includeContinuations: false), [Candidate("浊")])
        XCTAssertTrue(lexicon.exact("ggt").contains { $0.word == "五笔" && $0.hint == "t" })
    }

    func testExtendedHanStaysInCandidateOrder() {
        let words = lexicon.exact("fhw").map(\.word)
        XCTAssertEqual(Array(words.prefix(5)), ["真", "䟑", "𨝊", "𧺭", "𧻋"])
    }

    func testCandidateCountAndEnterBehavior() {
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, code in self.lexicon.exact(code) }
        var state = Composition()
        var preferences = Preferences()
        preferences.candidateCount = 9
        preferences.returnSelectsCandidate = true
        _ = state.handle(.letter("i"), preferences: preferences, lookup: lookup)
        XCTAssertEqual(state.visible.count, 9)
        XCTAssertEqual(state.handle(.returnKey, preferences: preferences, lookup: lookup).text, "不")
        preferences.fifthKeyCommits = false
        for _ in 0..<4 { _ = state.handle(.letter("i"), preferences: preferences, lookup: lookup) }
        XCTAssertTrue(state.handle(.letter("a"), preferences: preferences, lookup: lookup).text.isEmpty)
        XCTAssertEqual(state.code, "iiii")
    }

    func testUpdateTransportTriesDirectThenMirrors() async throws {
        let origin = UpdateCatalog.api
        var attempts: [String] = []
        let value = try await UpdateTransport.first(for: origin) { source in
            attempts.append(source.host ?? "")
            guard source.host == "gh-proxy.com" else { throw URLError(.cannotConnectToHost) }
            return "valid"
        }
        XCTAssertEqual(value, "valid")
        XCTAssertEqual(attempts, ["api.github.com", "ghfast.top", "gh-proxy.com"])
    }

    func testUpdateCatalogUsesVersionAndChecksAssetURL() throws {
        let digest = String(repeating: "a", count: 64)
        let json = """
        [
          {"tag_name":"v0.1.18","draft":true,"assets":[]},
          {"tag_name":"v0.1.9","draft":false,"assets":[{"name":"WA-Wubi-0.1.9.dmg",
            "browser_download_url":"https://example.com/WA-Wubi-0.1.9.dmg","size":10,"digest":"sha256:\(digest)"}]},
          {"tag_name":"v0.1.10","draft":false,"assets":[{"name":"WA-Wubi-0.1.10.dmg",
            "browser_download_url":"https://github.com/huluxiaohuowa/wa-wubi/releases/download/v0.1.10/WA-Wubi-0.1.10.dmg",
            "size":10,"digest":"sha256:\(digest)"}]}
        ]
        """
        let result = try UpdateCatalog.newest(in: Data(json.utf8), newerThan: "0.1.5")
        XCTAssertEqual(result?.version, "0.1.10")
        XCTAssertEqual(result?.sha256, digest)
        XCTAssertNil(try UpdateCatalog.newest(in: Data(json.utf8), newerThan: "0.1.10"))
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

    func testShiftCommitPreference() throws {
        var state = Composition()
        let prefs = Preferences()
        let keys: (Composition.Mode, String) -> [Candidate] = { _, _ in [Candidate("还"), Candidate("一水")] }
        for key in "gip" { _ = state.handle(.letter(key), preferences: prefs, lookup: keys) }
        XCTAssertEqual(state.shiftToggleEnglish(selectsCandidate: false).text, "gip")
        XCTAssertTrue(state.english)
        XCTAssertFalse(state.active)
        XCTAssertEqual(state.shiftToggleEnglish(selectsCandidate: true).text, "")
        for key in "gip" { _ = state.handle(.letter(key), preferences: prefs, lookup: keys) }
        _ = state.handle(.forward, preferences: prefs, lookup: keys)
        XCTAssertEqual(state.shiftToggleEnglish(selectsCandidate: true).text, "还")

        let previous = try JSONEncoder().encode(prefs)
        XCTAssertNil(try JSONDecoder().decode(Preferences.self, from: previous).shiftSelectsCandidate)
        var updated = prefs
        updated.shiftSelectsCandidate = false
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored.shiftSelectsCandidate, false)
    }

    func testFirstShiftPreferencePersistsInSnapshot() throws {
        let defaults = Preferences()
        var english = defaults
        english.shiftSelectsCandidate = false
        var snapshot = Snapshot()
        try snapshot.updatePreferences(from: defaults, to: english, device: "local")
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(snapshot))
        let shift = try XCTUnwrap(restored.values["pref/shiftSelectsCandidate"]?.value)
        XCTAssertEqual(shift, Data("false".utf8))
        XCTAssertEqual(restored.values.count, 1)
        try snapshot.updatePreferences(from: english, to: defaults, device: "local")
        let cleared = try XCTUnwrap(snapshot.values["pref/shiftSelectsCandidate"])
        XCTAssertNil(cleared.value)
    }

    func testTouchLanguageKeyPreferencePersistsSeparatelyFromShift() throws {
        var previous = Preferences()
        previous.shiftSelectsCandidate = false
        let oldData = try JSONEncoder().encode(previous)
        let oldDevice = try JSONDecoder().decode(Preferences.self, from: oldData)
        XCTAssertFalse(oldDevice.touchLanguageKeySelectsCandidate ?? false)

        var updated = oldDevice
        updated.touchLanguageKeySelectsCandidate = true
        var snapshot = Snapshot()
        try snapshot.updatePreferences(from: previous, to: updated, device: "local")
        XCTAssertEqual(snapshot.values["pref/touchLanguageKeySelectsCandidate"]?.value, Data("true".utf8))
        XCTAssertNil(snapshot.values["pref/shiftSelectsCandidate"])
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(restored.touchLanguageKeySelectsCandidate, true)
        XCTAssertEqual(restored.shiftSelectsCandidate, false)
    }

    func testLearnsPhraseOnlyAfterAbandoningMatchingCode() {
        let dictionary = Lexicon([Entry("微", "tmgt"), Entry("信", "wy"), Entry("信", "wyg"), Entry("心", "ny")])
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, code in dictionary.exact(code) }
        var composition = Composition()
        var learning = PhraseLearning()
        let prefs = Preferences()
        let now = Date()
        func key(_ value: Composition.Key) -> Entry? {
            let previous = composition
            let result = composition.handle(value, preferences: prefs, lookup: lookup)
            learning.handle(value, from: previous, to: composition, now: now)
            return learning.record(result, lexicon: dictionary, now: now)
        }
        func type(_ value: String) {
            for character in value { XCTAssertNil(key(.letter(character))) }
        }
        type("tmgt")
        XCTAssertNil(key(.space))
        type("wy")
        XCTAssertNil(key(.space))
        type("tmwy")
        for _ in 0..<4 { XCTAssertNil(key(.backspace)) }
        type("tmgt")
        XCTAssertNil(key(.space))
        type("wy")
        XCTAssertEqual(key(.space), Entry("微信", "tmwy"))
        type("tmwy")
        XCTAssertNil(key(.escape))
        type("tmgt")
        XCTAssertNil(key(.space))
        type("ny")
        XCTAssertNil(key(.space))
    }

    func testNewSettingsMergeWithOtherDevicePreferences() throws {
        let defaults = Preferences()
        var settings = defaults
        settings.learnsPhrases = true
        settings.speechConfiguration = Data("fixture".utf8)
        settings.autoCheckUpdates = false
        settings.automaticallyInstallUpdates = false
        var local = Snapshot()
        try local.updatePreferences(from: defaults, to: settings, device: "local")
        var remote = Snapshot()
        XCTAssertTrue(remote.merge(local))
        XCTAssertEqual(remote.values["pref/learnsPhrases"]?.value, Data("true".utf8))
        XCTAssertEqual(remote.values["pref/autoCheckUpdates"]?.value, Data("false".utf8))
        XCTAssertEqual(remote.values["pref/automaticallyInstallUpdates"]?.value, Data("false".utf8))
        let speech = try XCTUnwrap(remote.values["pref/speechConfiguration"]?.value)
        XCTAssertEqual(try JSONDecoder().decode(Data.self, from: speech), settings.speechConfiguration)
    }

    func testLearnsAfterDeletingAnAutomaticallyCommittedWord() {
        let dictionary = Lexicon([Entry("重创", "tgwb"), Entry("笑", "ttdu"), Entry("死", "gqx"),
                                  Entry("人", "w"), Entry("了", "b"), Entry("了", "bnh")])
        let lookup: (Composition.Mode, String) -> [Candidate] = { _, code in dictionary.exact(code) }
        var prefs = Preferences()
        prefs.autoCommit = true
        var input = Composition()
        var learning = PhraseLearning()
        let now = Date()
        func key(_ value: Composition.Key) -> (Composition.Result, Entry?) {
            let previous = input
            let result = input.handle(value, preferences: prefs, lookup: lookup)
            learning.handle(value, from: previous, to: input, now: now)
            return (result, learning.record(result, lexicon: dictionary, now: now))
        }
        var automatic = Composition.Result()
        for c in "tgwb" { automatic = key(.letter(c)).0 }
        XCTAssertEqual(automatic.automaticSelection?.word, "重创")
        XCTAssertFalse(key(.backspace).0.handled)
        XCTAssertFalse(key(.backspace).0.handled)
        for c in "ttdu" { XCTAssertNil(key(.letter(c)).1) }
        for code in ["gqx", "w"] {
            for c in code { XCTAssertNil(key(.letter(c)).1) }
            XCTAssertNil(key(.space).1)
        }
        XCTAssertNil(key(.letter("b")).1)
        XCTAssertEqual(key(.space).1, Entry("笑死人了", "tgwb"))
    }

    func testManualCandidateOrderKeepsFixedCandidatesInPlace() throws {
        let dictionary = Lexicon([Entry("不", "i"), Entry("水", "iiii")])
        let list = [Candidate("不"), Candidate("水"), Candidate("江", hint: "a"),
                    Candidate("水流", hint: "ii"), Candidate("润", hint: "ugg")]
        XCTAssertNil(dictionary.manualOrder(in: list, code: "i", moving: 0, to: 2))
        XCTAssertNil(dictionary.manualOrder(in: list, code: "i", moving: 4, to: 1))
        let order = try XCTUnwrap(dictionary.manualOrder(in: list, code: "i", moving: 4, to: 2))
        let saved = try JSONDecoder().decode([Candidate].self, from: JSONEncoder().encode(order))
        XCTAssertEqual(dictionary.applyingManualOrder(saved, to: list, code: "i"),
                       [list[0], list[1], list[4], list[2], list[3]])
        let rootCode = [Candidate("水"), Candidate("普通词"), Candidate("新词")]
        XCTAssertNil(dictionary.manualOrder(in: rootCode, code: "iiii", moving: 2, to: 0))
    }

    func testTextAndSCELImport() throws {
        let tsv = "水火\tiioo\t10\ntest\t测试\t3"
        let text = try DictionaryImport.read(Data(tsv.utf8), extension: "txt", lexicon: lexicon)
        XCTAssertEqual(text.entries, [Entry("水火", "iioo", weight: 10), Entry("测试", try XCTUnwrap(lexicon.existingCode(for: "测试")), weight: 3)])
        var scel = Data(repeating: 0, count: 0x2628)
        scel.replaceSubrange(0..<8, with: [0x40, 0x15, 0, 0, 0x44, 0x43, 0x53, 1])
        scel.append(contentsOf: [1, 0, 2, 0, 0, 0, 4, 0])
        scel.append("水火".data(using: .utf16LittleEndian)!)
        scel.append(contentsOf: [0, 0])
        let words = try DictionaryImport.read(scel, extension: "scel", lexicon: lexicon)
        XCTAssertEqual(words.entries, [Entry("水火", "iioo")])
        XCTAssertThrowsError(try DictionaryImport.read(scel.dropLast(), extension: "scel", lexicon: lexicon))
    }

    func testSogouTextAndTemporaryEnglishTools() throws {
        let phrases = "ii,1=水火\noooo,2=火"
        let imported = try DictionaryImport.read(Data(phrases.utf8), extension: "txt", lexicon: lexicon)
        XCTAssertEqual(imported.entries.map(\.code), ["iioo", "oooo"])
        XCTAssertEqual(imported.entries.map(\.word), ["水火", "火"])
        for (input, expected) in [("2026-11-17", "2026年11月17日"), ("12.45", "壹拾贰元肆角伍分")] {
            var state = Composition()
            _ = state.handle(.semicolon, preferences: Preferences()) { _, _ in [] }
            for key in input {
                _ = state.handle(.punctuation(key), preferences: Preferences()) { _, _ in [] }
            }
            XCTAssertEqual(state.handle(.returnKey, preferences: Preferences()) { _, _ in [] }.text, expected)
        }
    }

    func testImportKeepsExistingCodeForDuplicateWord() throws {
        let data = Data("水火\tzabc\t4\n水火\tzzzz\t8\naaaa\t😀".utf8)
        let result = try DictionaryImport.read(data, extension: "txt", lexicon: lexicon,
                                               preferredCodes: ["水火": "iifg"])
        XCTAssertEqual(result.entries.map(\.word), ["水火"])
        XCTAssertEqual(result.entries.map(\.code), ["iifg"])
    }

    func testSogouDirectoryParsesOfficialSearchResults() throws {
        XCTAssertTrue(try XCTUnwrap(SogouDirectory.search("法律")).absoluteString.contains("%B7%A8%C2%C9"))
        let homepage = #"<div><a href="/dict/detail/index/123/?rf=dictindex">公开词库</a><a href="/dict/cate/index/36">分类</a></div>"#
        XCTAssertEqual(SogouDirectory.parse(homepage).first?.name, "公开词库")
        XCTAssertEqual(SogouDirectory.categories(in: homepage).first?.name, "分类")
        guard let path = ProcessInfo.processInfo.environment["WAWUBI_TEST_SOGOU_SEARCH"] else { return }
        let html = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
        let rows = SogouDirectory.parse(html)
        XCTAssertGreaterThan(rows.count, 5)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(try XCTUnwrap(SogouDirectory.pageLink(in: html, label: "下一页")).absoluteString,
                       "https://pinyin.sogou.com/dict/search/search_list/%B7%A8%C2%C9/normal/2")
    }

    func testPublicSCELSampleWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["WAWUBI_TEST_SCEL"] else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let imported = try DictionaryImport.read(data, extension: "scel", lexicon: lexicon)
        XCTAssertGreaterThan(imported.entries.count, 0)
        XCTAssertTrue(imported.entries.allSatisfy { Entry.validCode($0.code) })
    }

    func testCloudResolutionUsesSelectedSideForConflicts() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        var local = Snapshot()
        var cloud = Snapshot()
        let common = "pref/opacity"
        let localOnly = "personal/a/甲"
        let cloudOnly = "personal/b/乙"
        let deleted = "personal/c/丙"
        let a = Data("a".utf8)
        let b = Data("b".utf8)
        local.set(common, to: a, device: "Mac", at: old)
        local.set(localOnly, to: a, device: "Mac", at: old)
        local.set(deleted, to: nil, device: "Mac", at: old)
        cloud.set(common, to: b, device: "iCloud", at: new)
        cloud.set(cloudOnly, to: b, device: "iCloud", at: new)
        cloud.set(deleted, to: b, device: "iCloud", at: new)

        let recent = local.resolved(with: cloud, using: .newest, device: "Mac")
        XCTAssertEqual(recent.values[common]?.value, b)
        let preferLocal = local.resolved(with: cloud, using: .local, device: "Mac")
        XCTAssertEqual(preferLocal.values[common]?.value, a)
        XCTAssertEqual(preferLocal.values[cloudOnly]?.value, b)
        XCTAssertNotNil(preferLocal.values[deleted])
        XCTAssertNil(preferLocal.values[deleted]?.value)
        let preferCloud = local.resolved(with: cloud, using: .cloud, device: "Mac")
        XCTAssertEqual(preferCloud.values[common]?.value, b)
        XCTAssertEqual(preferCloud.values[localOnly]?.value, a)
        let switched = local.resolved(with: cloud, using: .replaceWithCloud, device: "Mac")
        XCTAssertNil(switched.values[localOnly])

        XCTAssertTrue(cloud.merge(preferLocal))
        XCTAssertEqual(cloud.values[common]?.value, a)
        XCTAssertNil(cloud.values[deleted]?.value)
    }

    func testCloudPriorityCanOverrideNewerLocalValue() {
        let old = Date(timeIntervalSince1970: 10)
        let new = Date(timeIntervalSince1970: 20)
        let key = "pref/vertical"
        let first = Data("true".utf8)
        let second = Data("false".utf8)
        var local = Snapshot()
        var cloud = Snapshot()
        local.set(key, to: first, device: "Mac", at: new)
        cloud.set(key, to: second, device: "iCloud", at: old)
        XCTAssertEqual(local.resolved(with: cloud, using: .newest, device: "Mac").values[key]?.value, first)
        XCTAssertEqual(local.resolved(with: cloud, using: .cloud, device: "Mac").values[key]?.value, second)
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
