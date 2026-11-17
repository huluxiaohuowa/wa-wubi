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
    @Published private(set) var categories: [SogouDirectory.Category] = []
    @Published private(set) var installing = false
    @Published private(set) var previous: URL?
    @Published private(set) var next: URL?
    private(set) var query = ""
    private var featured: [SogouDictionary]?
    private var request: Task<Void, Never>?
    private let store: LibraryStore
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 35
        return URLSession(configuration: configuration)
    }()

    init(store: LibraryStore) { self.store = store }

    func browse(category id: String = "") {
        if let category = categories.first(where: { $0.id == id }) {
            load(category.url, term: "", page: 1)
        } else {
            load(SogouDirectory.home, term: "", page: 1)
        }
    }

    func search(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = SogouDirectory.search(term) else {
            message = "请输入 80 字以内的关键词。"
            return
        }
        load(url, term: term, page: 1)
    }

    func changePage(_ step: Int) {
        guard let url = step < 0 ? previous : next else { return }
        load(url, term: query, page: page + step)
    }

    private func load(_ url: URL, term: String, page number: Int) {
        guard !installing else { return }
        request?.cancel()
        query = term
        page = number
        previous = nil
        next = nil
        if url == SogouDirectory.home, let featured {
            request = nil
            items = featured
            message = ""
            busy = false
            return
        }
        items = []
        busy = true
        message = "正在读取搜狗词库…"
        request = Task {
            defer {
                if !Task.isCancelled { busy = false; request = nil }
            }
            do {
                let bytes = try await download(url, limit: 2_000_000)
                try Task.checkCancellation()
                let html = String(decoding: bytes, as: UTF8.self)
                items = SogouDirectory.parse(html)
                if url == SogouDirectory.home {
                    categories = SogouDirectory.categories(in: html)
                    if !items.isEmpty || !categories.isEmpty { featured = items }
                }
                previous = SogouDirectory.pageLink(in: html, label: "上一页")
                next = SogouDirectory.pageLink(in: html, label: "下一页")
                message = items.isEmpty ? "这页没有找到可下载的词库。" : ""
            } catch {
                if !Task.isCancelled { message = "搜狗网站暂时不可用，可以打开官网重试。" }
            }
        }
    }

    func install(_ item: SogouDictionary) {
        guard !busy, !store.loading else { return }
        installing = true
        busy = true
        message = "正在下载并转换为 86 五笔编码…"
        let lexicon = store.lexicon
        Task {
            defer { installing = false; busy = false }
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
