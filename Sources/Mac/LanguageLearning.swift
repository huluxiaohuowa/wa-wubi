import Foundation

enum LanguageLearning {
    static let enabledKey = "languageLearningEnabled"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func migratePreference() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) == nil else { return }
        defaults.set(CloudPredictionConfiguration.current.showsGlosses == true, forKey: enabledKey)
    }

    private static let englishGlossary = Task.detached(priority: .utility) { () -> [String: String] in
        guard let url = Bundle.main.url(forResource: "QingjianEnglishGlossary", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var glossary: [String: String] = [:]
        text.enumerateLines { line, _ in
            guard !line.hasPrefix("#") else { return }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard let source = fields.first, !source.isEmpty,
                  let translation = fields.dropFirst().first(where: { !$0.isEmpty }) else { return }
            let word = String(source)
            if glossary[word] == nil { glossary[word] = String(translation) }
        }
        return glossary
    }

    static func offlineTranslations(for words: [String], language: String) async -> [String: String] {
        guard ["英语", "英文", "english", "en"].contains(language.lowercased()) else { return [:] }
        let glossary = await englishGlossary.value
        var translations: [String: String] = [:]
        for word in words { translations[word] = glossary[word] }
        return translations
    }
}
