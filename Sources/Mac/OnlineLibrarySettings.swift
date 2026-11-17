import SwiftUI
import WubiCore

struct OnlineLibrarySettings: View {
    private enum Source: String, CaseIterable { case all = "全部", sogou = "搜狗", rime = "Rime", thu = "清华" }

    @ObservedObject var store: LibraryStore
    @ObservedObject var catalog: DictionaryCatalog
    @StateObject private var sogou: SogouCatalog
    @State private var source = Source.all
    @State private var query = ""

    init(store: LibraryStore, catalog: DictionaryCatalog) {
        self.store = store
        self.catalog = catalog
        _sogou = StateObject(wrappedValue: SogouCatalog(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("在线词库").font(.headline)
                Spacer()
                if source == .sogou {
                    Link("搜狗词库官网", destination: SogouDirectory.search(query) ?? SogouDirectory.home)
                        .font(.caption)
                } else {
                    Button("检查更新") { catalog.refresh() }.disabled(catalog.busy)
                }
            }
            Picker("词库来源", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: source) { value in
                query = ""
                if value == .sogou { sogou.loadIfNeeded() }
            }
            HStack {
                TextField(source == .sogou ? "搜索搜狗公开词库" : "搜索词库", text: $query)
                    .onSubmit { if source == .sogou { sogou.search(query) } }
                if source == .sogou {
                    Button("搜索") { sogou.search(query) }.disabled(sogou.busy)
                }
            }
            if source == .sogou { sogouResults }
            else { packageResults }
        }
    }

    private var packageResults: some View {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = catalog.items.filter { item in
            let rime = item.source.path.localizedCaseInsensitiveContains("rime") ||
                item.source.path.localizedCaseInsensitiveContains("jidian")
            let inSource = source == .all || (source == .rime ? rime : !rime)
            return inSource && (filter.isEmpty || item.name.localizedCaseInsensitiveContains(filter))
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(filtered) { item in
                let installed = store.groups.first { $0.id == "catalog-" + item.id }
                HStack {
                    Text(item.name)
                    Link("来源", destination: item.source).font(.caption)
                    Spacer()
                    if installed?.version == item.version {
                        Label("已安装", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(installed == nil ? "安装" : "更新") { catalog.install(item) }
                            .disabled(catalog.busy || store.loading)
                    }
                }
            }
            if filtered.isEmpty && !filter.isEmpty && !catalog.busy {
                Text("没有匹配的词库。").font(.caption).foregroundStyle(.secondary)
            }
            if !catalog.message.isEmpty { Text(catalog.message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var sogouResults: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sogou.query.isEmpty { Text("搜索「\(sogou.query)」").font(.caption).foregroundStyle(.secondary) }
            ForEach(sogou.items) { item in
                let installed = store.groups.contains { $0.id == "sogou-" + item.id }
                HStack {
                    Text(item.name).lineLimit(1)
                    Link("来源", destination: item.page).font(.caption)
                    Spacer()
                    Button(installed ? "检查并更新" : "安装") { sogou.install(item) }
                        .disabled(sogou.busy || store.loading)
                }
            }
            if sogou.page > 1 || sogou.hasMore {
                HStack {
                    Button("上一页") { sogou.search(sogou.query, page: sogou.page - 1) }
                        .disabled(sogou.busy || sogou.page == 1)
                    Text("第 \(sogou.page) 页").font(.caption).monospacedDigit()
                    Button("下一页") { sogou.search(sogou.query, page: sogou.page + 1) }
                        .disabled(sogou.busy || !sogou.hasMore)
                }
            }
            if !sogou.message.isEmpty { Text(sogou.message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
