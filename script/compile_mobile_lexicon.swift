import Foundation

@main struct CompileMobileLexicon {
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let temporary = output.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Lexicon.bundled(String(contentsOf: source, encoding: .utf8)).writeCompiledDatabase(to: temporary)
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: output)
        }
    }
}
