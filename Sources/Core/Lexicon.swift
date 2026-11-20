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

public struct Candidate: Hashable, Codable, Sendable {
    public enum Source: String, Codable, Sendable { case cloud, pinyin }

    public let word: String
    public let hint: String
    public let source: Source?
    public var isCloud: Bool { source == .cloud }

    public init(_ word: String, hint: String = "", source: Source? = nil) {
        self.word = word
        self.hint = hint
        self.source = source
    }

    // A saved candidate order identifies display entries independently of their lookup source.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.word == rhs.word && lhs.hint == rhs.hint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(word)
        hasher.combine(hint)
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

    public static let coincidentShortcuts: Set<String> = ["a", "w"]

    private let table: [String: [Entry]]
    private let stems: [String: String]
    private let sortedCodes: [String]
    private let fixedWords: Set<String>
    private let existingCodes: [String: String]
    private let database: LexiconDatabase?

    public init(_ entries: [Entry], stems suppliedStems: [String: String] = [:]) {
        database = nil
        table = Dictionary(grouping: entries, by: \.code).mapValues { $0.sorted { $0.weight > $1.weight } }
        sortedCodes = table.keys.sorted()
        fixedWords = Set(Self.roots.values).union(entries.lazy.filter { $0.code.count == 1 }.map(\.word))
        var canonical: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if let currentIndex = canonical[entry.word] {
                let current = entries[currentIndex]
                if entry.code.count < current.code.count { continue }
                if entry.code.count == current.code.count &&
                    (entry.weight < current.weight || (entry.weight == current.weight && entry.code >= current.code)) { continue }
            }
            canonical[entry.word] = index
        }
        existingCodes = canonical.mapValues { entries[$0].code }
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

    public init?(compiledAt url: URL) {
        guard let database = LexiconDatabase(url) else { return nil }
        self.database = database
        table = [:]
        sortedCodes = []
        stems = [:]
        existingCodes = [:]
        fixedWords = Set(Self.roots.values).union(
            "abcdefghijklmnopqrstuvwxyz".flatMap { database.entries(for: String($0)).map(\.word) }
        )
    }

    #if os(macOS)
    func writeCompiledDatabase(to url: URL) throws {
        try LexiconDatabase.write(to: url, entries: table, words: existingCodes, stems: stems, pinyin: pinyinIndex())
    }
    #endif

    public static func bundled(_ text: String) -> Lexicon {
        var rows: [Entry] = []
        var stems: [String: String] = [:]
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex
            let line = text[start..<end]
            start = end < text.endIndex ? text.index(after: end) : end
            guard !line.hasPrefix("#") else { continue }
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

    public func existingCode(for word: String) -> String? { database?.code(for: word) ?? existingCodes[word] }

    public func fullCode(for word: String) -> String? {
        fullCode(for: word) { database?.stem(for: $0) ?? stems[$0] }
    }

    private func fullCode(for word: String, stem: (String) -> String?) -> String? {
        if word.count == 1 { return stem(word) }
        let chars = word.map(String.init)
        guard chars.count >= 2 else { return nil }
        let parts = chars.count <= 3 ? chars : Array(chars.prefix(3)) + [chars[chars.count - 1]]
        let codes = parts.compactMap(stem)
        guard codes.count == parts.count else { return nil }
        switch codes.count {
        case 2: return String(codes[0].prefix(2)) + String(codes[1].prefix(2))
        case 3: return String(codes[0].prefix(1)) + String(codes[1].prefix(1)) + String(codes[2].prefix(2))
        default: return codes.map { String($0.prefix(1)) }.joined()
        }
    }

    public func exact(_ code: String, extra: [Entry] = [], edits: [String: WordEdit] = [:],
                      includeContinuations: Bool = true) -> [Candidate] {
        let base = database?.entries(for: code) ?? table[code, default: []]
        let preferred = edits.values.filter { $0.pinned && !$0.hidden }.sorted { $0.word < $1.word }
        var seen = Set<String>()
        var words = (preferred.map(\.word) + base.map(\.word) + extra.map(\.word)).filter {
            edits[$0]?.hidden != true && seen.insert($0).inserted
        }
        let root = code.first.flatMap { Self.roots[$0] }
        if let root, let first = code.first, code.count == 4, code.allSatisfy({ $0 == first }) {
            words.removeAll { $0 == root }
            words.insert(root, at: 0)
            return words.map { Candidate($0) }
        }

        let shortRoot = code.count == 1 ? root : nil
        if let shortRoot { words.removeAll { $0 == shortRoot } }
        var candidates = words.map { Candidate($0) }
        if includeContinuations || (shortRoot != nil && candidates.isEmpty) {
            var exactWords = Set(words)
            if let shortRoot { exactWords.insert(shortRoot) }
            let hints = continuationCandidates(for: code, excluding: exactWords, edits: edits)
            if includeContinuations {
                candidates += hints
            } else if let first = hints.first {
                candidates.append(Candidate(first.word))
            }
        }
        if let shortRoot {
            if candidates.isEmpty && Self.protectedShortcutCount(for: code) == 2 { candidates.append(Candidate(code)) }
            let position = Self.protectedShortcutCount(for: code) - 1
            candidates.insert(Candidate(shortRoot), at: position)
        }
        return candidates
    }

    private func continuationCandidates(for prefix: String, excluding: Set<String>,
                                        edits: [String: WordEdit]) -> [Candidate] {
        guard (1...3).contains(prefix.count) else { return [] }
        if let database {
            var results: [Candidate] = []
            var code = ""
            var suffix = ""
            var seen = Set<String>()
            database.visitContinuations(for: prefix) { entry in
                if entry.code != code {
                    code = entry.code
                    suffix = String(code.dropFirst(prefix.count))
                    seen.removeAll(keepingCapacity: true)
                }
                if !excluding.contains(entry.word), edits[entry.word]?.hidden != true,
                   seen.insert(entry.word).inserted {
                    results.append(Candidate(entry.word, hint: suffix))
                }
                return results.count < 72
            }
            return results
        }
        var lower = 0
        var upper = sortedCodes.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sortedCodes[middle] < prefix { lower = middle + 1 }
            else { upper = middle }
        }
        var results: [Candidate] = []
        for code in sortedCodes[lower...] {
            guard code.hasPrefix(prefix) else { break }
            guard code.count > prefix.count else { continue }
            let suffix = String(code.dropFirst(prefix.count))
            var seen = Set<String>()
            for entry in table[code, default: []] where !excluding.contains(entry.word) &&
              edits[entry.word]?.hidden != true && seen.insert(entry.word).inserted {
                results.append(Candidate(entry.word, hint: suffix))
                if results.count == 72 { return results }
            }
        }
        return results
    }

    public static func protectedShortcutCount(for code: String) -> Int {
        guard code.count == 1, let key = code.first, roots[key] != nil else { return 0 }
        return coincidentShortcuts.contains(code) ? 1 : 2
    }

    public func isFixedWord(_ word: String) -> Bool { fixedWords.contains(word) }

    public func canMoveCandidate(_ candidate: Candidate, at index: Int, code: String) -> Bool {
        !candidate.isCloud && index >= Self.protectedShortcutCount(for: code) && !isFixedWord(candidate.word)
    }

    public func manualOrder(in candidates: [Candidate], code: String, moving source: Int, to target: Int) -> [Candidate]? {
        let positions = candidates.indices.filter { canMoveCandidate(candidates[$0], at: $0, code: code) }
        guard source != target, let from = positions.firstIndex(of: source),
              let to = positions.firstIndex(of: target) else { return nil }
        var order = positions.map { candidates[$0] }
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        return order
    }

    public func applyingManualOrder(_ order: [Candidate], to candidates: [Candidate], code: String) -> [Candidate] {
        guard !order.isEmpty else { return candidates }
        let ranks = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        let positions = candidates.indices.filter {
            canMoveCandidate(candidates[$0], at: $0, code: code) && ranks[candidates[$0]] != nil
        }
        let sorted = positions.map { candidates[$0] }.sorted { ranks[$0, default: 0] < ranks[$1, default: 0] }
        var result = candidates
        for (position, candidate) in zip(positions, sorted) { result[position] = candidate }
        return result
    }

    public func ranked(_ candidates: [Candidate], code: String, scores: [String: Int],
                       edits: [String: WordEdit], includesFixed: Bool) -> [Candidate] {
        guard !scores.isEmpty else { return candidates }
        let positions = candidates.indices.filter { index in
            let word = candidates[index].word
            guard edits[word]?.pinned != true else { return false }
            return includesFixed || (!isFixedWord(word) && index >= Self.protectedShortcutCount(for: code))
        }
        let sorted = positions.sorted {
            let prior = scores[candidates[$0].word, default: 0]
            let next = scores[candidates[$1].word, default: 0]
            return prior == next ? $0 < $1 : prior > next
        }
        var result = candidates
        for (position, source) in zip(positions, sorted) { result[position] = candidates[source] }
        return result
    }

    /// Looks up one spelling in the bundled database without loading the full index.
    public func compiledPinyinCandidates(for code: String) -> [Candidate] {
        database?.pinyinCandidates(for: code) ?? []
    }

    public func pinyinIndex() -> [String: [Candidate]] {
        if let database { return database.pinyinIndex() }
        var words: [String: Int] = [:]
        func add(_ entry: Entry) {
            if entry.word.count <= 6 {
                words[entry.word] = max(words[entry.word, default: 0], entry.weight)
            }
        }
        for rows in table.values {
            for entry in rows.prefix(12) where entry.weight > 0 { add(entry) }
        }
        var index: [String: [Candidate]] = [:]
        for (word, _) in words.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
            guard let hint = fullCode(for: word, stem: { stems[$0] }) else { continue }
            let key = autoreleasepool {
                word.applyingTransform(.mandarinToLatin, reverse: false)?
                    .replacingOccurrences(of: "ü", with: "v")
                    .folding(options: .diacriticInsensitive, locale: Locale(identifier: "zh"))
                    .lowercased().filter { !$0.isWhitespace }
            }
            guard let key else { continue }
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
