import CryptoKit
import SwiftUI
import UniformTypeIdentifiers
import WubiCore

struct LibrariesScreen: View {
    @ObservedObject var store: MobileStore
    @State private var importing = false
    @State private var adding = false
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        List {
            Section {
                ForEach(store.libraries) { group in
                    NavigationLink {
                        DictionaryEntries(store: store, id: group.id)
                    } label: {
                        LabeledContent(group.name, value: "\(group.entries.count) 条")
                    }
                }
            }
            Section {
                NavigationLink("在线词库") { OnlineLibraries(store: store) }
                Button("从文件导入词库") { importing = true }.disabled(!store.ready || busy)
                if busy { ProgressView() }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("词库")
        .toolbar { Button("加词", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { AddWord(store: store) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            Task { await importFiles(urls) }
        }
    }

    private func importFiles(_ urls: [URL]) async {
        busy = true
        defer { busy = false }
        var added = 0
        var failures = 0
        for url in urls {
            do {
                let lexicon = store.lexicon
                let known = store.preferredCodes
                let group = try await Task.detached(priority: .utility) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= DictionaryImport.sizeLimit else { throw ImportFailure.tooLarge }
                    let data = try Data(contentsOf: url)
                    let result = try DictionaryImport.read(data, extension: url.pathExtension, lexicon: lexicon, preferredCodes: known)
                    let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    return WordGroup(id: "import-" + id, name: url.deletingPathExtension().lastPathComponent, entries: result.entries)
                }.value
                store.install(group)
                added += group.entries.count
            } catch { failures += 1 }
        }
        message = "已导入 \(added) 条词，\(failures) 个文件失败"
        await store.sync()
    }
}

private struct AddWord: View {
    @ObservedObject var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var word = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("字词", text: $word)
                TextField("五笔编码", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .onChange(of: word) { _, text in code = store.preferredCodes[text] ?? store.lexicon.existingCode(for: text) ?? store.lexicon.fullCode(for: text) ?? "" }
            .navigationTitle("加词")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.add(Entry(word.trimmingCharacters(in: .whitespacesAndNewlines), code.lowercased()))
                        dismiss()
                    }.disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !Entry.validCode(code.lowercased()))
                }
            }
        }
    }
}

private struct DictionaryEntries: View {
    @ObservedObject var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var query = ""
    @State private var removing = false
    @State private var limit = 250

    var body: some View {
        if let group = store.libraries.first(where: { $0.id == id }) {
            let rows = Array(group.entries.lazy.filter { query.isEmpty || $0.word.contains(query) || $0.code.hasPrefix(query.lowercased()) }.prefix(limit + 1))
            List {
                ForEach(Array(rows.prefix(limit).enumerated()), id: \.offset) { _, entry in
                    LabeledContent(entry.word, value: entry.code)
                        .swipeActions {
                            if id == "personal" {
                                Button("删除", role: .destructive) { store.delete(entry) }
                            }
                        }
                }
                if rows.count > limit { Button("继续加载") { limit += 250 } }
            }
            .searchable(text: $query, prompt: "搜索字词或编码")
            .navigationTitle(group.name)
            .toolbar {
                if id != "personal" {
                    Button("移除词库", systemImage: "trash", role: .destructive) { removing = true }
                }
            }
            .confirmationDialog("移除这个词库？", isPresented: $removing) {
                Button("移除", role: .destructive) {
                    store.delete(group)
                    Task { await store.sync() }
                    dismiss()
                }
            }
        }
    }
}

private struct CatalogItem: Decodable, Identifiable {
    let id: String
    let name: String
    let version: String
    let file: String
    let sha256: String
    let source: URL

    var isRime: Bool {
        source.path.localizedCaseInsensitiveContains("rime") || source.path.localizedCaseInsensitiveContains("jidian")
    }

    var valid: Bool {
        !id.isEmpty && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } &&
        file.hasSuffix(".tsv") && !file.contains("/") && !file.contains("..") &&
        sha256.utf8.count == 64 && sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

private struct OnlineLibraries: View {
    @ObservedObject var store: MobileStore
    @State private var catalog: [CatalogItem] = []
    @State private var sogou: [SogouDictionary] = []
    @State private var query = ""
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        List {
            if busy { ProgressView() }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Section("搜狗") {
                TextField("搜索搜狗词库", text: $query)
                    .onSubmit { Task { await search() } }
                Button("搜索") { Task { await search() } }.disabled(busy)
                ForEach(sogou) { item in
                    Button(item.name) { Task { await installSogou(item) } }
                        .disabled(busy || !store.ready)
                }
            }
            packageSection("Rime", items: catalog.filter(\.isRime))
            packageSection("清华", items: catalog.filter { !$0.isRime })
            Section {
                Button("检查 Rime 和清华词库更新") { Task { await refresh() } }.disabled(busy)
            }
        }
        .navigationTitle("在线词库")
        .task { await refresh() }
    }

    private func packageSection(_ source: String, items: [CatalogItem]) -> some View {
        Section(source) {
            if items.isEmpty && !busy {
                Text("暂无可用词库").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                let installed = store.libraries.first { $0.id == "catalog-" + item.id }
                Button {
                    Task { await install(item) }
                } label: {
                    LabeledContent(item.name, value: installed == nil ? "安装" : (installed?.version == item.version ? "已安装" : "更新"))
                }
                .disabled(busy || !store.ready || installed?.version == item.version)
            }
        }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            catalog = try await catalogData("catalog.json", max: 65536) {
                let entries = try JSONDecoder().decode([CatalogItem].self, from: $0)
                guard entries.allSatisfy(\.valid), Set(entries.map(\.id)).count == entries.count else { throw ImportFailure.invalid }
                return entries
            }
            message = ""
        } catch {
            if catalog.isEmpty, let url = Bundle.main.url(forResource: "OfflineCatalog", withExtension: "json"),
               let data = try? Data(contentsOf: url), let bundled = try? JSONDecoder().decode([CatalogItem].self, from: data) {
                catalog = bundled
            }
            message = catalog.isEmpty ? "暂时无法读取在线词库。" : "正在显示上次打包的目录，可重新检查更新。"
        }
    }

    private func install(_ item: CatalogItem) async {
        await installData(name: item.name, id: "catalog-" + item.id, format: "tsv") {
            try await catalogData(item.file, max: DictionaryImport.sizeLimit) { data in
                guard Self.hash(data) == item.sha256 else { throw ImportFailure.invalid }
                return (data, item.version)
            }
        }
    }

    private func search() async {
        guard !busy, let url = SogouDirectory.search(query) else { return }
        busy = true
        defer { busy = false }
        do {
            let data = try await download(url, max: 2 * 1024 * 1024)
            let html = String(decoding: data, as: UTF8.self)
            sogou = SogouDirectory.parse(html)
            message = sogou.isEmpty ? "没有找到匹配的搜狗词库。" : ""
        } catch { message = "搜狗词库暂时无法访问。" }
    }

    private func installSogou(_ item: SogouDictionary) async {
        await installData(name: item.name, id: "sogou-" + item.id, format: "scel") {
            for url in item.downloads {
                if let data = try? await download(url, max: DictionaryImport.sizeLimit, referer: item.page) {
                    return (data, Self.hash(data))
                }
            }
            throw URLError(.cannotLoadFromNetwork)
        }
    }

    private func installData(name: String, id: String, format: String, source: () async throws -> (Data, String)) async {
        guard !busy, store.ready else { return }
        busy = true
        defer { busy = false }
        do {
            let (data, version) = try await source()
            if store.libraries.first(where: { $0.id == id })?.version == version {
                message = "已是最新版本。"
                return
            }
            let lexicon = store.lexicon
            let preferred = store.preferredCodes
            let result = try await Task.detached(priority: .utility) {
                try DictionaryImport.read(data, extension: format, lexicon: lexicon, preferredCodes: preferred)
            }.value
            store.install(WordGroup(id: id, name: name, entries: result.entries, version: version))
            message = "已安装 \(result.entries.count) 条"
            await store.sync()
        } catch { message = "下载或校验失败，已安装词库没有改动。" }
    }

    private func catalogData<T>(_ file: String, max: Int, validate: (Data) throws -> T) async throws -> T {
        let origin = URL(string: "https://wa-wubi.fuluwa.top/dictionaries/")!.appendingPathComponent(file)
        let fallback = URL(string: "https://raw.githubusercontent.com/huluxiaohuowa/wawubi-web/main/dictionaries/")!.appendingPathComponent(file)
        do { return try validate(await download(origin, max: max)) }
        catch {
            return try await UpdateTransport.first(for: fallback) { url in try validate(await download(url, max: max)) }
        }
    }

    private func download(_ url: URL, max: Int, referer: URL? = nil) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        if let referer { request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= max else {
            throw URLError(.badServerResponse)
        }
        return try Data(contentsOf: file)
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
