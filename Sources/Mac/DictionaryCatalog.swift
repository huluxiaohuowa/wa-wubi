import CryptoKit
import Foundation
import Combine
import WubiCore

struct CatalogItem: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let version: String
    let file: String
    let sha256: String
    let source: URL
}

final class DictionaryCatalog: ObservableObject {
    @Published private(set) var items: [CatalogItem] = []
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    private let base = URL(string: "https://wa-wubi.fuluwa.top/dictionaries/")!
    private let store: LibraryStore

    init(store: LibraryStore) { self.store = store }

    func refresh() {
        guard !busy else { return }
        busy = true
        message = ""
        Task { @MainActor in
            defer { busy = false }
            do {
                let data = try await download(base.appendingPathComponent("catalog.json"), limit: 65536)
                items = try JSONDecoder().decode([CatalogItem].self, from: data)
                message = items.isEmpty ? "当前没有可安装的词库。" : "已检查词库目录。"
            } catch { message = "词库目录暂不可用，请稍后重试。" }
        }
    }

    func install(_ item: CatalogItem) {
        guard !busy, !store.loading else { return }
        busy = true
        message = ""
        let lexicon = store.lexicon
        Task { @MainActor in
            defer { busy = false }
            do {
                guard item.file.hasSuffix(".tsv"), !item.file.contains("/"), !item.file.contains(".."),
                      !item.id.isEmpty, item.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                    throw ImportFailure.invalid
                }
                let data = try await download(base.appendingPathComponent(item.file), limit: DictionaryImport.sizeLimit)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == item.sha256 else { throw ImportFailure.invalid }
                let result = try await Task.detached(priority: .utility) {
                    try DictionaryImport.read(data, extension: "tsv", lexicon: lexicon)
                }.value
                store.install(WordGroup(id: "catalog-" + item.id, name: item.name,
                                        entries: result.entries, version: item.version))
                message = "已安装 \(item.name)，共 \(result.entries.count) 条。"
            } catch { message = "下载或校验词库失败，现有词库已保留。" }
        }
    }

    private func download(_ url: URL, limit: Int) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", http.url?.host == base.host,
              http.expectedContentLength <= limit else { throw ImportFailure.invalid }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ImportFailure.tooLarge }
            data.append(byte)
        }
        return data
    }
}
