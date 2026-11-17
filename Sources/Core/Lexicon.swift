import Foundation

public struct Entry: Hashable, Codable, Sendable {
    public let word: String
    public let code: String
    public var weight: Int

    public init(_ word: String, _ code: String, weight: Int = 0) {
        self.word = word
        self.code = code
        self.weight = weight
    }

    public static func validCode(_ code: String) -> Bool {
        (1...4).contains(code.utf8.count) && code.utf8.allSatisfy { (97...122).contains($0) }
    }
}

public struct Candidate: Equatable, Sendable {
    public let word: String
    public let hint: String

    public init(_ word: String, hint: String = "") {
        self.word = word
        self.hint = hint
    }
}

public final class Lexicon: @unchecked Sendable {
    // 86 键名按实际字母顺序。简码与键名属于两套候选规则。
    public static let roots: [Character: String] = [
        "a": "工", "b": "子", "c": "又", "d": "大", "e": "月",
        "f": "土", "g": "王", "h": "目", "i": "水", "j": "日",
        "k": "口", "l": "田", "m": "山", "n": "已", "o": "火",
        "p": "之", "q": "金", "r": "白", "s": "木", "t": "禾",
        "u": "立", "v": "女", "w": "人", "x": "纟", "y": "言",
    ]

    private let table: [String: [Entry]]
    private let stems: [String: String]

    public init(_ entries: [Entry], stems suppliedStems: [String: String] = [:]) {
        table = Dictionary(grouping: entries, by: \.code).mapValues { rows in
            rows.enumerated().sorted {
                $0.element.weight == $1.element.weight ? $0.offset < $1.offset : $0.element.weight > $1.element.weight
            }.map(\.element)
        }
        var stems = suppliedStems
        for entry in entries where entry.word.count == 1 && entry.code.count >= 2 {
            if stems[entry.word, default: ""].count < entry.code.count {
                stems[entry.word] = entry.code
            }
        }
        for (key, word) in Self.roots {
            stems[word] = String(repeating: String(key), count: 4)
        }
        self.stems = stems
    }

    public static func bundled(_ text: String) -> Lexicon {
        var rows: [Entry] = []
        var stems: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, Entry.validCode(String(fields[1])) else { continue }
            let word = String(fields[0])
            rows.append(Entry(word, String(fields[1]), weight: fields.count > 2 ? Int(fields[2]) ?? 0 : 0))
            if word.count == 1, fields.count > 3, Entry.validCode(String(fields[3])) {
                stems[word] = String(fields[3])
            }
        }
        return Lexicon(rows, stems: stems)
    }

    public func fullCode(for word: String) -> String? {
        if word.count == 1 { return stems[word] }
        let chars = word.map(String.init)
        guard chars.count >= 2 else { return nil }
        let parts = chars.count <= 3 ? chars : Array(chars.prefix(3)) + [chars[chars.count - 1]]
        let codes = parts.compactMap { stems[$0] }
        guard codes.count == parts.count else { return nil }
        switch codes.count {
        case 2: return String(codes[0].prefix(2)) + String(codes[1].prefix(2))
        case 3: return String(codes[0].prefix(1)) + String(codes[1].prefix(1)) + String(codes[2].prefix(2))
        default: return codes.map { String($0.prefix(1)) }.joined()
        }
    }

    public func exact(_ code: String, extra: [Entry] = [], edits: [String: WordEdit] = [:]) -> [Candidate] {
        let base = table[code, default: []]
        let preferred = edits.values.filter { $0.pinned && !$0.hidden }.sorted { $0.word < $1.word }
        var seen = Set<String>()
        var words = (preferred.map(\.word) + base.map(\.word) + extra.map(\.word)).filter {
            edits[$0]?.hidden != true && seen.insert($0).inserted
        }
        if let first = code.first, let root = Self.roots[first],
           code.count == 4, code.allSatisfy({ $0 == first }) {
            words.removeAll { $0 == root }
            if words.isEmpty, let short = table[String(first)]?.first(where: { $0.word != root })?.word {
                words.append(short)
            }
            if words.isEmpty {
                // A repeated key whose short code equals its key name still needs a selectable first slot.
                words.append(code)
            }
            words.insert(root, at: 1)
        }
        return words.map { Candidate($0) }
    }

    public func pinyinIndex() -> [String: [Candidate]] {
        var words: [String: Int] = [:]
        for rows in table.values {
            for entry in rows.prefix(12) where entry.weight > 0 && entry.word.count <= 6 {
                words[entry.word] = max(words[entry.word, default: 0], entry.weight)
            }
        }
        var index: [String: [Candidate]] = [:]
        for (word, _) in words.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            guard let hint = fullCode(for: word),
                  let latin = word.applyingTransform(.mandarinToLatin, reverse: false) else { continue }
            let key = latin.replacingOccurrences(of: "ü", with: "v")
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "zh"))
                .lowercased().filter { !$0.isWhitespace }
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) }) else { continue }
            if index[key, default: []].count < 40 { index[key, default: []].append(Candidate(word, hint: hint)) }
        }
        return index
    }
}

public struct WordEdit: Codable, Sendable {
    public let word: String
    public let pinned: Bool
    public let hidden: Bool
    public init(_ word: String, pinned: Bool = false, hidden: Bool = false) {
        self.word = word
        self.pinned = pinned
        self.hidden = hidden
    }
}
