import Foundation
import CoreFoundation

public enum ImportFailure: LocalizedError {
    case invalid, empty, tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalid: return "无法读取词库。请检查文件内容或编码。"
        case .empty: return "没有可导入的 86 五笔词条。"
        case .tooLarge: return "词库超过 32 MB，请拆分后导入。"
        }
    }
}

public struct ImportResult {
    public let entries: [Entry]
    public let skipped: Int
}

public enum DictionaryImport {
    public static let sizeLimit = 32 * 1024 * 1024

    public static func read(_ data: Data, extension fileExtension: String, lexicon: Lexicon) throws -> ImportResult {
        guard data.count <= sizeLimit else { throw ImportFailure.tooLarge }
        let fileExtension = fileExtension.lowercased()
        let raw: [(String, String?, Int)]
        if fileExtension == "scel" {
            raw = try scelWords(data).map { ($0, nil, 0) }
        } else {
            guard let text = decodeText(data) else { throw ImportFailure.invalid }
            raw = textRows(text, rime: fileExtension == "yaml")
        }
        var rows: [Entry] = []
        var skipped = 0
        var seen: Set<String> = []
        for (word, supplied, weight) in raw {
            guard word.count <= 64, let code = supplied ?? lexicon.fullCode(for: word),
                  Entry.validCode(code) else {
                skipped += 1
                continue
            }
            if seen.insert(code + "\t" + word).inserted { rows.append(Entry(word, code, weight: weight)) }
        }
        guard !rows.isEmpty else { throw ImportFailure.empty }
        return ImportResult(entries: rows, skipped: skipped)
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.contains("\0") {
            return utf8.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        }
        if data.prefix(256).contains(0) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }

    private static func textRows(_ text: String, rime: Bool) -> [(String, String?, Int)] {
        let lines = text.split(whereSeparator: \.isNewline)
        let body = rime && lines.contains("...") ? lines.drop(while: { $0 != "..." }).dropFirst() : lines[...]
        return body.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["),
                  trimmed != "---", trimmed != "..." else { return nil }
            if let equals = trimmed.firstIndex(of: "=") {
                let columns = trimmed[..<equals].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let word = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if let first = columns.first, Entry.validCode(first.lowercased()), !word.isEmpty,
                   columns.count == 1 || (columns.count == 2 && Int(columns[1]) != nil) {
                    let priority = columns.count == 2 ? max(0, 1000 - min(1000, max(0, Int(columns[1]) ?? 0))) : 0
                    return (word, first.lowercased(), priority)
                }
            }
            let fields = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "=" || $0 == "|" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard let first = fields.first, !first.isEmpty else { return nil }
            let second = fields.count > 1 ? fields[1] : ""
            let weight = fields.count > 2 ? Int(fields[2]) ?? 0 : Int(second) ?? 0
            if Entry.validCode(first.lowercased()), !second.isEmpty, Int(second) == nil {
                return (second, first.lowercased(), weight)
            }
            if Entry.validCode(second.lowercased()) { return (first, second.lowercased(), weight) }
            return (first, nil, weight)
        }
    }

    private static func scelWords(_ data: Data) throws -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count > 0x1544, bytes[1] == 0x15,
              Array(bytes[4..<8]) == [0x44, 0x43, 0x53, 0x01] else { throw ImportFailure.invalid }
        let offset: Int
        switch bytes[0] {
        case 0x40: offset = 0x2628
        case 0x44: offset = 0x26c4
        default: throw ImportFailure.invalid
        }
        var position = offset
        var words: [String] = []
        func word16() throws -> Int {
            guard position <= bytes.count - 2 else { throw ImportFailure.invalid }
            defer { position += 2 }
            return Int(bytes[position]) | Int(bytes[position + 1]) << 8
        }
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, position <= bytes.count - count else { throw ImportFailure.invalid }
            defer { position += count }
            return bytes[position..<(position + count)]
        }

        while position < bytes.count {
            let count = try word16()
            if count == 0, bytes[position...].allSatisfy({ $0 == 0 }) { break }
            let indexLength = try word16()
            guard count > 0, indexLength > 0, indexLength.isMultiple(of: 2) else { throw ImportFailure.invalid }
            _ = try take(indexLength)
            for _ in 0..<count {
                let length = try word16()
                guard length > 0, length.isMultiple(of: 2) else { throw ImportFailure.invalid }
                let raw = try take(length)
                let extra = try word16()
                _ = try take(extra)
                if let word = String(bytes: raw, encoding: .utf16LittleEndian), !word.isEmpty { words.append(word) }
            }
        }
        return words
    }
}
