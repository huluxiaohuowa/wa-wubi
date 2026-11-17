import Combine
import CryptoKit
import Foundation
import WubiCore

@MainActor
final class SogouCatalog: ObservableObject {
    @Published private(set) var items: [SogouDictionary] = []
    @Published private(set) var message = ""
    @Published private(set) var busy = false
    @Published private(set) var page = 1
    @Published private(set) var hasMore = false
    private(set) var query = ""
    private var loaded = false
    private let store: LibraryStore
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 35
        return URLSession(configuration: configuration)
    }()

    init(store: LibraryStore) { self.store = store }

    func loadIfNeeded() {
        if !loaded { search("") }
    }

    func search(_ term: String, page next: Int = 1) {
        guard !busy else { return }
        guard let url = SogouDirectory.search(term, page: next) else {
            message = "请输入 80 字以内的关键词。"
            return
        }
        query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        page = next
        items = []
        hasMore = false
        busy = true
        message = "正在读取搜狗词库…"
        Task {
            defer { busy = false }
            do {
                let bytes = try await download(url, limit: 2_000_000)
                let html = String(decoding: bytes, as: UTF8.self)
                items = Array(SogouDirectory.parse(html).prefix(24))
                hasMore = !query.isEmpty && SogouDirectory.hasNextPage(in: html, after: page)
                loaded = true
                message = items.isEmpty ? "这页没有找到可下载的词库。" : ""
            } catch { message = "搜狗网站暂时不可用，可以打开官网重试。" }
        }
    }

    func install(_ item: SogouDictionary) {
        guard !busy, !store.loading else { return }
        busy = true
        message = "正在下载并转换为 86 五笔编码…"
        let lexicon = store.lexicon
        Task {
            defer { busy = false }
            for url in item.downloads {
                do {
                    let bytes = try await download(url, limit: DictionaryImport.sizeLimit, referer: item.page)
                    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    let id = "sogou-" + item.id
                    if store.groups.first(where: { $0.id == id })?.version == hash {
                        message = "已是这份搜狗词库的最新内容。"
                        return
                    }
                    let preferred = store.preferredImportCodes
                    let result = try await Task.detached(priority: .utility) {
                        try DictionaryImport.read(bytes, extension: "scel", lexicon: lexicon, preferredCodes: preferred)
                    }.value
                    store.install(WordGroup(id: id, name: item.name, entries: result.entries, version: hash))
                    message = "已加入 \(result.entries.count) 条，跳过 \(result.skipped) 条。"
                    return
                } catch { continue }
            }
            message = "官方词库暂时无法下载或转换，已安装的版本保持原样。"
        }
    }

    nonisolated private func download(_ url: URL, limit: Int, referer: URL? = nil) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", let host = http.url?.host, host.hasSuffix(".sogou.com"),
              http.expectedContentLength <= limit else { throw ImportFailure.invalid }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ImportFailure.tooLarge }
            data.append(byte)
        }
        return data
    }
}
