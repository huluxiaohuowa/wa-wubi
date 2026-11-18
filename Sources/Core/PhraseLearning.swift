import Foundation

public struct PhraseLearning {
    private var code = ""
    private var word = ""
    private var erasing = false
    private var committedCharacters = 0
    private var forwardingDeletion = false
    private var expires: Date = .distantPast

    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func handle(_ key: Composition.Key, from previous: Composition, to current: Composition,
                                now: Date = Date()) {
        if now > expires { reset() }
        forwardingDeletion = false
        if committedCharacters > 0 {
            if key == .backspace && !previous.active && !previous.english {
                committedCharacters -= 1
                forwardingDeletion = true
            } else {
                reset()
            }
        }
        if (key == .backspace || key == .escape), previous.mode == .wubi, previous.code.count == 4 {
            reset()
            code = previous.code
            erasing = current.active
            expires = now.addingTimeInterval(20)
        } else if erasing {
            if key == .backspace || key == .escape { erasing = current.active }
            else { reset() }
        } else if current.english || current.mode != .wubi || key == .escape {
            reset()
        }
    }

    public mutating func record(_ result: Composition.Result, lexicon: Lexicon, now: Date = Date()) -> Entry? {
        guard !forwardingDeletion, !erasing else { return nil }
        defer {
            if let automatic = result.automaticSelection, code.isEmpty {
                reset()
                code = automatic.code
                committedCharacters = automatic.word.count
                expires = now.addingTimeInterval(20)
            }
        }
        guard !code.isEmpty, committedCharacters == 0 else { return nil }
        guard now <= expires, result.handled else { reset(); return nil }
        guard !result.text.isEmpty else { return nil }
        guard result.selections.count == 1, let selection = result.selections.first,
              selection.word == result.text, selection.word.count == 1,
              lexicon.fullCode(for: selection.word) != nil else { reset(); return nil }

        word += selection.word
        if lexicon.fullCode(for: word) == code {
            let entry = Entry(word, code)
            reset()
            return entry
        }
        if word.count >= 16 { reset() }
        return nil
    }
}
