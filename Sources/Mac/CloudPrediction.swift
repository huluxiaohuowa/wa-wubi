import Foundation
import Security
import WubiCore

struct CloudPredictionConfiguration: Codable, Equatable {
    var enabled = false
    var baseURL = ""
    var model = ""
    var translationLanguage = "英语"
    var showsGlosses: Bool?

    var endpoint: URL? { CloudCandidateService.endpoint(for: baseURL) }

    var credentialOrigin: String? { endpoint.flatMap(CloudCandidateService.credentialOrigin) }

    static var current: Self {
        guard let data = UserDefaults.standard.data(forKey: "cloudPrediction"),
              let config = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return config
    }

    static let didChange = Notification.Name("WAWubi.cloudPredictionDidChange")

    func save(key: String) throws {
        if enabled && (endpoint == nil || model.isEmpty || translationLanguage.isEmpty) {
            throw CloudPredictionError.configuration
        }
        let data = try JSONEncoder().encode(self)
        if let origin = credentialOrigin, key != CloudPredictionKeychain.read(origin: origin) {
            try CloudPredictionKeychain.save(key, origin: origin)
        }
        UserDefaults.standard.set(data, forKey: "cloudPrediction")
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

enum CloudPredictionError: LocalizedError {
    case configuration, keychain, response

    var errorDescription: String? {
        switch self {
        case .configuration: return "请填写有效的服务地址、模型和翻译目标语言。"
        case .keychain: return "无法保存云联想 API Key。"
        case .response: return "服务商没有返回可用结果。"
        }
    }
}

enum CloudPredictionKeychain {
    private static func selector(_ origin: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "top.fuluwa.inputmethod.Wubi86.cloud-prediction",
            kSecAttrAccount as String: origin,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func read(origin: String) -> String {
        var query = selector(origin)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String, origin: String) throws {
        let selector = selector(origin)
        if key.isEmpty {
            let status = SecItemDelete(selector as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudPredictionError.keychain }
            return
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(selector as CFDictionary, value as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound,
              SecItemAdd(selector.merging(value) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
            throw CloudPredictionError.keychain
        }
    }
}

enum CloudPrediction {
    typealias Input = CloudCandidateService.Input

    static func suggestions(_ input: Input, config: CloudPredictionConfiguration) async throws -> [String] {
        guard config.enabled, let endpoint = config.endpoint, let origin = config.credentialOrigin else {
            throw CloudPredictionError.configuration
        }
        return try await CloudCandidateService.suggestions(input, endpoint: endpoint, model: config.model,
                                                            key: CloudPredictionKeychain.read(origin: origin))
    }

    static func glosses(_ words: [String], config: CloudPredictionConfiguration) async throws -> [String: String] {
        let data = try JSONEncoder().encode(words)
        let output = try await complete(
            instruction: "把列表中的每个中文词译成\(config.translationLanguage)。只返回 JSON 对象，键为原词，值为一个简短译词。不要代码围栏。",
            input: String(decoding: data, as: UTF8.self), config: config, maxTokens: 256
        )
        guard let translated = try? JSONDecoder().decode([String: String].self, from: Data(output.utf8)) else {
            throw CloudPredictionError.response
        }
        return translated.filter { word, gloss in
            words.contains(word) && (1...32).contains(gloss.count) &&
                !gloss.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    static func complete(instruction: String, input: String, config: CloudPredictionConfiguration,
                         maxTokens: Int = 512) async throws -> String {
        guard config.enabled, let endpoint = config.endpoint, let origin = config.credentialOrigin,
              !config.model.isEmpty else { throw CloudPredictionError.configuration }
        return try await CloudCandidateService.complete(instruction: instruction, input: input, endpoint: endpoint,
                                                        model: config.model, key: CloudPredictionKeychain.read(origin: origin),
                                                        maxTokens: maxTokens)
    }
}
