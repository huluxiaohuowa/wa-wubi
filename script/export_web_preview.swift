import Foundation

@main
enum ExportPreview {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let text = try String(contentsOf: source, encoding: .utf8)
        let lexicon = Lexicon.bundled(text)
        var codes = Set(Lexicon.roots.keys.map(String.init))
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let cells = line.split(separator: "\t", maxSplits: 2)
            if cells.count >= 2, Entry.validCode(String(cells[1])) {
                for length in 1...cells[1].count {
                    codes.insert(String(cells[1].prefix(length)))
                }
            }
        }
        var expected: [Character: [String: [[String]]]] = [:]
        for code in codes {
            guard let first = code.first else { continue }
            let candidates = lexicon.exact(code).prefix(9).map { [$0.word, $0.hint] }
            if !candidates.isEmpty { expected[first, default: [:]][code] = candidates }
        }
        expected["z", default: [:]]["zz"] = ["※", "—", "…", "·", "✓", "×", "→", "←", "↑"].map { [$0, ""] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try encoder.encode(Lexicon.coincidentShortcuts.sorted()).write(to: output.appendingPathComponent("shortcuts.json"), options: .atomic)
        for (key, rows) in expected {
            try encoder.encode(rows).write(to: output.appendingPathComponent("\(key).json"), options: .atomic)
        }
    }
}
