import Foundation
import Security
import WubiCore

struct MobileCloudPrediction: Codable, Equatable {
    var enabled = false
    var baseURL = ""
    var model = ""

    private static let storageKey = "mobileCloudPrediction"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: MobileStorage.group) }

    var endpoint: URL? { CloudCandidateService.endpoint(for: baseURL) }
    var origin: String? { endpoint.flatMap(CloudCandidateService.credentialOrigin) }

    static var current: Self {
        guard let data = defaults?.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return config
    }

    func save(key: String) throws {
        guard let defaults = Self.defaults else { throw CocoaError(.fileWriteNoPermission) }
        if enabled && (origin == nil || model.isEmpty) { throw CloudCandidateService.Failure.configuration }
        let data = try JSONEncoder().encode(self)
        if let origin, key != Self.key(for: origin) {
            try Self.saveKey(key, for: origin)
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    func suggestions(_ input: CloudCandidateService.Input) async throws -> [String] {
        guard enabled, let endpoint, let origin else { return [] }
        return try await CloudCandidateService.suggestions(input, endpoint: endpoint, model: model,
                                                            key: Self.key(for: origin))
    }

    private static func query(for origin: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccessGroup as String: MobileStorage.group,
            kSecAttrService as String: "WA 五笔 iOS 云联想",
            kSecAttrAccount as String: origin,
            kSecAttrSynchronizable as String: false,
        ]
    }

    static func key(for origin: String) -> String {
        var query = query(for: origin)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func saveKey(_ key: String, for origin: String) throws {
        var query = query(for: origin)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CocoaError(.fileWriteNoPermission) }
            return
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecSuccess { return }
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard status == errSecItemNotFound,
              SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
    }
}
