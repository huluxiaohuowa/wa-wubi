import Foundation

private final class NoCloudRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum CloudCandidateService {
    public enum Failure: LocalizedError {
        case configuration, response, http(Int)

        public var errorDescription: String? {
            switch self {
            case .configuration: return "请填写有效的服务地址和模型。"
            case .response: return "服务商没有返回可用结果。"
            case .http(let status): return "服务商请求失败（HTTP \(status)）。"
            }
        }
    }

    public static func endpoint(for baseURL: String) -> URL? {
        guard var url = URLComponents(string: baseURL),
              let host = url.host, !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = path.isEmpty ? "/v1" : "/" + path
        url.path = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        return url.url
    }

    public static func credentialOrigin(for endpoint: URL) -> String? {
        guard var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = ""
        return origin.string
    }
    public struct Input: Encodable {
        let pinyin: String?
        let candidates: [String]
        let precedingText: String

        public init(pinyin: String?, candidates: [String], precedingText: String) {
            self.pinyin = pinyin
            self.candidates = candidates
            self.precedingText = precedingText
        }
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

    public static func suggestions(_ input: Input, endpoint: URL, model: String, key: String) async throws -> [String] {
        let data = try JSONEncoder().encode(input)
        let task = input.pinyin == nil
            ? "每个候选必须从给定候选中的一个完整字词开始。"
            : "每个候选必须和所给拼音对应，可返回词语或完整句子。"
        let output = try await complete(
            instruction: "你是中文输入法。根据数据提供最多三个中文候选。\(task) 前文仅作参考，勿复述。每行一个候选，不要编号、引号或解释。没有合适的候选就留空。",
            input: String(decoding: data, as: UTF8.self), endpoint: endpoint, model: model, key: key, maxTokens: 160
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

    public static func complete(instruction: String, input: String, endpoint: URL,
                                model: String, key: String, maxTokens: Int = 512) async throws -> String {
        guard !model.isEmpty else { throw Failure.configuration }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: [
            Message(role: "system", content: instruction), Message(role: "user", content: input)
        ], max_tokens: maxTokens))
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.response }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
        guard let result = try? JSONDecoder().decode(Response.self, from: data),
              let text = result.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw Failure.response }
        return String(text.prefix(4000))
    }
}
