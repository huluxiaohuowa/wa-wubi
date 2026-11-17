import Foundation

public enum UpdateTransport {
    private static let mirrors = ["https://ghfast.top/", "https://gh-proxy.com/", "https://hk.gh-proxy.com/"]

    public static func sources(for origin: URL) -> [URL] {
        guard origin.scheme == "https", ["github.com", "api.github.com", "raw.githubusercontent.com"].contains(origin.host) else { return [origin] }
        return [origin] + mirrors.compactMap { URL(string: $0 + origin.absoluteString) }
    }

    public static func first<T>(for origin: URL, attempt: (URL) async throws -> T) async throws -> T {
        var lastError: Error = URLError(.cannotConnectToHost)
        for url in sources(for: origin) {
            try Task.checkCancellation()
            do { return try await attempt(url) }
            catch { lastError = error }
        }
        throw lastError
    }
}

public struct WubiUpdate: Equatable, Sendable {
    public let version: String
    public let url: URL
    public let bytes: Int
    public let sha256: String
}

public enum UpdateCatalog {
    private static let origin = "https://github.com/huluxiaohuowa/wa-wubi/releases/download/"
    public static let api = URL(string: "https://api.github.com/repos/huluxiaohuowa/wa-wubi/releases?per_page=20")!

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int
        let digest: String?
    }

    public static func versionParts(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard parts.count == 3, numbers.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        return numbers
    }

    public static func newest(in data: Data, newerThan installed: String) throws -> WubiUpdate? {
        let releases = try JSONDecoder().decode([Release].self, from: data)
        guard let baseline = versionParts(installed) else { return nil }
        var selected: WubiUpdate?
        var maxVersion = baseline
        var newerWithoutAsset = false
        for release in releases where !release.draft && release.tag_name.hasPrefix("v") {
            let version = String(release.tag_name.dropFirst())
            guard let parts = versionParts(version), baseline.lexicographicallyPrecedes(parts) else { continue }
            let name = "WA-Wubi-\(version).dmg"
            let source = origin + release.tag_name + "/" + name
            guard let asset = release.assets.first(where: { $0.name == name && $0.browser_download_url.absoluteString == source }),
                  asset.size > 0, asset.size <= 64 * 1024 * 1024,
                  let digest = asset.digest, digest.hasPrefix("sha256:"),
                  digest.dropFirst(7).utf8.count == 64,
                  digest.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else {
                newerWithoutAsset = true
                continue
            }
            if maxVersion.lexicographicallyPrecedes(parts) {
                maxVersion = parts
                selected = WubiUpdate(version: version, url: asset.browser_download_url, bytes: asset.size, sha256: String(digest.dropFirst(7)))
            }
        }
        if selected == nil && newerWithoutAsset { throw URLError(.cannotDecodeContentData) }
        return selected
    }
}
