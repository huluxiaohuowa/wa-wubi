import Foundation

public enum CandidateTheme: String, CaseIterable, Codable, Sendable {
    case system, ink, paper, indigo
}

public struct Preferences: Codable, Equatable, Sendable {
    public var theme = CandidateTheme.system
    public var punctuationOverrides: [String: String] = [:]
    public var opacity = 0.96
    public var fontSize = 19.0
    public var vertical = false
    public var shiftToggle = true
    public var semicolonSelect = true
    public var apostropheSelect = true
    public var autoCommit = false
    public var emptyToEnglish = false
    public var chinesePunctuation = true
    public var cornerQuotes = false
    public var traditional = false
    public var mixedPinyin = false
    public var cloud = false

    public init() {}
}

public struct Composition {
    public enum Mode: Equatable { case wubi, english, pinyin }
    public enum Key: Equatable {
        case letter(Character), number(Int), space, returnKey, backspace, escape
        case next, previous, forward, backward, semicolon, apostrophe, backtick, punctuation(Character)
    }
    public struct Result: Equatable {
        public var handled: Bool
        public var text: String
        public init(_ handled: Bool = true, _ text: String = "") {
            self.handled = handled
            self.text = text
        }
    }

    public private(set) var code = ""
    public private(set) var mode = Mode.wubi
    public private(set) var page = 0
    public private(set) var selected = 0
    public private(set) var candidates: [Candidate] = []
    public private(set) var last = ""
    public private(set) var english = false
    private var openDouble = true
    private var openSingle = true
    public static let pageSize = 5
    public var visible: [Candidate] { Array(candidates.dropFirst(page * Self.pageSize).prefix(Self.pageSize)) }
    public var active: Bool { !code.isEmpty || mode != .wubi }
    public var pageCount: Int { max(1, (candidates.count + Self.pageSize - 1) / Self.pageSize) }

    public init() {}

    public mutating func reset() {
        code = ""
        mode = .wubi
        page = 0
        selected = 0
        candidates = []
    }

    public mutating func refresh(_ lookup: (Mode, String) -> [Candidate]) {
        candidates = mode == .english || code.isEmpty ? [] : lookup(mode, code)
        page = min(page, pageCount - 1)
        selected = min(selected, max(0, visible.count - 1))
    }

    public mutating func toggleEnglish() -> Result {
        let result = active ? accept(index: selected) : Result()
        english.toggle()
        return result
    }

    public mutating func accept(index: Int, raw: Bool = false, fallback: Bool = true) -> Result {
        let list = visible
        let value = !raw && list.indices.contains(index) ? list[index].word : (fallback ? code : "")
        if !fallback && value.isEmpty { return Result() }
        reset()
        if !value.isEmpty { last = value }
        return Result(true, value)
    }

    public mutating func handle(_ key: Key, preferences: Preferences, lookup: (Mode, String) -> [Candidate]) -> Result {
        if english { return Result(false) }
        switch key {
        case .escape:
            guard active else { return Result(false) }
            reset()
        case .backspace:
            guard active else { return Result(false) }
            if code.isEmpty { reset() }
            else {
                code.removeLast()
                page = 0
                selected = 0
                refresh(lookup)
            }
        case .returnKey:
            if mode == .english, let converted = Self.convertEnglishTools(code) {
                reset()
                last = converted
                return Result(true, converted)
            }
            return active ? accept(index: selected, raw: true) : Result(false)
        case .space:
            if mode == .english {
                if let converted = Self.convertEnglishTools(code) {
                    reset()
                    last = converted
                    return Result(true, converted)
                }
                let result = accept(index: 0, raw: true)
                return Result(false, result.text)
            }
            return active ? accept(index: selected) : Result(false)
        case .number(let number):
            if mode == .english { code += String(number) }
            else if active, (1...Self.pageSize).contains(number) {
                return accept(index: number - 1, fallback: false)
            } else { return Result(false) }
        case .next, .previous:
            guard !candidates.isEmpty else { return Result(false) }
            page = min(pageCount - 1, max(0, page + (key == .next ? 1 : -1)))
            selected = 0
        case .forward, .backward:
            guard !candidates.isEmpty else { return Result(false) }
            let index = min(candidates.count - 1, max(0, page * Self.pageSize + selected + (key == .forward ? 1 : -1)))
            page = index / Self.pageSize
            selected = index % Self.pageSize
        case .semicolon:
            if mode == .english { code += ";" }
            else if !candidates.isEmpty, preferences.semicolonSelect { return accept(index: 1, fallback: false) }
            else if !active { mode = .english }
            else { return punctuate(";", preferences: preferences) }
        case .apostrophe:
            if mode == .english { code += "'" }
            else if !candidates.isEmpty, preferences.apostropheSelect { return accept(index: 2, fallback: false) }
            else { return punctuate("'", preferences: preferences) }
        case .backtick:
            if !active { mode = .pinyin }
            else { return punctuate("`", preferences: preferences) }
        case .punctuation(let character):
            if mode == .english { code.append(character) }
            else { return punctuate(character, preferences: preferences) }
        case .letter(let character):
            if mode == .english {
                code.append(character)
                return Result()
            }
            if !active, character.isUppercase {
                mode = .english
                code.append(character)
                return Result()
            }
            let letter = Character(character.lowercased())
            if mode == .wubi, code == "z", letter != "z", !last.isEmpty {
                let repeated = last
                reset()
                _ = handle(.letter(letter), preferences: preferences, lookup: lookup)
                return Result(true, repeated)
            }
            var prefix = ""
            if mode == .wubi, code.count == 4, !preferences.mixedPinyin || !candidates.isEmpty {
                if candidates.isEmpty, preferences.emptyToEnglish {
                    mode = .english
                    code.append(character)
                    return Result()
                }
                prefix = accept(index: selected).text
            }
            guard code.count < 32 else { return Result() }
            code.append(letter)
            page = 0
            selected = 0
            refresh(lookup)
            let keyName = code.count == 4 && code.first.map { first in
                Lexicon.roots[first] != nil && code.allSatisfy { $0 == first }
            } == true
            if mode == .wubi, preferences.autoCommit, code.count == 4, candidates.count == 1, !keyName {
                return Result(true, prefix + accept(index: 0).text)
            }
            return Result(true, prefix)
        }
        return Result()
    }

    private static func convertEnglishTools(_ text: String) -> String? {
        if text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: text), formatter.string(from: date) == text {
                let parts = text.split(separator: "-")
                if let month = Int(parts[1]), let day = Int(parts[2]) {
                    return "\(parts[0])年\(month)月\(day)日"
                }
            }
        }
        guard text.range(of: #"^\d{1,12}(\.\d{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: ".")
        guard let amount = Int(parts[0]) else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "zh_Hans")
        let digits = Array("零壹贰叁肆伍陆柒捌玖")
        let financial: [Character: Character] = [
            "〇":"零", "一":"壹", "二":"贰", "两":"贰", "三":"叁", "四":"肆", "五":"伍",
            "六":"陆", "七":"柒", "八":"捌", "九":"玖", "十":"拾", "百":"佰", "千":"仟",
        ]
        guard let regular = formatter.string(from: NSNumber(value: amount)) else { return nil }
        var upper = String(regular.map { financial[$0] ?? $0 })
        if upper.hasPrefix("拾") { upper = "壹" + upper }
        upper += "元"
        let fraction = parts.count == 2 ? Array(parts[1].compactMap(\.wholeNumberValue)) : []
        let jiao = fraction.first ?? 0
        let fen = fraction.count == 2 ? fraction[1] : 0
        if jiao > 0 { upper += String(digits[jiao]) + "角" }
        if fen > 0 { upper += (jiao == 0 && amount > 0 ? "零" : "") + String(digits[fen]) + "分" }
        if jiao == 0 && fen == 0 { upper += "整" }
        return upper
    }

    private mutating func punctuate(_ character: Character, preferences: Preferences) -> Result {
        let prefix = active ? accept(index: selected).text : ""
        guard preferences.chinesePunctuation else { return Result(false, prefix) }
        if let mark = preferences.punctuationOverrides[String(character)] {
            return Result(true, prefix + mark)
        }
        if character == "\"" {
            let mark = openDouble ? (preferences.cornerQuotes ? "「" : "“") : (preferences.cornerQuotes ? "」" : "”")
            openDouble.toggle()
            return Result(true, prefix + mark)
        }
        if character == "'" {
            let mark = openSingle ? (preferences.cornerQuotes ? "『" : "‘") : (preferences.cornerQuotes ? "』" : "’")
            openSingle.toggle()
            return Result(true, prefix + mark)
        }
        let marks: [Character: String] = [",":"，", ".":"。", ";":"；", ":":"：", "?":"？", "!":"！", "(":"（", ")":"）", "[":"【", "]":"】", "<":"《", ">":"》", "\\":"、", "^":"……", "_":"——"]
        return marks[character].map { Result(true, prefix + $0) } ?? Result(false, prefix)
    }
}
