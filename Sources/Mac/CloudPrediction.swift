import Foundation
import Security

struct CloudPredictionConfiguration: Codable, Equatable {
    var enabled = false
    var baseURL = ""
    var model = ""
    var translationLanguage = "英语"
    var showsGlosses: Bool?

    var endpoint: URL? {
        guard var url = URLComponents(string: baseURL),
              let host = url.host, !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = path.isEmpty ? "/v1" : "/" + path
        url.path = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        return url.url
    }

    var credentialOrigin: String? {
        guard let endpoint, var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = ""
        return origin.string
    }

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
    case configuration, keychain, response, http(Int)

    var errorDescription: String? {
        switch self {
        case .configuration: return "请填写有效的服务地址、模型和翻译目标语言。"
        case .keychain: return "无法保存云联想 API Key。"
        case .response: return "服务商没有返回可用结果。"
        case .http(let status): return "服务商请求失败（HTTP \(status)）。"
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

private final class NoCloudRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CloudPrediction {
    struct Input: Encodable {
        let pinyin: String?
        let candidates: [String]
        let precedingText: String
    }

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct Request: Encodable {
        let model: String
        let messages: [Message]
        let max_tokens: Int
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NoCloudRedirect(), delegateQueue: nil)
    }()

    static func suggestions(_ input: Input, config: CloudPredictionConfiguration) async throws -> [String] {
        let data = try JSONEncoder().encode(input)
        let task = input.pinyin == nil
            ? "每个候选必须从给定候选中的一个完整字词开始。"
            : "每个候选必须和所给拼音对应，可返回词语或完整句子。"
        let output = try await complete(
            instruction: "你是中文输入法。根据数据提供最多三个中文候选。\(task) 前文仅作参考，勿复述。每行一个候选，不要编号、引号或解释。没有合适的候选就留空。",
            input: String(decoding: data, as: UTF8.self), config: config, maxTokens: 160
        )
        var seen = Set(input.candidates)
        return Array(output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...48).contains(value.count),
                  value.unicodeScalars.first?.properties.isIdeographic == true,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  input.pinyin != nil || input.candidates.contains(where: { value.hasPrefix($0) }),
                  seen.insert(value).inserted else { return nil }
            return value
        }.prefix(3))
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
              !config.model.isEmpty else {
            throw CloudPredictionError.configuration
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = CloudPredictionKeychain.read(origin: origin)
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Request(model: config.model, messages: [
            Message(role: "system", content: instruction), Message(role: "user", content: input)
        ], max_tokens: maxTokens))
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudPredictionError.response }
        guard (200..<300).contains(http.statusCode) else { throw CloudPredictionError.http(http.statusCode) }
        guard let result = try? JSONDecoder().decode(Response.self, from: data),
              let text = result.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw CloudPredictionError.response }
        return String(text.prefix(4000))
    }
}
