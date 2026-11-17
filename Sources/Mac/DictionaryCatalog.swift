import Combine
import CryptoKit
import Foundation
import WubiCore

struct CatalogItem: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let file: String
    let sha256: String
    let source: URL

    var valid: Bool {
        file.hasSuffix(".tsv") && !file.contains("/") && !file.contains("..") &&
        !id.isEmpty && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } &&
        sha256.utf8.count == 64 &&
        sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

final class DictionaryCatalog: ObservableObject {
    @Published private(set) var items: [CatalogItem] = []
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    private var lastRefresh: Date?
    private let site = URL(string: "https://wa-wubi.fuluwa.top/dictionaries/")!
    private let github = URL(string: "https://raw.githubusercontent.com/huluxiaohuowa/wawubi-web/main/dictionaries/")!
    private let store: LibraryStore
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    init(store: LibraryStore) { self.store = store }

    func refresh(automatic: Bool = false) {
        guard !busy else { return }
        if automatic, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 300 { return }
        busy = true
        message = "正在检查在线词库…"
        Task { @MainActor in
            defer { busy = false }
            do {
                items = try await retrieve("catalog.json", limit: 65536) { data in
                    let list = try JSONDecoder().decode([CatalogItem].self, from: data)
                    guard list.allSatisfy(\.valid), Set(list.map(\.id)).count == list.count else {
                        throw ImportFailure.invalid
                    }
                    return list
                }
                lastRefresh = Date()
                message = items.isEmpty ? "当前没有可安装的词库。" : ""
            } catch { message = "各词库源暂不可用，请稍后重试。" }
        }
    }

    func install(_ item: CatalogItem) {
        guard !busy, !store.loading, item.valid else { return }
        busy = true
        message = "正在下载并校验词库…"
        let lexicon = store.lexicon
        Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await retrieve(item.file, limit: DictionaryImport.sizeLimit) { data in
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == item.sha256 else { throw ImportFailure.invalid }
                    return data
                }
                let known = store.preferredImportCodes
                let result = try await Task.detached(priority: .utility) {
                    try DictionaryImport.read(data, extension: "tsv", lexicon: lexicon, preferredCodes: known)
                }.value
                store.install(WordGroup(id: "catalog-" + item.id, name: item.name,
                                        entries: result.entries, version: item.version))
                message = "已安装 \(item.name)，共 \(result.entries.count) 条。"
            } catch { message = "下载或校验词库失败，现有词库已保留。" }
        }
    }

    private func retrieve<T>(_ name: String, limit: Int, validate: (Data) throws -> T) async throws -> T {
        let primary = site.appendingPathComponent(name)
        do { return try validate(await download(primary, limit: limit)) }
        catch {
            return try await UpdateTransport.first(for: github.appendingPathComponent(name)) { url in
                try validate(await download(url, limit: limit))
            }
        }
    }

    private func download(_ url: URL, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.expectedContentLength <= limit else { throw ImportFailure.invalid }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ImportFailure.tooLarge }
            data.append(byte)
        }
        return data
    }
}
